import Foundation
import Lattice
import Synchronization
import LatticeNodeCore
import cashew

/// What a log row records.
public enum LogKind: String, Sendable, CaseIterable {
    /// A block fact with the work that weighed it: a header (with its first
    /// proof, on a child chain). Shared on the weight-fact stream.
    case block
    /// A further grind on a weighed block: on a child chain, another proof.
    /// Shared on the weight-fact stream.
    case work
    /// A parent's attributed run: derived work, never shared.
    case run
    /// Local verdicts, recomputed by every node, never shared.
    case validation
    case exclusion
    /// The host started running a level (`cid` = its genesis); replay
    /// starts the level's facts here.
    case level
    /// The host stopped running a level.
    case drop
}

/// One entry of the weight-fact stream: a header or a proof, by position.
public struct WeightEntry: Sendable, Equatable {
    public let seq: Int64
    public let kind: LogKind
    public let block: String
    /// The contribution that weighs `block`: its grind root.
    public let grind: String
}

/// What a restart reads back: one linear scan of the log.
public struct Restored: Sendable {
    /// The levels the host runs, root first.
    public let records: [LevelRecord]
    /// Each level's facts since its record, in log order.
    public let facts: [ChainPath: [BlockImportBatch]]
    /// The local mempool journal per level, oldest first.
    public let mempool: [ChainPath: [String]]

    /// The host core these facts rebuild.
    ///
    /// REQUIRES the node on Lattice 41. On Lattice 40 the host re-derives its
    /// child levels from genesis links, which this store does not keep
    /// (decision 18d), so the first `.tick` after restore drops every child
    /// level. Lattice 41's multi-root genesis deletes that selection
    /// (`issuers`, `wantedGenesis`, `reconcileChildren`).
    // LATTICE 41: `ChainTree.restore` takes `specs` and a context carrying
    // the root genesis CID; `HostCore.restore` loses `issued`.
    public func host(
        hosted: Set<ChainPath>,
        pins: [ChainPath: String] = [:],
        config: CoreConfig = CoreConfig()
    ) throws -> HostCore {
        try HostCore.restore(records: records, facts: facts, issued: [], hosted: hosted, pins: pins, config: config)
    }
}

/// The node's one store: four tables in one SQLite database.
///
/// - `meta`: the schema version and the root genesis this store belongs to.
/// - `content(cid, bytes, members)`: every content-addressed object.
///   `members` lists a wire Volume's member CIDs on its root row.
/// - `log(seq, chain, kind, cid, fact)`: ONE append-only log of facts, in
///   the order they became durable. Its block and work rows are the
///   weight-fact stream peers resume by `seq`.
/// - `mempool(chain, cid, added_at)`: the local transaction journal.
///
/// Everything else (the weighed graph, weights, verdicts, tips) is derived:
/// a restart replays the log into the trees. Content is collected by
/// reachability from what the log and the mempool name.
public final class Store: Sendable {
    private let connection: Mutex<SQLite>

