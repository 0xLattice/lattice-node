import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// What an execution reads through: the node's own store first, then the
/// content layer, which finds the CID at any other node that stored it and
/// keeps a copy. No content is served that no node stored: a body arrives
/// only through `fetchBody`, and a post-state exists only where an execution
/// stored it.
struct ContentLayer: Fetcher {
    let own: SimCAS
    let providers: [SimCAS]

    func fetch(rawCid: String) async throws -> Data {
        if let data = try? await own.fetch(rawCid: rawCid) { return data }
        for provider in providers {
            if let data = try? await provider.fetch(rawCid: rawCid) {
                own.put([rawCid: data])
                return data
            }
        }
        throw FetcherError.notFound(rawCid)
    }
}

/// How a crash tears a node's last write. The fact log and the content a
/// node holds are separate stores (state.db and the volumes). The shell
/// fsyncs a batch's content before it commits the facts (`ChainBatch`), so
/// a crash can lose facts whose content is durable, or content no durable
/// fact references, but never content a durable fact references: facts kept
/// with their states lost is an ordering violation, not a crash mode.
public enum CrashMode: CaseIterable, Sendable {
    /// The whole batch is lost.
    case loseBatch
    /// The batch's content (headers and post-states) survives, its facts do
    /// not.
    case keepContentLoseFacts
    /// The batch survives, and every body Volume not yet executed (the
    /// downloads in progress) is lost.
    case keepFactsLoseUnexecutedBodies
}

/// A miner whose block has valid proof-of-work and header linkage and an
/// invalid body: its log is that block and a block on it once released.
/// Its bodies are in the content layer like any other. It must never be
/// blamed: only execution can tell, and an invalid body is an exclusion, not
/// a verdict on the peer that relayed it.
public struct InvalidBodyMiner: SimScript {
    public let name: String
    public let isHonest = true
    let config: ChainCoreConfig
    var stream: ScriptStream

    public init(name: String, config: ChainCoreConfig) {
        self.name = name
        self.config = config
        stream = ScriptStream(name)
    }

    func log(_ world: World, _ now: Int64) -> [SimBlock] {
        logOnceReleased([world.invalidBody, world.invalidBodyChild], world: world, now: now)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard let reply = stream.answer(
            message, log: log(world, now), held: Set(world.blocks.keys), world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let release = [world.invalidBody, world.invalidBodyChild]
            .compactMap { world.blocks[$0]?.releaseAt }.max() ?? now
        guard now >= release else { return [.wakeAt(release)] }
        return stream.push(log(world, now), to: peers)
    }
}

extension Invariants {
    /// The body window and connect after every step: what is asked for or
    /// held is on the best chain after its executed prefix and within the
    /// operator's count, or is a child of a block on the act-on path; the
    /// one connect in flight is a weighed block whose parent is executed.
    static func checkBodies(node: String, core: ChainCore, digest: TreeDigest, now: Int64, wakes: [Int64]) throws {
        let window = core.bodyWindow
        let inWindow = Set(window)
        let bodies = core.bodies
        let prefix = digest.canonicalPath.prefix { digest.executed.contains($0) }.count
        let lookAhead = Set(digest.canonicalPath.dropFirst(prefix).prefix(max(core.config.bodyWindow, 0)))
        var actOn = Set<String>()
        var cursor: String? = digest.actOnTip
        while let cid = cursor, actOn.insert(cid).inserted { cursor = digest.blocks[cid]?.parent }
        if let stray = bodies.requested.union(bodies.arrived).first(where: {
            !lookAhead.contains($0) && !(digest.blocks[$0]?.parent.map(actOn.contains) ?? false)
        }) {
            throw fail(node, "body \(stray) is neither in the look-ahead nor a child of the act-on path")
        }
        if !bodies.requested.isDisjoint(with: bodies.arrived) {
            throw fail(node, "a body is both requested and arrived")
        }
        if let stray = bodies.requested.union(bodies.arrived).first(where: { !inWindow.contains($0) }) {
            throw fail(node, "body \(stray) is outside the window after the act-on tip")
        }
        if let stray = bodies.parked.keys.first(where: { !inWindow.contains($0) }) {
            throw fail(node, "parked body \(stray) is outside the window")
        }
        let waiting = { (cid: String) in (bodies.parked[cid]?.notBefore ?? .min) > now }
        if let unasked = window.first(where: {
            !bodies.requested.contains($0) && !bodies.arrived.contains($0) && !waiting($0)
        }) {
            throw fail(node, "window block \(unasked) has no body asked for and is not parked")
        }
        if let retry = bodies.parked.values.map(\.notBefore).filter({ $0 > now }).min(),
           !wakes.contains(where: { $0 <= retry }) {
            throw fail(node, "a parked body waits until \(retry) with no wake scheduled for it")
        }
        for cid in window where digest.executed.contains(cid) {
            throw fail(node, "window block \(cid) is already executed")
        }
        if let connecting = bodies.connecting {
            guard let entry = digest.blocks[connecting] else {
                throw fail(node, "connecting \(connecting), which is not weighed")
            }
            if let parent = entry.parent, !digest.executed.contains(parent) {
                throw fail(node, "connecting \(connecting) before its parent executed")
            }
        }
    }

