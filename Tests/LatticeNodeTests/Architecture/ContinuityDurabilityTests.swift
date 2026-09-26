import Crypto
import Foundation
import Lattice
import LatticeMinerCore
import cashew
import UInt256
import XCTest
@testable import LatticeNode

final class ContinuityDurabilityTests: XCTestCase {

    private func nonce(
        of block: Block,
        from start: UInt64,
        where accepts: (UInt256) -> Bool
    ) -> UInt64 {
        let midstate = ProofOfWork.midstate(for: block)
        var n = start
        while n - start < (1 << 24) {
            if accepts(ProofOfWork.hash(midstate: midstate, nonce: n)) { return n }
            n += 1
        }
        XCTFail("unsatisfiable nonce search")
        return start
    }

    private func mine(
        on producer: ChainProcess,
        depth: Int,
        miner: (privateKey: String, publicKey: String)
    ) async throws -> [Block] {
        let service = ChainService(
            process: producer,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            acceptedTransactionPublisher: { _ in }
        )
        var blocks: [Block] = []
        for index in 0..<depth {
            let body = TransactionBody(
                accountActions: [AccountAction(
                    owner: CryptoUtils.createAddress(from: miner.publicKey),
                    delta: 1
                )],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: miner.publicKey)],
                fee: 0, nonce: UInt64(index), chainPath: ["Nexus"]
            )
            let header = try HeaderImpl(node: body)
            let signature = try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: miner.privateKey
            ))
            let reward = Transaction(
                signatures: [miner.publicKey: signature], body: header
            )
            let template = try await service.miningTemplate(
                MiningTemplateRequest(rewards: [MiningReward(
                    chainPath: ["Nexus"], transaction: reward
                )])
            )
            let block = template.block.auditReplacingNonce(
                nonce(of: template.block, from: 0) { $0 <= template.block.target }
            )
            let outcome = try await producer.admit(BlockHeader(node: block))
            XCTAssertTrue(outcome.decision.isAccepted, "block \(index)")
            blocks.append(block)
        }
        return blocks
    }

    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-audit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func configuration(_ dir: URL) throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: dir,
            privateKeyHex: String(repeating: "01", count: 32)
        )
    }

    /// EAGER tier: a locally mined chain must still be attestable after a restart.
    func testEagerChainStaysAttestableAcrossRestart() async throws {
        let dir = directory()
        let config = try configuration(dir)
        var process: ChainProcess? = try await ChainProcess.open(configuration: config)
        let chain = try await mine(on: process!, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let live = await process!.hasProducedParentState(tipState)
        XCTAssertTrue(live, "live eager chain must attest its own tip state")

        process = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasProducedParentState(tipState)
        XCTAssertTrue(recovered, "eager chain must still attest its tip state after restart")
    }

    /// WEIGHED -> VALIDATE tier: the path this diff adds the durable fact for.
    func testWalkValidatedChainStaysAttestableAcrossRestart() async throws {
        let producerDir = directory()
        let producer = try await ChainProcess.open(
            configuration: try configuration(producerDir)
        )
        let chain = try await mine(on: producer, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                let outcome = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
                XCTAssertTrue(outcome.decision.isAccepted, "\(mode) admission")
            }
        }
        let live = await consumer!.hasProducedParentState(tipState)
        XCTAssertTrue(live, "live walk-validated chain must attest its tip state")

        consumer = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasProducedParentState(tipState)
        XCTAssertTrue(
            recovered,
            "walk-validated chain must still attest its tip state after restart"
        )
    }

    /// A WEIGHED-only chain must NOT be attestable (the defect being fixed).
    func testWeighedOnlyChainIsNotAttestable() async throws {
        let producerDir = directory()
        let producer = try await ChainProcess.open(
            configuration: try configuration(producerDir)
        )
        let chain = try await mine(on: producer, depth: 3, miner: CryptoUtils.generateKeyPair())
        let tipState = try XCTUnwrap(chain.last).postState.rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for block in chain {
            let outcome = try await consumer!.admit(
                BlockHeader(node: block),
                remoteSource: FetcherContentSource(producer),
                mode: .weighed
            )
            XCTAssertTrue(outcome.decision.isAccepted)
        }
        // Fixture guard: nothing here may have executed, or the assertions
        // below would hold for the wrong reason.
        for block in chain {
            let cid = try BlockHeader(node: block).rawCID
            let executed = await consumer!.blockValidated(cid)
            XCTAssertFalse(
                executed,
                "weighed admission must not mark a block executed"
            )
        }
        let live = await consumer!.hasProducedParentState(tipState)
        XCTAssertFalse(live, "a weighed (unexecuted) tip must not be attestable")

        consumer = nil
        let restarted = try await ChainProcess.open(configuration: config)
        let recovered = await restarted.hasProducedParentState(tipState)
        XCTAssertFalse(
            recovered, "a weighed tip must not become attestable by restarting"
        )
    }

    /// Item 2/3: a demoted (retention-evicted) marker must NOT retract the
    /// durable execution fact, and the restarted chain must still attest.
    func testDemotedMarkerDoesNotRetractExecutionAcrossRestart() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(directory())
        )
        let chain = try await mine(
            on: producer, depth: 3, miner: CryptoUtils.generateKeyPair()
        )
        let tipState = try XCTUnwrap(chain.last).postState.rawCID
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                _ = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
            }
        }
        try await consumer!.demoteValidatedForTesting(tipCID)
        let afterDemote = await consumer!.hasProducedParentState(tipState)
        consumer = nil

        XCTAssertTrue(
            afterDemote,
            """
            A demote is retention bookkeeping — the cached post-state may be \
            evicted — not a retraction of the execution. A live chain must \
            still attest a state it ran.
            """
        )

        let restarted = try await ChainProcess.open(configuration: config)
        let marker = await restarted.blockValidated(tipCID)
        XCTAssertFalse(
            marker,
            """
            Fixture guard: the demote must still be in force after restart. \
            If boot re-promoted the block, the assertion below would pass on \
            the mutable marker and never exercise the durable fact.
            """
        )
        let attestable = await restarted.hasProducedParentState(tipState)
        XCTAssertTrue(
            attestable,
            "a demoted marker must not unmake the durable execution fact"
        )
    }

    /// The serving surface answers ONE question, so there is no cost to
    /// ration. A non-anchor `from` is not a question any correct child can ask,
    /// and is refused as malformed before it can reach the consensus actor —
    /// which is what replaced the old visit budget and the rate limiter alike.
    func testNonAnchorContinuityQuestionIsRefusedAsMalformed() throws {
        let anchor = LatticeState.emptyHeader.rawCID
        let someState = NexusGenesis.expectedBlockHash
        // Both must be well-formed and distinct, or this test would be decided
        // by the canonical-CID or from==to checks and never reach the anchor
        // rule it exists to pin.
        XCTAssertTrue(CIDIdentity.isCanonical(anchor))
        XCTAssertTrue(CIDIdentity.isCanonical(someState))
        XCTAssertNotEqual(anchor, someState)

        // The protocol's own shape survives.
        XCTAssertNoThrow(
            try ParentChainFactMessage(
                requestID: 1,
                fact: .continuity(fromStateCID: anchor, toStateCID: someState)
            ).validate()
        )

        // A general reachability question does not: it is the only way to
        // reach an ancestry walk, and no correct child can ask for one.
        XCTAssertThrowsError(
            try ParentChainFactMessage(
                requestID: 1,
                fact: .continuity(fromStateCID: someState, toStateCID: anchor)
            ).validate()
        ) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
        }
    }

    /// An UPGRADED store — rows written before validation facts existed, so the
    /// mutable tier column is their only execution record — is migrated at boot
    /// into durable facts, and a later demote no longer erases those
    /// executions. Without the migration the chain comes back having forgotten
    /// every execution; without STAGING it (replaying only), the column stays
    /// the sole record and the demote below erases it permanently.
    func testUpgradedStoreMigratesLegacyExecutionsIntoDurableFacts() async throws {
        let producer = try await ChainProcess.open(
            configuration: try configuration(directory())
        )
        let chain = try await mine(
            on: producer, depth: 3, miner: CryptoUtils.generateKeyPair()
        )
        let tipState = try XCTUnwrap(chain.last).postState.rawCID
        let tipCID = try BlockHeader(node: try XCTUnwrap(chain.last)).rawCID

        let dir = directory()
        let config = try configuration(dir)
        var consumer: ChainProcess? = try await ChainProcess.open(configuration: config)
        for mode in [AdmissionMode.weighed, .validate] {
            for block in chain {
                _ = try await consumer!.admit(
                    BlockHeader(node: block),
                    remoteSource: FetcherContentSource(producer),
                    mode: mode
                )
            }
        }
        consumer = nil

        // Simulate a store written by the PREVIOUS build: the tier column is
        // set, but no validation fact/batch was ever written.
        let db = dir.appendingPathComponent("state.db").path
        let genesis = NexusGenesis.expectedBlockHash
        let batchPredicate = """
            CAST(payload AS TEXT) LIKE '%validation%'
              AND CAST(payload AS TEXT) NOT LIKE '%blockHeight%'
            """
        // These DELETEs are matched against the JSON encoding of a batch. If
        // that encoding ever shifts they silently match nothing, the store is
        // never actually "legacy", the migration is never exercised, and the
        // assertions below pass for the wrong reason — so assert each one
        // actually removed rows. Issued SEPARATELY on purpose: sqlite3_prepare
        // compiles only the FIRST statement of a string and drops the rest, so
        // a combined script would run one DELETE and silently skip the other.
        let deletedBatches = try runSQL(
            db, "DELETE FROM admission_batches WHERE \(batchPredicate)"
        )
        XCTAssertGreaterThan(
            deletedBatches, 0,
            """
            Fixture no longer simulates a legacy store: no standalone \
            validation batch matched. The encoding this predicate depends on \
            has changed — fix the predicate, do not delete this assertion.
            """
        )
        let deletedFacts = try runSQL(db, """
            DELETE FROM admission_facts
              WHERE CAST(fact_id AS TEXT) LIKE '%validation%'
                AND CAST(fact_id AS TEXT) NOT LIKE '%\(genesis)%'
            """)
        XCTAssertGreaterThan(
            deletedFacts, 0,
            "no normalized validation fact matched; the fact-id shape changed"
        )
        XCTAssertEqual(
            try queryScalar(
                db,
                "SELECT count(*) FROM admission_batches WHERE \(batchPredicate)"
            ),
            0,
            "every standalone validation batch should now be gone"
        )

        var migrated: ChainProcess? = try await ChainProcess.open(configuration: config)
        let afterMigration = await migrated!.hasProducedParentState(tipState)
        XCTAssertTrue(afterMigration, "the migration must carry legacy history")

        // The migration must have STAGED, not merely replayed: a batch has to
        // be back on disk, or the column is still the sole record and the
        // demote below would erase the execution for good.
        XCTAssertGreaterThan(
            try queryScalar(
                db,
                "SELECT count(*) FROM admission_batches WHERE \(batchPredicate);"
            ),
            0,
            """
            The migration replayed without staging. The mutable column would \
            remain the only record of these executions, and any later demote \
            would erase them permanently.
            """
        )

        // Now demote that legacy row exactly as boot reconciliation or
        // retention eviction would.
        try await migrated!.demoteValidatedForTesting(tipCID)
        migrated = nil
        let reopened = try await ChainProcess.open(configuration: config)
        let afterDemote = await reopened.hasProducedParentState(tipState)
        XCTAssertTrue(
            afterDemote,
            "demoting a migrated pre-fact row must not erase the execution"
        )
    }

    /// In-process, via the same SQLite wrapper the node uses. Shelling out to
    /// `/usr/bin/sqlite3` put a host binary in a unit test's path — the CI
    /// image ships `libsqlite3-dev` (the library), not the CLI, so this test
    /// could only ever run on macOS.
    @discardableResult
    private func runSQL(_ path: String, _ sql: String) throws -> Int {
        let db = try NodeSQLite(path: path)
        return try db.execute(sql)
    }

    private func queryScalar(_ path: String, _ sql: String) throws -> Int {
        let db = try NodeSQLite(path: path)
        guard let value = try db.query(sql).first?.values.first?.intValue else {
            XCTFail("scalar query returned no value: \(sql)")
            return -1
        }
        return Int(value)
    }
}

private extension Block {
    func auditReplacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version, parent: parent, transactions: transactions,
            target: target, nextTarget: nextTarget, spec: spec,
            parentState: parentState, prevState: prevState, postState: postState,
            children: children, height: height, timestamp: timestamp, nonce: nonce
        )
    }
}
