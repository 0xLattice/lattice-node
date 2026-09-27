import Foundation
import Lattice
import UInt256
import XCTest
@testable import LatticeNode

/// Safety net: what boot does with one damaged row in each table it reads.
///
/// "Boot" is `ChainProcess.open`: `NodeStore.init` (node_metadata), then the
/// admission log replay and the normalized-index audit (admission_batches,
/// admission_facts, accepted_blocks, issued_parent_fact_sources,
/// issued_parent_facts, issued_child_edges, issued_child_proofs,
/// parent_evidence_scan, parent_evidence_inbox, prepared_child_proofs,
/// child_genesis_volume_roots, contextual_candidates, contextual_candidate_roots,
/// contextual_candidate_children), the local mempool (local_mempool_transactions),
/// the consensus revision floor (consensus_revision) and the prepared-proof
/// recovery (prepared_child_proofs, pending_child_proof_routes).
///
/// Every case starts from one valid fixture (Nexus, two mined blocks), damages
/// exactly one row through SQL, reopens, and records what boot did. The
/// fixture is built once and copied per case, so a case can never see another
/// case's damage. The tables the fixture leaves empty (the hierarchy and
/// candidate tables of a childless Nexus node) are damaged by INSERTING one
/// malformed row, which is the only row boot can then read.
///
/// Summary of CURRENT behaviour, as pinned by the three tests below
/// (`// TODO(refactor)` marks the cases the refactor should flip to a typed
/// error naming table and column):
///
/// - node_metadata: refused with `NodeStoreError.wipeRequired` (an untyped
///   reason string; the column is not named).
/// - consensus_revision, admission_batches, admission_facts, accepted_blocks
///   (parent / sequence), issued_parent_fact_sources, issued_parent_facts,
///   issued_child_edges, issued_child_proofs, parent_evidence_scan,
///   parent_evidence_inbox, local_mempool_transactions, prepared_child_proofs,
///   contextual_candidates, contextual_candidate_roots,
///   contextual_candidate_children: refused with `NodeStoreError.corrupt`
///   (a free-text reason; neither table nor column is named).
/// - accepted_blocks.validated out of range, child_genesis_volume_roots,
///   pending_child_proof_routes: silently tolerated — boot succeeds with the
///   damaged row in place (TODO).
/// - accepted_blocks.leaf disagreeing with the parent links: repaired at boot
///   (documented behaviour, pinned as such).
///
/// No damage crashes the process today.
final class SafetyNetCorruptStoreTests: XCTestCase {

    /// What `ChainProcess.open` did with the damaged store.
    private enum Observed: Equatable, CustomStringConvertible {
        case corrupt
        case wipeRequired
        case missingMaterializedVolume
        case opened
        case other(String)

        var description: String {
            switch self {
            case .corrupt: "NodeStoreError.corrupt"
            case .wipeRequired: "NodeStoreError.wipeRequired"
            case .missingMaterializedVolume: "ChainProcessError.missingMaterializedVolume"
            case .opened: "opened (damage tolerated)"
            case .other(let error): "other error: \(error)"
            }
        }
    }

    private struct Damage {
        let table: String
        let column: String
        let description: String
        /// Executed one statement at a time (`sqlite3_prepare` compiles only
        /// the first statement of a string).
        let sql: [String]
    }

    // MARK: - Cases

