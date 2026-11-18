import Foundation
import Lattice
@testable import LatticeNodeCore
import XCTest
@testable import LatticeNode
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
            privateKeyHex: String(repeating: "5b", count: 32), connectBatch: 3
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
        mutating func step(_ event: NodeEvent) async throws {
            var pending = [event]
            while !pending.isEmpty {
                let effects = host.step(pending.removeFirst(), now: NodeRuntime.now())
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

        /// Run the first held job as the worker does; its events, unapplied.
        mutating func runHeld() async -> [NodeEvent] {
            guard !held.isEmpty else {
                XCTFail("no connect job held; asked \(asked)")
                return []
            }
            let jobs = held.removeFirst()
            let levels = host.levels
            return await NodeRuntime.connectJob(
                jobs, at: host.rootPath, levels: LiveLevels { $0(levels) }, storage: storage
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
}
