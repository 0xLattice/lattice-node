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

/// Runs an actor's jobs, one at a time, on a dispatch queue of its own
/// (`DispatchSerialQueue` is this, but not on Linux). The queue names no
/// QoS: on Darwin each job runs at the QoS of the thread that enqueued it,
/// and a task's later priority escalation does not reach the queue.
final class SerialQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Node-owned immutable facts and availability indexes for one hosted tree.
///
/// Its SQLite calls are synchronous, and a commit waits for its fsync
/// (`synchronous=FULL`), so the actor runs on a serial queue of its own, not
/// the Swift cooperative pool, and the reads made outside it (`reads`) have
/// a connection of their own: a commit blocks that queue's thread, never a
/// pool thread the node's other tasks need. VolumeBroker keeps its writes on
/// a queue, and its reads on another connection one at a time, for the same
/// reason.
actor NodeStore {
    let database: NodeSQLite
    /// The connection the `nonisolated` reads use: in WAL mode, each read
    /// (one at a time, `NodeSQLite`) sees what was committed when it began,
    /// and never waits on a commit.
    let reads: NodeSQLite
    /// The steps whose facts transaction waits in `lane`: read first.
    nonisolated let pending = PendingFacts()
    /// The lane this store's writes of a running node are made in, in the
    /// order the loop asked for them, off the loop.
    nonisolated let lane = StoreLane()
    let nexusGenesisCID: String
    private let executor = SerialQueueExecutor(label: "LatticeNode.NodeStore")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

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
        try database.configureDurability()

        self.database = database
        reads = try NodeSQLite(path: databasePath.path, create: false)
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

/// Collects the Volumes one admission materializes and records their
/// canonical boundaries. Nothing is in the broker until `commit`, which
/// publishes them all in one transaction: all of an admission's content is
/// durable, or none of it. Without a broker the walk keeps only the roots,
/// and the Volumes too when `keepsVolumes` (`takeVolumes`).
actor NodeImportStorage: VolumeStorer {
    private let storage: (any VolumeBroker)?
    private let keepsVolumes: Bool
    private var pending: [ValidatedVolume] = []
    private var roots = Set<String>()

    init(storage: (any VolumeBroker)?, keepsVolumes: Bool = false) {
        self.storage = storage
        self.keepsVolumes = keepsVolumes
    }

    /// Cashew's hook: it hands over each Volume with every entry serialized
    /// from its node and hashed against its CID, so the broker does not hash
    /// it again. Only Volumes a Cashew walk produced come here.
    func store(volume: SerializedVolume) throws {
        if storage != nil || keepsVolumes { pending.append(try ValidatedVolume(trusting: volume)) }
        roots.insert(volume.root)
    }

    /// The Volumes the walk derived and nothing committed: without a
    /// broker, or for a caller that commits them itself.
    func takeVolumes() -> [ValidatedVolume] {
        defer { pending.removeAll() }
        return pending
    }

    func commit() async throws {
        let volumes = pending
        pending.removeAll()
        try await storage?.storeVolumesLocal(volumes)
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
