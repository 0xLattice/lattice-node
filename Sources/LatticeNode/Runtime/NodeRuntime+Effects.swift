import Foundation
import Ivy
import IvyWebSocket
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import Synchronization
import cashew

extension NodeRuntime.Loop {
    // MARK: - Network → events

    mutating func receive(_ input: NodeRuntimeNetworkInput) async -> Bool {
        switch input {
        case .connected(let peer):
            guard peer.role == .endpoint else {
                _ = await ivy.disconnectSession(ifCurrent: peer)
                return true
            }
            let replaced = sessions[peer.key.hex]
            let id = nextSession
            let hello = helloPayload()
            sessions[peer.key.hex] = Session(peer: peer, id: id, sentHello: hello)
            nextSession += 1
            let (inputs, key) = (inputs, peer.key.hex)
            Timers.deadline(after: helloTimeout, generation: id) { id in
                inputs.yield(.helloDeadline(peerKey: key, session: id))
            }
            // Built at each connect, so it names what is hosted now.
            if let hello {
                await outbox.send(to: peer, topic: OverlayTopic.overlayHello, payload: hello)
            }
            if peer.route != .direct {
                // A peer met through another is worth a connection of
                // its own. One that cannot be made leaves the relayed
                // session as it is, as libp2p's DCUtR does: the relay
                // bounds the routes it carries.
                let punch = punch
                Task { _ = await punch.upgrade(peer) }
            }
            if let replaced, replaced.ready {
                guard await step(.peerGone(replaced.coreID)) else { return false }
                // Forget the host it was, so the new session's hello wakes.
                return await meetHosts()
            }
        case .disconnected(let key):
            guard let session = sessions[key],
                  !(await ivy.connectedPeers).contains(session.peer.id) else { return true }
            sessions[key] = nil
            maintenance.sessionLost(peers: sessions.count, configuration: configuration)
            if session.ready {
                await refreshWebAddresses()
                guard await step(.peerGone(session.coreID)) else { return false }
                // Forget the host it was, so its reconnect wakes.
                return await meetHosts()
            }
        case .hello(let peer, let payload):
            // A ready session's later hello replaces its claims, if its
            // first hello said it sends them; otherwise it is ignored.
            guard var session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                  !session.ready || session.capabilities.contains(ChainHandshake.helloUpdates) else {
                return true
            }
                guard let remote = try? ChainHandshake.decode(payload),
                      (try? remote.validateCompatibility(
                          expectedNexusGenesisCID: configuration.nexusGenesisCID,
                          expectedChainPath: configuration.chainPath
                      )) != nil else {
                    // A later hello that does not hold is ignored: the
                    // session keeps the claims it has.
                    guard !session.ready else { return true }
                    sessions[peer.key.hex] = nil
                    _ = await ivy.disconnectSession(ifCurrent: peer)
                    return true
                }
            let update = session.ready
            let before = session.capabilities
            session.ready = true
            session.capabilities = Set(remote.capabilities ?? [])
            // What is hosted may have changed since this node's hello
            // was sent, while the session was not yet ready to be told.
            var resend: Data?
            if !update, session.capabilities.contains(ChainHandshake.helloUpdates),
               let current = helloPayload(), current != session.sentHello {
                resend = current
                session.sentHello = current
            }
            sessions[peer.key.hex] = session
            if let resend { await outbox.send(to: peer, topic: OverlayTopic.overlayHello, payload: resend) }
            // Asked for a route when a peer cannot be dialled. A session
            // that is itself relayed cannot carry another.
            let peerRelays = session.capabilities.contains(ChainHandshake.relay)
            if peer.route == .direct,
               update ? peerRelays != before.contains(ChainHandshake.relay) : peerRelays {
                await ivy.setRelaying(peer.id, peerRelays)
            }
            guard !update else {
                // What it hosts changed: each chain's peers are counted again.
                func hosting(_ claims: Set<String>) -> Set<String> {
                    claims.filter { $0.hasPrefix(ChainHandshake.hosting([])) }
                }
                if hosting(before) != hosting(session.capabilities) { startNetworkMaintenance() }
                return await meetHosts()
            }
            await refreshWebAddresses()
            guard await step(.peerReady(session.coreID)) else { return false }
            return await meetHosts()
        case .sync(let peer, let chainPath, let message):
            guard let session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                  session.ready else {
                return true
            }
            return await step(.received(session.coreID, chainPath, message))
        case .transactionAvailable(let peer, let cid):
            guard let session = sessions[peer.key.hex], session.peer.sessionID == peer.sessionID,
                  session.ready else {
                return true
            }
            transactionFetches.fetch(cid, from: session.peer, as: session.coreID, levels: core.levels)
        }
        return true
    }

