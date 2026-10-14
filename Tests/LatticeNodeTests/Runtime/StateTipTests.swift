import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// `state: tip`: a node keeps the state its chains' tips are made of, and
/// lets go of what a newer block replaced.
final class StateTipTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(
        keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil, state: StateRetention = .all
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-state-\(UUID().uuidString)", isDirectory: true
        )
        if reused == nil { addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) } }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            state: state
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
        let storage = try await NodeStorage.open(configuration: host.configuration)
        return (try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        ), storage)
    }

    private typealias Key = (privateKey: String, publicKey: String)

    private func address(_ key: Key) -> String { CryptoUtils.createAddress(from: key.publicKey) }

    private func transaction(
        _ signer: Key, nonce: UInt64, moves: [(String, Int64)] = [], actions: [Action] = []
    ) throws -> Transaction {
        let header = try HeaderImpl(node: TransactionBody(
            accountActions: moves.map { AccountAction(owner: $0.0, delta: $0.1) },
            actions: actions, depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(signer)], nonce: nonce, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [signer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: signer.privateKey
            ))],
            body: header
        )
    }

    /// Every node of the state of `block`, with how many nodes of that
    /// state name it (its root once), read from this store alone: nil when
    /// a node of it is not held.
    private func stateNodes(of block: String, in storage: NodeStorage) async throws -> [String: Int]? {
        let fact = try await storage.store.blockFact(block, at: ["Nexus"])
        let root = try XCTUnwrap(fact?.postStateCID)
        guard let state = try? await LatticeStateHeader(rawCID: root).resolveRecursive(fetcher: storage.localFetcher) else {
            return nil
        }
        var counts: [String: Int] = [:]
        func count(_ header: any Header) {
            counts[header.rawCID, default: 0] += 1
            guard counts[header.rawCID] == 1, let node = header.node else { return }
            for property in node.properties() {
                if let child = node.get(property: property) { count(child) }
            }
        }
        count(state)
        return counts
    }

    private func assertKeepsExactlyTheStateOf(
        _ tip: String, _ storage: NodeStorage, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await eventually("the kept state is moved to the tip (\(message))") {
            try await storage.store.stateTip(at: ["Nexus"]) == tip
        }
        let state = try await stateNodes(of: tip, in: storage)
        let counted = try await storage.store.stateCounts(at: ["Nexus"])
        XCTAssertEqual(counted, try XCTUnwrap(state, "the tip's state is held", file: file, line: line), message, file: file, line: line)
    }

    /// A miner on `tip` executes blocks that pay, spend and change one
    /// account's balance while its nonce holds the same value, which makes
    /// the two one node of the state. After each,
    /// the counts are exactly the tip's state, node for node; the state of
    /// an old block is gone; and a restart changes nothing.
    func testTheKeptStateIsExactlyTheTipsState() async throws {
        let node = try host(keyByte: 0xb0, state: .tip)
        let miner: Key = CryptoUtils.generateKeyPair()
        var other: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        var blocks: [String] = []
        do {
            let (runtime, storage) = try await start(node)
            func mine(_ transactions: [Transaction] = []) async throws {
                for transaction in transactions {
                    _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
                }
                let mined = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
                blocks.append(mined)
                try await assertKeepsExactlyTheStateOf(mined, storage, "block \(blocks.count)")
            }
            try await mine()
            try await mine()
            // An account holds 1, and after two transactions of its own the
            // nonce the state records for it is 1 too: its balance and its
            // nonce are then one node, held in two places, when the keys
            // around them branch alike. An account whose do not is passed over.
            var minerNonce: UInt64 = 0
            var shared = false
            for _ in 0..<6 where !shared {
                other = CryptoUtils.generateKeyPair()
                let before = try await storage.store.stateCounts(at: ["Nexus"]).filter { $0.value > 1 }.count
                try await mine([try transaction(miner, nonce: minerNonce, moves: [(address(miner), -2), (address(other), 1)])])
                minerNonce += 1
                try await mine([try transaction(other, nonce: 0)])
                try await mine([try transaction(other, nonce: 1)])
                shared = try await storage.store.stateCounts(at: ["Nexus"]).filter { $0.value > 1 }.count > before
            }
            XCTAssertTrue(shared, "a balance and a nonce of one value are one node")
            // Its balance changes while its nonce stays: the node leaves one
            // place and stays in the other, where the next transaction reads it.
            try await mine([try transaction(miner, nonce: minerNonce, moves: [(address(miner), -2), (address(other), 1)])])
            try await mine([try transaction(other, nonce: 2)])
            try await mine([try transaction(other, nonce: 3, moves: [(address(other), -2)])])

            let old = try await stateNodes(of: blocks[0], in: storage)
            XCTAssertNil(old, "the state a newer block replaced is let go of")
            let balance = await runtime.reads.account(owner: address(other), blockCID: try XCTUnwrap(blocks.last))?.balance
            XCTAssertEqual(balance, 0)
            await runtime.stop()
        }

        let (runtime, storage) = try await start(node)
        let tip = try XCTUnwrap(blocks.last)
        try await assertKeepsExactlyTheStateOf(tip, storage, "after a restart")
        let next = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
        try await assertKeepsExactlyTheStateOf(next, storage, "after a block mined on the restarted node")
        await runtime.stop()
    }

    /// A node on `tip` follows one branch, then a heavier one that forks at
    /// genesis: the state it needs there was let go of, and comes from the
    /// peer with the blocks. The kept state is exactly the new tip's.
    func testANodeOnTipFollowsAReorgWhoseForkPointStateItDropped() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        func branch(_ keyByte: UInt8, blocks count: Int) async throws -> (Host, NodeRuntime, String) {
            let producer = try host(keyByte: keyByte)
            let (runtime, _) = try await start(producer)
            let paid = MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: ["Nexus"], address: address(payer)),
            ])
            var tip = ""
            for _ in 0..<count { tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID }
            return (producer, runtime, tip)
        }
        let (first, firstRuntime, firstTip) = try await branch(0xb2, blocks: 3)
        let (second, secondRuntime, secondTip) = try await branch(0xb3, blocks: 5)

        var node = try host(keyByte: 0xb4, peers: [first.endpoint], state: .tip)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the first branch") { runtime.published.value?.actOnTip == firstTip }
            try await assertKeepsExactlyTheStateOf(firstTip, storage, "the first branch")
            await runtime.stop()
        }
        node = try host(
            keyByte: 0xb4, peers: [second.endpoint], storageDirectory: node.configuration.storagePath, state: .tip
        )
        let (runtime, storage) = try await start(node)
        try await eventually("the node moves onto the heavier branch") { runtime.published.value?.actOnTip == secondTip }
        try await assertKeepsExactlyTheStateOf(secondTip, storage, "the heavier branch")
        let left = try await stateNodes(of: firstTip, in: storage)
        XCTAssertNil(left, "the state of the branch it left is let go of")
        await runtime.stop()
        await firstRuntime.stop()
        await secondRuntime.stop()
    }

    /// The state of a chain's tip is kept whole after a move to another
    /// branch: an account the branch it left changed and the new branch
    /// never touches is read from a peer, so its state is read at the tip
    /// and its transaction is mined.
    func testStateTheNewBranchNeverTouchesComesFromAPeer() async throws {
        let (payer, account): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let first = try host(keyByte: 0xb8)
        let (firstRuntime, _) = try await start(first)
        func mine(_ runtime: NodeRuntime, _ transactions: [Transaction] = []) async throws -> String {
            for transaction in transactions {
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
            }
            return try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
        }
        _ = try await mine(firstRuntime)
        _ = try await mine(firstRuntime)
        let shared = try await mine(firstRuntime, [
            try transaction(payer, nonce: 0, moves: [(address(account), 5), (address(payer), -5)]),
        ])
        // The second branch builds on the shared history and never touches the account.
        var second = try host(keyByte: 0xb9, peers: [first.endpoint])
        do {
            let (runtime, _) = try await start(second)
            try await eventually("the second producer has the shared history") {
                runtime.published.value?.actOnTip == shared
            }
            await runtime.stop()
        }
        second = try host(keyByte: 0xb9, storageDirectory: second.configuration.storagePath)
        let (secondRuntime, _) = try await start(second)
        var secondTip = ""
        for _ in 0..<4 { secondTip = try await mine(secondRuntime) }
        let firstTip = try await mine(firstRuntime, [
            try transaction(payer, nonce: 1, moves: [(address(account), 1), (address(payer), -1)]),
        ])

        var node = try host(keyByte: 0xba, peers: [first.endpoint], state: .tip)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the first branch") { runtime.published.value?.actOnTip == firstTip }
            try await assertKeepsExactlyTheStateOf(firstTip, storage, "the first branch")
            await runtime.stop()
        }
        node = try host(
            keyByte: 0xba, peers: [second.endpoint], storageDirectory: node.configuration.storagePath, state: .tip
        )
        let (runtime, storage) = try await start(node)
        try await eventually("the node moves onto the heavier branch") { runtime.published.value?.actOnTip == secondTip }
        try await assertKeepsExactlyTheStateOf(secondTip, storage, "the heavier branch")
        let balance = await runtime.reads.account(owner: address(account), blockCID: secondTip)?.balance
        XCTAssertEqual(balance, 5)
        let tip = try await mine(runtime, [try transaction(account, nonce: 0, moves: [(address(account), -1)])])
        // The payment of the branch it left is returned and mined with it.
        let after = await runtime.reads.account(owner: address(account), blockCID: tip)
        XCTAssertEqual(after?.nonce, 1, "the account's transaction is mined on the node that had let go of its state")
        XCTAssertEqual(after?.balance, 5)
        await runtime.stop()
        await firstRuntime.stop()
        await secondRuntime.stop()
    }

    /// Keys that split a node of the state while a node below it changes,
    /// with a twin of the changed node elsewhere: the twin leaving its
    /// place does not take the node the other place still names.
    func testANodeNamedFromTwoPlacesAcrossASplitStays() async throws {
        let node = try host(keyByte: 0xbb, state: .tip)
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let (runtime, storage) = try await start(node)
        var nonce: UInt64 = 0
        func mine(_ actions: [Action]) async throws {
            if !actions.isEmpty {
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(miner, nonce: nonce, actions: actions)
                ))
                nonce += 1
            }
            let mined = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
            try await assertKeepsExactlyTheStateOf(mined, storage, "after \(actions.map(\.key))")
        }
        try await mine([])
        try await mine([
            Action(key: "abbX", oldValue: nil, newValue: "1"),
            Action(key: "abdY", oldValue: nil, newValue: "1"),
            Action(key: "qc", oldValue: nil, newValue: "9"),
            Action(key: "qdY", oldValue: nil, newValue: "2"),
        ])
        try await mine([
            Action(key: "azZ", oldValue: nil, newValue: "7"),
            Action(key: "abdY", oldValue: "1", newValue: "2"),
        ])
        try await mine([Action(key: "qdY", oldValue: "2", newValue: "3")])
        try await mine([Action(key: "abdY", oldValue: "2", newValue: "5")])
        XCTAssertEqual(runtime.published.value?.mempoolCount, 0, "the transaction that reads the node is mined")
        await runtime.stop()
    }

    /// A node on `none` syncs a chain whose blocks pay and spend, restarts
    /// and keeps validating. Between blocks it holds only what the last
    /// execution touched: no older block's state, and nothing a block read
    /// once that block has executed.
    func testANodeOnNoneSyncsAndKeepsValidatingHoldingNoState() async throws {
        let (payer, payee): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try host(keyByte: 0xbc)
        let (producerRuntime, _) = try await start(producer)
        var nonce: UInt64 = 0
        func produce(_ count: Int, paying: Bool = true) async throws -> [String] {
            var blocks: [String] = []
            for _ in 0..<count {
                if paying {
                    _ = try await producerRuntime.submitTransaction(SubmitTransactionRequest(
                        transaction: try transaction(payer, nonce: nonce, moves: [(address(payer), -2), (address(payee), 1)])
                    ))
                    nonce += 1
                }
                blocks.append(try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID)
            }
            return blocks
        }
        var blocks = try await produce(2, paying: false)
        blocks += try await produce(6)

        let node = try host(keyByte: 0xbd, peers: [producer.endpoint], state: .none)
        func holdsNoState(_ runtime: NodeRuntime, _ storage: NodeStorage, through tip: String) async throws {
            try await eventually("the node executes \(tip.suffix(6))") { runtime.published.value?.actOnTip == tip }
            for block in blocks.dropLast() {
                let state = try await stateNodes(of: block, in: storage)
                XCTAssertNil(state, "an older block's state is not held")
            }
            let reads = try await storage.broker.retainedScopes(prefix: storage.scopes.chain + ":reads:")
            XCTAssertEqual(reads, [], "nothing a block read is held once it has executed")
        }
        do {
            let (runtime, storage) = try await start(node)
            try await holdsNoState(runtime, storage, through: try XCTUnwrap(blocks.last))
            await runtime.stop()
        }
        blocks += try await produce(3)
        let (runtime, storage) = try await start(node)
        try await holdsNoState(runtime, storage, through: try XCTUnwrap(blocks.last))
        let balance = await producerRuntime.reads.account(owner: address(payee), blockCID: try XCTUnwrap(blocks.last))?.balance
        XCTAssertEqual(balance, 9, "the chain the node validated pays and spends")
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// The default keeps the state of every block, and counts nothing.
    func testANodeOnAllKeepsEveryState() async throws {
        let node = try host(keyByte: 0xb6)
        let (runtime, storage) = try await start(node)
        var blocks: [String] = []
        for _ in 0..<3 { blocks.append(try BlockHeader(node: try await runtime.mineBlock()).rawCID) }
        for block in blocks {
            let state = try await stateNodes(of: block, in: storage)
            XCTAssertNotNil(state)
        }
        let counted = try await storage.store.stateCounts(at: ["Nexus"])
        XCTAssertEqual(counted, [:])
        await runtime.stop()
    }

    /// A node two nodes of the state name stays until both let go of it.
    func testANodeTwoPlacesHoldLeavesWithTheSecond() async throws {
        let storage = try await NodeStorage.open(configuration: try host(keyByte: 0xb7, state: .tip).configuration)
        let store = await storage.store
        var moved = try await store.moveStateCounts(at: ["Nexus"], to: "a", changes: ["shared": 2, "single": 1])
        XCTAssertEqual(Set(moved.entered), ["shared", "single"])
        moved = try await store.moveStateCounts(at: ["Nexus"], to: "b", changes: ["shared": -1, "single": -1])
        XCTAssertEqual(moved.left, ["single"])
        moved = try await store.moveStateCounts(at: ["Nexus"], to: "c", changes: ["shared": -1])
        XCTAssertEqual(moved.left, ["shared"])
        let tip = try await store.stateTip(at: ["Nexus"])
        XCTAssertEqual(tip, "c")
    }
}

private struct StateCountRow: NodeStoreRecord {
    static let table = "core_meta"
    private let row: Row

    init(_ row: Row) { self.row = row }
    var entry: (String, Int) { get throws { (try row.text("key"), Int(try row.text("value")) ?? 0) } }
}

private extension NodeStore {
    func stateCounts(at chainPath: [String]) throws -> [String: Int] {
        let prefix = Self.stateCountKey("", at: chainPath)
        return Dictionary(uniqueKeysWithValues: try database.rows(
            StateCountRow.self, "SELECT key, value FROM core_meta WHERE substr(key, 1, ?2) = ?1",
            params: [.text(prefix), .int(Int64(prefix.count))]
        ).map { (String(try $0.entry.0.dropFirst(prefix.count)), try $0.entry.1) })
    }
}
