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
        hierarchyState.descendantRewards = rewards
        hierarchyState.descendantMinimumWork = minimumWork
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
                  let offer = hierarchyState.hierarchyRecords[key]?.offer,
                  offer.candidate.block.parentState.rawCID == parentStateCID,
                  offer.childCID != hierarchyState.parentTipContext?.carriedChildren[directory]
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
        var carriedChildren = hierarchyState.parentTipContext?.carriedChildren ?? [:]
        if let tipCID = context.parentCarrier.parent?.rawCID {
            let onTip = await process.carriedChildBlocks(
                on: tipCID,
                directories: children.compactMap { $0.2.last }
            )
            carriedChildren.merge(onTip) { _, tip in tip }
        }
        let carriedOnContext = hierarchyState.parentTipContext?.carriedChildren ?? [:]
        var candidates: [(Int, DirectChildCandidate)] = []
        var stale = 0
        var carried = 0
        for (rank, key, path) in children {
            guard let offer = hierarchyState.hierarchyRecords[key]?.offer else { continue }
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
        guard hasChildren || hierarchyState.parentTipContext != nil else { return }
        let rewards = hierarchyState.descendantRewards
        let minimumWork = hierarchyState.descendantMinimumWork
        // Cheap first: the validated tip's CID without resolving the block.
        // A walk step publishes a state change per block, and this must
        // not cost the process gate three times per step when nothing the
        // children build against changed.
        let directories = Set(hierarchyRoles.map(\.value).compactMap { role -> String? in
            guard case .child(let path) = role else { return nil }
            return path.last
        })
        if let current = hierarchyState.parentTipContext,
           let cheapTip = await process.deepestValidatedCanonicalTip()?.cid,
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
        if let current = hierarchyState.parentTipContext,
           current.tipCID == tipCID,
           current.directories == directories,
           Self.sameRewardPlan(current.rewards, rewards),
           current.minimumWork == minimumWork {
            return
        }
        let carried = await process.carriedChildBlocks(
            on: tipCID, directories: directories.sorted()
        )
        guard isCurrentRuntime(generation: generation, process: process) else { return }
        hierarchyState.nextParentTipSequence &+= 1
        let context = ParentTipContext(
            sequence: hierarchyState.nextParentTipSequence,
            tipCID: tipCID,
            tipData: tipData,
            rewards: rewards,
            minimumWork: minimumWork,
            carriedChildren: carried,
            directories: directories
        )
        hierarchyState.parentTipContext = context
        SyncTrace.log("parent tip context \(context.sequence): h=\(tip.height) tip=\(tipCID.prefix(12)) carried=\(carried.keys.sorted())")
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
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        hierarchyState.parentTipPushDirty = true
        hierarchyState.parentTipPushTask.start { token in
            Task { [weak self] in
                await self?.runParentTipPushes(
                    token: token,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func runParentTipPushes(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        // A run cancelled by a stop that a restart followed must not clear
        // the restart's handle.
        defer { hierarchyState.parentTipPushTask.clear(token) }
        while hierarchyState.parentTipPushDirty, !Task.isCancelled,
              hierarchyState.parentTipPushTask.holds(token),
              isCurrentRuntime(generation: generation, process: process) {
            hierarchyState.parentTipPushDirty = false
            await resendRefusedChildEvidenceHints(
                generation: generation, process: process
            )
            await refreshParentTipContext(process: process, generation: generation)
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process),
                  let context = hierarchyState.parentTipContext else { return }
            for (key, role) in hierarchyRoles {
                // Each push suspends: the next child is pushed only while
                // this run still owns the slot and its generation runs.
                guard hierarchyState.parentTipPushTask.holds(token),
                      isCurrentRuntime(generation: generation, process: process)
                else { return }
                guard case .child(let childPath) = role,
                      isChildEvidenceReady(key),
                      let peer = hierarchyState.hierarchyRecords[key]?.session,
                      sequence(hierarchyState.hierarchyRecords[key]?.pushedSequence, on: peer) != context.sequence
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
                  let peer = hierarchyState.hierarchyRecords[key]?.session,
                  isChildEvidenceReady(key) else { continue }
            let sent = await sendToHierarchyPeer(
                peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            if case .enqueued = sent,
               hierarchyState.hierarchyRecords.update(session: peer, {
                   guard $0.refusedHint == payload else { return false }
                   $0.refusedHint = nil
                   return true
               }) == true {
                SyncTrace.log("child evidence announcement re-sent to \(key.hex.prefix(12))")
            }
        }
    }

    /// A send to a hierarchy session whose result a per-peer write
    /// follows. The session may end while the send is suspended, so that
    /// write goes through `update(session:)`, never `update`.
    private func sendToHierarchyPeer(
        _ peer: AuthenticatedPeer,
        topic: String,
        payload: Data
    ) async -> SendMessageResult {
        let sent = await hierarchy.sendMessage(
            to: peer,
            topic: topic,
            payload: payload
        )
        #if DEBUG
        await hierarchySendReturnedForTesting?(topic, sent)
        #endif
        return sent
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
            minimumWork: minimumWork
        ).encoded() else {
            SyncTrace.log("parent tip push to \(childPath.joined(separator: "/")) not built")
            return
        }
        let sent = await sendToHierarchyPeer(
            peer,
            topic: NodeNetworkTopic.parentTipAvailable,
            payload: payload
        )
        if case .enqueued = sent {
            // The session may have ended while the send was suspended: the
            // record, if any, belongs to it only while it is still live.
            hierarchyState.hierarchyRecords.update(session: peer) {
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
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyState.receivedParentTip != nil,
              chain?.networkCapabilities.contains(.childCandidates) == true
        else { return }
        hierarchyState.candidateOfferDirty = true
        hierarchyState.candidateOfferTask.start { token in
            Task { [weak self] in
                await self?.runCandidateOffers(
                    token: token,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func runCandidateOffers(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { hierarchyState.candidateOfferTask.clear(token) }
        while hierarchyState.candidateOfferDirty, !Task.isCancelled,
              hierarchyState.candidateOfferTask.holds(token),
              isCurrentRuntime(generation: generation, process: process) {
            hierarchyState.candidateOfferDirty = false
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
        // A candidate this chain built that the parent's evidence names as
        // carried and still holds in the inbox (undecided), now ready for
        // or in its admission: the carried block is about to be this
        // chain's weighed tip, and a candidate built now, on the tip before
        // it, would only be its sibling. The inbox is written only from the
        // configured parent's evidence, so no overlay peer can populate
        // this set; an announcement can at most re-ready an inbox entry's
        // own attempt. Offer once the admission decides or parks; the
        // drain re-arms the offer either way. An open gate also clears a
        // deferral the drain never got to read.
        let pendingHandoff = (try? await process.store.pendingHandoffChildCIDs()) ?? []
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard offerGate(pendingHandoff: pendingHandoff) else {
            SyncTrace.log("candidate offer deferred: own carried candidate awaiting admission")
            return
        }
        guard let context = hierarchyState.receivedParentTip,
              hierarchyState.hierarchyRecords[context.peer.key]?.session?.sessionID
                == context.peer.sessionID,
              hierarchyState.hierarchyRecords[context.peer.key]?.role == .parent,
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
              hierarchyState.hierarchyRecords[context.peer.key]?.session?.sessionID
                == context.peer.sessionID,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID
        else { return }
        // The same candidate again says nothing new to the parent.
        if childCID == hierarchyState.lastOfferedCandidateCID { return }
        hierarchyState.nextCandidateOfferSequence &+= 1
        guard let payload = try? ChildCandidateAvailableMessage(
            sequence: hierarchyState.nextCandidateOfferSequence,
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
        // The parent session (or the runtime) may have ended while the send
        // was suspended; its end reset the last-offered mark, which a late
        // write would re-set against the next session.
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyState.hierarchyRecords[context.peer.key]?.session?.sessionID
                == context.peer.sessionID else { return }
        if case .enqueued = sent {
            hierarchyState.lastOfferedCandidateCID = childCID
            SyncTrace.log("candidate offered \(hierarchyState.nextCandidateOfferSequence): h=\(candidate.block.height) for tip=\(context.tipCID.prefix(12))")
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
        guard hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyState.hierarchyRecords[peer.key]?.role == .parent else { return nil }
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
            // A full inbox would refuse the evidence after its fetch: it
            // waits for room without costing the parent a fetch. A refused
            // scan resumes on the capacity callback
            // (`parentEvidenceCapacityBecameAvailable`, then a new round).
            if result == .handled,
               (try? await process.store.parentEvidenceInboxHasCapacity()) == false {
                result = .backpressured
            }
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
        token: LifetimeToken,
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
            let waiter = ChildEvidenceReadyWaiter(
                sessionID: peer.sessionID,
                continuation: continuation
            )
            // A session that already ended has no record to wait in.
            if hierarchyState.hierarchyRecords.update(session: peer, {
                $0.evidence.waiters.append(waiter)
            }) == nil {
                continuation.resume(returning: false)
            }
        }
    }

    private func markChildEvidenceReady(_ peer: AuthenticatedPeer) {
        let waiters = hierarchyState.hierarchyRecords.update(session: peer) {
            record -> [ChildEvidenceReadyWaiter] in
            record.evidence.ready = true
            let waiters = record.evidence.waiters
            record.evidence.waiters = []
            return waiters
        } ?? []
        for waiter in waiters {
            waiter.continuation.resume(
                returning: waiter.sessionID == peer.sessionID
            )
        }
    }

    private func cancelChildEvidenceReadyWaiters(for peerKey: PeerKey) {
        let waiters = hierarchyState.hierarchyRecords.updateExisting(peerKey) {
            record -> [ChildEvidenceReadyWaiter] in
            record.evidence.clearFences()
            let waiters = record.evidence.waiters
            record.evidence.waiters = []
            return waiters
        } ?? []
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    func canServeHierarchyContent(to peer: AuthenticatedPeer) -> Bool {
        runtimeGeneration != 0
            && hierarchyState.hierarchyRecords[peer.key]?.role != nil
            && hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
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
            return hierarchyState.hierarchyRecords[key]?.session
        }
        for peer in bootstrappingPeers {
            hierarchyState.hierarchyRecords.update(session: peer) { record in
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
            return hierarchyState.hierarchyRecords[key]?.session
        }
        for peer in bootstrappingPeers + readyPeers {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
                if !isChildEvidenceReady(peer.key) {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                continue
            }
            let result = await sendToHierarchyPeer(
                peer,
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
                hierarchyState.hierarchyRecords.update(session: peer) { $0.refusedHint = nil }
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
                hierarchyState.hierarchyRecords.update(session: peer) { $0.refusedHint = payload }
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
        guard let count = hierarchyState.hierarchyRecords[peer.key]?.evidence
            .publicationsInFlight(for: sessionID) else {
            return
        }
        if !permitsCleanup {
            SyncTrace.log("child evidence publication to \(peer.key.hex.prefix(8)) failed: session no longer becomes ready")
            hierarchyState.hierarchyRecords.update(session: peer) {
                $0.evidence.markPublicationFailed(for: sessionID)
            }
        }
        if count == 1 {
            hierarchyState.hierarchyRecords.update(session: peer) {
                $0.evidence.setPublicationsInFlight(0, for: sessionID)
            }
            if permitsCleanup,
               hierarchyState.hierarchyRecords[peer.key]?.evidence
                .publicationFailed(for: sessionID) != true,
               hierarchyState.hierarchyRecords[peer.key]?.evidence
                .indexComplete(for: sessionID) == true,
               hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID {
                markChildEvidenceReady(peer)
            }
        } else {
            hierarchyState.hierarchyRecords.update(session: peer) {
                $0.evidence.setPublicationsInFlight(count - 1, for: sessionID)
            }
        }
    }

    private func completeChildEvidenceIndex(for peer: AuthenticatedPeer) {
        // Only the live session's fence: this runs after the index serve's
        // suspensions, and a fence for an ended session could never be
        // read again (nor could it mark anything ready).
        let sessionID = peer.sessionID
        guard hierarchyState.hierarchyRecords.update(session: peer, {
            $0.evidence.markIndexComplete(for: sessionID)
        }) != nil else { return }
        if hierarchyState.hierarchyRecords[peer.key]?.evidence
            .publicationsInFlight(for: sessionID) == nil,
           hierarchyState.hierarchyRecords[peer.key]?.evidence
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

    /// Ends the key's hierarchy authorization, given the record the caller
    /// took out: by session when a session ended (`remove(_:ifBoundTo:)`,
    /// so a newer session's record and state are never touched), by key
    /// only when a connect replaces the key's session.
    func clearHierarchyAuthorization(
        for key: PeerKey,
        removed: HierarchyPeerRecord?
    ) {
        removed?.helloDeadline?.task.cancel()
        cancelParentEvidence(for: key)
        for waiter in removed?.evidence.waiters ?? [] {
            waiter.continuation.resume(returning: false)
        }
        let removedRole = removed?.role
        Self.pruneChildPeerRotations(
            &hierarchyState.childPeerRotation,
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
            hierarchyState.backfilledChildDirectories.remove(directory)
        }
        if case .parent? = removedRole {
            purgeHierarchyRequests()
        }
        if hierarchyState.receivedParentTip?.peer.key == key {
            hierarchyState.receivedParentTip = nil
            hierarchyState.lastOfferedCandidateCID = nil
        }
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
            // Not retained: the scan re-serves this page next round.
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
            }
        }
    }

    /// Seam: an import could not decide on a fact the parent will send.
    /// Its evidence leaves the inbox for the in-memory orphan pool, which
    /// keeps its place in the parent's index; an orphan already pooled (its
    /// block imported again from the fetcher's own attempt) takes the new
    /// retry. An orphan fetched again from the pool that is still undecided
    /// with no specific trigger is dropped — lost by design, recoverable by
    /// asking the parent for it (`requestParentEvidence`). Room made works as
    /// a decision's does.
    func parentEvidenceOrphaned(
        childCID: String,
        rootCID: String,
        retry: ParentEvidenceOrphans.Retry,
        generation: UInt64,
        process: ChainProcess
    ) async {
        let orphaned = (try? await process.orphanParentEvidence(
            childCID: childCID, rootCID: rootCID
        )) ?? []
        guard isCurrentRuntime(generation: generation, process: process) else { return }
        let key = ParentEvidenceOrphans.Key(childCID: childCID, rootCID: rootCID)
        let refetched = hierarchyState.refetchedOrphans.remove(key) != nil
        if retry == .nextTrigger, refetched {
            hierarchyState.parentEvidenceOrphans.remove(key)
        } else if orphaned.isEmpty {
            hierarchyState.parentEvidenceOrphans.updateRetry(key, retry)
        } else {
            for entry in orphaned {
                hierarchyState.parentEvidenceOrphans.insert(
                    sourceID: entry.sourceID, summary: entry.summary, retry: retry
                )
            }
        }
        guard !orphaned.isEmpty,
              (try? await process.store.parentEvidenceInboxHasCapacity()) == true,
              isCurrentRuntime(generation: generation, process: process)
        else { return }
        parentEvidenceCapacityBecameAvailable()
        await requestEvidenceIndex(generation: generation, process: process)
    }

    /// Seam: a parent-backed import decided its block; its orphan, if the
    /// fetcher's own attempt decided it, is gone.
    func parentEvidenceDecided(childCID: String, rootCID: String) {
        let key = ParentEvidenceOrphans.Key(childCID: childCID, rootCID: rootCID)
        hierarchyState.parentEvidenceOrphans.remove(key)
        hierarchyState.refetchedOrphans.remove(key)
    }

    /// Seam: the one retry trigger. A block was accepted (`accepted`, by
    /// import or outside it through `predecessorConnectedOutOfBand`): the
    /// orphans behind it, and those whose time has come, are released. The
    /// parent said hello (`accepted` nil): every orphan whose retry is met
    /// (predecessor accepted, time reached, not served before, or any
    /// other) is released.
    /// Orphans whose block the fetcher still holds stay pooled (its attempt
    /// decides them). Exactly the released orphans are fetched again from
    /// the parent by their place in its index — never a rescan — each on its
    /// own, so one the parent cannot serve holds up none of the others.
    func parentEvidenceRetryTrigger(
        accepted acceptedCID: String?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else { return }
        var accepted: Set<String> = []
        if let acceptedCID {
            accepted.insert(acceptedCID)
        } else {
            hierarchyState.refetchedOrphans.removeAll()
            var predecessors: Set<String> = []
            for orphan in hierarchyState.parentEvidenceOrphans.entries.values {
                if case .predecessor(let predecessorCID) = orphan.retry {
                    predecessors.insert(predecessorCID)
                }
            }
            for predecessorCID in predecessors
            where await process.hasAcceptedBlock(predecessorCID) {
                accepted.insert(predecessorCID)
            }
        }
        guard isCurrentRuntime(generation: generation, process: process),
              let parent = configuredParentPeer() else { return }
        let now = ParentEvidenceOrphans.clock()
        let atHello = acceptedCID == nil
        if atHello {
            hierarchyState.parentHelloReleaseSession = parent.sessionID
        }
        var held: Set<String> = []
        for orphan in hierarchyState.parentEvidenceOrphans.entries.values
        where fetcherHasParentAttempt(orphan.summary.childCID) {
            held.insert(orphan.summary.childCID)
        }
        let released = hierarchyState.parentEvidenceOrphans.release { orphan in
            guard !held.contains(orphan.summary.childCID) else { return false }
            switch orphan.retry {
            case .nextTrigger: return atHello
            case .notBefore(let time): return time <= now
            case .unservedUntil(let time): return atHello || time <= now
            case .predecessor(let predecessorCID): return accepted.contains(predecessorCID)
            }
        }
        guard !released.isEmpty else { return }
        SyncTrace.log("orphaned parent evidence released: \(released.map { $0.summary.childCID.prefix(12) })")
        Task { [weak self] in
            await self?.refetchReleasedOrphans(
                released, from: parent, generation: generation, process: process
            )
        }
    }

    /// Seam: the inbox has room again after a refetch stopped at a full
    /// one. Exactly the orphans that refetch put back are fetched again;
    /// no other orphan is released and no refetch mark is cleared (only
    /// the parent's hello does that), so room freed by the refetches'
    /// own imports cannot cycle them.
    func parentEvidenceRoomResumed(generation: UInt64, process: ChainProcess) async {
        guard isCurrentRuntime(generation: generation, process: process),
              let parent = configuredParentPeer() else { return }
        let waiting = hierarchyState.orphansAwaitingRoom
        hierarchyState.orphansAwaitingRoom.removeAll()
        var held: Set<String> = []
        for orphan in hierarchyState.parentEvidenceOrphans.entries.values
        where fetcherHasParentAttempt(orphan.summary.childCID) {
            held.insert(orphan.summary.childCID)
        }
        let released = hierarchyState.parentEvidenceOrphans.release { orphan in
            !held.contains(orphan.summary.childCID) && waiting.contains(
                ParentEvidenceOrphans.Key(
                    childCID: orphan.summary.childCID, rootCID: orphan.summary.rootCID
                )
            )
        }
        guard !released.isEmpty else { return }
        SyncTrace.log("orphaned parent evidence resumed with room: \(released.map { $0.summary.childCID.prefix(12) })")
        await refetchReleasedOrphans(
            released, from: parent, generation: generation, process: process
        )
    }

    /// Fetches released orphans again, one by one. The parent unable to
    /// serve one puts it back in the pool until the request timeout passes
    /// (its own trigger may already have fired) or the parent's next hello:
    /// a request cut short by its session ending can report the parent
    /// unable to serve before this runtime learns the session ended, and
    /// then only that hello follows. Its session ending puts it
    /// and the rest back for the reconnect's hello (or the request timeout),
    /// or, when that hello has already released the pool, fetches them from
    /// the new session at once;
    /// a full inbox puts the rest back and waits for the capacity callback,
    /// which resumes exactly those. Only a malformed answer drops an
    /// orphan. An orphan is marked refetched only once its import is
    /// queued, so a refetch that queued none leaves no mark behind.
    private func refetchReleasedOrphans(
        _ released: [ParentEvidenceOrphans.Orphan],
        from parent: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        for (index, orphan) in released.enumerated() {
            guard isCurrentRuntime(generation: generation, process: process) else { return }
            let result = await recoverParentEvidence(
                orphan.summary,
                sourceID: orphan.sourceID,
                advanceScan: false,
                refetchedOrphan: true,
                from: parent,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else { return }
            let sessionCurrent =
                hierarchyState.hierarchyRecords[parent.key]?.session?.sessionID == parent.sessionID
            switch result {
            case .handled:
                continue
            case .backpressured:
                let waiting = Array(released[index...])
                repool(waiting)
                for orphan in waiting {
                    hierarchyState.orphansAwaitingRoom.insert(ParentEvidenceOrphans.Key(
                        childCID: orphan.summary.childCID, rootCID: orphan.summary.rootCID
                    ))
                }
                // Room freed while this refetch was suspended found none
                // waiting: its callback is taken here instead.
                if (try? await process.store.parentEvidenceInboxHasCapacity()) == true,
                   isCurrentRuntime(generation: generation, process: process) {
                    parentEvidenceCapacityBecameAvailable()
                }
                return
            case .unavailable where !sessionCurrent, .failed where !sessionCurrent:
                let rest = Array(released[index...])
                // The session that could not serve them ended. A newer one
                // whose hello already released the pool, while these were
                // out of it, owes them that release: fetched from it now.
                // Otherwise the hello to come releases them, or the
                // request timeout does.
                if let current = configuredParentPeer(),
                   current.sessionID != parent.sessionID,
                   hierarchyState.parentHelloReleaseSession == current.sessionID {
                    await refetchReleasedOrphans(
                        rest, from: current, generation: generation, process: process
                    )
                } else {
                    repool(rest, retry: unservedRetry())
                }
                return
            case .unavailable:
                repool([orphan], retry: unservedRetry())
            case .failed:
                continue
            }
        }
    }

    /// An orphan the parent did not serve: the next hello or, failing one,
    /// the request timeout.
    private func unservedRetry() -> ParentEvidenceOrphans.Retry {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        return .unservedUntil(
            ParentEvidenceOrphans.clock() + Int64(timeout / .milliseconds(1))
        )
    }

    /// `retry` nil keeps each orphan's own.
    private func repool(
        _ orphans: [ParentEvidenceOrphans.Orphan],
        retry: ParentEvidenceOrphans.Retry? = nil
    ) {
        for orphan in orphans {
            hierarchyState.parentEvidenceOrphans.insert(
                sourceID: orphan.sourceID,
                summary: orphan.summary,
                retry: retry ?? orphan.retry
            )
        }
    }

    /// Bitcoin's getdata for parent evidence: a child block this node holds
    /// without its parent's evidence (reached by the predecessor walk, its
    /// orphan evicted or lost with a restart) is asked of the configured
    /// parent by CID. The parent answers from its durable issued index with
    /// the same live hint a carry sends, which the evidence lane recovers.
    /// Fire and forget, bounded like the overlay locate it runs beside: a
    /// parent that does not route the topic stays silent.
    func requestParentEvidence(
        for childCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              let parent = configuredParentPeer(),
              hierarchyState.hierarchyRecords[parent.key]?.role == .parent,
              let payload = try? ParentEvidenceRequestMessage(
                requestID: makeRequestID(),
                childPath: configuration.chainPath,
                childCID: childCID
              ).encoded() else { return }
        let sent = await hierarchy.sendMessage(
            to: parent,
            topic: NodeNetworkTopic.parentEvidenceRequest,
            payload: payload
        )
        SyncTrace.log("parent-evidence-request \(childCID.prefix(12)) sent=\(sent)")
    }

    private func recoverParentEvidence(
        _ summary: IssuedChildEvidenceSummary,
        sourceID: String,
        advanceScan: Bool,
        refetchedOrphan: Bool = false,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> ParentEvidenceResult {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyState.hierarchyRecords[peer.key]?.role == .parent else {
            return .failed
        }
        // A block the fetcher already holds on the parent's word is not
        // fetched again: its attempt decides it.
        if fetcherHasParentAttempt(summary.childCID) {
            return .handled
        }
        // A full inbox would refuse the evidence after its fetch: it waits
        // for room without costing the parent a fetch, and resumes on the
        // capacity callback.
        if (try? await process.store.parentEvidenceInboxHasCapacity()) == false {
            return .backpressured
        }
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyState.hierarchyRecords[peer.key]?.role == .parent else {
            return .failed
        }
        let lease = EvidenceVolumeLease(
            plane: .hierarchy,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if sessionLeases.activeEvidenceVolumes.contains(lease) { return .handled }
        // Wait for a slot, woken by its release (a timeout re-checks the
        // session). The stale and lease checks also pass on the first step:
        // both were just made above with no suspension between.
        while sessionLeases.activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates {
            await waitForEvidenceVolumeSlot(
                timeout: planeConfigurations.hierarchy.requestTimeout,
                generation: generation
            )
            if Task.isCancelled { return .handled }
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
               hierarchyState.hierarchyRecords[peer.key]?.role == .parent else {
                return .failed
            }
            if sessionLeases.activeEvidenceVolumes.contains(lease) { return .handled }
        }
        sessionLeases.activeEvidenceVolumes.insert(lease)
        defer { releaseEvidenceVolume(lease) }
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
                    && hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
                    && hierarchyState.hierarchyRecords[peer.key]?.role == .parent
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
              hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              hierarchyState.hierarchyRecords[peer.key]?.role == .parent else {
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
        // A refetched orphan is marked once its import is queued: that
        // import, still undecided with no specific trigger, drops it.
        let refetchKey = ParentEvidenceOrphans.Key(
            childCID: summary.childCID, rootCID: summary.rootCID
        )
        if refetchedOrphan, isCurrentRuntime(generation: generation, process: process) {
            hierarchyState.refetchedOrphans.insert(refetchKey)
        }
        let enqueued = await enqueueInboxParentCandidate(
            // Weighed, like every network-sourced block: the verified proof is
            // all the weighed tier needs, so the block enters fork choice with
            // its work at once and is executed when the chain would step into
            // it. Admitted eagerly it would first wait on a continuity fact —
            // a deferral whose only memory was this process.
            CandidateSeed(
                blockCID: summary.childCID,
                package: gated,
                weighed: true,
                fromParent: true
            ),
            generation: generation,
            process: process
        )
        if refetchedOrphan, !enqueued,
           isCurrentRuntime(generation: generation, process: process) {
            hierarchyState.refetchedOrphans.remove(refetchKey)
        }
        return enqueued ? .handled : .failed
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
        guard hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
              let role = hierarchyState.hierarchyRecords[peer.key]?.role else { return }

        switch (message.topic, role) {
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
                      hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID,
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
            let previous = hierarchyState.runReportApplyTail
            hierarchyState.runReportApplyTail = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, let self,
                      await self.isCurrentRuntime(
                        generation: generation, process: process
                      ) else { return }
                try? await chain.applyParentRunReport(report.report)
            }

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

        case (NodeNetworkTopic.parentEvidenceRequest, .child(let childPath)):
            // Getdata for one carried block's evidence: answered from the
            // durable issued index with the live hint a carry sends, or not
            // at all. One indexed read per request.
            guard let directory = childPath.last,
                  let request = try? ParentEvidenceRequestMessage.decoded(
                    message.payload
                  ), request.childPath == childPath,
                  let issued = try? await process.store.issuedChildEvidenceSummary(
                    childCID: request.childCID, directory: directory
                  ),
                  isCurrentRuntime(generation: generation, process: process),
                  let payload = try? ChildEvidenceAvailableMessage(
                    childPath: childPath,
                    sourceID: issued.sourceID,
                    ordinal: issued.summary.ordinal,
                    childCID: request.childCID,
                    rootCID: issued.summary.rootCID,
                    attachmentCID: issued.summary.attachmentCID
                  ).encoded()
            else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )

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
                  ), let pending = hierarchyState.pendingEvidenceIndexes[response.requestID],
                  pending.peer.sessionID == peer.sessionID,
                  response.childPath == pending.request.childPath,
                  (response.sourceID == pending.request.sourceID
                    ? response.cursor == pending.request.cursor
                        && pending.request.through.map({
                            response.through == $0
                        }) ?? true
                    : response.cursor == 0)
            else { return }
            hierarchyState.pendingEvidenceIndexes.removeValue(forKey: response.requestID)
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
            if let current = hierarchyState.receivedParentTip,
               current.peer.sessionID == peer.sessionID,
               context.sequence <= current.sequence {
                SyncTrace.log("parent tip dropped: stale sequence \(context.sequence) <= \(current.sequence)")
                return
            }
            hierarchyState.receivedParentTip = ReceivedParentTipContext(
                sequence: context.sequence,
                peer: peer,
                tipCID: context.tipCID,
                tip: tip,
                rewards: context.rewards,
                minimumWork: context.minimumWork
            )
            SyncTrace.log("parent tip \(context.sequence): h=\(tip.height) tip=\(context.tipCID.prefix(12)) rewards=\(context.rewards.count)")
            scheduleCandidateOffer(generation: generation, process: process)

        case (NodeNetworkTopic.childCandidateAvailable, .child(let childPath)):
            // Only a child this chain has wired in, and only once there is a
            // context to build against: a legitimate child pushes for a
            // context it received. Nothing is decoded for anyone else.
            guard isChildEvidenceReady(peer.key),
                  hierarchyState.parentTipContext != nil else {
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
            if let cached = hierarchyState.hierarchyRecords[peer.key]?.offer,
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
                  hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
                return
            }
            if let cached = hierarchyState.hierarchyRecords[peer.key]?.offer,
               cached.sessionID == peer.sessionID,
               offer.sequence <= cached.sequence {
                SyncTrace.log("child candidate from \(childPath.joined(separator: "/")) dropped: stale sequence")
                return
            }
            hierarchyState.hierarchyRecords.update(session: peer) {
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
        removeHierarchyHelloDeadline(for: peer.key, session: peer.sessionID)?.task.cancel()
        if let existing = hierarchyState.hierarchyRecords[peer.key]?.role {
            if existing != role {
                await hierarchy.disconnectSession(ifCurrent: peer)
                return
            }
        }
        if hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID != peer.sessionID {
            hierarchyState.hierarchyRecords.update(peer.key) { $0.evidence.ready = false }
            cancelChildEvidenceReadyWaiters(for: peer.key)
        }
        hierarchyState.hierarchyRecords.update(peer.key) {
            $0.role = role
            $0.session = peer
        }
        if case .child = role {
            // Tolerant ingest of the child's self-declared read URL: invalid
            // or absent just isn't carried (never a session cost).
            if let url = normalizedPublicReadURL(remote.publicReadURL) {
                hierarchyState.hierarchyRecords.update(peer.key) { $0.declaredReadURL = url }
            } else {
                hierarchyState.hierarchyRecords.update(peer.key) { $0.declaredReadURL = nil }
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
              hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID else {
            return
        }
        if case .parent = role {
            // The run re-ask follows the evidence round this starts, once
            // the blocks it brings are held here (`scheduleParentEvidencePage`).
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
            await parentEvidenceRetryTrigger(
                accepted: nil,
                generation: generation,
                process: process
            )
        } else if case .child(let childPath) = role {
            guard await waitForChildEvidenceReady(peer: peer) else {
                // Only this session ends: a reconnect that replaced it while
                // the wait was suspended keeps its record and hello deadline.
                if let removed = hierarchyState.hierarchyRecords.remove(
                    peer.key, ifBoundTo: peer.sessionID
                ) {
                    clearHierarchyAuthorization(
                        for: peer.key, removed: removed
                    )
                }
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

    /// Seam: overlay hellos and admissions call this too. A stale caller
    /// (a generation that has ended) schedules nothing: it would otherwise
    /// claim the one recovery slot for its generation and swallow the
    /// current generation's schedules.
    func scheduleChildProofRecovery(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard isCurrentRuntime(generation: generation, process: process) else { return }
        // Teardown empties the slot, so a task it holds is this generation's.
        guard hierarchyState.childProofRecoveryTask.isEmpty else {
            hierarchyState.childProofRecoveryNeedsRefresh = true
            return
        }
        hierarchyState.childProofRecoveryNeedsRefresh = false
        hierarchyState.childProofRecoveryTask.start { token in
            Task { [weak self] in
                await self?.recoverChildProofs(
                    token: token,
                    generation: generation,
                    process: process
                )
            }
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
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer {
            if hierarchyState.childProofRecoveryTask.clear(token) {
                hierarchyState.childProofRecoveryNeedsRefresh = false
            }
        }
        // This pass still owns the recovery slot and its generation runs.
        func current() -> Bool {
            !Task.isCancelled
                && hierarchyState.childProofRecoveryTask.holds(token)
                && isCurrentRuntime(generation: generation, process: process)
        }
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
        where !hierarchyState.backfilledChildDirectories.contains(directory) {
            guard current() else { return }
            await process.backfillChildProofRoutes(directory: directory)
            // Mark only after completion, so an interrupted backfill retries on
            // the next recovery pass rather than being skipped as done; and
            // only while this pass is current, or a restart's set would
            // record a backfill it never ran.
            guard current() else { return }
            hierarchyState.backfilledChildDirectories.insert(directory)
        }
        repeat {
            // The refresh flag is read and reset only by the pass that owns
            // the slot: a stale pass would swallow the current one's.
            guard current() else { return }
            hierarchyState.childProofRecoveryNeedsRefresh = false
            await retryRecoveredChildProofs(
                generation: generation,
                process: process
            )
            guard current() else { return }
            await retryCurrentTipChildProofs(
                generation: generation,
                process: process
            )
        } while current() && hierarchyState.childProofRecoveryNeedsRefresh
    }

    func scheduleHierarchyHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        removeHierarchyHelloDeadline(for: peer.key, session: nil)?.task.cancel()
        let token = LifetimeToken.next()
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
        hierarchyState.hierarchyRecords.update(peer.key) {
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
            deadlineSessionID: hierarchyState.hierarchyRecords[peer.key]?.helloDeadline?.sessionID
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
        token: LifetimeToken
    ) async {
        guard isCurrentGeneration(generation),
            isRunning,
            hierarchyState.hierarchyRecords[peer.key]?.helloDeadline?.token == token,
            hierarchyState.hierarchyRecords[peer.key]?.helloDeadline?.sessionID == peer.sessionID,
            hierarchyState.hierarchyRecords[peer.key]?.role == nil
        else { return }
        removeHierarchyHelloDeadline(for: peer.key, session: peer.sessionID)
        await hierarchy.recycleSession(ifCurrent: peer)
    }

    /// Verify-not-trust gate for a self-contained child genesis: whether the
    /// co-hosted parent level still anchors exactly this genesis CID for
    /// this chain's directory (a parent reorg during the fetch may have
    /// moved it) and recorded it bound to the empty parent state. Local
    /// reads.
    nonisolated func parentRecordedChildGenesis(
        _ childGenesisCID: String
    ) async -> Bool {
        let directory = configuration.address.directory
        guard let parentLevel,
              await parentLevel.anchoredGenesisCID(directory: directory)
                == childGenesisCID
        else { return false }
        return await parentLevel.recordedGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID
        ) != nil
    }

    /// One trigger of `activateGenesisIfRecorded`: this level's start, a
    /// parent tip change, a child overlay hello, or the slow
    /// retry after a failed fetch or confirm. One
    /// attempt runs at a time; a trigger that lands during an attempt runs
    /// one more after it, so no trigger is lost.
    func triggerGenesisActivation() {
        guard isRunning, parentLevel != nil, let process else { return }
        let generation = runtimeGeneration
        hierarchyState.genesisActivationRequested = true
        hierarchyState.genesisActivationTask.start { token in
            Task { [weak self] in
                await self?.runGenesisActivation(
                    token: token, generation: generation, process: process
                )
            }
        }
    }

    private func runGenesisActivation(
        token: LifetimeToken,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { hierarchyState.genesisActivationTask.clear(token) }
        while hierarchyState.genesisActivationRequested, !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process) {
            hierarchyState.genesisActivationRequested = false
            await activateGenesisIfRecorded(
                generation: generation, process: process
            )
        }
    }

    /// A same-chain overlay peer completed its hello. A child still
    /// awaiting its genesis may fetch it from this peer, seeded or not (a
    /// seed that is not the anchored genesis falls back to the fetch). On an
    /// active chain the attempt returns at once.
    func overlayPeerMayProvideGenesis() {
        triggerGenesisActivation()
    }

    /// Where a deployer seeds this node with its child genesis. A seeded
    /// node rebuilds its genesis; an adopting node fetches it.
    private nonisolated var genesisSeedURL: URL {
        configuration.storagePath.appendingPathComponent("child-genesis.json")
    }

    /// A hosted child with no genesis activates the one its parent anchored:
    /// read the CID the parent committed for this directory, rebuild the
    /// genesis from the deployer's seed when this node holds one, and fetch
    /// it through the child overlay when it holds none or the seed is
    /// unreadable or rebuilds to another CID (the fetch is bound to the
    /// anchored CID). Admit it once the parent confirms it. Nothing here
    /// waits: no anchor yet leaves the chain awaiting the next trigger, and
    /// an anchored genesis that could not be fetched or confirmed also arms
    /// the one slow retry, for a parent too quiet to trigger again.
    private func activateGenesisIfRecorded(
        generation: UInt64,
        process: ChainProcess
    ) async {
        let directory = configuration.address.directory
        guard let parentLevel, await process.awaitsGenesis,
              let genesisCID = await parentLevel.anchoredGenesisCID(
                  directory: directory
              ),
              !Task.isCancelled,
              isCurrentRuntime(generation: generation, process: process)
        else { return }
        let confirm: @Sendable (String) async -> Bool = { [weak self] cid in
            await self?.parentRecordedChildGenesis(cid) ?? false
        }
        var outcome = ChildGenesisActivation.notAnchoredGenesis
        if FileManager.default.fileExists(atPath: genesisSeedURL.path) {
            if let seed = try? JSONDecoder().decode(
                ChildGenesisSeed.self, from: Data(contentsOf: genesisSeedURL)
            ) {
                outcome = (try? await process.activateChildGenesis(
                    anchoredCID: genesisCID,
                    from: .seed(seed),
                    confirmParentRecordedGenesis: confirm
                )) ?? .unconfirmed
            } else {
                SyncTrace.log(
                    "child-genesis seed unreadable directory=\(directory);"
                        + " fetching the anchored genesis"
                )
            }
        }
        if outcome == .notAnchoredGenesis, !Task.isCancelled {
            outcome = (try? await remoteContentSource.withRoot(
                genesisCID
            ) { session in
                try await process.activateChildGenesis(
                    anchoredCID: genesisCID,
                    from: .fetch(session),
                    confirmParentRecordedGenesis: confirm
                )
            }) ?? .notAnchoredGenesis
        }
        SyncTrace.log(
            "child-genesis \(outcome) directory=\(directory) cid=\(genesisCID)"
        )
        guard isCurrentRuntime(generation: generation, process: process)
        else { return }
        switch outcome {
        case .activated:
            hierarchyState.genesisRetryTask.cancel()
        case .notAnchoredGenesis, .unconfirmed:
            armGenesisRetry(generation: generation)
            return
        case .notAwaiting:
            return
        }
        // The genesis bootstrapped to active OUT OF BAND (not via candidate
        // admission), so it never fired its one-shot connect signal. Wake the
        // successors that parked behind it while awaitingGenesis, or the chain
        // above the genesis stays orphaned at height 0.
        await predecessorConnectedOutOfBand(genesisCID)
        await chain?.genesisActivatedOutOfBand()
        await requestEvidenceIndex(generation: generation, process: process)
    }

    /// The one slow retry of a genesis that was anchored but could not be
    /// fetched or confirmed (say an adopting node asked before any provider
    /// held it): a quiet parent may not move its tip again. At most one
    /// timer is armed; stop cancels and joins it.
    private func armGenesisRetry(generation: UInt64) {
        let delay = Self.genesisRetryNanoseconds
        hierarchyState.genesisRetryTask.start { token in
            Task { [weak self] in
                guard await Timers.sleep(nanoseconds: delay) else { return }
                await self?.genesisRetryFired(token: token, generation: generation)
            }
        }
    }

    private func genesisRetryFired(token: LifetimeToken, generation: UInt64) {
        guard hierarchyState.genesisRetryTask.clear(token),
              isCurrentGeneration(generation)
        else { return }
        triggerGenesisActivation()
    }

    /// Drops the hierarchy requests a gone parent session can never answer.
    func purgeHierarchyRequests() {
        // Only the parent sends these requests' answers.
        hierarchyState.pendingEvidenceIndexes.removeAll()
    }

    /// Seam: the parent-evidence inbox has room again; the configured
    /// parent's evidence session may resume, and a scan or an orphan
    /// refetch a full inbox stopped runs again.
    func parentEvidenceCapacityBecameAvailable() {
        if let parent = configuredParentPeer(),
           let session = parentEvidenceSession(for: parent) {
            let scanStopped = parentEvidence.isBackpressured(session)
            parentEvidence.capacityBecameAvailable(for: session)
            let orphansWaited = !hierarchyState.orphansAwaitingRoom.isEmpty
            if scanStopped || orphansWaited, let process {
                let generation = runtimeGeneration
                Task { [weak self] in
                    if scanStopped {
                        await self?.requestEvidenceIndex(
                            generation: generation, process: process
                        )
                    }
                    if orphansWaited {
                        await self?.parentEvidenceRoomResumed(
                            generation: generation, process: process
                        )
                    }
                }
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
            return hierarchyState.hierarchyRecords[key]?.session
        }
        for peer in children {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchyState.hierarchyRecords[peer.key]?.session?.sessionID == peer.sessionID
            else { continue }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.parentRunReport,
                payload: payload
            )
        }
    }

    /// Returns whether a request was sent: none is while a round is in
    /// flight or starting, before a parent session exists, or on a root
    /// chain. A page refused because a round is in flight is superseded by
    /// it: that round scans from the durable cursor.
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
            ), !configuration.address.isNexus
        else { return false }
        guard hierarchyState.pendingEvidenceIndexes.isEmpty,
              !hierarchyState.evidenceRoundStarting,
              let parent = configuredParentPeer()
        else { return false }
        hierarchyState.evidenceRoundStarting = true
        let durableCursor: ParentEvidenceScanCursor
        if let sourceID, let cursor {
            durableCursor = ParentEvidenceScanCursor(
                sourceID: sourceID,
                ordinal: cursor
            )
        } else {
            let persisted = try? await fence.process
                .store.parentEvidenceScanCursor()
            // A stop while the cursor was read reset the round flags; a
            // late write here would take the restart's.
            guard isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            ) else { return false }
            guard let persisted else {
                hierarchyState.evidenceRoundStarting = false
                return false
            }
            durableCursor = persisted
        }
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            sourceID: durableCursor.sourceID,
            cursor: durableCursor.ordinal,
            through: through
        )
        guard let payload = try? request.encoded() else {
            hierarchyState.evidenceRoundStarting = false
            return false
        }
        hierarchyState.pendingEvidenceIndexes[request.requestID] = .init(
            peer: parent,
            request: request
        )
        hierarchyState.evidenceRoundStarting = false
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
            hierarchyState.pendingEvidenceIndexes.removeValue(forKey: request.requestID)
            return false
        }
        if result != .notConnected {
            if hierarchyState.pendingEvidenceIndexes[request.requestID] != nil {
                scheduleEvidenceIndexTimeout(
                    request.requestID,
                    generation: fence.generation
                )
            }
            return true
        } else {
            hierarchyState.pendingEvidenceIndexes.removeValue(forKey: request.requestID)
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
              let request = hierarchyState.pendingEvidenceIndexes.removeValue(
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
            start: hierarchyState.childPathRotation,
            limit: min(pathKeys.count, Self.maximumDirectChildren)
        )
        hierarchyState.childPathRotation = pathRotation.next

        var selectedPaths: [(path: [String], peers: [PeerKey])] = []
        for pathIndex in pathRotation.indices {
            let pathKey = pathKeys[pathIndex]
            guard let path = paths[pathKey] else { continue }
            let keys = peers[pathKey]!.sorted { $0.hex < $1.hex }
            let start = (hierarchyState.childPeerRotation[pathKey] ?? 0) % keys.count
            let rotation = Self.rotatedPeerIndices(
                peerCount: keys.count,
                start: start,
                limit: min(Self.maximumPeersPerChildPath, keys.count)
            )
            selectedPaths.append((path, rotation.indices.map { keys[$0] }))
            hierarchyState.childPeerRotation[pathKey] = rotation.next
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
            start: hierarchyState.childProofPathRotation,
            limit: min(directories.count, Self.maximumDirectChildren)
        )
        hierarchyState.childProofPathRotation = rotation.next
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

    /// Seam: whether any wired child declared a public read URL.
    var anyChildDeclaredReadURL: Bool {
        hierarchyState.hierarchyRecords.records.values.contains { $0.declaredReadURL != nil }
    }

    /// Seam: this node's own self-description for `genesisCID`: its configured
    /// public read URL when that is its own chain's genesis, plus the URLs its
    /// wired children declared in their hierarchy hellos when the CID is one
    /// this node anchored for a child directory. Deduped, bounded.
    func declaredReadURLs(
        genesisCID: String,
        process: ChainProcess
    ) async -> [String] {
        var urls: [String] = []
        if let own = configuration.publicReadURL,
           await process.canonicalBlockCID(atHeight: 0) == genesisCID {
            urls.append(own)
        }
        // One sample of the wired children, taken before the resolve suspends
        // and iterated below: the answer then describes a single consistent
        // moment. Reading live hierarchy roles after the suspension instead
        // would mix a child admitted mid-resolve into a lookup that never
        // asked for its directory, and drop it anyway. It is served from the
        // next ask on.
        let wiredChildren = hierarchyRoles.compactMap { key, role -> (PeerKey, String)? in
            guard case .child(let path) = role, let directory = path.last else {
                return nil
            }
            return (key, directory)
        }
        let anchored = await process.anchoredChildGenesisCIDs(
            directories: Set(wiredChildren.map(\.1))
        )
        let directories = Set(
            anchored.filter { $0.value == genesisCID }.map(\.key)
        )
        if !directories.isEmpty {
            // Shuffled, not dictionary order: wired-child roles are
            // permissionless, and a stable iteration order would let a batch
            // of sybil declarants shadow the honest child's URL from every
            // answer for the process lifetime. Random selection keeps every
            // declarant reachable across repeated asks.
            for (key, directory) in wiredChildren.shuffled() {
                guard directories.contains(directory),
                      let url = hierarchyState.hierarchyRecords[key]?.declaredReadURL,
                      !urls.contains(url) else { continue }
                urls.append(url)
                if urls.count >= ReadEndpointResponseMessage.maximumURLs {
                    break
                }
            }
        }
        return Array(urls.prefix(ReadEndpointResponseMessage.maximumURLs))
    }
}
