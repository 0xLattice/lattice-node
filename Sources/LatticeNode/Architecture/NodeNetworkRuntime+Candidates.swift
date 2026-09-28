import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    /// Seam: the one way plane code hands the fetcher a candidate. Every
    /// caller has just checked `generation` against the fence in the same
    /// synchronous segment.
    @discardableResult
    func enqueueCandidate(_ seed: CandidateSeed, generation: UInt64) -> Bool {
        guard isRunning, isCurrentGeneration(generation) else { return false }
        let result = blockFetcher.observe(seed)
        serviceBlockFetcher()
        return result.accepted
    }

    /// Seam: candidates a parent fact was holding, handed back when the fact
    /// arrives, times out or its session ends. `observe` flips only a
    /// `.waiting(.evidence)` attempt back to `.ready`, never a
    /// `.waiting(.later)` one, so each is also retried explicitly; without
    /// that it would wedge until the wall-clock poll (or 2h expiry).
    func reReadyCandidates(_ seeds: [CandidateSeed]) {
        for seed in seeds {
            _ = blockFetcher.observe(seed)
            blockFetcher.retryExternalDependency(
                blockCID: seed.blockCID,
                rootCID: seed.recoveryRootCID
            )
            serviceBlockFetcher()
        }
    }

    /// Seam: a predecessor activated outside admission (an adopted genesis)
    /// wakes the successors parked behind it.
    func predecessorConnectedOutOfBand(_ blockCID: String) {
        blockFetcher.predecessorConnectedOutOfBand(blockCID)
        serviceBlockFetcher()
    }

    /// Seam: an overlay session ended or was replaced; its provider no
    /// longer serves any candidate.
    func disconnectProvider(_ peer: AuthenticatedPeer) {
        blockFetcher.disconnect(candidateProvider(peer))
    }

    /// Seam: whether any attempt for the block is held.
    func fetcherTracks(_ blockCID: String) -> Bool {
        blockFetcher.tracks(blockCID)
    }

    /// Seam: whether an attempt for the block was seeded with the configured
    /// parent's evidence (in whatever state).
    func fetcherHasParentAttempt(_ blockCID: String) -> Bool {
        blockFetcher.hasParentAttempt(blockCID)
    }

    /// Seam: the candidate offer's gate against admission. Deferred while
    /// any of `pendingHandoff` (own candidates the parent names as carried)
    /// is ready for or in its admission: the flag is set and the admission
    /// drain re-arms the offer. Open otherwise, which also clears a deferral
    /// the drain never got to read (its attempt left the fetcher without an
    /// admission).
    func offerGate(pendingHandoff: [String]) -> Bool {
        if pendingHandoff.contains(where: { blockFetcher.isAwaitingAdmission($0) }) {
            candidateOfferDeferredByAdmission = true
            return false
        }
        candidateOfferDeferredByAdmission = false
        return true
    }

    /// Seam: the offer held behind a carried block; the admission drain
    /// re-arms it.
    func markOfferDeferred() {
        candidateOfferDeferredByAdmission = true
    }

    func candidateProvider(
        _ peer: AuthenticatedPeer
    ) -> CandidateProvider {
        CandidateProvider(
            publicKey: peer.id.publicKey,
            sessionID: peer.sessionID
        )
    }

    func serviceBlockFetcher() {
        if blockFetcher.hasTimedWait {
            scheduleWaitingCandidateRetry()
        }
        if blockFetcher.hasReadyCandidate {
            startCandidateWorker()
        }
        reviewCarriedHoldIfParentAttemptLeft()
    }

    /// Every fetcher change passes here: when the carried block's last
    /// parent-backed attempt leaves the fetcher (completed, expired, or
    /// evicted for capacity), the hold is reviewed.
    private func reviewCarriedHoldIfParentAttemptLeft() {
        let carried = carriedHoldBlockCID()
        let backed = carried.flatMap {
            blockFetcher.hasParentAttempt($0) ? $0 : nil
        }
        defer { parentBackedCarriedCID = backed }
        guard let carried, backed == nil,
              parentBackedCarriedCID == carried,
              let process else { return }
        let generation = runtimeGeneration
        Task { [weak self] in
            await self?.reviewCarriedChildHold(
                generation: generation, process: process
            )
        }
    }

    private func startCandidateWorker() {
        let generation = runtimeGeneration
        candidateWorker.start { token in
            Task { [weak self] in
                await self?.drainCandidateImports(
                    token: token,
                    generation: generation
                )
            }
        }
    }

    private func drainCandidateImports(
        token: LifetimeToken,
        generation: UInt64
    ) async {
        defer { finishCandidateWorker(token: token) }
        while isRunning, runtimeGeneration == generation,
              candidateWorker.holds(token),
              let candidate = blockFetcher.next() {
            guard let process,
                  isCurrentRuntime(
                    generation: generation,
                    process: process
                  ) else { return }
            await importCandidate(
                candidate,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ) else { return }
            serviceBlockFetcher()
            // The carried block's attempt completed (parked or left the
            // fetcher): the hold is reviewed now.
            if candidate.blockCID == carriedHoldBlockCID() {
                await reviewCarriedChildHold(
                        generation: generation, process: process
                )
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return }
            }
            // An offer deferred behind an admission is owed a look whatever
            // that admission decided: an acceptance reports a state change,
            // a park reports nothing. Only then; an admission a peer drove
            // (a duplicate, an invalid block) is not a reason to build.
            if candidateOfferDeferredByAdmission {
                candidateOfferDeferredByAdmission = false
                scheduleCandidateOffer(generation: generation, process: process)
            }
            await advanceRangeSync(generation: generation, process: process)
        }
    }

    private func finishCandidateWorker(token: LifetimeToken) {
        guard candidateWorker.clear(token) else { return }
        if isRunning, blockFetcher.hasReadyCandidate {
            startCandidateWorker()
        }
    }

    private func completeCandidate(
        _ candidate: Candidate,
        resolution: BlockFetcher.Resolution,
        deficientProviders: Set<CandidateProvider> = []
    ) {
        SyncTrace.log(
            "complete \(candidate.blockCID) \(resolution) "
                + "deficient=\(deficientProviders.count)"
        )
        _ = blockFetcher.complete(
            candidate.ticket,
            resolution: resolution,
            deficientProviders: deficientProviders
        )
        serviceBlockFetcher()
    }

    private func importCandidate(
        _ candidate: Candidate,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard let chain else { return }
        let authenticatedPackage: AuthenticatedChildPackage?
        if let package = candidate.package {
            authenticatedPackage = package
        } else if let rootCID = candidate.recoveryRootCID {
            guard let recovered = try? await process
                .recoveredAuthenticatedChildPackage(
                    for: candidate.blockCID,
                    rootCID: rootCID
                ) else {
                completeCandidate(candidate, resolution: .wait(.evidence))
                return
            }
            authenticatedPackage = recovered
        } else {
            authenticatedPackage = nil
        }
        var failedOverlayProviders = Set<CandidateProvider>()
        let childDirectories = authenticatedChildDirectories()
        var attempt: (
            value: NodeImportOutcome,
            attribution: IvyRootContentSource.Attribution
        )?
        let header = BlockHeader(
                        rawCID: candidate.blockCID,
                        node: nil,
                        encryptionInfo: nil
        )
        var exactSources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )]
        // Order the direct advertisers by a per-process-seeded hash of
        // (publicKey, blockCID) — NOT raw publicKey — so an attacker cannot grind
        // Sybil keys to sort ahead of the genuine supplier for a given block, and
        // CAP the fan-out so an announcement flood cannot force O(N) sequential
        // timeouts before the recovery source (below) is reached. The recovery
        // source's full pin cascade still reaches the genuine supplier if every
        // capped slot is a Sybil, so the worst case is bounded, not unbounded.
        let overlaySources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )] = Self.boundedOrderedExactPeers(
            readyPeers(for: candidate.providers),
            blockCID: candidate.blockCID
        ).map {
            (
                peer: $0,
                source: candidateContentSource(
                    preferred: overlay,
                    peer: $0
                ),
                plane: .overlay
            )
        }
        exactSources = []
        if authenticatedPackage != nil,
           let parent = configuredParentPeer() {
            exactSources.append((
                parent,
                candidateContentSource(
                    preferred: hierarchy,
                    peer: parent
                ),
                .hierarchy
            ))
        }
        exactSources.append(contentsOf: overlaySources)
        // A verified CID remains discoverable even when its first advertiser
        // fails. Ivy resolves public pins to an exact authenticated supplier.
        exactSources.append((nil, remoteContentSource, .overlay))
        for exact in exactSources {
            let initialResponse: AttributedVolumeResponse?
            if let peer = exact.peer, let plane = exact.plane {
                let response: AttributedVolumeResponse
                switch plane {
                case .overlay:
                    response = await overlay.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                case .hierarchy:
                    response = await hierarchy.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                }
                if response.failure == .localCapacityUnavailable {
                    continue
                }
                if response == .empty {
                    // Empty has no attributable supplier: Ivy also uses it for
                    // transient session, timeout, and enqueue failures. Keep
                    // the exact advertiser available for a quick retry.
                    continue
                }
                let volume = SerializedVolume(
                    root: response.rootCID,
                    entries: response.entries
                )
                guard response.servedBy == peer.id,
                      response.rootCID == candidate.blockCID else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard (try? volume.validate()) != nil else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return }
                switch plane {
                case .overlay:
                    guard isReadySession(peer) else {
                        continue
                    }
                case .hierarchy:
                    guard configuredParentPeer()?.sessionID == peer.sessionID else {
                        continue
                    }
                }
                initialResponse = response
            } else {
                initialResponse = nil
            }
            let capture = IvyRootContentSource.AttributionCapture()
            do {
                let resolved = try await exact.source.withRootTracing(
                    candidate.blockCID,
                    initialResponse: initialResponse,
                    capture: capture
                ) { session in
                    try await Self.enforceLocalImportPolicy(
                        candidateCID: candidate.blockCID,
                        source: session,
                        configuration: configuration
                    )
                    let admitted = try await chain.importNetworkCandidate(NetworkCandidateImport(
                        header: header,
                        authenticatedChildPackage: authenticatedPackage,
                        preparingChildDirectories: childDirectories,
                        contentSource: session,
                        weighed: candidate.weighed
                    ))
                    return admitted
                }
                await reportDeficientVolumes(resolved.attribution)
                // Admission durably records any unresolved direct-child
                // routes. The runtime's single coalesced worker owns their
                // availability retry and publishes each completed proof.
                scheduleChildProofRecovery(
                    generation: generation,
                    process: process
                )
                attempt = resolved
                break
            } catch {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                if error is NodePolicyDecline {
                    completeCandidate(
                        candidate,
                        resolution: .terminal,
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let failure = error as? BlockImportError {
                    let decision = NodeImportDecision(failure)
                    if decision.shouldRetryWhenEvidenceChanges {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.evidence),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                    if decision.shouldRetryLater {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                if error is CancellationError {
                    completeCandidate(
                        candidate,
                        resolution: .wait(.content),
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let attribution = capture.snapshot() {
                    await reportDeficientVolumes(attribution)
                    if attribution.allResponsesComplete,
                       !attribution.localCapacityUnavailable,
                       !attribution.contentUnavailable {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
            }
        }
        guard let attempt else {
            completeCandidate(
                candidate,
                resolution: .wait(.content),
                deficientProviders: failedOverlayProviders
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let outcome = attempt.value
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        if outcome.parentCarrierLink != nil {
            _ = await announceCurrentCarrierChildEvidence(
                directories: childDirectories,
                carrierCID: candidate.blockCID,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            if let authenticated = authenticatedPackage,
               let edge = await DirectChildEdge.derive(
                    from: authenticated.package.proof
               ), let edgeCID = edge.edgeCID {
                if let portableAttachmentCID = try? await process
                        .store.portableEvidenceVolumeCID(
                            scope: .incomingCarrier,
                            edgeCID: edgeCID,
                            rootCID: authenticated.package.proof.rootCID
                        ) {
                    await announcePortableAttachmentAvailability(
                        edgeCID: edgeCID,
                        rootCID: authenticated.package.proof.rootCID,
                        attachmentCID: portableAttachmentCID,
                        generation: generation,
                        process: process
                    )
                }
            }
        }

        // Only the peer that supplied a COMPLETE invalid candidate can be blamed
        // for it, and only when it was the sole remote supplier: parent evidence
        // authenticates only parent facts and never vouches for the child
        // transition. "Blame" is a per-root routing suppression, never a ban.
        SyncTrace.log("admit \(candidate.blockCID.prefix(12)) weighed=\(candidate.weighed) decision=\(outcome.decision)")
        // Only the parent's evidence decides for the hold: an overlay-seeded
        // attempt decided against (a forged package, say) says nothing.
        if candidate.fromParent,
           !outcome.decision.isAccepted,
           !outcome.decision.shouldRetryWhenEvidenceChanges,
           !outcome.decision.shouldRetryLater {
            releaseCarriedHold(ifCarried: candidate.blockCID)
        }
        if outcome.decision == .invalid {
            if attempt.attribution.allResponsesComplete,
               let supplierKey = attempt.attribution.soleRemoteSupplierPublicKey,
               let supplier = try? PeerKey(supplierKey),
               hasReadySession(supplier),
               configuration.address.isNexus || outcome.parentCarrierLink != nil {
                await overlay.reportDeficientContent(
                    rootCID: candidate.blockCID,
                    servedBy: PeerID(publicKey: supplierKey)
                )
            }
        }
        if case .unavailable(let requirement?) = outcome.decision,
           let authenticatedPackage {
            let parentPath = Array(configuration.chainPath.dropLast())
            switch requirement {
            case .parentGenesis(
                let requiredPath,
                let directory,
                let childGenesisCID,
                let parentStateCID
            ) where requiredPath == parentPath
                    && directory == configuration.address.directory:
                await requestParentChainFact(
                    .genesis(
                        childGenesisCID: childGenesisCID,
                        parentStateCID: parentStateCID
                    ),
                    for: candidate.blockCID,
                    package: authenticatedPackage,
                    generation: generation,
                    process: process
                )
            case .parentStateContinuity(
                let requiredPath,
                let fromStateCID,
                let toStateCID
            ) where requiredPath == parentPath:
                await requestParentChainFact(
                    .continuity(
                        fromStateCID: fromStateCID,
                        toStateCID: toStateCID
                    ),
                    for: candidate.blockCID,
                    package: authenticatedPackage,
                    generation: generation,
                    process: process
                )
            default:
                break
            }
        }
        // A cold-synced block arrives without the portable package the live path
        // carries. When it needs a child proof this node cannot recover locally
        // (its own parent never mined the carriers), solicit the package from the
        // block's supplier so the retry admits it exactly like the live path.
        if authenticatedPackage == nil,
           case .unavailable(.childProof(_, let childCID)?) = outcome.decision {
            await requestPortableAttachmentLocate(
                for: childCID,
                candidate: candidate,
                supplierPublicKey: attempt.attribution.soleRemoteSupplierPublicKey,
                generation: generation,
                process: process
            )
        }
        let resolution: BlockFetcher.Resolution
        if let predecessor = outcome.sameChainPredecessor,
           await process.hasAcceptedBlock(predecessor.predecessorCID) == false {
            // Park only when the predecessor is genuinely still missing. An
            // already-accepted predecessor already fired its one-shot connect
            // signal, so parking on it now would wedge this candidate forever.
            resolution = .predecessor(predecessor.predecessorCID)
        } else if let predecessor = outcome.sameChainPredecessor,
                  let missing = await process.deepestMissingAncestor(
                      of: predecessor.predecessorCID
                  ) {
            // The immediate predecessor is accepted but itself DISCONNECTED:
            // its connect signal fired long ago, so parking on it would wedge
            // — but stopping here wedges just the same, because the segment is
            // missing a deeper ancestor. Park on the deepest genuinely-missing
            // block (the wake that actually unblocks this candidate); the park
            // also seeds its acquisition, and each arrival re-walks one level
            // until the segment connects and fork choice promotes it. This is
            // both the gap fast-forward and the fresh deep-sync descent.
            resolution = .predecessor(missing)
        } else if outcome.decision.isAccepted {
            resolution = .connected
        } else if outcome.decision == .unavailable(nil),
                  (
                    attempt.attribution.contentUnavailable
                        || attempt.attribution.localCapacityUnavailable
                  ) {
            resolution = .wait(.content)
        } else if case .unavailable(.parentGenesis?) = outcome.decision {
            resolution = .wait(.later)
        } else if case .unavailable(.parentStateContinuity?) = outcome.decision {
            resolution = .wait(.later)
        } else if outcome.decision.shouldRetryWhenEvidenceChanges {
            resolution = .wait(.evidence)
        } else if outcome.decision.shouldRetryLater {
            resolution = .wait(.later)
        } else {
            resolution = .terminal
        }
        completeCandidate(
            candidate,
            resolution: resolution,
            deficientProviders: failedOverlayProviders
        )
        if outcome.decision.isAccepted, authenticatedPackage != nil,
           (try? await process.store.parentEvidenceInboxHasCapacity()) == true {
            parentEvidenceCapacityBecameAvailable()
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        }
    }

    private nonisolated static func enforceLocalImportPolicy(
        candidateCID: String,
        source: any ContentSource,
        configuration: NodeConfiguration
    ) async throws {
        let rootData = await source.fetch(Set([candidateCID]))[candidateCID]
        if let rootData, let block = Block(data: rootData) {
            let specCID = block.spec.rawCID
            if let specData = await source.fetch(Set([specCID]))[specCID] {
                guard specData.count
                        <= configuration.resourcePolicy.maximumChainSpecBytes
                else {
                    throw NodePolicyDecline.chainSpecTooLarge
                }
                if let resolvedSpec = try? await block.spec.resolve(
                    source: source
                ),
                   let spec = resolvedSpec.node,
                   spec.wasmPolicies.count
                    > configuration.resourcePolicy.maximumWasmPolicies {
                    throw NodePolicyDecline.tooManyWasmPolicies
                }
            }
        }
    }

    private func reportDeficientVolume(
        _ rootCID: String,
        servedBy peer: PeerID,
        on plane: CandidateSourcePlane
    ) async {
        switch plane {
        case .overlay:
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        case .hierarchy:
            await hierarchy.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        }
    }

    private func reportDeficientVolumes(
        _ attribution: IvyRootContentSource.Attribution
    ) async {
        for (rootCID, suppliers) in attribution.deficientVolumeSuppliers {
            for supplier in suppliers {
                await overlay.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: PeerID(publicKey: supplier)
                )
            }
        }
    }

    /// Per-process-seeded ordering key for a candidate's direct advertisers.
    /// Swift's Hasher is seeded per process, so a remote attacker cannot grind
    /// Sybil keys to sort ahead of the genuine supplier for a given block; the
    /// order stays deterministic within a node's lifetime. publicKey breaks ties.
    private static func exactSourceOrder(
        _ peer: AuthenticatedPeer,
        blockCID: String
    ) -> (Int, String) {
        var hasher = Hasher()
        hasher.combine(peer.id.publicKey)
        hasher.combine(blockCID)
        return (hasher.finalize(), peer.id.publicKey)
    }

    /// Direct advertisers to probe before the recovery source: de-ground order
    /// (see exactSourceOrder) capped to a small constant, so an announcement flood
    /// cannot force O(N) sequential fetch timeouts per block.
    static func boundedOrderedExactPeers(
        _ peers: [AuthenticatedPeer],
        blockCID: String
    ) -> [AuthenticatedPeer] {
        peers
            .sorted {
                exactSourceOrder($0, blockCID: blockCID)
                    < exactSourceOrder($1, blockCID: blockCID)
            }
            .prefix(maximumExactContentSources)
            .map { $0 }
    }

    private func candidateContentSource(
        preferred ivy: Ivy,
        peer: AuthenticatedPeer
    ) -> IvyRootContentSource {
        let fallback = overlay
        return IvyRootContentSource { rootCID in
            let response = await ivy.fetchVolume(
                rootCID: rootCID,
                from: peer
            )
            if response.failure == .localCapacityUnavailable {
                return response
            }
            guard response != .empty,
                  response.servedBy == peer.id else {
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            guard response.rootCID == rootCID,
                  (try? volume.validate()) != nil else {
                await ivy.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: peer.id
                )
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            return response
        }
    }

    private func scheduleWaitingCandidateRetry() {
        guard blockFetcher.hasTimedWait else { return }
        let generation = runtimeGeneration
        waitingCandidateRetryTask.start { token in
            Timers.deadline(
                after: Self.futureCandidateRetryInterval,
                generation: generation
            ) { [weak self] generation in
                await self?.retryWaitingCandidates(
                    token: token,
                    generation: generation
                )
            }
        }
    }

    private func retryWaitingCandidates(
        token: LifetimeToken,
        generation: UInt64
    ) {
        guard waitingCandidateRetryTask.clear(token),
              isCurrentGeneration(generation), isRunning else { return }
        blockFetcher.retry()
        serviceBlockFetcher()
    }
}
