import Foundation
import Lattice
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: what a node recovers from its two stores at boot.
///
/// A deterministic fixture (state.db + volumes.db) is produced in-test, a
/// fresh `ChainProcess` is booted from it, and the booted view — canonical tip
/// and height, validated tip, every accepted block's parent / height /
/// canonicality / leaf flag / durable validation tier / process-level
/// validated flag, the admission log (batch count, each batch's fact kinds in
/// sequence order, normalized fact count — so a boot that re-stages, drops a
/// validation fact or reorders batches is caught), and the volume broker's
/// pinned roots and owners — is
/// compared against the checked-in expectation in
/// `Goldens/boot-recovery.json`, both by value and byte-for-byte (the file
/// must be exactly what the sorted-keys encoder emits, so a hand edit or a
/// stray reformat cannot pass).
///
/// Scenario (all timestamps and nonces fixed, no wall clock, no random keys):
///
///     genesis ── A ── D            A, D: validated off-chain (fork losers)
///        └───── B ── C ── E        B, C, E: canonical, validated
///
/// A producer mines A (canonical), B (accepted side), C (reorg onto B), E
/// (extends the reorged chain) and D (side, extends A). A consumer at the
/// fixture root admits all five weighed, then validates all five, then loses
/// D's validated-owner pin (a retention eviction). The boot under test must
/// demote D to the weighed tier (marker without its pin), keep A validated but
/// non-canonical, and land on E.
///
/// Regenerate with `LATTICE_NODE_REGENERATE_GOLDENS=1`: the file is rewritten
/// and the test then FAILS, so a regeneration can never pass silently — run
/// again without the variable to verify. The next consensus flag day (the
/// Lattice 36 flat child index) changes every block CID; regenerate after it.
final class SafetyNetBootRecoveryGoldenTests: XCTestCase {

    struct Expectation: Codable, Equatable {
        struct AcceptedBlock: Codable, Equatable {
            let cid: String
            let parentCID: String?
            let height: UInt64?
            let admissionSequence: Int64
            let canonical: Bool
            let leaf: Bool
            /// `accepted_blocks.validated`: 0 weighed, 1 eager, 2 walk-validated.
            let storeValidatedTier: Int64
            /// `ChainProcess.blockValidated` after boot (either executed tier).
            let processValidated: Bool
        }

        let schemaEpoch: Int64
        let tipCID: String?
        let canonicalHeight: UInt64?
        let validatedTipCID: String?
        let validatedHeight: UInt64?
        /// Sorted by CID.
        let blocks: [AcceptedBlock]
        let admissionBatchCount: Int
        /// Per batch in `seq` order, the kind of each fact in batch order.
        let admissionBatchFactKinds: [[String]]
        let admissionFactCount: Int
        let pinnedRoots: [String]
        let pinnedOwners: [String]
    }

    private static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Goldens/boot-recovery.json")

    /// The same sorted-keys encoder the store uses for its own payloads, plus
    /// a trailing newline. Compact on purpose: pretty-printing differs between
    /// Foundation implementations and would break the byte comparison on CI.
    private static func encode(_ expectation: Expectation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(expectation) + Data("\n".utf8)
    }

