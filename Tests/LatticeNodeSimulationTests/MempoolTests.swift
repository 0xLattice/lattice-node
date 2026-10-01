import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// Ports of `TransactionPoolArchitectureTests` (MiningAndTransactionPoolTests)
/// to the `Mempool` value: the same admission, replacement, eviction and
/// ordering rules, synchronous, over resolved content.
final class MempoolTests: XCTestCase {
    func testHistoricalBodyCIDInputSignatureIsAccepted() throws {
        let key = CryptoUtils.generateKeyPair()
        let body = transactionBody(
            key: key,
            accountActions: [AccountAction(owner: address(key), delta: -1)],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let header = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(CryptoUtils.sign(message: header.rawCID, privateKeyHex: key.privateKey))
        let transaction = Transaction(signatures: [key.publicKey: signature], body: header)
        var pool = Mempool()

        let cid = try pool.submit(transaction, spec: testSpec(), addedAt: 0).transactionCID

        XCTAssertEqual(cid, try VolumeImpl<Transaction>(node: transaction).rawCID)
        XCTAssertEqual(pool.count, 1)
    }

    func testPoolEnforcesResourcesButLeavesConsensusToLattice() throws {
        let key = CryptoUtils.generateKeyPair()
        let wrongPathBody = transactionBody(
            key: key,
            accountActions: [AccountAction(owner: address(key), delta: -1)],
            nonce: 0,
            chainPath: ["Nexus", "Wrong"]
        )
        let wrongPath = Transaction(
            signatures: [key.publicKey: "not-a-signature"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        var pool = Mempool(limits: MempoolLimits(maxSignatures: 1))

        try pool.submit(wrongPath, spec: testSpec(), addedAt: 0)

        let tooManySignatures = Transaction(
            signatures: ["a": "x", "b": "y"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        XCTAssertThrowsError(try pool.submit(tooManySignatures, spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .tooLarge)
        }

        let detached = try HeaderImpl(node: wrongPathBody).removingNode()
        // The signature-field cap is the wire capacity (UInt16.max); a field
        // one byte past it is too large before anything else is read.
        let oversizedSignature = Transaction(
            signatures: [String(repeating: "a", count: Int(UInt16.max) + 1): "x"],
            body: detached
        )
        XCTAssertThrowsError(try pool.submit(oversizedSignature, spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .tooLarge)
        }

        // The core sees only resolved content: the shell fetches a body first.
        XCTAssertThrowsError(try pool.submit(
            Transaction(signatures: [:], body: detached), spec: testSpec(), addedAt: 0
        )) {
            XCTAssertEqual($0 as? MempoolError, .unresolved)
        }

        let smallSpec = testSpec(maxBlockSize: 64)
        XCTAssertThrowsError(try pool.submit(
            Transaction(signatures: [:], body: try HeaderImpl(node: wrongPathBody)),
            spec: smallSpec,
            addedAt: 0
        )) {
            XCTAssertEqual($0 as? MempoolError, .tooLarge)
        }
        XCTAssertEqual(pool.count, 1)
    }

    func testValueCreatingTransactionIsNeverPooled() throws {
        let key = CryptoUtils.generateKeyPair()
        let minting = try signed(key, [AccountAction(owner: address(key), delta: 5)], nonce: 0)
        var pool = Mempool()
        XCTAssertThrowsError(try pool.submit(minting, spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .invalidState)
        }
    }

    func testWithinASignerNonceOrderBeatsFee() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let later = try signed(key, [AccountAction(owner: address(key), delta: -1)], nonce: 1)
        let earlier = try signed(key, [AccountAction(owner: address(key), delta: -1)], nonce: 0)
        try pool.submit(later, spec: testSpec(), disposition: .future, addedAt: 0)
        try pool.submit(earlier, spec: testSpec(), addedAt: 0)
        XCTAssertEqual(pool.transactions(limit: 2).map(\.body.rawCID), [earlier.body.rawCID, later.body.rawCID])
    }

    func testFutureNonceBecomesEligibleBehindReadyPredecessor() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        let actions = [AccountAction(owner: address(key), delta: -2), AccountAction(owner: recipient, delta: 1)]
        let current = try signed(key, actions, nonce: 0)
        let future = try signed(key, actions, nonce: 1)
        try pool.submit(current, spec: testSpec(), addedAt: 0)
        try pool.submit(future, spec: testSpec(), disposition: .future, addedAt: 0)
        XCTAssertEqual(pool.transactions(limit: .max).map(\.body.node?.nonce), [0, 1])

        // The pool is a value: the copy taken before is the rollback.
        let before = pool
        let removed = pool.reclassify(try Mempool.cid(of: current), as: .invalid)
        pool.reclassify(try Mempool.cid(of: future), as: .ready)

        XCTAssertEqual(removed.removed.count, 1)
        XCTAssertEqual(pool.transactions(limit: .max).map(\.body.node?.nonce), [1])
        XCTAssertEqual(before.transactions(limit: .max).map(\.body.node?.nonce), [0, 1])
    }

    func testDependencyFrontierPreservesMultiSignerNonceOrder() throws {
        var pool = Mempool()
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let first = try signed(firstKey, [], nonce: 0)
        let second = try signed(secondKey, [], nonce: 0)
        let joint = try SimTransactions.signed(keys: [firstKey, secondKey], accountActions: [], nonce: 1, chainPath: ["Nexus"])
        for (transaction, disposition) in [(first, MempoolDisposition.ready), (second, .ready), (joint, .future)] {
            try pool.submit(transaction, spec: testSpec(), disposition: disposition, addedAt: 0)
        }

        let roots = try pool.transactions(limit: .max).map(Mempool.cid(of:))
        XCTAssertEqual(roots.count, 3)
        XCTAssertEqual(roots.last, try Mempool.cid(of: joint))
        XCTAssertEqual(Set(roots.dropLast()), Set(try [first, second].map(Mempool.cid(of:))))
    }

    func testSameSignerAndNonceReplacedByHigherFee() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        let low = try signed(key, [
            AccountAction(owner: address(key), delta: -2), AccountAction(owner: recipient, delta: 1),
        ], nonce: 0)
        let high = try signed(key, [
            AccountAction(owner: address(key), delta: -3), AccountAction(owner: recipient, delta: 1),
        ], nonce: 0)

        try pool.submit(low, spec: testSpec(), addedAt: 0)
        let replacement = try pool.submit(high, spec: testSpec(), addedAt: 0)

        XCTAssertEqual(replacement.replaced.map(\.cid), [try Mempool.cid(of: low)])
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.transactions(limit: 1).first?.body.rawCID, high.body.rawCID)
    }

    func testPartialSignerOverlapAtSameNonceIsRejected() throws {
        var pool = Mempool()
        let firstKey = CryptoUtils.generateKeyPair()
        let sharedKey = CryptoUtils.generateKeyPair()
        let thirdKey = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        let first = try SimTransactions.signed(keys: [firstKey, sharedKey], accountActions: [
            AccountAction(owner: address(firstKey), delta: -1),
            AccountAction(owner: address(sharedKey), delta: -1),
            AccountAction(owner: recipient, delta: 1),
        ], nonce: 0, chainPath: ["Nexus"])
        let overlap = try SimTransactions.signed(keys: [sharedKey, thirdKey], accountActions: [
            AccountAction(owner: address(sharedKey), delta: -1),
            AccountAction(owner: address(thirdKey), delta: -2),
            AccountAction(owner: recipient, delta: 1),
        ], nonce: 0, chainPath: ["Nexus"])

        try pool.submit(first, spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try pool.submit(overlap, spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .conflictingNonce)
        }
        XCTAssertEqual(pool.count, 1)
    }

    func testCapacityKeepsOldestReadyAtEqualFeeAndRejectsNewer() throws {
        var pool = Mempool(limits: MempoolLimits(maxCount: 1))
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        let incumbent = try signed(firstKey, [
            AccountAction(owner: address(firstKey), delta: -2), AccountAction(owner: recipient, delta: 1),
        ], nonce: 0)
        let newer = try signed(secondKey, [
            AccountAction(owner: address(secondKey), delta: -2), AccountAction(owner: recipient, delta: 1),
        ], nonce: 0)

        try pool.submit(incumbent, spec: testSpec(), addedAt: 1_000)
        XCTAssertThrowsError(try pool.submit(newer, spec: testSpec(), addedAt: 2_000)) {
            XCTAssertEqual($0 as? MempoolError, .full)
        }
        XCTAssertEqual(pool.count, 1)
        XCTAssertEqual(pool.transactions(limit: 1).first?.body.rawCID, incumbent.body.rawCID)
    }

    func testReadyTransactionsOutrankNonReadyFeesAtCapacity() throws {
        let ready = try signed(CryptoUtils.generateKeyPair(), [], nonce: 0)
        let futureKey = CryptoUtils.generateKeyPair()
        let future = try signed(futureKey, [AccountAction(owner: address(futureKey), delta: -1_000_000)], nonce: 1)

        var readyPool = Mempool(limits: MempoolLimits(maxCount: 1))
        try readyPool.submit(ready, spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try readyPool.submit(future, spec: testSpec(), disposition: .future, addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .full)
        }

        var futurePool = Mempool(limits: MempoolLimits(maxCount: 1))
        try futurePool.submit(future, spec: testSpec(), disposition: .future, addedAt: 0)
        let mutation = try futurePool.submit(ready, spec: testSpec(), addedAt: 0)
        XCTAssertEqual(mutation.evicted.map(\.transaction.body.rawCID), [future.body.rawCID])
    }

    func testNonReadyQueueIsBoundedPerSigner() throws {
        var pool = Mempool(limits: MempoolLimits(maxNonReadyPerSigner: 1))
        let key = CryptoUtils.generateKeyPair()
        try pool.submit(try signed(key, [], nonce: 1), spec: testSpec(), disposition: .future, addedAt: 0)
        XCTAssertThrowsError(try pool.submit(
            try signed(key, [], nonce: 2), spec: testSpec(), disposition: .unavailable, addedAt: 0
        )) {
            XCTAssertEqual($0 as? MempoolError, .full)
        }
    }

    func testReplaceByFeeRequiresAStrictlyHigherBid() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        // The bid is the real miner fee = debit - credit; a distinct credit
        // gives each attempt its own CID at the same (signer, nonce).
        func tx(debit: Int64, credit: Int64) throws -> Transaction {
            try signed(key, [
                AccountAction(owner: address(key), delta: -debit), AccountAction(owner: recipient, delta: credit),
            ], nonce: 0)
        }

        try pool.submit(tx(debit: 6, credit: 1), spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try pool.submit(tx(debit: 7, credit: 2), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }
        XCTAssertThrowsError(try pool.submit(tx(debit: 5, credit: 1), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }
        let bump = try tx(debit: 7, credit: 1)
        let mutation = try pool.submit(bump, spec: testSpec(), addedAt: 0)
        XCTAssertEqual(mutation.replaced.count, 1)
        XCTAssertEqual(pool.items.map(\.cid), [try Mempool.cid(of: bump)])
    }

    func testCapacityEvictionShedsTheLowestFeeFirst() throws {
        var pool = Mempool(limits: MempoolLimits(maxCount: 2))
        func transaction(minerFee: Int64) throws -> Transaction {
            let key = CryptoUtils.generateKeyPair()
            return try signed(key, [AccountAction(owner: address(key), delta: -minerFee)], nonce: 0)
        }

        let low = try transaction(minerFee: 1)
        let rich = try transaction(minerFee: 10)
        let mid = try transaction(minerFee: 5)
        for tx in [low, rich, mid] { try pool.submit(tx, spec: testSpec(), addedAt: 0) }

        XCTAssertEqual(Set(pool.items.map(\.cid)), Set(try [rich, mid].map(Mempool.cid(of:))))
        XCTAssertThrowsError(try pool.submit(try transaction(minerFee: 1), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .full)
        }
    }

    func testTemplateOrderingLeadsWithTheHighestFeeSigner() throws {
        var pool = Mempool()
        func submit(minerFee: Int64) throws -> String {
            let key = CryptoUtils.generateKeyPair()
            let tx = try signed(key, [AccountAction(owner: address(key), delta: -minerFee)], nonce: 0)
            try pool.submit(tx, spec: testSpec(), addedAt: 0)
            return try Mempool.cid(of: tx)
        }
        let cheap = try submit(minerFee: 1)
        let rich = try submit(minerFee: 100)
        let mid = try submit(minerFee: 20)
        XCTAssertEqual(try pool.transactions(limit: .max).map(Mempool.cid(of:)), [rich, mid, cheap])
    }

    func testNonReadyDeclaredFeeCannotBuyEviction() throws {
        var pool = Mempool(limits: MempoolLimits(maxCount: 1))
        func futureTransaction(debit: Int64) throws -> Transaction {
            let key = CryptoUtils.generateKeyPair()
            return try signed(key, [AccountAction(owner: address(key), delta: -debit)], nonce: 5)
        }
        let older = try futureTransaction(debit: 1)
        try pool.submit(older, spec: testSpec(), disposition: .future, addedAt: 1_000)
        XCTAssertThrowsError(try pool.submit(
            try futureTransaction(debit: 1_000_000), spec: testSpec(), disposition: .future, addedAt: 2_000
        )) {
            XCTAssertEqual($0 as? MempoolError, .full)
        }
        XCTAssertEqual(pool.items.map(\.cid), [try Mempool.cid(of: older)])
    }

    func testNonReadySlotReplacedByStrictlyHigherRealFee() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        func pendingClaim(debit: Int64, credit: Int64) throws -> Transaction {
            try signed(key, [
                AccountAction(owner: address(key), delta: -debit), AccountAction(owner: recipient, delta: credit),
            ], nonce: 5)
        }
        try pool.submit(try pendingClaim(debit: 2, credit: 1), spec: testSpec(), disposition: .future, addedAt: 0)
        XCTAssertThrowsError(try pool.submit(
            try pendingClaim(debit: 3, credit: 2), spec: testSpec(), disposition: .future, addedAt: 0
        )) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }
        let better = try pendingClaim(debit: 5, credit: 1)
        let mutation = try pool.submit(better, spec: testSpec(), disposition: .future, addedAt: 0)
        XCTAssertEqual(mutation.replaced.count, 1)
        XCTAssertEqual(pool.items.map(\.cid), [try Mempool.cid(of: better)])
    }

