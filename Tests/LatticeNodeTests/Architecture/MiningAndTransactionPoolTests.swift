import Foundation
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode

private actor MiningTestStore: Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = entries[rawCid] else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    func store(entries newEntries: [String: Data]) async throws {
        entries.merge(newEntries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) async throws {
        entries.merge(volume.entries) { existing, _ in existing }
    }

    func insert(_ data: Data, for cid: String) {
        entries[cid] = data
    }

    func allEntries() -> [String: Data] { entries }
}

private struct UnavailableMiningFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

final class MiningTemplateBookTests: XCTestCase {
    func testTemplateUsesChainTargetAndRejectsDuplicateChildDirectories() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"]
        )

        let template = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        XCTAssertEqual(template.searchTarget, fixture.genesis.nextTarget)

        let child = DirectChildCandidate(
            directory: "Payments",
            block: fixture.genesis
        )
        await XCTAssertThrowsErrorAsync(
            try await book.build(
                previous: fixture.genesis,
                transactions: [],
                children: [child, child],
                timestamp: 1,
                fetcher: fixture.store
            )
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .duplicateChildDirectory)
        }
    }

    func testTemplateRecursivelyPropagatesNestedSearchTarget() async throws {
        let hard = try await chainFixture(target: UInt256(4))
        let middleGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: hard.genesis.postState,
            timestamp: 1,
            target: UInt256(4),
            fetcher: hard.store
        )
        let leafGenesis = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: middleGenesis.postState,
            timestamp: 1,
            target: .max,
            fetcher: hard.store
        )
        let leafBlock = try await BlockBuilder.buildBlock(
            previous: leafGenesis,
            timestamp: 2,
            fetcher: hard.store
        )
        let middleBook = MiningTemplateBook(
            chainPath: ["Nexus", "Middle"],
        )
        let middle = try await middleBook.build(
            previous: middleGenesis,
            transactions: [],
            children: [DirectChildCandidate(
                directory: "Leaf",
                block: leafBlock
            )],
            timestamp: 2,
            fetcher: hard.store
        )
        XCTAssertEqual(middle.block.target, UInt256(4))
        XCTAssertEqual(middle.searchTarget, UInt256.max)

        let rootBook = MiningTemplateBook(
            chainPath: ["Nexus"],
        )
        let root = try await rootBook.build(
            previous: hard.genesis,
            transactions: [],
            children: [DirectChildCandidate(
                directory: "Middle",
                block: middle.block,
                searchWitness: middle.searchWitness
            )],
            timestamp: 2,
            fetcher: hard.store
        )

        XCTAssertEqual(root.block.target, UInt256(4))
        XCTAssertEqual(root.searchTarget, UInt256.max)
    }

    func testStateInvalidTransactionDoesNotSuppressWork() async throws {
        let fixture = try await chainFixture()
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let valid = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 1
        )
        let stale = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2_000),
                AccountAction(owner: recipient, delta: 1_999),
            ],
            fee: 1,
            nonce: 2
        )

        let template = try await MiningTemplateBook(
            chainPath: ["Nexus"],
        ).build(
            previous: fixture.genesis,
            transactions: [valid, stale],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        let transactions = try XCTUnwrap(template.block.transactions.node)
        let included = try transactions.allKeysAndValues().values.compactMap {
            $0.node?.body.rawCID
        }

        XCTAssertEqual(included, [valid.body.rawCID])
    }

    func testTemplateFillsWithValidTransactionSkippingStateInvalid()
        async throws
    {
        let fixture = try await chainFixture()
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let invalid = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2_000),
                AccountAction(owner: recipient, delta: 1_900),
            ],
            fee: 100,
            nonce: 2
        )
        let valid = try signedTransaction(
            key: fixture.key,
            accountActions: [
                AccountAction(owner: fixture.owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 1
        )
        let pool = TransactionPool()
        let spec = try XCTUnwrap(fixture.genesis.spec.node)
        _ = try await pool.submit(
            valid,
            spec: spec,
            fetcher: fixture.store
        )
        _ = try await pool.submit(
            invalid,
            spec: spec,
            fetcher: fixture.store
        )
        // Served in ascending nonce order (valid n1 before invalid n2), not by fee.
        let ordered = await pool.transactions(limit: .max)

        let template = try await MiningTemplateBook(
            chainPath: ["Nexus"],
        ).build(
            previous: fixture.genesis,
            transactions: ordered,
            children: [],
            timestamp: 1,
            transactionLimit: 2,
            fetcher: fixture.store
        )
        let included = try XCTUnwrap(template.block.transactions.node)
            .allKeysAndValues().values
        XCTAssertEqual(included.count, 1)
        XCTAssertEqual(
            included.first?.rawCID,
            try VolumeImpl<Transaction>(node: valid).rawCID
        )
    }

    func testStateFetchFailureIsNotMisclassifiedAsStaleTransaction() async throws {
        let fixture = try await chainFixture()
        let transaction = try signedTransaction(
            key: fixture.key,
            accountActions: [AccountAction(owner: fixture.owner, delta: -1)],
            fee: 1,
            nonce: 1
        )

        await XCTAssertThrowsErrorAsync(
            try await MiningTemplateBook(
                chainPath: ["Nexus"],
            ).build(
                previous: fixture.genesis.withUnresolvedPostState(),
                transactions: [transaction],
                children: [],
                timestamp: 1,
                fetcher: UnavailableMiningFetcher()
            )
        ) { error in
            XCTAssertTrue(error is FetcherError)
        }
    }

    func testTemplateNeverSearchesAndOnlyAppliesSubmittedNonce() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
        )
        let template = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )

        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.workID, try BlockHeader(node: template.block).rawCID)
        let submitted = try await book.candidate(workID: template.workID, nonce: 42)
        XCTAssertEqual(submitted.nonce, 42)
    }

    func testPreviewCannotBeSubmittedOrEvictIssuedWork() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            capacity: 1
        )
        let issued = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        let preview = try await book.preview(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 2,
            fetcher: fixture.store
        )
        XCTAssertNotEqual(preview.workID, issued.workID)

        await XCTAssertThrowsErrorAsync(
            try await book.candidate(workID: preview.workID, nonce: 0)
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
        let submitted = try await book.candidate(
            workID: issued.workID,
            nonce: 42
        )
        XCTAssertEqual(submitted.nonce, 42)
    }

    func testReissuedWorkRefreshesTemplateCapacityOrder() async throws {
        let fixture = try await chainFixture()
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
            capacity: 2
        )
        func issue(timestamp: Int64) async throws -> MiningTemplate {
            try await book.build(
                previous: fixture.genesis,
                transactions: [],
                children: [],
                timestamp: timestamp,
                fetcher: fixture.store
            )
        }

        let first = try await issue(timestamp: 1)
        let second = try await issue(timestamp: 2)
        let reissued = try await issue(timestamp: 1)
        XCTAssertEqual(reissued.workID, first.workID)
        let third = try await issue(timestamp: 3)

        _ = try await book.candidate(workID: first.workID, nonce: 0)
        _ = try await book.candidate(workID: third.workID, nonce: 0)
        await XCTAssertThrowsErrorAsync(
            try await book.candidate(workID: second.workID, nonce: 0)
        ) { error in
            XCTAssertEqual(error as? MiningTemplateError, .unknownWork)
        }
    }

    func testFirstLiveTemplateWinsWorkIDMetadataCollision() async throws {
        let fixture = try await chainFixture(target: UInt256(1))
        let book = MiningTemplateBook(
            chainPath: ["Nexus"],
        )
        let first = try await book.build(
            previous: fixture.genesis,
            transactions: [],
            children: [],
            timestamp: 1,
            fetcher: fixture.store
        )
        let conflicting = MiningTemplate(
            workID: first.workID,
            block: first.block,
            searchTarget: UInt256(7),
            chainPath: first.chainPath,
            expiresAt: ContinuousClock.now + .seconds(30),
            childCandidates: first.childCandidates,
            searchWitness: nil
        )

        let issued = await book.issue(conflicting)
        XCTAssertEqual(issued.searchTarget, first.searchTarget)

        await book.invalidateAll()
        let shortLived = MiningTemplate(
            workID: first.workID,
            block: first.block,
            searchTarget: first.searchTarget,
            chainPath: first.chainPath,
            expiresAt: ContinuousClock.now + .milliseconds(250),
            childCandidates: first.childCandidates,
            searchWitness: first.searchWitness
        )
        _ = await book.issue(shortLived)
        let reused = await book.issue(MiningTemplate(
            workID: conflicting.workID,
            block: conflicting.block,
            searchTarget: conflicting.searchTarget,
            chainPath: conflicting.chainPath,
            expiresAt: ContinuousClock.now + .seconds(30),
            childCandidates: conflicting.childCandidates,
            searchWitness: conflicting.searchWitness
        ))
        let response = MiningTemplateResponse(
            template: reused,
            maximumLifetimeMilliseconds: 30_000
        )
        XCTAssertLessThanOrEqual(response.expiresInMilliseconds, 250)

        await book.invalidateAll()
        _ = await book.issue(MiningTemplate(
            workID: first.workID,
            block: first.block,
            searchTarget: first.searchTarget,
            chainPath: first.chainPath,
            expiresAt: ContinuousClock.now - .seconds(1),
            childCandidates: first.childCandidates,
            searchWitness: first.searchWitness
        ))
        let replacement = await book.issue(MiningTemplate(
            workID: conflicting.workID,
            block: conflicting.block,
            searchTarget: conflicting.searchTarget,
            chainPath: conflicting.chainPath,
            expiresAt: ContinuousClock.now + .seconds(30),
            childCandidates: conflicting.childCandidates,
            searchWitness: conflicting.searchWitness
        ))
        XCTAssertEqual(replacement.searchTarget, conflicting.searchTarget)
    }

    private func chainFixture(
        target: UInt256 = .max
    ) async throws -> (
        genesis: Block,
        store: MiningTestStore,
        key: (privateKey: String, publicKey: String),
        owner: String
    ) {
        let store = MiningTestStore()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 10,
            targetBlockTime: 1_000,
            initialReward: 100,
            halvingInterval: 10_000
        )
        let premine = try signedTransaction(
            key: key,
            accountActions: [AccountAction(
                owner: owner,
                delta: Int64(spec.premineAmount())
            )],
            fee: 0,
            nonce: 0
        )
        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: spec,
            transactions: [premine],
            timestamp: 0,
            target: target,
            fetcher: store
        )
        try await VolumeImpl<Transaction>(node: premine).store(storer: store)
        try await LatticeState.emptyHeader.storeRecursively(storer: store)
        try await BlockHeader(node: result.block).storeBlock(storer: store)
        try await result.block.postState.storeRecursively(storer: store)
        return (result.block, store, key, owner)
    }
}

