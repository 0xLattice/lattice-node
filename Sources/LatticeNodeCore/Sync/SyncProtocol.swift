import Lattice
import cashew
import Foundation
import UInt256

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

/// A peer's proof of a header, checked where the header was decoded: on
/// the task that received it, never on the decision loop. Its verdict is a
/// fact about the proof and the block, so the step that takes the header
/// applies it at once.
public struct CheckedChildProof: Sendable {
    public let proof: ChildBlockProof
    /// The proof's content identity: the hash of its canonical bytes.
    public let id: String
    public let result: Result<VerifiedChildEvidence, ChildProofVerificationFailure>

    /// `verifySecuringWork` of `proof`, whose canonical bytes are `bytes`,
    /// for `block` on the chain at `chainPath`.
    public init(_ proof: ChildBlockProof, bytes: Data, of block: Block, at chainPath: [String]) {
        self.proof = proof
        self.id = "\(UInt256.hash(bytes))"
        self.result = proof.verifySecuringWork(child: block, chainPath: chainPath)
    }

    /// Whether the proof failed: malformed, or no work for this block. An
    /// honest peer never sends one; the core disconnects the sender.
    public var failed: Bool {
        guard case .success(let evidence) = result, let work = evidence.contribution else { return true }
        return work.work == .zero
    }
}

/// One header on the wire: the block node and, when it fits, the children
/// map its `children` link commits. An omitted children map is fetched by
/// CID. A child chain's header adds the proofs that weigh it: a
/// `ChildBlockProof` per root that carries it. A child genesis carries its
/// spec, which every root holds as its own.
///
/// `proofs` is what a header carries out; `checked` is what a received
/// header brings in: its proofs within the receiver's `maxProofBytes`, each
/// checked where it was decoded (`checkingProofs`). The core takes only
/// `checked`: a proof not checked is unavailable, never judged.
public struct HeaderEntry: Sendable {
    public let block: Block
    public let children: FlatDictionary<BlockHeader>?
    public let proofs: [ChildBlockProof]
    public let checked: [CheckedChildProof]
    public let spec: ChainSpec?
    /// The block's CID when it came with the block: a received header's, the
    /// hash of the bytes it was decoded from, taken where they arrived.
    private let receivedCID: String?

    /// `cid`: the block's CID when already known (a received header's,
    /// hashed from its bytes); nil has `cid` computed from the node. The core
    /// keys the header by it unchecked, so it must be the CID of `block`.
    public init(
        block: Block, children: FlatDictionary<BlockHeader>?, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil,
        cid: String? = nil, checked: [CheckedChildProof] = []
    ) {
        self.block = block
        self.children = children
        self.proofs = proofs
        self.checked = checked
        self.spec = spec
        self.receivedCID = cid
    }

    /// The entry as received at `chainPath`: each proof whose canonical
    /// bytes (`bytes`, when the caller holds them, in `proofs` order) fit
    /// `maxProofBytes` checked, up to the first that fails. A proof over the
    /// limit is left unchecked: a local resource limit, never blamed. None
    /// after a failure is checked: the core disconnects the sender at it
    /// and reads no further, so a page of junk costs one failed check.
    public func checkingProofs(at chainPath: [String], maxProofBytes: Int, bytes: [Data]? = nil) -> HeaderEntry {
        var checked: [CheckedChildProof] = []
        for (index, proof) in proofs.enumerated() {
            guard let data = bytes?[index] ?? (try? proof.serialize()), data.count <= maxProofBytes else { continue }
            let check = CheckedChildProof(proof, bytes: data, of: block, at: chainPath)
            checked.append(check)
            if check.failed { break }
        }
        return HeaderEntry(block: block, children: children, proofs: proofs, spec: spec, cid: receivedCID, checked: checked)
    }

    /// Whether a proof of this received entry failed its check.
    public var failedACheck: Bool { checked.last?.failed == true }

    /// The same entry without its inline children map.
    public func withoutChildren() -> HeaderEntry {
        HeaderEntry(block: block, children: nil, proofs: proofs, spec: spec, cid: receivedCID, checked: checked)
    }

