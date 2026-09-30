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
