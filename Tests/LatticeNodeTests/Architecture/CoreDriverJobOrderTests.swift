import Foundation
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeNode
import cashew

/// A tip move's read of its blocks against the driver's job ordering: one
/// worker, execution first, mining jobs in the order the core emitted them,
/// each built by `CoreDriver.miningJob` and skipped at dequeue when its
/// epoch moved, over a real `ChainProcess` and Lattice preflight.
final class CoreDriverJobOrderTests: NetworkTrustTestCase {
    private struct Harness {
        var host: HostCore
        let process: ChainProcess
        let headers: CoreHeaderStore
        /// The driver's mining FIFO.
        var jobs: [CoreDriver.CoreJob] = []
        /// Every reply and announce the mining effects gave.
        var replies: [MiningEffect] = []

        var mining: Mining { host.levels[host.rootPath]!.mining }
        var actOnTip: String { host.levels[host.rootPath]!.snapshot.actOnTip }

        /// Step `event` and execute its effects as the driver does: persist
        /// first, execution at once (bodies are held locally), mining jobs
        /// queued.
        mutating func step(_ event: HostEvent) async throws {
            var pending = [event]
            while !pending.isEmpty {
                let effects = host.step(pending.removeFirst(), now: CoreDriver.now())
                for case .persist(let batch) in effects {
                    for (_, level) in batch.levels {
                        try await process.persistCoreBatch(level, headers: headers)
                    }
                }
                for effect in effects {
                    switch effect {
                    case .connect(let path, let job, let facts):
                        pending.append(.level(path, .connected(await ChainTree.connect(
                            job, fetcher: process.localFetcher, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: CoreDriver.now())
                        ))))
                    case .level(let path, .fetchBody(let cid)):
                        pending.append(.level(path, .bodyFetched(cid: cid)))
                    case .level(let path, .mining(let mining)):
                        switch mining {
                        case .preflight, .buildTemplate, .returnTransactions:
                            jobs.append(CoreDriver.miningJob(
                                mining, at: path,
                                level: CoreDriver.jobLevel(host.levels[path]!.tree),
                                process: process
                            ))
                        case .poolChanged:
                            break
                        default:
                            replies.append(mining)
                        }
                    default:
                        break
                    }
                }
            }
        }

        /// Run the queued mining job at `index` as the worker does.
        mutating func runJob(at index: Int = 0) async throws {
            let job = jobs.remove(at: index)
            guard job.isCurrent(in: host) else { return }
            for event in await job.run() { try await step(event) }
        }

        mutating func runJobs() async throws {
            while !jobs.isEmpty { try await runJob() }
        }

        func admitted(_ replyID: UInt64) -> Bool {
            replies.contains { if case .transactionAdmitted(replyID, _, _, _) = $0 { true } else { false } }
        }

        func refused(_ replyID: UInt64) -> Bool {
            replies.contains { if case .transactionRefused(replyID, _) = $0 { true } else { false } }
        }
    }

    private func harness(keyByte: UInt8) async throws -> Harness {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-core-job-order-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        // The submit waits through every move here; none is refused as
        // retriable for waiting too long.
        var config = CoreConfig()
        config.mining.maxReissues = 16
        return Harness(
            host: try await CoreDriver.boot(process: process, configuration: configuration, coreConfig: config),
            process: process,
            headers: try CoreHeaderStore(directory: storage)
        )
    }

    private func transaction() throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
    }

    /// Mine a block on `previous` carrying `transactions`, store its content
    /// and weigh it as this host's grind; its execution runs at once.
    @discardableResult
    private func mine(
        _ harness: inout Harness,
        on previous: Block,
        _ transactions: [Transaction] = [],
        timestamp: Int64
    ) async throws -> Block {
        var nonce: UInt64 = 0
        var block: Block
        repeat {
            block = try await BlockBuilder.buildBlock(
                previous: previous, transactions: transactions,
                timestamp: timestamp, nonce: nonce, fetcher: harness.process
            )
            nonce += 1
        } while block.proofOfWorkHash() > block.target
        let children = try await harness.process.storeMinedBlock(block)
        try await harness.step(.mined(MinedGrind(root: block, rootChildren: children, carried: [])))
        return block
    }

    /// The finding's order: the move issues its read, and a verdict on the
    /// new tip (which would refuse the confirmed transaction) never comes
    /// before it.
    func testASubmitTheEnteredBlockConfirmsIsAdmittedThroughTheDriverJobOrder() async throws {
        var harness = try await harness(keyByte: 0x41)
        let clock = TestBlockClock()
        let genesis = try await harness.process.canonicalTipBlock()
        let tx = try transaction()
        // The submit waits on its verdict while the block carrying it lands.
        try await harness.step(.level(harness.host.rootPath, .mining(
            .transactionReceived(tx, origin: .local(replyID: 1))
        )))
        let block = try await mine(&harness, on: genesis, [tx], timestamp: clock.next())
        XCTAssertEqual(harness.actOnTip, try BlockHeader(node: block).rawCID)

        try await harness.runJobs()
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        XCTAssertFalse(harness.refused(1), "\(harness.replies)")
        XCTAssertEqual(harness.mining.pendingAdmissions, 0)
        XCTAssertFalse(harness.mining.mempool.contains(try Mempool.cid(of: tx)))
    }

    /// Move 1 enters B; move 2 leaves it. The second read answers first and
    /// returns B's transaction; the first read's late confirmation is stale
    /// and undoes nothing.
    func testALateConfirmationNeverUndoesAReorgReturn() async throws {
        var harness = try await harness(keyByte: 0x42)
        let clock = TestBlockClock()
        let genesis = try await harness.process.canonicalTipBlock()
        let tx = try transaction()
        let cid = try Mempool.cid(of: tx)
        try await harness.step(.level(harness.host.rootPath, .mining(
            .transactionReceived(tx, origin: .local(replyID: 1))
        )))
        let b = try await mine(&harness, on: genesis, [tx], timestamp: clock.next())
        let bCID = try BlockHeader(node: b).rawCID
        XCTAssertEqual(harness.actOnTip, bCID)
        // The read of B is the last job the move queued; hold it back.
        let firstRead = harness.jobs.removeLast()

        // A heavier empty branch from genesis.
        let c1 = try await mine(&harness, on: genesis, timestamp: clock.next())
        let c2 = try await mine(&harness, on: c1, timestamp: clock.next())
        XCTAssertEqual(harness.actOnTip, try BlockHeader(node: c2).rawCID)
        XCTAssertNotEqual(harness.actOnTip, bCID)

        // Every later job first, then the read of B.
        try await harness.runJobs()
        XCTAssertTrue(harness.mining.mempool.contains(cid), "B's transaction is back in the pool")
        harness.jobs.append(firstRead)
        try await harness.runJobs()
        XCTAssertTrue(harness.mining.mempool.contains(cid), "B's transaction is back in the pool")
        // Admitted by the pool on the new tip, never confirmed by B.
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        XCTAssertEqual(harness.mining.pendingAdmissions, 0)
    }
}
