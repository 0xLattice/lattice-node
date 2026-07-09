import Lattice
import Foundation
import Ivy
import LatticeNodeWire
import VolumeBroker
import Tally
import cashew
import UInt256

// Ivy delegate / data-source handlers + broker cascade for ChainNetwork.
// Behavior-preserving extraction : IvyDataSource volume responders,
// IvyDelegate gossip dispatch (including the bounded gossip-task spawner and
// per-peer token buckets), peer-message routing, and the pin-request handler.
extension ChainNetwork {

    // MARK: - IvyDataSource

    nonisolated public func data(for cid: String) async -> Data? {
        // Per-CID wire responder — serves ONLY a Volume ROOT's node (e.g. a block
        // root, which a peer fetches to proof-of-work-verify it). A Volume's
        // INTERNAL entries are never served individually over the wire: they
        // travel inside their volume's one-shot bundle (`volumeData(for: rootCID)`)
        // and resolve from the local CAS. Serving internal entries by CID is an
        // antipattern (per-node fetch churn, defeats object-grain bundling), so
        // this deliberately does NOT resolve arbitrary CIDs from cas_data —
        // `fetchVolumeLocal/fetchVolume(root:)` returns a payload only when `cid`
        // is a real volume root, so a non-root CID falls through to nil.
        //
        // The disk tier is root-keyed (volume_metadata), so it only
        // ever return a payload for a genuine root. The MEMORY tier is NOT: it
        // keys by whatever root a volume was stored under, and IvyFetcher caches
        // network responses as single-entry SerializedVolume(root: cid) under
        // arbitrary (possibly INTERNAL) CIDs. Serving those would leak an internal
        // entry over the wire. A real content volume (a block closure)
        // always has more than the bare root entry, so require >1 entry from the
        // memory tier; an internal-CID cache singleton (count==1) is rejected and
        // falls through to the root-keyed disk tier (which returns nil for a
        // non-root). A genuinely single-node volume not yet flushed is served from
        // disk a moment later — gossip pushes whole blocks, so this transient gap
        // never blocks PoW verification.
        if let v = await broker.fetchVolumeLocal(root: cid), v.entries.count > 1, let d = v.entries[cid] { return d }
        if let v = await diskBroker.fetchVolumeLocal(root: cid), let d = v.entries[cid] { return d }
        return nil
    }

    /// Volume responder.
    ///
    /// Volume payloads in the broker hold only the entries for one Volume —
    /// stems plus the root, terminating at the next Volume boundary (its
    /// leaves are themselves Volume roots, fetched separately). So serving
    /// the whole payload returns exactly one Volume's worth, not its
    /// transitive subtree.
    ///
    /// Empty `cids` means "everything you have under this root"; non-empty
    /// `cids` filters to that subset (legacy callers that want a partial
    /// response).
    nonisolated public func volumeData(for rootCID: String, cids: [String]) async -> [(cid: String, data: Data)] {
        // Volumes are served by PINS. A pin is this node's own intentional
        // "I hold and serve this" state — committed blocks, candidates, specs,
        // genesis, mempool transaction closures. The gate is PIN-REACHABILITY,
        // not a per-root pin: object-grain pinning pins the object root (e.g.
        // the block), and its sub-volume roots (tx volumes, state-trie nodes)
        // are covered by that closure pin — exactly the eviction engine's
        // `protected` semantics. Groupings we hold but never committed to
        // (relay residue, parent-tracking roots fetched by the extractor,
        // in-flight sync bundles) are NOT served: a headers-only tracker
        // answering a volume want with its bare-root grouping would shadow
        // real holders for the requester (first responder wins). The requester
        // verifies completeness JIT during resolution and demotes peers whose
        // bundles do not resolve — the gate keeps us from being that peer.
        // Serve ONLY from the authoritative durable grouping, never the memory
        // tier. Two reasons, and they coincide:
        //   1. serve-by-pins: a thing is servable iff pinned, and pins are
        //      durable — so the durable store IS the serve source by definition.
        //   2. soundness of the pin-reachability gate: the gate authorizes by
        //      walking `volume_entries` adjacency, which is only trustworthy if
        //      those edges came from a structural `storeRecursively` walk of a
        //      validated object — which is the ONLY writer of the durable graph
        //      (the fetch cache is memory-only). The memory tier, by contrast,
        //      holds fetched bundles whose entry set is whatever a responder
        //      sent; unioning it into a served bundle would let a peer graft
        //      padded content-addressed junk into a legitimately-pinned root's
        //      response. Disk-only serving closes that.
        // The serve gate — pin-reachability AND an own non-empty grouping — is factored
        // into `servableRootPayload(for:)` (below) so startup recovery's "already servable"
        // skip reuses the EXACT same predicate and cannot drift from it.
        guard let payload = await servableRootPayload(for: rootCID) else { return [] }
        let entries = payload.entries
        if cids.isEmpty {
            return entries.map { (cid: $0.key, data: $0.value) }
        }
        return cids.compactMap { cid in
            entries[cid].map { (cid: cid, data: $0) }
        }
    }

