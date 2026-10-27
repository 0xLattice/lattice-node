import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// The `Mempool` value: admission, claims and replacement, eviction and
/// fee-rate ordering, synchronous, over resolved content. Everything pooled
/// was ready; a verdict is `MiningState`'s concern.
final class MempoolTests: XCTestCase {
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

    func testATransactionMustLeaveRoomForTheBlockAroundIt() throws {
        let spec = testSpec()
        let room = Mempool.transactionRoom(spec)
        XCTAssertLessThan(room, spec.maxBlockSize)
        // The allowance is the same on any chain.
        XCTAssertEqual(Mempool.transactionRoom(testSpec(maxBlockSize: 4_000)), 4_000 - (spec.maxBlockSize - room))
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 0))
        XCTAssertNoThrow(try pool.submit(try storing(size: room), spec: spec, addedAt: 0))
        XCTAssertThrowsError(try pool.submit(try storing(size: room + 1), spec: spec, addedAt: 0)) {
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
        XCTAssertEqual(pool.nextBlock(testSpec()).first?.body.rawCID, high.body.rawCID)
    }

    /// The claim is a signer's nonce, not the signer: a pooled transaction
    /// whose nonce the tip has since used never blocks the signer's next,
    /// which needs no higher fee.
    func testAStaleNonceNeverBlocksTheSignersNext() throws {
        var pool = Mempool()
        let key = CryptoUtils.generateKeyPair()
        try pool.submit(try paying(key, fee: 50, nonce: 0), spec: testSpec(), addedAt: 0)
        try pool.submit(try paying(key, fee: 1, nonce: 1), spec: testSpec(), addedAt: 0)
        XCTAssertEqual(pool.count, 2)
    }

    /// A co-signer (a fee sponsor) backs as many pooled transactions as its
    /// balance pays, under any first signers, and no more.
    func testACoSignerBacksAsManyTransactionsAsItsBalancePays() throws {
        var pool = Mempool()
        let sponsor = CryptoUtils.generateKeyPair()
        func sponsored(fee: Int64, client: (privateKey: String, publicKey: String) = CryptoUtils.generateKeyPair()) throws -> Transaction {
            try SimTransactions.signed(keys: [client, sponsor], accountActions: [
                AccountAction(owner: address(sponsor), delta: -fee),
            ], nonce: 0, chainPath: ["Nexus"])
        }
        let balance = [address(sponsor): UInt64(25)]
        let client = CryptoUtils.generateKeyPair()
        try pool.submit(try sponsored(fee: 10, client: client), spec: testSpec(), addedAt: 0, balances: balance)
        try pool.submit(try sponsored(fee: 10), spec: testSpec(), addedAt: 0, balances: balance)
        XCTAssertThrowsError(try pool.submit(try sponsored(fee: 10), spec: testSpec(), addedAt: 0, balances: balance)) {
            XCTAssertEqual($0 as? MempoolError, .insufficientFunds, "25 pays two fees of 10, not three")
        }
        // Its own transaction draws on the same balance.
        XCTAssertThrowsError(try pool.submit(try paying(sponsor, fee: 6, nonce: 0), spec: testSpec(), addedAt: 0, balances: balance)) {
            XCTAssertEqual($0 as? MempoolError, .insufficientFunds)
        }
        try pool.submit(try paying(sponsor, fee: 5, nonce: 0), spec: testSpec(), addedAt: 0, balances: balance)
        XCTAssertEqual(pool.count, 3)

        // A replacement's debit stands in for the one it replaces; one that
        // still does not fit must outbid what else the account pays for.
        XCTAssertThrowsError(try pool.submit(try sponsored(fee: 11, client: client), spec: testSpec(), addedAt: 0, balances: balance)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "10 + 5 + 11 is over 25, and 11 does not outbid 10 and 5")
        }
        XCTAssertEqual(try pool.submit(
            try sponsored(fee: 11, client: client), spec: testSpec(), addedAt: 0, balances: [address(sponsor): 26]
        ).replaced.count, 1)
    }

    /// A transaction an account's balance cannot also pay displaces that
    /// account's lowest-paying transactions when it pays more than them.
    func testAHigherPayerDisplacesAnAccountsLowestPaying() throws {
        var pool = Mempool()
        let sponsor = CryptoUtils.generateKeyPair()
        func sponsored(fee: Int64) throws -> Transaction {
            try SimTransactions.signed(keys: [CryptoUtils.generateKeyPair(), sponsor], accountActions: [
                AccountAction(owner: address(sponsor), delta: -fee),
            ], nonce: 0, chainPath: ["Nexus"])
        }
        let balance = [address(sponsor): UInt64(20)]
        try pool.submit(try sponsored(fee: 12), spec: testSpec(), addedAt: 0, balances: balance)
        let low = try sponsored(fee: 6)
        try pool.submit(low, spec: testSpec(), addedAt: 0, balances: balance)
        XCTAssertThrowsError(try pool.submit(try sponsored(fee: 6), spec: testSpec(), addedAt: 0, balances: balance)) {
            XCTAssertEqual($0 as? MempoolError, .insufficientFunds, "6 does not outbid 6")
        }
        // 12 + 8 fits 20 once the 6 is gone, and 8 pays it and the increment.
        let high = try sponsored(fee: 8)
        let mutation = try pool.submit(high, spec: testSpec(), addedAt: 0, balances: balance)
        XCTAssertEqual(mutation.replaced.map(\.cid), [try Mempool.cid(of: low)])
        XCTAssertEqual(pool.count, 2)
    }

    /// When a verdict reads less on an account than the pool debits it,
    /// its lowest-paying transactions leave until the rest fit.
    func testAnAccountThatCanPayLessShedsItsLowestPaying() throws {
        var pool = Mempool()
        let sponsor = CryptoUtils.generateKeyPair()
        var cids: [String] = []
        for fee in [Int64(30), 10, 20] {
            let tx = try SimTransactions.signed(keys: [CryptoUtils.generateKeyPair(), sponsor], accountActions: [
                AccountAction(owner: address(sponsor), delta: -fee),
            ], nonce: 0, chainPath: ["Nexus"])
            try pool.submit(tx, spec: testSpec(), addedAt: 0, balances: [address(sponsor): 60])
            cids.append(try Mempool.cid(of: tx))
        }
        XCTAssertTrue(pool.rebalance([address(sponsor): 60]).departed.isEmpty)
        XCTAssertTrue(pool.rebalance(["someone else": 0]).departed.isEmpty, "an account the pool does not debit")
        let shed = pool.rebalance([address(sponsor): 50])
        XCTAssertEqual(shed.evicted.map(\.cid), [cids[1]])
        XCTAssertEqual(Set(pool.items.map(\.cid)), [cids[0], cids[2]])
        XCTAssertEqual(pool.rebalance([address(sponsor): 0]).evicted.count, 2)
        // Nothing debits it now: the budget starts over.
        let again = try SimTransactions.signed(keys: [CryptoUtils.generateKeyPair(), sponsor], accountActions: [
            AccountAction(owner: address(sponsor), delta: -5),
        ], nonce: 0, chainPath: ["Nexus"])
        try pool.submit(again, spec: testSpec(), addedAt: 0, balances: [address(sponsor): 5])
    }

    /// A transaction's debit is its net take from each account, as
    /// consensus nets it: account actions and the receipts it pays (the
    /// withdrawer pays the demander). A credit is no debit.
    func testADebitIsTheNetTakeFromEachAccount() throws {
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: "a", delta: -10), AccountAction(owner: "a", delta: 4),
                AccountAction(owner: "b", delta: -3), AccountAction(owner: "b", delta: 3),
                AccountAction(owner: "c", delta: 6),
            ],
            actions: [], depositActions: [],
            receiptActions: [ReceiptAction(withdrawer: "b", nonce: 1, demander: "c", amountDemanded: 7, directory: "Child")],
            withdrawalActions: [],
            signers: ["a"], nonce: 0, chainPath: ["Nexus"]
        )
        XCTAssertEqual(Mempool.debits(of: body), ["a": 6, "b": 7])
    }

    /// A receipt's payment draws on the withdrawer's budget like any debit:
    /// one balance cannot back many receipts that each spend all of it.
    func testAReceiptDrawsOnTheWithdrawersBudget() throws {
        var pool = Mempool()
        let withdrawer = CryptoUtils.generateKeyPair()
        func receipt(nonce: UInt128) throws -> Transaction {
            try SimTransactions.signed(keys: [CryptoUtils.generateKeyPair(), withdrawer], accountActions: [
                AccountAction(owner: address(withdrawer), delta: -5),
            ], receiptActions: [ReceiptAction(
                withdrawer: address(withdrawer), nonce: nonce, demander: "seller", amountDemanded: 15, directory: "Child"
            )], nonce: 0, chainPath: ["Nexus"])
        }
        let balance = [address(withdrawer): UInt64(30)]
        try pool.submit(try receipt(nonce: 1), spec: testSpec(), addedAt: 0, balances: balance)
        XCTAssertThrowsError(try pool.submit(try receipt(nonce: 2), spec: testSpec(), addedAt: 0, balances: balance)) {
            XCTAssertEqual($0 as? MempoolError, .insufficientFunds, "20 and 20 more is over 30")
        }
    }

    /// Two senders writing one state key never share the pool: one of them
    /// could not be mined. Uncongested, the key goes to the higher fee, so a
    /// cheap write cannot hold it against a better offer.
    func testAStateKeyGoesToTheHigherFee() throws {
        func write(_ key: (privateKey: String, publicKey: String), _ stateKey: String, fee: Int64) throws -> Transaction {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: address(key), delta: -fee)],
                actions: [Action(key: stateKey, oldValue: nil, newValue: address(key))],
                depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
            )
            return Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
        }
        var pool = Mempool()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let alices = try write(alice, "name/ada", fee: 1)
        try pool.submit(alices, spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try pool.submit(try write(bob, "name/ada", fee: 1), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }
        let bobs = try write(bob, "name/ada", fee: 2)
        XCTAssertEqual(try pool.submit(bobs, spec: testSpec(), addedAt: 0).replaced.map(\.cid), [try Mempool.cid(of: alices)])
        try pool.submit(try write(alice, "name/lin", fee: 1), spec: testSpec(), addedAt: 0)
        XCTAssertEqual(pool.count, 2, "the nonce it lost is free")
    }

    /// A conflict goes to what makes the next block pay more. A large write
    /// paying a high fee at a low rate never reaches the next block, so it
    /// holds its key against nothing that would: a small bid paying less in
    /// all takes it, by raising what the next block pays.
    func testABidThatWouldNotReachTheNextBlockHoldsNothing() throws {
        func write(_ key: (privateKey: String, publicKey: String), fee: Int64, padding: Int = 0) throws -> Transaction {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: address(key), delta: -fee)],
                actions: [Action(key: "name/ada", oldValue: nil, newValue: String(repeating: "x", count: padding + 1))],
                depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
            )
            return Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
        }
        let spec = testSpec(maxTransactions: 1)
        var pool = Mempool()
        let pin = try write(CryptoUtils.generateKeyPair(), fee: 500, padding: 20_000)
        try pool.submit(pin, spec: spec, addedAt: 0)
        try pool.submit(try paying(CryptoUtils.generateKeyPair(), fee: 100, nonce: 0), spec: spec, addedAt: 0)
        XCTAssertThrowsError(try pool.submit(try write(CryptoUtils.generateKeyPair(), fee: 100), spec: spec, addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "the next block would pay no more")
        }
        let bid = try write(CryptoUtils.generateKeyPair(), fee: 150)
        XCTAssertEqual(try pool.submit(bid, spec: spec, addedAt: 0).replaced.map(\.cid), [try Mempool.cid(of: pin)])
        XCTAssertEqual(try pool.nextBlock(spec).map(Mempool.cid(of:)), [try Mempool.cid(of: bid)])
    }

    /// A bid that would not reach the next block displaces nothing, even when
    /// taking its conflict out lets a larger, richer transaction in.
    func testABidOutsideTheNextBlockDisplacesNothing() throws {
        func write(_ name: String, fee: Int64, padding: Int = 0) throws -> Transaction {
            let key = CryptoUtils.generateKeyPair()
            let body = TransactionBody(
                accountActions: [AccountAction(owner: address(key), delta: -fee)],
                actions: [Action(key: name, oldValue: nil, newValue: String(repeating: "x", count: padding + 1))],
                depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
            )
            return Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
        }
        let rich = try write("name/x", fee: 100_000, padding: 2_000)
        let honest = try write("name/ada", fee: 50)
        let behind = try write("name/d", fee: 200, padding: 2_000)
        let spec = try blocks(holding: size(rich) + size(behind) + 2 * Self.place)
        var pool = Mempool()
        for tx in [rich, honest, behind] { try pool.submit(tx, spec: spec, addedAt: 0) }
        XCTAssertEqual(try pool.nextBlock(spec).map(Mempool.cid(of:)), [try Mempool.cid(of: rich), try Mempool.cid(of: honest)])
        XCTAssertThrowsError(try pool.submit(try write("name/ada", fee: 1), spec: spec, addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "out of the next block, though removing the honest write lets a richer one in")
        }
    }

    /// One transaction sharing claims with two pooled ones displaces both
    /// only by paying for both.
    func testATransactionOverlappingTwoPaysForBoth() throws {
        var pool = Mempool()
        let first = CryptoUtils.generateKeyPair()
        let second = CryptoUtils.generateKeyPair()
        func body(_ key: (privateKey: String, publicKey: String), fee: Int64, writing: [Action]) throws -> Transaction {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: address(key), delta: -fee)],
                actions: writing, depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
            )
            return Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
        }
        let write = Action(key: "name/ada", oldValue: nil, newValue: "x")
        try pool.submit(try paying(first, fee: 1, nonce: 0), spec: testSpec(), addedAt: 0)
        try pool.submit(try body(second, fee: 1, writing: [write]), spec: testSpec(), addedAt: 0)
        // The first's nonce and the second's key.
        XCTAssertThrowsError(try pool.submit(try body(first, fee: 2, writing: [write]), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "2 does not pay 1 + 1 and the increment")
        }
        XCTAssertEqual(pool.count, 2)
        XCTAssertEqual(try pool.submit(try body(first, fee: 3, writing: [write]), spec: testSpec(), addedAt: 0).replaced.count, 2)
        XCTAssertEqual(pool.count, 1)
    }

    /// A deposit and a receipt are claimed like a nonce: two transactions
    /// that create, spend or pay for the same one never share the pool, and
    /// one paying no more than the other is refused.
    func testDepositsAndReceiptsAreClaimed() throws {
        let demander = address(CryptoUtils.generateKeyPair())
        func body(signer: String, deposits: [DepositAction] = [], receipts: [ReceiptAction] = [],
                  withdrawals: [WithdrawalAction] = []) -> Transaction {
            let body = TransactionBody(
                accountActions: [AccountAction(owner: signer, delta: -5)], actions: [], depositActions: deposits,
                receiptActions: receipts, withdrawalActions: withdrawals, signers: [signer], nonce: 0,
                chainPath: ["Nexus", "Child"]
            )
            return Transaction(signatures: [signer: "x"], body: try! HeaderImpl(node: body))
        }
        let deposit = DepositAction(nonce: 7, demander: demander, amountDemanded: 3, amountDeposited: 3)
        let withdrawal = WithdrawalAction(withdrawer: "w", nonce: 7, demander: demander, amountDemanded: 3, amountWithdrawn: 3)
        var pool = Mempool()
        try pool.submit(body(signer: "a", withdrawals: [withdrawal]), spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try pool.submit(body(signer: "b", withdrawals: [withdrawal]), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "one deposit, spent once")
        }
        XCTAssertThrowsError(try pool.submit(body(signer: "c", deposits: [deposit]), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }

        let receipt = ReceiptAction(withdrawer: "w", nonce: 7, demander: demander, amountDemanded: 3, directory: "Child")
        var parent = Mempool()
        try parent.submit(body(signer: "a", receipts: [receipt]), spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try parent.submit(body(signer: "b", receipts: [receipt]), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow, "one receipt, paid once")
        }
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
        XCTAssertEqual(pool.nextBlock(testSpec()).first?.body.rawCID, incumbent.body.rawCID)
    }

    /// `minRelayFee` is node admission policy on the real fee (the balance
    /// excess): below it is refused by name, at it is admitted, and the
    /// default 0 admits a zero-fee transaction. The daemon's default is 1.
    func testMinRelayFeeRefusesCheaperTransactions() throws {
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        func tx(fee: Int64, nonce: UInt64) throws -> Transaction {
            try signed(key, [
                AccountAction(owner: address(key), delta: -(fee + 1)), AccountAction(owner: recipient, delta: 1),
            ], nonce: nonce)
        }
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 5))
        XCTAssertThrowsError(try pool.submit(tx(fee: 4, nonce: 0), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .belowMinRelayFee)
        }
        XCTAssertThrowsError(try pool.check(tx(fee: 4, nonce: 0), spec: testSpec())) {
            XCTAssertEqual($0 as? MempoolError, .belowMinRelayFee)
        }
        try pool.submit(tx(fee: 5, nonce: 0), spec: testSpec(), addedAt: 0)
        XCTAssertEqual(pool.count, 1)

        var open = Mempool()
        try open.submit(tx(fee: 0, nonce: 0), spec: testSpec(), addedAt: 0)
        XCTAssertEqual(open.count, 1)
    }

    /// A replacement pays `replacementIncrement` more: at least 1, and the
    /// relay floor when that is higher.
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
        XCTAssertEqual(try pool.nextBlock(testSpec()).map(Mempool.cid(of:)), [rich, mid, cheap])
    }

    func testAReplacementPaysTheRelayFloorMore() throws {
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 5))
        let key = CryptoUtils.generateKeyPair()
        let recipient = address(CryptoUtils.generateKeyPair())
        func tx(fee: Int64) throws -> Transaction {
            try signed(key, [
                AccountAction(owner: address(key), delta: -(fee + 1)), AccountAction(owner: recipient, delta: 1),
            ], nonce: 0)
        }
        try pool.submit(tx(fee: 10), spec: testSpec(), addedAt: 0)
        XCTAssertThrowsError(try pool.submit(tx(fee: 14), spec: testSpec(), addedAt: 0)) {
            XCTAssertEqual($0 as? MempoolError, .feeTooLow)
        }
        XCTAssertEqual(try pool.submit(tx(fee: 15), spec: testSpec(), addedAt: 0).replaced.count, 1)
    }

    func testVersionMovesOnEveryChangeAndOnlyThen() throws {
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 0))
        let key = CryptoUtils.generateKeyPair()
        let tx = try signed(key, [], nonce: 0)
        let start = pool.version
        try pool.submit(tx, spec: testSpec(), addedAt: 0)
        let inserted = pool.version
        XCTAssertGreaterThan(inserted, start)
        try pool.submit(tx, spec: testSpec(), addedAt: 0)
        pool.remove(["absent"])
        XCTAssertEqual(pool.version, inserted, "a duplicate and a removal of nothing change nothing")
        pool.remove([try Mempool.cid(of: tx)])
        XCTAssertGreaterThan(pool.version, inserted)
    }

    /// The real fee is the debit excess: a self-debit of `fee` pays it all.
    private func paying(
        _ key: (privateKey: String, publicKey: String), fee: Int64, nonce: UInt64
    ) throws -> Transaction {
        try signed(key, [AccountAction(owner: address(key), delta: -fee)], nonce: nonce)
    }

    private func size(_ transaction: Transaction) throws -> Int {
        try XCTUnwrap(transaction.toData()).count + XCTUnwrap(transaction.body.node?.toData()).count
    }

    /// What a block charges each transaction beyond its own bytes.
    private static let place = 256

    /// A chain whose blocks hold `count` transactions charging `bytes` in
    /// all: their own bytes and `place` each.
    private func blocks(holding bytes: Int, count: UInt64 = 100) -> ChainSpec {
        let allowance = testSpec().maxBlockSize - Mempool.transactionRoom(testSpec())
        return testSpec(maxBlockSize: bytes + allowance - Self.place, maxTransactions: count)
    }

    /// The next block takes the higher fee rate first; one that does not
    /// fit is skipped for a smaller one behind it.
    func testATransactionThatDoesNotFitIsSkippedForOneThatDoes() throws {
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 0))
        let big = try storing(size: 2_000)
        let small = try paying(CryptoUtils.generateKeyPair(), fee: 1, nonce: 0)
        let rich = try paying(CryptoUtils.generateKeyPair(), fee: 1_000, nonce: 0)
        for tx in [big, small, rich] { try pool.submit(tx, spec: testSpec(), addedAt: 0) }
        XCTAssertEqual(try pool.nextBlock(testSpec(maxTransactions: 1)).map(Mempool.cid(of:)), [try Mempool.cid(of: rich)])
        let spec = try blocks(holding: size(rich) + size(small) + 2 * Self.place)
        XCTAssertEqual(try pool.nextBlock(spec).map(Mempool.cid(of:)), try [rich, small].map(Mempool.cid(of:)))
    }

    /// What a template is handed fits the block it builds: each transaction
    /// is charged its share of the block around it, so one that fits by its
    /// own bytes alone but not with the trie it adds is skipped, and the
    /// builder never has to cut the list short.
    func testTheNextBlockChargesEachTransactionItsPlaceInTheBlock() throws {
        let spec = testSpec(maxBlockSize: 20_000)
        var pool = Mempool(limits: MempoolLimits(minRelayFee: 0))
        let small = try (0..<8).map { _ in try paying(CryptoUtils.generateKeyPair(), fee: 1_000, nonce: 0) }
        for tx in small { try pool.submit(tx, spec: spec, addedAt: 0) }
        let used = try small.reduce(0) { $0 + (try size($1)) }
        let big = try storing(size: Mempool.transactionRoom(spec) - used - 100)
        try pool.submit(big, spec: spec, addedAt: 0)
        XCTAssertEqual(Set(try pool.nextBlock(spec).map(Mempool.cid(of:))), Set(try small.map(Mempool.cid(of:))),
                       "by their own bytes alone, all nine fit")

        // The largest transaction admitted fits a block carrying only it.
        var alone = Mempool(limits: MempoolLimits(minRelayFee: 0))
        let largest = try storing(size: Mempool.transactionRoom(spec))
        try alone.submit(largest, spec: spec, addedAt: 0)
        XCTAssertEqual(alone.nextBlock(spec).count, 1)
    }

    /// A fill gives up after 1,000 transactions in a row fail to fit, as
    /// Bitcoin Core does: a small one behind 1,000 large, better-paying ones
    /// is left out, and behind 999 it is taken.
    func testSelectionStopsAfterAThousandMissesInARow() throws {
        for large in [999, 1_000] {
            var pool = Mempool()
            let credited = (0..<3).map { address(Self.fixedKey("credited", $0)) }
            var small: (cid: String, size: Int)?
            for index in 0...large {
                let key = Self.fixedKey("miss", index)
                let isSmall = index == large
                let fee: Int64 = isSmall ? 1 : 1_000_000
                var actions = [AccountAction(owner: address(key), delta: -(fee + (isSmall ? 0 : 3)))]
                if !isSmall { actions += credited.map { AccountAction(owner: $0, delta: 1) } }
                let body = TransactionBody(
                    accountActions: actions, actions: [], depositActions: [], receiptActions: [],
                    withdrawalActions: [], signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
                )
                let transaction = Transaction(signatures: [key.publicKey: "x"], body: try HeaderImpl(node: body))
                let cid = try XCTUnwrap(pool.submit(transaction, spec: testSpec(), addedAt: 0).transactionCID)
                if isSmall { small = (cid, try size(transaction)) }
            }
            let (cid, smallSize) = try XCTUnwrap(small)
            let chosen = try pool.nextBlock(blocks(holding: smallSize + Self.place)).map(Mempool.cid(of:))
            XCTAssertEqual(chosen, large < 1_000 ? [cid] : [], "\(large) large")
        }
    }

    /// A fixed stand-in key: the pool never checks signatures.
    private static func fixedKey(_ role: String, _ index: Int) -> (privateKey: String, publicKey: String) {
        ("\(role)-private-\(index)", "\(role)-public-\(index)")
    }

    func testProjectionOfARoomyPoolIsOneOpenBlock() throws {
        var pool = Mempool()
        XCTAssertEqual(pool.projectedBlocks(count: 12, spec: testSpec(maxTransactions: 10)), [])

        let cheap = try paying(CryptoUtils.generateKeyPair(), fee: 1, nonce: 0)
        let rich = try paying(CryptoUtils.generateKeyPair(), fee: 50, nonce: 0)
        for tx in [cheap, rich] { try pool.submit(tx, spec: testSpec(), addedAt: 0) }

        let blocks = pool.projectedBlocks(count: 12, spec: testSpec(maxTransactions: 10))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].transactionCount, 2)
        XCTAssertEqual(blocks[0].bytes, try size(cheap) + size(rich))
        XCTAssertEqual(blocks[0].lowestFee.uint64Value, 1, "the cheapest taken sets the block's rate")
        XCTAssertEqual(blocks[0].lowestFeeBytes, try size(cheap))
        XCTAssertFalse(blocks[0].full, "nothing waits: the floor makes the next block")
    }

    func testProjectionFillsBlocksInFeeOrderAndMarksTheFullOnes() throws {
        var pool = Mempool()
        let fees: [Int64] = [1, 100, 10]
        for fee in fees {
            try pool.submit(try paying(CryptoUtils.generateKeyPair(), fee: fee, nonce: 0), spec: testSpec(), addedAt: 0)
        }

        let two = pool.projectedBlocks(count: 2, spec: testSpec(maxTransactions: 1))
        XCTAssertEqual(two.map(\.lowestFee.uint64Value), [100, 10])
        XCTAssertEqual(two.map(\.full), [true, true], "the fee-1 transaction waits behind both")

        let all = pool.projectedBlocks(count: 12, spec: testSpec(maxTransactions: 1))
        XCTAssertEqual(all.map(\.lowestFee.uint64Value), [100, 10, 1])
        XCTAssertEqual(all.map(\.full), [true, true, false])

        // Bytes bound a block as the count does, each charged its place in it.
        let oneEach = try size(paying(CryptoUtils.generateKeyPair(), fee: 1, nonce: 0)) + Self.place
        XCTAssertEqual(pool.projectedBlocks(count: 12, spec: blocks(holding: oneEach + oneEach / 2, count: 10)).count, 3)
    }

}