    // MARK: - Step and effects

    mutating func step(_ event: NodeEvent) async -> Bool {
        let started = SyncTrace.now()
        let effects = core.step(event, now: NodeRuntime.now())
        let stepped = SyncTrace.now()
        // Only the step moves a level: its window is read once, here,
        // before any effect refreshes a view.
        let reordered = bodyFetches.moveWindows(core)
        // Time in the step's facts transaction, for the trace.
        var persisting = 0.0
        defer {
            if SyncTrace.enabled {
                SyncTrace.log(
                    chain: core.rootPath,
                    "node-runtime step \(event.traceLabel) core \(SyncTrace.ms(started, stepped)) ms total \(SyncTrace.ms(started, SyncTrace.now())) ms persist \(SyncTrace.ms(0, persisting)) ms depth \(inputs.depth) -> \(effects.map(\.traceLabel))"
                )
            }
        }
        // The facts transaction, then publish, then everything else, each
        // in order.
        func rank(_ effect: NodeEffect) -> Int {
            switch effect {
            case .persist, .level(_, .mining(.poolChanged)): 0
            case .level(_, .publish): 1
            default: 2
            }
        }
        let ordered = effects.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        for effect in ordered {
            guard SyncTrace.enabled, case .persist = effect else {
                guard await execute(effect) else { return false }
                continue
            }
            let before = SyncTrace.now()
            guard await execute(effect) else { return false }
            persisting += SyncTrace.now() - before
        }
        await retention.settleBodies(core.levels, configuration: configuration)
        await retention.settleState(core.levels, counts: &counts)
        await bodyFetches.order(reordered)
        await retention.releaseReads()
        refreshView(core.touched)
        return true
    }

    private mutating func execute(_ effect: NodeEffect) async -> Bool {
        switch effect {
        case .persist(let batch):
            do {
                try await storage.persistNodeBatch(batch, logID: core.logID)
            } catch {
                // Fail-stop: no later effect of this step may run.
                failStop(error)
                return false
            }
            await retention.persisted(batch, configuration: configuration)
        case .level(let path, let effect):
            return await execute(effect, at: path)
        case .disconnect(let peer, let reason):
            guard let session = session(peer) else { break }
            sessions[peer.key] = nil
            // No `.disconnected` follows for a session already gone: it
            // is no longer a connected host, so its reconnect wakes.
            for path in connectedHosts.keys.keys { connectedHosts.keys[path]?.remove(peer.key) }
            switch SessionClose(reason) {
            case .recycle:
                _ = await ivy.recycleSession(ifCurrent: session.peer)
            case .close:
                _ = await ivy.disconnectSession(ifCurrent: session.peer)
            }
        case .connect(let path, let jobs):
            self.jobs.enqueue(NodeRuntime.connectJob(
                jobs, at: path, levels: LiveLevels(inputs: inputs), storage: storage, remote: remote,
                failStop: failStop
            ))
            self.jobs.start(in: core)
        case .wakeAt(let time):
            if let wake, wake.time <= time { break }
            wake?.task.cancel()
            let inputs = inputs
            wake = (time, Task {
                let delay = UInt64(max(0, time - NodeRuntime.now()))
                guard await Timers.sleep(nanoseconds: delay * 1_000_000) else { return }
                inputs.yield(.event(.tick))
            })
        }
        return true
    }