    /// Refused with `NodeStoreError.corrupt`.
    private static let refusedAsCorrupt: [Damage] = [
        Damage(
            table: "consensus_revision", column: "revision",
            description: "non-numeric text",
            sql: ["UPDATE consensus_revision SET revision = 'not-a-number' WHERE singleton = 1"]
        ),
        Damage(
            table: "admission_batches", column: "payload",
            description: "malformed JSON in the newest batch",
            sql: ["UPDATE admission_batches SET payload = X'00' WHERE seq = (SELECT MAX(seq) FROM admission_batches)"]
        ),
        Damage(
            table: "admission_batches", column: "volume_roots",
            description: "malformed JSON in the newest batch",
            sql: ["UPDATE admission_batches SET volume_roots = X'00' WHERE seq = (SELECT MAX(seq) FROM admission_batches)"]
        ),
        Damage(
            table: "admission_facts", column: "payload",
            description: "one fact's bytes no longer match its batch",
            sql: ["UPDATE admission_facts SET payload = X'00' WHERE fact_id = (SELECT MIN(fact_id) FROM admission_facts)"]
        ),
        Damage(
            table: "accepted_blocks", column: "parent_cid",
            description: "empty parent CID on a non-genesis block",
            sql: ["UPDATE accepted_blocks SET parent_cid = '' WHERE block_cid = (SELECT MIN(block_cid) FROM accepted_blocks WHERE parent_cid IS NOT NULL)"]
        ),
        Damage(
            table: "accepted_blocks", column: "admission_seq",
            description: "zero admission sequence",
            sql: ["UPDATE accepted_blocks SET admission_seq = 0 WHERE block_cid = (SELECT MIN(block_cid) FROM accepted_blocks)"]
        ),
        Damage(
            table: "issued_parent_fact_sources", column: "payload",
            description: "inserted malformed JSON source",
            sql: ["INSERT INTO issued_parent_fact_sources (payload) VALUES (X'00')"]
        ),
        Damage(
            table: "issued_parent_facts", column: "payload",
            description: "inserted fact with no source",
            sql: ["INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES ('carrier', 'x', 'y', X'00')"]
        ),
        Damage(
            table: "issued_child_edges", column: "edge_cid",
            description: "inserted edge without an attachment",
            sql: ["INSERT INTO issued_child_edges (edge_cid, parent_carrier_cid, directory, child_cid) VALUES ('not-a-cid', 'carrier', 'Payments', 'child')"]
        ),
        Damage(
            table: "issued_child_proofs", column: "root_cid",
            description: "inserted proof with malformed CID text",
            sql: ["INSERT INTO issued_child_proofs (scope, edge_cid, root_cid, attachment_cid, ordinal) VALUES ('outgoing_direct_child', 'edge', 'not-a-cid', 'not-a-cid', 1)"]
        ),
        Damage(
            table: "parent_evidence_scan", column: "source_id",
            description: "non-UUID source",
            sql: ["UPDATE parent_evidence_scan SET source_id = 'not-a-uuid' WHERE singleton = 1"]
        ),
        Damage(
            table: "parent_evidence_inbox", column: "attachment_cid",
            description: "inserted entry with malformed CID text",
            sql: ["INSERT INTO parent_evidence_inbox (source_id, ordinal, child_cid, root_cid, attachment_cid) VALUES ('00000000-0000-4000-8000-000000000001', 1, 'child', 'root', 'not-a-cid')"]
        ),
        Damage(
            table: "local_mempool_transactions", column: "transaction_cid",
            description: "inserted malformed CID text",
            sql: ["INSERT INTO local_mempool_transactions (transaction_cid, added_at) VALUES ('not-a-cid', 0)"]
        ),
        Damage(
            table: "prepared_child_proofs", column: "attachment_cid",
            description: "inserted proof with malformed CID text",
            sql: ["INSERT INTO prepared_child_proofs (carrier_cid, batch_seq, directory, child_cid, is_child_genesis, attachment_cid) VALUES ('carrier', 1, 'Payments', 'child', 0, 'not-a-cid')"]
        ),
        Damage(
            table: "contextual_candidates", column: "candidate_cid",
            description: "inserted candidate without roots",
            sql: ["INSERT INTO contextual_candidates (candidate_cid, offer_seq, issued, handoff, handoff_seq) VALUES ('not-a-cid', 1, 0, 0, NULL)"]
        ),
        Damage(
            table: "contextual_candidate_roots", column: "root_cid",
            description: "inserted root without a candidate",
            sql: ["INSERT INTO contextual_candidate_roots (candidate_cid, root_cid) VALUES ('orphan', 'not-a-cid')"]
        ),
        Damage(
            table: "contextual_candidate_children", column: "child_peer_key",
            description: "inserted child without a candidate",
            sql: ["INSERT INTO contextual_candidate_children (candidate_cid, child_peer_key, child_cid) VALUES ('orphan', 'not-a-peer-key', 'child')"]
        ),
    ]

    /// Refused with `NodeStoreError.wipeRequired`.
    private static let refusedAsWipeRequired: [Damage] = [
        Damage(
            table: "node_metadata", column: "sync_source_id",
            description: "non-UUID sync source",
            sql: ["UPDATE node_metadata SET sync_source_id = 'not-a-uuid' WHERE singleton = 1"]
        ),
        Damage(
            table: "node_metadata", column: "nexus_genesis_cid",
            description: "a different genesis",
            sql: ["UPDATE node_metadata SET nexus_genesis_cid = 'not-a-cid' WHERE singleton = 1"]
        ),
    ]

    /// Boot succeeds with the damaged row still in place.
    // TODO(refactor): should be a typed error naming table and column.
    private static let silentlyTolerated: [Damage] = [
        Damage(
            table: "accepted_blocks", column: "validated",
            description: "tier 7 (neither weighed, eager nor walk-validated)",
            sql: ["UPDATE accepted_blocks SET validated = 7 WHERE block_cid = (SELECT MIN(block_cid) FROM accepted_blocks WHERE parent_cid IS NOT NULL)"]
        ),
        Damage(
            table: "child_genesis_volume_roots", column: "root_cid",
            description: "inserted malformed CID text for an unknown child",
            sql: ["INSERT INTO child_genesis_volume_roots (child_cid, root_cid) VALUES ('child', 'not-a-cid')"]
        ),
        Damage(
            table: "pending_child_proof_routes", column: "carrier_cid",
            description: "inserted route with an empty carrier",
            sql: ["INSERT INTO pending_child_proof_routes (carrier_cid, batch_seq, directory) VALUES ('', 1, 'Payments')"]
        ),
    ]

    // MARK: - Tests

    func testBootRefusesDamagedRowsWithNodeStoreErrorCorrupt() async throws {
        try await assertBoot(Self.refusedAsCorrupt, observes: .corrupt)
    }

