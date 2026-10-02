import Lattice
import LatticeNodeCore

/// What a scripted peer does in reply to an input, at some level.
public enum LevelAction: Sendable {
    case send(PeerID, ChainPath, SyncMessage)
    case wakeAt(Int64)
}

/// A scripted peer of the multi-level simulator.
public protocol LevelScript: Sendable {
    var name: String { get }
    /// True for a peer an honest node must never disconnect.
    var isHonest: Bool { get }
    mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction]
    mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction]
    func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex?
    mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction]
}

/// A level script's weigh log at one level: entries in log order, each with
/// the time it is appended (a stable prefix as time passes) and the block it
/// is fetched by.
struct LevelLogItem {
    let time: Int64
    let entry: LogEntry
    let block: SimBlock
}

/// A level script's stream, served the way a core serves one: pages of IDs,
/// pushes of what was appended, its blocks by CID and their ancestors.
struct LevelStream: Sendable {
    let logID: String
    var pushed: [ChainPath: Int] = [:]

    init(_ logID: String) {
        self.logID = logID
    }

    static func entries(_ log: [LevelLogItem], _ range: Range<Int>) -> [StreamEntry] {
        range.map { StreamEntry(position: UInt64($0 + 1), entry: log[$0].entry) }
    }

    /// The answer to a request at `path` over `log` (its items up to now),
    /// each served header made by `make`; ancestors from `held`.
    func answer(
        _ message: SyncMessage, at path: ChainPath, log: [LevelLogItem], held: [SimBlock],
        world: LevelWorld, _ config: CoreConfig, _ make: (SimBlock) -> HeaderEntry
    ) -> SyncMessage? {
        switch message {
        case .getStream(let requestID, let asked, let after, _):
            let from = asked == logID ? Int(min(after, UInt64(log.count))) : 0
            let end = min(log.count, from + config.maxHeadersPerPage)
            return .stream(StreamPage(requestID: requestID, logID: logID, entries: Self.entries(log, from..<end), hasMore: end < log.count))
        case .getData(let requestID, let cids):
            let blocks = Dictionary(log.map { ($0.block.cid, $0.block) }, uniquingKeysWith: { a, _ in a })
            return .headers(HeadersResponse(requestID: requestID, entries: cids.compactMap { blocks[$0] }.map(make), hasMore: false))
        case .getAncestors(let requestID, let cid, let max):
            let byCID = Dictionary(held.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
            var chain: [SimBlock] = []
            var current: String? = cid
            while let hash = current, chain.count <= max, hash != world.geneses[path]?.cid, let block = byCID[hash] {
                chain.append(block)
                current = block.parent
            }
            return .headers(HeadersResponse(requestID: requestID, entries: chain.map(make), hasMore: false))
        case .stream, .headers:
            return nil
        }
    }

    /// Push what `log` appended at `path` since the last push to every peer.
    mutating func push(_ log: [LevelLogItem], at path: ChainPath, to peers: [PeerID]) -> [LevelAction] {
        let from = pushed[path] ?? 0
        guard log.count > from else { return [] }
        pushed[path] = log.count
        let page = StreamPage(requestID: 0, logID: logID, entries: Self.entries(log, from..<log.count), hasMore: false)
        return peers.map { .send($0, path, .stream(page)) }
    }
}

extension LevelWorld {
    func childIndex(_ cid: String, at path: ChainPath, now: Int64) -> ChildIndex? {
        (blocks[path] ?? [:]).values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }

    /// A log over `blocks` at `path` up to `now`: each block's header once
    /// released (at a child level, once its first proof is public too), and
    /// each proof once public; sorted by time, headers first.
    func log(of blocks: [SimBlock], at path: ChainPath, now: Int64, proofs: Bool = true) -> [LevelLogItem] {
        var items: [LevelLogItem] = []
        for block in blocks {
            let truths = (self.proofs[path]?[block.cid] ?? [:]).sorted { $0.key < $1.key }
            var at = block.releaseAt
            if path.count > 1 {
                guard let first = truths.map(\.value.releaseAt).min() else { continue }
                at = max(at, first)
            }
            items.append(LevelLogItem(time: at, entry: .header(block.cid), block: block))
            if proofs, path.count > 1 {
                for (root, truth) in truths {
                    items.append(LevelLogItem(time: max(at, truth.releaseAt), entry: .proof(root, of: block.cid), block: block))
                }
            }
        }
        return items.filter { $0.time <= now }.sorted {
            $0.time != $1.time ? $0.time < $1.time
                : $0.entry.kind != $1.entry.kind ? $0.entry.kind == .header
                : ($0.entry.block, $0.entry.cid) < ($1.entry.block, $1.entry.cid)
        }
    }
}

/// An honest archive of every level: its log is every released block (a
/// child block once a proof of it is public) and each proof as it becomes
/// public; it serves any released block by CID, with its public proofs, and
/// its child index. It never shows the withheld branch.
public struct LevelSource: LevelScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    var stream: LevelStream

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
        stream = LevelStream(name)
    }

    func log(_ path: ChainPath, _ now: Int64, _ world: LevelWorld) -> [LevelLogItem] {
        let blocks = world.released(path, at: now, withheld: false).filter { $0.height > 0 }
        return world.log(of: blocks, at: path, now: now)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] { [] }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let log = log(path, now, world)
        guard let reply = stream.answer(message, at: path, log: log, held: log.map(\.block), world: world, config, {
            config.entry($0.block, children: $0.children, proofs: world.publicProofs(path, $0.cid, at: now))
        }) else { return [] }
        return [.send(peer, path, reply)]
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        var actions: [LevelAction] = []
        for path in world.paths {
            actions += stream.push(log(path, now, world), at: path, to: peers)
        }
        let times = world.grinds.flatMap { [$0.releaseAt, $0.proofsAt] }.filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}

