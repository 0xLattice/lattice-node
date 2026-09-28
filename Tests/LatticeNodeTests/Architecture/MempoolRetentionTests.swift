import Foundation
@testable import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// The mempool's retention against its membership, through the node's own
/// entry points: `ChainService` admission, templates, submitted work, network
/// block import, canonical reconciliation and restore, over a real
/// `ChainProcess` and its on-disk `volumes.db`.
///
/// Pins are read straight from the broker's `volume_pins` table, because
/// `owners(root:)` answers presence only and a pin taken twice under one owner
/// is exactly the defect a count must catch.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class MempoolRetentionTests: XCTestCase {

    // MARK: - NODE-MEMPOOL-001.e

    /// A seeded model-based run: random pool operations against a reference
    /// model of what is pooled, asserting after EVERY operation, for every
    /// root the run ever created, that the live-pool owner pins it exactly
    /// once iff it is pooled — the claim.
    ///
    /// The same step also checks the journal and the durable owner (one pin
    /// iff pooled and local). Those checks track CURRENT behaviour and
    /// establish nothing: NODE-MEMPOOL-001.f and .k own the durable claims,
    /// and the reorg rule below encodes the known defect #227
    /// (NODE-MEMPOOL-001.o).
    ///
    /// Deterministic: every choice the model makes, and every outcome it
    /// predicts, is a function of the seed and the model state. No CID, key
    /// or clock orders anything it predicts — funded fees are unique across
    /// the run and an eviction is drawn only when its victim is unique by
    /// readiness or fee. Keys (and on macOS signatures) are fresh per run, so a replay
    /// repeats the operation sequence and every pool size, not the CIDs. The
    /// run prints that sequence as one `mempool model trace` line.
    /// `LATTICE_TEST_SEED` picks another sequence and
    /// `LATTICE_MEMPOOL_MODEL_STEPS` another length.
    /// Establishes: NODE-MEMPOOL-001.e
    func testLivePoolPinsTrackPoolMembershipAcrossRandomOperations() async throws {
        let defaultSeed: UInt64 = 0x5EED_3E3B_0017_0E01
        let seed = try TestSeed.resolve(default: defaultSeed)
        let defaultSteps = 72
        let steps = try TestBudget.resolve(
            "LATTICE_MEMPOOL_MODEL_STEPS",
            default: defaultSteps
        )
        var generator = SplitMix64(state: seed.value)
        let node = try await MempoolNode.open(test: self, mempoolMaxCount: 3)
        var model = PoolModel(capacity: 3)
        let funded = try await node.fundKeys(count: min(steps + 8, 1_000))
        model.fundedKeys = funded
        try await node.assertMatches(model, context: "\(seed) setup")

        var executed: [ModelOperation: Int] = [:]
        var trace: [String] = []
        var failed = false
        for step in 0..<steps where !failed {
            let operation = model.applicable().randomElement(using: &generator)!
            let context = "\(seed) step=\(step) op=\(operation)"
            executed[operation, default: 0] += 1
            do {
                try await node.apply(
                    operation,
                    to: &model,
                    using: &generator,
                    context: context
                )
                try await node.assertMatches(model, context: context)
                trace.append(
                    "\(operation)(\(model.pooled.count),"
                        + "\(model.pooled.filter(model.local.contains).count))"
                )
            } catch {
                XCTFail("\(context): \(error)")
                failed = true
            }
        }
        print("mempool model trace \(seed): \(trace.joined(separator: " "))")
        // The default run must reach every operation; another seed or length
        // explores whatever it draws.
        if seed.value == defaultSeed, steps >= defaultSteps, !failed {
            XCTAssertEqual(
                Set(executed.keys), Set(ModelOperation.allCases),
                "\(seed) left an operation unexercised: \(executed)"
            )
        }
    }

    // MARK: - NODE-MEMPOOL-001.b

    /// A Nexus template builds on the validated tip — its parent and height —
    /// while a heavier canonical branch is only weighed. The branch arrives
    /// the way weighed sync delivers it, through
    /// `ChainService.importNetworkCandidate(weighed: true)`, so canonical
    /// reconciliation runs and arms the validate walk; with no body source the
    /// walk parks on the missing bodies and the tiers stay apart. The pool is
    /// left empty: which transactions such a template carries is
    /// NODE-MEMPOOL-001.n (#228).
    /// The child path through the same builder is
    /// `NetworkTrustCandidateTests.testAParkedExecutionWalkDoesNotWithholdTheChildsCandidate`.
    /// Establishes: NODE-MEMPOOL-001.b
    func testTemplateBuildsOnTheValidatedTipNotTheWeighedCanonicalTip() async throws {
        let consumer = try await MempoolNode.open(
            test: self,
            executionWalkRetryInterval: .seconds(3_600)
        )
        let validatedBlock = try await consumer.mine()
        let validatedCID = try BlockHeader(node: validatedBlock).rawCID

        let producer = try await MempoolNode.open(test: self)
        let shared = try await producer.process.importBlock(
            BlockHeader(node: validatedBlock),
            remoteSource: FetcherContentSource(consumer.process)
        )
        XCTAssertTrue(shared.decision.isAccepted)
        // Each weighed block carries a transaction, so its body is not part of
        // the boundary a weighed admission stores and the walk cannot execute
        // it locally (an empty block's boundary is the whole block).
        let reward = [AccountAction(
            owner: CryptoUtils.createAddress(
                from: CryptoUtils.generateKeyPair().publicKey
            ),
            delta: 1
        )]
        let weighed = [
            try await producer.mine(rewards: reward),
            try await producer.mine(rewards: reward),
        ]
        for block in weighed {
            let outcome = try await consumer.service.importNetworkCandidate(
                BlockHeader(node: block),
                authenticatedChildPackage: nil,
                preparingChildDirectories: [],
                contentSource: FetcherContentSource(producer.process),
                weighed: true
            )
            XCTAssertTrue(outcome.decision.isAccepted, "\(outcome.decision)")
            await outcome.canonicalCommitReceipt?.wait()
        }
        // Join the walk the reconciliation armed, so the tiers read below are
        // the ones the template is built against.
        await consumer.service.shutdown()
        let canonicalHeight = await consumer.process.canonicalTipHeight()
        XCTAssertEqual(canonicalHeight, validatedBlock.height + 2)
        let validated = await consumer.process.deepestValidatedCanonicalTip()
        XCTAssertEqual(validated?.cid, validatedCID)

        let template = try await consumer.service.miningTemplate(
            MiningTemplateRequest()
        )
        XCTAssertEqual(template.block.parent?.rawCID, validatedCID)
        XCTAssertEqual(template.block.height, validatedBlock.height + 1)
    }

    // MARK: - NODE-MEMPOOL-001.h

    /// Startup clears the live-pool owner (NODE-MEMPOOL-001.g); restoring the
    /// journal pins every restored local root under it again, exactly once,
    /// while the peer root that did not survive stays unpinned.
    /// Establishes: NODE-MEMPOOL-001.h
    func testRestoredLocalRootsArePinnedAgainAfterStartupClearsTheLiveOwner()
        async throws
    {
        var node: MempoolNode? = try await MempoolNode.open(test: self)
        let locals = try (0..<3).map { _ in
            try signedTransaction(key: CryptoUtils.generateKeyPair())
        }
        let peer = try signedTransaction(key: CryptoUtils.generateKeyPair())
        _ = try await node!.service.submitTransaction(
            SubmitTransactionRequest(transaction: locals[0])
        )
        _ = try await node!.service.submitNetworkTransaction(peer)
        for local in locals.dropFirst() {
            _ = try await node!.service.submitTransaction(
                SubmitTransactionRequest(transaction: local)
            )
        }
        let localRoots = try locals.map(Self.root)
        let peerRoot = try Self.root(peer)
        let before = try node!.ledger.counts()
        for root in localRoots + [peerRoot] {
            XCTAssertEqual(before.live[root], 1, root)
        }

        await node!.service.shutdown()
        let (directory, configuration) = (node!.directory, node!.configuration)
        node = nil
        let reopened = try await MempoolNode.open(
            test: self,
            directory: directory,
            configuration: configuration
        )
        let cleared = try reopened.ledger.counts()
        XCTAssertTrue(cleared.live.isEmpty, "startup left \(cleared.live)")
        for root in localRoots {
            XCTAssertEqual(cleared.durable[root], 1, root)
        }

        try await reopened.service.restoreLocalTransactions()
        let restored = await reopened.service.transactionInventoryRoots()
        XCTAssertEqual(Set(restored), Set(localRoots))
        let after = try reopened.ledger.counts()
        XCTAssertEqual(after.live, Dictionary(uniqueKeysWithValues: localRoots.map { ($0, 1) }))
        XCTAssertEqual(after.durable, Dictionary(uniqueKeysWithValues: localRoots.map { ($0, 1) }))
    }

    // MARK: - NODE-MEMPOOL-001.j

    /// Peer submissions stay serveable while pooled: after unpinned content is
    /// evicted with no grace, the network's content source still serves each
    /// pooled peer root as its whole Volume — every entry of the Volume the
    /// transaction encodes to, byte for byte — and the service still reads it.
    /// The replaced peer root is gone, which proves the eviction ran.
    /// Establishes: NODE-MEMPOOL-001.j
    func testPooledPeerSubmissionsStayServeableAfterEviction() async throws {
        let node = try await MempoolNode.open(test: self)
        let replacedKey = CryptoUtils.generateKeyPair()
        let replacedAddress = CryptoUtils.createAddress(from: replacedKey.publicKey)
        func queued(fee: Int64) throws -> Transaction {
            try signedTransaction(
                key: replacedKey,
                accountActions: [AccountAction(owner: replacedAddress, delta: -fee)],
                nonce: 1
            )
        }
        let replaced = try queued(fee: 1)
        let peers = [
            try signedTransaction(key: CryptoUtils.generateKeyPair()),
            try queued(fee: 2),
            try signedTransaction(key: CryptoUtils.generateKeyPair()),
        ]
        _ = try await node.service.submitNetworkTransaction(peers[0])
        _ = try await node.service.submitNetworkTransaction(replaced)
        for peer in peers.dropFirst() {
            let inserted = try await node.service.submitNetworkTransaction(peer)
            XCTAssertTrue(inserted)
        }
        let peerRoots = try peers.map(Self.root)
        let pooled = await node.service.transactionInventoryRoots()
        XCTAssertEqual(Set(pooled), Set(peerRoots))

        let broker = try DiskBroker(path: node.volumesPath)
        _ = try await broker.evictUnpinned(graceSeconds: 0)

        let source = ChainProcessIvyContentSource(process: node.process)
        let replacedServed = await source.volume(
            rootCID: try Self.root(replaced),
            maxDataBytes: .max
        )
        XCTAssertTrue(replacedServed.isEmpty, "eviction did not run")
        for (index, root) in peerRoots.enumerated() {
            let reference = MemoryBroker()
            try await VolumeImpl<Transaction>(node: peers[index]).store(storer: reference)
            let stored = await reference.fetchVolumeLocal(root: root)
            let expected = try XCTUnwrap(stored)
            let served = await source.volume(rootCID: root, maxDataBytes: .max)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: served.map { ($0.cid, $0.data) }),
                expected.entries,
                "pooled peer submission \(index) is no longer served whole"
            )
            let read = await node.service.transaction(cid: root)
            XCTAssertNotNil(read, "pooled peer submission \(index) cannot be read")
        }
    }

    static func root(_ transaction: Transaction) throws -> String {
        try VolumeImpl<Transaction>(node: transaction).rawCID
    }
}

