import BenchVFS
import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// A power loss takes every write a database had not synced. The Volume
/// store does not wait for a write's sync (`BrokerDurability.deferred`), so
/// what an operator or a miner was promised, and what a start relies on,
/// must have been synced where it was promised. Each test runs a node, takes
/// what a power loss at that moment is sure to leave (each database file as
/// of its last sync), and starts a node on that.
final class PowerLossTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private typealias Key = (privateKey: String, publicKey: String)

    static let alpha = ["Nexus", "Alpha"]
    static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    /// Every store of a test is under this directory, whose databases keep
    /// their last synced bytes beside them.
    private var disks: URL!

    override func setUpWithError() throws {
        XCTAssertEqual(bench_vfs_install(), 0)
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-outage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The path SQLite opens its files by: every link resolved.
        let real = try XCTUnwrap(realpath(made.path, nil))
        defer { free(real) }
        disks = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        bench_vfs_keep_synced(disks.path)
    }

    override func tearDown() {
        bench_vfs_keep_synced("")
        try? FileManager.default.removeItem(at: disks)
    }

    /// What a power loss now leaves of `directory`, as a new directory: each
    /// database file as of its last sync (one never synced is gone), every
    /// other file as it is.
    private func afterPowerLoss(_ directory: URL) throws -> URL {
        let left = disks.appendingPathComponent("left-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        // One moment's: no database's synced bytes change while they are read.
        bench_vfs_hold_synced(1)
        defer { bench_vfs_hold_synced(0) }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let source = directory.appendingPathComponent(name)
            if name.hasSuffix(".durable") {
                try FileManager.default.copyItem(at: source, to: left.appendingPathComponent(String(name.dropLast(8))))
            } else if name.hasSuffix(".durable.tmp") || name.contains(".db") {
                continue
            } else {
                try FileManager.default.copyItem(at: source, to: left.appendingPathComponent(name))
            }
        }
        return left
    }

    private func host(
        keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil,
        state: StateRetention = .all, hostsAlpha: Bool = false, alphaSpec: ChainSpec? = nil,
        stateBuffer: Int = NodeResourcePolicy.defaultMaximumBufferedStateBytes
    ) throws -> Host {
        let storageDirectory = reused ?? disks.appendingPathComponent("node-\(UUID().uuidString)", isDirectory: true)
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            peerSearchInterval: 600,
            resourcePolicy: NodeResourcePolicy(maximumBufferedStateBytes: stateBuffer),
            state: state,
            hostedChildren: hostsAlpha ? [Self.alpha] : [],
            childSpecs: alphaSpec.map { [Self.alpha: $0] } ?? [:]
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    private func start(_ host: Host) async throws -> (NodeRuntime, NodeStorage) {
        // A directory a node of this test just stopped on is free once that
        // node's last work has let go of its store.
        var opened: NodeStorage?
        try await eventually("the store directory is free") {
            do {
                opened = try await NodeStorage.open(configuration: host.configuration)
                return true
            } catch NodeStorageError.storageInUse {
                return false
            }
        }
        let storage = try XCTUnwrap(opened)
        return (try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        ), storage)
    }

    private func address(_ key: Key) -> String { CryptoUtils.createAddress(from: key.publicKey) }

    private func payment(_ payer: Key, to payee: Key, nonce: UInt64) throws -> Transaction {
        let header = try HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: address(payer), delta: -2), AccountAction(owner: address(payee), delta: 1)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(payer)], nonce: nonce, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [payer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: payer.privateKey
            ))],
            body: header
        )
    }

    /// A transaction the operator was told is accepted is in the pool of
    /// the node that starts after a power loss.
    func testAnAcknowledgedTransactionOutlivesAPowerLoss() async throws {
        let (payer, payee): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let node = try host(keyByte: 0xe1)
        let (runtime, _) = try await start(node)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        for _ in 0..<2 { _ = try await runtime.mineBlock(paid) }
        let accepted = try await runtime.submitTransaction(
            SubmitTransactionRequest(transaction: try payment(payer, to: payee, nonce: 0))
        ).transactionCID
        let left = try afterPowerLoss(node.configuration.storagePath)
        await runtime.stop()

        let (after, _) = try await start(try host(keyByte: 0xe1, storageDirectory: left))
        try await eventually("the transaction is in the pool again") {
            await after.reads.readSnapshot().mempoolCount == 1
        }
        let block = try BlockHeader(node: try await after.mineBlock(paid)).rawCID
        try await eventually("and a block confirms it") {
            after.published.value?.actOnTip == block
        }
        let confirmed = await after.reads.transaction(cid: accepted)
        XCTAssertNotNil(confirmed)
        await after.stop()
    }

    /// A block a miner was told is accepted is on the chain of the node
    /// that starts after a power loss, with no peer to give it back: the
    /// node holds its body, executes again what it must, and answers for
    /// its state.
    func testABlockAMinerWasAnsweredForOutlivesAPowerLoss() async throws {
        try await answeredBlockOutlivesAPowerLoss(stateBuffer: NodeResourcePolicy.defaultMaximumBufferedStateBytes)
    }

    /// The same with a buffer of 0, flushed after every step.
    func testABlockAMinerWasAnsweredForOutlivesAPowerLossWithNoStateBuffer() async throws {
        try await answeredBlockOutlivesAPowerLoss(stateBuffer: 0)
    }

    private func answeredBlockOutlivesAPowerLoss(stateBuffer: Int) async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let node = try host(keyByte: 0xe2, stateBuffer: stateBuffer)
        let (runtime, _) = try await start(node)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        var tip = ""
        for _ in 0..<5 { tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID }
        let left = try afterPowerLoss(node.configuration.storagePath)
        await runtime.stop()

        let (after, _) = try await start(try host(keyByte: 0xe2, storageDirectory: left, stateBuffer: stateBuffer))
        try await eventually("the node is on the block it answered for") {
            after.published.value?.actOnTip == tip
        }
        let balance = await after.reads.account(owner: address(miner), blockCID: tip)?.balance
        XCTAssertNotNil(balance, "and holds its state")
        await after.stop()
    }

    /// What the operator pinned is pinned and held after a power loss.
    func testAPinOutlivesAPowerLoss() async throws {
        let node = try host(keyByte: 0xe3)
        let (runtime, storage) = try await start(node)
        let volume = try VolumeImpl<ChainSpec>(node: Self.alphaSpec)
        let bytes = try XCTUnwrap(volume.node?.toData())
        try await storage.pin(volume.rawCID, entries: [volume.rawCID: bytes])
        let left = try afterPowerLoss(node.configuration.storagePath)
        await runtime.stop()

        let after = try await NodeStorage.open(configuration: try host(keyByte: 0xe3, storageDirectory: left).configuration)
        let pins = await after.operatorPins()
        XCTAssertEqual(pins, [volume.rawCID])
        let held = await after.broker.hasVolume(root: volume.rawCID)
        XCTAssertTrue(held)
    }

    /// A node that loses power while it syncs starts on a tip whose state
    /// it holds, with no peer to read from, and reaches its peer's tip once
    /// it has one again. With a small state buffer its states reach the
    /// store, and the marker of what is stored moves, many times before the
    /// power goes.
    func testANodeThatLosesPowerWhileSyncingStartsOnStateItHolds() async throws {
        let (payer, payee): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let producer = try host(keyByte: 0xe4)
        let (producerRuntime, _) = try await start(producer)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        for _ in 0..<2 { _ = try await producerRuntime.mineBlock(paid) }
        var tip = ""
        for nonce in 0..<12 {
            _ = try await producerRuntime.submitTransaction(
                SubmitTransactionRequest(transaction: try payment(payer, to: payee, nonce: UInt64(nonce)))
            )
            tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID
        }

        let follower = try host(keyByte: 0xe5, peers: [producer.endpoint], state: .recent, stateBuffer: 4_096)
        let (runtime, _) = try await start(follower)
        try await eventually("the follower is part of the way") {
            (await runtime.reads.readSnapshot().height ?? 0) >= 6
        }
        let left = try afterPowerLoss(follower.configuration.storagePath)
        await runtime.stop()

        // Alone: what it stands on is read from its own store.
        do {
            let (alone, _) = try await start(try host(keyByte: 0xe5, storageDirectory: left, state: .recent, stateBuffer: 4_096))
            let snapshot = await alone.reads.readSnapshot()
            XCTAssertGreaterThan(snapshot.height ?? 0, 0, "the node starts on a block it executed before the power went")
            let standing = try XCTUnwrap(snapshot.tipCID)
            let balance = await alone.reads.account(owner: address(payer), blockCID: standing)?.balance
            XCTAssertNotNil(balance, "the node holds the state of the tip it starts on")
            await alone.stop()
        }
        let (again, _) = try await start(
            try host(keyByte: 0xe5, peers: [producer.endpoint], storageDirectory: left, state: .recent, stateBuffer: 4_096)
        )
        try await eventually("the follower reaches its peer's tip") { again.published.value?.actOnTip == tip }
        await again.stop()
        await producerRuntime.stop()
    }

    /// A node following a child chain it was given no spec for reads the
    /// spec from the chain's genesis as it syncs, and needs it at every
    /// start. It starts after a power loss that follows the genesis.
    func testAFollowedChildChainsSpecOutlivesAPowerLoss() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let producer = try host(keyByte: 0xe6, hostsAlpha: true, alphaSpec: Self.alphaSpec)
        let (producerRuntime, _) = try await start(producer)
        let paid = MiningTemplateRequest(recipients: [
            MiningRecipient(chainPath: ["Nexus"], address: address(miner)),
            MiningRecipient(chainPath: Self.alpha, address: address(miner)),
        ])
        let producerAlpha = try XCTUnwrap(producerRuntime.levelReads[Self.alpha])
        try await eventually("the producer's child chain has blocks") {
            _ = try await producerRuntime.mineBlock(paid)
            return (await producerAlpha.readSnapshot().height ?? 0) >= 3
        }

        let follower = try host(keyByte: 0xe7, peers: [producer.endpoint], hostsAlpha: true)
        let (runtime, _) = try await start(follower)
        let alpha = try XCTUnwrap(runtime.levelReads[Self.alpha])
        try await eventually("the follower executes the child chain") {
            (await alpha.readSnapshot().height ?? 0) >= 1
        }
        let left = try afterPowerLoss(follower.configuration.storagePath)
        await runtime.stop()

        // Alone first: the start itself needs the spec, and no peer has it then.
        do {
            let (alone, _) = try await start(try host(keyByte: 0xe7, storageDirectory: left, hostsAlpha: true))
            XCTAssertNotNil(alone.levelReads[Self.alpha], "the node starts, following the child chain")
            await alone.stop()
        }
        let (after, _) = try await start(
            try host(keyByte: 0xe7, peers: [producer.endpoint], storageDirectory: left, hostsAlpha: true)
        )
        let afterAlpha = try XCTUnwrap(after.levelReads[Self.alpha])
        let producerSnapshot = await producerAlpha.readSnapshot()
        let height = try XCTUnwrap(producerSnapshot.height)
        try await eventually("the follower starts and reaches the child chain's tip") {
            (await afterAlpha.readSnapshot().height ?? 0) >= height
        }
        await after.stop()
        await producerRuntime.stop()
    }
}
