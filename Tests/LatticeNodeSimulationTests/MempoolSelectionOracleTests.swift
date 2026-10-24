import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// Template selection checked against a brute-force statement of its rules,
/// over seeded random pools: nonce chains of mixed classification, fees and
/// sizes, under random transaction and byte limits.
///
/// The rules, as the pool's chains make them: a run is consecutive pooled
/// nonces of one first signer; it is selectable when its head is ready (or,
/// contextually, unavailable), and only its first 25 entries (the package
/// limits). A package is a prefix of what is left of a run; its rate is its
/// ready entries' fees over its size. Each step takes the best-rate package
/// (ties: the smaller CID of its last entry) if it fits, else marks that last
/// entry so no package ends there again.
final class MempoolSelectionOracleTests: XCTestCase {
    func testSelectionMatchesTheBruteForceRules() throws {
        var rng = SplitMix64(state: 0x5EED)
        for round in 0..<60 {
            let generated = try randomPool(&rng)
            for contextual in [false, true] {
                let limit = Int(rng.next() % 40) + 1
                let maxBytes = rng.next() % 3 == 0 ? Int.max : Int(rng.next() % 6_000) + 200
                let chosen = contextual
                    ? generated.pool.contextualTransactions(limit: limit, maxBytes: maxBytes)
                    : generated.pool.transactions(limit: limit, maxBytes: maxBytes)
                XCTAssertEqual(
                    try chosen.map(Mempool.cid(of:)),
                    oracle(generated.entries, limit: limit, maxBytes: maxBytes, contextual: contextual),
                    "round \(round), contextual \(contextual), limit \(limit), maxBytes \(maxBytes)"
                )
            }
        }
    }

    private struct Generated {
        var pool: Mempool
        var entries: [OracleEntry]
    }

    private struct OracleEntry {
        let cid: String
        let signer: String
        let nonce: UInt64
        let disposition: MempoolDisposition
        let fee: Int
        let size: Int
    }

    private func randomPool(_ rng: inout SplitMix64) throws -> Generated {
        var pool = Mempool()
        var entries: [OracleEntry] = []
        let credited = (0..<4).map { _ in address(CryptoUtils.generateKeyPair()) }
        for _ in 0..<Int(rng.next() % 10 + 2) {
            let key = CryptoUtils.generateKeyPair()
            let owner = address(key)
            var nonce = rng.next() % 3
            // Long enough, now and then, to meet the 25-entry limit.
            let length = rng.next() % 4 == 0 ? Int(rng.next() % 30 + 20) : Int(rng.next() % 6 + 1)
            for _ in 0..<length {
                if rng.next() % 8 == 0 { nonce += 1 } // a gap starts a new run
                let disposition: MempoolDisposition = [.ready, .ready, .future, .unavailable][Int(rng.next() % 4)]
                let fee = Int(rng.next() % 1_000_000) + 1
                let extra = Int(rng.next() % 4)
                var actions = [AccountAction(owner: owner, delta: -Int64(fee + extra))]
                for index in 0..<extra { actions.append(AccountAction(owner: credited[index], delta: 1)) }
                let body = TransactionBody(
                    accountActions: actions, actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [], signers: [owner], nonce: nonce, chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
                let cid = try XCTUnwrap(pool.submit(transaction, spec: testSpec(), disposition: disposition, addedAt: 0).transactionCID)
                let size = try XCTUnwrap(transaction.toData()).count + XCTUnwrap(body.toData()).count
                entries.append(OracleEntry(
                    cid: cid, signer: owner, nonce: nonce, disposition: disposition,
                    fee: disposition == .ready ? fee : 0, size: size
                ))
                nonce += 1
            }
        }
        return Generated(pool: pool, entries: entries)
    }

    private func oracle(_ entries: [OracleEntry], limit: Int, maxBytes: Int, contextual: Bool) -> [String] {
        var runs: [[OracleEntry]] = []
        for chain in Dictionary(grouping: entries, by: \.signer).values {
            var run: [OracleEntry] = []
            for entry in chain.sorted(by: { $0.nonce < $1.nonce }) {
                if let last = run.last, last.nonce + 1 != entry.nonce { runs.append(run); run = [] }
                run.append(entry)
            }
            runs.append(run)
        }
        runs = runs.filter {
            $0[0].disposition == .ready || (contextual && $0[0].disposition == .unavailable)
        }.map { Array($0.prefix(25)) }

        var starts = Array(repeating: 0, count: runs.count)
        var skipped = Set<String>()
        var chosen: [String] = []
        var bytes = 0
        var misses = 0
        while chosen.count < limit {
            var best: (run: Int, end: Int, fee: Int, size: Int)?
            for (index, run) in runs.enumerated() where starts[index] < run.count {
                var fee = 0, size = 0
                for end in starts[index]..<run.count {
                    fee += run[end].fee
                    size += run[end].size
                    guard !skipped.contains(run[end].cid) else { continue }
                    if let current = best {
                        let lhs = fee * current.size, rhs = current.fee * size
                        let tip = run[end].cid, currentTip = runs[current.run][current.end].cid
                        guard lhs > rhs || (lhs == rhs && tip < currentTip) else { continue }
                    }
                    best = (index, end, fee, size)
                }
            }
            guard let pick = best else { break }
            let members = runs[pick.run][starts[pick.run]...pick.end]
            guard members.count <= limit - chosen.count, pick.size <= maxBytes - bytes else {
                skipped.insert(runs[pick.run][pick.end].cid)
                misses += 1
                if misses >= 1_000 { break }
                continue
            }
            misses = 0
            chosen += members.map(\.cid)
            bytes += pick.size
            starts[pick.run] = pick.end + 1
        }
        return chosen
    }
}
