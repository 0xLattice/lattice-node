import Foundation

public enum StoreError: Error, Equatable {
    case sqlite(String)
    /// The database was written by a newer binary: refuse rather than guess.
    case newerSchema(found: Int, supported: Int)
    /// The database belongs to another network (another root genesis).
    case wrongNetwork(stored: String, opened: String)
    /// A log row or a level's content does not decode.
    case corrupt(String)
    /// Content reachable from a root is not traceable (undecodable bytes):
    /// the collector refuses to sweep rather than lose what it links.
    case untraceable(String)
}

/// The schema as an ordered list of migrations. Each runs once, in its own
/// transaction together with the version bump, so a crash leaves the store
/// at a whole version. A store newer than the binary is refused.
enum Schema {
    struct Migration: Sendable {
        let version: Int
        let apply: @Sendable (SQLite) throws -> Void
    }

    static let migrations: [Migration] = [
        Migration(version: 1) { db in
            try db.script("""
                CREATE TABLE content(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    cid TEXT NOT NULL UNIQUE,
                    bytes BLOB NOT NULL,
                    members BLOB
                );
                CREATE TABLE log(
                    seq INTEGER PRIMARY KEY,
                    chain TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    cid TEXT NOT NULL,
                    fact BLOB NOT NULL
                );
                CREATE INDEX log_chain_seq ON log(chain, seq);
                CREATE TABLE mempool(
                    chain TEXT NOT NULL,
                    cid TEXT NOT NULL,
                    added_at INTEGER NOT NULL,
                    PRIMARY KEY(chain, cid)
                );
                """)
        },
    ]

    static var current: Int { migrations.last?.version ?? 0 }

    static func migrate(_ db: SQLite) throws {
        try db.script("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        let found = try version(db)
        guard found <= current else { throw StoreError.newerSchema(found: found, supported: current) }
        for migration in migrations where migration.version > found {
            try db.transaction {
                try migration.apply(db)
                try Meta.set(Meta.schemaVersion, String(migration.version), db)
            }
        }
    }

    static func version(_ db: SQLite) throws -> Int {
        try Meta.get(Meta.schemaVersion, db).flatMap(Int.init) ?? 0
    }
}

enum Meta {
    static let schemaVersion = "schema_version"
    static let rootGenesis = "nexus_genesis_cid"
    /// The highest `content.id` at the last committed `apply`: the
    /// collector's write barrier.
    static let collectable = "gc_watermark"

    static func get(_ key: String, _ db: SQLite) throws -> String? {
        try db.first("SELECT value FROM meta WHERE key = ?", [.text(key)]) { row in
            row.blob(0).map { String(decoding: $0, as: UTF8.self) }
        } ?? nil
    }

    static func set(_ key: String, _ value: String, _ db: SQLite) throws {
        try db.run(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .blob(Data(value.utf8))]
        )
    }
}
