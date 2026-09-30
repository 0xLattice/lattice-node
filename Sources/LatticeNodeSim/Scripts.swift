import Lattice
import LatticeNodeCore

/// What a scripted peer does in reply to an input.
public enum ScriptAction: Sendable {
    case send(PeerID, SyncMessage)
    case wakeAt(Int64)
}

/// A scripted peer: honest sources that stand in for the network's miners,
/// and the adversaries. A script picks its own responses; the simulator only
/// carries them.
public protocol SimScript: Sendable {
    var name: String { get }
    /// True for a peer an honest node must never disconnect.
    var isHonest: Bool { get }
    mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction]
    mutating func received(
        _ message: SyncMessage,
        from peer: PeerID,
        now: Int64,
        world: World,
        rng: inout SplitMix64
    ) -> [ScriptAction]
    /// The child index bytes it returns for `cid`, or nil.
    func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex?
    mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction]
}

/// The best chain of `blocks` (in release order) under the reference GHOST.
func bestChain(of blocks: [SimBlock], genesis: SimBlock) -> [SimBlock] {
    var reference = GhostReference(genesis: genesis.cid)
    var byCID = [genesis.cid: genesis]
    for block in blocks {
        reference.add(block.cid, parent: block.parent, work: workForTarget(block.block.target))
        byCID[block.cid] = block
    }
    return reference.descent().path.compactMap { byCID[$0] }
}

/// The page after the first locator entry on `chain`.
func page(of chain: [SimBlock], after locator: [String], limit: Int) -> (blocks: [SimBlock], hasMore: Bool) {
    let fork = locator.lazy.compactMap { hash in chain.firstIndex { $0.cid == hash } }.first ?? 0
    let rest = chain.dropFirst(fork + 1)
    return (Array(rest.prefix(limit)), rest.count > limit)
}

func entry(_ block: SimBlock) -> HeaderEntry {
    HeaderEntry(block: block.block, children: block.children)
}

/// One header pushed unsolicited, as a node relays a header it just weighed.
func relay(_ block: SimBlock) -> SyncMessage {
    .headers(HeadersResponse(requestID: 0, entries: [entry(block)], hasMore: false))
}

/// An honest miner's node: it pushes each honest block's header as it is
/// released, serves its best chain of the released blocks, announces its head
/// when it changes and every `reannounceInterval`, and serves child indexes.
/// After the last release it re-pushes every released header each interval
/// for a while: the stand-in for a reliable transport's retransmission over
/// the simulator's lossy links.
public struct HonestSource: SimScript {
    public let name: String
    public let isHonest = true
    let pageSize: Int
    let reannounceInterval: Int64
    let lastRelease: Int64
    var announced: String?
    var nextReannounce: Int64 = 0
    var pushed = 0
    var nextPushAll: Int64 = 0

    public init(name: String, pageSize: Int, reannounceInterval: Int64, world: World) {
        self.name = name
        self.pageSize = pageSize
        self.reannounceInterval = reannounceInterval
        self.lastRelease = world.honest.compactMap { world.blocks[$0]?.releaseAt }.max() ?? 0
    }

    func chain(_ world: World, _ now: Int64) -> [SimBlock] {
        bestChain(of: world.released(world.honest, at: now), genesis: world.genesis)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard let head = chain(world, now).last else { return [] }
        return [.send(peer, .announce(blockCID: head.cid, height: head.height))]
    }

    public mutating func received(
        _ message: SyncMessage,
        from peer: PeerID,
        now: Int64,
        world: World,
        rng: inout SplitMix64
    ) -> [ScriptAction] {
        guard case .getHeaders(let request) = message else { return [] }
        let served = page(of: chain(world, now), after: request.locator, limit: pageSize)
        return [.send(peer, .headers(HeadersResponse(
            requestID: request.requestID,
            entries: served.blocks.map(entry),
            hasMore: served.hasMore
        )))]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        var actions: [ScriptAction] = []
        let released = world.released(world.honest, at: now)
        for block in released.dropFirst(pushed) {
            actions += peers.map { .send($0, relay(block)) }
        }
        pushed = released.count
        if let head = chain(world, now).last, head.cid != announced || now >= nextReannounce {
            announced = head.cid
            nextReannounce = now + reannounceInterval
            actions += peers.map { .send($0, .announce(blockCID: head.cid, height: head.height)) }
        }
        let quietUntil = lastRelease + 8 * reannounceInterval
        if now >= lastRelease, now >= nextPushAll, now < quietUntil {
            nextPushAll = now + reannounceInterval
            for block in released {
                actions += peers.map { .send($0, relay(block)) }
            }
        }
        let nextRelease = world.honest.compactMap { world.blocks[$0]?.releaseAt }
            .filter { $0 > now }.min()
        let quiet = now < quietUntil ? [nextReannounce, max(nextPushAll, lastRelease)] : []
        if let wake = ([nextRelease].compactMap { $0 } + quiet).min() {
            actions.append(.wakeAt(wake))
        }
        return actions
    }
}

/// Header spammer running the ASERT-saturation attack: a fork from genesis
/// whose second block is dated far behind schedule, so every later header's
/// target saturates toward the maximum (valid proof-of-work at almost no
/// cost). It answers one header request in four with that fork and the rest
/// with a header that does not connect, and re-announces its tip every five
/// seconds.
public struct HeaderSpammer: SimScript {
    public let name: String
    public let isHonest = false
    var requests: [PeerID: Int] = [:]

