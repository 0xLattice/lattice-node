import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct StagedImport: Sendable, Equatable {
    let sequence: Int64
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
    var payload: Data { get throws { try row.blob("payload") } }
    var volumeRoots: Data { get throws { try row.blob("volume_roots") } }
}

/// `admission_facts`: one normalized fact of an admission batch.
struct ImportFactRow: NodeStoreRecord {
    static let table = "admission_facts"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var factID: Data { get throws { try row.blob("fact_id") } }
    var payload: Data { get throws { try row.blob("payload") } }
}

extension NodeStore {
    func stagedImports() async throws -> [StagedImport] {
        try loadStagedImports()
    }

    func loadStagedImports() throws -> [StagedImport] {
        try database.rows(
            ImportBatchRow.self,
            "SELECT seq, payload, volume_roots FROM admission_batches ORDER BY seq ASC"
        ).map { row in
            StagedImport(
                sequence: try row.sequence,
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
        var expectedFacts: [Data: Data] = [:]
        for admission in staged {
            for (id, payload) in try Self.normalizedFacts(in: admission.batch) {
                if let existing = expectedFacts[id], existing != payload {
                    guard try Self.restatesWeighedBlock(existing, as: payload) else {
                        throw NodeStoreError.corrupt(
                            "admission batches disagree about an immutable fact"
                        )
                    }
                }
                expectedFacts[id] = payload
            }
        }

        var actualFacts: [Data: Data] = [:]
        for row in try database.rows(
            ImportFactRow.self, "SELECT fact_id, payload FROM admission_facts"
        ) {
            actualFacts[try row.factID] = try row.payload
        }
        guard actualFacts == expectedFacts else {
            throw NodeStoreError.corrupt(
                "normalized admission facts do not match immutable batches"
            )
        }
    }
}
