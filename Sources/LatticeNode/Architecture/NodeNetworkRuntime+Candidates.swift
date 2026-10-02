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

    /// Seam: candidates a parent fact was holding, handed back with the
    /// fact merged in. `observe` flips only a `.waiting(.evidence)` attempt
    /// back to `.ready`, never a `.waiting(.parentFact)` one, so each is also
    /// retried explicitly; without that it would wait for the parent's next
    /// tip change.
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

    /// The co-hosted parent level changed. Delivered off the parent's lease;
    /// it wakes the candidates parked on a parent fact that now holds.
    func parentChanged(_ change: ParentChange) async {
        switch change {
        case .tipChanged:
            parentTipChanges &+= 1
            await retryHeldParentFacts()
        case .runs, .plan:
            // The service's mailbox drains these, never the network.
            break
        }
    }

    /// Re-readies the parks whose parent fact the parent level holds now.
    /// Each distinct fact is read once, however many parks wait on it, and
    /// a park whose fact still does not hold stays parked: a parent catching
    /// up publishes once per block, and each publish costs a few local reads,
    /// not a re-admission of every parked candidate.
    func retryHeldParentFacts() async {
        guard isRunning, let parentLevel else { return }
        let generation = runtimeGeneration
        // Collected in the same synchronous segment as the wake's counter
        // bump: a park that lands after this sees the bump (`importCandidate`).
        let waits = blockFetcher.parentFactWaits()
        var held = Set<ParentFact>()
        for fact in waits {
            if await parentLevel.holds(fact) { held.insert(fact) }
        }
        guard isRunning, isCurrentGeneration(generation), !held.isEmpty else {
            return
        }
        blockFetcher.retryParentFactWaits(holding: held)
        serviceBlockFetcher()
    }

    /// Seam: a predecessor activated outside admission (an adopted genesis)
    /// wakes the successors parked behind it.
    func predecessorConnectedOutOfBand(_ blockCID: String) async {
        blockFetcher.predecessorConnectedOutOfBand(blockCID)
        serviceBlockFetcher()
    }

    /// Seam: an overlay session ended or was replaced; its provider no
    /// longer serves any candidate.
    func disconnectProvider(_ peer: AuthenticatedPeer) {
        blockFetcher.disconnect(candidateProvider(peer))
    }

    /// Seam: whether some held block parks on a predecessor this node does
    /// not hold.
    func fetcherAwaitsMissingAncestry() -> Bool {
        blockFetcher.awaitsMissingAncestry
    }

    /// Seam: whether any attempt for the block is held.
    func fetcherTracks(_ blockCID: String) -> Bool {
        blockFetcher.tracks(blockCID)
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
        deficientProviders: Set<CandidateProvider> = [],
        parentFact: ParentFact? = nil,
        awaitsChildProof: Bool = false
    ) {
        syncTrace(
            "complete \(candidate.blockCID) \(resolution) "
                + "deficient=\(deficientProviders.count)"
        )
        _ = blockFetcher.complete(
            candidate.ticket,
            resolution: resolution,
            deficientProviders: deficientProviders,
            parentFact: parentFact,
            awaitsChildProof: awaitsChildProof
        )
        serviceBlockFetcher()
    }

    /// Seam: the blocks parked awaiting a child proof, which the overlay's
    /// child-evidence lookup searches peers' indexes for.
    func childProofWaits() -> [String] {
        blockFetcher.childProofWaits()
    }

    /// `NetworkInterface.announceCarriedEvidence`: the service admitted a
    /// block under a package outside the candidate worker, which may have
    /// changed the child-evidence index root.
    func announceCarriedEvidence(_ package: AuthenticatedChildPackage) async {
        guard isRunning, let process else { return }
        scheduleChildEvidenceRootAnnounce(
            generation: runtimeGeneration,
            process: process
        )
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
        var attempt: (
            value: NodeImportOutcome,
            attribution: IvyRootContentSource.Attribution
        )?
        let header = BlockHeader(
                        rawCID: candidate.blockCID,
                        node: nil,
                        encryptionInfo: nil
        )
        // Order the direct advertisers by a per-process-seeded hash of
        // (publicKey, blockCID) — NOT raw publicKey — so an attacker cannot grind
        // Sybil keys to sort ahead of the genuine supplier for a given block, and
        // CAP the fan-out so an announcement flood cannot force O(N) sequential
        // timeouts before the recovery source (below) is reached. The recovery
        // source's full pin cascade still reaches the genuine supplier if every
        // capped slot is a Sybil, so the worst case is bounded, not unbounded.
        var exactSources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource
        )] = Self.boundedOrderedExactPeers(
            readyPeers(for: candidate.providers),
            blockCID: candidate.blockCID
        ).map {
            (
                peer: $0,
                source: candidateContentSource(
                    preferred: overlay,
                    peer: $0
                )
            )
        }
        // A verified CID remains discoverable even when its first advertiser
        // fails. Ivy resolves public pins to an exact authenticated supplier.
        exactSources.append((nil, remoteContentSource))
        for exact in exactSources {
            let initialResponse: AttributedVolumeResponse?
            if let peer = exact.peer {
                let response = await overlay.fetchVolume(
                    rootCID: candidate.blockCID,
                    from: peer
                )
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
                      response.rootCID == candidate.blockCID,
                      (try? volume.validate()) != nil else {
                    failedOverlayProviders.insert(candidateProvider(peer))
                    await overlay.reportDeficientContent(
                        rootCID: candidate.blockCID,
                        servedBy: peer.id
                    )
                    continue
                }
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return }
                guard isReadySession(peer) else {
                    continue
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
                    // Local storage first: the chain spec is almost always
                    // held already, and asking the supplier for it again is
                    // one wasted request per candidate.
                    try await Self.enforceLocalImportPolicy(
                        candidateCID: candidate.blockCID,
                        source: CompositeContentSource([process, session]),
                        configuration: configuration
                    )
                    let admitted = try await chain.importNetworkCandidate(NetworkCandidateImport(
                        header: header,
                        authenticatedChildPackage: authenticatedPackage,
                        contentSource: session,
                        weighed: candidate.weighed
                    ))
                    return admitted
                }
                await reportDeficientVolumes(resolved.attribution)
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
        if authenticatedPackage != nil {
            // An admission under a package may have added a proof to the
            // child-evidence index: push the root if it moved.
            scheduleChildEvidenceRootAnnounce(
                generation: generation,
                process: process
            )
        }

        syncTrace("admit \(candidate.blockCID.prefix(12)) weighed=\(candidate.weighed) decision=\(outcome.decision)")
        let soleSupplier = attempt.attribution.soleRemoteSupplierPublicKey
        if let blamed = Self.candidateBlame(
            outcome.decision,
            blockSupplierAtFault: outcome.blockSupplierAtFault,
            complete: attempt.attribution.allResponsesComplete,
            soleSupplier: soleSupplier,
            supplierHasReadySession: soleSupplier
                .flatMap { try? PeerKey($0) }
                .map { hasReadySession($0) } ?? false
        ) {
            await overlay.reportDeficientContent(
                rootCID: candidate.blockCID,
                servedBy: PeerID(publicKey: blamed)
            )
        }
        // A parent fact the admission lacks is read from the co-hosted parent
        // level. When the parent holds it the candidate re-readies with the
        // merged package once parked; when not, it parks until the parent's
        // tip moves and the parent holds it (`parentChanged`).
        let parentTipChanges = self.parentTipChanges
        var parentFactPackage: AuthenticatedChildPackage?
        var parentFact: ParentFact?
        if case .unavailable(let requirement?) = outcome.decision {
            parentFact = ParentFact(requirement, child: configuration.address)
        }
        if case .unavailable(let requirement?) = outcome.decision,
           let authenticatedPackage, let parentLevel {
            parentFactPackage = await parentLevel.evidence(
                for: requirement,
                child: configuration.address,
                package: authenticatedPackage
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
        }
        // A cold-synced block arrives without the package the live path
        // carries. When it needs a child proof this node cannot recover locally
        // (its own parent never mined the carriers), it parks awaiting one and
        // is looked up in the overlay peers' child-evidence indexes; each
        // proof found is enqueued as a package seed, so the retry admits it
        // exactly like the live path.
        var awaitsChildProof = false
        if authenticatedPackage == nil,
           case .unavailable(.childProof?) = outcome.decision {
            awaitsChildProof = true
        }
        let parkOn: String?
        if let predecessor = outcome.sameChainPredecessor,
           await process.hasAcceptedBlock(predecessor.predecessorCID) == false {
            // Park only when the predecessor is genuinely still missing. An
            // already-accepted predecessor already fired its one-shot connect
            // signal, so parking on it now would wedge this candidate forever.
            parkOn = predecessor.predecessorCID
        } else if let predecessor = outcome.sameChainPredecessor {
            // The immediate predecessor is accepted but itself DISCONNECTED:
            // its connect signal fired long ago, so parking on it would wedge
            // — but stopping here wedges just the same, because the segment is
            // missing a deeper ancestor. Park on the deepest genuinely-missing
            // block (the wake that actually unblocks this candidate); the park
            // also seeds its acquisition, and each arrival re-walks one level
            // until the segment connects and fork choice promotes it. This is
            // both the gap fast-forward and the fresh deep-sync descent.
            parkOn = await process.deepestMissingAncestor(
                of: predecessor.predecessorCID
            )
        } else {
            parkOn = nil
        }
        let resolution = Self.candidateResolution(
            outcome.decision,
            parkOn: parkOn,
            contentShortfall: attempt.attribution.contentUnavailable
                || attempt.attribution.localCapacityUnavailable
        )
        completeCandidate(
            candidate,
            resolution: resolution,
            deficientProviders: failedOverlayProviders,
            parentFact: parentFact,
            awaitsChildProof: awaitsChildProof
        )
        if awaitsChildProof {
            wantChildEvidence(generation: generation, process: process)
        }
        if let parentFactPackage {
            reReadyCandidates([CandidateSeed(
                blockCID: candidate.blockCID,
                package: parentFactPackage
            )])
        } else if case .wait(.parentFact) = resolution,
                  self.parentTipChanges != parentTipChanges {
            // The tip moved while the fact was read: that wake collected
            // the parked facts before this park, so check again.
            await retryHeldParentFacts()
        }
    }

    /// The peer an admission outcome blames, or nil. Only a header that
    /// proves no work the chain accepts (`proofOfWorkInvalid`) blames its
    /// sender; every other refusal blames no one. On a child chain the
    /// failure must also be the block's own (`blockSupplierAtFault`): a
    /// proof that carries no work came from the child-evidence index, not
    /// from the block's supplier, and the node does not know which peer
    /// served it, so that failure blames no one. Even then only a complete
    /// candidate is attributable, and only to its sole remote supplier while
    /// that supplier's session is ready. "Blame" is a per-root routing
    /// suppression, never a ban.
    nonisolated static func candidateBlame(
        _ decision: NodeImportDecision,
        blockSupplierAtFault: Bool,
        complete: Bool,
        soleSupplier: String?,
        supplierHasReadySession: Bool
    ) -> String? {
        guard decision == .proofOfWorkInvalid,
              blockSupplierAtFault,
              complete,
              let soleSupplier,
              supplierHasReadySession else {
            return nil
        }
        return soleSupplier
    }

    /// How the fetcher resolves an admission outcome. A missing same-chain
    /// ancestor (`parkOn`) parks the candidate on it, whatever the decision.
    /// Otherwise an accepted decision connects; `unavailable` waits: for a new
    /// provider when the body itself was not served (`contentShortfall`), for
    /// the parent's tip to move on a missing parent fact (genesis or state
    /// continuity), and for new evidence otherwise; `temporarilyInvalid`
    /// waits on a timer; every other decision is terminal.
    nonisolated static func candidateResolution(
        _ decision: NodeImportDecision,
        parkOn: String?,
        contentShortfall: Bool
    ) -> BlockFetcher.Resolution {
        if let parkOn { return .predecessor(parkOn) }
        if decision.isAccepted { return .connected }
        if decision == .unavailable(nil), contentShortfall {
            return .wait(.content)
        }
        if case .unavailable(.parentStateContinuity?) = decision {
            return .wait(.parentFact)
        }
        if decision.shouldRetryWhenEvidenceChanges { return .wait(.evidence) }
        if decision.shouldRetryLater { return .wait(.later) }
        return .terminal
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