    /// The block's CID: a received header's, hashed once from its bytes; a
    /// header built here, from its node.
    public var cid: String? {
        receivedCID ?? (try? BlockHeader(node: block).rawCID)
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

/// A proof the core credited at a child block, durable beside the work fact
/// it produced.
public struct StoredProof: Sendable {
    public let childCID: String
    public let proof: ChildBlockProof

    public init(childCID: String, proof: ChildBlockProof) {
        self.childCID = childCID
        self.proof = proof
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
///
/// Each object is logged once, known by a bit at its handle in the level's
/// tree: a header at its block's (`ChainTree.handle(of:)`), a proof at its
/// grind's (`grindHandle(of:at:)`, one grind, one block). Handles name the
/// same object for the tree's lifetime, and the tree only grows, so a bit
/// answers exactly as the entry itself would. An entry the tree has no
/// handle for (a durable fact a restore discards) is kept by value.
public struct WeighLog: Sendable {
    public let id: String
    public private(set) var entries: [LogEntry] = []
    private var headers = HandleBits()
    private var proofs = HandleBits()
    private var unhandled: Set<LogEntry> = []

    public init(id: String = "") {
        self.id = id
    }

    /// The log of `entries`, each once, over the tree that took them.
    public init(id: String, entries: [LogEntry], in tree: ChainTree) {
        self.id = id
        for entry in entries { append(entry, in: tree) }
    }

    public var count: UInt64 { UInt64(entries.count) }

    public func contains(_ entry: LogEntry, in tree: ChainTree) -> Bool {
        if unhandled.contains(entry) { return true }
        switch entry.kind {
        // Only `.header(_:)` is logged: one naming another block never was.
        case .header: return entry.cid == entry.block && tree.handle(of: entry.block).map(headers.contains) ?? false
        case .proof: return tree.grindHandle(of: entry.cid, at: entry.block).map(proofs.contains) ?? false
        }
    }

    /// Log `entry` unless it is logged, after `tree` took it. A header is
    /// `.header(_:)`: its bit is its block's, so its cid must be that block.
    @discardableResult
    mutating func append(_ entry: LogEntry, in tree: ChainTree) -> Bool {
        precondition(entry.kind == .proof || entry.cid == entry.block, "a header entry names its own block")
        guard !unhandled.contains(entry) else { return false }
        let inserted = switch entry.kind {
        case .header: tree.handle(of: entry.block).map { headers.insert($0) }
        case .proof: tree.grindHandle(of: entry.cid, at: entry.block).map { proofs.insert($0) }
        }
        guard inserted ?? unhandled.insert(entry).inserted else { return false }
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

/// A set of tree handles, one bit each.
private struct HandleBits: Sendable {
    private var words: [UInt64] = []

    func contains(_ handle: UInt32) -> Bool {
        let word = Int(handle >> 6)
        return word < words.count && words[word] & 1 << (handle & 63) != 0
    }

    mutating func insert(_ handle: UInt32) -> Bool {
        let word = Int(handle >> 6), bit: UInt64 = 1 << (handle & 63)
        if word >= words.count { words += repeatElement(0, count: word + 1 - words.count) }
        guard words[word] & bit == 0 else { return false }
        words[word] |= bit
        return true
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

extension SyncMessage {
    /// The message as a receiver at `chainPath` takes it: a headers page's
    /// proofs checked, as the wire decode checks them where they arrive
    /// (`HeaderEntry.checkingProofs`). Any other message is unchanged.
    public func checkingProofs(at chainPath: [String], maxProofBytes: Int) -> SyncMessage {
        guard case .headers(let response) = self else { return self }
        var failed = false
        return .headers(HeadersResponse(
            requestID: response.requestID,
            entries: response.entries.map { entry in
                // Past a failure the core reads nothing: nothing is checked.
                guard !failed else { return entry }
                let checked = entry.checkingProofs(at: chainPath, maxProofBytes: maxProofBytes)
                failed = checked.failedACheck
                return checked
            },
            hasMore: response.hasMore
        ))
    }
}
