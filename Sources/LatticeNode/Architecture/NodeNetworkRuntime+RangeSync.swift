import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    // MARK: - Forward-apply range sync
    //
    // Catch up to a heavier peer by paging its MAIN chain FORWARD from our own
    // frontier and applying each bounded page through the ordinary candidate
    // worker. Blocks arrive genesis-ward and admit parent-first
    // (appendCanonicalTip), so nothing is retained — the working set is a small,
    // fixed window regardless of chain depth (no depth ceiling, no gap buffer).
    // Pages are pipelined by block CID and bounded to a few ahead of our applied
    // tip. One range sync runs at a time; a peer that stops advancing our tip
    // (withheld bodies / off-chain blocks) is rotated off so an honest heavier
    // tip is not starved.

    func startRangeSync(
        peer: AuthenticatedPeer,
        targetHeight: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.rangeSync.state == nil,
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        let acquired = await process.canonicalTip()
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.rangeSync.state == nil,
              overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else { return }
        SyncTrace.log(
            "range-sync start target=\(targetHeight) "
                + "peer=\(peer.key.hex.prefix(8))"
        )
        // The anchor is the ACQUIRED tip — one (cid, height) pair describing
        // the same block — until the common-ancestor negotiation below
        // replaces it; a validated-tip CID under an acquired height would
        // re-page every held block above it.
        overlayState.rangeSync.state = RangeSync.State(
            peer: peer,
            requestID: 0,
            awaiting: false,
            hasMore: true,
            requestedAfterCID: acquired?.cid ?? configuration.nexusGenesisCID,
            requestedHeight: acquired?.height ?? 0,
            targetHeight: targetHeight,
            progressEpoch: 0,
            progressBaselineHeight: acquired?.height ?? 0,
            redriveAttempts: 0,
            negotiated: false,
            responseTimeout: nil,
            progressTimeout: nil
        )
        scheduleRangeSyncProgress(generation: generation, process: process)
        // Negotiate the common ancestor before streaming, so a frontier that
        // sits on a losing sibling is not told "empty = caught up" and marooned.
        await sendAncestorRangeRequest(generation: generation, process: process)
    }

    /// Request the next forward page if one is due: the common ancestor is
    /// negotiated, not already awaiting a response, the peer has more, and we
    /// are within the outstanding-window bound (requested minus applied). The
    /// `negotiated` guard matters: an admission drain can pump during the
    /// locator build inside `sendAncestorRangeRequest` (awaiting is still
    /// false there), and a forward page from the un-negotiated anchor would
    /// re-page held history and bump the requestID the negotiation reply
    /// must match.
    private func pumpRangeSync(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = overlayState.rangeSync.state, sync.negotiated, !sync.awaiting, sync.hasMore,
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[sync.peer.key]?.readyPeer?.sessionID == sync.peer.sessionID else { return }
        let applied = await fetchedHeight(process)
        guard var current = overlayState.rangeSync.state, current.requestID == sync.requestID,
              current.negotiated, !current.awaiting, current.hasMore,
              isCurrentRuntime(generation: generation, process: process) else { return }
        let window = RangeSync.maxPagesAhead
            * UInt64(ForwardRangeResponseMessage.maximumBlocks)
        guard current.requestedHeight < applied + window else { return }
        let requestID = makeRequestID()
        guard let payload = try? ForwardRangeRequestMessage(
            requestID: requestID,
            afterCID: current.requestedAfterCID
        ).encoded() else {
            clearRangeSync()
            return
        }
        current.awaitResponse(
            requestID: requestID,
            timeout: Timers.deadline(
                after: planeConfigurations.overlay.requestTimeout,
                generation: generation
            ) { [weak self] generation in
                await self?.rangeSyncTimedOut(requestID: requestID, generation: generation)
            }
        )
        let peer = current.peer
        overlayState.rangeSync.state = current
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.forwardRangeRequest,
            payload: payload
        )
    }

    func handleForwardRangeResponse(
        _ message: PeerMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = overlayState.rangeSync.state, sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              sync.peer.sessionID == peer.sessionID,
              let response = try? ForwardRangeResponseMessage.decoded(message.payload),
              response.requestID == sync.requestID else {
            return
        }
        // Leave the response timeout ARMED through the apply loop: if we bail
        // early below it remains a live backstop that reclaims the slot. It is
        // cancelled only once we commit the advanced state.
        var lastCID: String?
        var enqueued: UInt64 = 0
        for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
            await overlay.rememberProvider(rootCID: cid, peer: peer.id)
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayState.rangeSync.state?.requestID == sync.requestID else { return }
            guard overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else {
                // The peer we were syncing from is gone (or reconnected as a new
                // session) mid-page — release the slot so another peer can drive
                // catch-up instead of stranding it until the progress deadline.
                clearRangeSync()
                return
            }
            // Below-tip range-sync page: admit on the weighed tier so a fresh
            // node catches its header chain up to the tip without executing every
            // historical block inline. The validate-on-candidacy walk executes
            // them forward once the branch is canonical.
            _ = enqueueCandidate(CandidateSeed(
                blockCID: cid,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            ), generation: generation)
            lastCID = cid
            enqueued += 1
        }
        guard var current = overlayState.rangeSync.state, current.requestID == sync.requestID else { return }
        current.settleResponse()
        current.hasMore = response.hasMore
        // Empty page: caught up, our frontier is off this peer's main chain, or
        // every entry was non-canonical — nothing more to pull here. Demote
        // the peer's recorded claim so the re-entry probe falls through to
        // the next-tallest recorded tip instead of re-picking this peer
        // every backoff forever (a fresh announcement re-records it — a liar
        // must keep actively re-announcing to re-capture the slot).
        guard enqueued > 0, let lastCID else {
            var claimed: UInt64?
            if let claim = overlayState.overlayRecords[peer.key]?.announcedTip,
               claim.peer.sessionID == peer.sessionID {
                overlayState.overlayRecords.update(peer.key) { $0.announcedTip = nil }
                claimed = claim.height
            }
            clearRangeSync()
            // Demoted, so the re-entry probe will not evaluate this peer: if
            // the empty page means we caught up to its claim, this is the
            // edge moment for its one frontier pull (a liar's claim fails
            // the edge test and pulls nothing).
            if let claimed {
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: claimed,
                    generation: generation,
                    process: process
                )
            }
            return
        }
        current.requestedAfterCID = lastCID
        current.requestedHeight += enqueued
        // Reached the peer's tip: every page is REQUESTED, but the blocks still
        // have to be fetched and applied through the single-active worker. Keep
        // the sync (and its progress watchdog) alive until the applied tip
        // actually reaches the target — a single wedged content fetch mid-apply
        // would otherwise strand catch-up with no path to re-request the block.
        overlayState.rangeSync.state = current
        serviceBlockFetcher()
        await pumpRangeSync(generation: generation, process: process)
    }

    /// The receiver's block locator: its own accepted main-chain CIDs,
    /// newest-first at exponentially increasing height gaps back to and
    /// including genesis. Bounded, so it spans any depth in a handful of
    /// entries. Every entry is a block THIS node accepted, so the ancestor the
    /// responder picks can never rewind us past our own verified history.
    private func buildBlockLocator(process: ChainProcess) async -> [String] {
        // Anchored at the ACQUIRED tip: the locator negotiates what we hold,
        // and a validated-tip base would re-page the weighed history above it.
        guard let tip = await process.canonicalTipHeight() else {
            return [configuration.nexusGenesisCID]
        }
        var heights: [UInt64] = []
        var step: UInt64 = 1
        var height = tip
        while heights.count < AncestorRangeRequestMessage.maximumLocatorEntries - 1 {
            heights.append(height)
            if height == 0 { break }
            height = height > step ? height - step : 0
            step = step > UInt64.max / 2 ? step : step &* 2
        }
        if heights.last != 0 { heights.append(0) }
        var locator: [String] = []
        for height in heights {
            if let cid = await process.canonicalBlockCID(atHeight: height) {
                locator.append(cid)
            }
        }
        return locator.isEmpty ? [configuration.nexusGenesisCID] : locator
    }

    /// Send the common-ancestor negotiation request that opens a range sync.
    private func sendAncestorRangeRequest(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = overlayState.rangeSync.state, !sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              overlayState.overlayRecords[sync.peer.key]?.readyPeer?.sessionID == sync.peer.sessionID else { return }
        let locator = await buildBlockLocator(process: process)
        guard var current = overlayState.rangeSync.state, current.requestID == sync.requestID,
              !current.awaiting,
              isCurrentRuntime(generation: generation, process: process) else { return }
        let requestID = makeRequestID()
        guard let payload = try? AncestorRangeRequestMessage(
            requestID: requestID,
            locator: locator
        ).encoded() else {
            clearRangeSync()
            return
        }
        current.awaitResponse(
            requestID: requestID,
            timeout: Timers.deadline(
                after: planeConfigurations.overlay.requestTimeout,
                generation: generation
            ) { [weak self] generation in
                await self?.rangeSyncTimedOut(requestID: requestID, generation: generation)
            }
        )
        let peer = current.peer
        overlayState.rangeSync.state = current
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.ancestorRangeRequest,
            payload: payload
        )
    }

    /// Handle the negotiated common-ancestor response — the three outcomes.
    func handleAncestorRangeResponse(
        _ message: PeerMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = overlayState.rangeSync.state, sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              sync.peer.sessionID == peer.sessionID,
              let response = try? AncestorRangeResponseMessage.decoded(message.payload),
              response.requestID == sync.requestID else {
            return
        }
        // Like the forward page: stay `awaiting` (timeout armed) through the
        // enqueue loop below. The loop suspends per CID and the worker it
        // starts drains into `pumpRangeSync`; flipping `awaiting`/`negotiated`
        // here would let that pump page forward from the PRE-negotiation
        // anchor (our own tip) and bump the requestID, so the negotiated
        // anchor committed after the loop would be discarded. The flags flip
        // only in the committed block.
        // Outcome (c): no locator entry on the peer's main chain — disjoint
        // retention. End this peer's stream and drop its recorded claim so the
        // re-entry probe tries the next-tallest peer instead of re-picking it.
        // Never punish (a slow and a stalling peer are indistinguishable), and
        // never conclude "caught up".
        guard let ancestor = response.commonAncestor else {
            SyncTrace.log("ancestor-range no-overlap peer=\(peer.key.hex.prefix(8))")
            if overlayState.overlayRecords[peer.key]?.announcedTip?.peer.sessionID == peer.sessionID {
                overlayState.overlayRecords.update(peer.key) { $0.announcedTip = nil }
            }
            clearRangeSync()
            return
        }
        // Outcomes (a)/(b): anchor at the negotiated common ancestor — a block
        // on OUR own accepted chain, so this never rewinds us. Enqueue the first
        // page, then hand off to the forward-range pump. An empty page here is
        // now genuinely "caught up", because the anchor is a real common block
        // rather than our (possibly off-chain) frontier.
        var lastCID: String?
        var enqueued: UInt64 = 0
        for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
            await overlay.rememberProvider(rootCID: cid, peer: peer.id)
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayState.rangeSync.state?.requestID == sync.requestID else { return }
            guard overlayState.overlayRecords[peer.key]?.readyPeer?.sessionID == peer.sessionID else {
                clearRangeSync()
                return
            }
            // First page of a range sync anchored at the negotiated common
            // ancestor: below-tip, so weighed like the forward-range pages that
            // follow it.
            _ = enqueueCandidate(CandidateSeed(
                blockCID: cid,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            ), generation: generation)
            lastCID = cid
            enqueued += 1
        }
        guard enqueued > 0, let lastCID else {
            // Caught up to this peer from a real common ancestor — or a peer
            // whose claim was a lie (a tall height, then nothing to page).
            // Demote its recorded claim exactly like the empty forward page:
            // left in place, `candidates.max(by: height)` would re-pick it
            // at every re-entry probe and it would own the single sync slot
            // forever. A fresh announcement re-records it. Caught up to an
            // honest claim, this is the edge moment for its frontier pull.
            var claimed: UInt64?
            if let claim = overlayState.overlayRecords[peer.key]?.announcedTip,
               claim.peer.sessionID == peer.sessionID {
                overlayState.overlayRecords.update(peer.key) { $0.announcedTip = nil }
                claimed = claim.height
            }
            clearRangeSync()
            if let claimed {
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: claimed,
                    generation: generation,
                    process: process
                )
            }
            return
        }
        // Anchor the request-height window at the ANCESTOR's height, not our own
        // frontier: if the frontier is a losing sibling far above the ancestor,
        // a window measured against the frozen canonical tip would stall the
        // stream after two pages, before the streamed main chain can outweigh
        // the sibling. Fall back to the frontier height if the lookup fails.
        let anchorHeight = await process.acceptedBlockHeight(ancestor)
        guard var committed = overlayState.rangeSync.state, committed.requestID == sync.requestID else { return }
        committed.settleResponse()
        committed.negotiated = true
        let base = anchorHeight ?? committed.requestedHeight
        committed.requestedAfterCID = lastCID
        committed.requestedHeight = base + enqueued
        committed.progressBaselineHeight = min(committed.progressBaselineHeight, base)
        committed.hasMore = response.hasMore
        overlayState.rangeSync.state = committed
        serviceBlockFetcher()
        await pumpRangeSync(generation: generation, process: process)
    }

    /// Hooked into the admission drain: as our tip advances, pull more pages.
    func advanceRangeSync(
        generation: UInt64,
        process: ChainProcess
    ) async {
        await pumpRangeSync(generation: generation, process: process)
    }

    /// Rotate off a peer whose pages never advance our applied tip within a
    /// deadline (withheld bodies or off-chain CIDs), so an honest heavier tip is
    /// not starved. Rearms itself while progress continues.
    private func scheduleRangeSyncProgress(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard var sync = overlayState.rangeSync.state else { return }
        let epoch = overlayState.rangeSync.advanceProgressEpoch()
        sync.progressEpoch = epoch
        sync.progressTimeout?.cancel()
        sync.progressTimeout = Timers.deadline(
            after: planeConfigurations.overlay.requestTimeout * 3,
            generation: generation
        ) { [weak self] generation in
            await self?.rangeSyncProgressDeadline(
                epoch: epoch,
                generation: generation,
                process: process
            )
        }
        overlayState.rangeSync.state = sync
    }

    private func rangeSyncProgressDeadline(
        epoch: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = overlayState.rangeSync.state, sync.progressEpoch == epoch,
              isCurrentGeneration(generation) else { return }
        let acquired = await process.canonicalTip()
        let applied = acquired?.height ?? 0
        guard var current = overlayState.rangeSync.state, current.progressEpoch == epoch,
              isCurrentGeneration(generation) else { return }
        if applied >= current.targetHeight {
            // Caught up to the peer's advertised tip: release the slot so the
            // next deep peer can drive, and let direct propagation carry any
            // blocks the peer has mined since.
            clearRangeSync()
            return
        }
        guard overlayState.overlayRecords[current.peer.key]?.readyPeer?.sessionID == current.peer.sessionID
        else {
            // The peer went away before we caught up: release the slot so a new
            // deep peer can take over instead of re-driving into a dead session.
            clearRangeSync()
            return
        }
        if applied > current.progressBaselineHeight {
            // The applied tip is still climbing — the worker is draining the
            // enqueued pages. Re-arm and keep watching; do not re-request.
            current.progressBaselineHeight = applied
            current.redriveAttempts = 0
            overlayState.rangeSync.state = current
            scheduleRangeSyncProgress(generation: generation, process: process)
            return
        }
        guard current.redriveAttempts < RangeSync.maxRedrives else {
            // Re-driving this peer has not advanced our tip across the cap: it is
            // withholding a block we need. Demote its recorded claim (see the
            // empty-page site) and release the slot so a different deep
            // peer can drive catch-up instead.
            if overlayState.overlayRecords[current.peer.key]?.announcedTip?.peer.sessionID
                == current.peer.sessionID {
                overlayState.overlayRecords.update(current.peer.key) { $0.announcedTip = nil }
            }
            clearRangeSync()
            return
        }
        current.redriveAttempts += 1
        // Stalled below the target with no applied progress in a full window:
        // a content fetch has wedged (e.g. its only provider was dropped as
        // deficient), and every already-enqueued successor is blocked behind
        // it. Rewind the request anchor to the current applied tip and page
        // forward again — re-delivering the wedged block re-attaches its
        // provider (bumping providerRevision re-readies the waiting candidate),
        // and rotates onto whatever the peer still serves.
        current.requestedAfterCID = acquired?.cid ?? configuration.nexusGenesisCID
        current.requestedHeight = applied
        current.progressBaselineHeight = applied
        current.hasMore = true
        current.negotiated = false
        current.settleResponse()
        overlayState.rangeSync.state = current
        scheduleRangeSyncProgress(generation: generation, process: process)
        // The rewound anchor is our frontier again: negotiate the common
        // ancestor before streaming, so a frontier that sits on a losing
        // sibling is not told "empty = caught up" and marooned.
        await sendAncestorRangeRequest(generation: generation, process: process)
    }

    private func rangeSyncTimedOut(requestID: UInt64, generation: UInt64) async {
        guard let sync = overlayState.rangeSync.state, sync.requestID == requestID, sync.awaiting,
              isCurrentGeneration(generation), let process else { return }
        guard overlayState.overlayRecords[sync.peer.key]?.readyPeer?.sessionID == sync.peer.sessionID else {
            // Peer we were paging from is gone: release the slot so another
            // deep peer's announcement can start a fresh sync.
            clearRangeSync()
            return
        }
        // The request went unanswered but the peer is still connected — clear
        // the awaiting latch and re-issue it rather than tearing down the whole
        // sync (the progress watchdog remains the backstop for a peer that has
        // genuinely stopped serving). An unanswered NEGOTIATION is re-sent as a
        // negotiation: paging forward from the un-negotiated frontier would
        // re-open the marooned-follower bug on one dropped packet.
        var current = sync
        current.settleResponse()
        overlayState.rangeSync.state = current
        if current.negotiated {
            await pumpRangeSync(generation: generation, process: process)
        } else {
            await sendAncestorRangeRequest(generation: generation, process: process)
        }
    }

    func clearRangeSync(from caller: String = #function) {
        SyncTrace.log("range-sync clear (\(caller))")
        overlayState.rangeSync.clear()
        scheduleRangeSyncReentry()
    }

    /// A cleared sync must not depend on a further announcement to restart:
    /// on a quiet network (nobody minting) none ever arrives, and a node
    /// still far behind would idle forever. Re-entry is the receiver's own
    /// assessment, probed one request-timeout after each clear.
    private func scheduleRangeSyncReentry() {
        guard overlayState.rangeSync.reentryTask == nil, !recordedAnnouncedTips.isEmpty else {
            return
        }
        let generation = runtimeGeneration
        overlayState.rangeSync.reentryTask = Timers.deadline(
            after: planeConfigurations.overlay.requestTimeout,
            generation: generation
        ) { [weak self] generation in
            await self?.maybeRestartRangeSync(generation: generation)
        }
    }

    private func maybeRestartRangeSync(generation: UInt64) async {
        overlayState.rangeSync.reentryTask = nil
        guard isCurrentGeneration(generation), isRunning,
              overlayState.rangeSync.state == nil, let process else { return }
        let ourHeight = await fetchedHeight(process)
        guard isCurrentRuntime(generation: generation, process: process),
              overlayState.rangeSync.state == nil else { return }
        // Every recorded peer we are now at the edge with (the sync that just
        // cleared brought us there, or nothing beyond the edge remains) gets
        // its one frontier pull; the helper re-checks the edge per peer.
        for (key, claim) in recordedAnnouncedTips.sorted(by: { $0.key.hex < $1.key.hex })
            where overlayState.overlayRecords[key]?.readyPeer?.sessionID == claim.peer.sessionID {
            await pullFrontierIfAtEdge(
                from: claim.peer,
                peerHeight: claim.height,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayState.rangeSync.state == nil else { return }
        }
        let candidates = recordedAnnouncedTips.filter { key, value in
            overlayState.overlayRecords[key]?.readyPeer?.sessionID == value.peer.sessionID
                && value.height > ourHeight + RangeSync.depthThreshold
        }
        guard let best = candidates.max(by: {
            $0.value.height < $1.value.height
        }) else { return }
        await startRangeSync(
            peer: best.value.peer,
            targetHeight: best.value.height,
            generation: generation,
            process: process
        )
        // The peer may refuse or stall again; the next clear re-probes.
    }

    /// The height acquisition compares against: the canonical (weighed-
    /// inclusive) tip — what we HOLD. `status().height` is the validated tip,
    /// the act-on gate (templates, reads, hello tip); under deferred execution
    /// weighed admissions never advance it, so gap tests, the paging window
    /// and the locator measured against it would pace range sync on the
    /// validate walk and re-page history already held.
    func fetchedHeight(_ process: ChainProcess) async -> UInt64 {
        await process.canonicalTipHeight() ?? 0
    }
}
