import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

enum NodeStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case wipeRequired(String)
    case conflictingImportFact
    case corrupt(String)
    /// A column of one row could not be read as the type its table declares
    /// for it (missing, NULL where required, wrong storage class, or outside
    /// the accessor's domain). Semantic corruption (index and batch disagree,
    /// a JSON payload fails to decode, an attachment is missing) stays
    /// `corrupt`.
    case malformedRow(table: String, column: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Invalid node store configuration: \(reason)"
        case .wipeRequired(let reason):
            "The node store is incompatible (\(reason)); stop the process, wipe its complete configured storage directory, and restart."
        case .conflictingImportFact:
            "Conflicting bytes for an immutable chain fact."
        case .corrupt(let reason):
            "The node store is corrupt: \(reason)"
        case .malformedRow(let table, let column):
            "The node store is corrupt: \(table).\(column) is malformed"
        }
    }
}

/// Node-owned immutable facts and availability indexes for one hosted tree.
actor NodeStore {
    let database: NodeSQLite
    let nexusGenesisCID: String

    init(
        databasePath: URL,
        nexusGenesisCID: String
    ) throws {
        guard !nexusGenesisCID.isEmpty else {
            throw NodeStoreError.invalidConfiguration("Nexus genesis CID is empty")
        }
        let database = try NodeSQLite(path: databasePath.path)
        let tableNames = Set(try database.rows(
            from: "sqlite_master",
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).map { try $0.text("name") })

        if tableNames.isEmpty {
            try Self.createSchema(
                in: database,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID
            )
        } else {
            try Self.validateMetadata(
                in: database,
                tableNames: tableNames,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID
            )
            guard tableNames == Self.expectedTables else {
                throw NodeStoreError.wipeRequired("schema tables are missing or unexpected")
            }
        }
        // Indexes are ensured on BOTH branches: an existing store runs no
        // other DDL, so an index added after its creation would never exist.
        try Self.ensureIndexes(in: database)
        try database.configureDurability()

        self.database = database
        self.nexusGenesisCID = nexusGenesisCID
    }


    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NodeStoreError.corrupt(String(describing: error))
        }
    }

}

/// Records the canonical Volume boundaries materialized during one admission.
actor NodeImportStorage: VolumeStorer {
    private let storage: any VolumeStorer
    private var roots = Set<String>()

    init(storage: any VolumeStorer) {
        self.storage = storage
    }

    func store(volume: SerializedVolume) async throws {
        try await storage.store(volume: volume)
        roots.insert(volume.root)
    }

    func takeStoredVolumeRoots() -> [String] {
        defer { roots.removeAll(keepingCapacity: true) }
        return roots.sorted()
    }
}


/// Owner pins represented as VolumeBroker retained roots: one scope per owner
/// name. Merges and advances on one scope are serialized by their callers
/// (the process mutation gate, or boot's storage-directory lock). Sets, not
/// counts: a root retained twice under one owner is released by one release.
extension RetainedRootMergeBroker {
    func retain(_ roots: [String], owner: String) async throws {
        guard !roots.isEmpty else { return }
        try await mergeRetainedRoots(scope: owner, roots: roots)
    }

    func release(_ roots: Set<String>, owner: String) async throws {
        let kept = try await retainedRoots(scope: owner).filter { !roots.contains($0) }
        try await advanceRetainedRoots(scope: owner, roots: kept)
    }
}
