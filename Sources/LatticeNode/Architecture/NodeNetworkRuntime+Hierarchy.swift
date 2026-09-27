import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    /// The miner's plan for this chain's descendants, as last supplied with a
    /// template request. Children build their candidates against it, so a
    /// change is pushed to them like a tip change.
    public func updateDescendantPlan(
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork]
    ) async {
        guard isRunning, let process else { return }
        descendantRewards = rewards
        descendantMinimumWork = minimumWork
        scheduleParentTipPush(generation: runtimeGeneration, process: process)
    }

    /// Something a template or a child candidate is a function of changed
    /// here: the validated tip, the mempool, a credit. As a parent, re-push
    /// the context to children if it differs; as a child, rebuild and push
    /// our candidate. Both are coalescing tasks: this call costs a flag, and
    /// the tip is re-read once per task run, not once per event.
    public func chainStateChanged() async {
        guard isRunning, let process else { return }
        let generation = runtimeGeneration
        scheduleParentTipPush(generation: generation, process: process)
        scheduleCandidateOffer(generation: generation, process: process)
    }

    /// The candidates a template built on the given parent state can carry,
    /// one line per directory as `directory:candidateCID` (several peers,
    /// several CIDs), sorted — an input to the template digest a miner
    /// compares to learn its work is stale. A held candidate for another
    /// parent state is not carried, so it is not an input.
    public func childCandidateDigestInput(parentStateCID: String) -> [String] {
        var byDirectory: [String: [String]] = [:]
        for (key, role) in hierarchyRoles {
            guard case .child(let path) = role, let directory = path.last,
                  isChildEvidenceReady(key),
                  let offer = hierarchyRecords[key]?.offer,
                  offer.candidate.block.parentState.rawCID == parentStateCID,
                  offer.childCID != parentTipContext?.carriedChildren[directory]
            else { continue }
            byDirectory[directory, default: []].append(offer.childCID)
        }
        return byDirectory.keys.sorted().map {
            "\($0):\(byDirectory[$0]!.sorted().joined(separator: ","))"
        }
    }

    /// The child candidates held for one exact provisional carrier: each
    /// ready child peer's latest pushed candidate, if it was built for this
    /// chain's current tip (its `parentState` is the carrier's `prevState`).
    /// Nothing is requested here; a child that has not pushed yet, or whose
    /// candidate is for an older tip, is simply not carried this round.
    public func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async -> [DirectChildCandidate] {
        guard isRunning, let process else { return [] }
        let wantedParentState = context.parentCarrier.prevState.rawCID
        let children = selectedChildPeers().filter {
            guard let directory = $0.2.last else { return false }
            return !context.excludedDirectories.contains(directory)
        }
        // What the template's own tip carries, and what the pushed context
        // names: the push task re-mints only after the tip validates, and a
        // template built in that window on a children-only carrier (same
        // post-state) would otherwise carry the block the tip just carried
        // once more; a template on an older tip is still not worth a block
        // the current branch already carries.
        var carriedChildren = parentTipContext?.carriedChildren ?? [:]
        if let tipCID = context.parentCarrier.parent?.rawCID {
            let onTip = await process.carriedChildBlocks(
                on: tipCID,
                directories: children.compactMap { $0.2.last }
            )
            carriedChildren.merge(onTip) { _, tip in tip }
        }
        let carriedOnContext = parentTipContext?.carriedChildren ?? [:]
        var candidates: [(Int, DirectChildCandidate)] = []
        var stale = 0
        var carried = 0
        for (rank, key, path) in children {
            guard let offer = hierarchyRecords[key]?.offer else { continue }
            guard offer.candidate.block.parentState.rawCID == wantedParentState
            else {
                stale += 1
                continue
            }
            // The block this chain's branch already carries for the
            // directory: a children-only carrier leaves the post-state, so
            // the offer still fits the tip, and carrying it again would
            // only credit the same block once more.
            if let directory = path.last,
               offer.childCID == carriedChildren[directory]
                || offer.childCID == carriedOnContext[directory] {
                carried += 1
                continue
            }
            candidates.append((rank, offer.candidate))
        }
        SyncTrace.log("child candidates: \(candidates.count) held of \(children.count) ready child peers (stale=\(stale) carried=\(carried)) excluded=\(context.excludedDirectories.sorted())")
        // A path claim is not authority. Several authenticated claimants may
        // serve one directory; rotate priority so a grindable lexicographic
        // key cannot own a slot.
        var selectedDirectories: Set<String> = []
        let selected = candidates.sorted { $0.0 < $1.0 }.compactMap {
            selectedDirectories.insert($0.1.directory).inserted ? $0.1 : nil
        }
        return selected.sorted { $0.directory < $1.directory }
    }

    /// A per-session sequence as it stands for the peer's current session;
    /// nil when it was read on an earlier session.
    private func sequence(_ recorded: SessionSequence?, on peer: AuthenticatedPeer) -> UInt64? {
        guard let recorded, recorded.sessionID == peer.sessionID else { return nil }
        return recorded.sequence
    }

    /// Re-reads this chain's validated tip and, if the context children build
    /// against changed (tip, rewards, minimum work), mints the next one for
    /// the push task to send. Only the push task calls this, so two reads
    /// never race to label an older tip with the newer sequence.
    private func refreshParentTipContext(
        process: ChainProcess,
        generation: UInt64
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let hasChildren = hierarchyRoles.map(\.value).contains {
            if case .child = $0 { return true }
            return false
        }
        guard hasChildren || parentTipContext != nil else { return }
        let rewards = descendantRewards
        let minimumWork = descendantMinimumWork
        // Cheap first: the validated tip's CID without resolving the block.
        // A walk step publishes a state change per block, and this must
        // not cost the process gate three times per step when nothing the
        // children build against changed.
        let directories = Set(hierarchyRoles.map(\.value).compactMap { role -> String? in
            guard case .child(let path) = role else { return nil }
            return path.last
        })
        if let current = parentTipContext,
           let cheapTip = await process.deepestValidatedMainChainTip()?.cid,
           cheapTip == current.tipCID,
           current.directories == directories,
           Self.sameRewardPlan(current.rewards, rewards),
           current.minimumWork == minimumWork {
            return
        }
        guard let tip = try? await process.validatedTipBlock(),
              let tipCID = try? BlockHeader(node: tip).rawCID,
              let tipData = tip.toData(),
              isCurrentRuntime(generation: generation, process: process)
        else { return }
        if let current = parentTipContext,
           current.tipCID == tipCID,
           current.directories == directories,
           Self.sameRewardPlan(current.rewards, rewards),
           current.minimumWork == minimumWork {
            return
        }
        let carriedChildren = await process.carriedChildBlocks(
            on: tipCID, directories: directories.sorted()
        )
        guard isCurrentRuntime(generation: generation, process: process) else { return }
        nextParentTipSequence &+= 1
        let context = ParentTipContext(
            sequence: nextParentTipSequence,
            tipCID: tipCID,
            tipData: tipData,
            rewards: rewards,
            minimumWork: minimumWork,
            carriedChildren: carriedChildren,
            directories: directories
        )
        parentTipContext = context
        SyncTrace.log("parent tip context \(context.sequence): h=\(tip.height) tip=\(tipCID.prefix(12)) carried=\(carriedChildren.keys.sorted())")
    }

    /// Pushes the latest context to every ready child. Coalescing, like the
    /// child's offer task: a burst of blocks marks it dirty once and the task
    /// pushes the context that stands when it runs. No pause between runs:
    /// a child's candidate is stale the moment this chain's tip moves, so
    /// every delay here is a round in which the child is not carried.
    private func scheduleParentTipPush(
        generation: UInt64,
        process: ChainProcess
    ) {
        parentTipPushDirty = true
        guard parentTipPushTask == nil else { return }
        parentTipPushTask = Task { [weak self] in
            await self?.runParentTipPushes(
                generation: generation,
                process: process
            )
        }
    }

    private func runParentTipPushes(
        generation: UInt64,
        process: ChainProcess
    ) async {
        // A run cancelled by a stop that a restart followed must not clear
        // the restart's handle.
        defer { if runtimeGeneration == generation { parentTipPushTask = nil } }
        while parentTipPushDirty, !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process) {
            parentTipPushDirty = false
            await resendRefusedChildEvidenceHints(
                generation: generation, process: process
            )
            await refreshParentTipContext(process: process, generation: generation)
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process),
                  let context = parentTipContext else { return }
            for (key, role) in hierarchyRoles {
                guard case .child(let childPath) = role,
                      isChildEvidenceReady(key),
                      let peer = hierarchyRecords[key]?.session,
                      sequence(hierarchyRecords[key]?.pushedSequence, on: peer) != context.sequence
                else { continue }
                await pushParentTipContext(context, to: peer, childPath: childPath)
            }
        }
    }

    private func resendRefusedChildEvidenceHints(
        generation: UInt64,
        process: ChainProcess
    ) async {
        for (key, payload) in recordedRefusedHints {
            guard isCurrentRuntime(generation: generation, process: process),
                  let peer = hierarchyRecords[key]?.session,
                  isChildEvidenceReady(key) else { continue }
            let sent = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            if case .enqueued = sent,
               hierarchyRecords[key]?.refusedHint == payload {
                hierarchyRecords.update(key) { $0.refusedHint = nil }
                SyncTrace.log("child evidence announcement re-sent to \(key.hex.prefix(12))")
            }
        }
    }

    private static func sameRewardPlan(
        _ lhs: [MiningReward], _ rhs: [MiningReward]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.chainPath == b.chainPath,
                  a.transaction.body.rawCID == b.transaction.body.rawCID,
                  a.transaction.signatures == b.transaction.signatures
            else { return false }
        }
        return true
    }

    private func pushParentTipContext(
        _ context: ParentTipContext,
        to peer: AuthenticatedPeer,
        childPath: [String]
    ) async {
        guard let process else { return }
        let rewards = context.rewards.filter {
            $0.chainPath.count >= childPath.count
                && Array($0.chainPath.prefix(childPath.count)) == childPath
        }
        let minimumWork = context.minimumWork.filter {
            $0.chainPath.count >= childPath.count
                && Array($0.chainPath.prefix(childPath.count)) == childPath
        }
        guard let resolvedRewards = await resolvedMiningRewards(
            rewards, process: process, generation: runtimeGeneration
        ), let payload = try? ParentTipContextMessage(
            sequence: context.sequence,
            childPath: childPath,
            tipCID: context.tipCID,
            tipData: context.tipData,
            rewards: resolvedRewards,
            minimumWork: minimumWork,
            carriedChildCID: childPath.last.flatMap { context.carriedChildren[$0] }
        ).encoded() else {
            SyncTrace.log("parent tip push to \(childPath.joined(separator: "/")) not built")
            return
        }
        let sent = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.parentTipAvailable,
            payload: payload
        )
        if case .enqueued = sent {
            hierarchyRecords.update(peer.key) {
                $0.pushedSequence = SessionSequence(
                    sessionID: peer.sessionID, sequence: context.sequence
                )
            }
        } else {
            SyncTrace.log("parent tip push to \(childPath.joined(separator: "/")) not sent: \(sent)")
        }
    }

    /// Rebuild this chain's candidate for its parent and push it. Coalescing:
    /// a change during a build marks the task dirty and it runs once more,
    /// with the inputs that stand then, and no pause: a candidate the parent
    /// already left behind is not carried, so the rebuild is the only way
    /// into the next carrier.
    func scheduleCandidateOffer(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard receivedParentTip != nil,
              chain?.networkCapabilities.contains(.childCandidates) == true
        else { return }
        candidateOfferDirty = true
        guard candidateOfferTask == nil else { return }
        candidateOfferTask = Task { [weak self] in
            await self?.runCandidateOffers(
                generation: generation,
                process: process
            )
        }
    }

    private func runCandidateOffers(
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { if runtimeGeneration == generation { candidateOfferTask = nil } }
        while candidateOfferDirty, !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process) {
            candidateOfferDirty = false
            await offerCandidate(generation: generation, process: process)
        }
    }

    private func offerCandidate(
        generation: UInt64,
        process: ChainProcess
    ) async {
        // Nothing to offer before this chain's genesis is active; the next
        // state change (activation commits) offers.
        guard await process.status().phase == .active else { return }
        // The block the parent's branch carries for this chain, as its
        // context names it, that this chain has not admitted: a candidate
        // built now would only be its sibling. Hold until the admission
        // decides: an acceptance publishes a state change, and a decision
        // against the block, or a scan round that ends without it, releases
        // the hold (`releasedCarriedChildCID`), so no offer waits on a block
        // that will never land.
        if let carried = receivedParentTip?.carriedChildCID,
           carried != releasedCarriedChildCID,
           !(await process.hasAcceptedBlock(carried)) {
            candidateOfferDeferredByAdmission = true
            carriedHoldCount += 1
            SyncTrace.log("candidate offer deferred: carried \(carried.prefix(12)) not yet admitted")
            return
        }
        // A candidate this chain built that the parent's evidence names as
        // carried and still holds in the inbox (undecided), now ready for
        // or in its admission: the carried block is about to be this
        // chain's weighed tip, and a candidate built now, on the tip before
        // it, would only be its sibling. The inbox is written only from the
        // configured parent's evidence, so no overlay peer can populate
        // this set; an announcement can at most re-ready an inbox entry's
        // own attempt. Offer once the admission decides or parks; the
        // drain re-arms the offer either way.
        if let pending = try? await process.store.pendingHandoffChildCIDs(),
           pending.contains(where: { blockFetcher.isAwaitingAdmission($0) }) {
            candidateOfferDeferredByAdmission = true
            SyncTrace.log("candidate offer deferred: own carried candidate awaiting admission")
            return
        }
        // The gate is open: a deferral the drain never got to read (its
        // attempt left the fetcher without an admission) is moot now.
        candidateOfferDeferredByAdmission = false
        guard let context = receivedParentTip,
              hierarchyRecords[context.peer.key]?.session?.sessionID
                == context.peer.sessionID,
              hierarchyRecords[context.peer.key]?.role == .parent,
              let chain,
              chain.networkCapabilities.contains(.childCandidates),
              let carrier = Self.provisionalCarrier(
                on: context.tip,
                tipCID: context.tipCID
              ) else { return }
        let parentSource = IvyRootContentSource(
            ivy: hierarchy,
            peer: context.peer,
            policy: configuration.resourcePolicy
        )
        let deadline = ContinuousClock.now
            + planeConfigurations.hierarchy.requestTimeout
        let built: DirectChildCandidate?
        do {
            built = try await parentSource.withRoot(
                context.tipCID,
                operation: { session in
                    try await ChildCandidateBudget.$deadline.withValue(deadline) {
                        try await chain.miningCandidate(
                            for: ChildCandidateRequestContext(
                                parentCarrier: carrier,
                                rewards: context.rewards,
                                minimumWork: context.minimumWork
                            ),
                            parentContentSource: session
                        )
                    }
                }
            )
        } catch {
            SyncTrace.log("candidate offer build failed: \(error)")
            return
        }
        guard let candidate = built,
              isCurrentRuntime(generation: generation, process: process),
              hierarchyRecords[context.peer.key]?.session?.sessionID
                == context.peer.sessionID,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID
        else { return }
        // The same candidate again says nothing new to the parent.
        if childCID == lastOfferedCandidateCID { return }
        nextCandidateOfferSequence &+= 1
        guard let payload = try? ChildCandidateAvailableMessage(
            sequence: nextCandidateOfferSequence,
            childPath: configuration.chainPath,
            childCID: childCID,
            blockData: blockData,
            searchWitness: candidate.searchWitness
        ).encoded() else { return }
        let sent = await hierarchy.sendMessage(
            to: context.peer,
            topic: NodeNetworkTopic.childCandidateAvailable,
            payload: payload
        )
        if case .enqueued = sent {
            lastOfferedCandidateCID = childCID
            SyncTrace.log("candidate offered \(nextCandidateOfferSequence): h=\(candidate.block.height) for tip=\(context.tipCID.prefix(12))")
        } else {
            // Not sent: the next change rebuilds and tries again; the
            // last-offered mark is untouched so the retry is not deduplicated.
            SyncTrace.log("candidate offer not sent: \(sent)")
        }
    }

    /// The carrier a child builds against without a parent template: a block
    /// on the parent's tip whose `prevState` is the tip's post-state — the
    /// one field the builder takes from a carrier — stamped now. Every real
    /// carrier the parent later mines on that tip has the same `prevState`,
    /// so the candidate fits any of them.
    private static func provisionalCarrier(
        on tip: Block,
        tipCID: String
    ) -> Block? {
        guard let emptyTransactions = try? HeaderImpl<
                  MerkleDictionaryImpl<VolumeImpl<Transaction>>
              >(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
              let emptyChildren = try? HeaderImpl<ChildIndex>(node: ChildIndex()),
              tip.height < UInt64.max else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return Block(
            version: tip.version,
            parent: VolumeImpl<Block>(rawCID: tipCID),
            transactions: emptyTransactions,
            target: tip.nextTarget,
            nextTarget: tip.nextTarget,
            spec: tip.spec,
            parentState: tip.parentState,
            prevState: tip.postState.removingNode(),
            postState: tip.postState.removingNode(),
            children: emptyChildren,
            height: tip.height + 1,
            timestamp: max(now, tip.timestamp + 1),
            nonce: 0
        )
    }

    func parentEvidenceSession(
        for peer: AuthenticatedPeer
    ) -> ParentEvidenceSession? {
        guard hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyRecords[peer.key]?.role == .parent else { return nil }
        return ParentEvidenceSession(
            peerID: peer.key.hex,
            sessionID: peer.sessionID
        )
    }

    /// Outcome of scheduling a batch of parent-announced evidence. LOCAL
    /// backpressure is deliberately distinct from rejection: recycling the
    /// authenticated parent link because THIS node's evidence lane is busy
    /// severs the only eager delivery path and caps recovery at one scan per
    /// reconnect — the announcement is droppable (the durable index re-serves
    /// it), the session is not.
    private enum ParentEvidenceAppend {
        case scheduled(Task<ParentEvidenceResult, Never>)
        case backpressured
        case rejected
    }

    private func appendParentEvidence(
        _ summaries: [IssuedChildEvidenceSummary],
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> ParentEvidenceAppend {
        guard !summaries.isEmpty else { return .backpressured }
        guard isCurrentRuntime(generation: generation, process: process),
              let session = parentEvidenceSession(for: peer) else {
            return .rejected
        }
        let activePortable = sessionLeases.activeEvidenceVolumes.lazy.filter {
            $0.plane == .overlay
        }.count
        guard let append = parentEvidence.beginAppend(
            for: session,
            competingOperationCount: sessionLeases.portableEvidenceWork.count
                + activePortable,
            capacity: Self.maximumEvidenceCandidates
        ) else { return .backpressured }
        let task = Task { [weak self] in
            guard let self else { return ParentEvidenceResult.failed }
            var result = if let predecessor = append.predecessor {
                await predecessor.value
            } else {
                ParentEvidenceResult.handled
            }
            if Task.isCancelled { result = .failed }
            for summary in summaries where result == .handled {
                result = await self.recoverParentEvidence(
                    summary,
                    sourceID: sourceID,
                    advanceScan: advanceScan,
                    from: peer,
                    generation: generation,
                    process: process
                )
            }
            await self.finishParentEvidence(
                session: session,
                token: append.token,
                result: result,
                peer: peer,
                generation: generation,
                process: process
            )
            return result
        }
        parentEvidence.install(
            task,
            token: append.token,
            for: session
        )
        return .scheduled(task)
    }

    private func finishParentEvidence(
        session: ParentEvidenceSession,
        token: UInt64,
        result: ParentEvidenceResult,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let shouldRecycle = parentEvidence.finish(
            token: token,
            result: result,
            for: session
        )
        guard parentEvidenceSession(for: peer) == session else { return }
        if shouldRecycle {
            await hierarchy.recycleSession(ifCurrent: peer)
        }
    }

    private func cancelParentEvidence(for key: PeerKey) {
        parentEvidence.cancel(peerID: key.hex)
    }

    private func waitForChildEvidenceReady(
        peer: AuthenticatedPeer
    ) async -> Bool {
        guard !isChildEvidenceReady(peer.key) else { return true }
        return await withCheckedContinuation { continuation in
            hierarchyRecords.update(peer.key) {
                $0.evidence.waiters.append(
                    ChildEvidenceReadyWaiter(
                        sessionID: peer.sessionID,
                        continuation: continuation
                    )
                )
            }
        }
    }

    private func markChildEvidenceReady(_ peer: AuthenticatedPeer) {
        guard hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
            return
        }
        let waiters = hierarchyRecords.update(peer.key) {
            record -> [ChildEvidenceReadyWaiter] in
            record.evidence.ready = true
            let waiters = record.evidence.waiters
            record.evidence.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(
                returning: waiter.sessionID == peer.sessionID
            )
        }
    }

    private func cancelChildEvidenceReadyWaiters(for peerKey: PeerKey) {
        let waiters = hierarchyRecords.update(peerKey) {
            record -> [ChildEvidenceReadyWaiter] in
            record.evidence.clearFences()
            let waiters = record.evidence.waiters
            record.evidence.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    func canServeHierarchyContent(to peer: AuthenticatedPeer) -> Bool {
        runtimeGeneration != 0
            && hierarchyRecords[peer.key]?.role != nil
            && hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
    }

    /// Publishes an already-promoted absolute proof prepared durably by the
    /// process admission boundary.
    @discardableResult
    public func publishChildProof(
        _ proof: ChildBlockProof,
        childDirectory: String,
        childCID: String
    ) async throws -> ChildBlockProof {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        let childPath = configuration.chainPath + [childDirectory]
        guard _isBoundedWireAtom(childCID),
              proof.directoryPath == Array(childPath.dropFirst()),
              !childDirectory.isEmpty,
              (try? proof.serialize()) != nil,
              let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID
        else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard (try? await process.store.issuedChildEvidence(
            childCID: childCID,
            directory: childDirectory,
            rootCID: proof.rootCID
        )) != nil else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard
            await announceChildEvidenceAvailability(
                childPath: childPath,
                childCID: childCID,
                rootCID: proof.rootCID,
                generation: generation,
                process: process
            )
        else {
            throw NodeNetworkRuntimeError.notRunning
        }
        return proof
    }

    /// Tell authenticated direct children about evidence that has already been
    /// made durable. This closes the reconnect race where the child asks for
    /// its index just before the parent finishes preparing the proof.
    private func announceChildEvidenceAvailability(
        childPath: [String],
        childCID: String,
        rootCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return false
        }
        let bootstrappingPeers = hierarchyRoles.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  !isChildEvidenceReady(key) else { return nil }
            return hierarchyRecords[key]?.session
        }
        for peer in bootstrappingPeers {
            hierarchyRecords.update(peer.key) { record in
                let count = record.evidence.publicationsInFlight(
                    for: peer.sessionID
                ) ?? 0
                record.evidence.setPublicationsInFlight(
                    count + 1,
                    for: peer.sessionID
                )
            }
        }
        guard let directory = childPath.last,
            let evidence = try? await process.store.issuedChildEvidence(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            let indexed = try? await process.store.issuedChildEvidenceSummary(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            isCurrentRuntime(generation: generation, process: process),
            let payload = try? ChildEvidenceAvailableMessage(
                childPath: childPath,
                sourceID: indexed.sourceID,
                ordinal: indexed.summary.ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: evidence.attachmentCID
            ).encoded()
        else {
            for peer in bootstrappingPeers {
                finishChildEvidencePublication(
                    to: peer,
                    permitsCleanup: false
                )
                await hierarchy.recycleSession(ifCurrent: peer)
            }
            return false
        }
        let readyPeers = hierarchyRoles.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  isChildEvidenceReady(key) else { return nil }
            return hierarchyRecords[key]?.session
        }
        for peer in bootstrappingPeers + readyPeers {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
                if !isChildEvidenceReady(peer.key) {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                continue
            }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return false
            }
            let bootstrapping = !isChildEvidenceReady(peer.key)
            switch result {
            case .enqueued:
                // A newer hint delivered supersedes an older one refused:
                // the scan its admission triggers serves the older entry.
                hierarchyRecords.update(peer.key) { $0.refusedHint = nil }
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: true
                    )
                }
            case .notConnected:
                SyncTrace.log("child evidence announcement to \(childPath.joined(separator: "/")) not enqueued: \(result); recycling the session")
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                await hierarchy.recycleSession(ifCurrent: peer)
            case .backpressured, .locallyRejected:
                // This node's own send budget refused, not the child: the
                // announcement is a hint over a durable index, so a refusal
                // costs a retry, never the session. Recycling here made
                // every busy round a reconnect, and a child bootstrapping
                // through it never became ready. The hint is re-sent on the
                // next push run; a child scans the index only on a hello or
                // an admission, so a refused hint left alone strands the
                // entry until the next delivered one.
                SyncTrace.log("child evidence announcement to \(childPath.joined(separator: "/")) not enqueued: \(result); re-sent on the next push run")
                hierarchyRecords.update(peer.key) { $0.refusedHint = payload }
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: true
                    )
                }
            }
        }
        return isCurrentRuntime(generation: generation, process: process)
    }

    private func finishChildEvidencePublication(
        to peer: AuthenticatedPeer,
        permitsCleanup: Bool
    ) {
        let sessionID = peer.sessionID
        guard let count = hierarchyRecords[peer.key]?.evidence
            .publicationsInFlight(for: sessionID) else {
            return
        }
        if !permitsCleanup {
            SyncTrace.log("child evidence publication to \(peer.key.hex.prefix(8)) failed: session no longer becomes ready")
            hierarchyRecords.update(peer.key) {
                $0.evidence.markPublicationFailed(for: sessionID)
            }
        }
        if count == 1 {
            hierarchyRecords.update(peer.key) {
                $0.evidence.setPublicationsInFlight(0, for: sessionID)
            }
            if permitsCleanup,
               hierarchyRecords[peer.key]?.evidence
                .publicationFailed(for: sessionID) != true,
               hierarchyRecords[peer.key]?.evidence
                .indexComplete(for: sessionID) == true,
               hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID {
                markChildEvidenceReady(peer)
            }
        } else {
            hierarchyRecords.update(peer.key) {
                $0.evidence.setPublicationsInFlight(count - 1, for: sessionID)
            }
        }
    }

    private func completeChildEvidenceIndex(for peer: AuthenticatedPeer) {
        // Only the live session's fence: this runs after the index serve's
        // suspensions, and a fence for an ended session could never be
        // read again (nor could it mark anything ready).
        guard hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
            return
        }
        let sessionID = peer.sessionID
        hierarchyRecords.update(peer.key) {
            $0.evidence.markIndexComplete(for: sessionID)
        }
        if hierarchyRecords[peer.key]?.evidence
            .publicationsInFlight(for: sessionID) == nil,
           hierarchyRecords[peer.key]?.evidence
            .publicationFailed(for: sessionID) != true {
            markChildEvidenceReady(peer)
        }
    }

    /// A direct child pulls its bounded index once on authentication. If that
    /// pull races durable proof preparation, re-advertise only evidence for
    /// this local carrier in its authenticated root context(s).
    func announceCurrentCarrierChildEvidence(
        directories: [String],
        carrierCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        let directories = Set(directories)
        var afterRootCID: String?
        var announcements = 0
        var rootsExamined = 0
        while announcements < Self.maximumReconnectEvidenceAnnouncements,
            rootsExamined < Self.maximumReconnectCarrierRoots
        {
            let remainingRoots = Self.maximumReconnectCarrierRoots - rootsExamined
            guard
                let roots = try? await process.parentCarrierRootPage(
                    carrierCID: carrierCID,
                    afterRootCID: afterRootCID,
                    limit: remainingRoots
                )
            else {
                return isCurrentRuntime(generation: generation, process: process)
            }
            guard !roots.isEmpty else { break }
            rootsExamined += roots.count
            for rootCID in roots {
                guard
                    let proofs = try? await process.durableDirectChildProofs(
                        carrierCID: carrierCID,
                        rootCID: rootCID,
                        directories: directories
                    )
                else { continue }
                for proof in proofs {
                    guard
                        await announceChildEvidenceAvailability(
                            childPath: configuration.chainPath + [proof.directory],
                            childCID: proof.childCID,
                            rootCID: proof.proof.rootCID,
                            generation: generation,
                            process: process
                        )
                    else { return false }
                    announcements += 1
                    if announcements == Self.maximumReconnectEvidenceAnnouncements {
                        return isCurrentRuntime(
                            generation: generation,
                            process: process
                        )
        }
                }
            }
            afterRootCID = roots.last
            guard roots.count == remainingRoots else { break }
        }
        return isCurrentRuntime(generation: generation, process: process)
    }

    @discardableResult
    func clearHierarchyAuthorization(for key: PeerKey) -> HierarchyPeer? {
        let removed = hierarchyRecords.remove(key)
        removed?.helloDeadline?.task.cancel()
        cancelParentEvidence(for: key)
        for waiter in removed?.evidence.waiters ?? [] {
            waiter.continuation.resume(returning: false)
        }
        let removedRole = removed?.role
        Self.pruneChildPeerRotations(
            &childPeerRotation,
            activeRoles: hierarchyRoles.map(\.value)
        )
        if case .child(let path)? = removedRole, let directory = path.last,
           !hierarchyRoles.map(\.value).contains(where: { role in
               guard case .child(let other) = role else { return false }
               return other.last == directory
           }) {
            // Last peer for this directory left: let a reconnecting child
            // re-run the late-child backfill for carriers admitted while it was
            // gone (those got no admission-time route seeded for it).
            backfilledChildDirectories.remove(directory)
        }
        if case .parent? = removedRole {
            purgeRequests(for: key, plane: .hierarchy)
        }
        if receivedParentTip?.peer.key == key {
            receivedParentTip = nil
            releasedCarriedChildCID = nil
            requestedCarriedChildCID = nil
            lastOfferedCandidateCID = nil
        }
        return removedRole
    }

    private func scheduleParentEvidencePage(
        _ response: ChildEvidenceIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        let tail: Task<ParentEvidenceResult, Never>?
        if response.entries.isEmpty {
            tail = nil
        } else {
            switch appendParentEvidence(
                response.entries,
                sourceID: response.sourceID,
                advanceScan: true,
                from: peer,
                generation: generation,
                process: process
            ) {
            case .scheduled(let appended):
                tail = appended
            case .backpressured:
                // The evidence lane is momentarily full. Keep the session and
                // retry THIS page after a beat — the scan must make progress
                // through congestion, not restart from a fresh reconnect.
                Timers.deadline(
                    after: planeConfigurations.hierarchy.requestTimeout,
                    generation: generation
                ) { [weak self] generation in
                    await self?.requestEvidenceIndex(
                        sourceID: response.sourceID,
                        cursor: response.cursor,
                        through: response.through,
                        generation: generation,
                        process: process
                    )
                }
                return
            case .rejected:
                Task { [hierarchy] in
                    await hierarchy.recycleSession(ifCurrent: peer)
                }
                return
            }
        }
        Task { [weak self] in
            guard let self else { return }
            guard (await tail?.value ?? .handled) == .handled else { return }
            // The scan cursor advances only through evidence this child has
            // durably retained (the per-item advanceScan path). The parent's
            // asserted `through` is never persisted directly: a lying parent
            // must not move the high-water mark past ordinals it never served.
            if response.next < response.through {
                await self.requestEvidenceIndex(
                    sourceID: response.sourceID,
                    cursor: response.next,
                    through: response.through,
                    generation: generation,
                    process: process
                )
            } else {
                // The round is complete — its evidence retained, its
                // candidates queued: ask for the runs of the committers this
                // chain already accepted blocks from (§9.10).
                await self.requestParentRunReports(
                    generation: generation, process: process
                )
                await self.reviewCarriedChildHold(
                    generation: generation, process: process
                )
            }
        }
    }

    /// After a scan round: the block the parent's context names as carried
    /// is either here, in the fetcher (its admission will decide), asked
    /// for now (the request this chain made while a round was in flight
    /// sent nothing), or, when a round sent for it ended without it, let
    /// go: the offer hold is released and the child builds on the tip it
    /// has, its own choice from here. No timer, no count: the scan's own
    /// round trip paces every step.
    private func reviewCarriedChildHold(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              let carried = receivedParentTip?.carriedChildCID,
              carried != releasedCarriedChildCID,
              !(await process.hasAcceptedBlock(carried)),
              !blockFetcher.tracks(carried) else { return }
        if requestedCarriedChildCID == carried {
            releasedCarriedChildCID = carried
            SyncTrace.log("carried \(carried.prefix(12)) not served by a scan round: offer hold released")
            scheduleCandidateOffer(generation: generation, process: process)
        } else if await requestEvidenceIndex(generation: generation, process: process) {
            requestedCarriedChildCID = carried
        }
    }

    private func recoverParentEvidence(
        _ summary: IssuedChildEvidenceSummary,
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> ParentEvidenceResult {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyRecords[peer.key]?.role == .parent else {
            return .failed
        }
        let lease = EvidenceVolumeLease(
            plane: .hierarchy,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if sessionLeases.activeEvidenceVolumes.contains(lease) { return .handled }
        // nil: a slot is free. The stale and lease checks also pass on the
        // first step: both were just made above with no suspension between.
        let slotWait: ParentEvidenceResult? = await Timers.poll(
            every: planeConfigurations.hierarchy.requestTimeout,
            onCancel: .handled
        ) {
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
               hierarchyRecords[peer.key]?.role == .parent else {
                return .done(.failed)
            }
            if sessionLeases.activeEvidenceVolumes.contains(lease) { return .done(.handled) }
            return sessionLeases.activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates
                ? .again
                : .done(nil)
        }
        if let slotWait { return slotWait }
        sessionLeases.activeEvidenceVolumes.insert(lease)
        defer { sessionLeases.activeEvidenceVolumes.remove(lease) }
        let source = IvyRootContentSource(
            ivy: hierarchy,
            peer: peer,
            maximumMembers: 1,
            maximumStorageBytes: ChildEvidenceVolume.maximumFramedBytes,
            maximumArchiveBytes: ChildEvidenceVolume.maximumArchiveBytes
        )
        let resolved: (
            value: ChildEvidenceVolume?,
            attribution: IvyRootContentSource.Attribution
        )
        switch await Timers.retryWhileCapacityUnavailable(
            every: planeConfigurations.hierarchy.requestTimeout,
            attempt: {
                await source.withRootTracing(
                    summary.attachmentCID,
                    operation: { session in
                        await Self.resolveEvidenceVolume(
                            summary.attachmentCID,
                            childCID: summary.childCID,
                            source: session
                        )
                    }
                )
            },
            capacityUnavailable: { $0.attribution.localCapacityUnavailable },
            stillCurrent: {
                isCurrentRuntime(generation: generation, process: process)
                    && hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
                    && hierarchyRecords[peer.key]?.role == .parent
            }
        ) {
        case .value(let fetched):
            resolved = fetched
        case .cancelled, .stale:
            return .failed
        }
        guard let attachment = resolved.value else {
            // Mirror the overlay gate: only a complete response that still
            // failed to resolve is malformed and worth recycling. A parent
            // momentarily unable to serve an advertised attachment is
            // retried on the next scan, without blame.
            return resolved.attribution.allResponsesComplete
                ? .failed
                : .unavailable
        }
        guard let envelope = try? ChildValidationPackageEnvelope.decode(
            attachment.envelopeBytes,
            maximumEncodedSize:
                configuration.resourcePolicy.maximumParentWitnessBytes
        ) else {
            return .failed
        }
        guard let package = try? envelope.makeValidationPackage() else {
            return .failed
        }
        let gated = AuthenticatedChildPackage(package: package)
        guard gated.package.proof.rootCID == summary.rootCID,
              let directHop = await gated.package.proof.directHop(),
              directHop.childCID == summary.childCID else {
            return .failed
        }
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyRecords[peer.key]?.role == .parent else {
            return .failed
        }
        let alreadyAdmitted: Bool
        do {
            alreadyAdmitted = try await process.retainParentEvidence(
                sourceID: sourceID,
                ordinal: summary.ordinal,
                attachment: attachment,
                package: gated,
                advanceScan: advanceScan
            )
        } catch NodeStoreError.parentEvidenceInboxFull {
            return .backpressured
        } catch {
            return .failed
        }
        // This carrier's evidence was admitted before: re-served by a scan
        // or a repeated hint, it credits nothing new, and an admission would
        // only be a duplicate through the one admission worker.
        if alreadyAdmitted {
            SyncTrace.log("parent evidence for \(summary.childCID.prefix(12)) already admitted: not re-entered")
            return .handled
        }
        return await enqueueInboxParentCandidate(
            // Weighed, like every network-sourced block: the verified proof is
            // all the weighed tier needs, so the block enters fork choice with
            // its work at once and is executed when the chain would step into
            // it. Admitted eagerly it would first wait on a continuity fact —
            // a deferral whose only memory was this process.
            CandidateSeed(blockCID: summary.childCID, package: gated, weighed: true),
            generation: generation,
            process: process
        ) ? .handled : .failed
    }

    func handleHierarchy(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.hierarchyHello {
            await handleHierarchyHello(
                message.payload,
                peer: peer,
                generation: generation,
                process: process
            )
            return
        }
        guard hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              let role = hierarchyRecords[peer.key]?.role else { return }

        switch (message.topic, role) {
        case (NodeNetworkTopic.parentChainFactRequest,
              .child(let childPath)):
            // Not behind the query guard: both answers are constant-time
            // reads (an indexed link, the executed-from-genesis frontier),
            // and a silently dropped question costs the child the whole
            // request timeout, which is how a budget here was diagnosed.
            guard let request = try?
                    ParentChainFactMessage.decoded(message.payload)
            else { return }
            let found: Bool
            switch request.fact {
            case .genesis(let childGenesisCID, let parentStateCID):
                guard let directory = childPath.last else { return }
                found = (try? await process.store.issuedParentGenesisLink(
                    directory: directory,
                    childGenesisCID: childGenesisCID,
                    parentStateCID: parentStateCID
                )) != nil
            case .continuity(_, let toStateCID):
                // `decoded` already refused any `from` but the empty state, so
                // this is only ever the anchor question — answered by the
                // executed-from-genesis frontier, walking no chain and
                // independently of height. That is why this path needs neither
                // a visit budget nor a rate limit.
                found = await process.hasProducedParentState(toStateCID)
            }
            SyncTrace.log("parent fact \(request.requestID) from \(childPath.joined(separator: "/")) found=\(found)")
            guard found else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.parentChainFactResponse,
                payload: message.payload
            )

        case (NodeNetworkTopic.parentChainFactResponse, .parent):
            guard let response = try?
                    ParentChainFactMessage.decoded(
                        message.payload
                    ) else { return }
            if let verification = pendingGenesisVerifications[
                response.requestID
            ], verification.peer.key == peer.key,
               verification.peer.sessionID == peer.sessionID,
               response == verification.request {
                resolveGenesisVerification(
                    response.requestID,
                    confirmed: true
                )
                return
            }
            guard let pending = pendingParentChainFacts[
                    response.requestID
                  ],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID,
                  response == pending.request else {
                return
            }
            pendingParentChainFacts.removeValue(
                forKey: response.requestID
            )
            SyncTrace.log("parent fact \(response.requestID) answered for \(pending.blockCID.prefix(12))")
            await acceptParentChainFact(
                pending: pending,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.parentRunReportRequest, .child(let childPath)):
            // A child asks for the runs of committers it names — on admitting
            // a block one of them carried, and after each evidence round.
            // Not behind the per-peer query guard: a dropped ask would be a
            // credit the child recovers only by chance, and the guard never
            // bounded rate anyway (one message per session is handled at a
            // time; Tally paces the plane). The serve below is a set lookup
            // for a directory already served, one anchored-genesis lookup
            // for one that is not, like the genesis-anchor arm; each named
            // committer is then one O(1) read, at most
            // `maximumParentRunReportRequestCarriers` of them. A committer
            // this node does not serve is silence, never a claim.
            guard let request = try?
                    ParentRunReportRequestMessage.decoded(message.payload),
                  let directory = childPath.last
            else { return }
            // A child re-asks right after its hello, while this node's
            // serve-on-hello may still be walking the graph; serve first
            // (idempotent, gated on the directory being anchored here) so the
            // answer is never silence for want of a settled table. Unlike the
            // hello path this does not wait for evidence-ready: that gate
            // sequences what this node publishes, not who may ask.
            guard isCurrentRuntime(generation: generation, process: process) else { return }
            if let chain,
               chain.networkCapabilities.contains(.runReportServing) {
                await chain.serveRuns(for: directory)
            }
            SyncTrace.log("run-report request from child dir=\(directory) committers=\(request.carrierCIDs.count)")
            for carrier in request.carrierCIDs {
                guard isCurrentRuntime(generation: generation, process: process),
                      hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
                      let report = await process.runReport(
                          carrier: carrier, directory: directory
                      ),
                      let payload = try? ParentRunReportMessage(report).encoded()
                else {
                    SyncTrace.log("run-report request committer=\(carrier.prefix(16)) silence")
                    continue
                }
                SyncTrace.log("run-report answer committer=\(carrier.prefix(16)) run=\(report.runWork) own=\(report.ownWork)")
                _ = await hierarchy.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.parentRunReport,
                    payload: payload
                )
            }

        case (NodeNetworkTopic.parentRunReport, .parent):
            // The parent's word on the run behind one of this chain's blocks
            // (§9.10). The service binds it and derives the credit under its
            // own lease; a refusal is counted there, never acted on here.
            guard let report = try? ParentRunReportMessage.decoded(message.payload),
                  let chain,
                  chain.networkCapabilities.contains(.parentRunReports)
            else { return }
            SyncTrace.log("run-report received committer=\(report.report.blockHash.prefix(16)) run=\(report.report.runWork) own=\(report.report.ownWork)")
            // Applied under the process gate, which an admission may hold
            // while it waits for a fact from this very session. Awaited here
            // it would hold the session's delivery, and the fact behind it,
            // until that wait timed out (traced: 15 s silences on every run
            // report). Detached instead; reports are monotone, so order is
            // immaterial.
            let previous = runReportApplyTail
            runReportApplyTail = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, let self,
                      await self.isCurrentRuntime(
                        generation: generation, process: process
                      ) else { return }
                try? await chain.applyParentRunReport(report.report)
            }

        case (NodeNetworkTopic.childGenesisAnchorRequest,
              .child(let childPath)):
            guard let request = try?
                    ChildGenesisAnchorRequestMessage.decoded(message.payload),
                  let directory = childPath.last,
                  parentStateQueryGuard.acquire(peer.key)
            else { return }
            defer {
                parentStateQueryGuard.release(peer.key)
            }
            // Read the CID the parent committed for this child's directory from
            // its own genesisState. Silence (not an error) when unanchored, so
            // an adopting child that raced ahead of the parent's anchor just
            // retries once the record lands.
            guard let genesisCID = await process
                    .anchoredChildGenesisCIDs(directories: [directory])[directory],
                  let payload = try? ChildGenesisAnchorResponseMessage(
                      requestID: request.requestID,
                      genesisCID: genesisCID
                  ).encoded() else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childGenesisAnchorResponse,
                payload: payload
            )

        case (NodeNetworkTopic.childGenesisAnchorResponse, .parent):
            guard let response = try?
                    ChildGenesisAnchorResponseMessage.decoded(message.payload),
                  let pending = pendingGenesisResolves[response.requestID],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID else {
                return
            }
            resolveGenesisAnchor(
                response.requestID, genesisCID: response.genesisCID
            )

        case (NodeNetworkTopic.childEvidenceAvailable, .parent):
            guard
                let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
                ), available.childPath == configuration.chainPath
            else { return }
            let handled = appendParentEvidence(
                [IssuedChildEvidenceSummary(
                    ordinal: available.ordinal,
                    childCID: available.childCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                )],
                sourceID: available.sourceID,
                advanceScan: false,
                from: peer,
                generation: generation,
                process: process
            )
            // A backpressured announcement is simply dropped: the parent's
            // durable index re-serves it on the next scan. Only a rejected
            // session (stale/unknown) is recycle-worthy.
            if case .rejected = handled {
                await hierarchy.recycleSession(ifCurrent: peer)
            }

        case (NodeNetworkTopic.childEvidenceIndexRequest, .child(let childPath)):
            guard let directory = childPath.last,
                  let request = try? ChildEvidenceIndexRequestMessage.decoded(
                    message.payload
                ), request.childPath == childPath
            else { return }
            guard let head = try? await process.store.issuedChildEvidenceScanHead(
                    directory: directory
                  )
            else { return }
            let sameSource = request.sourceID == head.sourceID
            let cursor = sameSource ? request.cursor : 0
            let through = sameSource
                ? (request.through ?? head.throughOrdinal)
                : head.throughOrdinal
            guard through <= head.throughOrdinal,
                  let summaries = try? await process.store.issuedChildEvidenceSummaries(
                    directory: directory,
                    afterOrdinal: cursor,
                    throughOrdinal: through,
                    limit: ChildEvidenceIndexResponseMessage.maximumEntries + 1
                  ), isCurrentRuntime(
                    generation: generation,
                    process: process
                  )
            else {
                return
            }
            let page = Array(
                summaries.prefix(
                ChildEvidenceIndexResponseMessage.maximumEntries
            ))
            guard
                let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: childPath,
                sourceID: head.sourceID,
                cursor: cursor,
                through: through,
                entries: page,
                next: summaries.count > page.count
                    ? (page.last?.ordinal ?? cursor)
                    : through
                ).encoded()
            else { return }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
            guard case .enqueued = result else { return }
            if summaries.count <= page.count {
                completeChildEvidenceIndex(for: peer)
            }
        case (NodeNetworkTopic.childEvidenceIndexResponse, .parent):
            guard
                let response = try? ChildEvidenceIndexResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingEvidenceIndexes[response.requestID],
                  pending.peer.sessionID == peer.sessionID,
                  response.childPath == pending.request.childPath,
                  (response.sourceID == pending.request.sourceID
                    ? response.cursor == pending.request.cursor
                        && pending.request.through.map({
                            response.through == $0
                        }) ?? true
                    : response.cursor == 0)
            else { return }
            pendingEvidenceIndexes.removeValue(forKey: response.requestID)
            scheduleParentEvidencePage(
                response,
                from: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.parentTipAvailable, .parent):
            guard let context = try? ParentTipContextMessage.decoded(
                    message.payload
                  ), context.childPath == configuration.chainPath,
                  let tip = _contentBoundBlock(
                    cid: context.tipCID,
                    data: context.tipData
                  ) else {
                SyncTrace.log("parent tip dropped: undecodable or unbound")
                return
            }
            // Sequences are per session: a lower one on the same session is
            // a reordered stale push; a new session starts over.
            if let current = receivedParentTip,
               current.peer.sessionID == peer.sessionID,
               context.sequence <= current.sequence {
                SyncTrace.log("parent tip dropped: stale sequence \(context.sequence) <= \(current.sequence)")
                return
            }
            receivedParentTip = ReceivedParentTipContext(
                sequence: context.sequence,
                peer: peer,
                tipCID: context.tipCID,
                tip: tip,
                rewards: context.rewards,
                minimumWork: context.minimumWork,
                carriedChildCID: context.carriedChildCID
            )
            SyncTrace.log("parent tip \(context.sequence): h=\(tip.height) tip=\(context.tipCID.prefix(12)) rewards=\(context.rewards.count) carried=\(context.carriedChildCID?.prefix(12) ?? "none")")
            // A carried block this chain has not admitted is fetched now,
            // not on the next hello or admission: the hint naming it may
            // have been refused, and no admission follows a held offer.
            if let carried = context.carriedChildCID,
               carried != requestedCarriedChildCID,
               !(await process.hasAcceptedBlock(carried)),
               await requestEvidenceIndex(generation: generation, process: process) {
                requestedCarriedChildCID = carried
            }
            scheduleCandidateOffer(generation: generation, process: process)

        case (NodeNetworkTopic.childCandidateAvailable, .child(let childPath)):
            // Only a child this chain has wired in, and only once there is a
            // context to build against: a legitimate child pushes for a
            // context it received. Nothing is decoded for anyone else.
            guard isChildEvidenceReady(peer.key),
                  parentTipContext != nil else {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: not ready or no context")
                return
            }
            // The frame's head names the candidate; what it names decides
            // whether the block is decoded at all. The same candidate
            // again, or a reordered older one, says nothing new: no
            // decode, no rebuild, whatever sequence it wears.
            guard let head = ChildCandidateAvailableMessage.peek(message.payload),
                  head.childPath == childPath,
                  let directory = childPath.last else {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: malformed head")
                return
            }
            // Sequences are per session: a candidate cached from an
            // earlier session of this peer (a restart Ivy replaced before
            // the disconnect reached us) neither dedupes nor orders this one.
            if let cached = hierarchyRecords[peer.key]?.offer,
               cached.sessionID == peer.sessionID {
                if cached.childCID == head.childCID {
                    SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: already held")
                    return
                }
                if head.sequence <= cached.sequence {
                    SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: stale sequence")
                    return
                }
            }
            guard let offer = try? ChildCandidateAvailableMessage.decoded(
                    message.payload
                  ), offer.childPath == childPath else {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: undecodable")
                return
            }
            guard let block = _contentBoundBlock(
                    cid: offer.childCID,
                    data: offer.blockData
                  ) else {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: unbound")
                return
            }
            let candidate = DirectChildCandidate(
                directory: directory,
                block: block,
                searchWitness: offer.searchWitness,
                advertiserPeerKey: peer.key
            )
            guard await schedulingTargets(for: candidate) != nil else {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: no scheduling target")
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
                return
            }
            if let cached = hierarchyRecords[peer.key]?.offer,
               cached.sessionID == peer.sessionID,
               offer.sequence <= cached.sequence {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: stale sequence")
                return
            }
            hierarchyRecords.update(peer.key) {
                $0.offer = CachedChildCandidate(
                    sequence: offer.sequence,
                    sessionID: peer.sessionID,
                    childCID: offer.childCID,
                    candidate: candidate
                )
            }
            SyncTrace.log("child candidate cached from \(childPath.joined(separator: "/")): h=\(block.height) parentState=\(block.parentState.rawCID.prefix(12)) seq=\(offer.sequence)")
            // This chain's own candidate now carries a fresher child: rebuild
            // it for our parent, if we have one.
            scheduleCandidateOffer(generation: generation, process: process)

        default:
            break
        }
    }

    private func handleHierarchyHello(
        _ payload: Data,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard expectsHierarchyHello(from: peer) else { return }
        guard peer.role == .endpoint, peer.route == .direct,
            let remote = try? ChainHello.decode(payload)
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        guard
            let role = Self.hierarchyRole(
            for: remote,
            peerKey: peer.key.hex,
            configuration: configuration
        )
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        guard isCurrentRuntime(generation: generation, process: process),
              expectsHierarchyHello(from: peer) else {
            return
        }
        removeHierarchyHelloDeadline(for: peer.key)?.task.cancel()
        if let existing = hierarchyRecords[peer.key]?.role {
            if existing != role {
                await hierarchy.disconnectSession(ifCurrent: peer)
                return
            }
        }
        if hierarchyRecords[peer.key]?.session?.sessionID != peer.sessionID {
            hierarchyRecords.update(peer.key) { $0.evidence.ready = false }
            cancelChildEvidenceReadyWaiters(for: peer.key)
        }
        hierarchyRecords.update(peer.key) {
            $0.role = role
            $0.session = peer
        }
        if case .child = role {
            // Tolerant ingest of the child's self-declared read URL: invalid
            // or absent just isn't carried (never a session cost).
            if let url = normalizedPublicReadURL(remote.publicReadURL) {
                hierarchyRecords.update(peer.key) { $0.declaredReadURL = url }
            } else {
                hierarchyRecords.update(peer.key) { $0.declaredReadURL = nil }
            }
        }
        scheduleHierarchyHelloFollowup(
            role: role,
            peer: peer,
            generation: generation,
            process: process
        )
    }

    private func scheduleHierarchyHelloFollowup(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        Task { [weak self] in
            await self?.finishHierarchyHello(
                role: role,
                peer: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func finishHierarchyHello(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
            return
        }
        if case .parent = role {
            // The run re-ask follows the evidence round this starts, once
            // the blocks it brings are held here (`scheduleParentEvidencePage`).
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        } else if case .child(let childPath) = role {
            guard await waitForChildEvidenceReady(peer: peer) else {
                _ = clearHierarchyAuthorization(for: peer.key)
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            // A child wired in: serve its runs from now on. The service
            // refuses a directory this chain never anchored a child genesis
            // for, so a hello alone names nothing (idempotent otherwise).
            if let directory = childPath.last,
               let chain,
               chain.networkCapabilities.contains(.runReportServing) {
                await chain.serveRuns(for: directory)
            }
            // A child wired in builds against this chain's current context:
            // the push task sends it to every ready child that lacks it.
            scheduleParentTipPush(generation: generation, process: process)
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
        }
    }

    func scheduleChildProofRecovery(
        generation: UInt64,
        process: ChainProcess
    ) {
        if childProofRecoveryTask != nil {
            if childProofRecoveryGeneration == generation {
                childProofRecoveryNeedsRefresh = true
            }
            return
        }
        childProofRecoveryGeneration = generation
        childProofRecoveryNeedsRefresh = false
        childProofRecoveryTask = Task { [weak self] in
            await self?.recoverChildProofs(
                generation: generation,
                process: process
            )
        }
    }

    /// Directories of the immediate children currently wired to this node.
    func wiredChildDirectories() -> Set<String> {
        Set(hierarchyRoles.map(\.value).compactMap { role -> String? in
            guard case .child(let path) = role else { return nil }
            return path.last
        })
    }

    private func recoverChildProofs(
        generation: UInt64,
        process: ChainProcess
    ) async {
        // Late-child backfill: a child that connected AFTER its carriers were
        // admitted — or whose carriers were recovered durably on restart rather
        // than re-admitted — has no pending proof route for those historical
        // carriers, so the retry loop below would have nothing to issue. A node
        // that MINED a carrier issues for every child eagerly; this restores the
        // same for a node that SYNCED it. Seed routes across the recent
        // accepted-carrier window for every connected direct child (the whole
        // set, not the rotated serving subset); the retry loop then generates
        // and announces them from local or peer content. Carriers older than the
        // window rely on the verified any-peer proof fallback — a bounded
        // window, not silent completeness.
        let connectedChildDirectories = Set(
            hierarchyRoles.map(\.value).compactMap { role -> String? in
                guard case .child(let path) = role else { return nil }
                return path.last
            }
        ).sorted()
        for directory in connectedChildDirectories
        where !backfilledChildDirectories.contains(directory) {
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await process.backfillChildProofRoutes(directory: directory)
            // Mark only after completion, so an interrupted backfill retries on
            // the next recovery pass rather than being skipped as done.
            backfilledChildDirectories.insert(directory)
        }
        repeat {
            childProofRecoveryNeedsRefresh = false
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryRecoveredChildProofs(
                generation: generation,
                process: process
            )
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryCurrentTipChildProofs(
                generation: generation,
                process: process
            )
        } while childProofRecoveryNeedsRefresh

        guard childProofRecoveryGeneration == generation,
              self.process === process else { return }
        childProofRecoveryTask = nil
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
    }

    func scheduleHierarchyHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        removeHierarchyHelloDeadline(for: peer.key)?.task.cancel()
        nextHelloDeadlineToken &+= 1
        let token = nextHelloDeadlineToken
        let task = Timers.deadline(
            after: planeConfigurations.hierarchy.requestTimeout,
            generation: generation
        ) { [weak self] generation in
            await self?.hierarchyHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        hierarchyRecords.update(peer.key) {
            $0.helloDeadline = HelloDeadline(
                token: token,
                sessionID: peer.sessionID,
                task: task
            )
        }
    }

    private func expectsHierarchyHello(from peer: AuthenticatedPeer) -> Bool {
        Self.hierarchyHelloMatches(
            sessionID: peer.sessionID,
            deadlineSessionID: hierarchyRecords[peer.key]?.helloDeadline?.sessionID
        )
    }

    static func hierarchyHelloMatches(
        sessionID: Data,
        deadlineSessionID: Data?
    ) -> Bool {
        deadlineSessionID == sessionID
    }

    private func hierarchyHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: UInt64
    ) async {
        guard isCurrentGeneration(generation),
            isRunning,
            hierarchyRecords[peer.key]?.helloDeadline?.token == token,
            hierarchyRecords[peer.key]?.helloDeadline?.sessionID == peer.sessionID,
            hierarchyRecords[peer.key]?.role == nil
        else { return }
        removeHierarchyHelloDeadline(for: peer.key)
        await hierarchy.recycleSession(ifCurrent: peer)
    }

    /// Verify-not-trust gate for deployer-seeded self-admission: ask the
    /// authenticated immediate parent whether it recorded exactly this child
    /// genesis CID (bound to the empty parent state a self-contained genesis
    /// commits to). The parent answers only on a positive match and stays silent
    /// otherwise, so an unrecorded — or mismatched — CID resolves `false` when the
    /// request times out. `false` on a missing parent session too; the caller
    /// retries until the parent connects and confirms.
    public func confirmParentRecordedChildGenesis(
        childGenesisCID: String
    ) async -> Bool {
        guard !configuration.address.isNexus,
              pendingGenesisVerifications.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            return false
        }
        let request = ParentChainFactMessage(
            requestID: makeRequestID(),
            fact: .genesis(
                childGenesisCID: childGenesisCID,
                parentStateCID: LatticeState.emptyHeader.rawCID
            )
        )
        guard let payload = try? request.encoded() else { return false }
        let delay = Timers.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        return await withCheckedContinuation { continuation in
            pendingGenesisVerifications[request.requestID] =
                PendingGenesisVerification(
                    peer: parent,
                    request: request,
                    continuation: continuation
                )
            Task { [weak self] in
                _ = await self?.hierarchy.sendMessage(
                    to: parent,
                    topic: NodeNetworkTopic.parentChainFactRequest,
                    payload: payload
                )
                _ = await Timers.sleep(nanoseconds: delay)
                await self?.resolveGenesisVerification(
                    request.requestID,
                    confirmed: false
                )
            }
        }
    }

    private func resolveGenesisVerification(
        _ requestID: UInt64,
        confirmed: Bool
    ) {
        guard let pending = pendingGenesisVerifications.removeValue(
            forKey: requestID
        ) else { return }
        pending.continuation.resume(returning: confirmed)
    }

    /// Ask the authenticated immediate parent for the genesis CID it recorded for
    /// THIS child's own directory (read from the parent's committed genesisState).
    /// Returns nil on a missing parent session or timeout, for the caller to
    /// retry. Verify-not-trust: the CID is content-addressed and re-confirmed
    /// against the parent record before any admission.
    private func resolveParentAnchoredGenesis() async -> String? {
        guard !configuration.address.isNexus,
              pendingGenesisResolves.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            return nil
        }
        let requestID = makeRequestID()
        guard let payload = try? ChildGenesisAnchorRequestMessage(
            requestID: requestID
        ).encoded() else { return nil }
        let delay = Timers.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        return await withCheckedContinuation { continuation in
            pendingGenesisResolves[requestID] = PendingGenesisResolve(
                peer: parent,
                continuation: continuation
            )
            Task { [weak self] in
                _ = await self?.hierarchy.sendMessage(
                    to: parent,
                    topic: NodeNetworkTopic.childGenesisAnchorRequest,
                    payload: payload
                )
                _ = await Timers.sleep(nanoseconds: delay)
                await self?.resolveGenesisAnchor(requestID, genesisCID: nil)
            }
        }
    }

    private func resolveGenesisAnchor(
        _ requestID: UInt64,
        genesisCID: String?
    ) {
        guard let pending = pendingGenesisResolves.removeValue(
            forKey: requestID
        ) else { return }
        pending.continuation.resume(returning: genesisCID)
    }

    func scheduleAdoptedGenesisBootstrap(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              adoptedGenesisTask == nil else { return }
        adoptedGenesisTask = Task { [weak self] in
            await self?.adoptedGenesisBootstrapLoop(
                generation: generation,
                process: process
            )
        }
    }

    /// A child this node ADOPTED (no local genesis seed) sits `awaitingGenesis`
    /// until it obtains its self-contained genesis: resolve the recorded CID off
    /// the authenticated parent, fetch the genesis volume from a child-overlay
    /// provider, and self-admit it (fail-closed on the parent record). A seeded
    /// deployer activates from its local seed before this ever fires; this drives
    /// the no-seed follower case the candidate machinery cannot (a self-contained
    /// genesis carries no ChildBlockProof to package). Once active, kick the
    /// ordinary follower sync so the child catches up to the parent's tip.
    private func adoptedGenesisBootstrapLoop(
        generation: UInt64,
        process: ChainProcess
    ) async {
        var lastTraced = ""
        func traceOnce(_ outcome: String) {
            guard outcome != lastTraced else { return }
            lastTraced = outcome
            SyncTrace.log("adopt-genesis \(outcome)")
        }
        await Timers.poll(every: .seconds(1), onCancel: ()) {
            guard isRunning, runtimeGeneration == generation else {
                return .done(())
            }
            if await process.status().phase != .awaitingGenesis { return .done(()) }
            if let genesisCID = await resolveParentAnchoredGenesis() {
                traceOnce("resolved \(genesisCID)")
                let activated = (try? await remoteContentSource.withRoot(
                    genesisCID
                ) { session in
                    try await process.activateAdoptedChildGenesis(
                        genesisCID: genesisCID,
                        remoteSource: session,
                        confirmParentRecordedGenesis: { [weak self] cid in
                            await self?.confirmParentRecordedChildGenesis(
                                childGenesisCID: cid
                            ) ?? false
                        }
                    )
                }) ?? false
                traceOnce(activated
                    ? "activated \(genesisCID)"
                    : "fetch-or-confirm failed \(genesisCID)")
                guard isCurrentRuntime(
                    generation: generation, process: process
                ) else { return .done(()) }
                if activated {
                    // The genesis just bootstrapped to active OUT OF BAND (not via
                    // candidate admission), so it never fired its one-shot connect
                    // signal. Wake the successors that parked behind it while
                    // awaitingGenesis, or the whole chain above the genesis stays
                    // orphaned and the child never canonicalizes past height 0.
                    blockFetcher.predecessorConnectedOutOfBand(genesisCID)
                    serviceBlockFetcher()
                    await requestEvidenceIndex(
                        generation: generation,
                        process: process
                    )
                    return .done(())
                }
            } else {
                traceOnce("parent record unresolved")
            }
            return .again
        }
    }

    /// Validate-tier evidence (deferred execution): a weighed CHILD block's
    /// `.execution` admission recovers its own proof package from the store but
    /// still needs the cross-chain fact the live path obtains from the
    /// configured parent — the parent-state continuity (or genesis) link. The
    /// walk hands the requirement here; this is the SAME request the live
    /// candidate path sends (`requestParentChainFact`), awaited, and the merged
    /// package is returned for the `.execution` re-admit. Nil when the fact is
    /// not obtainable now (no parent session, request budget, timeout); the
    /// walk then parks and retries. Without this, every weighed child block
    /// parks the walk on `.unavailable(.parentStateContinuity)` forever.
    public func resolveExecutionEvidence(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage? {
        guard isRunning, let process, !configuration.address.isNexus,
              let fact = parentFact(for: requirement) else {
            return nil
        }
        let generation = runtimeGeneration
        guard let package = try? await process.recoveredAuthenticatedChildPackage(
            for: blockCID
        ), isCurrentRuntime(generation: generation, process: process) else {
            return nil
        }
        return await awaitParentFact(
            fact,
            for: blockCID,
            package: package,
            generation: generation,
            process: process
        )
    }

    #if DEBUG
    /// Test seam: `resolveExecutionEvidence` with the block's package supplied
    /// instead of recovered from the store — the request, await and every
    /// resumption path are the production ones.
    public func resolveExecutionEvidenceForTesting(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement,
        package: AuthenticatedChildPackage
    ) async -> AuthenticatedChildPackage? {
        guard isRunning, let process, let fact = parentFact(for: requirement) else {
            return nil
        }
        return await awaitParentFact(
            fact,
            for: blockCID,
            package: package,
            generation: runtimeGeneration,
            process: process
        )
    }
    #endif

    private func parentFact(
        for requirement: CrossChainEvidenceRequirement
    ) -> ParentChainFact? {
        let parentPath = Array(configuration.chainPath.dropLast())
        switch requirement {
        case .parentGenesis(
            let requiredPath, let directory, let childGenesisCID, let parentStateCID
        ) where requiredPath == parentPath
                && directory == configuration.address.directory:
            return .genesis(
                childGenesisCID: childGenesisCID,
                parentStateCID: parentStateCID
            )
        case .parentStateContinuity(let requiredPath, let fromStateCID, let toStateCID)
            where requiredPath == parentPath:
            return .continuity(fromStateCID: fromStateCID, toStateCID: toStateCID)
        default:
            return nil
        }
    }

    /// Send the parent-fact request and await its outcome: the merged package
    /// on a fact, nil on refusal, timeout, parent disconnect or reset. Every
    /// removal of the pending entry resumes the continuation (see
    /// `discardPendingParentChainFacts`), so the walk never stays suspended.
    private func awaitParentFact(
        _ fact: ParentChainFact,
        for blockCID: String,
        package: AuthenticatedChildPackage,
        generation: UInt64,
        process: ChainProcess
    ) async -> AuthenticatedChildPackage? {
        SyncTrace.log(
            "validate evidence request block=\(blockCID.prefix(12)) fact=\(fact)"
        )
        return await withCheckedContinuation { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                await self.requestParentChainFact(
                    fact,
                    for: blockCID,
                    package: package,
                    generation: generation,
                    process: process,
                    continuation: continuation
                )
            }
        }
    }

    /// The one teardown path for pending parent-fact requests: a walk's
    /// continuation is resumed nil, a live candidate's entry is requeued when
    /// asked. No other site may drop an entry without going through here.
    func discardPendingParentChainFacts(
        where predicate: (PendingParentChainFact) -> Bool,
        requeue: Bool
    ) {
        let discarded = pendingParentChainFacts.values.filter(predicate)
        pendingParentChainFacts = pendingParentChainFacts.filter {
            !predicate($0.value)
        }
        for pending in discarded {
            if let continuation = pending.continuation {
                continuation.resume(returning: nil)
            } else if requeue {
                retryParentFactCandidate(pending)
            }
        }
    }

    /// Ask the parent for the runs of the committers this chain recently
    /// accepted blocks from — after every evidence catch-up round: the
    /// fallback for pushes missed while the session was down. The blocks a
    /// round itself brings are queued as candidates, not yet accepted, so
    /// they are asked for one by one as they are admitted (the service's
    /// requester). Nothing to ask means nothing is sent.
    private func requestParentRunReports(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let chain,
              chain.networkCapabilities.contains(.recentCarriers)
        else { return }
        let carriers = await chain.recentCarriers()
        await requestParentRunReports(
            carriers: carriers, generation: generation, process: process
        )
    }

    /// Ask the parent for the runs of the committers of a block just
    /// admitted here (§9.10) — one message for all of them. Public for the
    /// service's admission effects.
    public func requestParentRunReports(carriers: [String]) async {
        guard isRunning, let process else { return }
        await requestParentRunReports(
            carriers: carriers, generation: runtimeGeneration, process: process
        )
    }

    private func requestParentRunReports(
        carriers: [String],
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              let parent = configuredParentPeer(),
              !carriers.isEmpty,
              let payload = try? ParentRunReportRequestMessage(
                  requestID: makeRequestID(),
                  carrierCIDs: carriers
              ).encoded()
        else { return }
        let sent = await hierarchy.sendMessage(
            to: parent,
            topic: NodeNetworkTopic.parentRunReportRequest,
            payload: payload
        )
        SyncTrace.log("run-report request committers=\(carriers.count) sent=\(sent)")
    }

    /// Push one run report to every authenticated child of its directory
    /// (§9.10). A push that does not land is re-served by the child's own
    /// ask — on admitting a block that committer carried, and after each
    /// evidence round — so no delivery result is acted on.
    public func announceParentRunReport(_ report: ParentRunReport) async {
        guard isRunning, let process,
              let payload = try? ParentRunReportMessage(report).encoded()
        else { return }
        let generation = runtimeGeneration
        let children = hierarchyRoles.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path.last == report.directory else { return nil }
            return hierarchyRecords[key]?.session
        }
        for peer in children {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
            else { continue }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.parentRunReport,
                payload: payload
            )
        }
    }

    func requestParentChainFact(
        _ fact: ParentChainFact,
        for blockCID: String,
        package: AuthenticatedChildPackage,
        generation: UInt64,
        process: ChainProcess,
        continuation: CheckedContinuation<AuthenticatedChildPackage?, Never>? = nil
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              pendingParentChainFacts.count
                < Self.maximumPendingRequests,
              !pendingParentChainFacts.values.contains(where: {
                  $0.blockCID == blockCID
                    && $0.request.fact == fact
              }),
              let parent = configuredParentPeer() else {
            continuation?.resume(returning: nil)
            return
        }
        let request = ParentChainFactMessage(
            requestID: makeRequestID(),
            fact: fact
        )
        guard let payload = try? request.encoded() else {
            continuation?.resume(returning: nil)
            return
        }
        pendingParentChainFacts[request.requestID] =
            PendingParentChainFact(
                peer: parent,
                request: request,
                blockCID: blockCID,
                package: package,
                continuation: continuation
            )
        // Armed BEFORE the send suspends: the entry must always have a
        // bounded life, whatever happens during or after the send. A failed
        // enqueue is transient — the same timeout used for an unanswered
        // parent response requeues the candidate (or resolves the walk's
        // request nil); a disconnect does so sooner.
        Timers.deadline(
            after: planeConfigurations.hierarchy.requestTimeout,
            generation: generation
        ) { [weak self] generation in
            await self?.parentChainFactRequestTimedOut(
                request.requestID,
                generation: generation
            )
        }
        let sent = await hierarchy.sendMessage(
            to: parent,
            topic: NodeNetworkTopic.parentChainFactRequest,
            payload: payload
        )
        SyncTrace.log("parent fact \(request.requestID) requested for \(blockCID.prefix(12)) walk=\(continuation != nil) sent=\(sent)")
        guard isCurrentRuntime(
            generation: generation,
            process: process
        ) else {
            discardPendingParentChainFacts(
                where: { $0.request.requestID == request.requestID },
                requeue: false
            )
            return
        }
    }

    private func acceptParentChainFact(
        pending: PendingParentChainFact,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            pending.continuation?.resume(returning: nil)
            return
        }
        let parentPath = Array(configuration.chainPath.dropLast())
        let localFact: AuthenticatedChildPackage
        switch pending.request.fact {
        case .genesis(let childGenesisCID, let parentStateCID):
            localFact = AuthenticatedChildPackage(package: ChildValidationPackage(
                proof: pending.package.package.proof,
                parentGenesisLink: ParentGenesisLink(
                    parentPath: parentPath,
                    directory: configuration.address.directory,
                    childGenesisCID: childGenesisCID,
                    parentStateCID: parentStateCID
                )
            ))
        case .continuity(let fromStateCID, let toStateCID):
            localFact = AuthenticatedChildPackage(package: ChildValidationPackage(
                proof: pending.package.package.proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: parentPath,
                    fromStateCID: fromStateCID,
                    toStateCID: toStateCID
                )
            ))
        }
        guard let merged = BlockFetcher.mergePackages(
            pending.package,
            localFact
        ) else {
            pending.continuation?.resume(returning: nil)
            return
        }
        // The validate walk asked for this fact: hand the merged package back
        // to its `.execution` re-admit; there is no live candidate to re-ready.
        if let continuation = pending.continuation {
            continuation.resume(returning: merged)
            return
        }
        // A parent fact that arrives SUCCESSFULLY must re-ready the candidate that
        // was blocked waiting for it. observe()/enqueueCandidate only flips a
        // `.waiting(.evidence)` attempt back to `.ready`, never a `.waiting(.later)`
        // one, so without retryExternalDependency the candidate would wedge until
        // the wall-clock poll (or 2h expiry). Mirror the timeout path
        // (retryParentFactCandidate) so the fact's arrival is itself the trigger.
        _ = blockFetcher.observe(CandidateSeed(
            blockCID: pending.blockCID,
            package: merged
        ))
        blockFetcher.retryExternalDependency(
            blockCID: pending.blockCID,
            rootCID: pending.package.package.proof.rootCID
        )
        serviceBlockFetcher()
    }

    private func parentChainFactRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
              let pending = pendingParentChainFacts.removeValue(
                forKey: requestID
              ) else { return }
        SyncTrace.log("parent fact \(requestID) timed out for \(pending.blockCID.prefix(12)) walk=\(pending.continuation != nil)")
        if let continuation = pending.continuation {
            continuation.resume(returning: nil)
            return
        }
        retryParentFactCandidate(pending)
    }

    private func retryParentFactCandidate(_ pending: PendingParentChainFact) {
        _ = blockFetcher.observe(CandidateSeed(
            blockCID: pending.blockCID,
            package: pending.package
        ))
        blockFetcher.retryExternalDependency(
            blockCID: pending.blockCID,
            rootCID: pending.package.package.proof.rootCID
        )
        serviceBlockFetcher()
    }

    /// Returns whether a request was sent: none is while a round is in
    /// flight, before a parent session exists, or on a root chain.
    @discardableResult
    func requestEvidenceIndex(
        sourceID: String? = nil,
        cursor: UInt64? = nil,
        through: UInt64? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async -> Bool {
        guard
            isRunning,
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), !configuration.address.isNexus,
              pendingEvidenceIndexes.isEmpty,
            let parent = configuredParentPeer()
        else { return false }
        let durableCursor: ParentEvidenceScanCursor
        if let sourceID, let cursor {
            durableCursor = ParentEvidenceScanCursor(
                sourceID: sourceID,
                ordinal: cursor
            )
        } else {
            guard let persisted = try? await fence.process
                .store.parentEvidenceScanCursor()
            else { return false }
            durableCursor = persisted
        }
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            sourceID: durableCursor.sourceID,
            cursor: durableCursor.ordinal,
            through: through
        )
        guard let payload = try? request.encoded() else { return false }
        pendingEvidenceIndexes[request.requestID] = .init(
            peer: parent,
            request: request
        )
        let result = await hierarchy.sendMessage(
                to: parent,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
        )
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
            return false
        }
        if result != .notConnected {
            if pendingEvidenceIndexes[request.requestID] != nil {
                scheduleEvidenceIndexTimeout(
                    request.requestID,
                    generation: fence.generation
                )
            }
            return true
        } else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
            return false
        }
    }

    private func scheduleEvidenceIndexTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Timers.deadline(
            after: timeout,
            generation: generation
        ) { [weak self] generation in
            await self?.evidenceIndexRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func evidenceIndexRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) async {
        guard isRunning,
            isCurrentGeneration(generation),
            let process,
              let request = pendingEvidenceIndexes.removeValue(
                forKey: requestID
            )
        else { return }
        await requestEvidenceIndex(
            sourceID: request.request.sourceID,
            cursor: request.request.cursor,
            through: request.request.through,
            generation: generation,
            process: process
        )
    }

    private func resolvedMiningRewards(
        _ rewards: [MiningReward],
        process: ChainProcess,
        generation: UInt64
    ) async -> [MiningReward]? {
        var resolved: [MiningReward] = []
        resolved.reserveCapacity(rewards.count)
        for reward in rewards {
            if reward.transaction.body.node != nil {
                resolved.append(reward)
                continue
            }
            guard
                let data = try? await process.fetch(
                    rawCid: reward.transaction.body.rawCID
                  ), let body = TransactionBody(data: data),
                isCurrentRuntime(generation: generation, process: process),
                  body.toData() == data,
                  let header = try? HeaderImpl<TransactionBody>(node: body),
                header.rawCID == reward.transaction.body.rawCID
            else {
                return nil
            }
            resolved.append(
                MiningReward(
                chainPath: reward.chainPath,
                transaction: Transaction(
                    signatures: reward.transaction.signatures,
                    body: header
                )
            ))
        }
        return resolved
    }

    private func selectedChildPeers() -> [(Int, PeerKey, [String])] {
        var paths: [String: [String]] = [:]
        var peers: [String: [PeerKey]] = [:]
        for (key, role) in hierarchyRoles {
            guard case .child(let path) = role,
                  isChildEvidenceReady(key) else {
                continue
            }
            let pathKey = path.joined(separator: "/")
            paths[pathKey] = path
            peers[pathKey, default: []].append(key)
        }

        let pathKeys = peers.keys.sorted()
        let pathRotation = Self.rotatedPeerIndices(
            peerCount: pathKeys.count,
            start: childPathRotation,
            limit: min(pathKeys.count, Self.maximumDirectChildren)
        )
        childPathRotation = pathRotation.next

        var selectedPaths: [(path: [String], peers: [PeerKey])] = []
        for pathIndex in pathRotation.indices {
            let pathKey = pathKeys[pathIndex]
            guard let path = paths[pathKey] else { continue }
            let keys = peers[pathKey]!.sorted { $0.hex < $1.hex }
            let start = (childPeerRotation[pathKey] ?? 0) % keys.count
            let rotation = Self.rotatedPeerIndices(
                peerCount: keys.count,
                start: start,
                limit: min(Self.maximumPeersPerChildPath, keys.count)
            )
            selectedPaths.append((path, rotation.indices.map { keys[$0] }))
            childPeerRotation[pathKey] = rotation.next
        }

        var selected: [(Int, PeerKey, [String])] = []
        for (pathIndex, peerIndex) in Self.interleavedChildPeerIndices(
            peerCounts: selectedPaths.map { $0.peers.count },
            limit: Self.maximumDirectChildren
        ) {
            let path = selectedPaths[pathIndex]
            selected.append((selected.count, path.peers[peerIndex], path.path))
        }
        return selected
    }

    func authenticatedChildDirectories() -> [String] {
        let directories: [String] = Array(
            Set<String>(
            hierarchyRoles.map(\.value).compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.last
            }
            )
        ).sorted()
        let rotation = Self.rotatedPeerIndices(
            peerCount: directories.count,
            start: childProofPathRotation,
            limit: min(directories.count, Self.maximumDirectChildren)
        )
        childProofPathRotation = rotation.next
        return rotation.indices.map { directories[$0] }
    }

    func retryCurrentTipChildProofs(
        tipCID: String? = nil,
        directories: [String]? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            )
        else { return }
        let resolvedTipCID: String
        if let tipCID {
            resolvedTipCID = tipCID
        } else {
            guard let currentTipCID = await fence.process.status().tipCID,
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            resolvedTipCID = currentTipCID
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        let directories = directories ?? authenticatedChildDirectories()
        guard !directories.isEmpty else { return }
        try? await remoteContentSource.withRoot(resolvedTipCID) { session in
            try await fence.process.prepareChildProofs(
                for: BlockHeader(
                    rawCID: resolvedTipCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: directories,
                remoteSource: session
            )
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        guard
            await announceCurrentCarrierChildEvidence(
                directories: directories,
                carrierCID: resolvedTipCID,
                generation: fence.generation,
                process: fence.process
            )
        else {
            return
        }
    }

    private func retryRecoveredChildProofs(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), let carrierCIDs = try? await fence.process.pendingChildProofCarrierCIDs(),
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        for carrierCID in carrierCIDs {
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            let directories = try? await remoteContentSource.withRoot(carrierCID) { session in
                try await fence.process.retryPendingChildProofs(
                    carrierCID: carrierCID,
                    remoteSource: session
                )
            }
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            if let directories, !directories.isEmpty {
                guard
                    await announceCurrentCarrierChildEvidence(
                        directories: directories,
                        carrierCID: carrierCID,
                        generation: fence.generation,
                        process: fence.process
                    )
                else { return }
            }
        }
    }
}
