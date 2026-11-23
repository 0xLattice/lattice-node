import Lattice
import cashew
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
    func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>?
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

/// A script's weigh log, served the way a core serves one: pages of IDs,
/// pushes of what it appended, its objects by CID and their ancestors. A
/// script's log is its blocks in log order, a stable prefix as time passes.
struct ScriptStream: Sendable {
    let logID: String
    var pushed = 0

    init(_ logID: String) {
        self.logID = logID
    }

    /// The answer to a request over `log`, each served header made by
    /// `entry`; ancestors are served from `held`.
    func answer(
        _ message: SyncMessage, log: [SimBlock], held: Set<String>, world: World, now: Int64,
        _ config: ChainCoreConfig, entry: ((SimBlock) -> HeaderEntry)? = nil
    ) -> SyncMessage? {
        let make = entry ?? { config.entry($0.block, children: $0.children) }
        switch message {
        case .getStream(let requestID, let asked, let after, _):
            let from = asked == logID ? Int(min(after, UInt64(log.count))) : 0
            let end = min(log.count, from + config.maxHeadersPerPage)
            return .stream(StreamPage(
                requestID: requestID, logID: logID, entries: Self.entries(log, from..<end), hasMore: end < log.count
            ))
        case .getData(let requestID, let cids):
            let logged = Dictionary(log.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
            let capped = config.page(cids.compactMap { logged[$0] }.map(make), hasMore: false)
            return .headers(HeadersResponse(requestID: requestID, entries: capped.entries, hasMore: capped.hasMore))
        case .getAncestors(let requestID, let cid, let max):
            let blocks = ancestors(of: cid, max: max, held: held, world: world, now: now)
            let capped = config.page(blocks.map(make), hasMore: false)
            return .headers(HeadersResponse(requestID: requestID, entries: capped.entries, hasMore: false))
        case .stream, .headers:
            return nil
        }
    }

    /// Push what `log` appended since the last push to every peer.
    mutating func push(_ log: [SimBlock], to peers: [PeerID]) -> [ScriptAction] {
        guard log.count > pushed else { return [] }
        let page = StreamPage(requestID: 0, logID: logID, entries: Self.entries(log, pushed..<log.count), hasMore: false)
        pushed = log.count
        return peers.map { .send($0, .stream(page)) }
    }

    static func entries(_ log: [SimBlock], _ range: Range<Int>) -> [StreamEntry] {
        range.map { StreamEntry(position: UInt64($0 + 1), entry: .header(log[$0].cid)) }
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

/// The blocks among `cids`, in log order: stably by release time, and only
/// once all are released (so the log only ever grows at its end).
func logOnceReleased(_ cids: [String], world: World, now: Int64) -> [SimBlock] {
    let blocks = cids.compactMap { world.blocks[$0] }
    guard let last = blocks.map(\.releaseAt).max(), last <= now else { return [] }
    return blocks
}

/// An honest miner's node: its weigh log is the honest blocks as they are
/// released; it streams it (pushing each block as it is released) and
/// serves any released block by CID and its child index.
public struct HonestSource: SimScript {
    public let name: String
    public let isHonest = true
    let config: ChainCoreConfig
    /// The honest blocks this source mines and serves (all by default).
    let chain: [String]?
    var stream: ScriptStream

    public init(name: String, config: ChainCoreConfig, chain: [String]? = nil) {
        self.name = name
        self.config = config
        self.chain = chain
        stream = ScriptStream(name)
    }

    func mine(_ world: World) -> [String] {
        guard let chain else { return world.honest }
        let members = Set(chain)
        return world.honest.filter(members.contains)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let log = world.released(mine(world), at: now)
        guard let reply = stream.answer(message, log: log, held: Set(mine(world)), world: world, now: now, config) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        var actions = stream.push(world.released(mine(world), at: now), to: peers)
        if let next = mine(world).compactMap({ world.blocks[$0]?.releaseAt }).filter({ $0 > now }).min() {
            actions.append(.wakeAt(next))
        }
        return actions
    }
}

/// Header spammer: its log is the ASERT-saturation fork (valid proof-of-work
/// at the easiest target the schedule allows; future-dated headers wait),
/// then garbage whose parents it never serves (its ancestors answers are
/// empty, so it is moved past, never blamed), an off-schedule header served
/// without its child index (blamed before any fetch), and a header that
/// fails proof-of-work.
public struct HeaderSpammer: SimScript {
    public let name: String
    public let isHonest = false
    let config: ChainCoreConfig
    let stream: ScriptStream

    public init(name: String, config: ChainCoreConfig) {
        self.name = name
        self.config = config
        stream = ScriptStream(name)
    }

    func log(_ world: World) -> [SimBlock] {
        (world.spam + world.garbage + [world.lies[.offScheduleTarget]!, world.lies[.failedProofOfWork]!])
            .compactMap { world.blocks[$0] }
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        let offSchedule = world.lies[.offScheduleTarget]!
        let config = self.config
        guard let reply = stream.answer(message, log: log(world), held: Set(world.spam), world: world, now: now, config, entry: {
            $0.cid == offSchedule ? HeaderEntry(block: $0.block, children: nil) : config.entry($0.block, children: $0.children)
        }) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>? { nil }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] { [] }
}

/// Shows one honest side block (the world's uncle) to a single node: its log
/// for that node is the uncle once released; the rest of the network can
/// only learn it through that node's stream. It serves any released honest
/// block's ancestors.
public struct UncleShower: SimScript {
    public let name: String
    public let isHonest = true
    let target: String
    let config: ChainCoreConfig
    var stream: ScriptStream

    public init(name: String, showingTo target: String, config: ChainCoreConfig) {
        self.name = name
        self.target = target
        self.config = config
        stream = ScriptStream(name)
    }

    func log(for peer: PeerID, _ world: World, _ now: Int64) -> [SimBlock] {
        peer.key == target ? world.released([world.uncle], at: now) : []
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard let reply = stream.answer(
            message, log: log(for: peer, world, now), held: Set(world.honest + [world.uncle]), world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        guard let uncle = world.blocks[world.uncle] else { return [] }
        guard now >= uncle.releaseAt else { return [.wakeAt(uncle.releaseAt)] }
        return stream.push([uncle], to: peers.filter { $0.key == target })
    }
}

/// Liar: an otherwise honest peer whose log, per session, is its headers
/// that are weighed and excluded (a wrong spec, a wrong prevState, and a
/// header on the latter), then one header that proves no work the chain
/// accepts (a failed proof-of-work, an off-schedule target or an
/// off-schedule timestamp, by session).
public struct Liar: SimScript {
    public static let blameable: [Lie] = [.failedProofOfWork, .offScheduleTarget, .offScheduleTimestamp]

    public let name: String
    public let isHonest = false
    let config: ChainCoreConfig
    var pushed: Set<UInt64> = []

    public init(name: String, config: ChainCoreConfig) {
        self.name = name
        self.config = config
    }

    func log(for peer: PeerID, _ world: World, _ now: Int64) -> [SimBlock] {
        let lie = Self.blameable[Int(peer.session % UInt64(Self.blameable.count))]
        return logOnceReleased(
            [world.lies[.wrongSpec]!, world.lies[.wrongPrevState]!, world.excludedChild, world.lies[lie]!],
            world: world, now: now
        )
    }

    func stream(_ peer: PeerID) -> ScriptStream { ScriptStream("\(name)#\(peer.session)") }

    public mutating func connected(_ peer: PeerID, now: Int64, world: World) -> [ScriptAction] { [] }

    public mutating func received(_ message: SyncMessage, from peer: PeerID, now: Int64, world: World) -> [ScriptAction] {
        guard let reply = stream(peer).answer(
            message, log: log(for: peer, world, now), held: Set(world.blocks.keys), world: world, now: now, config
        ) else { return [] }
        return [.send(peer, reply)]
    }

    public func fetch(_ cid: String, now: Int64, world: World) -> FlatDictionary<BlockHeader>? {
        world.blocks.values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    /// Push each session its log once the lies are released.
    public mutating func tick(peers: [PeerID], now: Int64, world: World) -> [ScriptAction] {
        let release = (Array(world.lies.values) + [world.excludedChild])
            .compactMap { world.blocks[$0]?.releaseAt }.max() ?? now
        guard now >= release else { return [.wakeAt(release)] }
        var actions: [ScriptAction] = []
        for peer in peers where pushed.insert(peer.session).inserted {
            var stream = stream(peer)
            actions += stream.push(log(for: peer, world, now), to: [peer])
        }
        return actions
    }
}
