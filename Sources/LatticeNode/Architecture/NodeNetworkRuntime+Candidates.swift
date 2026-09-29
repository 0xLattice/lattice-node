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
    /// it wakes the candidates parked on a parent fact that now holds, and a
    /// chain still awaiting its genesis looks for the parent's anchor.
    func parentChanged(_ change: ParentChange) async {
        switch change {
        case .tipChanged:
            parentTipChanges &+= 1
            triggerGenesisActivation()
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
    /// wakes the successors parked behind it, and is an acceptance like any
    /// other for the parent evidence waiting on it.
    func predecessorConnectedOutOfBand(_ blockCID: String) async {
        blockFetcher.predecessorConnectedOutOfBand(blockCID)
        serviceBlockFetcher()
        guard let process else { return }
        await parentEvidenceRetryTrigger(
            accepted: blockCID, generation: runtimeGeneration, process: process
        )
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

    /// Seam: whether an attempt for the block was seeded with the configured
    /// parent's evidence (in whatever state).
    func fetcherHasParentAttempt(_ blockCID: String) -> Bool {
        blockFetcher.hasParentAttempt(blockCID)
    }

    /// Seam: the ready candidate's gate against admission. Closed while any
    /// of `pendingHandoff` (own candidates the parent names as carried) is
    /// ready for or in its admission: the carried block is about to be this
    /// chain's weighed tip, and a candidate built now would only be its
    /// sibling. The flag is set and the admission drain re-arms the build.
    /// Open otherwise, which also clears a deferral the drain never got to
    /// read (its attempt left the fetcher without an admission).
    func offerGate(pendingHandoff: [String]) -> Bool {
        if pendingHandoff.contains(where: { blockFetcher.isAwaitingAdmission($0) }) {
            candidateOfferDeferredByAdmission = true
            return false
        }
        candidateOfferDeferredByAdmission = false
        return true
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
            // A build deferred behind an admission is owed a look whatever
            // that admission decided: an acceptance reports a state change,
            // a park reports nothing. Only then; an admission a peer drove
            // (a duplicate, an invalid block) is not a reason to build.
            if candidateOfferDeferredByAdmission {
                candidateOfferDeferredByAdmission = false
                await chain?.candidateGateReopened()
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
        deficientProviders: Set<CandidateProvider> = [],
        parentFact: ParentFact? = nil
    ) {
        syncTrace(
            "complete \(candidate.blockCID) \(resolution) "
                + "deficient=\(deficientProviders.count)"
        )
        _ = blockFetcher.complete(
            candidate.ticket,
            resolution: resolution,
            deficientProviders: deficientProviders,
            parentFact: parentFact
        )
        serviceBlockFetcher()
    }

    /// `NetworkInterface.announceCarriedEvidence`: the service admitted a
    /// carrier-linked block under `package` outside the candidate worker.
    func announceCarriedEvidence(_ package: AuthenticatedChildPackage) async {
        guard isRunning, let process else { return }
        await announcePortableAttachment(
            package,
            generation: runtimeGeneration,
            process: process
        )
    }

    /// Announces the portable attachment a carrier-linked admission under
    /// `authenticated` stored, so overlay peers can fetch the block's proof.
    private func announcePortableAttachment(
        _ authenticated: AuthenticatedChildPackage,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let edge = await DirectChildEdge.derive(
                from: authenticated.package.proof
              ), let edgeCID = edge.edgeCID,
              let portableAttachmentCID = try? await process
                .store.portableEvidenceVolumeCID(
                    scope: .incomingCarrier,
                    edgeCID: edgeCID,
                    rootCID: authenticated.package.proof.rootCID
                ) else { return }
        await announcePortableAttachmentAvailability(
            edgeCID: edgeCID,
            rootCID: authenticated.package.proof.rootCID,
            attachmentCID: portableAttachmentCID,
            generation: generation,
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
                    // Declined by this node's policy: decided here, so its
                    // parent evidence is consumed.
                    if let authenticatedPackage {
                        try? await process.consumeDeclinedParentEvidence(
                            childCID: candidate.blockCID,
                            rootCID: authenticatedPackage.package.proof.rootCID
                        )
                    }
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
                        await orphanUndecidedParentEvidence(
                            candidate, package: authenticatedPackage,
                            resolution: .wait(.evidence), decision: decision,
                            notBefore: nil, generation: generation, process: process
                        )
                        return
                    }
                    if decision.shouldRetryLater {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        await orphanUndecidedParentEvidence(
                            candidate, package: authenticatedPackage,
                            resolution: .wait(.later), decision: decision,
                            notBefore: nil, generation: generation, process: process
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
                        await orphanUndecidedParentEvidence(
                            candidate, package: authenticatedPackage,
                            resolution: .wait(.later), decision: nil,
                            notBefore: nil, generation: generation, process: process
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
            await orphanUndecidedParentEvidence(
                candidate, package: authenticatedPackage,
                resolution: .wait(.content), decision: nil,
                notBefore: nil, generation: generation, process: process
            )
            if authenticatedPackage == nil {
                // Only the parent's evidence opens its content to a lone
                // child: ask the parent for it.
                await requestParentEvidence(
                    for: candidate.blockCID, generation: generation, process: process
                )
            }
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
            if let authenticated = authenticatedPackage {
                await announcePortableAttachment(
                    authenticated,
                    generation: generation,
                    process: process
                )
            }
        }

        syncTrace("admit \(candidate.blockCID.prefix(12)) weighed=\(candidate.weighed) decision=\(outcome.decision)")
        let soleSupplier = attempt.attribution.soleRemoteSupplierPublicKey
        if let blamed = Self.candidateBlame(
            outcome.decision,
            complete: attempt.attribution.allResponsesComplete,
            soleSupplier: soleSupplier,
            supplierHasReadySession: soleSupplier
                .flatMap { try? PeerKey($0) }
                .map { hasReadySession($0) } ?? false,
            isNexus: configuration.address.isNexus,
            hasCarrierLink: outcome.parentCarrierLink != nil
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
            // The parent's durable index may hold it where no overlay peer
            // admitted it (a lone child, its orphan evicted or lost).
            await requestParentEvidence(
                for: childCID, generation: generation, process: process
            )
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
            parentFact: parentFact
        )
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
        await orphanUndecidedParentEvidence(
            candidate, package: authenticatedPackage,
            resolution: resolution, decision: outcome.decision,
            notBefore: outcome.notBefore, generation: generation, process: process
        )
        // A block reached without its parent's evidence whose content no
        // overlay peer serves (a lone child's predecessor walk): the parent's
        // evidence brings the block's content with it, so ask the parent.
        if authenticatedPackage == nil, case .wait(.content) = resolution {
            await requestParentEvidence(
                for: candidate.blockCID, generation: generation, process: process
            )
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        // An accepted block may be what orphaned parent evidence waits on.
        if outcome.decision.isAccepted {
            await parentEvidenceRetryTrigger(
                accepted: candidate.blockCID, generation: generation, process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
        }
        // A decided block consumed its inbox entry, accepted or not: room
        // for evidence that waited on it.
        let decided: Bool = switch resolution {
        case .connected, .terminal: true
        case .wait, .predecessor: false
        }
        if decided, let authenticatedPackage {
            parentEvidenceDecided(
                childCID: candidate.blockCID,
                rootCID: authenticatedPackage.package.proof.rootCID
            )
        }
        if decided, authenticatedPackage != nil,
           (try? await process.store.parentEvidenceInboxHasCapacity()) == true {
            parentEvidenceCapacityBecameAvailable()
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        }
    }

    /// The peer an admission outcome blames, or nil. Only a complete
    /// `invalid` candidate is attributable, and only to its sole remote
    /// supplier while that supplier's session is ready. On a child chain the
    /// candidate must also carry a parent carrier link: parent evidence
    /// authenticates only parent facts and never vouches for the child
    /// transition. "Blame" is a per-root routing suppression, never a ban.
    nonisolated static func candidateBlame(
        _ decision: NodeImportDecision,
        complete: Bool,
        soleSupplier: String?,
        supplierHasReadySession: Bool,
        isNexus: Bool,
        hasCarrierLink: Bool
    ) -> String? {
        guard decision == .invalid,
              complete,
              let soleSupplier,
              supplierHasReadySession,
              isNexus || hasCarrierLink else {
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
        if case .unavailable(.parentGenesis?) = decision {
            return .wait(.parentFact)
        }
        if case .unavailable(.parentStateContinuity?) = decision {
            return .wait(.parentFact)
        }
        if decision.shouldRetryWhenEvidenceChanges { return .wait(.evidence) }
        if decision.shouldRetryLater { return .wait(.later) }
        return .terminal
    }

    /// An undecided parent-backed import leaves the inbox as an orphan
    /// unless a parent fact decides it (`ParentEvidenceOrphans.retry`).
    private func orphanUndecidedParentEvidence(
        _ candidate: Candidate,
        package: AuthenticatedChildPackage?,
        resolution: BlockFetcher.Resolution,
        decision: NodeImportDecision?,
        notBefore: Int64?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let package,
              isCurrentRuntime(generation: generation, process: process),
              let retry = ParentEvidenceOrphans.retry(
                resolution: resolution,
                decision: decision,
                notBefore: notBefore,
                now: ParentEvidenceOrphans.clock()
              ) else { return }
        await parentEvidenceOrphaned(
            childCID: candidate.blockCID,
            rootCID: package.package.proof.rootCID,
            retry: retry,
            generation: generation,
            process: process
        )
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
