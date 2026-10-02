import Foundation
import Lattice
import UInt256
import XCTest
@testable import LatticeNode

/// Safety net: what boot does with one damaged row in each table it reads.
///
/// "Boot" is `ChainProcess.open`: `NodeStore.init` (node_metadata), then the
/// journal audit (admission_batches, admission_facts, accepted_blocks) and
/// the local mempool (local_mempool_transactions).
///
/// Every case starts from one valid fixture (Nexus, two mined blocks), damages
/// exactly one row through SQL, reopens, and records what boot did. The
/// fixture is built once and copied per case, so a case can never see another
/// case's damage.
///
/// - node_metadata: refused with `NodeStoreError.wipeRequired`.
/// - A column that cannot be read as its table declares it: refused with
///   `NodeStoreError.malformedRow(table:column:)` naming exactly the damaged
///   table and column.
/// - Semantic damage the row layer cannot see (undecodable batches, facts
///   that disagree with their batch): refused with `NodeStoreError.corrupt`.
/// - accepted_blocks.leaf disagreeing with the parent links: repaired at boot.
///
/// No damage crashes the process.
final class SafetyNetCorruptStoreTests: XCTestCase {

    /// What `ChainProcess.open` did with the damaged store.
    private enum Observed: Equatable, CustomStringConvertible {
        case corrupt
        case malformedRow(table: String, column: String)
        case wipeRequired
        case missingMaterializedVolume
        case opened
        case other(String)

        var description: String {
            switch self {
            case .corrupt: "NodeStoreError.corrupt"
            case .malformedRow(let table, let column):
                "NodeStoreError.malformedRow(\(table).\(column))"
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
    ]

    /// Refused with `NodeStoreError.malformedRow(table:column:)` naming the
    /// damaged table and column.
    private static let refusedAsMalformedRow: [Damage] = [
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
            table: "accepted_blocks", column: "validated",
            description: "tier 7 (neither weighed, eager nor walk-validated)",
            sql: ["UPDATE accepted_blocks SET validated = 7 WHERE block_cid = (SELECT MIN(block_cid) FROM accepted_blocks WHERE parent_cid IS NOT NULL)"]
        ),
        Damage(
            table: "local_mempool_transactions", column: "transaction_cid",
            description: "inserted malformed CID text",
            sql: ["INSERT INTO local_mempool_transactions (transaction_cid, added_at) VALUES ('not-a-cid', 0)"]
        ),
    ]

    /// Refused with `NodeStoreError.wipeRequired`.
    private static let refusedAsWipeRequired: [Damage] = [
        Damage(
            table: "node_metadata", column: "nexus_genesis_cid",
            description: "a different genesis",
            sql: ["UPDATE node_metadata SET nexus_genesis_cid = 'not-a-cid' WHERE singleton = 1"]
        ),
    ]

    // MARK: - Tests

    /// `refusedAsCorrupt` observes the untyped `.corrupt`; `refusedAsMalformedRow`
    /// observes `.malformedRow` naming exactly the damaged table and column.
    func testBootRefusesDamagedRowsWithTypedErrors() async throws {
        try await assertBoot(Self.refusedAsCorrupt, observes: .corrupt)
        try await assertBoot(Self.refusedAsMalformedRow) { damage in
            .malformedRow(table: damage.table, column: damage.column)
        }
    }

    func testBootRefusesDamagedMetadataWithWipeRequired() async throws {
        try await assertBoot(Self.refusedAsWipeRequired, observes: .wipeRequired)
    }

    /// A leaf flag that disagrees with the parent links is a derived index
    /// and is REPAIRED at boot, not refused.
    func testBootRepairsDisagreeingLeafFlag() async throws {
        let fixture = try await buildFixture()
        // A flipped flag and an out-of-range flag are both a derived index to
        // repair, never a refusal.
        for damage in [
            "UPDATE accepted_blocks SET leaf = 1 - leaf",
            "UPDATE accepted_blocks SET leaf = 2",
        ] {
            let root = try damagedCopy(of: fixture, applying: [damage])
            if damage.hasSuffix("1 - leaf") {
                let flipped = try leafFlags(at: root)
                XCTAssertTrue(
                    flipped.values.contains(true) && flipped.values.contains(false),
                    "fixture guard: the flip must leave both leaf values present"
                )
            }
            let observed = await observeBoot(at: root)
            XCTAssertEqual(observed, .opened, "accepted_blocks.leaf after \(damage)")
            let repaired = try leafFlags(at: root)
            let parents = try parentLinks(at: root)
            for (cid, leaf) in repaired {
                let hasChildren = parents.values.contains(cid)
                XCTAssertEqual(
                    leaf, !hasChildren,
                    "accepted_blocks.leaf for \(cid) was not repaired from the parent links after \(damage)"
                )
            }
        }
    }

    // MARK: - Harness

    private func assertBoot(
        _ damages: [Damage],
        observes expected: Observed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await assertBoot(damages, file: file, line: line) { _ in expected }
    }

    private func assertBoot(
        _ damages: [Damage],
        file: StaticString = #filePath,
        line: UInt = #line,
        observes expected: (Damage) -> Observed
    ) async throws {
        let fixture = try await buildFixture()
        var results: [(Damage, Observed)] = []
        for damage in damages {
            let root = try damagedCopy(of: fixture, applying: damage.sql)
            results.append((damage, await observeBoot(at: root)))
        }
        // Every failure message names the (table, column) it belongs to;
        // `XCTContext.runActivity` is unavailable on swift-corelibs-xctest.
        for (damage, observed) in results {
            let expected = expected(damage)
            XCTAssertEqual(
                observed, expected,
                "\(damage.table).\(damage.column) (\(damage.description)): "
                    + "boot observed \(observed), pinned \(expected)",
                file: file, line: line
            )
        }
    }

    private func observeBoot(at root: URL) async -> Observed {
        do {
            _ = try await ChainProcess.open(configuration: try configuration(root))
            return .opened
        } catch NodeStoreError.corrupt {
            return .corrupt
        } catch NodeStoreError.malformedRow(let table, let column) {
            return .malformedRow(table: table, column: column)
        } catch NodeStoreError.wipeRequired {
            return .wipeRequired
        } catch ChainProcessError.missingMaterializedVolume {
            return .missingMaterializedVolume
        } catch {
            return .other(String(describing: error))
        }
    }

    /// A valid Nexus store: genesis plus two mined blocks, the driver
    /// stopped before returning.
    private func buildFixture() async throws -> URL {
        let root = temporaryDirectory()
        let driver = try await startDriver(
            try await ChainProcess.open(configuration: try configuration(root))
        )
        for _ in 0..<2 { _ = try await driver.mineBlock() }
        await driver.stop()
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
