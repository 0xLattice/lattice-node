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
    mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction]
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

/// A catch-up page over `graph` (a script's weighed blocks, genesis
/// excluded): every block that is neither known nor an ancestor of a known
/// one, in `HeaderKey` order after the cursor.
func page(of graph: [SimBlock], _ request: HeadersRequest, world: World, limit: Int) -> (blocks: [SimBlock], hasMore: Bool) {
    var skip: Set<String> = [world.genesis.cid]
    for known in request.known {
        var cursor: String? = known
        while let cid = cursor, skip.insert(cid).inserted {
            cursor = world.blocks[cid]?.parent
        }
    }
    let rest = graph
        .filter { !skip.contains($0.cid) }
        .map { (key: HeaderKey(height: $0.height, cid: $0.cid), block: $0) }
        .filter { entry in request.after.map { entry.key > $0 } ?? true }
        .sorted { $0.key < $1.key }
        .map(\.block)
    return (Array(rest.prefix(limit)), rest.count > limit)
}

/// Headers as a relay or an answer, each child index inline when it fits.
func headers(_ blocks: [SimBlock], requestID: UInt64 = 0, hasMore: Bool = false, _ config: CoreConfig) -> SyncMessage {
    .headers(HeadersResponse(
        requestID: requestID,
        entries: blocks.map { config.entry($0.block, children: $0.children) },
        hasMore: hasMore
    ))
}

/// An honest miner's node: it relays each honest block's header as it is
/// released, answers catch-up with the released honest blocks, and serves
/// any released block by CID and its child index.
public struct HonestSource: SimScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    /// The honest blocks this source mines and serves (all by default).
    let chain: [String]?
    var relayed = 0

    public init(name: String, config: CoreConfig, chain: [String]? = nil) {
        self.name = name
        self.config = config
        self.chain = chain
    }

    func mine(_ world: World) -> [String] {
        guard let chain else { return world.honest }
        let members = Set(chain)
        return world.honest.filter(members.contains)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        switch message {
        case .getHeaders(let request):
            let served = page(of: world.released(mine(world), at: now), request, world: world, limit: config.maxHeadersPerPage)
            let capped = config.page(served.blocks.map { config.entry($0.block, children: $0.children) }, hasMore: served.hasMore)
            return [.send(peer, .headers(HeadersResponse(
                requestID: request.requestID, entries: capped.entries, hasMore: capped.hasMore
            )))]
        case .getHeader(let requestID, let cid):
            let held = mine(world).contains(cid) ? [cid] : []
            return [.send(peer, headers(world.released(held, at: now), requestID: requestID, config))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let released = world.released(mine(world), at: now)
        let fresh = Array(released.dropFirst(relayed))
        relayed = released.count
        var actions: [ScriptAction] = fresh.isEmpty ? [] : peers.map { .send($0, headers(fresh, config)) }
        if let next = mine(world).compactMap({ world.blocks[$0]?.releaseAt }).filter({ $0 > now }).min() {
            actions.append(.wakeAt(next))
        }
        return actions
    }
}

/// Header spammer: relays the ASERT-saturation fork (valid proof-of-work at
/// the easiest target the schedule allows) as it is released, then floods
/// garbage whose parents it never serves (it leaves every `getHeader`
/// unanswered, so it stalls), ending each flood with a header that fails
/// proof-of-work.
public struct HeaderSpammer: SimScript {
    public let name: String
    public let isHonest = false
    let config: CoreConfig
    var relayed = 0

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
    }

    /// The fork, then garbage without child indexes and again with them
    /// inline however big (growing the queue after admission), then an
    /// off-schedule header without its child index (it must be blamed before
    /// a fetch), then a failed proof-of-work.
    func flood(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let garbage = world.garbage.compactMap { world.blocks[$0] }
        let bare = garbage.map { HeaderEntry(block: $0.block, children: nil) }
        let full = garbage.map { HeaderEntry(block: $0.block, children: $0.children) }
        let offSchedule = world.released([world.lies[.offScheduleTarget]!], at: now)
            .map { HeaderEntry(block: $0.block, children: nil) }
        let forged = world.lies[.failedProofOfWork].flatMap { world.blocks[$0] }.map { [$0] } ?? []
        return [
            .send(peer, headers(world.released(world.spam, at: now), config)),
            .send(peer, .headers(HeadersResponse(requestID: 0, entries: bare, hasMore: false))),
            .send(peer, .headers(HeadersResponse(requestID: 0, entries: full, hasMore: false))),
            .send(peer, .headers(HeadersResponse(requestID: 0, entries: offSchedule, hasMore: false))),
            .send(peer, headers(forged, config)),
        ]
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        flood(peer, now: now, world: world)
    }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard case .getHeaders(let request) = message else { return [] }
        let served = page(of: world.released(world.spam, at: now), request, world: world, limit: config.maxHeadersPerPage)
        return [.send(peer, headers(served.blocks, requestID: request.requestID, hasMore: served.hasMore, config))]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? { nil }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let released = world.released(world.spam, at: now)
        let fresh = Array(released.dropFirst(relayed))
        relayed = released.count
        var actions: [ScriptAction] = fresh.isEmpty ? [] : peers.map { .send($0, headers(fresh, config)) }
        if let next = world.spam.compactMap({ world.blocks[$0]?.releaseAt }).filter({ $0 > now }).min() {
            actions.append(.wakeAt(next))
        }
        return actions
    }
}