    /// The whole-object-by-root serve predicate. A root is servable over P2P iff BOTH:
    ///  1. PIN-REACHABLE — pinned, or reachable upward through the disk `volume_entries`
    ///     graph from a live pin. That graph is written ONLY by a structural
    ///     `storeRecursively` walk of a VALIDATED object (the fetch cache is memory-only
    ///     and never consulted here), so a pin-reachable CID is committed, verified content
    ///     — safe to serve at any grain. Unpinned relay/cache residue is refused.
    ///  2. Has its OWN non-empty `volume_entries(self, *)` grouping — i.e. it is a genuine
    ///     Volume ROOT (block, chain spec, tx-value/sub-volume, state boundary), written
    ///     with its own grouping by `storeRecursively`. `fetchVolumeLocal(root:)` queries
    ///     `volume_entries WHERE root = rootCID`, so a non-empty return IS the "is a
    ///     servable root" test.
    ///
    /// CRUCIAL: pin-reachability ALONE is insufficient. An internal in-package CID (a block
    /// transactions/children trie node, a tx BODY) is pin-reachable — it lives as a NON-root
    /// entry of its owner's pinned grouping — yet has NO own grouping, so it is refused and
    /// delivered ONLY inside the owning object's bundle. Recovery reuses this predicate so a
    /// tx-value root that is pin-reachable via a block bundle but missing its own grouping is
    /// NOT mistaken for servable.
    ///
    /// Returns the servable grouping (for `volumeData` to serve) or nil (refused).
    nonisolated public func servableRootPayload(for rootCID: String) async -> SerializedVolume? {
        guard await diskBroker.isPinReachable(cid: rootCID) else { return nil }
        guard let payload = await diskBroker.fetchVolumeLocal(root: rootCID), !payload.entries.isEmpty else { return nil }
        return payload
    }

    nonisolated public func hasVolume(rootCID: String) async -> Bool {
        // MemoryBroker first: recently received blocks may not be flushed to disk yet.
        if let payload = await broker.fetchVolumeLocal(root: rootCID), !payload.entries.isEmpty {
            return true
        }
        return await durableBroker.hasVolume(root: rootCID)
    }

