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

    /// The same rules after every step of random pool changes: submits
    /// (fresh, replacing, conflicting, evicting under tight limits, with
    /// co-signers or no signer), reclassifications (including to invalid),
    /// removals and clears. The model follows what each mutation reports, and
    /// is checked against the pool's membership before selection is.
    func testSelectionMatchesTheRulesAcrossPoolChanges() throws {
        var rng = SplitMix64(state: 0xC4A1)
        let keys = (0..<6).map { Self.key("stateful", $0) }
        let signers = keys.map(address)
        var signerless = 0, cosigned = 0, replaced = 0, evicted = 0, reclassified = 0, removed = 0
        for round in 0..<60 {
            let long = round % 3 == 2
            var pool = Mempool(limits: MempoolLimits(
                maxCount: long ? Int(rng.next() % 40) + 60 : Int(rng.next() % 30) + 6,
                maxNonReadyPerSigner: long ? 64 : Int(rng.next() % 6) + 2
            ))
            var model: [String: OracleEntry] = [:]

            func submit(_ index: Int, _ bodySigners: [String], nonce: UInt64, _ disposition: MempoolDisposition, step: Int) throws {
                let fee = Int(rng.next() % 1_000) + (rng.next() % 4 == 0 ? 0 : 1)
                let extra = Int(rng.next() % 3)
                var actions = [AccountAction(owner: signers[index], delta: -Int64(fee + extra))]
                for other in 0..<extra { actions.append(AccountAction(owner: signers[other], delta: 1)) }
                let body = TransactionBody(
                    accountActions: actions, actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [], signers: bodySigners, nonce: nonce, chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [keys[index].publicKey: "x"], body: try HeaderImpl(node: body))
                guard let mutation = try? pool.submit(transaction, spec: testSpec(), disposition: disposition, addedAt: Int64(step)),
                      let inserted = mutation.inserted else { return }
                for item in mutation.departed { model[item.cid] = nil }
                replaced += mutation.replaced.count
                evicted += mutation.evicted.count
                if bodySigners.isEmpty { signerless += 1 }
                if bodySigners.count > 1 { cosigned += 1 }
                let size = try XCTUnwrap(transaction.toData()).count + XCTUnwrap(body.toData()).count
                model[inserted.cid] = OracleEntry(
                    cid: inserted.cid, signer: bodySigners.first ?? "\u{0}" + inserted.cid, nonce: nonce,
                    disposition: disposition, fee: fee, size: size
                )
            }

            // A long round starts from one signer's 35-nonce chain: changes
            // then land inside, at and past a run's 25-entry window.
            if long {
                for nonce in 0..<UInt64(35) {
                    try submit(0, [signers[0]], nonce: nonce, nonce == 0 ? .ready : [.ready, .ready, .future, .unavailable][Int(rng.next() % 4)], step: 0)
                }
            }
            for step in 0..<80 {
                let roll = rng.next() % 100
                if roll < 55 {
                    let index = long && rng.next() % 2 == 0 ? 0 : Int(rng.next() % UInt64(signers.count))
                    let shape = rng.next() % 20
                    let bodySigners = shape == 0 ? [] : shape < 4
                        ? [signers[index], signers[(index + 1) % signers.count]] : [signers[index]]
                    let disposition: MempoolDisposition = [.ready, .ready, .future, .unavailable][Int(rng.next() % 4)]
                    try submit(index, bodySigners, nonce: rng.next() % (long ? 40 : 30), disposition, step: step)
                } else if roll < 80, let cid = model.keys.sorted().randomElement(using: &rng) {
                    let disposition: MempoolDisposition = [.ready, .future, .unavailable, .invalid][Int(rng.next() % 4)]
                    let mutation = pool.reclassify(cid, as: disposition)
                    for item in mutation.removed { model[item.cid] = nil }
                    if !mutation.reclassified.isEmpty { model[cid]?.disposition = disposition }
                    reclassified += 1
                } else if roll < 97 {
                    let cids = model.keys.sorted().filter { _ in rng.next() % 4 == 0 }
                    for item in pool.remove(cids).removed { model[item.cid] = nil }
                    removed += cids.count
                } else {
                    for item in pool.clear().removed { model[item.cid] = nil }
                }

                XCTAssertEqual(pool.count, model.count, "round \(round), step \(step): pool count")
                for cid in model.keys { XCTAssertTrue(pool.contains(cid), "round \(round), step \(step): \(cid) missing") }
                for contextual in [false, true] {
                    let limit = Int(rng.next() % 40) + 1
                    let maxBytes = rng.next() % 3 == 0 ? Int.max : Int(rng.next() % 6_000) + 200
                    let chosen = contextual
                        ? pool.contextualTransactions(limit: limit, maxBytes: maxBytes)
                        : pool.transactions(limit: limit, maxBytes: maxBytes)
                    XCTAssertEqual(
                        try chosen.map(Mempool.cid(of:)),
                        oracle(Array(model.values), limit: limit, maxBytes: maxBytes, contextual: contextual),
                        "round \(round), step \(step), contextual \(contextual), limit \(limit), maxBytes \(maxBytes)"
                    )
                }
            }
        }
        // Every kind of change was exercised.
        for (name, count) in [("signer-less", signerless), ("co-signed", cosigned), ("replaced", replaced),
                              ("evicted", evicted), ("reclassified", reclassified), ("removed", removed)] {
            XCTAssertGreaterThan(count, 0, name)
        }
        print("ORACLE-COVERAGE signerless \(signerless) cosigned \(cosigned) replaced \(replaced) evicted \(evicted) reclassified \(reclassified) removed \(removed)")
    }

    /// A fixed stand-in key: the pool never checks signatures, and fixed keys
    /// keep every CID, so a failing seed fails the same way again.
    private static func key(_ role: String, _ index: Int) -> (privateKey: String, publicKey: String) {
        ("\(role)-private-\(index)", "\(role)-public-\(index)")
    }

    private struct Generated {
        var pool: Mempool
        var entries: [OracleEntry]
    }

    private struct OracleEntry {
        let cid: String
        /// The chain: its first signer, or `"\u{0}"` + its CID when it has none.
        let signer: String
        let nonce: UInt64
        var disposition: MempoolDisposition
        /// Its surplus; counted only while it is ready.
        let fee: Int
        let size: Int
    }

    private func randomPool(_ rng: inout SplitMix64) throws -> Generated {
        var pool = Mempool()
        var entries: [OracleEntry] = []
        let credited = (0..<4).map { address(Self.key("credited", $0)) }
        for signer in 0..<Int(rng.next() % 10 + 2) {
            let key = Self.key("pool", signer)
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
                    fee: fee, size: size
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
        // A signer-less entry past nonce 0 extends nothing, so it can execute.
        runs = runs.filter {
            $0[0].disposition == .ready || (contextual && $0[0].disposition == .unavailable)
                || ($0[0].signer.hasPrefix("\u{0}") && $0[0].nonce > 0)
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
                    fee += run[end].disposition == .ready ? run[end].fee : 0
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