/// Shows one honest side block (the world's uncle) to a single node: the
/// rest of the network can only learn it through that node's relay. Its own
/// catch-up answer is empty; it serves any released block by CID.
public struct UncleShower: SimScript {
    public let name: String
    public let isHonest = true
    let target: String
    let config: CoreConfig

    public init(name: String, showingTo target: String, config: CoreConfig) {
        self.name = name
        self.target = target
        self.config = config
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard peer.key == target else { return [] }
        return [.send(peer, headers(world.released([world.uncle], at: now), config))]
    }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        switch message {
        case .getHeaders(let request):
            return [.send(peer, headers([], requestID: request.requestID, config))]
        case .getHeader(let requestID, let cid):
            let held = world.honest.contains(cid) || cid == world.uncle ? [cid] : []
            return [.send(peer, headers(world.released(held, at: now), requestID: requestID, config))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        guard let uncle = world.blocks[world.uncle] else { return [] }
        guard now >= uncle.releaseAt else { return [.wakeAt(uncle.releaseAt)] }
        return peers.filter { $0.key == target }.map { .send($0, headers([uncle], config)) }
    }
}

/// Liar: an otherwise honest peer that relays, on every connection, its
/// headers that are weighed and excluded (a wrong spec, a wrong prevState,
/// and a header on the latter), then one header that proves no work the chain
/// accepts (a failed proof-of-work, an off-schedule target or an
/// off-schedule timestamp, in turn).
public struct Liar: SimScript {
    public static let blameable: [Lie] = [.failedProofOfWork, .offScheduleTarget, .offScheduleTimestamp]

    public let name: String
    public let isHonest = false
    let config: CoreConfig
    public private(set) var told: [Lie: Int] = [:]
    var connections = 0

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
    }

    func excluded(_ world: World, _ now: Int64) -> [SimBlock] {
        world.released(
            [world.lies[.wrongSpec]!, world.lies[.wrongPrevState]!, world.excludedChild], at: now
        )
    }

    mutating func lie(to peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let lie = Self.blameable[connections % Self.blameable.count]
        guard let block = world.lies[lie].flatMap({ world.blocks[$0] }), block.releaseAt <= now else { return [] }
        connections += 1
        told[lie, default: 0] += 1
        return [
            .send(peer, headers(excluded(world, now), config)),
            .send(peer, headers([block], config)),
        ]
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        lie(to: peer, now: now, world: world)
    }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        switch message {
        case .getHeaders(let request):
            let graph = world.released(world.honest, at: now) + excluded(world, now)
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

    /// Lie to every peer once the lies are released.
    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let release = world.lies.values.compactMap { world.blocks[$0]?.releaseAt }.max() ?? now
        guard now >= release else { return [.wakeAt(release)] }
        guard connections == 0 else { return [] }
        return peers.flatMap { lie(to: $0, now: now, world: world) }
    }
}