    private mutating func execute(_ effect: LatticeNodeCore.ChainEffect, at path: ChainPath) async -> Bool {
        switch effect {
        case .persist, .disconnect, .wakeAt, .connect:
            // The host merges these into its own effects.
            break
        case .publish(let snapshot):
            refreshView([path])
            outputs[path]?.published.publish(snapshot)
        case .send(let peer, let message):
            guard let session = session(peer), let frame = try? ChainSyncWire.encode(message, at: path) else { break }
            SyncTrace.log(chain: path, "sent \(ChainSyncWire.traceLabel(message))")
            await outbox.send(to: session.peer, topic: frame.topic, payload: frame.payload)
        case .serveHeaders(let peer, let token, let requestID, let blockCIDs, let hasMore):
            guard let session = session(peer) else { break }
            let (storage, outbox, inputs, config, failStop) = (storage, outbox, inputs, core.config, failStop)
            NodeRuntime.spawn {
                // Built up to a page, or for as long as the serving
                // budget allows, and no further: the work is the
                // page's, however many headers were asked, and the
                // answer leaves before the requester's deadline.
                let started = ContinuousClock.now
                var entries: [HeaderEntry] = []
                var (bytes, cut) = (0, false)
                // A child header carries its saved proofs. Read off the
                // loop, a proof whose staging transaction has not
                // committed may show, as headers may: it was verified
                // before persist, and the peer verifies it again.
                var saved = SavedProofPage(store: storage.store, path: path, cids: blockCIDs)
                for (offset, cid) in blockCIDs.enumerated() {
                    let proofs: [ChildBlockProof]
                    do {
                        proofs = try saved.proofs(at: offset)
                    } catch {
                        failStop(error)
                        return
                    }
                    guard let stored = await storage.chainHeader(cid) else { continue }
                    let spec = stored.block.parent == nil
                        ? try? await storage.chainGenesisSpec(cid) : nil
                    let entry = config.entry(
                        stored.block, children: stored.children,
                        proofs: proofs, spec: spec ?? nil
                    )
                    let elapsed = (ContinuousClock.now - started) / .milliseconds(1)
                    guard config.fits(
                        entry, first: entries.isEmpty, bytes: &bytes, elapsed: Int64(elapsed)
                    ) else {
                        cut = true
                        break
                    }
                    entries.append(entry)
                }
                do {
                    let frame = try ChainSyncWire.encode(.headers(HeadersResponse(
                        requestID: requestID, entries: entries, hasMore: hasMore || cut
                    )), at: path)
                    // Served once handed to the transport, not merely
                    // attempted: a page refused as backpressured is sent
                    // when the session drains.
                    _ = await outbox.send(to: session.peer, topic: frame.topic, payload: frame.payload).value
                } catch {
                    // Unanswered, the requester's deadline decides; say why.
                    SyncTrace.log(chain: path, "headers answer \(requestID) not sent: \(error)")
                }
                inputs.yield(.event(.level(path, .headersServed(peer, token: token))))
            }
        case .fetchByCID(let peer, let cid):
            guard let session = session(peer) else { break }
            let (storage, ivy, inputs) = (storage, ivy, inputs)
            NodeRuntime.spawn {
                let bytes: Data?
                if let local = storage.store.childIndexBytes(cid) {
                    bytes = local
                } else {
                    bytes = await ivy.fetchVolume(rootCID: cid, from: session.peer).entries[cid]
                }
                // No answer is no event: the request's deadline decides.
                guard let bytes, let index = FlatDictionary<BlockHeader>(data: bytes) else { return }
                inputs.yield(.event(.level(path, .childIndexFetched(peer, cid: cid, index))))
            }
        case .fetchBody(let cid):
            bodyFetches.fetch(
                cid, at: path, nexusGenesisCID: configuration.nexusGenesisCID,
                maxBlockSize: core.levels[path]?.maxBlockSize(of: cid)
            )
        case .cancelBody(let cid):
            bodyFetches.cancel(cid, at: path)
        case .deriveProofs(let batch):
            // A level's derivations of the step, in at most one job per
            // worker, so a burst of carriers still runs side by side.
            let size = (batch.count + jobs.workers - 1) / jobs.workers
            for start in stride(from: 0, to: batch.count, by: size) {
                jobs.enqueue(deriveProofs(Array(batch[start..<min(start + size, batch.count)]), at: path))
            }
            jobs.start(in: core)
        case .verifyProofs(let batch):
            // Off the loop: a check without its block reads it from the
            // header store there; one whose block is gone answers nil,
            // blaming no one.
            jobs.enqueue(NodeRuntime.proofJob(batch, at: path, storage: storage))
            jobs.start(in: core)
        case .readTransactions(let blocks):
            jobs.enqueue(NodeRuntime.readJob(blocks, at: path, storage: storage))
            jobs.start(in: core)
        case .mining(let effect):
            return await execute(effect, at: path)
        case .workSubmitted(let replyID, let outcome):
            answer(replyID, .success(.work(outcome)))
        }
        return true
    }