    nonisolated public func hasDurableVolume(rootCID: String) async -> Bool {
        // The durable-store commit guard must answer from actual on-disk bytes.
        // DiskBroker.hasVolume has a negative-cache fast path; after large batch
        // writes, a root previously observed absent can age out of its recent-store
        // ring and falsely report missing. fetchVolumeLocal bypasses that cache.
        if let payload = await durableBroker.fetchVolumeLocal(root: rootCID), !payload.entries.isEmpty {
            return true
        }
        return await durableBroker.hasVolume(root: rootCID)
    }

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {
        // Bypass the gossip-task cap: peer-connect must always send our current
        // tip, even when the queue is saturated from a concurrent CAS recovery.
        Task { await self.delegate?.chainNetwork(self, didConnectPeer: peer) }
    }
    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        // H2: drop node-side per-peer state on disconnect so Sybil/churn
        // connect-disconnect cycles can't accumulate unbounded residue. Tally
        // ledger hygiene is library-owned since Ivy 6.0.0 (every disconnect/
        // teardown path calls tally.resetPeer itself); the node prunes only its
        // own per-peer maps (`knownPeerTips` via didDisconnectPeer).
        Task {
            await (self.delegate as? LatticeNode)?.didDisconnectPeer(publicKey: peer.publicKey)
        }
    }

    nonisolated public func ivy(_ ivy: Ivy, didIdentifyPeer realID: PeerID, previous: PeerID) {
        // inbound peers fire `didConnect` under a temporary `inbound-<uuid>`
        // id and are re-keyed to their real identity only after identify, so the
        // node never saw a banned inbound peer's real id at `didConnectPeer`. Ivy
        // 6.1.0 surfaces the canonical identity here; route it to the node delegate
        // so it can enforce the durable ban against `realID`. This fires once per
        // successful identify FRAME (a re-identify re-fires), so the delegate
        // enforcement must be idempotent (re-check + re-disconnect, no counters).
        Task { await self.delegate?.chainNetwork(self, didIdentifyPeer: realID) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveSpawnCertChain peer: PeerID) {
        // the chain arrived (a separate frame after identify); route it
        // so the node re-classifies now that spawnCertChain(for:) is populated,
        // closing the present-vs-classify under-trust race.
        Task { await self.delegate?.chainNetwork(self, didReceiveSpawnCertChain: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        spawnGossipTask { await self.delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, height: 0, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        spawnGossipTask { await self.delegate?.chainNetwork(self, didReceiveBlock: cid, data: data, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didDiscoverPublicAddress address: ObservedAddress) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveMessage message: Message, from peer: PeerID) {
        switch message {
        case .peerMessage(let topic, let payload):
            // chainAnnounce is a control message — it must process even when the
            // gossip queue is full so partition heals don't get stuck, so it
            // bypasses the gossip cap. It still gets its OWN bounded spawner so a
            // chainAnnounce flood cannot create unbounded concurrent Tasks (the
            // per-peer TokenBucket inside the handler is the second line below).
            if topic == "chainAnnounce" {
                spawnChainAnnounceTask { await self.handlePeerMessage(topic: topic, payload: payload, from: peer) }
            } else {
                spawnGossipTask { await self.handlePeerMessage(topic: topic, payload: payload, from: peer) }
            }
        default:
            break
        }
    }

    /// Spawn a gossip-handling Task only if the pending count is below the cap.
    /// Dropped messages will be re-delivered via gossip when the queue drains.
    private nonisolated func spawnGossipTask(_ work: @escaping @Sendable () async -> Void) {
        let accepted = pendingGossipTasks.withLock { count -> Bool in
            guard count < maxPendingGossipTasks else { return false }
            count += 1
            return true
        }
        guard accepted else { return }
        Task {
            defer { pendingGossipTasks.withLock { $0 -= 1 } }
            await work()
        }
    }

    /// Spawn a chainAnnounce-handling Task only if the pending count is below the
    /// dedicated chainAnnounce cap. Bounds concurrent Tasks on the control topic
    /// that bypasses the gossip cap. Dropped announces are re-delivered by the
    /// next chainAnnounce broadcast, so dropping under flood is safe.
    private nonisolated func spawnChainAnnounceTask(_ work: @escaping @Sendable () async -> Void) {
        let accepted = pendingChainAnnounceTasks.withLock { count -> Bool in
            guard count < maxPendingChainAnnounceTasks else { return false }
            count += 1
            return true
        }
        guard accepted else { return }
        Task {
            defer { pendingChainAnnounceTasks.withLock { $0 -= 1 } }
            await work()
        }
    }

    #if DEBUG
    /// Drives the REAL chainAnnounce spawner used by `ivy(_:didReceiveMessage:)`.
    /// Returns whether the work was accepted (false once the cap is hit).
    nonisolated func spawnChainAnnounceTaskForTesting(_ work: @escaping @Sendable () async -> Void) {
        spawnChainAnnounceTask(work)
    }
    nonisolated func spawnGossipTaskForTesting(_ work: @escaping @Sendable () async -> Void) {
        spawnGossipTask(work)
    }
    nonisolated func pendingChainAnnounceCountForTesting() -> Int {
        pendingChainAnnounceTasks.withLock { $0 }
    }
    nonisolated func pendingGossipCountForTesting() -> Int {
        pendingGossipTasks.withLock { $0 }
    }
    /// Drives the REAL mempool-full handler ingress (handlePeerMessage) so the
    /// source-exclusion / ban-threshold path is exercised end-to-end.
    func ingestForTesting(topic: String, payload: Data, from peer: PeerID) async {
        await handlePeerMessage(topic: topic, payload: payload, from: peer)
    }
    func mempoolFullFailureCountForTesting(_ peer: PeerID) -> Int? {
        mempoolFullFailures[peer]
    }
    func getHeadersBucketTryConsumeForTesting(_ peer: PeerID) -> Bool {
        getHeadersBuckets.tryConsume(peer)
    }
    func getHeadersBucketCountForTesting() -> Int { getHeadersBuckets.count }
    /// The insertion-time timestamp the gossip dedup recorded for a CID (nil if
    /// not present). Lets a test assert that re-seeing an in-window CID does NOT
    /// refresh its timestamp, so dedup eviction stays oldest-insertion and can't
    /// be defeated to replay a tx.
    func recentTxCIDTimestampForTesting(_ cid: String) -> ContinuousClock.Instant? {
        recentTxCIDs[cid]
    }
    func recentTxCIDCountForTesting() -> Int { recentTxCIDs.count }
    #endif

    func handlePeerMessage(topic: String, payload: Data, from peer: PeerID) async {
        switch topic {
        case "newBlock":
            if let decoded = NetworkWireCodecs.parseNewBlockPayload(payload) {
                if let data = decoded.blockData {
                    await delegate?.chainNetwork(self, didReceiveBlock: decoded.cid, data: data, from: peer)
                } else {
                    await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: decoded.cid, height: 0, from: peer)
                }
            }
        case "childBlock":
            // bound the inline proof on the DECLARED `proofLen` header field
            // read straight from the raw wire bytes — BEFORE `parseChildBlockPayload`
            // copies the proof body via `Data(...)`, BEFORE `Block(data:)`, and
            // BEFORE `ChildBlockProofEnvelope.deserialize`. This is the earliest
            // node-controlled point. An oversized-but-malformed proof deserializes to
            // nil, so the post-decode cap in LatticeNode+BlockSideEffects (which only
            // fires for a non-nil proof) would let it through; checking the declared
            // length closes that gap and avoids ever allocating the oversized copy.
            // Reject + penalize the peer before any proof copy, parse, CAS write, or
            // relay. Fail closed.
            if let declaredProofLen = NetworkWireCodecs.childBlockDeclaredProofLength(payload),
               let del = delegate,
               !del.chainNetwork(self, allowsChildBlockSize: 0, proofBytes: declaredProofLen) {
                let tally = await ivy.tally
                tally.recordFailure(peer: peer)
                break
            }
            guard let decoded = NetworkWireCodecs.parseChildBlockPayload(payload) else { break }
            // Inline block size is only knowable after parse (it is the frame tail,
            // not a length-prefixed field); bound it here before materializing the
            // block. The proof was already bounded above on its declared length.
            if let del = delegate,
               !del.chainNetwork(self, allowsChildBlockSize: decoded.blockData.count, proofBytes: nil) {
                let tally = await ivy.tally
                tally.recordFailure(peer: peer)
                break
            }
            guard let block = Block(data: decoded.blockData),
                  Self.blockCIDMatches(decoded.cid, block: block) else { break }
            let proofs = decoded.proofData.flatMap { ChildBlockProofEnvelope.deserialize($0) } ?? []
            await delegate?.chainNetwork(self, didReceiveChildBlock: decoded.cid, data: decoded.blockData,
                                         proofs: proofs, from: peer)

        case "mempool-full":
            // Wire format: [cidLen: UInt16 LE][cid][bodyLen: UInt32 LE][body][tx]
            // Body is inline because HeaderImpl's Codable only emits rawCID —
            // without it, the decoded Transaction has body.node == nil and
            // TransactionValidator fails with .missingBody.
            guard mempoolGossipBuckets.tryConsume(peer) else { break }
            guard let decoded = Self.decodeMempoolFullPayload(payload) else { break }
            let cidStr = decoded.cid
            let bodyData = decoded.bodyData
            let txData = decoded.transactionData
            // Dedup: skip if we've seen this tx CID recently
            let now = ContinuousClock.Instant.now
            if let lastSeen = recentTxCIDs[cidStr], now - lastSeen < txDeduplicationWindow {
                break
            }
            guard let body = TransactionBody(data: bodyData),
                  let wireTx = Transaction(data: txData),
                  wireTx.body.rawCID == cidStr,
                  // known-valid local node; CID cannot fail
                  try! HeaderImpl<TransactionBody>(node: body).rawCID == cidStr else { break }
            let resolvedTx = Transaction(
                signatures: wireTx.signatures,
                body: HeaderImpl(rawCID: cidStr, node: body, encryptionInfo: nil)
            )
            // Delegate now owns full admission (validate + classify + insert);
            // ChainNetwork no longer calls nodeMempool directly. Pending
            // classification for receipt-blocked withdrawals must happen
            // here too so a peer's gossip doesn't bypass the classifier.
            //
            // Fail closed when no delegate is attached (startup/recovery window
            // before LatticeNode wires itself in): a bare nodeMempool.add would
            // skip signature/nonce/balance/policy validation entirely. Drop the
            // tx. Gossip is fire-and-forget — nothing re-sends it — so a tx
            // arriving in this window is lost to THIS node's mempool (bounded:
            // the originator still holds it; consensus is unaffected). The drop
            // happens before the dedup set records the CID, so a later re-send
            // remains admittable.
            guard let del = delegate else {
                NodeLogger("gossip").debug("\(directory): dropping gossiped tx \(String(cidStr.prefix(16)))… — no admission delegate attached yet (fail closed)")
                break
            }
            let admission = await del.chainNetwork(self, admitTransaction: resolvedTx, bodyCID: cidStr)
            switch admission {
            case .accepted:
                mempoolFullFailures.reset(peer)
                await storeLocally(cid: cidStr, data: bodyData)
                // Store the whole Transaction closure too, so a relayed-to node can
                // serve the Transaction volume a block references by root (block
                // sync needs the volume, not just the standalone body node).
                await storeTransactionClosure(resolvedTx)
                recentTxCIDs[cidStr] = now
                Self.evictRecentTxCIDs(&recentTxCIDs, limit: maxRecentTxCIDs)
                // Relay onward, but EXCLUDE the source peer: re-sending the tx to
                // the peer that just sent it is pure amplification (it already has
                // it). Source-exclusion on the relay edge stops a flooder from
                // having its own traffic bounced back at it. We fan out per-peer
                // (skipping `peer`) instead of broadcastMessage so the source is
                // never a relay target.
                for target in Self.relayTargets(connected: await ivy.connectedPeers, excludingSource: peer) {
                    await ivy.sendMessage(to: target, topic: "mempool-full", payload: payload)
                }
            case .rejectedMempoolFull:
                // Mempool is full: the flooding source is excluded from relay (we
                // never reach the broadcast) and, once it crosses the threshold,
                // banned durably so it stops burning validation work. The counter
                // dict is LRU-bounded inside `LRUCounter`: at capacity it drops the
                // least-recently-touched entry, never the peer being incremented,
                // so a spoofed-key flood cannot evict the real flooder's count.
                let failures = mempoolFullFailures.increment(peer)
                if failures >= mempoolFullBanThreshold {
                    mempoolFullFailures.reset(peer)
                    await delegate?.chainNetwork(self, banPeer: peer)
                }
            case .rejected(let consensusInvalid):
                if consensusInvalid {
                    let tally = await ivy.tally
                    tally.recordFailure(peer: peer)
                }
                break
            }
        case ConsensusProvider.requestTopic:
            // (serve): answer a trusted descendant's weight query and
            // reply on THIS network. The delegate gates on spawn-tree scope and
            // returns nil (stay silent) for an out-of-scope/federated peer.
            // Per-peer rate gate FIRST (mirrors getHeaders): a cw-request flood —
            // even from a federated peer that will be scope-refused — must not cost
            // an unthrottled decode + scope-lookup + chain-path resolution each.
            guard consensusRequestBuckets.tryConsume(peer) else { break }
            if let reply = await delegate?.chainNetwork(self, handleConsensusRequest: payload, from: peer) {
                await ivy.sendMessage(to: peer, topic: ConsensusProvider.responseTopic, payload: reply)
            }
        case ConsensusProvider.responseTopic:
            // (client): a response to one of our own weight requests.
            // Pass the responder so the client only accepts it from the peer it asked.
            await delegate?.chainNetwork(self, handleConsensusResponse: payload, from: peer)

        case ChildPeerProvider.advertiseTopic:
            // A connected child advertised its chain-gossip endpoint over this
            // (parent) chain's link. Rate-gate (same amplification class as cw) and
            // hand to the node, which stores it against the peer for getChildPeers.
            guard childPeerRequestBuckets.tryConsume(peer) else { break }
            await delegate?.chainNetwork(self, handleChildPeerAdvertise: payload, from: peer)
        case ChildPeerProvider.genesisTopic:
            // A connected child pushed its genesis content. Charge a HEAVY cost on the shared
            // bucket: unlike the near-free advertise/request messages, an admitted genesis message
            // can drive a durable store + closure rebuild, so it must be far rarer (cost 10 ≈ ~1/s
            // sustained vs ~10/s). The handler additionally short-circuits once the genesis is held.
            guard childPeerRequestBuckets.tryConsume(peer, cost: 10) else { break }
            await delegate?.chainNetwork(self, handleChildGenesisAdvertise: payload, from: peer)
        case ChildPeerProvider.requestTopic:
            // (serve): answer a followed child's same-chain-peer query from the live
            // spawn-trusted subscriber set and reply on THIS network. Rate gate FIRST
            // so a flood does not cost an unthrottled decode + subscriber scan each.
            guard childPeerRequestBuckets.tryConsume(peer) else { break }
            if let reply = await delegate?.chainNetwork(self, handleChildPeerRequest: payload, from: peer) {
                await ivy.sendMessage(to: peer, topic: ChildPeerProvider.responseTopic, payload: reply)
            }
        case ChildPeerProvider.responseTopic:
            // (client): a response to one of our own getChildPeers requests.
            await delegate?.chainNetwork(self, handleChildPeerResponse: payload, from: peer)
        case "chainAnnounce":
            // Per-peer rate gate: a chainAnnounce flood from one peer triggers a
            // recordProvider + delegate announcement-handling per message; cap it
            // so one peer can't monopolize the chainAnnounce spawner / fork-choice.
            guard chainAnnounceBuckets.tryConsume(peer) else { break }
            if let announce = ChainAnnounceData.deserialize(payload) {
                guard Self.acceptsChainAnnounce(announce, for: directory) else { break }
                // Register the announcing peer as a provider for their tip CID so
                // fetchVolume can find it directly without relying on pin announcements.
                await ivy.recordProvider(rootCID: announce.tipCID, peer: peer)
                await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: announce.tipCID, height: announce.tipHeight, from: peer)
            }
        case "pinRequest":
            if let cid = String(data: payload, encoding: .utf8) {
                guard pinRequestBuckets.tryConsume(peer) else { break }
                await handlePinRequest(cid: cid, from: peer)
            }

        case "getHeaders":
            // Same cheap-request/expensive-response amplification as getHeaders2
            // (up to `maxHeaderBatchSize` fetch+decode per request); gate it with
            // the same per-peer bucket BEFORE the fetch loop.
            guard getHeadersBuckets.tryConsume(peer) else { break }
            guard let request = NetworkWireCodecs.parseHeaderRequestPayload(payload) else { break }
            let requestID = request.requestID
            let fromCID = request.fromCID
            let count = Int(request.count)

            var headers: [(cid: String, data: Data)] = []
            var currentCID = fromCID
            // Byte-budget the batch while building it: Ivy's Message.serialize
            // silently returns EMPTY Data when the encoded frame exceeds
            // maxFrameSize, so an oversized headerBatch response vanishes and
            // the requester loops on tiny batches. Stop before the entry that
            // would bust the budget — the client's multi-batch continuation
            // handles short batches.
            var responseBytes = Self.headerBatchBaseBytes
            for _ in 0..<min(count, Self.maxHeaderBatchSize) {
                guard let vol = await diskBroker.fetchVolumeLocal(root: currentCID),
                      let blockData = vol.entries[currentCID],
                      let block = Block(data: blockData) else { break }
                guard Self.headerBatchHasRoom(
                    currentBytes: responseBytes,
                    cidByteCount: currentCID.utf8.count,
                    dataByteCount: blockData.count,
                    proofByteCount: nil
                ) else { break }
                responseBytes += Self.headerBatchEntryBytes(
                    cidByteCount: currentCID.utf8.count,
                    dataByteCount: blockData.count,
                    proofByteCount: nil
                )
                headers.append((cid: currentCID, data: blockData))
                guard let parentCID = block.parent?.rawCID, !parentCID.isEmpty else { break }
                currentCID = parentCID
            }

            let response = NetworkWireCodecs.encodeHeaderBatch(requestID: requestID, headers: headers)
            await ivy.sendMessage(to: peer, topic: "headerBatch", payload: response)

        case "headerBatch":
            _ = await handleHeaderBatchResponse(payload: payload, from: peer)

        case "getHeaders2":
            // Proof-carrying variant of getHeaders: each served header is bundled with
            // the ChildBlockProof this node persisted for it (F5-4 block_proofs), so a
            // syncing child chain can verify anchored PoW. Request wire = getHeaders.
            //
            // Per-peer rate gate BEFORE the fetch loop: a single getHeaders2 request
            // fans out to up to `maxHeaderBatchSize` diskBroker.fetchVolumeLocal +
            // Block(data:) decodes — the canonical cheap-request/expensive-response
            // amplification vector. Over-rate requests are dropped here without the
            // up-to-1000-fetch walk.
            guard getHeadersBuckets.tryConsume(peer) else { break }
            guard let request = NetworkWireCodecs.parseHeaderRequestPayload(payload) else { break }
            let requestID = request.requestID
            let fromCID = request.fromCID
            let count = Int(request.count)

            var entries: [(cid: String, data: Data, proof: Data?)] = []
            var currentCID = fromCID
            // Same silent-drop hazard as getHeaders (see above), and worse:
            // bundled proofs inflate entries well past bare headers, so an
            // unbudgeted proof-carrying batch busts maxFrameSize far sooner.
            var responseBytes = Self.headerBatchBaseBytes
            for _ in 0..<min(count, Self.maxHeaderBatchSize) {
                guard let vol = await diskBroker.fetchVolumeLocal(root: currentCID),
                      let blockData = vol.entries[currentCID],
                      let block = Block(data: blockData) else { break }
                let proof = await delegate?.chainNetwork(self, blockProofData: currentCID)
                if proof == nil {
                    NodeLogger("sync").warn("\(directory): getHeaders2 serving \(String(currentCID.prefix(16)))… without child proof")
                }
                guard Self.headerBatchHasRoom(
                    currentBytes: responseBytes,
                    cidByteCount: currentCID.utf8.count,
                    dataByteCount: blockData.count,
                    proofByteCount: proof?.count ?? 0
                ) else { break }
                responseBytes += Self.headerBatchEntryBytes(
                    cidByteCount: currentCID.utf8.count,
                    dataByteCount: blockData.count,
                    proofByteCount: proof?.count ?? 0
                )
                entries.append((cid: currentCID, data: blockData, proof: proof))
                guard let parentCID = block.parent?.rawCID, !parentCID.isEmpty else { break }
                currentCID = parentCID
            }

            let response = NetworkWireCodecs.encodeHeaderBatch2(requestID: requestID, entries: entries)
            await ivy.sendMessage(to: peer, topic: "headerBatch2", payload: response)

        case "headerBatch2":
            _ = await handleHeaderBatchWithProofsResponse(payload: payload, from: peer)

        default:
            break
        }
    }

    /// Relay targets for a mempool-full tx: every connected peer EXCEPT the
    /// source. Source-exclusion stops a flooder from having its own traffic
    /// bounced back at it (pure amplification — it already has the tx). Pure
    /// function so the source-exclusion edge is unit-testable without a live Ivy.
    static func relayTargets(connected: [PeerID], excludingSource source: PeerID) -> [PeerID] {
        connected.filter { $0 != source }
    }

    /// Accept a remote pin request: fetch the CID, store it, and announce.
    /// Data is stored in the LRU cache but NOT permanently pinned. Pinning
    /// relay data under the chain-directory owner would accumulate forever
    /// (that owner is never unpinned by any prune path), allowing a peer
    /// sending rapid pinRequests to exhaust the entire disk budget.
    private func handlePinRequest(cid: String, from peer: PeerID) async {
        if await durableBroker.hasVolume(root: cid) {
            let fee = await ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + 86400
            await announce(cid: cid, expiry: expiry, fee: fee)
            return
        }

        guard let data = await ivy.get(cid: cid, target: peer) else { return }

        // SEC-502: bound per-CID size to prevent peer-driven disk exhaustion.
        // At 10 req/s × 128 peers × unbounded CID size, disk fills rapidly.
        // Cap at maxBlockSize: legitimate block CIDs fit within this; anything
        // larger is not a valid block and need not be stored.
        let maxSize = resources.maxPinRequestBytes
        guard data.count <= maxSize else {
            NodeLogger("storage").warn("\(directory): handlePinRequest rejected oversized CID \(String(cid.prefix(16)))… (\(data.count) > \(maxSize) bytes)")
            return
        }

        let payload = SerializedVolume(root: cid, entries: [cid: data])
        do {
            try await durableBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): handlePinRequest store cid=\(String(cid.prefix(16)))… failed: \(error)")
            return
        }

        let fee = await ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + 86400
        await announce(cid: cid, expiry: expiry, fee: fee)
    }
}

/// Per-peer token-bucket limiter with bounded size and least-recently-seen
/// eviction. Reused by every per-peer-gated gossip topic (mempool-full,
/// pinRequest, getHeaders2, chainAnnounce) so the AC-required eviction
/// semantics live in one place instead of being re-derived per call site.
///
/// Two invariants the AC named explicitly:
///  1. An actively-rate-limited (exhausted) bucket is NEVER reset to full. We
///     mutate the existing bucket in place — we never replace it with a fresh
///     full `TokenBucket` — so a peer that drained its bucket cannot refill it
///     by sending another request.
///  2. Eviction at capacity removes the LEAST-RECENTLY-SEEN peer, never the
///     peer we are currently servicing and never "whichever bucket happens to
///     be exhausted". An attacker hammering us is, by definition, recently
///     seen, so it is the last candidate for eviction — it can't churn itself
///     out of the dict to get a fresh bucket.
struct PeerRateBuckets {
    private var buckets: [PeerID: TokenBucket] = [:]
    /// Monotonic touch order: peer -> sequence number of its last access.
    /// The minimum sequence number is the least-recently-seen peer.
    private var lastSeen: [PeerID: UInt64] = [:]
    private var seq: UInt64 = 0
    private let capacity: Double
    private let refillPerSec: Double
    private let maxEntries: Int

    init(capacity: Double, refillPerSec: Double, maxEntries: Int) {
        self.capacity = capacity
        self.refillPerSec = refillPerSec
        self.maxEntries = maxEntries
    }

    var count: Int { buckets.count }

    /// Charge one token to `peer`. Returns true if admitted. The peer's bucket
    /// is created (full) only if it does not already exist; an existing bucket
    /// is mutated in place so an exhausted bucket is never reset.
    mutating func tryConsume(_ peer: PeerID, cost: Double = 1) -> Bool {
        seq &+= 1
        if buckets[peer] == nil {
            evictIfNeeded(incoming: peer)
            buckets[peer] = TokenBucket(capacity: capacity, refillPerSec: refillPerSec)
        }
        lastSeen[peer] = seq
        // `buckets[peer]` exists here; mutate in place (no `?? TokenBucket(...)`).
        return buckets[peer]!.tryConsume(cost)
    }

    /// Evict the least-recently-seen peer when inserting `incoming` would exceed
    /// the cap. Never evicts `incoming` (it isn't in the dict yet anyway).
    private mutating func evictIfNeeded(incoming: PeerID) {
        guard buckets.count >= maxEntries else { return }
        guard let victim = lastSeen.min(by: { $0.value < $1.value })?.key else {
            // No touch records (shouldn't happen) — drop an arbitrary entry.
            if let any = buckets.first?.key { buckets.removeValue(forKey: any) }
            return
        }
        buckets.removeValue(forKey: victim)
        lastSeen.removeValue(forKey: victim)
    }

    #if DEBUG
    func tokensForTesting(_ peer: PeerID) -> Double? { buckets[peer]?.tokens }
    func containsForTesting(_ peer: PeerID) -> Bool { buckets[peer] != nil }
    #endif
}

/// Bounded per-peer integer counter with least-recently-touched eviction.
/// Used for `mempoolFullFailures`: a spoofed-key flood must not be able to evict
/// the real flooder's accumulating count (which would reset it and defeat the
/// ban trigger), so at capacity we drop the LEAST-recently-touched entry, never
/// the peer being incremented.
struct LRUCounter {
    private var counts: [PeerID: Int] = [:]
    private var lastSeen: [PeerID: UInt64] = [:]
    private var seq: UInt64 = 0
    private let maxEntries: Int

    init(maxEntries: Int) { self.maxEntries = maxEntries }

    var count: Int { counts.count }
    subscript(peer: PeerID) -> Int? { counts[peer] }

    /// Increment `peer`'s counter and return the new value. The incremented peer
    /// is marked most-recently-seen, so it is never the eviction victim.
    mutating func increment(_ peer: PeerID) -> Int {
        seq &+= 1
        if counts[peer] == nil, counts.count >= maxEntries,
           let victim = lastSeen.min(by: { $0.value < $1.value })?.key {
            counts.removeValue(forKey: victim)
            lastSeen.removeValue(forKey: victim)
        }
        let next = (counts[peer] ?? 0) + 1
        counts[peer] = next
        lastSeen[peer] = seq
        return next
    }

    mutating func reset(_ peer: PeerID) {
        counts.removeValue(forKey: peer)
        lastSeen.removeValue(forKey: peer)
    }
}

/// Lazy-refill token bucket. `tryConsume` returns false when starved so the
/// caller can drop the request without further work. State is updated on every
/// call; idle peers retain their full capacity until next message.
struct TokenBucket {
    var tokens: Double
    var lastRefill: ContinuousClock.Instant
    let capacity: Double
    let refillPerSec: Double

    init(capacity: Double, refillPerSec: Double) {
        self.tokens = capacity
        self.lastRefill = .now
        self.capacity = capacity
        self.refillPerSec = refillPerSec
    }

    mutating func tryConsume(_ cost: Double = 1) -> Bool {
        let now = ContinuousClock.Instant.now
        let elapsed = Double((now - lastRefill).components.seconds) +
            Double((now - lastRefill).components.attoseconds) / 1e18
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSec)
            lastRefill = now
        }
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}
