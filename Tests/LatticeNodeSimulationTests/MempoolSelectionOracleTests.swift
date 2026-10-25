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
                let limit = Self.randomLimit(&rng)
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
    /// removals and clears, and changes naming entries already gone. Some
    /// rounds grow one long chain, some sit just under `UInt64.max`, and some
    /// fees are near `Int64.max` so packages pass 64 bits. The model follows
    /// what each mutation reports, and is checked against the pool's
    /// membership before selection is. A refused submit must be one of the
    /// refusals the step can cause.
    func testSelectionMatchesTheRulesAcrossPoolChanges() throws {
        var rng = SplitMix64(state: 0xC4A1)
        let keys = (0..<6).map { Self.key("stateful", $0) }
        let signers = keys.map(address)
        var signerless = 0, cosigned = 0, replaced = 0, evicted = 0, reclassified = 0, removed = 0
        var wide = 0, topNonces = 0, absent = 0
        for round in 0..<60 {
            let long = round % 3 == 2
            // Nonces up to `UInt64.max`, where a run cannot extend further.
            let base: UInt64 = round % 5 == 4 ? .max - 39 : 0
            var gone: [String] = []
            var pool = Mempool(limits: MempoolLimits(
                maxCount: long ? Int(rng.next() % 40) + 60 : Int(rng.next() % 30) + 6,
                maxNonReadyPerSigner: long ? 64 : Int(rng.next() % 6) + 2
            ))
            var model: [String: OracleEntry] = [:]

            func depart(_ items: [MempoolItem]) {
                for item in items {
                    model[item.cid] = nil
                    gone.append(item.cid)
                }
            }

            func submit(_ index: Int, _ bodySigners: [String], nonce: UInt64, _ disposition: MempoolDisposition, step: Int) throws {
                let extra = Int(rng.next() % 3)
                // The last signer pays near-maximal fees, so its runs pass 64 bits.
                let fee = index == signers.count - 1
                    ? Self.wideFee(&rng, extra: extra) : Int(rng.next() % 1_000) + (rng.next() % 4 == 0 ? 0 : 1)
                var actions = [AccountAction(owner: signers[index], delta: -Int64(fee + extra))]
                for other in 0..<extra { actions.append(AccountAction(owner: signers[other], delta: 1)) }
                let body = TransactionBody(
                    accountActions: actions, actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [], signers: bodySigners, nonce: nonce, chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [keys[index].publicKey: "x"], body: try HeaderImpl(node: body))
                let mutation: MempoolMutation
                do {
                    mutation = try pool.submit(transaction, spec: testSpec(), disposition: disposition, addedAt: Int64(step))
                } catch let error as MempoolError {
                    // A lower bid on a taken slot, a slot taken by a co-signed
                    // entry, or no room.
                    XCTAssertTrue([.feeTooLow, .conflictingNonce, .full].contains(error), "round \(round), step \(step): \(error)")
                    return
                }
                guard let inserted = mutation.inserted else { return }
                depart(mutation.departed)
                if fee > Int.max / 2, disposition == .ready { wide += 1 }
                if nonce > .max - 25 { topNonces += 1 }
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
                for nonce in base..<base + 35 {
                    try submit(0, [signers[0]], nonce: nonce, nonce == base ? .ready : [.ready, .ready, .future, .unavailable][Int(rng.next() % 4)], step: 0)
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
                    try submit(index, bodySigners, nonce: base + rng.next() % (long ? 40 : 30), disposition, step: step)
                } else if roll < 80, let cid = rng.next() % 6 == 0 && !gone.isEmpty
                            ? gone.randomElement(using: &rng) : model.keys.sorted().randomElement(using: &rng) {
                    let disposition: MempoolDisposition = [.ready, .future, .unavailable, .invalid][Int(rng.next() % 4)]
                    let mutation = pool.reclassify(cid, as: disposition)
                    depart(mutation.removed)
                    if !mutation.reclassified.isEmpty { model[cid]?.disposition = disposition }
                    if model[cid] == nil && mutation.removed.isEmpty { absent += 1 }
                    reclassified += 1
                } else if roll < 97 {
                    // Long rounds take one entry at a time, so their chain
                    // stays long enough to move a window.
                    var cids = long ? Array(model.keys.sorted().randomElement(using: &rng).map { [$0] } ?? [])
                        : model.keys.sorted().filter { _ in rng.next() % 4 == 0 }
                    if rng.next() % 4 == 0, let old = gone.randomElement(using: &rng) {
                        cids.append(old)
                        if model[old] == nil { absent += 1 }
                    }
                    depart(pool.remove(cids).removed)
                    removed += cids.count
                } else {
                    depart(pool.clear().removed)
                }

                XCTAssertEqual(pool.count, model.count, "round \(round), step \(step): pool count")
                for cid in model.keys { XCTAssertTrue(pool.contains(cid), "round \(round), step \(step): \(cid) missing") }
                for contextual in [false, true] {
                    let limit = Self.randomLimit(&rng)
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
                              ("evicted", evicted), ("reclassified", reclassified), ("removed", removed),
                              ("wide fees", wide), ("top nonces", topNonces), ("absent", absent)] {
            XCTAssertGreaterThan(count, 0, name)
        }
        print("ORACLE-COVERAGE signerless \(signerless) cosigned \(cosigned) replaced \(replaced) evicted \(evicted) reclassified \(reclassified) removed \(removed) wide \(wide) top \(topNonces) absent \(absent)")
    }

    /// Fees past 64 bits once summed (a fee is at most `Int64.max`, so it
    /// takes three): compared exactly by the pool's wide fallback, against
    /// each other and against packages on its 64-bit path. Fees rise along
    /// each run, so a whole run is its best package. Signer 0's pays more per
    /// byte than signer 1's; were wide fees clamped to 64 bits they would tie
    /// on fee and signer 1's, the smaller, would go first.
    func testSelectionComparesPackagesPast64Bits() throws {
        var pool = Mempool()
        var entries: [OracleEntry] = []
        let top = Int(Int64.max) - 10
        let credited = (0..<3).map { address(Self.key("credited", $0)) }
        for (signer, fees, extra) in [(0, [top - 2_000, top - 1_000, top], 3), (1, [top / 2, top - 1_000, top], 0),
                                      (2, [top - 1], 0), (3, [top, 5], 0), (4, [7], 0)] {
            let key = Self.key("wide", signer)
            for (nonce, fee) in fees.enumerated() {
                let body = TransactionBody(
                    accountActions: [AccountAction(owner: address(key), delta: -Int64(fee - extra))]
                        + credited.prefix(extra).map { AccountAction(owner: $0, delta: 1) },
                    actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                    signers: [address(key)], nonce: UInt64(nonce), chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
                let cid = try XCTUnwrap(pool.submit(transaction, spec: testSpec(), addedAt: 0).transactionCID)
                let size = try XCTUnwrap(transaction.toData()).count + XCTUnwrap(body.toData()).count
                entries.append(OracleEntry(
                    cid: cid, signer: address(key), nonce: UInt64(nonce), disposition: .ready, fee: fee - 2 * extra, size: size
                ))
            }
        }
        for limit in [1, 2, 3, 6, .max] {
            XCTAssertEqual(
                try pool.transactions(limit: limit).map(Mempool.cid(of:)),
                oracle(entries, limit: limit, maxBytes: .max, contextual: false),
                "limit \(limit)"
            )
        }
    }

    /// Selection gives up after 1,000 packages in a row fail to fit, as
    /// Bitcoin Core does: a small package behind 1,000 large, better-paying
    /// ones is left out, and behind 999 it is taken.
    func testSelectionStopsAfterAThousandMissesInARow() throws {
        for large in [999, 1_000] {
            var pool = Mempool()
            var entries: [OracleEntry] = []
            let credited = (0..<3).map { address(Self.key("credited", $0)) }
            var smallSize = 0
            for index in 0...large {
                let key = Self.key("miss", index)
                let isSmall = index == large
                let fee = isSmall ? 1 : 1_000_000
                var actions = [AccountAction(owner: address(key), delta: -Int64(fee + (isSmall ? 0 : 3)))]
                if !isSmall { actions += credited.map { AccountAction(owner: $0, delta: 1) } }
                let body = TransactionBody(
                    accountActions: actions, actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [], signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
                let cid = try XCTUnwrap(pool.submit(transaction, spec: testSpec(), addedAt: 0).transactionCID)
                let size = try XCTUnwrap(transaction.toData()).count + XCTUnwrap(body.toData()).count
                if isSmall { smallSize = size }
                entries.append(OracleEntry(cid: cid, signer: address(key), nonce: 0, disposition: .ready, fee: fee, size: size))
            }
            XCTAssertLessThan(smallSize, entries[0].size)
            let chosen = try pool.transactions(limit: .max, maxBytes: smallSize).map(Mempool.cid(of:))
            XCTAssertEqual(chosen, large < 1_000 ? [entries[large].cid] : [], "\(large) large")
            XCTAssertEqual(chosen, oracle(entries, limit: .max, maxBytes: smallSize, contextual: false), "\(large) large")
        }
    }

    /// A transaction limit, sometimes none: production asks for `.max`.
    private static func randomLimit(_ rng: inout SplitMix64) -> Int {
        rng.next() % 6 == 0 ? .max : Int(rng.next() % 40) + 1
    }

    /// A fee near `Int64.max` that still leaves room for `extra` credits of 1.
    private static func wideFee(_ rng: inout SplitMix64, extra: Int) -> Int {
        Int(Int64.max) - extra - Int(rng.next() % 1_000)
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
            // Some signers pay near-maximal fees throughout, so their runs'
            // packages pass 64 bits.
            let paysWide = rng.next() % 6 == 0
            var nonce = rng.next() % 3
            // Long enough, now and then, to meet the 25-entry limit.
            let length = rng.next() % 4 == 0 ? Int(rng.next() % 30 + 20) : Int(rng.next() % 6 + 1)
            for _ in 0..<length {
                if rng.next() % 8 == 0 { nonce += 1 } // a gap starts a new run
                let disposition: MempoolDisposition = [.ready, .ready, .future, .unavailable][Int(rng.next() % 4)]
                let extra = Int(rng.next() % 4)
                let fee = paysWide ? Self.wideFee(&rng, extra: extra) : Int(rng.next() % 1_000_000) + 1
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
            // Exact: 25 fees near `Int64.max` times a summed size fit 128 bits.
            var best: (run: Int, end: Int, fee: Int128, size: Int128)?
            for (index, run) in runs.enumerated() where starts[index] < run.count {
                var fee: Int128 = 0, size: Int128 = 0
                for end in starts[index]..<run.count {
                    fee += run[end].disposition == .ready ? Int128(run[end].fee) : 0
                    size += Int128(run[end].size)
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
            guard members.count <= limit - chosen.count, pick.size <= Int128(maxBytes - bytes) else {
                skipped.insert(runs[pick.run][pick.end].cid)
                misses += 1
                if misses >= 1_000 { break }
                continue
            }
            misses = 0
            chosen += members.map(\.cid)
            bytes += Int(pick.size)
            starts[pick.run] = pick.end + 1
        }
        return chosen
    }
}