final class TransactionPoolArchitectureTests: XCTestCase {
    func testHistoricalBodyCIDInputSignatureIsAcceptedAtNodeIngress() async throws {
        let store = MiningTestStore()
        let key = CryptoUtils.generateKeyPair()
        let body = transactionBody(
            key: key,
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: -1
            )],
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let header = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(CryptoUtils.sign(
            message: header.rawCID,
            privateKeyHex: key.privateKey
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: signature],
            body: header
        )
        let pool = TransactionPool()

        let cid = try await pool.submit(
            transaction,
            spec: testSpec(),
            fetcher: store
        ).transactionCID

        XCTAssertEqual(cid, try VolumeImpl<Transaction>(node: transaction).rawCID)
        let count = await pool.count
        XCTAssertEqual(count, 1)
    }

    func testPoolEnforcesResourcesButLeavesConsensusToLattice() async throws {
        let store = MiningTestStore()
        let key = CryptoUtils.generateKeyPair()
        let wrongPathBody = transactionBody(
            key: key,
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: -1
            )],
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus", "Wrong"]
        )
        let wrongPath = Transaction(
            signatures: [key.publicKey: "not-a-signature"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        let pool = TransactionPool(maxSignatures: 1)

        _ = try await pool.submit(
            wrongPath,
            spec: testSpec(),
            fetcher: store
        )

        let tooManySignatures = Transaction(
            signatures: ["a": "x", "b": "y"],
            body: try HeaderImpl(node: wrongPathBody)
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                tooManySignatures,
                spec: testSpec(),
                fetcher: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }

        let detached = try HeaderImpl(node: wrongPathBody).removingNode()
        // The signature-field cap is the wire capacity (UInt16.max), not an
        // invented 256; a field one byte past it is rejected as too large.
        let oversizedSignature = Transaction(
            signatures: [String(repeating: "a", count: Int(UInt16.max) + 1): "x"],
            body: detached
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                oversizedSignature,
                spec: testSpec(),
                fetcher: UnavailableMiningFetcher()
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }

        let smallSpec = testSpec(maxBlockSize: 1_024)
        await store.insert(Data(repeating: 0, count: 1_025), for: detached.rawCID)
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                Transaction(signatures: [:], body: detached),
                spec: smallSpec,
                fetcher: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .tooLarge)
        }
        let count = await pool.count
        XCTAssertEqual(count, 1)
    }

    func testWithinASignerNonceOrderBeatsFee() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        // Higher fee on the higher nonce, same signer: the fee market ranks across
        // signers, but a signer's own nonces must stay sequential so the assembler
        // can apply them, so nonce 0 is still served before nonce 1.
        let later = try signedTransaction(
            key: key,
            accountActions: [AccountAction(owner: owner, delta: -1)],
            fee: 1_000,
            nonce: 1
        )
        let earlier = try signedTransaction(
            key: key,
            accountActions: [AccountAction(owner: owner, delta: -1)],
            fee: 1,
            nonce: 0
        )
        _ = try await pool.submit(
            later, spec: testSpec(), fetcher: store, disposition: .future
        )
        _ = try await pool.submit(
            earlier, spec: testSpec(), fetcher: store
        )
        let ordered = await pool.transactions(limit: 2).map(\.body.rawCID)
        XCTAssertEqual(ordered, [earlier.body.rawCID, later.body.rawCID])
    }

    func testFutureNonceBecomesEligibleBehindReadyPredecessor()
        async throws
    {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let current = try signedTransaction(
            key: key,
            accountActions: [
                AccountAction(owner: owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 0
        )
        let future = try signedTransaction(
            key: key,
            accountActions: [
                AccountAction(owner: owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 1
        )

        _ = try await pool.submit(
            current,
            spec: testSpec(),
            fetcher: store
        )
        _ = try await pool.submit(
            future,
            spec: testSpec(),
            fetcher: store,
            disposition: .future
        )
        let initiallyReady = await pool.transactions(limit: .max)
            .map(\.body.node?.nonce)
        XCTAssertEqual(initiallyReady, [0, 1])

        let removed = await pool.revalidate { transaction in
            switch transaction.body.node?.nonce {
            case 0: return .invalid
            case 1: return .ready
            default: return .future
            }
        }

        XCTAssertEqual(removed.removed.count, 1)
        let finallyReady = await pool.transactions(limit: .max)
            .map(\.body.node?.nonce)
        XCTAssertEqual(finallyReady, [1])

        await pool.rollback(removed)
        let restored = await pool.transactions(limit: .max)
            .map(\.body.node?.nonce)
        XCTAssertEqual(restored, [0, 1])
    }

    func testDependencyFrontierPreservesMultiSignerNonceOrder()
        async throws
    {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let first = try signedTransaction(
            key: firstKey,
            accountActions: [],
            fee: 1,
            nonce: 0
        )
        let second = try signedTransaction(
            key: secondKey,
            accountActions: [],
            fee: 10,
            nonce: 0
        )
        let joint = try signedTransaction(
            keys: [firstKey, secondKey],
            accountActions: [],
            fee: 100,
            nonce: 1
        )
        for (transaction, disposition) in [
            (first, TransactionPoolDisposition.ready),
            (second, .ready),
            (joint, .future),
        ] {
            _ = try await pool.submit(
                transaction,
                spec: testSpec(),
                fetcher: store,
                disposition: disposition
            )
        }

        let selected = await pool.transactions(limit: .max)
        let roots = try selected.map { try VolumeImpl<Transaction>(node: $0).rawCID }
        // The nonce-1 multi-signer transaction is served after BOTH its nonce-0
        // predecessors (so the builder can sequence it); within nonce 0 the order
        // is deterministic (by CID), not by fee.
        XCTAssertEqual(roots.count, 3)
        XCTAssertEqual(roots.last, try VolumeImpl<Transaction>(node: joint).rawCID)
        XCTAssertEqual(
            Set(roots.dropLast()),
            Set(try [first, second].map {
                try VolumeImpl<Transaction>(node: $0).rawCID
            })
        )
    }

    func testSameSignerAndNonceReplacedByHigherFee() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let low = try signedTransaction(
            key: key,
            accountActions: [
                AccountAction(owner: owner, delta: -2),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 0
        )
        let high = try signedTransaction(
            key: key,
            accountActions: [
                AccountAction(owner: owner, delta: -3),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 2,
            nonce: 0
        )

        // The first submission holds the (signer, nonce) slot...
        _ = try await pool.submit(
            low,
            spec: testSpec(),
            fetcher: store
        )
        // ...until the SAME signer replaces it by out-bidding the incumbent fee
        // (replace-by-fee). Only the signer can sign that nonce, so this is
        // self-replacement, not a front-run.
        let replacement = try await pool.submit(
            high,
            spec: testSpec(),
            fetcher: store
        )
        XCTAssertEqual(replacement.replaced.map(\.cid), [
            try VolumeImpl<Transaction>(node: low).rawCID,
        ])

        let count = await pool.count
        let selected = await pool.transactions(limit: 1).first
        XCTAssertEqual(count, 1)
        XCTAssertEqual(selected?.body.rawCID, high.body.rawCID)
    }

    func testPartialSignerOverlapAtSameNonceIsRejected() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let firstKey = CryptoUtils.generateKeyPair()
        let sharedKey = CryptoUtils.generateKeyPair()
        let thirdKey = CryptoUtils.generateKeyPair()
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let first = try signedTransaction(
            keys: [firstKey, sharedKey],
            accountActions: [
                AccountAction(
                    owner: CryptoUtils.createAddress(from: firstKey.publicKey),
                    delta: -1
                ),
                AccountAction(
                    owner: CryptoUtils.createAddress(from: sharedKey.publicKey),
                    delta: -1
                ),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 0
        )
        let overlap = try signedTransaction(
            keys: [sharedKey, thirdKey],
            accountActions: [
                AccountAction(
                    owner: CryptoUtils.createAddress(from: sharedKey.publicKey),
                    delta: -1
                ),
                AccountAction(
                    owner: CryptoUtils.createAddress(from: thirdKey.publicKey),
                    delta: -2
                ),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 2,
            nonce: 0
        )

        _ = try await pool.submit(
            first,
            spec: testSpec(),
            fetcher: store
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                overlap,
                spec: testSpec(),
                fetcher: store
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .conflictingNonce)
        }

        let count = await pool.count
        XCTAssertEqual(count, 1)
    }

    func testCapacityKeepsOldestReadyAtEqualFeeAndRejectsNewer() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool(maxCount: 1)
        let firstKey = CryptoUtils.generateKeyPair()
        let secondKey = CryptoUtils.generateKeyPair()
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let incumbent = try signedTransaction(
            key: firstKey,
            accountActions: [
                AccountAction(
                    owner: CryptoUtils.createAddress(from: firstKey.publicKey),
                    delta: -2
                ),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 0
        )
        // A newer ready transaction at the SAME miner fee (both debit 2, credit 1
        // → excess 1): fee is the primary eviction key, so equal fees fall back to
        // first-come-first-served and the newer arrival cannot displace the
        // incumbent.
        let newer = try signedTransaction(
            key: secondKey,
            accountActions: [
                AccountAction(
                    owner: CryptoUtils.createAddress(from: secondKey.publicKey),
                    delta: -2
                ),
                AccountAction(owner: recipient, delta: 1),
            ],
            fee: 1,
            nonce: 0
        )

        _ = try await pool.submit(
            incumbent, spec: testSpec(), fetcher: store, addedAt: Date(timeIntervalSince1970: 1)
        )
        // At capacity and equal fee, the older ready entry is kept; the newer
        // one is rejected.
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                newer, spec: testSpec(), fetcher: store, addedAt: Date(timeIntervalSince1970: 2)
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }

        let count = await pool.count
        let selected = await pool.transactions(limit: 1).first
        XCTAssertEqual(count, 1)
        XCTAssertEqual(selected?.body.rawCID, incumbent.body.rawCID)
    }

    func testReadyTransactionsOutrankNonReadyFeesAtCapacity() async throws {
        let store = MiningTestStore()
        let ready = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            accountActions: [],
            fee: 0,
            nonce: 0
        )
        // A non-ready transaction paying a large REAL miner fee (debit excess
        // 1_000_000) still loses to a zero-fee ready one: readiness is ranked
        // above fee.
        let futureKey = CryptoUtils.generateKeyPair()
        let future = try signedTransaction(
            key: futureKey,
            accountActions: [
                AccountAction(
                    owner: CryptoUtils.createAddress(from: futureKey.publicKey),
                    delta: -1_000_000
                ),
            ],
            fee: 0,
            nonce: 1
        )

        let readyPool = TransactionPool(maxCount: 1)
        _ = try await readyPool.submit(ready, spec: testSpec(), fetcher: store)
        await XCTAssertThrowsErrorAsync(
            try await readyPool.submit(
                future,
                spec: testSpec(),
                fetcher: store,
                disposition: .future
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }

        let futurePool = TransactionPool(maxCount: 1)
        _ = try await futurePool.submit(
            future,
            spec: testSpec(),
            fetcher: store,
            disposition: .future
        )
        let mutation = try await futurePool.submit(
            ready,
            spec: testSpec(),
            fetcher: store
        )
        XCTAssertEqual(mutation.evicted.map(\.transaction.body.rawCID), [
            future.body.rawCID,
        ])
    }

    func testNonReadyQueueIsBoundedPerSigner() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool(maxNonReadyPerSigner: 1)
        let key = CryptoUtils.generateKeyPair()
        let first = try signedTransaction(
            key: key,
            accountActions: [],
            fee: 1,
            nonce: 1
        )
        let second = try signedTransaction(
            key: key,
            accountActions: [],
            fee: 2,
            nonce: 2
        )

        _ = try await pool.submit(
            first,
            spec: testSpec(),
            fetcher: store,
            disposition: .future
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                second,
                spec: testSpec(),
                fetcher: store,
                disposition: .unavailable
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }
    }

    func testReplaceByFeeRequiresAStrictlyHigherBid() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )

        // The bid is the real miner fee = debit − credit. A distinct credit
        // gives each attempt a distinct CID at the same (signer, nonce) while we
        // dial the excess via the debit, so we exercise the fee gate — not the
        // idempotent duplicate-CID early return.
        func tx(debit: Int64, credit: Int64) throws -> Transaction {
            try signedTransaction(
                key: key,
                accountActions: [
                    AccountAction(owner: owner, delta: -debit),
                    AccountAction(owner: recipient, delta: credit),
                ],
                fee: 0,
                nonce: 0
            )
        }

        // Incumbent pays a miner fee of 5 (debit 6, credit 1).
        _ = try await pool.submit(
            tx(debit: 6, credit: 1), spec: testSpec(), fetcher: store,
            addedAt: Date()
        )

        // Equal miner fee (5, via debit 7/credit 2) at the same slot is rejected.
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                tx(debit: 7, credit: 2), spec: testSpec(), fetcher: store,
                addedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .feeTooLow)
        }
        // Lower miner fee (4, via debit 5/credit 1) is rejected.
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                tx(debit: 5, credit: 1), spec: testSpec(), fetcher: store,
                addedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .feeTooLow)
        }

        // A strictly higher miner fee (6, via debit 7/credit 1) replaces it.
        let bump = try tx(debit: 7, credit: 1)
        let mutation = try await pool.submit(
            bump, spec: testSpec(), fetcher: store, addedAt: Date()
        )
        XCTAssertEqual(mutation.replaced.count, 1)
        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot.first?.cid,
            try VolumeImpl<Transaction>(node: bump).rawCID
        )
    }

    func testCapacityEvictionShedsTheLowestFeeFirst() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool(maxCount: 2)

        // The miner fee is the debit excess, not the declared `body.fee` field.
        func submit(minerFee: Int64) async throws -> Transaction {
            let key = CryptoUtils.generateKeyPair()
            let owner = CryptoUtils.createAddress(from: key.publicKey)
            let transaction = try signedTransaction(
                key: key,
                accountActions: [AccountAction(owner: owner, delta: -minerFee)],
                fee: 0,
                nonce: 0
            )
            _ = try await pool.submit(
                transaction, spec: testSpec(), fetcher: store, addedAt: Date()
            )
            return transaction
        }

        let low = try await submit(minerFee: 1)
        let rich = try await submit(minerFee: 10)
        // Pool is full (maxCount 2). A fee-5 arrival outranks the fee-1 entry,
        // so the fee-1 entry is evicted, not the newcomer.
        let mid = try await submit(minerFee: 5)

        let survivors = Set(await pool.snapshot().map(\.cid))
        XCTAssertEqual(survivors, Set(try [rich, mid].map {
            try VolumeImpl<Transaction>(node: $0).rawCID
        }))
        XCTAssertFalse(
            survivors.contains(try VolumeImpl<Transaction>(node: low).rawCID)
        )

        // A fee below every incumbent cannot buy its way in.
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let underbid = try signedTransaction(
            key: key,
            accountActions: [AccountAction(owner: owner, delta: -1)],
            fee: 0,
            nonce: 0
        )
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                underbid, spec: testSpec(), fetcher: store, addedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }
    }

    func testTemplateOrderingLeadsWithTheHighestFeeSigner() async throws {
        let store = MiningTestStore()
        let pool = TransactionPool()

        // Rank is the real miner fee (debit excess), not the declared field.
        func submit(minerFee: Int64) async throws -> String {
            let key = CryptoUtils.generateKeyPair()
            let owner = CryptoUtils.createAddress(from: key.publicKey)
            let transaction = try signedTransaction(
                key: key,
                accountActions: [AccountAction(owner: owner, delta: -minerFee)],
                fee: 0,
                nonce: 0
            )
            _ = try await pool.submit(
                transaction, spec: testSpec(), fetcher: store, addedAt: Date()
            )
            return try VolumeImpl<Transaction>(node: transaction).rawCID
        }

        let cheap = try await submit(minerFee: 1)
        let rich = try await submit(minerFee: 100)
        let mid = try await submit(minerFee: 20)

        let ordered = await pool.transactions(limit: .max)
        let orderedCIDs = try ordered.map {
            try VolumeImpl<Transaction>(node: $0).rawCID
        }
        XCTAssertEqual(orderedCIDs, [rich, mid, cheap])
    }

    func testNonReadyDeclaredFeeCannotBuyEviction() async throws {
        // A non-ready entry's debits are not funding-checked, so its `minerFee`
        // is untrusted: among non-ready entries eviction is first-come-first-
        // served, and a later huge-declared-fee entry cannot displace an older one.
        let store = MiningTestStore()
        let pool = TransactionPool(maxCount: 1)

        func futureTransaction(debit: Int64) throws -> Transaction {
            let key = CryptoUtils.generateKeyPair()
            let owner = CryptoUtils.createAddress(from: key.publicKey)
            return try signedTransaction(
                key: key,
                accountActions: [AccountAction(owner: owner, delta: -debit)],
                fee: 0,
                nonce: 5
            )
        }

        let older = try futureTransaction(debit: 1)
        _ = try await pool.submit(
            older, spec: testSpec(), fetcher: store,
            disposition: .future, addedAt: Date(timeIntervalSince1970: 1)
        )
        let newerHugeFee = try futureTransaction(debit: 1_000_000)
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                newerHugeFee, spec: testSpec(), fetcher: store,
                disposition: .future, addedAt: Date(timeIntervalSince1970: 2)
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .full)
        }
        let survivors = await pool.snapshot().map(\.cid)
        XCTAssertEqual(survivors, [try VolumeImpl<Transaction>(node: older).rawCID])
    }

    func testNonReadySlotReplacedByStrictlyHigherRealFee() async throws {
        // Replace-by-fee applies to a not-yet-executable slot too: a signer may
        // replace their OWN pending claim (e.g. a withdrawal queued before its
        // parent receipt commits) with a higher-value one, but an equal excess is
        // still rejected — replacement stays fee-gated, never free recency.
        let store = MiningTestStore()
        let pool = TransactionPool()
        let key = CryptoUtils.generateKeyPair()
        let owner = CryptoUtils.createAddress(from: key.publicKey)
        let recipient = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )

        // Excess = debit − credit; the credit varies the CID at a fixed excess.
        func pendingClaim(debit: Int64, credit: Int64) throws -> Transaction {
            try signedTransaction(
                key: key,
                accountActions: [
                    AccountAction(owner: owner, delta: -debit),
                    AccountAction(owner: recipient, delta: credit),
                ],
                fee: 0,
                nonce: 5
            )
        }

        // Incumbent pending claim pays excess 1 (debit 2, credit 1).
        _ = try await pool.submit(
            try pendingClaim(debit: 2, credit: 1), spec: testSpec(),
            fetcher: store, disposition: .future
        )
        // Equal excess (debit 3, credit 2) at the same slot is still rejected.
        await XCTAssertThrowsErrorAsync(
            try await pool.submit(
                try pendingClaim(debit: 3, credit: 2), spec: testSpec(),
                fetcher: store, disposition: .future
            )
        ) { error in
            XCTAssertEqual(error as? TransactionPoolError, .feeTooLow)
        }
        // A strictly higher excess (debit 5, credit 1 → excess 4) replaces it.
        let better = try pendingClaim(debit: 5, credit: 1)
        let mutation = try await pool.submit(
            better, spec: testSpec(), fetcher: store, disposition: .future
        )
        XCTAssertEqual(mutation.replaced.count, 1)
        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot.first?.cid,
            try VolumeImpl<Transaction>(node: better).rawCID
        )
    }

}