    private mutating func execute(_ effect: MiningEffect, at path: ChainPath) async -> Bool {
        switch effect {
        case .poolChanged(let delta):
            do {
                try await storage.persistPoolDelta(delta)
            } catch {
                failStop(error)
                return false
            }
        case .transactionAdmitted(let replyID, let cid, let count, let bytes):
            answer(replyID, .success(.admitted(cid: cid, count: count, bytes: bytes)))
        case .transactionRefused(let replyID, let error):
            answer(replyID, .failure(error))
        case .templateIssued(let replyID, let template):
            answer(replyID, .success(.template(template)))
        case .templateRefused(let replyID, let error), .workRefused(let replyID, let error):
            answer(replyID, .failure(error))
        case .announceTransaction(let cid):
            guard let payload = try? TransactionAvailableMessage(volumeRootCID: cid).encoded() else { break }
            // To the chain's current peers: no other peer runs its pool,
            // and with many chains most sessions host others. Every
            // session hosts Nexus.
            let hosts = ChainHosts.of(path, nexusGenesisCID: configuration.nexusGenesisCID)
            let hosting = Set(await remote.peerCapabilities.sessions(hosting: hosts, ivy: ivy).map(\.sessionID))
            for session in sessions.values.sorted(by: { $0.id < $1.id })
            where session.ready && hosting.contains(session.peer.sessionID) {
                await outbox.send(
                    to: session.peer, topic: OverlayTopic.transactionAvailable, payload: payload
                )
            }
        case .mined(let replyID, let block):
            // Its nonce cleared the search target: stale work is counted.
            if staleWork.remove(replyID) != nil { miningMetrics.submittedOnStaleTemplate() }
            // Content first: the block is stored before the grind's one
            // step weighs it.
            // The carried blocks of hosted levels, each with its proof
            // verified, join the grind: one step weighs every level the
            // grind meets.
            let (storage, remote, inputs) = (storage, remote, inputs)
            let hosted = Set(core.levels.keys)
            NodeRuntime.spawn {
                do {
                    let children = try await storage.storeMinedBlock(block, remote: remote)
                    let carried = try await storage.carriedGrinds(of: block, hosted: hosted, remote: remote)
                    inputs.yield(.event(.mined(
                        MinedGrind(root: block, rootChildren: children, carried: carried), replyID: replyID
                    )))
                } catch {
                    inputs.yield(.answer(replyID, .failure(error)))
                }
            }
        case .preflight:
            // An admission's job must run, else its submit is never
            // answered and its cid stays admitting.
            guard let basis = core.levels[path].flatMap({
                NodeRuntime.miningBasis(effect, tree: $0.tree, parent: core.levels[Array(path.dropLast())])
            }) else { preconditionFailure("every hosted level's tree carries a context: a preflight has a basis") }
            jobs.enqueue(NodeRuntime.miningJob(effect, at: path, basis: basis, storage: storage, remote: remote), effect)
            jobs.start(in: core)
        case .buildTemplate:
            guard let basis = core.levels[path].flatMap({ NodeRuntime.miningBasis(effect, tree: $0.tree) }) else { break }
            jobs.enqueue(NodeRuntime.miningJob(
                effect, at: path, basis: basis, storage: storage, remote: remote,
                children: childTemplateInputs(below: path),
                hosted: core.ordered.filter { $0.count > path.count && $0.starts(with: path) },
                levels: LiveLevels(inputs: inputs),
                cache: childTemplates
            ), effect)
            jobs.start(in: core)
        case .returnTransactions:
            jobs.enqueue(NodeRuntime.miningJob(effect, at: path, basis: nil, storage: storage, remote: remote), effect)
            jobs.start(in: core)
        }
        return true
    }