    /// Content before facts: every block a persist records as executed has
    /// its whole post-state — every node of it, not only the root — in the
    /// node's own store.
    static func checkStatesStored(node: String, batch: ChainBatch, store: SimStore, content: SimCAS) async throws {
        for fact in batch.facts.flatMap(\.facts) {
            guard case .validation(let validation) = fact else { continue }
            guard let postState = store.headers[validation.blockHash]?.block.postState else {
                throw fail(node, "executed \(validation.blockHash) has no durable header")
            }
            do {
                _ = try await LatticeStateHeader(rawCID: postState.rawCID).resolveRecursive(fetcher: content)
            } catch {
                throw fail(node, "executed \(validation.blockHash) without storing its whole post-state: \(error)")
            }
        }
    }

    /// Liveness: with every body of its best chain available, a node's
    /// act-on tip is its best tip.
    static func checkLiveness(node: String, digest: TreeDigest, available: (String) -> Bool) throws {
        guard digest.canonicalPath.allSatisfy(available) else { return }
        if digest.actOnTip != digest.canonicalTip {
            throw fail(node, "act-on tip \(digest.actOnTip) never reached best tip \(digest.canonicalTip) with every body available")
        }
    }
}

extension Simulator {
    /// `name` dies in the middle of writing `batch` and restarts from what
    /// its stores kept: the core is rebuilt by replaying the fact log, every
    /// session ends (both ends reconnect later), and work the dead process
    /// started never reports.
    mutating func crash(_ name: String, tearing batch: ChainBatch, _ mode: CrashMode) async throws {
        guard var node = cores[name] else { return }
        switch mode {
        case .loseBatch:
            break
        case .keepContentLoseFacts:
            for state in batch.states {
                try await storeMaterialized(state, in: node.content)
            }
            node.store.appendTorn(batch)
        case .keepFactsLoseUnexecutedBodies:
            for state in batch.states {
                try await storeMaterialized(state, in: node.content)
            }
            node.store.append(batch)
            for cid in node.bodies.subtracting(node.store.validations) {
                node.content.removeAll(world.blocks[cid]?.body.keys.map { $0 } ?? [])
                node.bodies.remove(cid)
            }
        }
        node.fetching = []
        let restored = try ChainCore.restore(
            replaying: node.store.facts,
            context: world.context,
            specs: [world.spec],
            config: node.core.config,
            logID: name,
            cursors: node.store.cursors
        )
        node.core = restored
        node.digest = TreeDigest(restored.tree)
        node.incarnation += 1
        cores[name] = node
        try Invariants.check(
            node: name, core: restored, digest: node.digest, previous: nil,
            store: node.store, world: world
        )
        for (pair, id) in sessions.sorted(by: { $0.value < $1.value })
        where pair.low == name || pair.high == name {
            let other = pair.low == name ? pair.high : pair.low
            sessions[pair] = nil
            if cores[other] != nil {
                try await step(other, .peerGone(PeerID(key: name, session: id)))
            }
            schedule(at: now + config.reconnectDelay, to: name, .connect(name, other))
        }
    }
}

/// Store an execution's materialized post-state as the shell does: every
/// Volume the execution loaded, each as its own boundary. A subtree it did
/// not load is unchanged from a state already stored.
public func storeMaterialized(_ state: LatticeState, in storer: any VolumeStorer) async throws {
    try await storeLoaded(LatticeStateHeader(node: state), in: storer)
}

private func storeLoaded(_ header: any Header, in storer: any VolumeStorer) async throws {
    guard let node = loadedNode(of: header) else { return }
    if let volume = header as? any Volume {
        try await volume.store(storer: storer)
    }
    var children: [any Header] = node.properties().sorted().compactMap { node.get(property: $0) }
    if let radix = node as? any RadixNode, let value = radix.value as? any Header {
        children.append(value)
    }
    for child in children {
        try await storeLoaded(child, in: storer)
    }
}

private func loadedNode<H: Header>(of header: H) -> (any Node)? {
    header.node
}
