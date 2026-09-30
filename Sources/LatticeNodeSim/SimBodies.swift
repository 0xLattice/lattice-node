import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// A node's view of the content layer while it executes: every CID the
/// world holds, except a block's own body Volume, which it holds only once
/// `fetchBody` delivered it. Executing a block whose body never arrived
/// therefore fails to resolve, as it would on a real node.
struct BodyGate: Fetcher {
    let content: SimCAS
    let blocks: Set<String>
    let held: Set<String>

    func fetch(rawCid: String) async throws -> Data {
        if blocks.contains(rawCid), !held.contains(rawCid) {
            throw FetcherError.notFound(rawCid)
        }
        return try await content.fetch(rawCid: rawCid)
    }
}

/// How a crash tears a node's last write. The fact log and the content a
/// node holds are separate stores (state.db and the volumes). Content is
/// written before any fact that references it, so a crash can keep content
/// without its facts, and can lose content no durable fact references —
/// never the reverse.
public enum CrashMode: CaseIterable, Sendable {
    /// The whole batch is lost.
    case loseBatch
    /// The batch's header content survives, its facts do not.
    case keepContentLoseFacts
    /// The batch survives, and every body Volume no durable execution
    /// references (the downloads not yet connected) is lost.
    case keepFactsLoseUnexecutedBodies
}

/// A miner whose block has valid proof-of-work and header linkage and an
/// invalid body: it relays that block and a block on it once released, and
/// answers catch-up with them. Its bodies are in the content layer like any
/// other. It must never be blamed: only execution can tell, and an invalid
/// body is an exclusion, not a verdict on the peer that relayed it.
public struct InvalidBodyMiner: SimScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    var relayed = false

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
    }

    func blocks(_ world: World, _ now: Int64) -> [SimBlock] {
        world.released([world.invalidBody, world.invalidBodyChild], at: now)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let shown = blocks(world, now)
        return shown.isEmpty ? [] : [.send(peer, headers(shown, config))]
    }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        switch message {
        case .getHeaders(let request):
            let graph = world.released(world.honest, at: now) + blocks(world, now)
            let served = page(of: graph, request, world: world, limit: config.maxHeadersPerPage)
            return [.send(peer, headers(served.blocks, requestID: request.requestID, hasMore: served.hasMore, config))]
        case .getHeader(let requestID, let cid):
            return [.send(peer, headers(world.released([cid], at: now), requestID: requestID, config))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let release = [world.invalidBody, world.invalidBodyChild]
            .compactMap { world.blocks[$0]?.releaseAt }.max() ?? now
        guard now >= release else { return [.wakeAt(release)] }
        guard !relayed else { return [] }
        relayed = true
        let shown = blocks(world, now)
        return peers.map { .send($0, headers(shown, config)) }
    }
}

extension Invariants {
    /// The body window and connect after every step: what is asked for or
    /// held is exactly on the best chain after the act-on tip and within the
    /// operator's count; the one connect in flight is a weighed block whose
    /// parent is executed.
    static func checkBodies(node: String, core: Core, digest: TreeDigest) throws {
        let window = core.bodyWindow
        let inWindow = Set(window)
        let bodies = core.bodies
        if bodies.requested.count + bodies.arrived.count > core.config.bodyWindow {
            throw fail(node, "the body window holds more than \(core.config.bodyWindow) bodies")
        }
        if !bodies.requested.isDisjoint(with: bodies.arrived) {
            throw fail(node, "a body is both requested and arrived")
        }
        if let stray = bodies.requested.union(bodies.arrived).first(where: { !inWindow.contains($0) }) {
            throw fail(node, "body \(stray) is outside the window after the act-on tip")
        }
        if let unasked = window.first(where: { !bodies.requested.contains($0) && !bodies.arrived.contains($0) }) {
            throw fail(node, "window block \(unasked) has no body asked for")
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
    mutating func crash(_ name: String, tearing batch: PersistBatch, _ mode: CrashMode) throws {
        guard var node = cores[name] else { return }
        switch mode {
        case .loseBatch:
            break
        case .keepContentLoseFacts:
            node.store.appendTorn(batch)
        case .keepFactsLoseUnexecutedBodies:
            node.store.append(batch)
            node.bodies.formIntersection(node.store.validations.union([world.genesis.cid]))
        }
        let restored = try Core.restore(
            replaying: node.store.facts,
            context: world.context,
            spec: world.spec,
            config: node.core.config
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
                try step(other, .peerGone(PeerID(key: name, session: id)))
            }
            schedule(at: now + config.reconnectDelay, to: name, .connect(name, other))
        }
    }
}
