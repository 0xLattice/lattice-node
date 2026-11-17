import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: what boot does with one damaged row in each table it reads.
///
/// "Boot" is `NodeStorage.open`: `NodeStore.init` (node_metadata) and the
/// local mempool (local_mempool_transactions); then `NodeRuntime.boot`, which
/// replays each hosted level's facts (admission_facts.payload).
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
/// - An undecodable fact: refused with `NodeStoreError.corrupt`.
/// - A row boot does not read: opened. The derived rows (accepted_blocks)
///   are written in their facts' own transaction, so boot does not
///   re-derive them; the read that reads a damaged row refuses it then.
/// - A Volume a fact names gone from volumes.db: opened. Content is fetched
///   when read; its absence is no damage.
///
/// No damage crashes the storage.
final class SafetyNetCorruptStoreTests: XCTestCase {

    /// What `NodeStorage.open` did with the damaged store.
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
            case .missingMaterializedVolume: "NodeStorageError.missingMaterializedVolume"
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
            table: "admission_facts", column: "payload",
            description: "malformed JSON in one fact",
            sql: ["UPDATE admission_facts SET payload = X'00' WHERE fact_id = (SELECT MIN(fact_id) FROM admission_facts)"]
        ),
    ]

    /// Opened: boot does not read these rows.
    private static let unread: [Damage] = [
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
    ]

    /// Refused with `NodeStoreError.malformedRow(table:column:)` naming the
    /// damaged table and column.
    private static let refusedAsMalformedRow: [Damage] = [
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

    func testBootOpensAStoreWhoseUnreadRowsAreDamaged() async throws {
        try await assertBoot(Self.unread, observes: .opened)
    }

    func testBootRefusesDamagedMetadataWithWipeRequired() async throws {
        try await assertBoot(Self.refusedAsWipeRequired, observes: .wipeRequired)
    }

    /// A fact whose content is gone from `volumes.db` does not stop boot:
    /// the store retains what it holds, and what it lacks is fetched when
    /// something reads it.
    func testBootOpensAStoreWhoseVolumesAreGone() async throws {
        let fixture = try await buildFixture()
        let root = try damagedCopy(
            of: fixture, database: "volumes.db",
            // Members before manifests, so the store stays self-consistent
            // and only the facts' references dangle.
            applying: ["DELETE FROM volume_entries", "DELETE FROM volume_metadata"]
        )
        let observed = await observeBoot(at: root)
        XCTAssertEqual(observed, .opened)
    }

    /// A Volume's bytes damaged in volumes.db. The store serves this node's
    /// own reads what it holds without hashing it again, as its bytes were
    /// checked on their way in, so the damage is caught where a read checks bytes against
    /// their CID: the block does not resolve, and the damaged bytes are
    /// never decoded. Nothing repairs them until the right bytes are
    /// stored again.
    func testDamagedVolumeBytesAreServedAndFailTheirCIDCheckWhenRead() async throws {
        let fixture = try await buildFixture()
        let genesis = try configuration(fixture).nexusGenesisCID
        let root = try damagedCopy(
            of: fixture, database: "volumes.db",
            applying: ["UPDATE cas_data SET data = X'00' WHERE cid = '\(genesis)'"]
        )
        let storage = try await NodeStorage.open(configuration: try configuration(root))
        let served = await storage.fetch([genesis])
        XCTAssertEqual(served, [genesis: Data([0])])
        do {
            _ = try await BlockHeader(rawCID: genesis).resolve(fetcher: storage)
            XCTFail("damaged bytes resolved")
        } catch DataErrors.cidMismatch {}
    }

    /// What this node sends a peer is checked first: a Volume holding
    /// damaged bytes is answered as not held, never sent.
    func testDamagedVolumeBytesAreNotSentToAPeer() async throws {
        let fixture = try await buildFixture()
        let genesis = try configuration(fixture).nexusGenesisCID
        let intact = NodeStorageIvyContentSource(
            storage: try await NodeStorage.open(configuration: try configuration(try damagedCopy(of: fixture, applying: [])))
        )
        let sent = await intact.volume(rootCID: genesis, maxDataBytes: .max)
        XCTAssertFalse(sent.isEmpty, "fixture guard: the intact Volume is sent")

        let damaged = NodeStorageIvyContentSource(storage: try await openDamaged(fixture, cid: genesis))
        let refused = await damaged.volume(rootCID: genesis, maxDataBytes: .max)
        XCTAssertTrue(refused.isEmpty)
    }

    /// What the public read routes send is checked first: a Volume holding
    /// damaged bytes is answered as not held, on `/volumes/:cid` and on
    /// `/volumes?cids=`.
    func testDamagedVolumeBytesAreNotServedOnThePublicReadRoutes() async throws {
        let fixture = try await buildFixture()
        let genesis = try configuration(fixture).nexusGenesisCID
        let intact = reads(try await NodeStorage.open(configuration: try configuration(try damagedCopy(of: fixture, applying: []))))
        let archive = await intact.completeVolumeArchive(rootCID: genesis)
        XCTAssertNotNil(archive, "fixture guard: the intact Volume is served")

        let damaged = reads(try await openDamaged(fixture, cid: genesis))
        let refused = await damaged.completeVolumeArchive(rootCID: genesis)
        let records = await damaged.completeVolumeRecords(rootCIDs: [genesis])
        XCTAssertNil(refused)
        XCTAssertEqual(records, CompleteVolumeRecords(body: Data(), complete: false))
    }

    // MARK: - Harness

    /// A copy of `fixture` whose `cid` bytes in volumes.db are damaged, opened.
    private func openDamaged(_ fixture: URL, cid: String) async throws -> NodeStorage {
        let root = try damagedCopy(
            of: fixture, database: "volumes.db",
            applying: ["UPDATE cas_data SET data = X'00' WHERE cid = '\(cid)'"]
        )
        return try await NodeStorage.open(configuration: try configuration(root))
    }

    private func reads(_ storage: NodeStorage) -> ChainReads {
        ChainReads(
            storage: storage,
            tip: { ChainStatus(
                phase: .active, chainPath: ["Nexus"], nexusGenesisCID: storage.configuration.nexusGenesisCID,
                tipCID: storage.configuration.nexusGenesisCID, height: 0, revision: nil
            ) },
            canonicalCID: { _ in nil },
            mempool: { _ in ChainReads.MempoolListing(count: 0, bytes: 0, cids: []) }
        )
    }

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
            let configuration = try configuration(root)
            let storage = try await NodeStorage.open(configuration: configuration)
            _ = try await NodeRuntime.boot(storage: storage, configuration: configuration, coreConfig: .init())
            return .opened
        } catch NodeStoreError.corrupt {
            return .corrupt
        } catch NodeStoreError.malformedRow(let table, let column) {
            return .malformedRow(table: table, column: column)
        } catch NodeStoreError.wipeRequired {
            return .wipeRequired
        } catch NodeStorageError.missingMaterializedVolume {
            return .missingMaterializedVolume
        } catch {
            return .other(String(describing: error))
        }
    }

    /// A valid Nexus store: genesis plus two mined blocks, the runtime
    /// stopped before returning.
    private func buildFixture() async throws -> URL {
        let root = temporaryDirectory()
        let runtime = try await startRuntime(
            try await NodeStorage.open(configuration: try configuration(root))
        )
        for _ in 0..<2 { _ = try await runtime.mineBlock() }
        await runtime.stop()
        return root
    }

    private func damagedCopy(
        of fixture: URL, database name: String = "state.db", applying sql: [String]
    ) throws -> URL {
        let copy = temporaryDirectory()
        try FileManager.default.copyItem(at: fixture, to: copy)
        let database = try NodeSQLite(path: copy.appendingPathComponent(name).path)
        for statement in sql {
            let changed = try database.execute(statement)
            XCTAssertGreaterThan(
                changed, 0,
                "fixture guard: the damage matched no row — \(statement)"
            )
        }
        return copy
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
