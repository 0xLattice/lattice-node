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

extension LevelWorld {
    /// A catch-up page over `graph` at one level: every block neither known
    /// nor an ancestor of a known one, in `HeaderKey` order after the cursor.
    func page(of graph: [SimBlock], at path: ChainPath, _ request: HeadersRequest, limit: Int) -> (blocks: [SimBlock], hasMore: Bool) {
        let level = blocks[path] ?? [:]
        var skip: Set<String> = [geneses[path]?.cid ?? ""]
        for known in request.known {
            var cursor: String? = known
            while let cid = cursor, skip.insert(cid).inserted {
                cursor = level[cid]?.parent
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

    func childIndex(_ cid: String, at path: ChainPath, now: Int64) -> ChildIndex? {
        (blocks[path] ?? [:]).values.first { $0.block.children.rawCID == cid && $0.releaseAt <= now }?.children
    }
}

/// An honest archive of every level: it relays each released block with its
/// public proofs, answers catch-up with the released blocks, and serves any
/// released block by CID and its child index. It never shows the withheld
/// branch before its proofs are public.
public struct LevelSource: LevelScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    var relayed: [ChainPath: Set<String>] = [:]

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
    }

    func headers(_ blocks: [SimBlock], at path: ChainPath, requestID: UInt64 = 0, hasMore: Bool = false,
                 now: Int64, world: LevelWorld) -> SyncMessage {
        .headers(HeadersResponse(
            requestID: requestID,
            entries: blocks.map {
                config.entry($0.block, children: $0.children, proofs: world.publicProofs(path, $0.cid, at: now))
            },
            hasMore: hasMore
        ))
    }

    func released(_ path: ChainPath, _ now: Int64, _ world: LevelWorld) -> [SimBlock] {
        world.released(path, at: now, withheld: false).filter {
            $0.height > 0 && (path.count == 1 || !world.publicProofs(path, $0.cid, at: now).isEmpty)
        }
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] { [] }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        switch message {
        case .getHeaders(let request):
            let served = world.page(of: released(path, now, world), at: path, request, limit: config.maxHeadersPerPage)
            return [.send(peer, path, headers(served.blocks, at: path, requestID: request.requestID,
                                              hasMore: served.hasMore, now: now, world: world))]
        case .getHeader(let requestID, let cid):
            let held = released(path, now, world).filter { $0.cid == cid }
            return [.send(peer, path, headers(held, at: path, requestID: requestID, now: now, world: world))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        var actions: [LevelAction] = []
        for path in world.paths {
            let fresh = released(path, now, world).filter { !(relayed[path]?.contains($0.cid) ?? false) }
            relayed[path, default: []].formUnion(fresh.map(\.cid))
            if !fresh.isEmpty {
                actions += peers.map { .send($0, path, headers(fresh, at: path, now: now, world: world)) }
            }
        }
        let times = world.grinds.flatMap { [$0.releaseAt, $0.proofsAt] }.filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}

/// The proof withholder: it shows its own Alpha side branch's headers as
/// they are released, WITHOUT proofs, and answers requests with them; the
/// proofs reach the evidence index only later. A node waits for them and
/// never blames it.
public struct ProofWithholder: LevelScript {
    public let name: String
    public let isHonest = true
    let config: CoreConfig
    var shown: Set<String> = []

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
    }

    func branch(_ world: LevelWorld, _ now: Int64) -> [SimBlock] {
        world.released(LevelWorld.alpha, at: now, withheld: true).filter { world.isWithheld(LevelWorld.alpha, $0.cid) }
    }

    func headers(_ blocks: [SimBlock], requestID: UInt64 = 0) -> SyncMessage {
        .headers(HeadersResponse(
            requestID: requestID,
            entries: blocks.map { config.entry($0.block, children: $0.children) },
            hasMore: false
        ))
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let branch = branch(world, now)
        return branch.isEmpty ? [] : [.send(peer, LevelWorld.alpha, headers(branch))]
    }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        let mine = path == LevelWorld.alpha ? branch(world, now) : []
        switch message {
        case .getHeaders(let request):
            let served = world.page(of: mine, at: path, request, limit: config.maxHeadersPerPage)
            return [.send(peer, path, headers(served.blocks, requestID: request.requestID))]
        case .getHeader(let requestID, let cid):
            return [.send(peer, path, headers(mine.filter { $0.cid == cid }, requestID: requestID))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        let fresh = branch(world, now).filter { !shown.contains($0.cid) }
        shown.formUnion(fresh.map(\.cid))
        var actions: [LevelAction] = fresh.isEmpty ? [] : peers.map { .send($0, LevelWorld.alpha, headers(fresh)) }
        let times = world.grinds.filter(\.withheld).map(\.releaseAt).filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}

/// A peer that shows one child header with one proof, to every peer, once
/// released, and answers every request empty. With the zero-work header it
/// must never be blamed (its proof carries no work, so the header is not at
/// fault); with the off-schedule header (its proof weighs) it must be.
public struct LoneHeader: LevelScript {
    public let name: String
    public let isHonest: Bool
    let header: LevelHeader?

    public init(name: String, header: LevelHeader?, blamed: Bool) {
        self.name = name
        self.header = header
        isHonest = !blamed
    }

    func show(_ peer: PeerID, _ now: Int64) -> [LevelAction] {
        guard let header, header.releaseAt <= now else { return [] }
        return [.send(peer, header.path, .headers(HeadersResponse(
            requestID: 0,
            entries: [HeaderEntry(block: header.block.block, children: header.block.children, proofs: [header.proof])],
            hasMore: false
        )))]
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        show(peer, now)
    }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        switch message {
        case .getHeaders(let request):
            return [.send(peer, path, .headers(HeadersResponse(requestID: request.requestID, entries: [], hasMore: false)))]
        case .getHeader(let requestID, _):
            return [.send(peer, path, .headers(HeadersResponse(requestID: requestID, entries: [], hasMore: false)))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        header.flatMap { $0.block.block.children.rawCID == cid ? $0.block.children : nil }
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        guard let header else { return [] }
        guard now >= header.releaseAt else { return [.wakeAt(header.releaseAt)] }
        return peers.flatMap { show($0, now) }
    }
}

/// A proof flooder (blamed: its proofs fail proof-of-work, and it comes back
/// on every reconnection, as fresh Sybils would): it relays every released
/// child block of every level
/// with as many bad proofs as a header may carry, ahead of honest relays: a
/// forged twin of each honest proof (the same root, tampered bytes) and
/// other blocks' proofs. Bad proofs carry no work, so it is never blamed,
/// and every honest proof must still be credited everywhere.
public struct ProofFlooder: LevelScript {
    public let name: String
    public let isHonest = false
    let config: CoreConfig
    var relayed: [ChainPath: Set<String>] = [:]

    public init(name: String, config: CoreConfig) {
        self.name = name
        self.config = config
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

    func flood(_ blocks: [SimBlock], at path: ChainPath, now: Int64, world: LevelWorld) -> SyncMessage {
        let others = (world.proofs[path] ?? [:]).sorted { $0.key < $1.key }.flatMap { $0.value.values.map(\.proof) }
        return .headers(HeadersResponse(
            requestID: 0,
            entries: blocks.map { block in
                let honest = world.publicProofs(path, block.cid, at: now)
                let garbage = others.filter { proof in !honest.contains { $0.rootCID == proof.rootCID } }
                let proofs = Array((honest.map(Self.twin) + garbage).prefix(config.proofs.maxPerHeader))
                return HeaderEntry(block: block.block, children: block.children, proofs: proofs)
            },
            hasMore: false
        ))
    }

    public mutating func connected(_ peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        // Every new session gets the whole flood again.
        world.paths.dropFirst().compactMap { path in
            let released = world.released(path, at: now, withheld: false).filter {
                $0.height > 0 && !world.publicProofs(path, $0.cid, at: now).isEmpty
            }
            return released.isEmpty ? nil : .send(peer, path, flood(released, at: path, now: now, world: world))
        }
    }

    public mutating func received(_ message: SyncMessage, at path: ChainPath, from peer: PeerID, now: Int64, world: LevelWorld) -> [LevelAction] {
        switch message {
        case .getHeaders(let request):
            return [.send(peer, path, .headers(HeadersResponse(requestID: request.requestID, entries: [], hasMore: false)))]
        case .getHeader(let requestID, _):
            return [.send(peer, path, .headers(HeadersResponse(requestID: requestID, entries: [], hasMore: false)))]
        case .headers:
            return []
        }
    }

    public func fetch(_ cid: String, at path: ChainPath, now: Int64, world: LevelWorld) -> ChildIndex? {
        world.childIndex(cid, at: path, now: now)
    }

    public mutating func tick(peers: [PeerID], now: Int64, world: LevelWorld) -> [LevelAction] {
        var actions: [LevelAction] = []
        for path in world.paths.dropFirst() {
            let fresh = world.released(path, at: now, withheld: false).filter {
                $0.height > 0 && !(relayed[path]?.contains($0.cid) ?? false)
                    && !world.publicProofs(path, $0.cid, at: now).isEmpty
            }
            relayed[path, default: []].formUnion(fresh.map(\.cid))
            if !fresh.isEmpty { actions += peers.map { .send($0, path, flood(fresh, at: path, now: now, world: world)) } }
        }
        let times = world.grinds.map(\.releaseAt).filter { $0 > now }
        if let next = times.min() { actions.append(.wakeAt(next)) }
        return actions
    }
}
