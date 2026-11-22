import Foundation
import Lattice
import UInt256
import XCTest
import cashew
import LatticeNodeCore
@testable import LatticeBlockTree
@testable import LatticeNode

/// A store from before block facts lost their state diff (no `fact_format`,
/// every block fact encoding an empty `"stateDiff"`) is re-encoded once when
/// it opens, so a block fact staged again matches its row.
final class FactFormatMigrationTests: XCTestCase {
    private let alpha: ChainPath = ["Nexus", "Alpha"]
    private let context = try! ChainRuntimeContext(path: ["Nexus", "Alpha"])

    private static func cid(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: "fact-format:\(seed)")).rawCID
    }

    private struct Work: Encodable {
        let id: String
        let work: UInt256
    }

    private static func work(_ work: UInt256, at hash: String) throws -> ChainFact {
        .work(ChainWorkFact(blockHash: hash, contribution: try JSONDecoder().decode(
            VerifiedWorkContribution.self, from: JSONEncoder().encode(Work(id: cid("grind-\(hash)"), work: work))
        )))
    }

    /// A genesis, executed, and a child weighed on it.
    private func batches() throws -> [BlockImportBatch] {
        let max = String(repeating: "f", count: 64)
        let (genesis, child) = (Self.cid("genesis"), Self.cid("child"))
        let state = Self.cid("state")
        return [
            BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: genesis, parentBlockHash: nil, blockHeight: 0,
                    postStateCID: state, prevStateCID: state, specCID: Self.cid("spec"),
                    target: max, nextTarget: max, timestamp: 0
                )),
                try Self.work(1, at: genesis),
                .validation(ChainValidationFact(blockHash: genesis)),
            ]),
            BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: child, parentBlockHash: genesis, blockHeight: 1,
                    postStateCID: Self.cid("child-state"), prevStateCID: state, specCID: Self.cid("spec"),
                    target: max, nextTarget: max, timestamp: 1
                )),
                try Self.work(2, at: child),
            ]),
        ]
    }

    private func blockPayloads(_ database: NodeSQLite) throws -> [Data] {
        try database.query("SELECT payload FROM admission_facts ORDER BY chain_path, seq, ord")
            .compactMap { $0["payload"]?.blobValue }
            .filter { $0.starts(with: Data(#"{"block":"#.utf8)) }
    }

    private func factFormat(_ database: NodeSQLite) throws -> String? {
        try database.query("SELECT value FROM core_meta WHERE key = 'fact_format'").first?["value"]?.textValue
    }

    /// A store staged with `batches`, then rewritten to the old format: each
    /// block fact as the old encoder wrote it (sorted keys, the empty diff
    /// between `specCID` and `target`), and no format recorded.
    private func legacyStore() async throws -> URL {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        let store = try NodeStore(databasePath: path, nexusGenesisCID: "genesis")
        try await store.stageChainFacts(try batches(), logID: "log", at: alpha)
        let database = try NodeSQLite(path: path.path)
        let rows = try database.query("SELECT chain_path, seq, ord, payload FROM admission_facts")
        var rewritten = 0
        for row in rows {
            guard let payload = row["payload"]?.blobValue,
                  payload.starts(with: Data(#"{"block":"#.utf8)) else { continue }
            let text = String(decoding: payload, as: UTF8.self)
            let old = text.replacingOccurrences(
                of: #","target":"#, with: #","stateDiff":{"created":{},"replaced":{}},"target":"#
            )
            XCTAssertNotEqual(old, text)
            _ = try database.execute(
                "UPDATE admission_facts SET payload = ?1 WHERE chain_path = ?2 AND seq = ?3 AND ord = ?4",
                params: [.blob(Data(old.utf8)), row["chain_path"]!, row["seq"]!, row["ord"]!]
            )
            rewritten += 1
        }
        XCTAssertEqual(rewritten, 2, "fixture: both block facts are in the old format")
        _ = try database.execute("DELETE FROM core_meta WHERE key = 'fact_format'")
        return path
    }

    func testAFreshStoreRecordsTheCurrentFormat() throws {
        let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
        _ = try NodeStore(databasePath: path, nexusGenesisCID: "genesis")
        XCTAssertEqual(try factFormat(try NodeSQLite(path: path.path)), NodeStore.currentFactFormat)
    }

    func testAnOldFormatStoreMigratesOnceAndRestagesWithoutConflict() async throws {
        let expected = try ChainTree.restore(replaying: try batches(), context: context)
        let path = try await legacyStore()
        let database = try NodeSQLite(path: path.path)
        XCTAssertTrue(try blockPayloads(database).allSatisfy {
            String(decoding: $0, as: UTF8.self).contains(#""stateDiff""#)
        })

        let store = try NodeStore(databasePath: path, nexusGenesisCID: "genesis")
        XCTAssertEqual(try factFormat(database), NodeStore.currentFactFormat)
        let migrated = try blockPayloads(database)
        XCTAssertEqual(migrated.count, 2)
        for payload in migrated {
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("stateDiff"))
            XCTAssertEqual(payload, try NodeStore.encode(try NodeStore.decode(ChainFact.self, from: payload)))
        }

        // The same facts staged again are held, not a conflict, and add none.
        try await store.stageChainFacts(try batches(), logID: "log", at: alpha)
        let stored = try await store.storedFacts(at: alpha)
        XCTAssertEqual(stored.facts, try batches().flatMap(\.facts))

        let restored = try ChainTree.restore(facts: stored.facts, context: context)
        XCTAssertEqual(restored.canonicalTip, expected.canonicalTip)
        for hash in [Self.cid("genesis"), Self.cid("child")] {
            XCTAssertEqual(restored.forkChoiceWeight(of: hash), expected.forkChoiceWeight(of: hash))
            XCTAssertEqual(restored.isExecuted(blockHash: hash), expected.isExecuted(blockHash: hash))
            XCTAssertEqual(restored.parent(of: hash), expected.parent(of: hash))
        }

        // Once: a second open finds the format recorded and rewrites nothing.
        _ = try NodeStore(databasePath: path, nexusGenesisCID: "genesis")
        XCTAssertEqual(try blockPayloads(database), migrated)
    }

    /// The migration is what makes re-staging safe: the old bytes, left in
    /// place, refuse the same fact as a conflict.
    func testWithoutTheMigrationRestagingTheSameFactConflicts() async throws {
        let path = try await legacyStore()
        _ = try NodeSQLite(path: path.path).execute(
            "INSERT INTO core_meta (key, value) VALUES ('fact_format', ?1)",
            params: [.text(NodeStore.currentFactFormat)]
        )
        let store = try NodeStore(databasePath: path, nexusGenesisCID: "genesis")
        do {
            try await store.stageChainFacts(try batches(), logID: "log", at: alpha)
            XCTFail("an old-format block fact matched its re-staged copy")
        } catch NodeStoreError.conflictingImportFact {}
    }

    func testAnUnknownFormatIsRefused() async throws {
        let path = try await legacyStore()
        _ = try NodeSQLite(path: path.path).execute(
            "INSERT INTO core_meta (key, value) VALUES ('fact_format', '3')"
        )
        XCTAssertThrowsError(try NodeStore(databasePath: path, nexusGenesisCID: "genesis")) { error in
            guard case NodeStoreError.wipeRequired = error else { return XCTFail("got \(error)") }
        }
    }
}
