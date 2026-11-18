import Foundation
import Lattice
@testable import LatticeNodeCore
import XCTest
@testable import LatticeNode
import cashew

/// A tip move's read of its blocks against the runtime's job ordering: one
/// worker, mining jobs in the order the core emitted them, each built by
/// `NodeRuntime.miningJob` and, a recheck, skipped at dequeue when its tip
/// is not the mining tip, over a real `NodeStorage` and Lattice preflight;
/// and the queues' order (`JobQueues`).
final class NodeRuntimeJobOrderTests: XCTestCase {
    private struct Harness {
        var host: NodeCore
        let storage: NodeStorage
        /// The runtime's mining FIFO.
        var jobs: [NodeRuntime.RuntimeJob] = []
        /// Every reply and announce the mining effects gave.
        var replies: [MiningEffect] = []
        /// Every `readTransactions` the core asked.
        var reads: [[String]] = []
        /// Every mining effect queued as a job.
        var spawned: [MiningEffect] = []

        var mining: MiningState { host.levels[host.rootPath]!.mining }
        var actOnTip: String { host.levels[host.rootPath]!.snapshot.actOnTip }

        /// The act-on tip's block, read from content.
        func tipBlock() async throws -> Block {
            let cid = actOnTip
            guard let data = await storage.content([cid])[cid], let block = Block(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return block
        }

        /// Step `event` and execute its effects as the runtime does: persist
        /// first, execution at once (bodies are held locally), mining jobs
        /// queued.
        mutating func step(_ event: NodeEvent) async throws {
            var pending = [event]
            while !pending.isEmpty {
                let effects = host.step(pending.removeFirst(), now: NodeRuntime.now())
                for case .persist(let batch) in effects {
                    try await storage.persistNodeBatch(batch, logID: host.logID)
                }
                for effect in effects {
                    switch effect {
                    case .connect(let path, let job):
                        // The job reads the levels as this step left them.
                        let levels = host.levels
                        pending += await NodeRuntime.connectJob(
                            job, at: path, levels: LiveLevels { $0(levels) }, storage: storage
                        ).run()
                    case .level(let path, .readTransactions(let blocks)):
                        reads.append(blocks)
                        pending += await NodeRuntime.readJob(blocks, at: path, storage: storage).run()
                    case .level(let path, .fetchBody(let cid)):
                        pending.append(.level(path, .bodyFetched(cid: cid)))
                    case .level(let path, .mining(let mining)):
                        switch mining {
                        case .preflight, .buildTemplate, .returnTransactions:
                            spawned.append(mining)
                            jobs.append(NodeRuntime.miningJob(
                                mining, at: path,
                                basis: NodeRuntime.miningBasis(mining, tree: host.levels[path]!.tree),
                                storage: storage
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

    private func harness(keyByte: UInt8, bodyWindow: Int = 64) async throws -> Harness {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-core-job-order-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let config = ChainCoreConfig(bodyWindow: bodyWindow)
        return Harness(
            host: try await NodeRuntime.boot(
                storage: storage, configuration: configuration, coreConfig: config
            ),
            storage: storage
        )
    }

    private func transaction(nonce: UInt64 = 0) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: nonce, chainPath: ["Nexus"]
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
                timestamp: timestamp, nonce: nonce, fetcher: harness.storage
            )
            nonce += 1
        } while block.proofOfWorkHash() > block.target
        let children = try await harness.storage.storeMinedBlock(block)
        try await harness.step(.mined(MinedGrind(root: block, rootChildren: children, carried: [])))
        return block
    }

    /// The finding's order: the move issues its read, and a verdict on the
    /// new tip (which would refuse the confirmed transaction) never comes
    /// before it.
    func testASubmitTheEnteredBlockConfirmsIsAdmittedThroughTheRuntimeJobOrder() async throws {
        var harness = try await harness(keyByte: 0x41)
        let clock = TestBlockClock()
        let genesis = try await harness.tipBlock()
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

    /// Two forward moves back to back, one worker: both blocks execute
    /// before any mining job runs, and the submit the first one carries is
    /// still admitted (each connect result names its transactions).
    func testTwoForwardMovesBackToBackConfirmTheWaitingSubmit() async throws {
        var harness = try await harness(keyByte: 0x43)
        let clock = TestBlockClock()
        let genesis = try await harness.tipBlock()
        let tx = try transaction()
        try await harness.step(.level(harness.host.rootPath, .mining(
            .transactionReceived(tx, origin: .local(replyID: 1))
        )))
        let b = try await mine(&harness, on: genesis, [tx], timestamp: clock.next())
        let c = try await mine(&harness, on: b, timestamp: clock.next())
        XCTAssertEqual(harness.actOnTip, try BlockHeader(node: c).rawCID)
        try await harness.runJobs()
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        XCTAssertFalse(harness.refused(1), "\(harness.replies)")
        XCTAssertTrue(harness.reads.isEmpty)
    }

    /// A reorg returns the transaction a left block carried to the pool.
    func testAReorgReturnsTheLeftBlocksTransaction() async throws {
        var harness = try await harness(keyByte: 0x42)
        let clock = TestBlockClock()
        let genesis = try await harness.tipBlock()
        let tx = try transaction()
        let cid = try Mempool.cid(of: tx)
        try await harness.step(.level(harness.host.rootPath, .mining(
            .transactionReceived(tx, origin: .local(replyID: 1))
        )))
        try await mine(&harness, on: genesis, [tx], timestamp: clock.next())
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        let c1 = try await mine(&harness, on: genesis, timestamp: clock.next())
        let c2 = try await mine(&harness, on: c1, timestamp: clock.next())
        XCTAssertEqual(harness.actOnTip, try BlockHeader(node: c2).rawCID)
        try await harness.runJobs()
        XCTAssertTrue(harness.mining.mempool.contains(cid), "the left block's transaction is back in the pool")
    }

    /// A reorg back onto a branch executed earlier: within the body window
    /// its blocks' transaction IDs are held, so it confirms in the move with
    /// no read; below it, the entered block is read first and the mempool
    /// follows once the read answers.
    func testAReorgOntoAnEarlierExecutedBranchConfirmsInsideAndOutsideTheWindow() async throws {
        for (window, sideLength) in [(64, 2), (1, 3)] {
            var harness = try await harness(keyByte: 0x44, bodyWindow: window)
            let clock = TestBlockClock()
            let genesis = try await harness.tipBlock()
            let tx = try transaction()
            let cid = try Mempool.cid(of: tx)
            let b1 = try await mine(&harness, on: genesis, [tx], timestamp: clock.next())
            let b1CID = try BlockHeader(node: b1).rawCID
            // A heavier side branch; B1's transaction returns to the pool.
            var side = genesis
            for _ in 0..<sideLength { side = try await mine(&harness, on: side, timestamp: clock.next()) }
            XCTAssertEqual(harness.actOnTip, try BlockHeader(node: side).rawCID)
            try await harness.runJobs()
            XCTAssertTrue(harness.mining.mempool.contains(cid), "window \(window)")
            // Back onto B1's branch, heavier again.
            var tip = b1
            for _ in 0..<sideLength { tip = try await mine(&harness, on: tip, timestamp: clock.next()) }
            XCTAssertEqual(harness.actOnTip, try BlockHeader(node: tip).rawCID, "window \(window)")
            XCTAssertEqual(harness.mining.tipCID, harness.actOnTip, "window \(window)")
            XCTAssertFalse(harness.mining.mempool.contains(cid), "B1 confirms it again: window \(window)")
            if window == 64 {
                XCTAssertTrue(harness.reads.isEmpty, "held within the window: \(harness.reads)")
            } else {
                XCTAssertTrue(harness.reads.contains { $0.contains(b1CID) }, "read below the window: \(harness.reads)")
            }
            try await harness.runJobs()
            XCTAssertFalse(harness.mining.mempool.contains(cid), "window \(window)")
        }
    }

    /// A job's basis, read from the live tree when it is spawned, gives what
    /// the per-epoch copy of the tree it replaces gave: the same preflight
    /// verdict, and the same difficulty anchor for the template.
    func testAJobsBasisReadsWhatACopyOfTheTreeRead() async throws {
        var harness = try await harness(keyByte: 0x45)
        let clock = TestBlockClock()
        let root = harness.host.rootPath
        var tip = try await harness.tipBlock()
        for _ in 0..<3 { tip = try await mine(&harness, on: tip, timestamp: clock.next()) }
        try await harness.runJobs()
        harness.spawned = []
        let ready = try transaction()
        // Nonce 1 is ahead of the signer's next nonce.
        let future = try transaction(nonce: 1)
        for (replyID, tx) in [ready, future].enumerated() {
            try await harness.step(.level(root, .mining(.transactionReceived(tx, origin: .local(replyID: UInt64(replyID))))))
        }
        try await harness.step(.level(root, .mining(.templateRequested(replyID: 9, TemplateRequest(rewardRecipient: nil)))))

        let tree = harness.host.levels[root]!.tree
        let copy = try XCTUnwrap(ChainLevel(tree: tree))
        let fetcher = harness.storage.workFetcher
        var dispositions: [TransactionPreflightDisposition] = []
        var anchors = 0
        for effect in harness.spawned {
            switch effect {
            case .preflight(let job):
                let basis = try XCTUnwrap(NodeRuntime.miningBasis(effect, tree: tree))
                let read = await TransactionPreflight.classify(
                    job.transaction, tipCID: job.tipCID, snapshot: basis.snapshot, chainPath: root, fetcher: fetcher
                )
                let copied = await copy.preflightTransaction(job.transaction, at: job.tipCID, fetcher: fetcher)
                XCTAssertEqual(read, copied)
                dispositions.append(read.disposition)
            case .buildTemplate(let job):
                let basis = try XCTUnwrap(NodeRuntime.miningBasis(effect, tree: tree))
                let copied = await copy.chain.difficultyAnchor(forBlockHash: job.tipCID)
                XCTAssertNotNil(copied)
                XCTAssertEqual(basis.anchor, copied)
                anchors += 1
            default:
                break
            }
        }
        XCTAssertEqual(Set(dispositions), [.ready, .future])
        XCTAssertEqual(anchors, 1)
    }

    /// A recheck queued on one tip is discarded at the runtime's dequeue
    /// (`JobQueues.next`, what `startJobs` takes from) once the mining tip is
    /// another: it is never handed to a worker, and the current job behind
    /// it is. A template build is never discarded: it is answered on any tip.
    func testARecheckWhoseTipIsNotTheMiningTipIsDiscarded() async throws {
        var harness = try await harness(keyByte: 0x46)
        let clock = TestBlockClock()
        let root = harness.host.rootPath
        var tip = try await harness.tipBlock()
        try await harness.step(.level(root, .mining(.transactionReceived(try transaction(), origin: .local(replyID: 1)))))
        try await harness.runJobs()
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        tip = try await mine(&harness, on: tip, timestamp: clock.next())
        let stale = try XCTUnwrap(harness.jobs.last { $0.tipCID != nil })
        XCTAssertTrue(stale.isCurrent(in: harness.host))
        try await harness.step(.level(root, .mining(.templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)))))
        let build = try XCTUnwrap(harness.jobs.last)
        XCTAssertNil(build.tipCID, "a build runs on any tip")

        try await mine(&harness, on: tip, timestamp: clock.next())
        let current = harness.mining.tipCID
        XCTAssertNotEqual(stale.tipCID, current, "the tip moved")
        var queues = NodeRuntime.JobQueues()
        queues.append(stale)
        queues.append(NodeRuntime.RuntimeJob(path: root, tipCID: current) { [] })
        let next = queues.next(in: harness.host)
        XCTAssertEqual(next?.tipCID, current, "the stale job is skipped for the current one")
        XCTAssertTrue(queues.isEmpty, "the stale job is dropped")
        XCTAssertNil(queues.next(in: harness.host))
        XCTAssertTrue(build.isCurrent(in: harness.host))
    }

    /// A level's next block runs ahead of the proof checks queued before
    /// it. Taken first in, first out by one worker (a one-CPU host), the
    /// root's next block waited behind thousands of child proof checks while
    /// a node synced a tree of chains, and the root executed a block every
    /// few minutes. The checks keep their order behind it.
    func testALevelsNextBlockRunsAheadOfQueuedProofChecks() async throws {
        let harness = try await harness(keyByte: 0x47)
        var queues = NodeRuntime.JobQueues()
        for index in 0..<1_000 { queues.append(Self.job("check-\(index)", depth: 2)) }
        queues.append(Self.job("root-block", depth: 1, kind: .connect))
        var order: [String] = []
        while let next = queues.next(in: harness.host) { order.append(next.path.last ?? "") }
        XCTAssertEqual(order, ["root-block"] + (0..<1_000).map { "check-\($0)" })
    }

    /// No level goes ahead of another: while a shallower level keeps
    /// queueing work, its own next blocks among it, a deeper level's next
    /// block and other work still run in their turn.
    func testADeeperLevelsNextBlockRunsUnderSteadyShallowerWork() async throws {
        let harness = try await harness(keyByte: 0x48)
        var queues = NodeRuntime.JobQueues()
        queues.append(Self.job("grand-block", depth: 3, kind: .connect))
        queues.append(Self.job("grand-check", depth: 3))
        var ran: [String] = []
        for step in 0..<10 {
            // Each turn the root queues more work, a next block among it.
            queues.append(Self.job("root-check-\(step)", depth: 1))
            queues.append(Self.job("root-block-\(step)", depth: 1, kind: .connect))
            if let next = queues.next(in: harness.host) { ran.append(next.path.last ?? "") }
        }
        XCTAssertEqual(ran.first, "grand-block", "the grandchild's next block, queued first, runs first")
        XCTAssertEqual(Array(ran.dropFirst()), (0..<9).map { "root-block-\($0)" }, "then each next block in turn")
        XCTAssertEqual(ran.count, 10)
        XCTAssertEqual(queues.rest.first?.path.last, "grand-check", "the other work keeps its place, first in line")
    }

    /// The queues' rule: (A) what an RPC waits on, an awaited admission or a
    /// template build, then (B) connects, then (C) the rest, each first in,
    /// first out. A stale recheck is skipped; a peer's admission never goes
    /// ahead of a queued connect.
    func testJobsRunAnsweredThenConnectsThenTheRestEachInArrivalOrder() async throws {
        let harness = try await harness(keyByte: 0x4A)
        let tip = harness.mining.tipCID
        let ran = Ran()
        // Each job, as queued, runs only to say its name.
        func named(_ name: String, _ job: NodeRuntime.RuntimeJob) -> NodeRuntime.RuntimeJob {
            NodeRuntime.RuntimeJob(path: job.path, tipCID: job.tipCID, kind: job.kind) { await ran.add(name); return [] }
        }
        func preflight(_ name: String, awaited: Bool, checksPolicies: Bool = true, tip tipCID: String = tip) throws
            -> NodeRuntime.RuntimeJob {
            let job = PreflightJob(
                id: 0, cid: name, transaction: try transaction(), tipCID: tipCID, poolVersion: 0,
                checksPolicies: checksPolicies, awaited: awaited
            )
            return named(name, NodeRuntime.miningJob(
                .preflight(job), at: harness.host.rootPath, basis: nil, storage: harness.storage
            ))
        }
        func build(_ name: String) -> NodeRuntime.RuntimeJob {
            named(name, NodeRuntime.RuntimeJob(path: harness.host.rootPath, tipCID: nil, kind: .answered) { [] })
        }
        func other(_ name: String, kind: NodeRuntime.RuntimeJob.Kind = .other) -> NodeRuntime.RuntimeJob {
            named(name, Self.job(name, depth: 1, kind: kind))
        }
        var queues = NodeRuntime.JobQueues()
        queues.append(other("check-0"))
        queues.append(try preflight("peer-0", awaited: false))
        queues.append(other("connect-0", kind: .connect))
        queues.append(try preflight("recheck-0", awaited: false, checksPolicies: false))
        queues.append(try preflight("stale-recheck", awaited: false, checksPolicies: false, tip: "elsewhere"))
        queues.append(try preflight("submit-0", awaited: true))
        queues.append(other("connect-1", kind: .connect))
        queues.append(build("build-0"))
        queues.append(try preflight("submit-1", awaited: true))
        queues.append(other("read-0"))
        while let next = queues.next(in: harness.host) { _ = await next.run() }
        let order = await ran.names
        XCTAssertEqual(order, [
            "submit-0", "build-0", "submit-1",
            "connect-0", "connect-1",
            "check-0", "peer-0", "recheck-0", "read-0",
        ])
    }

    /// Restored journal rows at boot are nobody's wait: their admissions
    /// queue behind a connect queued after them (C), never ahead (A).
    func testRestoredRowsQueueBehindConnects() async throws {
        var harness = try await harness(keyByte: 0x4B)
        let root = harness.host.rootPath
        for nonce in 0..<6 {
            try await harness.step(.level(root, .mining(.transactionReceived(
                try transaction(nonce: UInt64(nonce)), origin: .restored(addedAt: 1)
            ))))
        }
        XCTAssertEqual(harness.jobs.count, 6)
        let ran = Ran()
        var queues = NodeRuntime.JobQueues()
        for (index, job) in harness.jobs.enumerated() {
            XCTAssertEqual(job.kind, .other)
            queues.append(NodeRuntime.RuntimeJob(path: job.path, tipCID: job.tipCID, kind: job.kind) {
                await ran.add("restored-\(index)"); return []
            })
        }
        queues.append(NodeRuntime.RuntimeJob(path: root, tipCID: nil, kind: .connect) { await ran.add("connect"); return [] })
        while let next = queues.next(in: harness.host) { _ = await next.run() }
        let order = await ran.names
        XCTAssertEqual(order, ["connect"] + (0..<6).map { "restored-\($0)" })
    }

    /// One worker, the tip moving while a submit's job waits: the job runs
    /// on the tip it was spawned on, its ready verdict, stale, is applied and
    /// answered once, and the pooled transaction is checked once more on the
    /// current tip. Two preflights in all, never a refusal.
    func testAStaleReadyVerdictIsAdmittedAndRecheckedOnceOnTheCurrentTip() async throws {
        var harness = try await harness(keyByte: 0x49)
        let clock = TestBlockClock()
        let root = harness.host.rootPath
        var tip = try await harness.tipBlock()
        let spawnedOn = harness.actOnTip
        let tx = try transaction()
        let cid = try Mempool.cid(of: tx)
        try await harness.step(.level(root, .mining(.transactionReceived(tx, origin: .local(replyID: 1)))))
        // Five moves while its job waits in the queue.
        for _ in 0..<5 { tip = try await mine(&harness, on: tip, timestamp: clock.next()) }
        XCTAssertFalse(harness.refused(1), "\(harness.replies)")

        var verdicts: [(tip: String, checksPolicies: Bool)] = []
        while !harness.jobs.isEmpty {
            let job = harness.jobs.removeFirst()
            guard job.isCurrent(in: harness.host) else { continue }
            for event in await job.run() {
                if case .level(_, .mining(.preflighted(let job, _, _))) = event, job.cid == cid {
                    verdicts.append((job.tipCID, job.checksPolicies))
                }
                try await harness.step(event)
            }
        }
        XCTAssertEqual(verdicts.map(\.tip), [spawnedOn, harness.actOnTip], "\(verdicts)")
        XCTAssertEqual(verdicts.map(\.checksPolicies), [true, false])
        XCTAssertTrue(harness.admitted(1), "\(harness.replies)")
        XCTAssertFalse(harness.refused(1), "\(harness.replies)")
        XCTAssertTrue(harness.mining.mempool.contains(cid), "pooled on the final tip")
        XCTAssertEqual(harness.mining.outstandingPreflights, 0)
    }

    private actor Ran {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    /// A job told apart by its path's last element, at `depth`; no tip, so
    /// it is always current.
    private static func job(
        _ name: String, depth: Int, kind: NodeRuntime.RuntimeJob.Kind = .other
    ) -> NodeRuntime.RuntimeJob {
        let path = Array(["Nexus", "Child", "Grand"].prefix(depth - 1)) + [name]
        return NodeRuntime.RuntimeJob(path: path, tipCID: nil, kind: kind) { [] }
    }

    /// A job reads the levels on the running loop, and once the loop has
    /// stopped every read is nil rather than a wait that never ends.
    func testAJobReadsTheLiveLevelsUntilTheLoopStops() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-core-job-order-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "47", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let runtime = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration), configuration: configuration
        )
        let levels = LiveLevels(inputs: runtime.inputs)
        let tip = await levels.read { $0[["Nexus"]]?.snapshot.actOnTip }
        XCTAssertEqual(tip, runtime.published.value?.actOnTip)
        await runtime.stop()
        let afterStop = await levels.read { $0.count }
        XCTAssertNil(afterStop)
    }
}