// MARK: - Model

enum ModelOperation: String, CaseIterable, CustomStringConvertible {
    case addLocal, addPeer, cancelledAdmission, replace, evict, include
    case invalidate, reorg, restore, failedReconcile, promote

    var description: String { rawValue }
}

/// What the pool must hold, derived from the operations alone.
struct PoolModel {
    enum Kind {
        /// Nonce 0 of a funded key paying `fee`: ready, ranked by fee.
        case funded(key: Int, fee: Int64)
        /// Nonce 0 of a fresh key, no actions: ready, fee zero. Only the
        /// unlock an invalidation mines (and a reorg may return) is plain.
        case plain(key: KeyPair)
        /// Nonce 1 of a fresh unfunded key debiting `fee`: future. Its fee is
        /// declared, not funded; it becomes invalid once nonce 0 lands.
        case future(key: KeyPair, fee: Int64)

        var isReady: Bool {
            if case .future = self { return false }
            return true
        }
    }

    typealias KeyPair = (privateKey: String, publicKey: String)

    struct Entry {
        let root: String
        let transaction: Transaction
        let kind: Kind
    }

    struct Inclusion {
        let parent: Block
        let roots: [String]
    }

    let capacity: Int
    var fundedKeys: [KeyPair] = []
    var nextFundedKey = 0
    /// Every root the run created, in creation order.
    var entries: [Entry] = []
    var pooled: [String] = []
    var local = Set<String>()
    /// Every fee a funded (ready) entry of this run has bid, so none repeats:
    /// the pool breaks equal fees by arrival time and CID, which no model
    /// can predict.
    var usedFees = Set<Int64>()
    /// The tip's own block, while it is one this run included transactions
    /// in and nothing has built on it.
    var lastInclusion: Inclusion?