func address(_ key: (privateKey: String, publicKey: String)) -> String {
    CryptoUtils.createAddress(from: key.publicKey)
}

/// A fee-0 transaction of exactly `size` bytes (envelope plus body), its
/// bulk one stored value.
func storing(size target: Int) throws -> Transaction {
    let key = CryptoUtils.generateKeyPair()
    func make(_ length: Int) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [], actions: [Action(key: "k", oldValue: nil, newValue: String(repeating: "a", count: length))],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(key)], nonce: 0, chainPath: ["Nexus"]
        )
        let header = try HeaderImpl(node: body)
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey))],
            body: header
        )
    }
    func size(_ transaction: Transaction) throws -> Int {
        let envelope = try XCTUnwrap(transaction.toData())
        let body = try XCTUnwrap(transaction.body.node?.toData())
        return envelope.count + body.count
    }
    var length = 0
    for _ in 0..<8 {
        let transaction = try make(length)
        let measured = try size(transaction)
        if measured == target { return transaction }
        length += target - measured
        guard length >= 0 else { break }
    }
    struct NoSuchSize: Error {}
    XCTFail("no transaction of exactly \(target) bytes")
    throw NoSuchSize()
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
        receiptActions: [],
        withdrawalActions: [],
        signers: [address(key)],
        nonce: nonce,
        chainPath: chainPath
    )
}

func testSpec(maxBlockSize: Int = 1_000_000, maxTransactions: UInt64 = 100) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: maxTransactions,
        maxStateGrowth: 100_000,
        maxBlockSize: maxBlockSize,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 100,
        halvingInterval: 10_000,
        halfLife: 10
    )
}
