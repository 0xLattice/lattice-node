import Lattice
import cashew

/// A peer as the core sees it: its key and the session it arrived on. An
/// event from a session the core no longer holds misses the `HeaderSync.peers`
/// lookup and is ignored, so a dead session needs no fence.
public struct PeerID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let key: String
    public let session: UInt64

    public init(key: String, session: UInt64) {
        self.key = key
        self.session = session
    }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.key != rhs.key ? lhs.key < rhs.key : lhs.session < rhs.session
    }

    public var description: String { "\(key)#\(session)" }
}

/// One header on the wire: the block node and, when it fits, the children
/// map its `children` link commits. An omitted children map is fetched by
/// CID. A child chain's header adds the proofs that weigh it: a
/// `ChildBlockProof` per root that carries it. A child genesis carries its
/// spec, which every root holds as its own.
public struct HeaderEntry: Sendable {
    public let block: Block
    public let children: FlatDictionary<BlockHeader>?
    public let proofs: [ChildBlockProof]
    public let spec: ChainSpec?

    public init(block: Block, children: FlatDictionary<BlockHeader>?, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil) {
        self.block = block
        self.children = children
        self.proofs = proofs
        self.spec = spec
    }
}

/// A header the core inserted, with the content that must be durable beside
/// its facts: the block node, its children map, and a genesis's spec.
public struct StoredHeader: Sendable {
    public let blockCID: String
    public let block: Block
    public let children: FlatDictionary<BlockHeader>
    public let spec: ChainSpec?

    public init(blockCID: String, block: Block, children: FlatDictionary<BlockHeader>, spec: ChainSpec? = nil) {
        self.blockCID = blockCID
        self.block = block
        self.children = children
        self.spec = spec
    }
}

/// One weighed object in a node's weigh log: a header, or a proof (a
/// `ChildBlockProof` grind) it credited at a child block. Only verifiable
/// objects are logged; validation and exclusion facts and attributed run
/// work never are (each node derives them).
public struct LogEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case header, proof }

    public let kind: Kind
    /// A header's CID, or a proof's content identity (`ChildProofJob.id`).
    public let cid: String
    /// The block the object is fetched by: the header itself, or the child
    /// block the proof weighs.
    public let block: String

    public static func header(_ cid: String) -> LogEntry { LogEntry(kind: .header, cid: cid, block: cid) }

    public static func proof(_ id: String, of block: String) -> LogEntry { LogEntry(kind: .proof, cid: id, block: block) }

    public init(kind: Kind, cid: String, block: String) {
        self.kind = kind
        self.cid = cid
        self.block = block
    }
}

/// A node's weigh log: every object it weighed, in its own weigh order,
/// append-only. Position `n` is entry `n - 1`. `id` names this log: a node
/// whose store resets starts a new log with a new id. The shell persists the
/// entries with the facts (`ChainBatch.log`) and hands them back at
/// restore.
public struct WeighLog: Sendable {
    public let id: String
    public private(set) var entries: [LogEntry] = []
    private var held: Set<LogEntry> = []

    public init(id: String = "", entries: [LogEntry] = []) {
        self.id = id
        for entry in entries { append(entry) }
    }

    public var count: UInt64 { UInt64(entries.count) }

    public func contains(_ entry: LogEntry) -> Bool { held.contains(entry) }

    @discardableResult
    mutating func append(_ entry: LogEntry) -> Bool {
        guard held.insert(entry).inserted else { return false }
        entries.append(entry)
        return true
    }

    /// Entries after position `after`, at most `limit` and (beyond the
    /// first) `bytes` of IDs, with their positions.
    func page(after: UInt64, limit: Int, bytes: Int = .max) -> (entries: [StreamEntry], hasMore: Bool) {
        guard after < count else { return ([], false) }
        var page: [StreamEntry] = []
        var total = 0
        var next = Int(after)
        while next < entries.count, page.count < limit {
            let entry = entries[next]
            total += entry.cid.utf8.count + entry.block.utf8.count + 16
            if !page.isEmpty, total > bytes { break }
            page.append(StreamEntry(position: UInt64(next + 1), entry: entry))
            next += 1
        }
        return (page, next < entries.count)
    }
}

/// One log entry on the wire, at its position in the sender's log.
public struct StreamEntry: Sendable, Hashable {
    public let position: UInt64
    public let entry: LogEntry

    public init(position: UInt64, entry: LogEntry) {
        self.position = position
        self.entry = entry
    }
}

/// A page of the sender's weigh log (IDs only, inv-style): the answer to
/// `getStream` (`requestID` set; `hasMore` asks for the next page), or a push
/// of entries just appended (`requestID` 0) to a peer that reached the end.
public struct StreamPage: Sendable {
    public let requestID: UInt64
    public let logID: String
    public let entries: [StreamEntry]
    public let hasMore: Bool

    public init(requestID: UInt64, logID: String, entries: [StreamEntry], hasMore: Bool) {
        self.requestID = requestID
        self.logID = logID
        self.entries = entries
        self.hasMore = hasMore
    }
}

/// Where a node is in a peer's log: the last position it received and
/// applied, in the log named `logID`. The shell persists it per peer key.
public struct StreamCursor: Sendable, Equatable {
    public let logID: String
    public let position: UInt64

    public init(logID: String, position: UInt64) {
        self.logID = logID
        self.position = position
    }
}

/// Headers the sender weighed, each with every proof it credited at it: the
/// answer to `getData` or `getAncestors` (an ancestors answer lists child to
/// parent). `hasMore`: the answer was cut by bytes. A `requestID` of 0 is an
/// unsolicited header, verified like any other.
public struct HeadersResponse: Sendable {
    public let requestID: UInt64
    public let entries: [HeaderEntry]
    public let hasMore: Bool

    public init(requestID: UInt64, entries: [HeaderEntry], hasMore: Bool) {
        self.requestID = requestID
        self.entries = entries
        self.hasMore = hasMore
    }
}

/// The sync messages the core reads and writes, decoded. The wire encoding
/// belongs to the shell.
public enum SyncMessage: Sendable {
    /// The receiver's weigh log after position `after`, if its log is still
    /// `logID`; otherwise from position 0. `own` names the sender's own log
    /// at this level, so the receiver reads it again when it changed.
    case getStream(requestID: UInt64, logID: String?, after: UInt64, own: String)
    case stream(StreamPage)
    /// These weighed headers, by CID, with their proofs.
    case getData(requestID: UInt64, cids: [String])
    /// The header `cid` (the unknown parent of a header the sender sent)
    /// and up to `max` of its ancestors, child to parent: Ethereum's reverse
    /// `GetBlockHeaders`, Avalanche's `GetAncestors`.
    case getAncestors(requestID: UInt64, cid: String, max: Int)
    case headers(HeadersResponse)
}