    init(capacity: Int) { self.capacity = capacity }

    func entry(_ root: String) -> Entry {
        entries.first { $0.root == root }!
    }

    var pooledEntries: [Entry] { pooled.map(entry) }

    func applicable() -> [ModelOperation] {
        var operations: [ModelOperation] = [
            .restore, .failedReconcile, .cancelledAdmission,
        ]
        let hasRoom = pooled.count < capacity
        if hasRoom { operations += [.addLocal, .addPeer] }
        if pooled.count == capacity, nextFundedKey < fundedKeys.count,
           evictionVictim() != nil {
            operations.append(.evict)
        }
        if pooledEntries.contains(where: { replacementFee(for: $0.kind) != nil }) {
            operations.append(.replace)
        }
        if pooledEntries.contains(where: \.kind.isReady) {
            operations.append(.include)
        }
        if hasRoom, pooledEntries.contains(where: { !$0.kind.isReady }) {
            operations.append(.invalidate)
        }
        if let lastInclusion,
           pooled.count + lastInclusion.roots.count <= capacity {
            operations.append(.reorg)
        }
        if pooled.contains(where: { !local.contains($0) }) {
            operations.append(.promote)
        }
        return operations
    }

    /// The one entry a bid of `evictionBid` must shed from a full pool, when
    /// the pool's order names exactly one. Ready outranks non-ready, so the
    /// victim is the non-ready entry when exactly one is pooled; with none,
    /// it is the ready entry with the strictly lowest fee. Among several
    /// non-ready entries, or equal fees, the pool orders by arrival time and
    /// CID, so no eviction is drawn.
    func evictionVictim() -> String? {
        let queued = pooledEntries.filter { !$0.kind.isReady }
        if queued.count == 1 { return queued[0].root }
        guard queued.isEmpty else { return nil }
        let ranked = pooledEntries.sorted { Self.fee(of: $0.kind) < Self.fee(of: $1.kind) }
        guard let lowest = ranked.first,
              Self.fee(of: lowest.kind) < PoolModel.evictionBid,
              ranked.count == 1
                || Self.fee(of: ranked[1].kind) > Self.fee(of: lowest.kind)
        else { return nil }
        return lowest.root
    }