    /// One job for derivations of one level and step, as its proof
    /// checks are one: each derivation from this node's own content
    /// only, never peers: the block (read from this store when weighed),
    /// the carrier, its child index and its saved proofs, written by the
    /// step that weighed it, before this effect. Each posts its own
    /// `derived` event, as when each was a job.
    private func deriveProofs(_ batch: [ChildDeriveJob], at path: ChainPath) -> NodeRuntime.RuntimeJob {
        let (storage, failStop) = (storage, failStop)
        let held = batch.map { $0.block ?? storage.store.header($0.childCID)?.block }
        let parent = Array(path.dropLast())
        return NodeRuntime.RuntimeJob(path: path, tipCID: nil) {
            var derived: [NodeEvent] = []
            for (job, held) in zip(batch, held) {
                // A stop does not wait for the rest of the batch.
                guard !Task.isCancelled else { return derived }
                var upstream: [ChildBlockProof] = []
                if parent.count > 1 {
                    do {
                        upstream = try storage.store.savedProofs(at: parent, for: [job.carrier])[job.carrier] ?? []
                    } catch {
                        failStop(error)
                        return derived
                    }
                }
                derived.append(.level(path, .derived(await job.run(held: held, upstream: upstream, fetcher: storage.workFetcher(.chain(path))))))
            }
            return derived
        }
    }

    func mined(_ path: ChainPath) -> Bool {
        NodeRuntime.mined(path, root: core.rootPath, levels: core.levels)
    }

    /// Every hosted level below `path` that is mined, as a template job
    /// reads it.
    func childTemplateInputs(below path: ChainPath) -> [ChildTemplateInput] {
        core.ordered.filter { $0.count > path.count && $0.starts(with: path) && mined($0) }.compactMap { child -> ChildTemplateInput? in
            guard let level = core.levels[child] else { return nil }
            let snapshot = level.snapshot
            let executed = !snapshot.actOnTip.isEmpty
            return ChildTemplateInput(
                path: child,
                tipCID: executed ? snapshot.actOnTip : nil,
                weighed: !snapshot.bestHeaderTip.isEmpty,
                // Each is checked again against the carrier's state.
                transactions: level.mining.nextBlock,
                anchor: executed ? NodeRuntime.anchor(level.tree, snapshot.actOnTip) : nil,
                // A weighed root that has not executed carries nothing
                // until it executes, rather than a rival genesis.
                genesisSpec: snapshot.bestHeaderTip.isEmpty ? configuration.childSpecs[child] : nil,
                genesisPremineRecipient: configuration.childPremineRecipients[child],
                genesisTransactions: configuration.childGenesisTransactions[child] ?? [],
                genesisTarget: .max
            )
        }
    }

    /// The live, ready session the core's peer names.
    private func session(_ peer: LatticeNodeCore.PeerID) -> Session? {
        guard let session = sessions[peer.key], session.id == peer.session, session.ready else { return nil }
        return session
    }
}
