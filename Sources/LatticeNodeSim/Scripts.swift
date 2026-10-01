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

/// A script's weigh log is its released blocks in release order (a stable
/// prefix as time passes): a page of it after `after`, from 0 if the asker's
/// log id is not `logID`.
func streamPage(of log: [SimBlock], logID: String, requestID: UInt64, asked: String?, after: UInt64, limit: Int) -> SyncMessage {
    let from = asked == logID ? Int(min(after, UInt64(log.count))) : 0
    let end = min(log.count, from + limit)
    let entries = (from..<end).map { StreamEntry(position: UInt64($0 + 1), entry: .header(log[$0].cid)) }
    return .stream(StreamPage(requestID: requestID, logID: logID, entries: entries, hasMore: end < log.count))
}

/// The push of a script's log entries `from..<log.count` (positions from
/// `from + 1`).
func streamPush(of log: [SimBlock], from: Int, logID: String) -> SyncMessage {
    let entries = (from..<log.count).map { StreamEntry(position: UInt64($0 + 1), entry: .header(log[$0].cid)) }
    return .stream(StreamPage(requestID: 0, logID: logID, entries: entries, hasMore: false))
}

/// A script's answer to the requests every script serves: its log (empty
/// for an adversary that only pushes), the objects it holds, and their
/// ancestors.
func answer(
    _ message: SyncMessage, log: [SimBlock], logID: String, held: Set<String>,
    world: World, now: Int64, _ config: CoreConfig
) -> SyncMessage? {
    switch message {
    case .getStream(let requestID, let asked, let after):
        return streamPage(of: log, logID: logID, requestID: requestID, asked: asked, after: after, limit: config.maxHeadersPerPage)
    case .getData(let requestID, let cids):
        let blocks = world.released(cids.filter(held.contains), at: now)
        let capped = config.page(blocks.map { config.entry($0.block, children: $0.children) }, hasMore: false)
        return .headers(HeadersResponse(requestID: requestID, entries: capped.entries, hasMore: capped.hasMore))
    case .getAncestors(let requestID, let cid, let max):
        let blocks = ancestors(of: cid, max: max, held: held, world: world, now: now)
        let capped = config.page(blocks.map { config.entry($0.block, children: $0.children) }, hasMore: false)
        return .headers(HeadersResponse(requestID: requestID, entries: capped.entries, hasMore: false))
    case .stream, .headers:
        return nil
    }
}

/// An ancestors answer over `held` (the CIDs a script serves): `cid` and up
/// to `max` of its held ancestors, child to parent, stopping above genesis.
func ancestors(of cid: String, max: Int, held: Set<String>, world: World, now: Int64) -> [SimBlock] {
    var blocks: [SimBlock] = []
    var current: String? = cid
    while let hash = current, blocks.count <= max, hash != world.genesis.cid, held.contains(hash),
          let block = world.blocks[hash], block.releaseAt <= now {
        blocks.append(block)
        current = block.parent
    }
    return blocks
}

/// Headers as a relay or an answer, each child index inline when it fits.
func headers(_ blocks: [SimBlock], requestID: UInt64 = 0, hasMore: Bool = false, _ config: CoreConfig) -> SyncMessage {
    .headers(HeadersResponse(
        requestID: requestID,
        entries: blocks.map { config.entry($0.block, children: $0.children) },
        hasMore: hasMore
    ))
}

/// An honest miner's node: its weigh log is the honest blocks as they are
/// released; it streams it (pushing each block as it is released to every
/// peer) and serves any released block by CID and its child index.
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
        let log = world.released(mine(world), at: now)
        guard let reply = answer(message, log: log, logID: name, held: Set(mine(world)), world: world, now: now, config) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> ChildIndex? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let released = world.released(mine(world), at: now)
        let from = relayed
        relayed = released.count
        var actions: [ScriptAction] = from == released.count ? [] : peers.map {
            .send($0, streamPush(of: released, from: from, logID: name))
        }
        if let next = mine(world).compactMap({ world.blocks[$0]?.releaseAt }).filter({ $0 > now }).min() {
            actions.append(.wakeAt(next))
        }
        return actions
    }
}

/// Header spammer: relays the ASERT-saturation fork (valid proof-of-work at
/// the easiest target the schedule allows) as it is released, then floods
/// garbage whose parents it never serves (it leaves every `getAncestors`
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

    /// It streams the spam fork; it never answers a request for content.
    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard case .getStream = message, let reply = answer(
            message, log: world.released(world.spam, at: now), logID: name, held: [], world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
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
/// rest of the network can only learn it through that node's stream. Its own
/// log is empty; it serves any released block and its ancestors.
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
        guard let reply = answer(
            message, log: [], logID: name, held: Set(world.honest + [world.uncle]), world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
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
        guard let reply = answer(
            message, log: [], logID: name, held: Set(world.blocks.keys), world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
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