    func testBootRefusesDamagedMetadataWithWipeRequired() async throws {
        try await assertBoot(Self.refusedAsWipeRequired, observes: .wipeRequired)
    }

    // TODO(refactor): should be a typed error naming table and column.
    func testBootSilentlyToleratesDamagedRowsTODO() async throws {
        try await assertBoot(Self.silentlyTolerated, observes: .opened)
    }

    /// A leaf flag that disagrees with the parent links is a derived index
    /// and is REPAIRED at boot, not refused.
    func testBootRepairsDisagreeingLeafFlag() async throws {
        let fixture = try await buildFixture()
        let root = try damagedCopy(of: fixture, applying: [
            "UPDATE accepted_blocks SET leaf = 1 - leaf",
        ])
        let flipped = try leafFlags(at: root)
        XCTAssertTrue(
            flipped.values.contains(true) && flipped.values.contains(false),
            "fixture guard: the flip must leave both leaf values present"
        )
        let observed = await observeBoot(at: root)
        XCTAssertEqual(observed, .opened, "accepted_blocks.leaf")
        let repaired = try leafFlags(at: root)
        let parents = try parentLinks(at: root)
        for (cid, leaf) in repaired {
            let hasChildren = parents.values.contains(cid)
            XCTAssertEqual(
                leaf, !hasChildren,
                "accepted_blocks.leaf for \(cid) was not repaired from the parent links"
            )
        }
    }

    // MARK: - Harness

    private func assertBoot(
        _ damages: [Damage],
        observes expected: Observed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try await buildFixture()
        var results: [(Damage, Observed)] = []
        for damage in damages {
            let root = try damagedCopy(of: fixture, applying: damage.sql)
            results.append((damage, await observeBoot(at: root)))
        }
        // `runActivity` is synchronous and main-actor isolated, so the async
        // boots above are gathered first and reported here, one activity per
        // (table, column).
        await MainActor.run {
            for (damage, observed) in results {
                XCTContext.runActivity(
                    named: "\(damage.table).\(damage.column): \(damage.description)"
                ) { _ in
                    XCTAssertEqual(
                        observed, expected,
                        "\(damage.table).\(damage.column) (\(damage.description)): "
                            + "boot observed \(observed), pinned \(expected)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    private func observeBoot(at root: URL) async -> Observed {
        do {
            let process = try await ChainProcess.open(
                configuration: try configuration(root)
            )
            _ = await process.status()
            return .opened
        } catch NodeStoreError.corrupt {
            return .corrupt
        } catch NodeStoreError.wipeRequired {
            return .wipeRequired
        } catch ChainProcessError.missingMaterializedVolume {
            return .missingMaterializedVolume
        } catch {
            return .other(String(describing: error))
        }
    }

    /// A valid Nexus store: genesis plus two deterministically mined blocks,
    /// closed (storage lock released) before returning.
    private func buildFixture() async throws -> URL {
        let root = temporaryDirectory()
        var producer: ChainProcess? = try await ChainProcess.open(
            configuration: try configuration(root)
        )
        var previous = try await producer!.canonicalTipBlock()
        for timestamp in [Int64(3_600_000), 7_200_000] {
            let candidate = try await BlockBuilder.buildBlock(
                previous: previous, timestamp: timestamp, fetcher: producer!
            )
            let mined = try XCTUnwrap(BlockBuilder.mine(
                block: candidate, target: candidate.target, maxAttempts: 1 << 16
            ))
            try await BlockHeader(node: mined).storeBlock(
                fetcher: producer!, storer: producer!
            )
            let outcome = try await producer!.admit(BlockHeader(node: mined))
            XCTAssertTrue(outcome.decision.isAccepted, "fixture block \(timestamp)")
            previous = mined
        }
        producer = nil
        return root
    }

    private func damagedCopy(of fixture: URL, applying sql: [String]) throws -> URL {
        let copy = temporaryDirectory()
        try FileManager.default.copyItem(at: fixture, to: copy)
        let database = try NodeSQLite(path: copy.appendingPathComponent("state.db").path)
        for statement in sql {
            let changed = try database.execute(statement)
            XCTAssertGreaterThan(
                changed, 0,
                "fixture guard: the damage matched no row — \(statement)"
            )
        }
        return copy
    }

    private func leafFlags(at root: URL) throws -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for row in try NodeSQLite(path: root.appendingPathComponent("state.db").path)
            .query("SELECT block_cid, leaf FROM accepted_blocks") {
            flags[try XCTUnwrap(row["block_cid"]?.textValue)] = row["leaf"]?.intValue == 1
        }
        return flags
    }

    private func parentLinks(at root: URL) throws -> [String: String] {
        var links: [String: String] = [:]
        for row in try NodeSQLite(path: root.appendingPathComponent("state.db").path)
            .query("SELECT block_cid, parent_cid FROM accepted_blocks WHERE parent_cid IS NOT NULL") {
            links[try XCTUnwrap(row["block_cid"]?.textValue)] =
                try XCTUnwrap(row["parent_cid"]?.textValue)
        }
        return links
    }

    private func configuration(_ storage: URL) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-safety-net-corrupt-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