private func signedTransaction(
    key: (privateKey: String, publicKey: String),
    accountActions: [AccountAction],
    fee: UInt64,
    nonce: UInt64,
    chainPath: [String] = ["Nexus"]
) throws -> Transaction {
    try signedTransaction(
        keys: [key],
        accountActions: accountActions,
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
}

private func signedTransaction(
    keys: [(privateKey: String, publicKey: String)],
    accountActions: [AccountAction],
    fee: UInt64,
    nonce: UInt64,
    chainPath: [String] = ["Nexus"]
) throws -> Transaction {
    let body = TransactionBody(
        accountActions: accountActions,
        actions: [],
        depositActions: [],
        genesisActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: keys.map { CryptoUtils.createAddress(from: $0.publicKey) },
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
    let header = try HeaderImpl(node: body)
    var signatures: [String: String] = [:]
    for key in keys {
        signatures[key.publicKey] = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: key.privateKey
        ))
    }
    return Transaction(signatures: signatures, body: header)
}

private func transactionBody(
    key: (privateKey: String, publicKey: String),
    accountActions: [AccountAction],
    fee: UInt64,
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
        signers: [CryptoUtils.createAddress(from: key.publicKey)],
        fee: fee,
        nonce: nonce,
        chainPath: chainPath
    )
}

private func testSpec(maxBlockSize: Int = 1_000_000) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: maxBlockSize,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 100,
        halvingInterval: 10_000
    )
}

private extension Block {
    func withUnresolvedPostState() -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState.removingNode(),
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
