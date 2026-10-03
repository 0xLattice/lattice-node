import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct StagedImport: Sendable, Equatable {
    let sequence: Int64
    let chainPath: [String]
    let batch: BlockImportBatch
    let volumeRoots: [String]
}

/// `admission_batches`: one immutable admission batch; `payload` and
/// `volumeRoots` are the JSON bytes, decoded by the caller so a decode
/// failure stays `corrupt`.
struct ImportBatchRow: NodeStoreRecord {
    static let table = "admission_batches"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var sequence: Int64 { get throws { try row.int("seq") } }
    var chainPath: String { get throws { try row.nonEmptyText("chain_path") } }
    var payload: Data { get throws { try row.blob("payload") } }
    var volumeRoots: Data { get throws { try row.blob("volume_roots") } }
}

/// `admission_facts`: one normalized fact of an admission batch.
struct ImportFactRow: NodeStoreRecord {
    static let table = "admission_facts"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var chainPath: String { get throws { try row.nonEmptyText("chain_path") } }
    var factID: Data { get throws { try row.blob("fact_id") } }
    var payload: Data { get throws { try row.blob("payload") } }
}

extension NodeStore {
    func stagedImports(at chainPath: [String]? = nil) async throws -> [StagedImport] {
        try loadStagedImports(at: chainPath)
    }

    func loadStagedImports(at chainPath: [String]? = nil) throws -> [StagedImport] {
        let rows: [ImportBatchRow]
        if let chainPath {
            rows = try database.rows(
                ImportBatchRow.self,
                "SELECT seq, chain_path, payload, volume_roots FROM admission_batches WHERE chain_path = ?1 ORDER BY seq ASC",
                params: [.text(chainPath.joined(separator: "/"))]
            )
        } else {
            rows = try database.rows(
                ImportBatchRow.self,
                "SELECT seq, chain_path, payload, volume_roots FROM admission_batches ORDER BY seq ASC"
            )
        }
        return try rows.map { row in
            let components = try row.chainPath.split(separator: "/").map(String.init)
            guard ChainAddress(components) != nil else {
                throw NodeStoreError.corrupt("an admission batch has an invalid chain path")
            }
            return StagedImport(
                sequence: try row.sequence,
                chainPath: components,
                batch: try Self.decode(BlockImportBatch.self, from: try row.payload),
                volumeRoots: try Self.decode([String].self, from: try row.volumeRoots)
            )
        }
    }

    private static func normalizedFacts(
        in batch: BlockImportBatch
    ) throws -> [Data: Data] {
        var normalized: [Data: Data] = [:]
        for fact in batch.facts {
            let id = try encode(fact.id)
            let payload = try encode(fact)
            if let existing = normalized[id], existing != payload {
                throw NodeStoreError.conflictingImportFact
            }
            normalized[id] = payload
        }
        return normalized
    }

    func auditAdmissionFacts(staged: [StagedImport]) throws {
        var expectedFacts: [String: [Data: Data]] = [:]
        for admission in staged {
            let path = admission.chainPath.joined(separator: "/")
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[path]?[id], existing != payload {
                    guard try Self.restatesWeighedBlock(existing, as: payload) else {
                        throw NodeStoreError.corrupt(
                            "admission batches disagree about an immutable fact"
                        )
                    }
                }
                expectedFacts[path, default: [:]][id] = payload
            }
        }

        var actualFacts: [String: [Data: Data]] = [:]
        for row in try database.rows(
            ImportFactRow.self, "SELECT chain_path, fact_id, payload FROM admission_facts"
        ) {
            actualFacts[try row.chainPath, default: [:]][try row.factID] = try row.payload
        }
        guard actualFacts == expectedFacts else {
            throw NodeStoreError.corrupt(
                "normalized admission facts do not match immutable batches"
            )
        }
    }
}