    /// Open (creating or migrating) the store at `path` for the network whose
    /// root genesis is `rootGenesis`.
    public init(path: String, rootGenesis: String) throws {
        let db = try SQLite(path: path)
        try db.script("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        try Schema.migrate(db)
        if let stored = try Meta.get(Meta.rootGenesis, db) {
            guard stored == rootGenesis else { throw StoreError.wrongNetwork(stored: stored, opened: rootGenesis) }
        } else {
            try Meta.set(Meta.rootGenesis, rootGenesis, db)
        }
        connection = Mutex(db)
    }

    /// Every read and write holds the one connection.
    func locked<T: Sendable>(_ body: (SQLite) throws -> T) throws -> T {
        try connection.withLock { db in try body(db) }
    }

    // MARK: - Writes

    /// Make `batch` durable in ONE transaction: its content first, then the
    /// log rows that reference it. A crash keeps all of it or none of it, so
    /// a durable fact never names absent content.
    public func apply(_ batch: StoreBatch) throws {
        try apply(batch, beforeCommit: {})
    }

    /// `beforeCommit` runs inside the open transaction: tests take a crash
    /// image there.
    func apply(_ batch: StoreBatch, beforeCommit: () throws -> Void) throws {
        let rows = try Self.rows(batch)
        try locked { db in
            try db.transaction {
                try Self.putContent(batch.content, db)
                for row in rows {
                    try db.run(
                        "INSERT INTO log(chain, kind, cid, fact) VALUES(?, ?, ?, ?)",
                        [.text(row.chain), .text(row.kind.rawValue), .text(row.cid), .blob(row.fact)]
                    )
                }
                // Content written before this commit is referenced by now
                // or never will be through this batch: it becomes
                // collectable. Later content waits for the next apply.
                try Meta.set(Meta.collectable, String(
                    try db.first("SELECT COALESCE(MAX(id), 0) FROM content") { $0.int(0) } ?? 0
                ), db)
                try beforeCommit()
            }
        }
    }

    /// Content outside a fact batch (a fetched body, a wire Volume): its own
    /// transaction. Nothing references it until a later batch does.
    public func put(_ entries: [String: Data], volumeRoot: String? = nil) throws {
        try locked { db in
            try db.transaction {
                try Self.putContent(entries, db)
                if let volumeRoot {
                    let members = entries.keys.filter { $0 != volumeRoot }.sorted().joined(separator: "\n")
                    try db.run("UPDATE content SET members = ? WHERE cid = ?", [.blob(Data(members.utf8)), .text(volumeRoot)])
                }
            }
        }
    }

    private static func putContent(_ entries: [String: Data], _ db: SQLite) throws {
        for (cid, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            try db.run("INSERT OR IGNORE INTO content(cid, bytes) VALUES(?, ?)", [.text(cid), .blob(bytes)])
        }
    }

    // MARK: - Mempool

    /// Journal a local transaction with its content, in one transaction.
    public func addToMempool(_ cid: String, content: [String: Data], at path: ChainPath, addedAt: Int64) throws {
        try locked { db in
            try db.transaction {
                try Self.putContent(content, db)
                try db.run(
                    "INSERT OR IGNORE INTO mempool(chain, cid, added_at) VALUES(?, ?, ?)",
                    [.text(Self.key(path)), .text(cid), .int(addedAt)]
                )
            }
        }
    }

    public func removeFromMempool(_ cids: [String], at path: ChainPath) throws {
        try locked { db in
            try db.transaction {
                for cid in cids {
                    try db.run("DELETE FROM mempool WHERE chain = ? AND cid = ?", [.text(Self.key(path)), .text(cid)])
                }
            }
        }
    }

    // MARK: - Reads

    public func content(_ cid: String) throws -> Data? {
        try locked { db in
            try db.first("SELECT bytes FROM content WHERE cid = ?", [.text(cid)]) { $0.blob(0) } ?? nil
        }
    }

    /// A wire Volume: its root and every member it was stored with.
    public func volume(_ root: String) throws -> SerializedVolume? {
        try locked { db in
            try db.transaction {
                guard let members = try db.first("SELECT members FROM content WHERE cid = ?", [.text(root)], { $0.blob(0) }),
                      let members else { return nil }
                var entries: [String: Data] = [:]
                for cid in [root] + String(decoding: members, as: UTF8.self).split(separator: "\n").map(String.init) {
                    guard let bytes = try db.first("SELECT bytes FROM content WHERE cid = ?", [.text(cid)], { $0.blob(0) }),
                          let bytes else { return nil }
                    entries[cid] = bytes
                }
                return SerializedVolume(root: root, entries: entries)
            }
        }
    }

    /// The weight-fact stream of one level: its header and proof entries
    /// after position `seq`, in log order.
    public func weightFacts(_ path: ChainPath, after seq: Int64, limit: Int) throws -> [WeightEntry] {
        try locked { db in
            // Only the level's current run counts: nothing after a drop,
            // nothing before its latest record.
            let start = try db.first(
                "SELECT seq, kind FROM log WHERE chain = ? AND kind IN ('level', 'drop') ORDER BY seq DESC LIMIT 1",
                [.text(Self.key(path))]
            ) { (seq: $0.int(0), dropped: $0.text(1) == LogKind.drop.rawValue) }
            if start?.dropped == true { return [] }
            var entries: [WeightEntry] = []
            try db.each(
                "SELECT seq, kind, cid, fact FROM log WHERE chain = ? AND seq > ? AND kind IN ('block', 'work') ORDER BY seq LIMIT ?",
                [.text(Self.key(path)), .int(max(seq, start?.seq ?? 0)), .int(Int64(limit))]
            ) { row in
                let batch = try Self.decode(row.blob(3) ?? Data())
                let grind = batch.facts.lazy.compactMap { fact -> String? in
                    if case .work(let work) = fact { return work.contribution.id }
                    return nil
                }.first ?? ""
                entries.append(WeightEntry(
                    seq: row.int(0), kind: LogKind(rawValue: row.text(1)) ?? .work, block: row.text(2), grind: grind
                ))
            }
            return entries
        }
    }

    /// Everything a restart needs, from one scan of the log in `seq` order;
    /// content is read only for each level's record (its genesis and spec).
    public func restore() throws -> Restored {
        try locked { db in
            var genesis: [ChainPath: String] = [:]
            var facts: [ChainPath: [BlockImportBatch]] = [:]
            try db.each("SELECT chain, kind, cid, fact FROM log ORDER BY seq") { row in
                let path = Self.path(row.text(0))
                switch LogKind(rawValue: row.text(1)) {
                case .level:
                    genesis[path] = row.text(2)
                    facts[path] = []
                case .drop:
                    genesis[path] = nil
                    facts[path] = nil
                case .some:
                    facts[path, default: []].append(try Self.decode(row.blob(3) ?? Data()))
                case nil:
                    throw StoreError.corrupt("log kind \(row.text(1))")
                }
            }
            var records: [LevelRecord] = []
            for (path, cid) in genesis {
                records.append(try Self.record(path, genesis: cid, db))
            }
            var mempool: [ChainPath: [String]] = [:]
            try db.each("SELECT chain, cid FROM mempool ORDER BY added_at, cid") { row in
                mempool[Self.path(row.text(0)), default: []].append(row.text(1))
            }
            return Restored(
                records: records.sorted { $0.path.count != $1.path.count ? $0.path.count < $1.path.count : Self.key($0.path) < Self.key($1.path) },
                facts: facts.filter { genesis[$0.key] != nil },
                mempool: mempool
            )
        }
    }

    private static func record(_ path: ChainPath, genesis cid: String, _ db: SQLite) throws -> LevelRecord {
        func node<N: Node>(_ cid: String, as type: N.Type) throws -> N {
            guard let bytes = try db.first("SELECT bytes FROM content WHERE cid = ?", [.text(cid)], { $0.blob(0) }),
                  let bytes, let node = N(data: bytes) else {
                throw StoreError.corrupt("level \(Self.key(path)) is missing \(cid)")
            }
            return node
        }
        let block = try node(cid, as: Block.self)
        return LevelRecord(
            path: path,
            spec: try node(block.spec.rawCID, as: ChainSpec.self),
            genesis: StoredHeader(blockCID: cid, block: block, children: try node(block.children.rawCID, as: ChildIndex.self))
        )
    }

    // MARK: - Rows

    struct Row {
        let chain: String
        let kind: LogKind
        let cid: String
        let fact: Data
    }

    /// A batch's log rows: dropped and added levels, then each level's facts.
    /// A Lattice batch splits so every row is one stream object or one
    /// verdict: its block and work facts stay one row (each replays as
    /// one batch), each validation or exclusion is its own.
    static func rows(_ batch: StoreBatch) throws -> [Row] {
        var rows: [Row] = []
        for path in batch.removed {
            rows.append(Row(chain: key(path), kind: .drop, cid: "", fact: Data()))
        }
        for record in batch.added {
            rows.append(Row(chain: key(record.path), kind: .level, cid: record.genesis.blockCID, fact: Data()))
        }
        for (path, facts) in batch.levels {
            for lattice in facts {
                var weight: [ChainFact] = []
                var verdicts: [Row] = []
                for fact in lattice.facts {
                    switch fact {
                    case .block, .work:
                        weight.append(fact)
                    case .validation(let validation):
                        verdicts.append(Row(chain: key(path), kind: .validation, cid: validation.blockHash, fact: try encode([fact])))
                    case .exclusion(let exclusion):
                        verdicts.append(Row(chain: key(path), kind: .exclusion, cid: exclusion.blockHash, fact: try encode([fact])))
                    }
                }
                if let row = try weightRow(weight, chain: key(path)) { rows.append(row) }
                rows += verdicts
            }
        }
        return rows
    }

    private static func weightRow(_ facts: [ChainFact], chain: String) throws -> Row? {
        var kind = LogKind.work
        var cid: String?
        for fact in facts {
            switch fact {
            case .block(let block):
                kind = .block
                cid = block.blockHash
            case .work(let work):
                if kind != .block, work.attributedRun != nil { kind = .run }
                cid = cid ?? work.blockHash
            case .validation, .exclusion:
                break
            }
        }
        guard let cid else { return nil }
        return Row(chain: chain, kind: kind, cid: cid, fact: try encode(facts))
    }

    /// A row's facts in Lattice's own `BlockImportBatch` encoding, so replay
    /// decodes the batch Lattice authenticates.
    // LATTICE 41 (`restore(records:)`): rows decode to records instead.
    private struct Envelope: Encodable {
        let facts: [ChainFact]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func encode(_ facts: [ChainFact]) throws -> Data {
        try encoder.encode(Envelope(facts: facts))
    }

    static func decode(_ data: Data) throws -> BlockImportBatch {
        do {
            return try JSONDecoder().decode(BlockImportBatch.self, from: data)
        } catch {
            throw StoreError.corrupt("undecodable log row: \(error)")
        }
    }

    static func key(_ path: ChainPath) -> String { path.joined(separator: "/") }
    static func path(_ key: String) -> ChainPath { key.split(separator: "/").map(String.init) }
}

// MARK: - cashew

extension Store: Fetcher, ContentSource, Storer, VolumeStorer {
    public func fetch(rawCid: String) async throws -> Data {
        guard let data = try content(rawCid) else { throw FetcherError.notFound(rawCid) }
        return data
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        var found: [String: Data] = [:]
        for cid in cids {
            if let data = try? content(cid) { found[cid] = data }
        }
        return found
    }

    public func store(entries: [String: Data]) async throws {
        try put(entries)
    }

    public func store(volume: SerializedVolume) async throws {
        try put(volume.entries, volumeRoot: volume.root)
    }
}