    func testBootRecoveryMatchesGolden() async throws {
        let actual = try await bootedExpectation()
        let actualBytes = try Self.encode(actual)

        if ProcessInfo.processInfo.environment["LATTICE_NODE_REGENERATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.goldenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actualBytes.write(to: Self.goldenURL)
            XCTFail(
                "Regenerated \(Self.goldenURL.path); re-run without "
                    + "LATTICE_NODE_REGENERATE_GOLDENS to verify it."
            )
            return
        }

        guard let onDisk = FileManager.default.contents(atPath: Self.goldenURL.path) else {
            XCTFail(
                "Missing golden \(Self.goldenURL.path); run once with "
                    + "LATTICE_NODE_REGENERATE_GOLDENS=1 to create it."
            )
            return
        }
        let expected = try JSONDecoder().decode(Expectation.self, from: onDisk)

        // Value comparison first: a mismatch names the field.
        XCTAssertEqual(actual.schemaEpoch, expected.schemaEpoch, "schemaEpoch")
        XCTAssertEqual(actual.tipCID, expected.tipCID, "tipCID")
        XCTAssertEqual(actual.canonicalHeight, expected.canonicalHeight, "canonicalHeight")
        XCTAssertEqual(actual.validatedTipCID, expected.validatedTipCID, "validatedTipCID")
        XCTAssertEqual(actual.validatedHeight, expected.validatedHeight, "validatedHeight")
        XCTAssertEqual(
            actual.blocks.map(\.cid), expected.blocks.map(\.cid),
            "accepted block set"
        )
        for (block, expectedBlock) in zip(actual.blocks, expected.blocks)
        where block != expectedBlock {
            XCTFail("block \(block.cid) recovered as \(block), golden says \(expectedBlock)")
        }
        XCTAssertEqual(actual.admissionBatchCount, expected.admissionBatchCount, "admissionBatchCount")
        XCTAssertEqual(
            actual.admissionBatchFactKinds, expected.admissionBatchFactKinds,
            "admissionBatchFactKinds"
        )
        XCTAssertEqual(actual.admissionFactCount, expected.admissionFactCount, "admissionFactCount")
        XCTAssertEqual(actual.pinnedRoots, expected.pinnedRoots, "pinnedRoots")
        XCTAssertEqual(actual.pinnedOwners, expected.pinnedOwners, "pinnedOwners")
        XCTAssertEqual(actual, expected)

        // Byte comparison: the file must be exactly the encoder's output.
        XCTAssertEqual(
            onDisk, actualBytes,
            "golden bytes differ from the sorted-keys encoding of the booted "
                + "view (a hand edit, a reformat, or a real change — regenerate "
                + "with LATTICE_NODE_REGENERATE_GOLDENS=1 if the change is intended)"
        )
        XCTAssertEqual(
            onDisk, try Self.encode(expected),
            "golden bytes are not the canonical encoding of their own value"
        )
    }

    // MARK: - Fixture

    private struct Scenario {
        let root: URL
        let configuration: NodeConfiguration
    }

    /// Builds the fixture, boots a fresh process from it, and reads the view.
    private func bootedExpectation() async throws -> Expectation {
        let scenario = try await buildFixture()
        var booted: ChainProcess? = try await ChainProcess.open(
            configuration: scenario.configuration
        )
        let process = booted!

        let status = await process.status()
        let canonical = await process.canonicalTip()
        var canonicalCIDs = Set<String>()
        if let canonical {
            for height in 0...canonical.height {
                if let cid = await process.mainChainBlockCID(atHeight: height) {
                    canonicalCIDs.insert(cid)
                }
            }
        }

        let database = try NodeSQLite(
            path: scenario.root.appendingPathComponent("state.db").path
        )
        var blocks: [Expectation.AcceptedBlock] = []
        for row in try database.query(
            "SELECT block_cid, parent_cid, admission_seq, validated, leaf FROM accepted_blocks ORDER BY block_cid"
        ) {
            let cid = try XCTUnwrap(row["block_cid"]?.textValue)
            blocks.append(Expectation.AcceptedBlock(
                cid: cid,
                parentCID: row["parent_cid"]?.textValue,
                height: await process.acceptedBlockHeight(cid),
                admissionSequence: try XCTUnwrap(row["admission_seq"]?.intValue),
                canonical: canonicalCIDs.contains(cid),
                leaf: row["leaf"]?.intValue == 1,
                storeValidatedTier: try XCTUnwrap(row["validated"]?.intValue),
                processValidated: await process.blockValidated(cid)
            ))
        }
        let schemaEpoch = try XCTUnwrap(
            try database.query(
                "SELECT schema_epoch FROM node_metadata WHERE singleton = 1"
            ).first?["schema_epoch"]?.intValue
        )
        var batchFactKinds: [[String]] = []
        for row in try database.query(
            "SELECT payload FROM admission_batches ORDER BY seq ASC"
        ) {
            let batch = try JSONDecoder().decode(
                BlockImportBatch.self,
                from: try XCTUnwrap(row["payload"]?.blobValue)
            )
            batchFactKinds.append(batch.facts.map { fact in
                switch fact {
                case .block: "block"
                case .work: "work"
                case .exclusion: "exclusion"
                case .validation: "validation"
                }
            })
        }
        let factCount = try XCTUnwrap(
            try database.query("SELECT COUNT(*) AS n FROM admission_facts")
                .first?["n"]?.intValue
        )

        // Release the storage lock before reading the broker independently.
        booted = nil
        let broker = try DiskBroker(
            path: scenario.root.appendingPathComponent("volumes.db").path
        )
        let pinnedRoots = await broker.pinnedRoots().sorted()
        // Every owner this node writes is prefixed by its retention scope,
        // which starts with the Nexus genesis CID (`pinnedOwners` needs a
        // non-empty prefix).
        let pinnedOwners = await broker.pinnedOwners(
            prefix: scenario.configuration.nexusGenesisCID
        ).sorted()

        return Expectation(
            schemaEpoch: schemaEpoch,
            tipCID: canonical?.cid,
            canonicalHeight: canonical?.height,
            validatedTipCID: status.tipCID,
            validatedHeight: status.height,
            blocks: blocks,
            admissionBatchCount: batchFactKinds.count,
            admissionBatchFactKinds: batchFactKinds,
            admissionFactCount: Int(factCount),
            pinnedRoots: pinnedRoots,
            pinnedOwners: pinnedOwners
        )
    }

