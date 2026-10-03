import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// The mempool and template book under a seeded transaction workload, every
/// invariant checked after every step. `SIM_SEEDS` sets how many seeds run
/// (10 per PR, many nightly); `LATTICE_TEST_SEED` sets the first.
final class TxWorkloadSimulationTests: XCTestCase {
    func testSeeds() async throws {
        let count = try TestBudget.resolve("SIM_SEEDS", default: 10)
        let first = try TestSeed.resolve(default: 0x7A_0000)
        var confirmed = 0
        for offset in 0..<UInt64(count) {
            let seed = first.value &+ offset
            var workload = try await TxWorkload.make(.random(seed: seed))
            do {
                let report = try await workload.run()
                XCTAssertGreaterThan(report.tipHeight, 0, "no block mined — replay with \(TestSeed(value: seed))")
                confirmed += report.confirmed
            } catch {
                return XCTFail("\(error) — replay with \(TestSeed(value: seed))")
            }
        }
        XCTAssertGreaterThan(confirmed, 0, "no workload transaction was ever mined")
        print("simulated \(count) tx workload seeds from \(first), \(confirmed) transactions confirmed")
    }

    func testTheSameSeedReplaysTheSameRun() async throws {
        var config = TxWorkloadConfig.random(seed: 0xD38)
        config.transactions = 30
        config.reorgProbability = 0.15
        config.duplicateProbability = 0.15
        var a = try await TxWorkload.make(config)
        var b = try await TxWorkload.make(config)
        let first = try await a.run()
        let second = try await b.run()
        XCTAssertEqual(first.trace, second.trace)
        XCTAssertEqual(first.steps, second.steps)
        XCTAssertEqual(first.confirmed, second.confirmed)
    }

    /// A deep reorg under a peer flood: the returned set and every peer's
    /// pending admissions stay inside their bounds at every step (checked by
    /// the run), and local submits are still answered.
    func testDeepReorgUnderAPeerFloodStaysBounded() async throws {
        var config = TxWorkloadConfig(seed: 0xF100D)
        config.transactions = 40
        config.reorgProbability = 0.3
        config.maxReorgDepth = 4
        config.floodProbability = 0.3
        config.floodPeers = 6
        config.floodSize = 10
        config.pending = MiningConfig(maxPendingPeerAdmissions: 8, maxPendingPerPeer: 2, maxPendingReturned: 3)
        var workload = try await TxWorkload.make(config)
        let report = try await workload.run()
        XCTAssertGreaterThan(report.reorgs, 0)
        XCTAssertGreaterThan(report.floods, 0)
        // `settle()` already requires every reply to arrive. Count the local
        // transaction outcomes as the liveness assertion this scenario is
        // meant to cover. Whether one remains on the final chain is incidental
        // under repeated deep reorgs, and transaction CIDs vary with CryptoKit's
        // hedged signatures between test processes.
        XCTAssertGreaterThanOrEqual(report.admitted + report.refused, config.transactions)
        XCTAssertGreaterThan(report.skippedJobs, 0, "stale jobs are skipped at dequeue")
    }

    /// The fixed workload keys are real Ed25519 pairs: their signatures verify.
    func testWorkloadKeysSignVerifiably() throws {
        for key in SimTransactions.keys {
            let transaction = try SimTransactions.signed(keys: [key], accountActions: [], nonce: 0)
            let signature = try XCTUnwrap(transaction.signatures[key.publicKey])
            XCTAssertTrue(TransactionSigning.verify(
                bodyHeader: transaction.body, signature: signature, publicKeyHex: key.publicKey
            ))
        }
    }
}
