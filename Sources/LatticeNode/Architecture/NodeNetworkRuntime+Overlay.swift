import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    public func announceBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        try await announceBlock(
            blockCID,
            generation: runtimeGeneration,
            process: process
        )
    }

    func announceBlock(
        _ blockCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async throws {
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        // The announced block's OWN height, not the validated tip's: every
        // accepted block is announced (weighed pages and frontier leaves
        // included), and a receiver's gap test reads the pair as one claim. A
        // catching-up node announcing (block@1000, height 100) would hide the
        // gap and record a stale tip at every receiver.
        let height = await process.acceptedBlockHeight(blockCID)
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let payload = try BlockAnnouncementMessage(
            blockCID: blockCID,
            height: height
        ).encoded()
        for peer in readyOverlayPeers {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
        }
    }

    public func publishAcceptedBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        try await announceBlock(
            blockCID,
            generation: generation,
            process: process
        )
    }

    /// Announces an already admitted complete transaction Volume to same-chain
    /// overlay peers. The process content source serves the Volume itself.
    public func publishTransaction(_ volumeRootCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: volumeRootCID
        ).encoded() else { return }
        for peer in readyOverlayPeers {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    func handleOverlay(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.overlayHello {
            syncTrace(
                "overlay hello peer=\(peer.key.hex.prefix(8)) "
                    + "expected=\(expectsOverlayHello(from: peer))"
            )
            guard expectsOverlayHello(from: peer) else { return }
            guard let remote = try? ChainHello.decode(message.payload),
                  (try? remote.validateCompatibility(
                    expectedNexusGenesisCID: configuration.nexusGenesisCID,
                    expectedChainPath: configuration.chainPath
                )) != nil
            else {
                await overlay.disconnectSession(ifCurrent: peer)
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  expectsOverlayHello(from: peer) else { return }
            removeOverlayHelloDeadline(for: peer.key, session: peer.sessionID)?.task.cancel()
            overlayState.overlayRecords.update(session: peer) { $0.session = .ready(peer) }
            overlayPeerMayProvideGenesis()
            // Advertise the ACQUIRED (canonical, weighed-inclusive) tip: every
            // receiver measures its gap, its range-sync target and its edge
            // against acquired heights, so advertising the validated tip would
            // strand a joiner at our validated height on a quiet network and
            // make it pull our frontier while genuinely deep.
            let helloTip = await process.canonicalTip()
            if let helloTip,
                let payload = try? BlockAnnouncementMessage(
                    blockCID: helloTip.cid,
                    height: helloTip.height
                ).encoded()
            {
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else {
                    return
                }
                let sent = await overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
                syncTrace(
                    "hello reply peer=\(peer.key.hex.prefix(8)) "
                        + "tip=\(helloTip.height) sent=\(sent)"
                )
            }
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            await sendChildEvidenceRoot(
                to: peer,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            // The peer's frontier is pulled by `pullFrontierIfAtEdge` once its
            // tip is known (its own hello-reply announcement) and we are at
            // the live edge with respect to it — never blindly here.
            // Child-proof recovery fetches the child content an owed route
            // lacks through the overlay: a new same-chain peer is a source an
            // earlier iteration did not have. Re-arming costs one coalesced
            // pass (a refresh flag while one runs).
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
            await requestTransactionInventory(
                from: peer,
                after: nil,
                generation: generation,
                process: process
            )
            return
        }

        guard overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        switch message.topic {
        case NodeNetworkTopic.transactionAvailable:
            guard let available = try? TransactionAvailableMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionVolume(
                available.volumeRootCID,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            guard let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
            ) else { return }
            await serveTransactionInventory(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryResponse:
            guard let response = try? TransactionInventoryResponseMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionInventory(
                response,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.childEvidenceRoot:
            guard let root = try? ChildEvidenceRootMessage
                .decoded(message.payload) else { return }
            receiveChildEvidenceRoot(
                root.rootCID,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.readEndpointRequest:
            guard let request = try? ReadEndpointRequestMessage.decoded(
                    message.payload
                )
            else { return }
            // The state walk behind declaredReadURLs runs only when this node
            // has anything to declare, single-flight per session, AND under
            // a global parent-state query capacity — an overlay peer flood
            // cannot multiply tip-state walks. Every other outcome
            // still answers empty: a fast negative beats making the asker
            // burn its timeout.
            var urls: [String] = []
            if configuration.publicReadURL != nil
                || anyChildDeclaredReadURL,
                sessionLeases.servingReadEndpoints.insert(peer.sessionID).inserted {
                defer {
                    if isCurrentRuntime(
                        generation: generation,
                        process: process
                    ) {
                        sessionLeases.servingReadEndpoints.remove(peer.sessionID)
                    }
                }
                if let hold = parentStateQueryGuard.acquire(peer.key) {
                    defer {
                        parentStateQueryGuard.release(hold)
                    }
                    urls = await declaredReadURLs(
                        genesisCID: request.genesisCID,
                        process: process
                    )
                }
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  let payload = try? ReadEndpointResponseMessage(
                      requestID: request.requestID,
                      genesisCID: request.genesisCID,
                      readURLs: urls
                  ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.readEndpointResponse,
                payload: payload
            )
        case NodeNetworkTopic.readEndpointResponse:
            guard let response = try? ReadEndpointResponseMessage.decoded(
                    message.payload
                ),
                let pending = overlayState.readURLDiscovery.pendingReadEndpoints[response.requestID],
                pending.peer.key == peer.key,
                pending.peer.sessionID == peer.sessionID,
                pending.genesisCID == response.genesisCID
            else { return }
            overlayState.readURLDiscovery.pendingReadEndpoints.removeValue(forKey: response.requestID)
            pending.timeout.cancel()
            pending.continuation.resume(returning: response.readURLs)
        case NodeNetworkTopic.blockAnnouncement:
            guard let announcement = try? BlockAnnouncementMessage.decoded(message.payload) else {
                return
            }
            await overlay.rememberProvider(
                rootCID: announcement.blockCID,
                peer: peer.id
            )
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
            // Only a genuinely deep gap — far more than a predecessor pull should
            // bridge — starts a forward-apply range sync; shallow and
            // steady-state propagation and child-chain rounds keep the fast
            // direct path below, with no wasted range-sync round-trips. The
            // announced height is the gap signal (absent for legacy peers, which
            // then just use the direct path).
            if await process.hasAcceptedBlock(announcement.blockCID) == false {
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
                let ourHeight = await fetchedHeight(process)
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
                if let announced = announcement.height {
                    // Remember the claim so a cleared range sync can re-enter
                    // on the receiver's own initiative: on a quiet network no
                    // further announcement ever arrives to restart it.
                    let known = overlayState.overlayRecords[peer.key]?.announcedTip?.height ?? 0
                    if announced > known
                        || overlayState.overlayRecords[peer.key]?.announcedTip?.peer.sessionID
                            != peer.sessionID {
                        overlayState.overlayRecords.update(session: peer) {
                            $0.announcedTip = (announced, peer)
                        }
                    }
                }
                if let announced = announcement.height,
                   announced > ourHeight + RangeSync.depthThreshold {
                    await startRangeSync(
                        peer: peer,
                        targetHeight: announced,
                        generation: generation,
                        process: process
                    )
                    guard isCurrentRuntime(generation: generation, process: process),
                          overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
                }
            }
            // A tip claim while blocks here park on missing ancestry: the
            // gap test above cannot see that gap (it may lie below our tip
            // or on another branch), so page this peer's chain from our fork
            // point once per session, as a locator exchange would.
            if let announced = announcement.height {
                await syncMissingAncestryIfNeeded(
                    from: peer,
                    peerHeight: announced,
                    generation: generation,
                    process: process
                )
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
            }
            // At-edge evaluation happens whether or not we hold the block:
            // holding the peer's tip IS being at its edge. The peer's height
            // is its best claim this session (this announcement or a taller
            // recorded one), so a losing-sibling announcement below its tip
            // cannot read as "at edge" while we are still deep.
            if let announced = announcement.height {
                let recorded = overlayState.overlayRecords[peer.key]?.announcedTip
                let peerHeight = recorded?.peer.sessionID == peer.sessionID
                    ? max(announced, recorded?.height ?? 0)
                    : announced
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: peerHeight,
                    generation: generation,
                    process: process
                )
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
            }
            // Network-sourced: weighed. It ranks on verified work and the
            // validate-on-candidacy walk executes it exactly when canonical.
            let candidate = CandidateSeed(
                blockCID: announcement.blockCID,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            )
            guard enqueueCandidate(candidate, generation: generation) else { return }
        case NodeNetworkTopic.acceptedLeavesRequest:
            // Answers a peer's one-shot frontier pull (see
            // `pullFrontierIfAtEdge`) with one page of accepted leaves; older
            // peers' cursored descent still pages through the same handler.
            guard
                let request = try? AcceptedLeavesRequestMessage.decoded(
                    message.payload
                ), sessionLeases.servingAcceptedLeaves.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(
                    generation: generation,
                    process: process
                ) {
                    sessionLeases.servingAcceptedLeaves.remove(peer.sessionID)
                }
            }
            guard
                let leaves = try? await process.store.acceptedLeafPage(
                    afterCID: request.afterCID,
                    snapshotSequence: request.snapshotSequence,
                    limit: AcceptedLeavesResponseMessage.maximumLeaves + 1
                ), isCurrentRuntime(generation: generation, process: process)
            else {
                return
            }
            // The cursor-less page is the most recently admitted leaves (the
            // frontier pull); the wire carries a page CID-sorted, and the
            // receiver never depends on order. A cursored (legacy descent)
            // page is already in CID order.
            let page = Array(
                leaves.blockCIDs.prefix(AcceptedLeavesResponseMessage.maximumLeaves)
            ).sorted()
            syncTrace(
                "frontier serve peer=\(peer.key.hex.prefix(8)) leaves=\(page.count)"
            )
            guard
                let payload = try? AcceptedLeavesResponseMessage(
                    requestID: request.requestID,
                    afterCID: request.afterCID,
                    snapshotSequence: leaves.snapshotSequence,
                    blockCIDs: page,
                    hasMore: leaves.blockCIDs.count > page.count
                ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        case NodeNetworkTopic.acceptedLeavesResponse:
            // The frontier page (see `pullFrontierIfAtEdge`): accepted only as
            // the one answer to the one request we sent this session —
            // correlated by requestID like every other response, then the
            // request is consumed, so an unsolicited, mismatched or repeated
            // page seeds nothing. Every leaf we lack seeds weighed; its
            // predecessor walk parks on missing ancestors that range sync or
            // the walk itself fills. No cursor, no retry state.
            guard let response = try? AcceptedLeavesResponseMessage.decoded(
                message.payload
            ) else { return }
            guard var pull = overlayState.overlayRecords[peer.key]?.frontierPull,
                  pull.sessionID == peer.sessionID,
                  pull.requestID == response.requestID else {
                syncTrace(
                    "frontier page rejected peer=\(peer.key.hex.prefix(8)) "
                        + "leaves=\(response.blockCIDs.count)"
                )
                return
            }
            pull.requestID = nil
            overlayState.overlayRecords.update(session: peer) { $0.frontierPull = pull }
            syncTrace(
                "frontier page peer=\(peer.key.hex.prefix(8)) "
                    + "leaves=\(response.blockCIDs.count)"
            )
            for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
                await overlay.rememberProvider(rootCID: cid, peer: peer.id)
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
                if await process.hasAcceptedBlock(cid) { continue }
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
                _ = enqueueCandidate(CandidateSeed(
                    blockCID: cid,
                    package: nil,
                    provider: candidateProvider(peer),
                    weighed: true
                ), generation: generation)
            }
        case NodeNetworkTopic.forwardRangeRequest:
            guard
                let request = try? ForwardRangeRequestMessage.decoded(
                    message.payload
                ), sessionLeases.servingAncestorRange.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(generation: generation, process: process) {
                    sessionLeases.servingAncestorRange.remove(peer.sessionID)
                }
            }
            let page = await process.forwardCanonicalRange(
                afterCID: request.afterCID,
                limit: ForwardRangeResponseMessage.maximumBlocks
            )
            guard
                isCurrentRuntime(generation: generation, process: process),
                let payload = try? ForwardRangeResponseMessage(
                    requestID: request.requestID,
                    afterCID: request.afterCID,
                    blockCIDs: page.blockCIDs,
                    hasMore: page.hasMore
                ).encoded()
            else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.forwardRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.forwardRangeResponse:
            await handleForwardRangeResponse(
                message,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            guard
                let request = try? AncestorRangeRequestMessage.decoded(
                    message.payload
                ), sessionLeases.servingAncestorRange.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(generation: generation, process: process) {
                    sessionLeases.servingAncestorRange.remove(peer.sessionID)
                }
            }
            let page = await process.commonAncestorRange(
                locator: request.locator,
                limit: AncestorRangeResponseMessage.maximumBlocks
            )
            guard
                isCurrentRuntime(generation: generation, process: process),
                let payload = try? AncestorRangeResponseMessage(
                    requestID: request.requestID,
                    commonAncestor: page.commonAncestor,
                    blockCIDs: page.blockCIDs,
                    hasMore: page.hasMore
                ).encoded()
            else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeResponse:
            await handleAncestorRangeResponse(
                message,
                from: peer,
                generation: generation,
                process: process
            )
        default:
            break
        }
    }

    private func requestTransactionInventory(
        from peer: AuthenticatedPeer,
        after: String?,
        generation: UInt64,
        process: ChainProcess,
        remainingRoots requestedRemainingRoots: Int? = nil,
        seenRoots: Set<String> = []
    ) async {
        let remainingRoots = requestedRemainingRoots
            ?? Self.maximumTransactionInventoryRootsPerSync
        guard remainingRoots > 0,
              chain?.networkCapabilities.contains(.transactions) == true,
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID,
              !overlayState.pendingTransactionInventories.values.contains(where: {
                  $0.peer.sessionID == peer.sessionID
              }) else { return }
        let request = TransactionInventoryRequestMessage(
            requestID: makeRequestID(),
            afterRootCID: after
        )
        guard let payload = try? request.encoded() else { return }
        let timeout = Timers.deadline(
            after: planeConfigurations.overlay.requestTimeout,
            generation: generation
        ) { [weak self] generation in
            await self?.transactionInventoryTimedOut(
                requestID: request.requestID,
                generation: generation
            )
        }
        overlayState.pendingTransactionInventories[request.requestID] = .init(
            peer: peer,
            request: request,
            remainingRoots: remainingRoots,
            seenRoots: seenRoots,
            timeout: timeout
        )
        let result = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryRequest,
            payload: payload
        )
        switch result {
        case .enqueued:
            break
        case .backpressured, .locallyRejected, .notConnected:
            overlayState.pendingTransactionInventories.removeValue(
                forKey: request.requestID
            )?.timeout.cancel()
        }
    }

    private func transactionInventoryTimedOut(
        requestID: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation),
              let pending = overlayState.pendingTransactionInventories.removeValue(
                forKey: requestID
              ) else { return }
        await overlay.recycleSession(ifCurrent: pending.peer)
    }

    private func serveTransactionInventory(
        _ request: TransactionInventoryRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let chain,
              chain.networkCapabilities.contains(.transactionInventory),
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        let roots = Array(Set(await chain.transactionInventoryRoots())).sorted()
            .filter { root in
                request.afterRootCID.map { root > $0 } ?? true
            }
        let page = Array(
            roots.prefix(TransactionInventoryResponseMessage.maximumRoots)
        )
        guard let payload = try? TransactionInventoryResponseMessage(
            requestID: request.requestID,
            afterRootCID: request.afterRootCID,
            volumeRootCIDs: page,
            hasMore: roots.count > page.count
        ).encoded() else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: payload
        )
    }

    private func scheduleTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let pending = overlayState.pendingTransactionInventories[response.requestID],
              pending.peer.sessionID == peer.sessionID,
              pending.request.afterRootCID == response.afterRootCID else { return }
        overlayState.pendingTransactionInventories.removeValue(
            forKey: response.requestID
        )?.timeout.cancel()
        Task { [weak self] in
            await self?.receiveTransactionInventory(
                response,
                pending: pending,
                from: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func receiveTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        pending: PendingTransactionInventory,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let chain,
              chain.networkCapabilities.contains(.transactionInventory),
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        let knownRoots = Set(await chain.transactionInventoryRoots())
        let roots = response.volumeRootCIDs.filter {
            !knownRoots.contains($0) && !pending.seenRoots.contains($0)
        }
        let selected = Array(roots.prefix(pending.remainingRoots))
        for rootCID in selected {
            guard let work = reserveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process
            ) else { continue }
            await receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                chain: work.chain,
                lease: work.lease
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
        }
        // Every page costs at least one unit of the session budget, so a
        // peer serving roots we already know cannot page for free — while an
        // all-known page still continues the scan, because honest mempools
        // overlap and later pages may hold roots we lack. The wire contract
        // (strictly ascending, unique, full page when hasMore) already
        // prevents replaying the same roots within a session.
        let remainingRoots = pending.remainingRoots - max(selected.count, 1)
        if response.hasMore,
           remainingRoots > 0,
           let cursor = response.volumeRootCIDs.last {
            await requestTransactionInventory(
                from: peer,
                after: cursor,
                generation: generation,
                process: process,
                remainingRoots: remainingRoots,
                seenRoots: pending.seenRoots.union(response.volumeRootCIDs)
            )
        }
    }

    private func scheduleTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let work = reserveTransactionVolume(
            rootCID,
            from: peer,
            generation: generation,
            process: process
        ) else { return }
        Task { [weak self] in
            await self?.receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                chain: work.chain,
                lease: work.lease
            )
        }
    }

    private func reserveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> (chain: any ChainInterface, lease: TransactionVolumeLease)? {
        guard let chain,
              chain.networkCapabilities.contains(.transactions),
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return nil }
        let lease = TransactionVolumeLease(
            sessionID: peer.sessionID,
            rootCID: rootCID
        )
        guard !sessionLeases.activeTransactionVolumes.contains(lease),
              sessionLeases.activeTransactionVolumes.count
                  < Self.maximumConcurrentTransactionVolumes,
              sessionLeases.activeTransactionVolumes.insert(lease).inserted else { return nil }
        return (chain, lease)
    }

    private func receiveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess,
        chain: any ChainInterface,
        lease: TransactionVolumeLease
    ) async {
        defer { sessionLeases.activeTransactionVolumes.remove(lease) }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        if let chain = self.chain,
           chain.networkCapabilities.contains(.transactionInventory),
           await chain.transactionInventoryRoots().contains(rootCID) {
            return
        }

        let response: AttributedVolumeResponse
        switch await Timers.retryWhileCapacityUnavailable(
            every: planeConfigurations.overlay.requestTimeout,
            attempt: { await overlay.fetchVolume(rootCID: rootCID, from: peer) },
            capacityUnavailable: { $0.failure == .localCapacityUnavailable },
            stillCurrent: {
                isCurrentRuntime(generation: generation, process: process)
                    && overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID
            }
        ) {
        case .value(let fetched):
            response = fetched
        case .cancelled, .stale:
            return
        }
        let volume = SerializedVolume(
            root: response.rootCID,
            entries: response.entries
        )
        guard response.servedBy == peer.id,
              response.rootCID == rootCID else {
            await overlay.recycleSession(ifCurrent: peer)
            return
        }
        guard (try? volume.validate()) != nil,
              let resolved = try? await VolumeImpl<Transaction>(
                rawCID: rootCID,
                node: nil,
                encryptionInfo: nil
            ).resolveRecursive(source: InMemoryContentSource(volume.entries)),
              resolved.rawCID == rootCID,
              let transaction = resolved.node else {
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer.id
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        do {
            guard try await chain.submitNetworkTransaction(transaction) else { return }
        } catch {
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: rootCID
        ).encoded() else { return }
        for candidate in readyOverlayPeers
        where candidate.sessionID != peer.sessionID {
            _ = await overlay.sendMessage(
                to: candidate,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    nonisolated static func resolveEvidenceVolume(
        _ cid: String,
        childCID: String? = nil,
        source: IvyRootContentSource.Session
    ) async -> ChildEvidenceVolume? {
        guard let serialized = await source.volume(rootCID: cid) else {
            return nil
        }
        return try? ChildEvidenceVolume(
            serialized: serialized,
            childCID: childCID
        )
    }

    func scheduleOverlayHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        removeOverlayHelloDeadline(for: peer.key, session: nil)?.task.cancel()
        let token = LifetimeToken.next()
        let task = Timers.deadline(
            after: planeConfigurations.overlay.requestTimeout,
            generation: generation
        ) { [weak self] generation in
            await self?.overlayHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        overlayState.overlayRecords.update(session: peer) {
            $0.helloDeadline = HelloDeadline(
                token: token,
                sessionID: peer.sessionID,
                task: task
            )
        }
    }

    private func expectsOverlayHello(from peer: AuthenticatedPeer) -> Bool {
        overlayState.overlayRecords[peer.key]?.awaitingHelloPeer?.sessionID == peer.sessionID
            && overlayState.overlayRecords[peer.key]?.helloDeadline?.sessionID == peer.sessionID
    }

    private func overlayHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: LifetimeToken
    ) async {
        guard isCurrentGeneration(generation), isRunning,
              overlayState.overlayRecords[peer.key]?.helloDeadline?.token == token,
              overlayState.overlayRecords[peer.key]?.helloDeadline?.sessionID == peer.sessionID,
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID != peer.sessionID else { return }
        removeOverlayHelloDeadline(for: peer.key, session: peer.sessionID)
        overlayState.overlayRecords.update(session: peer) { record in
            if case .awaitingHello? = record.session { record.session = nil }
        }
        await overlay.recycleSession(ifCurrent: peer)
    }

    /// Records `peer`'s tip claim, then asks the OLDEST unasked claimant
    /// (`askForMissingAncestry`) if blocks here park on missing ancestry.
    /// Every claim is recorded, whether or not its block is held, so a claim
    /// that meets a busy range-sync slot is asked when the slot clears; the
    /// oldest goes first, so no session jumps the queue by reconnecting.
    func syncMissingAncestryIfNeeded(
        from peer: AuthenticatedPeer,
        peerHeight: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID
        else { return }
        overlayState.overlayRecords.update(session: peer) { record in
            if var claim = record.ancestryClaim, claim.sessionID == peer.sessionID {
                claim.height = max(claim.height, peerHeight)
                record.ancestryClaim = claim
            } else {
                record.ancestryClaim = AncestryClaim(
                    sessionID: peer.sessionID,
                    sequence: LifetimeToken.next().rawValue,
                    height: peerHeight,
                    asked: false
                )
            }
        }
        guard let oldest = unaskedAncestryClaimant else { return }
        await askForMissingAncestry(
            peer: oldest, generation: generation, process: process
        )
    }

    /// Once per session, when some held block parks on a predecessor this
    /// node lacks, run the ordinary range sync against a session that has
    /// claimed its tip: the ancestor negotiation finds our fork point on its
    /// main chain and the pages that follow arrive as seeds with this peer as
    /// provider, like any range sync's. A missing ancestor on that chain is
    /// fetched from the peer that claimed it; one that is not is left to the
    /// next session. An unresponsive peer is handled by the range sync's own
    /// response and progress timeouts. While another range sync holds the
    /// slot this does nothing; the claim stays unasked, and the slot's
    /// re-entry probe asks it when the slot clears.
    func askForMissingAncestry(
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard fetcherAwaitsMissingAncestry(),
              overlayState.rangeSync.state == nil,
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID,
              let claim = overlayState.overlayRecords[peer.key]?.ancestryClaim,
              claim.sessionID == peer.sessionID, !claim.asked
        else { return }
        syncTrace(
            "ancestry sync peer=\(peer.key.hex.prefix(8)) peerHeight=\(claim.height)"
        )
        // Marked asked the moment the slot is taken, before the ancestor
        // request suspends, so no second ask can slip in.
        await startRangeSync(
            peer: peer,
            targetHeight: claim.height,
            generation: generation,
            process: process
        ) {
            overlayState.overlayRecords.update(session: peer) {
                if $0.ancestryClaim?.sessionID == peer.sessionID {
                    $0.ancestryClaim?.asked = true
                }
            }
        }
    }

    /// The ready session with the OLDEST recorded tip claim not yet asked
    /// for missing ancestry, while blocks here park on it. First in, first
    /// asked: a reconnect's new claim queues behind every earlier one.
    var unaskedAncestryClaimant: AuthenticatedPeer? {
        guard fetcherAwaitsMissingAncestry() else { return nil }
        return overlayState.overlayRecords.records
            .compactMap { _, record -> (peer: AuthenticatedPeer, sequence: UInt64)? in
                guard let peer = record.readyPeer,
                      let claim = record.ancestryClaim,
                      claim.sessionID == peer.sessionID, !claim.asked else { return nil }
                return (peer, claim.sequence)
            }
            .min { $0.sequence < $1.sequence }?
            .peer
    }

    /// One-shot frontier pull, once per session, at the live edge. The tip
    /// announcement and main-chain range sync never carry losing forks, yet
    /// fork choice weighs subtrees; a peer's accepted LEAVES plus parent links
    /// determine its whole header graph, so one page per session is the
    /// entire discovery — each unknown leaf's predecessor walk reassembles
    /// its ancestry down to known history. That walk is short only when we
    /// already hold the peer's main chain up to the live edge: pulled while
    /// deep, every leaf would descend the whole gap top-down in competition
    /// with range sync (and the parks would evict the leaves themselves). So
    /// the pull waits for the moment `peerHeight` is within
    /// `RangeSync.depthThreshold` of our acquired tip — evaluated wherever
    /// that is decided: on the peer's announcements and when a range sync
    /// clears. No cursor: the live frontier is small under the losing-fork
    /// budget, and any remainder re-enters through announcements.
    func pullFrontierIfAtEdge(
        from peer: AuthenticatedPeer,
        peerHeight: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        // The edge is measured PER PEER — our acquired tip against THIS peer's
        // own height, the test below — so a range sync running for some other
        // peer says nothing about whether we are at the edge with this one.
        // While we are genuinely deep that same per-peer test suppresses the
        // pull anyway, which is what keeps a deep joiner from descending the
        // whole gap; keying on the single shared range-sync slot instead let
        // one peer's unverified height claim silence every OTHER peer's
        // frontier for as long as it held the slot.
        guard overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID,
              overlayState.overlayRecords[peer.key]?.frontierPull?.sessionID != peer.sessionID else { return }
        let ourHeight = await fetchedHeight(process)
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID,
              overlayState.overlayRecords[peer.key]?.frontierPull?.sessionID != peer.sessionID,
              peerHeight <= ourHeight + RangeSync.depthThreshold else { return }
        let requestID = makeRequestID()
        guard let payload = try? AcceptedLeavesRequestMessage(
            requestID: requestID,
            afterCID: nil
        ).encoded() else { return }
        overlayState.overlayRecords.update(session: peer) {
            $0.frontierPull = FrontierPull(
                sessionID: peer.sessionID,
                requestID: requestID
            )
        }
        syncTrace(
            "frontier pull peer=\(peer.key.hex.prefix(8)) "
                + "peerHeight=\(peerHeight) ours=\(ourHeight)"
        )
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.acceptedLeavesRequest,
            payload: payload
        )
    }

    func discardServingSessions(of session: AuthenticatedPeer?) {
        if let session {
            sessionLeases.discardServing(session.sessionID)
        }
    }

    /// The provider's session when it is still the key's ready session.
    func overlayPeer(
        for provider: CandidateProvider
    ) -> AuthenticatedPeer? {
        guard let key = try? PeerKey(provider.publicKey),
              let peer = overlayState.overlayRecords[key]?.readyPeer,
              peer.sessionID == provider.sessionID else { return nil }
        return peer
    }

    /// Seam: the providers whose sessions are still ready, in order.
    func readyPeers(for providers: [CandidateProvider]) -> [AuthenticatedPeer] {
        providers.compactMap(overlayPeer(for:))
    }

    /// Seam: whether `peer` is still its key's ready overlay session.
    func isReadySession(_ peer: AuthenticatedPeer) -> Bool {
        overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID
    }

    /// Seam: whether the key holds a ready overlay session.
    func hasReadySession(_ key: PeerKey) -> Bool {
        overlayState.overlayRecords[key]?.readyPeer != nil
    }

    /// Drops the overlay requests a gone session can never answer. Each
    /// table is keyed by requestID; the peer is only a filter.
    func purgeOverlayRequests(for key: PeerKey) {
        let disconnectedInventories = overlayState.pendingTransactionInventories.filter {
            $0.value.peer.key == key
        }
        for pending in disconnectedInventories.values {
            pending.timeout.cancel()
        }
        overlayState.pendingTransactionInventories = overlayState.pendingTransactionInventories.filter {
            $0.value.peer.key != key
        }
        // A response can never arrive on a gone session (a reconnect gets
        // a fresh sessionID the response guard rejects), so resolve the
        // ask empty now instead of burning its timeout.
        let disconnectedReadEndpoints = overlayState.readURLDiscovery.removePendingReadEndpoints(of: key)
        for pending in disconnectedReadEndpoints.values {
            pending.timeout.cancel()
            pending.continuation.resume(returning: [])
        }
    }
}

// MARK: - Child-evidence index sync

extension NodeNetworkRuntime {
    /// Child blocks awaiting a proof lookup are bounded; a block refused
    /// here is wanted again at its next parked retry.
    static let maximumWantedChildEvidence = 256

    /// Tells one peer this node's current child-evidence root (on hello).
    func sendChildEvidenceRoot(
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus,
              let root = try? await process.childEvidenceRoot(),
              let payload = try? ChildEvidenceRootMessage(rootCID: root).encoded(),
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID
        else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childEvidenceRoot,
            payload: payload
        )
    }

    /// The root may have changed: push it to every ready peer if it did.
    /// Requests made while a push runs coalesce into one more push.
    func scheduleChildEvidenceRootAnnounce(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        overlayState.childEvidenceAnnounceDirty = true
        overlayState.childEvidenceAnnounce.start { token in
            Task { [weak self] in
                await self?.announceChildEvidenceRoot(
                    token: token,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    func announceChildEvidenceRoot(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer {
            if overlayState.childEvidenceAnnounce.clear(token),
               overlayState.childEvidenceAnnounceDirty {
                scheduleChildEvidenceRootAnnounce(
                    generation: generation,
                    process: process
                )
            }
        }
        while overlayState.childEvidenceAnnounce.holds(token),
              overlayState.childEvidenceAnnounceDirty {
            overlayState.childEvidenceAnnounceDirty = false
            guard let root = try? await process.childEvidenceRoot(),
                  overlayState.childEvidenceAnnounce.holds(token),
                  root != overlayState.announcedChildEvidenceRoot,
                  let payload = try? ChildEvidenceRootMessage(rootCID: root).encoded()
            else { continue }
            overlayState.announcedChildEvidenceRoot = root
            for peer in readyOverlayPeers {
                guard overlayState.childEvidenceAnnounce.holds(token) else { return }
                _ = await overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.childEvidenceRoot,
                    payload: payload
                )
            }
        }
    }

    /// Keeps a peer's latest root; a new one is walked against ours, and
    /// searched for the blocks still waiting on a proof.
    func receiveChildEvidenceRoot(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let root = PeerEvidenceRoot(sessionID: peer.sessionID, rootCID: rootCID)
        let lookup = !overlayState.wantedChildEvidence.isEmpty
        let changed = overlayState.overlayRecords.update(session: peer) { record in
            guard record.evidenceRoot != root else { return false }
            record.evidenceRoot = root
            record.evidenceWalkDirty = true
            record.evidenceLookupDirty = record.evidenceLookupDirty || lookup
            return true
        } ?? false
        guard changed else { return }
        startChildEvidenceSync(generation: generation, process: process)
    }

    /// A block needs a proof this node lacks: look it up in the latest roots
    /// of up to `maximumExactContentSources` ready peers now, and in every
    /// root that changes until it is found.
    func wantChildEvidence(
        _ childCID: String,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        if !overlayState.wantedChildEvidence.contains(childCID) {
            guard overlayState.wantedChildEvidence.count
                    < Self.maximumWantedChildEvidence else {
                syncTrace("child-evidence want-overflow \(childCID)")
                return
            }
            overlayState.wantedChildEvidence.insert(childCID)
        }
        let peers = overlayState.overlayRecords.records
            .filter { $0.value.readyPeer != nil && $0.value.evidenceRoot != nil }
            .keys
            .shuffled()
            .prefix(Self.maximumExactContentSources)
        for key in peers {
            overlayState.overlayRecords.updateExisting(key) {
                $0.evidenceLookupDirty = true
            }
        }
        startChildEvidenceSync(generation: generation, process: process)
    }

    private func startChildEvidenceSync(
        generation: UInt64,
        process: ChainProcess
    ) {
        overlayState.childEvidenceSync.start { token in
            Task { [weak self] in
                await self?.runChildEvidenceSync(
                    token: token,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    /// The one serial worker: one peer root at a time, so its fetches are
    /// bounded by construction.
    func runChildEvidenceSync(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer {
            if overlayState.childEvidenceSync.clear(token),
               nextChildEvidencePeer() != nil,
               isCurrentRuntime(generation: generation, process: process) {
                startChildEvidenceSync(generation: generation, process: process)
            }
        }
        while overlayState.childEvidenceSync.holds(token),
              isCurrentRuntime(generation: generation, process: process),
              let key = nextChildEvidencePeer() {
            guard let (lookup, walk, root) = overlayState.overlayRecords
                .updateExisting(key, { record in
                    defer {
                        record.evidenceLookupDirty = false
                        record.evidenceWalkDirty = false
                    }
                    return (
                        record.evidenceLookupDirty,
                        record.evidenceWalkDirty,
                        record.evidenceRoot
                    )
                }),
                  let record = root,
                  let peer = overlayState.overlayRecords[key]?.readyPeer,
                  peer.sessionID == record.sessionID else { continue }
            await syncChildEvidence(
                from: peer,
                rootCID: record.rootCID,
                lookup: lookup,
                walk: walk,
                generation: generation,
                process: process
            )
        }
    }

    /// The next peer, in key order, with a root still to be walked or
    /// searched.
    private func nextChildEvidencePeer() -> PeerKey? {
        overlayState.overlayRecords.records
            .filter { $0.value.evidenceWalkDirty || $0.value.evidenceLookupDirty }
            .keys
            .min(by: { $0.hex < $1.hex })
    }

    /// Fetches, from one peer's root, the proofs this node lacks for the
    /// blocks it wants (`lookup`) and for the blocks its own index holds
    /// (`walk`), through one budgeted session bound to that peer. Every
    /// verified proof is a package seed; a failure is blamed on the sole
    /// supplier of a complete fetch, whose root is then dropped.
    private func syncChildEvidence(
        from peer: AuthenticatedPeer,
        rootCID: String,
        lookup: Bool,
        walk: Bool,
        generation: UInt64,
        process: ChainProcess
    ) async {
        var wanted: [String] = []
        if lookup {
            for childCID in overlayState.wantedChildEvidence.sorted()
                .prefix(Self.maximumEvidenceCandidates) {
                if await process.hasAcceptedBlock(childCID) {
                    overlayState.wantedChildEvidence.remove(childCID)
                } else {
                    wanted.append(childCID)
                }
            }
        }
        let localRoot = walk ? (try? await process.childEvidenceRoot()) ?? nil : nil
        guard !wanted.isEmpty || (localRoot != nil && localRoot != rootCID),
              isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let source = IvyRootContentSource(
            ivy: overlay,
            peer: peer,
            policy: configuration.resourcePolicy
        )
        let local = process.childEvidenceFetcher
        let wantedKeys = wanted
        let maximumEncodedSize = configuration.resourcePolicy.maximumParentWitnessBytes
        let result = await source.withRootTracing(rootCID) { session in
            await ChildEvidenceIndex.collect(
                peerRoot: rootCID,
                localRoot: localRoot,
                wanted: wantedKeys,
                peer: CoalescingFetcher(session),
                local: local,
                maximumEncodedSize: maximumEncodedSize,
                weighs: { proof, childCID in
                    await process.childEvidenceWeighs(proof, childCID: childCID)
                }
            )
        }
        let collected = result.value
        syncTrace(
            "child-evidence sync peer=\(peer.key.hex.prefix(8)) "
                + "root=\(rootCID.prefix(12)) wanted=\(wanted.count) "
                + "found=\(collected.verified.count) failed=\(collected.failed)"
        )
        let blamed = Self.childEvidenceBlame(
            failed: collected.failed && !collected.localFailure,
            complete: result.attribution.allResponsesComplete,
            soleSupplier: result.attribution.soleRemoteSupplierPublicKey
        )
        if let blamed {
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: PeerID(publicKey: blamed)
            )
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID
                == peer.sessionID else {
            return
        }
        for (entry, package) in collected.verified {
            // A rejected enqueue is local congestion, not the peer's fault:
            // the block stays wanted and is looked up again.
            if enqueueCandidate(CandidateSeed(
                blockCID: entry.childCID,
                package: AuthenticatedChildPackage(package: package),
                weighed: true
            ), generation: generation) {
                overlayState.wantedChildEvidence.remove(entry.childCID)
            }
        }
        if blamed != nil {
            overlayState.overlayRecords.update(session: peer) {
                $0.evidenceRoot = nil
            }
            await overlay.recycleSession(ifCurrent: peer)
        } else if collected.failed, !collected.verified.isEmpty {
            // The session's budget ran out mid-pass: the roots still differ,
            // so the rest is fetched on another pass.
            overlayState.overlayRecords.update(session: peer) {
                $0.evidenceWalkDirty = true
                $0.evidenceLookupDirty = $0.evidenceLookupDirty || lookup
            }
        }
    }

    /// Blame follows the bytes alone: a pass that failed is its sole
    /// supplier's fault when every response was complete, and never
    /// otherwise; a pass that verified is never blamed.
    nonisolated static func childEvidenceBlame(
        failed: Bool,
        complete: Bool,
        soleSupplier: String?
    ) -> String? {
        failed && complete ? soleSupplier : nil
    }
}