    private func buildFixture() async throws -> Scenario {
        let producer = try await ChainProcess.open(
            configuration: try configuration(temporaryDirectory())
        )
        let genesis = try await producer.canonicalTipBlock()
        let a = try await mineChild(of: genesis, timestamp: 3_600_000, on: producer)
        try await admitEager(a, on: producer, expecting: "canonicalized")
        // Equal work: A stays canonical only if Lattice's CID comparator does
        // not prefer B, so B's nonce is searched under that rule rather than
        // assumed from the encoding.
        let b = try await mineChild(
            of: genesis, timestamp: 3_600_001, on: producer,
            notPreferredOver: BlockHeader(node: a).rawCID
        )
        try await admitEager(b, on: producer, expecting: "acceptedSide")
        let c = try await mineChild(of: b, timestamp: 7_200_000, on: producer)
        try await admitEager(c, on: producer, expecting: "canonicalized")
        let e = try await mineChild(of: c, timestamp: 10_800_000, on: producer)
        try await admitEager(e, on: producer, expecting: "canonicalized")
        let d = try await mineChild(of: a, timestamp: 7_200_001, on: producer)
        try await admitEager(d, on: producer, expecting: "acceptedSide")

        let root = temporaryDirectory()
        let configuration = try configuration(root)
        var consumer: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let chain = [a, b, c, e, d]
        for mode in [ImportMode.header, .execution] {
            for block in chain {
                let outcome = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(
                    outcome.decision.isAccepted,
                    "\(mode) admission of block at height \(block.height)"
                )
            }
        }
        // Fixture guard: every block is walk-validated before the eviction.
        for block in chain {
            let cid = try BlockHeader(node: block).rawCID
            let validated = await consumer!.blockValidated(cid)
            XCTAssertTrue(validated, "fixture: \(cid) must be validated before boot")
        }
        // The retained/pruned boundary: D's post-state pin is gone, so boot
        // must demote its marker.
        try await consumer!.unpinValidatedOwnerForTesting(
            try BlockHeader(node: d).rawCID
        )
        consumer = nil
        return Scenario(root: root, configuration: configuration)
    }

    private func admitEager(
        _ block: Block, on process: ChainProcess, expecting: String
    ) async throws {
        let decision = try await process.admit(BlockHeader(node: block)).decision
        let observed: String
        switch decision {
        case .canonicalized: observed = "canonicalized"
        case .acceptedSide: observed = "acceptedSide"
        default: observed = String(describing: decision)
        }
        XCTAssertEqual(
            observed, expecting,
            "fixture: block at height \(block.height) timestamp \(block.timestamp)"
        )
    }

    /// Deterministic mining (the `mineChild` pattern of `ChainProcessTests`):
    /// fixed timestamp, nonce search from zero. With `notPreferredOver`, the
    /// search continues past every nonce whose block the fork-choice
    /// comparator would prefer over that sibling, so the result is a side
    /// block under the consensus rule itself.
    private func mineChild(
        of previous: Block,
        timestamp: Int64,
        on process: ChainProcess,
        notPreferredOver sibling: String? = nil
    ) async throws -> Block {
        // `BlockBuilder.mine` restarts its search at nonce 0, so the search
        // is done here: the nonce is part of the built block and checked with
        // the same proof-of-work hash the validator uses.
        for nonce in UInt64(0)..<(1 << 16) {
            let candidate = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: process
            )
            guard candidate.proofOfWorkHash() <= candidate.target else { continue }
            if let sibling,
               forkChoicePrefersBlock(try BlockHeader(node: candidate).rawCID, over: sibling) {
                continue
            }
            try await BlockHeader(node: candidate).storeBlock(
                fetcher: process,
                storer: process
            )
            return candidate
        }
        XCTFail("fixture: no nonce below 2^16 mined a block at timestamp \(timestamp)")
        throw FixtureError.nonceSearchExhausted
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
            .appendingPathComponent("lattice-safety-net-boot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private enum FixtureError: Error {
    case nonceSearchExhausted
}
