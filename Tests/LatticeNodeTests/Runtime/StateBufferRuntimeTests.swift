import Foundation
import Ivy
import Lattice
import cashew
import LatticeNodeCore
import XCTest
@testable import LatticeNode
import LatticeNodeAPI

/// Executed state is buffered in memory and flushed to the store in batches
/// (`StateBuffer`). What an operator sees of that: a node reads the state of
/// the blocks it executed, keeps it across a clean stop, and after a crash
/// executes again what the crash lost and comes back to the same tip with
/// the same balances, asking no peer.
final class StateBufferRuntimeTests: XCTestCase {
    private let nexus = ["Nexus"]

    private func directory(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-state-buffer-\(name)-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func configuration(
        _ directory: URL, buffer: Int = NodeResourcePolicy.defaultMaximumBufferedStateBytes,
        state: StateRetention = .all
    ) throws -> (NodeConfiguration, IvyConfig) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: nexus, storagePath: directory,
            privateKeyHex: String(repeating: "5b", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), externalAddress: "127.0.0.1",
            resourcePolicy: NodeResourcePolicy(maximumBufferedStateBytes: buffer),
            state: state
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", port), mode: .overlay
        )
        return (configuration, overlay)
    }

    /// Mines `count` Nexus blocks paying `payee`, each executed before the
    /// next. Returns the tip.
    private func mine(_ count: Int, on runtime: NodeRuntime, paying payee: String) async throws -> String {
        for _ in 0..<count {
            let height = runtime.published.value?.actOnHeight ?? 0
            _ = try await runtime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: nexus, address: payee),
            ]))
            try await eventually("the mined block executes") {
                (runtime.published.value?.actOnHeight ?? 0) > height
            }
        }
        return try XCTUnwrap(runtime.published.value?.actOnTip)
    }

    private func payee() -> String {
        CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
    }

    /// What a start must give back: the tip, and the balance at it.
    private struct Seen: Equatable {
        let tip: String
        let balance: UInt64
    }

    /// Runs a node on `configuration`, lets `work` use it, and stops it
    /// cleanly. The store is released when this returns.
    private func run<T>(
        _ configuration: NodeConfiguration, _ overlay: IvyConfig,
        _ work: (NodeRuntime) async throws -> T
    ) async throws -> T {
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let result = try await work(runtime)
        await runtime.stop()
        return result
    }

    /// The tip and `payee`'s balance at it, once the node can read it; the
    /// tip is `expected` when one is given, once the node has reached it.
    private func seen(by runtime: NodeRuntime, of payee: String, at expected: String? = nil) async throws -> Seen {
        if let expected {
            try await eventually("the node is back at its tip") { runtime.published.value?.actOnTip == expected }
        }
        let tip = try XCTUnwrap(runtime.published.value?.actOnTip)
        var balance: UInt64?
        try await eventually("the tip's state is read") {
            balance = await runtime.reads.account(owner: payee, blockCID: tip)?.balance
            return balance != nil
        }
        return Seen(tip: tip, balance: try XCTUnwrap(balance))
    }

    /// With the default buffer, one every step fills, and none: a node that
    /// is stopped and started again reads what it executed, with no peer,
    /// and goes on from the same tip.
    func testANodeStoppedAndStartedAgainReadsWhatItExecuted() async throws {
        for buffer in [NodeResourcePolicy.defaultMaximumBufferedStateBytes, 1, 0] {
            let (configuration, overlay) = try configuration(directory("clean-\(buffer)"), buffer: buffer)
            let payee = payee()
            let before = try await run(configuration, overlay) { runtime in
                _ = try await self.mine(5, on: runtime, paying: payee)
                return try await self.seen(by: runtime, of: payee)
            }
            XCTAssertGreaterThan(before.balance, 0, "buffer \(buffer)")
            try await run(configuration, overlay) { runtime in
                let after = try await self.seen(by: runtime, of: payee)
                XCTAssertEqual(after, before, "buffer \(buffer)")
                let next = try await self.mine(1, on: runtime, paying: payee)
                XCTAssertNotEqual(next, before.tip, "buffer \(buffer)")
            }
        }
    }

    /// The store's files as a crash would leave them: copied while the node
    /// runs, before any clean stop. A node started on the copy, with no
    /// peer, starts below its tip, executes again the blocks whose state
    /// the crash lost, and is back at the same tip with the same balance.
    func testANodeStartedAfterACrashComesBackToTheSameTipAndBalances() async throws {
        let (configuration, overlay) = try configuration(directory("running"))
        let crashed = directory("crashed")
        let payee = payee()
        var tipState = ""
        let before = try await run(configuration, overlay) { runtime in
            let tip = try await self.mine(6, on: runtime, paying: payee)
            let seen = try await self.seen(by: runtime, of: payee)
            let fact = try await runtime.storage.store.blockFact(tip, at: self.nexus)
            tipState = try XCTUnwrap(fact).postStateCID
            // No write is under way while the files are copied: the copy
            // is the store at one moment, as a crash leaves it.
            await runtime.storage.written()
            try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(atPath: configuration.storagePath.path)
            where file.hasSuffix(".db") || file.hasSuffix("-wal") {
                try FileManager.default.copyItem(
                    at: configuration.storagePath.appendingPathComponent(file),
                    to: crashed.appendingPathComponent(file)
                )
            }
            return seen
        }

        let (restarted, restartedOverlay) = try self.configuration(crashed)
        let storage = try await NodeStorage.open(configuration: restarted)
        // The premise, or this test shows nothing: the crash did lose the
        // tip's state. A store that held it would pass below untested.
        let held = await storage.broker.hasVolume(root: tipState)
        XCTAssertFalse(held, "the copied store still holds the tip's state: nothing was lost")
        let runtime = try await NodeRuntime.start(storage: storage, configuration: restarted, overlay: restartedOverlay)
        let after = try await seen(by: runtime, of: payee, at: before.tip)
        XCTAssertEqual(after, before)
        let next = try await mine(1, on: runtime, paying: payee)
        XCTAssertNotEqual(next, before.tip)
        await runtime.stop()
    }

    /// With a state window, where the counts and the releases work on the
    /// store: the same holds across a clean stop.
    func testANodeKeepingRecentStateReadsWhatItExecutedAfterARestart() async throws {
        let (configuration, overlay) = try configuration(directory("recent"), state: .recent)
        let payee = payee()
        let before = try await run(configuration, overlay) { runtime in
            _ = try await self.mine(8, on: runtime, paying: payee)
            return try await self.seen(by: runtime, of: payee)
        }
        try await run(configuration, overlay) { runtime in
            let after = try await self.seen(by: runtime, of: payee)
            XCTAssertEqual(after, before)
        }
    }

    /// A disk that has stopped answering: a write waits in the store's
    /// lane and every write behind it with it. The node goes on executing
    /// the blocks it is given and answers for them, their balances and
    /// their blocks, from what it holds in memory; when the disk answers,
    /// a node started again is at the same tip with the same balance.
    func testANodeWhoseDiskStoppedAnsweringGoesOnExecutingAndAnswering() async throws {
        let (configuration, overlay) = try configuration(directory("stalled"))
        let payee = payee()
        let (answers, disk) = AsyncStream<Void>.makeStream()
        let before = try await run(configuration, overlay) { runtime in
            _ = try await self.mine(2, on: runtime, paying: payee)
            let height = try XCTUnwrap(runtime.published.value?.actOnHeight)
            runtime.storage.lane.run { for await _ in answers { break } }
            let tip = try await self.mine(4, on: runtime, paying: payee)
            XCTAssertEqual(runtime.published.value?.actOnHeight, height + 4)
            // Asked while nothing of the four blocks is written.
            let seen = try await self.seen(by: runtime, of: payee)
            XCTAssertEqual(seen.tip, tip)
            let executed = await runtime.storage.hasExecutedBlock(tip, at: self.nexus)
            XCTAssertTrue(executed, "the tip is answered for as executed")
            disk.yield()
            return seen
        }
        try await run(configuration, overlay) { runtime in
            let after = try await self.seen(by: runtime, of: payee)
            XCTAssertEqual(after, before)
        }
    }

    /// A transaction this node acknowledged to its operator is not lost to
    /// a crash, whatever the crash took. A block confirms it, and the node
    /// dies before that block is written: started again, the node is below
    /// that block and holds the transaction in its pool, to be mined again.
    func testATransactionAnOperatorSubmittedOutlivesACrashThatLostItsBlock() async throws {
        let (configuration, overlay) = try configuration(directory("submitted"))
        let crashed = directory("submitted-crashed")
        let payee = payee()
        let (answers, disk) = AsyncStream<Void>.makeStream()
        let key = CryptoUtils.generateKeyPair()
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [Action(key: "k", oldValue: nil, newValue: "v")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: nexus
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: body, privateKeyHex: key.privateKey
            ))],
            body: body
        )
        let before = try await run(configuration, overlay) { runtime -> String in
            let tip = try await self.mine(2, on: runtime, paying: payee)
            let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
            XCTAssertEqual(admitted.mempoolCount, 1)
            // The disk stops answering, once every write before is made;
            // a block confirms the transaction.
            let (stopped, stops) = AsyncStream<Void>.makeStream()
            runtime.storage.lane.run {
                stops.yield()
                for await _ in answers { break }
            }
            for await _ in stopped { break }
            _ = try await self.mine(1, on: runtime, paying: payee)
            try await eventually("the block took the transaction from the pool") {
                runtime.published.value?.mempoolCount == 0
            }
            // The crash: the store as it is now, the block unwritten.
            try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(atPath: configuration.storagePath.path)
            where file.hasSuffix(".db") || file.hasSuffix("-wal") {
                try FileManager.default.copyItem(
                    at: configuration.storagePath.appendingPathComponent(file),
                    to: crashed.appendingPathComponent(file)
                )
            }
            disk.yield()
            return tip
        }

        let (restarted, restartedOverlay) = try self.configuration(crashed)
        try await run(restarted, restartedOverlay) { runtime in
            // The premise: the crash did lose the confirming block.
            try await eventually("the node is at the tip below the lost block") {
                runtime.published.value?.actOnTip == before
            }
            try await eventually("the transaction is in the pool again") {
                runtime.published.value?.mempoolCount == 1
            }
        }
    }
}