    func testVersionMovesOnEveryChangeAndOnlyThen() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let tx = try signed(key, [], nonce: 0)
        let start = pool.version
        try pool.submit(tx, spec: testSpec(), addedAt: 0)
        let inserted = pool.version
        XCTAssertGreaterThan(inserted, start)
        try pool.submit(tx, spec: testSpec(), addedAt: 0)
        pool.reclassify(try Mempool.cid(of: tx), as: .ready)
        XCTAssertEqual(pool.version, inserted, "a duplicate and an unchanged verdict change nothing")
        pool.reclassify(try Mempool.cid(of: tx), as: .future)
        XCTAssertGreaterThan(pool.version, inserted)
    }
    // MARK: - Greedy ancestor-package selection

    /// The real fee is the debit excess: a self-debit of `fee` pays it all.
    private func paying(
        _ key: (privateKey: String, publicKey: String), fee: Int64, nonce: UInt64
    ) throws -> Transaction {
        try signed(key, [AccountAction(owner: address(key), delta: -fee)], nonce: nonce)
    }

    private func size(_ transaction: Transaction) throws -> Int {
        try XCTUnwrap(transaction.toData()).count + XCTUnwrap(transaction.body.node?.toData()).count
    }

    func testHighFeeChildPullsInItsLowFeeParent() throws {
        var pool = Mempool()
        let parentKey = CryptoUtils.generateKeyPair()
        let parent = try paying(parentKey, fee: 1, nonce: 0)
        let child = try paying(parentKey, fee: 1_000, nonce: 1)
        let mid = try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0)
        try pool.submit(parent, spec: testSpec(), addedAt: 0)
        // Funding-checked: only a ready surplus counts toward a package.
        try pool.submit(child, spec: testSpec(), disposition: .ready, addedAt: 0)
        try pool.submit(mid, spec: testSpec(), addedAt: 0)

        // The parent alone is the worst rate, but its package with the child
        // is the best, so it leads, parent first.
        XCTAssertEqual(
            try pool.transactions(limit: .max).map(Mempool.cid(of:)),
            try [parent, child, mid].map(Mempool.cid(of:))
        )
    }

    func testPackageSelectionBeatsPerTransactionSelection() throws {
        var pool = Mempool()
        let parentKey = CryptoUtils.generateKeyPair()
        let parent = try paying(parentKey, fee: 1, nonce: 0)
        let child = try paying(parentKey, fee: 1_000, nonce: 1)
        let mid = try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0)
        try pool.submit(parent, spec: testSpec(), addedAt: 0)
        // Funding-checked: only a ready surplus counts toward a package.
        try pool.submit(child, spec: testSpec(), disposition: .ready, addedAt: 0)
        try pool.submit(mid, spec: testSpec(), addedAt: 0)

        // Room for two. Per transaction, the mid (100) and then the parent (1)
        // fit and the child is stranded: 101. The package earns 1_001.
        let expected = try [parent, child].map(Mempool.cid(of:))
        XCTAssertEqual(try pool.transactions(limit: 2).map(Mempool.cid(of:)), expected)
        let twoBytes = try size(parent) + size(child)
        XCTAssertEqual(try pool.transactions(limit: .max, maxBytes: twoBytes).map(Mempool.cid(of:)), expected)
    }

    func testDescendantsAreRescoredWithoutTheirSelectedAncestors() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let rich = try paying(key, fee: 5_000, nonce: 0)
        let poorChild = try paying(key, fee: 1, nonce: 1)
        let other = try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0)
        try pool.submit(rich, spec: testSpec(), addedAt: 0)
        try pool.submit(poorChild, spec: testSpec(), disposition: .future, addedAt: 0)
        try pool.submit(other, spec: testSpec(), addedAt: 0)

        // With its parent counted, the child's package (5_001 over two) beats
        // `other`; once the parent is taken, the child alone (1) does not.
        XCTAssertEqual(
            try pool.transactions(limit: .max).map(Mempool.cid(of:)),
            try [rich, other, poorChild].map(Mempool.cid(of:))
        )
    }

    func testPackageThatDoesNotFitIsSkippedForOneThatDoes() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let parent = try paying(key, fee: 1, nonce: 0)
        let child = try paying(key, fee: 1_000, nonce: 1)
        let single = try paying(CryptoUtils.generateKeyPair(), fee: 10, nonce: 0)
        try pool.submit(parent, spec: testSpec(), addedAt: 0)
        try pool.submit(child, spec: testSpec(), disposition: .ready, addedAt: 0)
        try pool.submit(single, spec: testSpec(), addedAt: 0)

        // One transaction of room: the best package needs two, so it is
        // skipped and the single fills the slot.
        XCTAssertEqual(try pool.transactions(limit: 1).map(Mempool.cid(of:)), [try Mempool.cid(of: single)])
        XCTAssertEqual(
            try pool.transactions(limit: .max, maxBytes: try size(single)).map(Mempool.cid(of:)),
            [try Mempool.cid(of: single)]
        )
    }

    func testNonceGapFutureEntriesAreNeverSelected() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let head = try paying(key, fee: 1, nonce: 0)
        let gapped = try paying(key, fee: 1_000, nonce: 2)
        let behindGap = try paying(key, fee: 1_000, nonce: 3)
        let orphan = try paying(CryptoUtils.generateKeyPair(), fee: 1_000, nonce: 7)
        try pool.submit(head, spec: testSpec(), addedAt: 0)
        for future in [gapped, behindGap, orphan] {
            try pool.submit(future, spec: testSpec(), disposition: .future, addedAt: 0)
        }

        XCTAssertEqual(try pool.transactions(limit: .max).map(Mempool.cid(of:)), [try Mempool.cid(of: head)])
    }

    func testUnavailableEntriesRootPackagesOnlyInContext() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let claim = try paying(key, fee: 1, nonce: 0)
        let next = try paying(key, fee: 50, nonce: 1)
        try pool.submit(claim, spec: testSpec(), disposition: .unavailable, addedAt: 0)
        try pool.submit(next, spec: testSpec(), disposition: .future, addedAt: 0)

        XCTAssertTrue(pool.transactions(limit: .max).isEmpty)
        XCTAssertEqual(
            try pool.contextualTransactions(limit: .max).map(Mempool.cid(of:)),
            try [claim, next].map(Mempool.cid(of:))
        )
    }

    func testMultiSignerPackageTakesEverySignersChain() throws {
        var pool = Mempool()
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let first = try paying(firstKey, fee: 1, nonce: 0)
        let second = try paying(secondKey, fee: 1, nonce: 0)
        let joint = try SimTransactions.signed(
            keys: [firstKey, secondKey],
            accountActions: [AccountAction(owner: address(firstKey), delta: -10_000)],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        let mid = try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0)
        for (transaction, disposition) in [
            (first, MempoolDisposition.ready), (second, .ready), (joint, .future), (mid, .ready),
        ] {
            try pool.submit(transaction, spec: testSpec(), disposition: disposition, addedAt: 0)
        }

        // The joint entry's surplus is unverified, so it lifts nothing; it
        // still follows both of its signers' chains.
        let order = try pool.transactions(limit: .max).map(Mempool.cid(of:))
        XCTAssertEqual(order.first, try Mempool.cid(of: mid))
        XCTAssertEqual(Set(order[1...2]), Set(try [first, second].map(Mempool.cid(of:))))
        XCTAssertEqual(order.last, try Mempool.cid(of: joint))
        // Room for two: the three-transaction package cannot fit.
        let two = try pool.transactions(limit: 2).map(Mempool.cid(of:))
        XCTAssertEqual(two.first, try Mempool.cid(of: mid))
        XCTAssertFalse(two.contains(try Mempool.cid(of: joint)))
    }

    func testForgedFutureSurplusDoesNotLiftItsReadyParent() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        let parent = try paying(key, fee: 1, nonce: 0)
        // Its debit is not funding-checked: the surplus may be unpayable.
        let forged = try paying(key, fee: 1_000_000, nonce: 1)
        let mid = try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0)
        try pool.submit(parent, spec: testSpec(), addedAt: 0)
        try pool.submit(forged, spec: testSpec(), disposition: .future, addedAt: 0)
        try pool.submit(mid, spec: testSpec(), addedAt: 0)

        XCTAssertEqual(
            try pool.transactions(limit: .max).map(Mempool.cid(of:)),
            try [mid, parent, forged].map(Mempool.cid(of:))
        )
    }

    func testNonReadyEntryNeedsEverySignersPredecessorPooled() throws {
        var pool = Mempool()
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let first = try paying(firstKey, fee: 1, nonce: 0)
        // The second signer has nothing pooled at nonce 0.
        let joint = try SimTransactions.signed(
            keys: [firstKey, secondKey],
            accountActions: [AccountAction(owner: address(firstKey), delta: -10)],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        try pool.submit(first, spec: testSpec(), addedAt: 0)
        try pool.submit(joint, spec: testSpec(), disposition: .future, addedAt: 0)

        XCTAssertEqual(try pool.transactions(limit: .max).map(Mempool.cid(of:)), [try Mempool.cid(of: first)])
        XCTAssertEqual(try pool.contextualTransactions(limit: .max).map(Mempool.cid(of:)), [try Mempool.cid(of: first)])
    }

    func testDeepChainSelectsWithinThePackageLimits() throws {
        let depth = 10_000
        var pool = Mempool(limits: MempoolLimits(maxCount: depth))
        let key = CryptoUtils.generateKeyPair()
        let owner = address(key)
        // Signatures are not the pool's concern, and classification does not
        // change the chain's shape, so a cheap ready chain stands in.
        var chain: [String] = []
        for nonce in 0..<depth {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: owner, delta: -1)],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [owner],
                nonce: UInt64(nonce),
                chainPath: ["Nexus"]
            )
            let transaction = Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
            chain.append(try XCTUnwrap(pool.submit(transaction, spec: testSpec(), addedAt: 0).transactionCID))
        }
        XCTAssertEqual(pool.count, depth)

        let start = Date()
        let selected = try pool.transactions(limit: .max).map(Mempool.cid(of:))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "selection is linear in the pool")
        XCTAssertEqual(selected, Array(chain.prefix(25)), "Bitcoin Core's 25-ancestor limit")
    }

}

func address(_ key: (privateKey: String, publicKey: String)) -> String {
    CryptoUtils.createAddress(from: key.publicKey)
}

func signed(
    _ key: (privateKey: String, publicKey: String),
    _ accountActions: [AccountAction],
    nonce: UInt64
) throws -> Transaction {
    try SimTransactions.signed(keys: [key], accountActions: accountActions, nonce: nonce, chainPath: ["Nexus"])
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    accountActions: [AccountAction],
    nonce: UInt64,
    chainPath: [String]
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: [],
        depositActions: [],
        genesisActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [address(key)],
        nonce: nonce,
        chainPath: chainPath
    )
}

func testSpec(maxBlockSize: Int = 1_000_000) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: maxBlockSize,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 100,
        halvingInterval: 10_000,
        halfLife: 10
    )
}