    /// The smallest strictly higher bid the slot can still pay, if any.
    func replacementFee(for kind: Kind) -> Int64? {
        switch kind {
        case .funded(_, let fee):
            // An eviction bid (the whole balance) cannot be outbid.
            fee + 1 >= PoolModel.evictionBid ? nil
                : ((fee + 1)..<PoolModel.evictionBid).first { !usedFees.contains($0) }
        case .future(_, let fee): fee + 1
        case .plain: nil
        }
    }

    /// An unused funded fee: `drawn` if free, else the next free one above it,
    /// wrapping below `evictionBid`.
    mutating func claimFee(_ drawn: Int64, above floor: Int64 = 0) -> Int64 {
        let span = PoolModel.evictionBid - 1 - floor
        var fee = drawn
        for _ in 0..<span where usedFees.contains(fee) {
            fee = fee >= PoolModel.evictionBid - 1 ? floor + 1 : fee + 1
        }
        precondition(!usedFees.contains(fee), "funded fees exhausted")
        usedFees.insert(fee)
        return fee
    }

    static func fee(of kind: Kind) -> Int64 {
        switch kind {
        case .funded(_, let fee), .future(_, let fee): fee
        case .plain: 0
        }
    }

    static let fundedBalance: Int64 = 1_000
    /// The eviction bid: the whole funded balance, above every other funded
    /// fee (those stay below it), so it outranks any ready entry but another
    /// eviction bid.
    static let evictionBid: Int64 = fundedBalance
}