    public init(name: String) {
        self.name = name
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard let tip = world.released(world.spam, at: now).last else { return [] }
        return [.send(peer, .announce(blockCID: tip.cid, height: tip.height))]
    }

    public mutating func received(
        _ message: SyncMessage,
        from peer: PeerID,
        now: Int64,
        world: World,
        rng: inout SplitMix64
    ) -> [ScriptAction] {
        guard case .getHeaders(let request) = message else { return [] }
        let entries: [HeaderEntry]
        requests[peer, default: 0] += 1
        if requests[peer, default: 0] % 4 == 1 {
            let fork = [world.genesis] + world.released(world.spam, at: now)
            entries = page(of: fork, after: request.locator, limit: .max).blocks.map(entry)
        } else {
            entries = world.blocks[world.orphan].map { [entry($0)] } ?? []
        }
        return [.send(peer, .headers(HeadersResponse(
            requestID: request.requestID, entries: entries, hasMore: false
        )))]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? { nil }

    /// Announce the spam tip as blocks are released and every five seconds
    /// for a while after the last one.
    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        var actions: [ScriptAction] = []
        let releases = world.spam.compactMap { world.blocks[$0]?.releaseAt }
        if let tip = world.released(world.spam, at: now).last {
            actions += peers.map { .send($0, .announce(blockCID: tip.cid, height: tip.height)) }
        }
        let until = (releases.max() ?? now) + 30_000
        if let next = releases.filter({ $0 > now }).min() {
            actions.append(.wakeAt(min(next, now + 5_000)))
        } else if now < until {
            actions.append(.wakeAt(now + 5_000))
        }
        return actions
    }
}

/// Shows one honest side block (the world's uncle) to a single node, pushing
/// its header to that node alone until `until`: the rest of the network can
/// only learn it through that node's relay.
public struct UncleShower: SimScript {
    public let name: String
    public let isHonest = true
    let target: String
    let interval: Int64
    let until: Int64

    public init(name: String, showingTo target: String, interval: Int64, until: Int64) {
        self.name = name
        self.target = target
        self.interval = interval
        self.until = until
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(
        _ message: SyncMessage,
        from peer: PeerID,
        now: Int64,
        world: World,
        rng: inout SplitMix64
    ) -> [ScriptAction] {
        guard case .getHeaders(let request) = message else { return [] }
        return [.send(peer, .headers(HeadersResponse(requestID: request.requestID, entries: [], hasMore: false)))]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? { nil }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        guard let uncle = world.blocks[world.uncle], now < until else { return [] }
        guard now >= uncle.releaseAt else { return [.wakeAt(uncle.releaseAt)] }
        return peers.filter { $0.key == target }.map { .send($0, relay(uncle)) } + [.wakeAt(now + interval)]
    }
}

/// Liar: answers every header request with honest headers whose first entry
/// is corrupted — a child index that does not match its CID (inline, or
/// served by CID), a nonce that fails proof-of-work, or a page that does not
/// chain.
public struct Liar: SimScript {
    public enum Lie: CaseIterable, Sendable {
        case mismatchedChildren
        case mismatchedFetchedChildren
        case failedProofOfWork
        case brokenChain
    }

    public let name: String
    public let isHonest = false
    let pageSize: Int
    public private(set) var told: [Lie: Int] = [:]

    public init(name: String, pageSize: Int) {
        self.name = name
        self.pageSize = pageSize
    }

    /// A child index whose CID matches no block's.
    static func fakeChildren(_ world: World) -> ChildIndex {
        ChildIndex(entries: ["Liar": try! BlockHeader(node: world.genesis.block)])
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let chain = bestChain(of: world.released(world.honest, at: now), genesis: world.genesis)
        guard let head = chain.last else { return [] }
        return [.send(peer, .announce(blockCID: head.cid, height: head.height))]
    }

    public mutating func received(
        _ message: SyncMessage,
        from peer: PeerID,
        now: Int64,
        world: World,
        rng: inout SplitMix64
    ) -> [ScriptAction] {
        guard case .getHeaders(let request) = message else { return [] }
        let chain = bestChain(of: world.released(world.honest, at: now), genesis: world.genesis)
        var entries = page(of: chain, after: request.locator, limit: pageSize).blocks.map(entry)
        var lie = Lie.allCases[rng.draw(0...Lie.allCases.count - 1)]
        if entries.isEmpty || (lie == .brokenChain && entries.count < 3) {
            lie = .failedProofOfWork
        }
        if entries.isEmpty, let head = chain.last {
            entries = [entry(head)]
        }
        guard let first = entries.first else { return [] }
        switch lie {
        case .mismatchedChildren:
            entries[0] = HeaderEntry(block: first.block, children: Self.fakeChildren(world))
        case .mismatchedFetchedChildren:
            entries[0] = HeaderEntry(block: first.block, children: nil)
        case .failedProofOfWork:
            entries[0] = HeaderEntry(block: World.forged(first.block), children: first.children)
        case .brokenChain:
            entries.remove(at: 1)
        }
        told[lie, default: 0] += 1
        return [.send(peer, .headers(HeadersResponse(
            requestID: request.requestID, entries: entries, hasMore: false
        )))]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        Self.fakeChildren(world)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] { [] }
}
