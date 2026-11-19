import Foundation
import Lattice
@testable import LatticeNodeCore
import XCTest
@testable import LatticeNode
import Synchronization
import cashew

/// Batched execution through the runtime, over a real `NodeStorage`: a
/// connect job of up to `connectBatch` ready blocks commits once, and a
/// crash while a batch runs leaves the node at the last batch committed.
final class BatchedConnectRuntimeTests: XCTestCase {
    private var configuration: NodeConfiguration!

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-batched-connect-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory,
            privateKeyHex: String(repeating: "5b", count: 32),
            // No state buffer: each batch's state is stored with its
            // commit, so what a crash keeps is the last committed batch.
            resourcePolicy: NodeResourcePolicy(maximumBufferedStateBytes: 0),
            connectBatch: 3
        )
    }

    /// A process: its storage opened from disk and its core booted.
    private struct Process {
        var host: NodeCore
        let storage: NodeStorage
        /// Connect jobs emitted and not run.
        var held: [[ConnectJob]] = []
        /// Persist effects executed.
        var commits = 0
        /// Bodies the core asked for, answered only by `deliver`.
        var asked: [String] = []

        var actOnTip: String { host.levels[host.rootPath]!.snapshot.actOnTip }

        /// Step `event`, executing persists as the runtime does and holding
        /// every connect job.
        mutating func step(_ event: NodeEvent, now: Int64 = NodeRuntime.now()) async throws {
            var pending = [event]
            while !pending.isEmpty {
                let effects = host.step(pending.removeFirst(), now: now)
                for case .persist(let batch) in effects {
                    try await storage.persistNodeBatch(batch, logID: host.logID)
                    commits += 1
                }
                for effect in effects {
                    switch effect {
                    case .connect(_, let jobs): held.append(jobs)
                    case .level(_, .fetchBody(let cid)): asked.append(cid)
                    default: break
                    }
                }
            }
        }

        /// The bodies asked for arrive, the last block's first: none starts
        /// a job until its parent's does, so one job takes them all.
        mutating func deliver() async throws {
            try await step(.tick)
            let cids = asked
            asked = []
            for cid in cids.reversed() {
                try await step(.level(host.rootPath, .bodyFetched(cid: cid)))
            }
        }

        /// Run the first held job as the worker does, storing its valid
        /// blocks through `store`; its events, unapplied.
        mutating func runHeld(
            failStop: @escaping @Sendable (any Error) -> Void = { XCTFail("fail-stop: \($0)") },
            store: @escaping NodeRuntime.StoreValidBlocks = { try await $0.storeValidBlocks($1, at: $2, from: $3) }
        ) async -> [NodeEvent] {
            guard !held.isEmpty else {
                XCTFail("no connect job held; asked \(asked)")
                return []
            }
            let jobs = held.removeFirst()
            let levels = host.levels
            return await NodeRuntime.connectJob(
                jobs, at: host.rootPath, levels: LiveLevels { $0(levels) }, storage: storage,
                failStop: failStop, store: store
            ).run()
        }
    }

    private func boot() async throws -> Process {
        let storage = try await NodeStorage.open(configuration: configuration)
        // The configuration's batch applies (the core config's is the default).
        return Process(
            host: try await NodeRuntime.boot(
                storage: storage, configuration: configuration, coreConfig: ChainCoreConfig(bodyWindow: 64)
            ),
            storage: storage
        )
    }

    /// `count` blocks on `previous`, their content stored, weighed as mined
    /// with their connects held.
    private func mine(_ count: Int, on previous: Block, _ process: inout Process) async throws -> [Block] {
        let clock = TestBlockClock()
        var blocks: [Block] = []
        var previous = previous
        for _ in 0..<count {
            var nonce: UInt64 = 0
            var block: Block
            repeat {
                block = try await BlockBuilder.buildBlock(
                    previous: previous, transactions: [], timestamp: clock.next(), nonce: nonce,
                    fetcher: process.storage
                )
                nonce += 1
            } while block.proofOfWorkHash() > block.target
            let children = try await process.storage.storeMinedBlock(block)
            try await process.step(.mined(MinedGrind(root: block, rootChildren: children, carried: [])))
            blocks.append(block)
            previous = block
        }
        return blocks
    }

    private func genesis(_ process: Process) async throws -> Block {
        let cid = process.actOnTip
        let content = await process.storage.content([cid])
        let data = try XCTUnwrap(content[cid])
        return try XCTUnwrap(Block(data: data))
    }

    func testABatchCommitsOnceAndACrashMidBatchRecoversToTheLastCommittedBatch() async throws {
        // Each process's storage is released before the next one opens it.
        let (genesisCID, cids): (String, [String])
        do {
            var first = try await boot()
            genesisCID = first.actOnTip
            let blocks = try await mine(6, on: try await genesis(first), &first)
            cids = try blocks.map { try BlockHeader(node: $0).rawCID }
            XCTAssertEqual(first.actOnTip, genesisCID, "every connect held")
        }

        // Restart: the weighed blocks' bodies are asked for and arrive; one
        // job takes the first three.
        do {
            var second = try await boot()
            XCTAssertEqual(second.actOnTip, genesisCID)
            try await second.deliver()
            XCTAssertEqual(second.held.map { $0.map(\.blockHash) }, [Array(cids.prefix(3))])
            let committed = second.commits
            let events = await second.runHeld()
            XCTAssertEqual(events.count, 1, "one event reports the batch")
            for event in events { try await second.step(event) }
            XCTAssertEqual(second.commits - committed, 1, "one commit for three blocks")
            XCTAssertEqual(second.actOnTip, cids[2])
            XCTAssertEqual(second.held.map { $0.map(\.blockHash) }, [Array(cids[3...5])])
            // The next batch runs, and the process dies before its verdicts
            // are applied: nothing of it is committed.
            _ = await second.runHeld()
        }

        do {
            var third = try await boot()
            XCTAssertEqual(third.actOnTip, cids[2], "the last committed batch")
            try await third.deliver()
            XCTAssertEqual(third.held.map { $0.map(\.blockHash) }, [Array(cids[3...5])], "the lost batch runs again")
            for event in await third.runHeld() { try await third.step(event) }
            XCTAssertEqual(third.actOnTip, cids[5])
        }

        let fourth = try await boot()
        XCTAssertEqual(fourth.actOnTip, cids[5])
    }

    /// The store's write failing is a local fault: the node fail-stops
    /// (Bitcoin's `AbortNode`) with nothing of the job reported, so no
    /// block of it connects; restarted, it runs the job again.
    func testAStoreWriteFailingFailStopsWithNothingOfTheJobConnected() async throws {
        let (genesisCID, cids): (String, [String])
        do {
            var first = try await boot()
            genesisCID = first.actOnTip
            cids = try await mine(3, on: try await genesis(first), &first).map { try BlockHeader(node: $0).rawCID }
        }
        do {
            var process = try await boot()
            try await process.deliver()
            let stopped = Stopped()
            let events = await process.runHeld(failStop: { stopped.record($0) }) { _, _, _, _ in throw StoreFailure() }
            XCTAssertTrue(events.isEmpty, "nothing of the job is reported")
            XCTAssertTrue(stopped.called, "the write failing fail-stops the node")
            XCTAssertEqual(process.actOnTip, genesisCID)
            let executed = try await process.storage.store.hasExecutedBlock(cids[0], at: ["Nexus"])
            XCTAssertFalse(executed)
        }
        var restarted = try await boot()
        XCTAssertEqual(restarted.actOnTip, genesisCID)
        try await restarted.deliver()
        for event in await restarted.runHeld() { try await restarted.step(event) }
        XCTAssertEqual(restarted.actOnTip, cids[2])
    }

    /// A block whose body cannot be read when it is stored ends its job at
    /// it: the blocks before it connect; it and the job's later blocks do
    /// not, the tip stays below it, and once its wait is over its body is
    /// asked for again and it connects.
    func testABlockWhoseBodyCannotBeStoredEndsTheJobAtIt() async throws {
        try await assertStoreFailure { cids in
            { storage, blocks, path, reads in
                try await storage.storeValidBlocks(blocks, at: path, from: Failing(reads, cid: cids[1]))
            }
        } connects: { cids in cids[0] }
    }

    private struct StoreFailure: Error {}

    private final class Stopped: Sendable {
        private let stopped = Mutex(false)
        func record(_: any Error) { stopped.withLock { $0 = true } }
        var called: Bool { stopped.withLock { $0 } }
    }

    /// Reads through `fetcher` except `cid`, which fails.
    private struct Failing: Fetcher {
        let fetcher: any Fetcher
        let cid: String

        init(_ fetcher: any Fetcher, cid: String) {
            self.fetcher = fetcher
            self.cid = cid
        }

        func fetch(rawCid: String) async throws -> Data {
            guard rawCid != cid else { throw StoreFailure() }
            return try await fetcher.fetch(rawCid: rawCid)
        }
    }

    /// Mines three blocks, runs their one job storing through `store`
    /// (given the blocks' CIDs), and checks the tip stops at `connects`
    /// (nil: the genesis), the failed block parked, then that it connects
    /// once asked for again.
    private func assertStoreFailure(
        _ store: ([String]) -> NodeRuntime.StoreValidBlocks,
        connects: ([String]) -> String?
    ) async throws {
        let (genesisCID, cids): (String, [String])
        do {
            var first = try await boot()
            genesisCID = first.actOnTip
            cids = try await mine(3, on: try await genesis(first), &first).map { try BlockHeader(node: $0).rawCID }
        }
        var process = try await boot()
        try await process.deliver()
        XCTAssertEqual(process.held.map { $0.map(\.blockHash) }, [cids])
        for event in await process.runHeld(store: store(cids)) { try await process.step(event) }
        let tip = connects(cids) ?? genesisCID
        XCTAssertEqual(process.actOnTip, tip, "the tip stays below the block not stored")
        let failed = cids[(cids.firstIndex(of: tip) ?? -1) + 1]
        XCTAssertTrue(process.held.isEmpty, "the failed block waits: no job runs it at once")
        let executed = try await process.storage.store.hasExecutedBlock(failed, at: ["Nexus"])
        XCTAssertFalse(executed, "the failed block is not recorded executed")

        // After its wait, it is asked for again and connects with the rest.
        try await process.step(.tick, now: NodeRuntime.now() + 2_000)
        XCTAssertTrue(process.asked.contains(failed), "asked for again once its wait is over")
        try await process.deliver()
        for event in await process.runHeld() { try await process.step(event) }
        XCTAssertEqual(process.actOnTip, cids[2])
    }
}