/// One node — process, service, and a reader over its pin table — driven only
/// through production entry points.
struct MempoolNode {
    let directory: URL
    let configuration: NodeConfiguration
    let process: ChainProcess
    let service: ChainService
    let ledger: PinLedger
    let mempoolMaxCount: Int

    var volumesPath: String {
        directory.appendingPathComponent("volumes.db").path
    }

    static func open(
        test: XCTestCase,
        mempoolMaxCount: Int = 10_000,
        executionWalkRetryInterval: Duration = .seconds(4)
    ) async throws -> MempoolNode {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-mempool-retention-\(UUID().uuidString)")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "6d", count: 32)
        )
        return try await open(
            test: test,
            directory: directory,
            configuration: configuration,
            mempoolMaxCount: mempoolMaxCount,
            executionWalkRetryInterval: executionWalkRetryInterval
        )
    }

    /// Opens (or, after a restart, reopens) the node stored in `directory`.
    static func open(
        test: XCTestCase,
        directory: URL,
        configuration: NodeConfiguration,
        mempoolMaxCount: Int = 10_000,
        executionWalkRetryInterval: Duration = .seconds(4)
    ) async throws -> MempoolNode {
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            network: ClosureNetworkInterface(
                childCandidateProvider: { _ in [] },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in }
            ),
            executionWalkRetryInterval: executionWalkRetryInterval,
            mempoolMaxCount: mempoolMaxCount
        )
        let scope = [configuration.nexusGenesisCID, configuration.address.key]
            .joined(separator: ":")
        return MempoolNode(
            directory: directory,
            configuration: configuration,
            process: process,
            service: service,
            ledger: try PinLedger(
                path: directory.appendingPathComponent("volumes.db").path,
                live: scope + ":live-mempool",
                durable: scope + ":durable-mempool"
            ),
            mempoolMaxCount: mempoolMaxCount
        )
    }

    /// Mines the pool into a block through the template and submit-work
    /// entry points, crediting `rewards` from a fresh reward signer.
    @discardableResult
    func mine(rewards: [AccountAction] = []) async throws -> Block {
        var request = MiningTemplateRequest()
        if !rewards.isEmpty {
            request = MiningTemplateRequest(rewards: [MiningReward(
                chainPath: ["Nexus"],
                transaction: try signedTransaction(
                    key: CryptoUtils.generateKeyPair(),
                    accountActions: rewards
                )
            )])
        }
        let template = try await service.miningTemplate(request)
        let nonce = solvedNonce(for: template)
        let response = try await service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: nonce
        ))
        guard response.accepted else {
            throw ModelError("work was not accepted: \(response.disposition)")
        }
        return template.block.replacingNonce(nonce)
    }

    /// Funds `count` fresh keys with `PoolModel.fundedBalance` each.
    func fundKeys(count: Int) async throws -> [PoolModel.KeyPair] {
        let keys = (0..<count).map { _ in CryptoUtils.generateKeyPair() }
        try await mine(rewards: keys.map {
            AccountAction(
                owner: CryptoUtils.createAddress(from: $0.publicKey),
                delta: PoolModel.fundedBalance
            )
        })
        return keys
    }

    func apply(
        _ operation: ModelOperation,
        to model: inout PoolModel,
        using generator: inout SplitMix64,
        context: String
    ) async throws {
        switch operation {
        case .addLocal, .addPeer:
            let entry = try newEntry(model: &model, using: &generator)
            try await submit(entry.transaction, local: operation == .addLocal)
            model.entries.append(entry)
            model.pooled.append(entry.root)
            if operation == .addLocal { model.local.insert(entry.root) }

        case .cancelledAdmission:
            // The request's task is cancelled (its client went away) once the
            // pool has taken the entry, possibly shedding another for it: the
            // admission fails and the pool, the journal and both owners' pins
            // must be exactly as before.
            let entry = try newEntry(model: &model, using: &generator)
            let local = Bool.random(using: &generator)
            let transaction = entry.transaction
            let task = Task { [service] in
                withUnsafeCurrentTask { $0?.cancel() }
                if local {
                    _ = try await service.submitTransaction(
                        SubmitTransactionRequest(transaction: transaction)
                    )
                } else {
                    _ = try await service.submitNetworkTransaction(transaction)
                }
            }
            if (try? await task.value) != nil {
                throw ModelError("a cancelled admission was admitted")
            }
            model.entries.append(entry)

        case .replace:
            let candidates = model.pooledEntries.filter {
                model.replacementFee(for: $0.kind) != nil
            }
            let old = candidates.randomElement(using: &generator)!
            let minimum = model.replacementFee(for: old.kind)!
            let replacement: PoolModel.Entry
            switch old.kind {
            case .funded(let key, let oldFee):
                let drawn = Int64.random(
                    in: minimum...min(minimum + 50, PoolModel.evictionBid - 1),
                    using: &generator
                )
                let fee = model.claimFee(drawn, above: oldFee)
                replacement = try fundedEntry(model.fundedKeys[key], index: key, fee: fee)
            case .future(let key, _):
                let fee = Int64.random(in: minimum...(minimum + 50), using: &generator)
                replacement = try futureEntry(key, fee: fee)
            case .plain:
                throw ModelError("a plain entry has no replacement bid")
            }
            let local = Bool.random(using: &generator)
            try await submit(replacement.transaction, local: local)
            model.entries.append(replacement)
            model.pooled.removeAll { $0 == old.root }
            model.local.remove(old.root)
            model.pooled.append(replacement.root)
            if local { model.local.insert(replacement.root) }

        case .evict:
            // A funded bid above every pooled fee: capacity sheds exactly the
            // entry the model names (see `evictionVictim`).
            let victim = model.evictionVictim()!
            let entry = try fundedEntry(
                model.fundedKeys[model.nextFundedKey],
                index: model.nextFundedKey,
                fee: PoolModel.evictionBid
            )
            model.nextFundedKey += 1
            let local = Bool.random(using: &generator)
            let before = Set(model.pooled)
            try await submit(entry.transaction, local: local)
            let after = Set(await service.transactionInventoryRoots())
            let evicted = before.subtracting(after)
            guard evicted == [victim], after.contains(entry.root) else {
                throw ModelError(
                    "eviction shed \(evicted.sorted()) (expected \(victim)); "
                        + "pool now \(after.sorted())"
                )
            }
            model.entries.append(entry)
            model.pooled.removeAll { $0 == victim }
            model.local.remove(victim)
            model.pooled.append(entry.root)
            if local { model.local.insert(entry.root) }

        case .include:
            try await include(model: &model)

        case .invalidate:
            // Nonce 0 of a queued entry's key lands; the queued entry, which
            // debits a balance that key never had, becomes invalid on the new
            // tip and must leave the pool.
            let queued = model.pooledEntries.filter { !$0.kind.isReady }
                .randomElement(using: &generator)!
            guard case .future(let key, _) = queued.kind else {
                throw ModelError("expected a queued entry")
            }
            let unlock = try signedTransaction(key: key, nonce: 0)
            let entry = PoolModel.Entry(
                root: try MempoolRetentionTests.root(unlock),
                transaction: unlock,
                kind: .plain(key: key)
            )
            try await submit(entry.transaction, local: true)
            model.entries.append(entry)
            model.pooled.append(entry.root)
            model.local.insert(entry.root)
            try await include(model: &model)
            model.pooled.removeAll { $0 == queued.root }
            model.local.remove(queued.root)

        case .reorg:
            // Two blocks on the included block's parent outweigh it: the
            // network import path reorganises, and reconciliation re-adds
            // every transaction the removed block carried, each with one live
            // pin (the claim).
            //
            // KNOWN DEFECT #227 (NODE-MEMPOOL-001.o): the journal entry left
            // with the inclusion and reconciliation does not restore it, so a
            // local transaction comes back as NON-local. The model encodes
            // that current behaviour below (the re-added roots are not put
            // back into `model.local`); a fix for #227 must flip this rule
            // to re-mark every root that was local when it was included.
            let inclusion = model.lastInclusion!
            var previous = inclusion.parent
            for offset in 1...2 {
                let unmined = try await BlockBuilder.buildBlock(
                    previous: previous,
                    timestamp: inclusion.parent.timestamp + Int64(offset),
                    fetcher: process
                )
                let block = unmined.replacingNonce(firstNonce(of: unmined) {
                    $0 <= unmined.target
                })
                let outcome = try await service.importNetworkCandidate(
                    BlockHeader(node: block),
                    authenticatedChildPackage: nil,
                    preparingChildDirectories: [],
                    contentSource: FetcherContentSource(process)
                )
                guard outcome.decision.isAccepted else {
                    throw ModelError("fork block \(offset) was refused: \(outcome.decision)")
                }
                await outcome.canonicalCommitReceipt?.wait()
                previous = block
            }
            let tip = try await process.validatedTipBlock()
            guard try BlockHeader(node: tip).rawCID == BlockHeader(node: previous).rawCID else {
                throw ModelError("the heavier fork did not become the tip")
            }
            model.pooled += inclusion.roots
            model.lastInclusion = nil

        case .restore:
            try await service.restoreLocalTransactions()
            model.pooled = model.pooled.filter { model.local.contains($0) }

        case .failedReconcile:
            // A canonical commit naming a block this node cannot resolve fails
            // reconciliation: the pool is reset and every live pin released;
            // the journal and its durable pins are untouched.
            let missing = try HeaderImpl<PublicKey>(
                node: PublicKey(key: "absent-\(UUID().uuidString)")
            ).rawCID
            let receipt = await service.enqueueCanonicalCommit(ChainCommit(
                tipHash: missing,
                canonicalBlocksAdded: [missing: 1],
                canonicalBlocksRemoved: []
            ))
            await receipt.wait()
            let counts = try ledger.counts()
            let locals = model.pooled.filter { model.local.contains($0) }
            guard counts.live.isEmpty,
                  counts.durable == Dictionary(uniqueKeysWithValues: locals.map { ($0, 1) })
            else {
                throw ModelError(
                    "after the reset: live \(counts.live), durable \(counts.durable), "
                        + "journaled \(locals.sorted())"
                )
            }
            // The next pool read restores the journal.
            model.pooled = locals

        case .promote:
            let peer = model.pooled.filter { !model.local.contains($0) }
                .randomElement(using: &generator)!
            try await submit(model.entry(peer).transaction, local: true)
            model.local.insert(peer)
        }
    }

    private func include(model: inout PoolModel) async throws {
        let parent = try await process.validatedTipBlock()
        let ready = model.pooledEntries.filter(\.kind.isReady).map(\.root)
        let block = try await mine()
        let carried = Set(try XCTUnwrap(block.transactions.node)
            .allKeysAndValues().values.map(\.rawCID))
        guard carried == Set(ready) else {
            throw ModelError(
                "the block carried \(carried.sorted()), expected the ready "
                    + "entries \(ready.sorted())"
            )
        }
        model.pooled.removeAll { carried.contains($0) }
        model.local.subtract(carried)
        model.lastInclusion = PoolModel.Inclusion(parent: parent, roots: ready)
    }

    private func submit(_ transaction: Transaction, local: Bool) async throws {
        if local {
            _ = try await service.submitTransaction(
                SubmitTransactionRequest(transaction: transaction)
            )
        } else {
            _ = try await service.submitNetworkTransaction(transaction)
        }
    }

    private func newEntry(
        model: inout PoolModel,
        using generator: inout SplitMix64
    ) throws -> PoolModel.Entry {
        let drawn = Int64.random(in: 1...500, using: &generator)
        if Bool.random(using: &generator), model.nextFundedKey < model.fundedKeys.count {
            let index = model.nextFundedKey
            model.nextFundedKey += 1
            return try fundedEntry(
                model.fundedKeys[index],
                index: index,
                fee: model.claimFee(drawn)
            )
        }
        return try futureEntry(CryptoUtils.generateKeyPair(), fee: drawn)
    }

    private func fundedEntry(
        _ key: PoolModel.KeyPair,
        index: Int,
        fee: Int64
    ) throws -> PoolModel.Entry {
        let transaction = try signedTransaction(
            key: key,
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: -fee
            )],
            nonce: 0
        )
        return PoolModel.Entry(
            root: try MempoolRetentionTests.root(transaction),
            transaction: transaction,
            kind: .funded(key: index, fee: fee)
        )
    }

    private func futureEntry(
        _ key: PoolModel.KeyPair,
        fee: Int64
    ) throws -> PoolModel.Entry {
        let transaction = try signedTransaction(
            key: key,
            accountActions: [AccountAction(
                owner: CryptoUtils.createAddress(from: key.publicKey),
                delta: -fee
            )],
            nonce: 1
        )
        return PoolModel.Entry(
            root: try MempoolRetentionTests.root(transaction),
            transaction: transaction,
            kind: .future(key: key, fee: fee)
        )
    }

    /// The pool, the journal and both owners' pins against the model.
    func assertMatches(_ model: PoolModel, context: String) async throws {
        let pooled = Set(model.pooled)
        let local = pooled.intersection(model.local)
        let actual = Set(await service.transactionInventoryRoots())
        guard actual == pooled else {
            throw ModelError(
                "pool holds \(actual.sorted()), model \(pooled.sorted())"
            )
        }
        let journal = Set(try await process.localTransactionTimestamps().keys)
        guard journal == local else {
            throw ModelError(
                "journal holds \(journal.sorted()), model \(local.sorted())"
            )
        }
        let counts = try ledger.counts()
        let roots = Set(model.entries.map(\.root))
            .union(counts.live.keys).union(counts.durable.keys)
        for root in roots.sorted() {
            let live = counts.live[root] ?? 0
            let durable = counts.durable[root] ?? 0
            let expectedLive = pooled.contains(root) ? 1 : 0
            let expectedDurable = local.contains(root) ? 1 : 0
            guard live == expectedLive, durable == expectedDurable else {
                throw ModelError(
                    "root \(root): live \(live) (expected \(expectedLive)), "
                        + "durable \(durable) (expected \(expectedDurable)); "
                        + "pooled \(pooled.contains(root)), local \(local.contains(root))"
                )
            }
        }
    }
}

struct ModelError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Reads the two mempool owners' pin counts from `volume_pins`.
struct PinLedger {
    let database: NodeSQLite
    let live: String
    let durable: String

    init(path: String, live: String, durable: String) throws {
        database = try NodeSQLite(path: path)
        self.live = live
        self.durable = durable
    }

    func counts() throws -> (live: [String: Int64], durable: [String: Int64]) {
        var live: [String: Int64] = [:]
        var durable: [String: Int64] = [:]
        for row in try database.query(
            "SELECT root, owner, count FROM volume_pins WHERE owner IN (?1, ?2)",
            params: [.text(self.live), .text(self.durable)]
        ) {
            guard let root = row["root"]?.textValue,
                  let owner = row["owner"]?.textValue,
                  let count = row["count"]?.intValue else { continue }
            if owner == self.live { live[root] = count } else { durable[root] = count }
        }
        return (live, durable)
    }
}
