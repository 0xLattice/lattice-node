import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

enum NodeStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case wipeRequired(String)
    case conflictingAdmissionFact
    case conflictingAdmissionBatch
    case conflictingIssuedParentFact
    case conflictingIssuedChildProof
    case invalidIssuedChildProof(String)
    case parentEvidenceInboxFull
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
            "The node store is incompatible (\(reason)); stop the process, delete its entire configured storage directory (state.db and volumes.db), and restart."
        case .conflictingAdmissionFact:
            "Conflicting bytes for an immutable chain fact."
        case .conflictingAdmissionBatch:
            "An admission batch was replayed with different Volume roots."
        case .conflictingIssuedParentFact:
            "A locally issued parent fact was replayed with different bytes."
        case .conflictingIssuedChildProof:
            "A locally issued child proof was replayed with different bytes."
        case .invalidIssuedChildProof(let childCID):
            "The proof cached for child \(childCID) does not prove that child from this chain path."
        case .parentEvidenceInboxFull:
            "The pending parent-evidence inbox is full."
        case .corrupt(let reason):
            "The node store is corrupt: \(reason)"
        case .malformedRow(let table, let column):
            "The node store is corrupt: \(table).\(column) is malformed"
        }
    }
}

/// Node-owned immutable facts and availability indexes for one absolute path.
actor NodeStore {
    let database: NodeSQLite
    let nexusGenesisCID: String
    let chainPath: [String]
    let recoveryVolumeBroker: any RetainedRootMergeBroker
    let blockRetentionScope: String
    let issuedRecoveryRetentionScope: String
    let preparedRecoveryRetentionScope: String
    let parentEvidenceInboxRetentionScope: String
    let parentEvidenceInboxCapacity: Int
    let handoffCandidateCapacity: Int
    let contextualCandidateOwner: String
    var preparedMutationInFlight = false
    var preparedMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        databasePath: URL,
        nexusGenesisCID: String,
        chainPath: [String],
        recoveryVolumeBroker: any RetainedRootMergeBroker,
        blockRetentionScope: String,
        issuedRecoveryRetentionScope: String,
        preparedRecoveryRetentionScope: String,
        parentEvidenceInboxRetentionScope: String = "parent-evidence-inbox",
        parentEvidenceInboxCapacity: Int = 64,
        contextualCandidateOwner: String,
        handoffCandidateCapacity: Int = 1_024
    ) throws {
        guard !nexusGenesisCID.isEmpty else {
            throw NodeStoreError.invalidConfiguration("Nexus genesis CID is empty")
        }
        guard chainPath.first == "Nexus", chainPath.allSatisfy({ !$0.isEmpty }) else {
            throw NodeStoreError.invalidConfiguration("chainPath must be absolute and begin with Nexus")
        }
        guard !blockRetentionScope.isEmpty,
              !issuedRecoveryRetentionScope.isEmpty,
              !preparedRecoveryRetentionScope.isEmpty,
              !parentEvidenceInboxRetentionScope.isEmpty,
              parentEvidenceInboxCapacity > 0,
              handoffCandidateCapacity > 0,
              issuedRecoveryRetentionScope != preparedRecoveryRetentionScope,
              issuedRecoveryRetentionScope != parentEvidenceInboxRetentionScope,
              preparedRecoveryRetentionScope != parentEvidenceInboxRetentionScope,
              !contextualCandidateOwner.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "hierarchy retention scopes must be nonempty and distinct"
            )
        }
        let database = try NodeSQLite(path: databasePath.path)
        let pathData = try Self.encode(chainPath)
        let tableNames = Set(try database.rows(
            from: "sqlite_master",
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ).map { try $0.text("name") })

        if tableNames.isEmpty {
            try Self.createSchema(
                in: database,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData
            )
        } else {
            try Self.validateMetadata(
                in: database,
                tableNames: tableNames,
                schemaEpoch: Self.currentSchemaEpoch,
                nexusGenesisCID: nexusGenesisCID,
                chainPath: pathData
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
        self.chainPath = chainPath
        self.recoveryVolumeBroker = recoveryVolumeBroker
        self.blockRetentionScope = blockRetentionScope
        self.issuedRecoveryRetentionScope = issuedRecoveryRetentionScope
        self.preparedRecoveryRetentionScope = preparedRecoveryRetentionScope
        self.parentEvidenceInboxRetentionScope =
            parentEvidenceInboxRetentionScope
        self.parentEvidenceInboxCapacity = parentEvidenceInboxCapacity
        self.contextualCandidateOwner = contextualCandidateOwner
        self.handoffCandidateCapacity = handoffCandidateCapacity
    }

    func acquirePreparedMutation() async {
        guard preparedMutationInFlight else {
            preparedMutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            preparedMutationWaiters.append(continuation)
        }
    }

    func releasePreparedMutation() {
        guard !preparedMutationWaiters.isEmpty else {
            preparedMutationInFlight = false
            return
        }
        preparedMutationWaiters.removeFirst().resume()
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
actor NodeAdmissionStorage: VolumeStorer {
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

