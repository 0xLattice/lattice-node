import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// Mempool admission's classification of one transaction against a chain's
/// executed tip: ready, future, invalid, or unavailable.
@MainActor
final class TransactionPreflightTests: XCTestCase {
    private typealias Key = (privateKey: String, publicKey: String)

    private func transaction(
        signers: [Key],
        nonce: UInt64,
        chainPath: [String] = [DEFAULT_ROOT_DIRECTORY],
        accountActions: [AccountAction] = [],
        actions: [Action] = [],
        withdrawalActions: [WithdrawalAction] = []
    ) -> Transaction {
        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: [],
            receiptActions: [],
            withdrawalActions: withdrawalActions,
            signers: signers.map(address),
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signatures = Dictionary(uniqueKeysWithValues: signers.map {
            ($0.publicKey, TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: $0.privateKey
            )!)
        })
        return Transaction(signatures: signatures, body: header)
    }

    private func fundedChain(
        cas: SimCAS,
        alice: Key,
        bob: Key
    ) async throws -> (chain: ChainTree, genesis: Block) {
        let premine = transaction(
            signers: [alice, bob],
            nonce: 0,
            accountActions: [
                AccountAction(owner: address(alice), delta: 500),
                AccountAction(owner: address(bob), delta: 500),
            ]
        )
        let genesis = try await storedGenesis(
            spec: preflightSpec(premine: 1),
            transactions: [premine],
            timestamp: 1_000,
            cas: cas
        )
        return (try await preflightChain(genesis: genesis, fetcher: cas), genesis)
    }

    /// A chain on a genesis carrying nothing, under `policies`.
    private func emptyChain(
        policies: [WasmPolicyRef] = [],
        timestamp: Int64 = 1_000,
        path: [String] = [DEFAULT_ROOT_DIRECTORY],
        cas: SimCAS
    ) async throws -> ChainTree {
        let genesis = try await storedGenesis(
            spec: preflightSpec(policies: policies), timestamp: timestamp, cas: cas
        )
        return try await preflightChain(genesis: genesis, path: path, fetcher: cas)
    }

    /// A recheck that leaves the signatures out still runs every rule that
    /// reads the tip's state.
    func testClassifyWithoutSignaturesSkipsOnlyTheSignatureRules() async throws {
        let cas = SimCAS()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let chain = try await fundedChain(cas: cas, alice: alice, bob: bob).chain
        let tip = chain.transactionPreflightTip(at: nil)
        func classify(_ transaction: Transaction, checksSignatures: Bool) async -> TransactionPreflightDisposition {
            await TransactionPreflight.classify(
                transaction, tipCID: tip.cid, snapshot: tip.snapshot,
                chainPath: [DEFAULT_ROOT_DIRECTORY], fetcher: cas,
                checksPolicies: false, checksSignatures: checksSignatures
            ).disposition
        }

        let valid = transaction(signers: [alice], nonce: 1)
        let forged = Transaction(
            signatures: [alice.publicKey: String(repeating: "00", count: 64)],
            body: valid.body
        )
        let wrongSigner = Transaction(
            signatures: transaction(signers: [bob], nonce: 1).signatures,
            body: valid.body
        )
        for (candidate, checked) in [(valid, TransactionPreflightDisposition.ready), (forged, .invalid), (wrongSigner, .invalid)] {
            let withSignatures = await classify(candidate, checksSignatures: true)
            XCTAssertEqual(withSignatures, checked)
            let withoutSignatures = await classify(candidate, checksSignatures: false)
            XCTAssertEqual(withoutSignatures, .ready)
        }
        // State still decides: a spent nonce, a nonce ahead, and the wrong chain.
        let spent = await classify(transaction(signers: [alice], nonce: 0), checksSignatures: false)
        XCTAssertEqual(spent, .invalid)
        let ahead = await classify(transaction(signers: [alice], nonce: 2), checksSignatures: false)
        XCTAssertEqual(ahead, .future)
        let elsewhere = await classify(
            transaction(signers: [alice], nonce: 1, chainPath: [DEFAULT_ROOT_DIRECTORY, "child"]),
            checksSignatures: false
        )
        XCTAssertEqual(elsewhere, .invalid)
        // The body's own rules still run: a debit of bob, who has not signed.
        let debitsANonSigner = await classify(
            transaction(signers: [alice], nonce: 1, accountActions: [
                AccountAction(owner: address(bob), delta: -1),
                AccountAction(owner: address(alice), delta: 1),
            ]),
            checksSignatures: false
        )
        XCTAssertEqual(debitsANonSigner, .invalid)
    }

    func testMultiSignerNonceClassificationUsesTheFirstSignerOnly() async throws {
        let cas = SimCAS()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        // Genesis is signed by [alice, bob] at nonce 0: alice's next nonce is
        // 1, and bob, a co-signer only, has never used a nonce.
        var chain: ChainTree
        let genesis: Block
        (chain, genesis) = try await fundedChain(cas: cas, alice: alice, bob: bob)

        let ready = await chain.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: cas
        )
        XCTAssertEqual(ready.disposition, .ready)
        XCTAssertEqual(ready.tipCID, try BlockHeader(node: genesis).rawCID)

        let future = await chain.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: cas
        )
        XCTAssertEqual(future.disposition, .future)

        // Bob first: his own floor (0) decides, whatever alice's is.
        let bobFirst = await chain.preflightTransaction(
            transaction(signers: [bob, alice], nonce: 0),
            fetcher: cas
        )
        XCTAssertEqual(bobFirst.disposition, .ready)

        let aliceAdvance = transaction(signers: [alice], nonce: 1)
        let block = try await storedBlock(
            on: genesis,
            transactions: [aliceAdvance],
            timestamp: 2_000,
            cas: cas
        )
        let blockHash = try BlockHeader(node: block).rawCID
        let admitted = try await chain.admitRoot(block, fetcher: cas)
        XCTAssertEqual(admitted.update?.excluded, false)
        XCTAssertTrue(chain.isExecuted(blockHash: blockHash))

        let stale = await chain.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: cas
        )
        XCTAssertEqual(stale.disposition, .invalid)
        XCTAssertEqual(stale.tipCID, blockHash)

        let next = await chain.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: cas
        )
        XCTAssertEqual(next.disposition, .ready)

        let bobStillFirst = await chain.preflightTransaction(
            transaction(signers: [bob, alice], nonce: 0),
            fetcher: cas
        )
        XCTAssertEqual(bobStillFirst.disposition, .ready)
    }

    func testPreflightClassifiesAgainstTheExecutedTipNotTheWeighedOne() async throws {
        // lattice-node #228: genesis -> block 1 (executed) -> block 2 (weighed
        // only, the canonical tip). Block 2 declares Alice's nonce 1 spent, so
        // her nonce-1 transaction is valid only on block 1's executed state.
        let cas = SimCAS()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        var chain: ChainTree
        let genesis: Block
        (chain, genesis) = try await fundedChain(cas: cas, alice: alice, bob: bob)
        let executed = try await storedBlock(on: genesis, timestamp: 2_000, cas: cas)
        let executedHash = try BlockHeader(node: executed).rawCID
        _ = try await chain.admitRoot(executed, fetcher: cas)
        let weighed = try await storedBlock(
            on: executed,
            transactions: [transaction(signers: [alice], nonce: 1)],
            timestamp: 3_000,
            cas: cas
        )
        let weighedHash = try BlockHeader(node: weighed).rawCID
        _ = try await chain.admitRoot(weighed, executing: false, fetcher: cas)
        let canonicalTip = chain.canonicalTip
        XCTAssertEqual(canonicalTip, weighedHash)
        let executedTipIsExecuted = chain.hasExecutedAncestry(blockHash: executedHash)
        let weighedTipIsExecuted = chain.hasExecutedAncestry(blockHash: weighedHash)
        XCTAssertTrue(executedTipIsExecuted)
        XCTAssertFalse(weighedTipIsExecuted)

        let aliceNext = transaction(signers: [alice], nonce: 1)
        let atExecuted = await chain.preflightTransaction(
            aliceNext,
            at: executedHash,
            fetcher: cas
        )
        XCTAssertEqual(atExecuted.disposition, .ready)
        XCTAssertEqual(atExecuted.tipCID, executedHash)
        let futureAtExecuted = await chain.preflightTransaction(
            transaction(signers: [alice], nonce: 2),
            at: executedHash,
            fetcher: cas
        )
        XCTAssertEqual(futureAtExecuted.disposition, .future)

        // Neither naming the weighed block nor defaulting to the canonical tip
        // classifies against its declared state.
        for (tip, label) in [(Optional(weighedHash), "named"), (nil, "default")] {
            let result = await chain.preflightTransaction(
                aliceNext,
                at: tip,
                fetcher: cas
            )
            XCTAssertEqual(result.disposition, .unavailable, label)
            XCTAssertEqual(result.tipCID, weighedHash, label)
        }

        // Once the weighed block is executed it is a valid tip, and its state
        // has spent Alice's nonce 1.
        let execution = await chain.execute(weighedHash, fetcher: cas)
        XCTAssertEqual(execution?.update?.excluded, false)
        let afterExecution = await chain.preflightTransaction(
            aliceNext,
            fetcher: cas
        )
        XCTAssertEqual(afterExecution.disposition, .invalid)
        XCTAssertEqual(afterExecution.tipCID, weighedHash)
    }

    func testStateTransitionAndSignatureFailuresAreInvalid() async throws {
        let cas = SimCAS()
        let signer = CryptoUtils.generateKeyPair()
        let chain = try await emptyChain(cas: cas)

        let overspend = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address(signer), delta: -1)]
        )
        let overspendResult = await chain.preflightTransaction(
            overspend,
            fetcher: cas
        )
        XCTAssertEqual(overspendResult.disposition, .invalid)

        let valid = transaction(signers: [signer], nonce: 0)
        let badSignature = Transaction(
            signatures: [signer.publicKey: "00"],
            body: valid.body
        )
        let badSignatureResult = await chain.preflightTransaction(
            badSignature,
            fetcher: cas
        )
        XCTAssertEqual(badSignatureResult.disposition, .invalid)
    }

    func testClassifyFromTheTreesBasis() async throws {
        let cas = SimCAS()
        let signer = CryptoUtils.generateKeyPair()
        let tree = try await emptyChain(cas: cas)

        let ready = transaction(signers: [signer], nonce: 0)
        let overspend = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address(signer), delta: -1)]
        )
        let missingBody = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(rawCID: absentCID("missing-body"))
        )
        let cases: [(Transaction, String?, TransactionPreflightDisposition)] = [
            (ready, nil, .ready),
            (overspend, nil, .invalid),
            (missingBody, nil, .unavailable),
            // A block this chain never executed has no snapshot.
            (ready, absentCID("not-executed"), .unavailable),
        ]
        for (tx, tipCID, expected) in cases {
            let basis = tree.transactionPreflightTip(at: tipCID)
            let classified = await TransactionPreflight.classify(
                tx,
                tipCID: basis.cid,
                snapshot: basis.snapshot,
                chainPath: tree.context!.path,
                fetcher: cas
            )
            XCTAssertEqual(classified.disposition, expected)
        }
    }

    func testValueCreatingTransactionIsInvalid() async throws {
        let cas = SimCAS()
        let signer = CryptoUtils.generateKeyPair()
        let chain = try await emptyChain(cas: cas)

        // Credits with nothing debited: negative miner surplus. The block
        // reward no longer funds transactions, so no block may carry it.
        let minting = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address(signer), delta: 5)]
        )
        let mintingResult = await chain.preflightTransaction(minting, fetcher: cas)
        XCTAssertEqual(mintingResult.disposition, .invalid)

        let neutral = transaction(signers: [signer], nonce: 0)
        let neutralResult = await chain.preflightTransaction(neutral, fetcher: cas)
        XCTAssertEqual(neutralResult.disposition, .ready)
    }

    func testMissingBodyAndPolicyContentAreUnavailable() async throws {
        let cas = SimCAS()
        let signer = CryptoUtils.generateKeyPair()
        let missingModule = WasmPolicyRef(
            moduleCID: absentCID("missing-policy"),
            scope: .transaction
        )
        let chain = try await emptyChain(policies: [missingModule], cas: cas)

        let missingPolicyResult = await chain.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: cas
        )
        XCTAssertEqual(missingPolicyResult.disposition, .unavailable)

        let missingBody = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(rawCID: absentCID("missing-body"))
        )
        let missingBodyResult = await chain.preflightTransaction(
            missingBody,
            fetcher: cas
        )
        XCTAssertEqual(missingBodyResult.disposition, .unavailable)
    }

    func testTheCheapChecksDecideBeforeAnyPolicyRuns() async throws {
        // The policy's module is missing, so a transaction that reaches the
        // policy is `.unavailable`. Every other verdict below was reached
        // without running it.
        let cas = SimCAS()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let missingModule = WasmPolicyRef(
            moduleCID: absentCID("missing-policy"),
            scope: .transaction
        )
        let genesis = try await storedGenesis(
            spec: preflightSpec(premine: 1, policies: [missingModule]),
            transactions: [transaction(
                signers: [alice],
                nonce: 0,
                accountActions: [AccountAction(owner: address(alice), delta: 500)]
            )],
            timestamp: 1_000,
            cas: cas
        )
        let chain = try await preflightChain(genesis: genesis, fetcher: cas)

        let cases: [(String, Transaction, TransactionPreflightDisposition)] = [
            ("stale nonce", transaction(signers: [alice], nonce: 0), .invalid),
            ("future nonce: the policy judges what is kept", transaction(signers: [alice], nonce: 2), .unavailable),
            ("overspend", transaction(
                signers: [bob],
                nonce: 0,
                accountActions: [AccountAction(owner: address(bob), delta: -1)]
            ), .invalid),
            ("a wrong old value", transaction(
                signers: [alice],
                nonce: 1,
                actions: [Action(key: "k", oldValue: "not-there", newValue: "v")]
            ), .invalid),
            ("ready: the policy runs", transaction(signers: [alice], nonce: 1), .unavailable),
        ]
        for (label, tx, expected) in cases {
            let result = await chain.preflightTransaction(tx, fetcher: cas)
            XCTAssertEqual(result.disposition, expected, label)
        }

        // Without the policies, the same ready transaction is ready, and the
        // state checks still refuse what they refused.
        let basis = chain.transactionPreflightTip(at: nil)
        let unjudged: [(String, Transaction, TransactionPreflightDisposition)] = [
            ("ready", transaction(signers: [alice], nonce: 1), .ready),
            ("stale nonce", transaction(signers: [alice], nonce: 0), .invalid),
            ("future nonce", transaction(signers: [alice], nonce: 2), .future),
        ]
        for (label, tx, expected) in unjudged {
            let result = await TransactionPreflight.classify(
                tx,
                tipCID: basis.cid,
                snapshot: basis.snapshot,
                chainPath: chain.context!.path,
                fetcher: cas,
                checksPolicies: false
            )
            XCTAssertEqual(result.disposition, expected, "unjudged: \(label)")
        }
    }

    func testNothingAPolicyRefusesIsKeptWhateverItsNonce() async throws {
        let cas = SimCAS()
        let alice = CryptoUtils.generateKeyPair()
        let refusing = try await PolicyWasm.store(PolicyWasm.module(body: { _ in PolicyWasm.i32(0) }), in: cas)
        let genesis = try await storedGenesis(
            spec: preflightSpec(premine: 1, policies: [refusing]),
            transactions: [transaction(
                signers: [alice],
                nonce: 0,
                accountActions: [AccountAction(owner: address(alice), delta: 500)]
            )],
            timestamp: 1_000,
            cas: cas
        )
        let chain = try await preflightChain(genesis: genesis, fetcher: cas)

        for (label, nonce) in [("ready", UInt64(1)), ("future", 2), ("far future", 40)] {
            let result = await chain.preflightTransaction(
                transaction(signers: [alice], nonce: nonce),
                fetcher: cas
            )
            XCTAssertEqual(result.disposition, .invalid, label)
        }
    }

    func testRejectingPolicyIsInvalid() async throws {
        let cas = SimCAS()
        let policy = try await PolicyWasm.store(PolicyWasm.module(body: { _ in PolicyWasm.i32(0) }), in: cas)
        let chain = try await emptyChain(policies: [policy], cas: cas)
        let signer = CryptoUtils.generateKeyPair()

        let rejected = await chain.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: cas
        )
        XCTAssertEqual(rejected.disposition, .invalid)
    }

    func testPolicySeesNextBlockHeight() async throws {
        // The tip is genesis (height 0), so the carrying block is height 1.
        for (minimum, expected) in [(Int64(1), TransactionPreflightDisposition.ready), (2, .invalid)] {
            let cas = SimCAS()
            let policy = try await PolicyWasm.store(
                PolicyWasm.contextField(at: wasmPolicyContextHeightOffset, atLeast: minimum), in: cas
            )
            let chain = try await emptyChain(policies: [policy], cas: cas)
            let result = await chain.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: cas
            )
            XCTAssertEqual(result.disposition, expected, "minimum height \(minimum)")
        }
    }

    func testPolicySeesInjectedValidationTime() async throws {
        // The carrying block is stamped max(tip + 1, now), and the policy
        // requires at least 3_000. Every clock sits far below wall time, which
        // would accept each case, so only the injected clock decides.
        let cases: [(tip: Int64, now: Int64, expected: TransactionPreflightDisposition)] = [
            (1_000, 3_000, .ready),    // now wins and meets the bound
            (1_000, 2_999, .invalid),  // now wins, one below the bound
            (5_000, 0, .ready),        // tip + 1 wins over a stale clock
        ]
        for (tip, now, expected) in cases {
            let cas = SimCAS()
            let policy = try await PolicyWasm.store(
                PolicyWasm.contextField(at: wasmPolicyContextTimestampOffset, atLeast: 3_000), in: cas
            )
            let chain = try await emptyChain(policies: [policy], timestamp: tip, cas: cas)
            let result = await chain.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: cas,
                validationContext: ValidationContext(nowMilliseconds: now)
            )
            XCTAssertEqual(result.disposition, expected, "tip \(tip), now \(now)")
        }
    }

    /// Fails the fetch of one content id with `error`; serves the rest.
    private actor FailingFetcher: Fetcher {
        let backing: SimCAS
        let failing: String
        let error: Error?

        init(backing: SimCAS, failing: String, error: Error?) {
            self.backing = backing
            self.failing = failing
            self.error = error
        }

        func fetch(rawCid: String) async throws -> Data {
            if rawCid == failing, let error { throw error }
            return try await backing.fetch(rawCid: rawCid)
        }
    }

    /// An error nothing enumerates.
    private struct Unenumerated: Error {}

    private enum PolicyOutcome { case accepted, invalid, unavailable }

    /// One outcome of a policy evaluation: the module, how it is referenced,
    /// whether this node can fetch it, and the verdict both paths must reach.
    private struct PolicyCase {
        var name: String
        /// The body of both entrypoints, given `$recurse`'s index.
        var body: (Int) -> [UInt8] = { _ in PolicyWasm.i32(1) }
        var alloc = PolicyWasm.i32(1024)
        var importsFunction = false
        var scope = WasmPolicyRef.Scope.transaction
        var entrypoint: String? = nil
        var fetchError: Error? = nil
        var expected: PolicyOutcome
    }

    func testPreflightAndImportClassifyEveryPolicyOutcomeAlike() async throws {
        // Every outcome of a policy evaluation, judged on the same transaction
        // by preflight and by import of a block carrying it. An outcome that
        // is a function of (module, input) on the pinned engine is a completed
        // verdict, so both exclude; only a module this node cannot obtain, or
        // an error nothing enumerates, is unavailable. The chains here skip
        // genesis validation, which would refuse the defective modules.
        typealias W = PolicyWasm
        let cases = [
            PolicyCase(name: "accept", expected: .accepted),
            PolicyCase(name: "reject", body: { _ in W.i32(0) }, expected: .invalid),
            PolicyCase(name: "unreachable", body: { _ in W.unreachable }, expected: .invalid),
            PolicyCase(
                name: "out-of-bounds load",  // (i32.load (i32.const 0x7fffffff))
                body: { _ in W.i32(0x7fffffff) + [0x28, 0x02, 0x00] }, expected: .invalid),
            PolicyCase(
                name: "divide by zero",  // (i32.div_u (i32.const 1) (i32.const 0))
                body: { _ in W.i32(1) + W.i32(0) + [0x6e] }, expected: .invalid),
            PolicyCase(
                name: "divide overflow",  // (i32.div_s (i32.const 0x80000000) (i32.const -1))
                body: { _ in W.i32(-0x8000_0000) + W.i32(-1) + [0x6d] }, expected: .invalid),
            PolicyCase(
                name: "indirect call to null",
                body: { _ in W.callNullary(slot: 1) + W.i32(1) }, expected: .invalid),
            PolicyCase(
                name: "mismatched indirect call",
                body: { _ in W.callNullary(slot: 0) + W.i32(1) }, expected: .invalid),
            PolicyCase(
                name: "table out of bounds",
                body: { _ in W.callNullary(slot: 9) + W.i32(1) }, expected: .invalid),
            PolicyCase(
                name: "call stack exhaustion",  // call $recurse
                body: { [0x10] + W.uleb($0) }, expected: .invalid),
            PolicyCase(name: "trap in the allocator", alloc: W.unreachable, expected: .invalid),
            PolicyCase(
                name: "allocator returns an out-of-range pointer",
                alloc: W.i32(0x7ffffff0), expected: .invalid),
            PolicyCase(name: "type-invalid body", body: { _ in [0x42, 0x01] }, expected: .invalid),  // i64.const 1
            PolicyCase(name: "stack-invalid body", body: { _ in [0x6a] }, expected: .invalid),  // i32.add
            PolicyCase(
                name: "unlinkable import",  // (import "env" "f" (func))
                importsFunction: true, expected: .invalid),
            PolicyCase(name: "missing entrypoint", entrypoint: "absent_entrypoint", expected: .invalid),
            PolicyCase(name: "action scope: accept", scope: .action, expected: .accepted),
            PolicyCase(name: "action scope: reject", body: { _ in W.i32(0) }, scope: .action, expected: .invalid),
            PolicyCase(name: "action scope: trap", body: { _ in W.unreachable }, scope: .action, expected: .invalid),
            PolicyCase(
                name: "action scope: allocator returns an out-of-range pointer",
                alloc: W.i32(0x7ffffff0), scope: .action, expected: .invalid),
            PolicyCase(
                name: "missing module",
                fetchError: cashew.FetcherError.notFound("module"), expected: .unavailable),
            PolicyCase(
                name: "unenumerated error",
                fetchError: Unenumerated(), expected: .unavailable),
        ]
        for testCase in cases {
            let store = SimCAS()
            let policy = try await W.store(
                W.module(body: testCase.body, alloc: testCase.alloc, importsFunction: testCase.importsFunction),
                scope: testCase.scope, entrypoint: testCase.entrypoint, in: store
            )
            let genesis = try await storedGenesis(
                spec: preflightSpec(policies: [policy]),
                timestamp: 1_000,
                cas: store
            )
            let tx = transaction(
                signers: [CryptoUtils.generateKeyPair()],
                nonce: 0,
                actions: testCase.scope == .action
                    ? [Action(key: "app/v1/data", oldValue: nil, newValue: "value")] : []
            )
            let block = try await storedBlock(
                on: genesis,
                transactions: [tx],
                timestamp: 2_000,
                nonce: 1,
                cas: store
            )
            let fetcher = FailingFetcher(
                backing: store, failing: policy.moduleCID, error: testCase.fetchError
            )

            var chain = try await preflightChain(genesis: genesis, fetcher: store)
            let preflight = await chain.preflightTransaction(tx, fetcher: fetcher)
            let imported = try await chain.admitRoot(block, fetcher: fetcher)

            switch testCase.expected {
            case .accepted:
                XCTAssertEqual(preflight.disposition, .ready, testCase.name)
                XCTAssertEqual(imported.update?.excluded, false, testCase.name)
            case .invalid:
                // Execution proves the block invalid: it keeps its work and
                // is excluded.
                XCTAssertEqual(preflight.disposition, .invalid, testCase.name)
                XCTAssertEqual(imported.update?.excluded, true, testCase.name)
            case .unavailable:
                XCTAssertEqual(preflight.disposition, .unavailable, testCase.name)
                XCTAssertEqual(imported.failure, .unavailableEvidence, testCase.name)
            }
        }
    }

    func testMisbehavingPolicyIsInvalid() async throws {
        // A module without the configured entrypoint throws
        // `.missingEntrypoint` at evaluation: a property of the chain's
        // committed policy, so the transaction is evicted as import would
        // exclude a block carrying it.
        let cas = SimCAS()
        let policy = try await PolicyWasm.store(PolicyWasm.module(), entrypoint: "absent_entrypoint", in: cas)
        let chain = try await emptyChain(policies: [policy], cas: cas)
        let result = await chain.preflightTransaction(
            transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
            fetcher: cas
        )
        XCTAssertEqual(result.disposition, .invalid)
    }

    func testChildWithdrawalNeedsCandidateParentState() async throws {
        let cas = SimCAS()
        let signer = CryptoUtils.generateKeyPair()
        let chain = try await emptyChain(path: [DEFAULT_ROOT_DIRECTORY, "Child"], cas: cas)
        let withdrawal = transaction(
            signers: [signer],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
            withdrawalActions: [WithdrawalAction(
                withdrawer: address(signer),
                nonce: 1,
                demander: address(signer),
                amountDemanded: 1,
                amountWithdrawn: 1
            )]
        )

        let result = await chain.preflightTransaction(
            withdrawal,
            fetcher: cas
        )
        XCTAssertEqual(result.disposition, .unavailable)

        // A parent state without the receipt: it may be a block away, so a
        // retry, never a verdict.
        try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
        let unproven = await chain.preflightTransaction(
            withdrawal,
            parentState: LatticeState.emptyHeader,
            fetcher: cas
        )
        XCTAssertEqual(unproven.disposition, .unavailable)

        // A receipt that is there and names another withdrawer is a verdict.
        // The receipt's own debit and credit are funded so it changes only
        // the receipt state.
        let other = address(CryptoUtils.generateKeyPair())
        let empty = try XCTUnwrap(LatticeState.emptyHeader.node)
        let (receipted, _) = try await empty.proveAndUpdateState(
            allAccountActions: [
                AccountAction(owner: other, delta: 1),
                AccountAction(owner: address(signer), delta: -1),
            ],
            allActions: [], allDepositActions: [],
            allReceiptActions: [ReceiptAction(
                withdrawer: other, nonce: 1, demander: address(signer), amountDemanded: 1, directory: "Child"
            )],
            allWithdrawalActions: [], transactionBodies: [], fetcher: cas
        )
        XCTAssertEqual(receipted.accountState.rawCID, empty.accountState.rawCID)
        let parent = try LatticeStateHeader(node: receipted)
        try await parent.storeRecursively(storer: cas as any VolumeStorer)
        let contradicted = await chain.preflightTransaction(withdrawal, parentState: parent, fetcher: cas)
        XCTAssertEqual(contradicted.disposition, .invalid)
    }
}