/// The proof withholder: its Alpha log is its own side branch's headers as
/// they are released, served WITHOUT proofs, and each proof once public
/// (the evidence index learns them only then). A node waits for them and
/// never blames it.
public struct ProofWithholder: LevelScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    var stream: LevelStream

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
        stream = LevelStream(name)
    }

    func branch(_ world: LevelWorld, _ now: Int64) -> [SimBlock] {
        world.released(LevelWorld.alpha, at: now, withheld: true).filter { world.isWithheld(LevelWorld.alpha, $0.cid) }
    }

    /// Headers at release, then each proof once public.
    func log(_ path: ChainPath, _ world: LevelWorld, _ now: Int64) -> [LevelLogItem] {
        guard path == LevelWorld.alpha else { return [] }
        let headers = branch(world, now).map { LevelLogItem(time: $0.releaseAt, entry: .header($0.cid), block: $0) }
        let proofs = world.log(of: branch(world, now), at: path, now: now).filter { $0.entry.kind == .proof }
        return (headers + proofs).sorted { $0.time != $1.time ? $0.time < $1.time : $0.entry.kind == .header && $1.entry.kind == .proof }
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] { [] }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let log = log(path, world, now)
        guard let reply = stream.answer(message, at: path, log: log, held: log.map(\.block), world: world, config, {
            config.entry($0.block, children: $0.children, proofs: world.publicProofs(path, $0.cid, at: now))
        }) else { return [] }
        return [.send(peer, path, reply)]
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        var actions = stream.push(log(LevelWorld.alpha, world, now), at: LevelWorld.alpha, to: peers)
        let times = world.grinds.filter(\.withheld).flatMap { [$0.releaseAt, $0.proofsAt] }.filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}

/// A peer whose log is one child header with one proof, once released. With
/// the zero-work header it must never be blamed (its proof carries no work,
/// so the header is not at fault); with the off-schedule header (its proof
/// weighs) it must be.
public struct LoneHeader: LevelScript {
    public let name: String
    public let isHonest: Bool
    let header: LevelHeader?
    var stream: LevelStream

    public init(name: String, header: LevelHeader?, blamed: Bool) {
        self.name = name
        self.header = header
        isHonest = !blamed
        stream = LevelStream(name)
    }

    func log(_ path: ChainPath, _ now: Int64) -> [LevelLogItem] {
        guard let header, header.path == path, header.releaseAt <= now else { return [] }
        return [LevelLogItem(time: header.releaseAt, entry: .header(header.block.cid), block: header.block)]
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] { [] }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let log = log(path, now)
        let proof = header?.proof
        guard let reply = stream.answer(message, at: path, log: log, held: log.map(\.block), world: world, CoreConfig(), {
            HeaderEntry(block: $0.block, children: $0.children, proofs: proof.map { [$0] } ?? [])
        }) else { return [] }
        return [.send(peer, path, reply)]
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        header.flatMap { $0.block.block.children.rawCID == cid ? $0.block.children : nil }
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        guard let header else { return [] }
        guard now >= header.releaseAt else { return [.wakeAt(header.releaseAt)] }
        return stream.push(log(header.path, now), at: header.path, to: peers)
    }
}

/// A proof flooder (blamed: its proofs fail proof-of-work, and it comes back
/// on every reconnection, as fresh Sybils would): its log is every released
/// child block of every level, served with as many bad proofs as a header
/// may carry: a forged twin of each honest proof (the same root, tampered
/// bytes) and other blocks' proofs. Every honest proof must still be
/// credited everywhere.
public struct ProofFlooder: LevelScript {
    public let name: String
    public let isHonest = false
    let config: CoreConfig
    var stream: LevelStream

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
        stream = LevelStream(name)
    }

    static func twin(of proof: ChildBlockProof) -> ChildBlockProof {
        var entries = proof.entries
        if let last = entries.indices.last {
            var data = entries[last].data
            if !data.isEmpty { data[data.startIndex] ^= 0xFF }
            entries[last] = (entries[last].cid, data)
        }
        return ChildBlockProof(rootCID: proof.rootCID, directoryPath: proof.directoryPath, entries: entries)
    }

    func flood(_ block: SimBlock, at path: ChainPath, now: Int64, world: LevelWorld) -> HeaderEntry {
        let others = (world.proofs[path] ?? [:]).sorted { $0.key < $1.key }.flatMap { $0.value.values.map(\.proof) }
        let honest = world.publicProofs(path, block.cid, at: now)
        let garbage = others.filter { proof in !honest.contains { $0.rootCID == proof.rootCID } }
        let proofs = Array((honest.map(Self.twin) + garbage).prefix(config.proofs.maxPerHeader))
        return HeaderEntry(block: block.block, children: block.children, proofs: proofs)
    }

    func log(_ path: ChainPath, _ now: Int64, _ world: LevelWorld) -> [LevelLogItem] {
        guard path.count > 1 else { return [] }
        let blocks = world.released(path, at: now, withheld: false).filter { $0.height > 0 }
        return world.log(of: blocks, at: path, now: now, proofs: false)
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] { [] }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let log = log(path, now, world)
        guard let reply = stream.answer(message, at: path, log: log, held: log.map(\.block), world: world, config, {
            flood($0, at: path, now: now, world: world)
        }) else { return [] }
        return [.send(peer, path, reply)]
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        var actions: [LevelAction] = []
        for path in world.paths.dropFirst() {
            actions += stream.push(log(path, now, world), at: path, to: peers)
        }
        let times = world.grinds.map(\.releaseAt).filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}
