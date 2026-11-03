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

/// `state: tip`: a node keeps the state its chains' tips are made of, and
/// lets go of what a newer block replaced.
final class StateTipTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(
        keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil, state: StateRetention = .all,
        finality: UInt64? = nil
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
            state: state,
            finality: FinalityWindows(all: finality)
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

    /// Every node of the state of `block` this store holds, counted as the
    /// node counts them: a node it lacks is left out with what it names.
    private func heldStateNodes(of block: String, in storage: NodeStorage) async throws -> [String: Int] {
        let fact = try await storage.store.blockFact(block, at: ["Nexus"])
        var counts: [String: Int] = [:]
        func resolved<H: Header>(_ header: H) async -> (any Header)? {
            try? await header.resolve(fetcher: storage.localFetcher)
        }
        func count(_ header: any Header) async {
            guard counts[header.rawCID] == nil else { counts[header.rawCID, default: 0] += 1; return }
            guard let node = await resolved(header) else { return }
            counts[header.rawCID] = 1
            for child in NodeStorage.children(of: node) { await count(child) }
        }
        await count(LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID)))
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
    /// an old block is not counted, and waits in the window; and a restart
    /// changes nothing.
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

            // The state a newer block replaced leaves the counts, and stays
            // in the window, for a move back onto it.
            let old = try await stateNodes(of: blocks[0], in: storage)
            let counted = try await storage.store.stateCounts(at: ["Nexus"])
            XCTAssertNotNil(old, "the window keeps the state a newer block replaced")
            XCTAssertNotEqual(old, counted, "the replaced state is not counted")
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
    /// genesis. The kept state is exactly the new tip's, and the branch it
    /// left waits in the window.
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
        XCTAssertNotNil(left, "the window keeps the state of the branch it left, for a move back")
        await runtime.stop()
        await firstRuntime.stop()
        await secondRuntime.stop()
    }

    /// A node on `tip` follows one branch, stops, and starts on a heavier
    /// one that forks below it. State at the fork point the first branch
    /// changed and the heavier one never touches left the kept state on
    /// the first move; the window keeps it across the restart's sweep, so
    /// the heavier branch's state is held whole from this store alone,
    /// with no heal.
    func testAMoveBackWithinTheWindowFindsTheForkPointsStateHereAcrossARestart() async throws {
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
        try await eventually("the kept state is moved to the heavier branch") {
            try await storage.store.stateTip(at: ["Nexus"]) == secondTip
        }
        // The account's state at the fork point left the kept state when it
        // moved onto the first branch, and stayed in the window across the
        // restart's sweep: the new branch's state is held whole, from this
        // store alone.
        let whole = try await stateNodes(of: secondTip, in: storage)
        let counted = try await storage.store.stateCounts(at: ["Nexus"])
        XCTAssertNotNil(whole, "the heavier branch's state is held whole")
        XCTAssertEqual(counted, whole, "the counts are the tip's whole state")
        let held = await runtime.reads.account(owner: address(account), blockCID: secondTip)
        XCTAssertEqual(held?.balance, 5, "the account's state at the fork point is read here")

        // The heavier branch's producer mines the account's transaction,
        // which changes its balance whatever else the block carries.
        _ = try await secondRuntime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(account, nonce: 0, moves: [(address(account), -2)])
        ))
        let spending = try await mine(secondRuntime)
        try await eventually("the node executes the block that reads the account") {
            runtime.published.value?.actOnTip == spending
        }
        try await eventually("the kept state is moved to that block") {
            try await storage.store.stateTip(at: ["Nexus"]) == spending
        }
        let after = await runtime.reads.account(owner: address(account), blockCID: spending)
        XCTAssertEqual(after?.nonce, 1, "the account's state is held again")
        XCTAssertNotNil(after?.balance)
        let countedAfter = try await storage.store.stateCounts(at: ["Nexus"])
        let heldAfter = try await heldStateNodes(of: spending, in: storage)
        XCTAssertEqual(countedAfter, heldAfter)
        await runtime.stop()
        await firstRuntime.stop()
        await secondRuntime.stop()
    }

    /// The window reaches as deep as the chain's finality window: the state
    /// of a block deeper than that below the tip is let go of, and the
    /// window holds only heights within it; the kept state stays the tip's.
    func testTheWindowLetsGoOfStateDeeperThanFinality() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        var node = try host(keyByte: 0xc0, state: .tip, finality: 2)
        var blocks: [String] = []
        do {
            let (runtime, storage) = try await start(node)
            for _ in 0..<7 { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
            try await assertKeepsExactlyTheStateOf(blocks[6], storage, "the tip")
            await runtime.stop()
        }
        node = try host(keyByte: 0xc0, storageDirectory: node.configuration.storagePath, state: .tip, finality: 2)
        let (runtime, storage) = try await start(node)
        try await assertKeepsExactlyTheStateOf(blocks[6], storage, "after a restart")
        let deep = try await stateNodes(of: blocks[1], in: storage)
        XCTAssertNil(deep, "the state of a block deeper than the window is let go of")
        let prefix = storage.scopes.stateWindowPrefix(at: ["Nexus"])
        let heights = try await storage.broker.retainedScopes(prefix: prefix).compactMap { UInt64($0.dropFirst(prefix.count)) }
        let tip = try await storage.store.blockFact(blocks[6], at: ["Nexus"])
        let height = try XCTUnwrap(tip?.blockHeight)
        XCTAssertTrue(heights.allSatisfy { $0 + 2 >= height }, "the window holds heights within it: \(heights)")
        await runtime.stop()
    }

    /// `cid` lost: let go of by every scope, then swept, as by an earlier
    /// run that lost it.
    private func lose(_ cid: String, in storage: NodeStorage) async throws {
        for scope in try await storage.broker.retainedScopes(prefix: storage.scopes.chain) {
            guard try await storage.broker.retainedRoots(scope: scope).contains(cid) else { continue }
            _ = try await storage.broker.releaseRetainedRoots(scope: scope, roots: [cid])
        }
        _ = try await storage.broker.sweep()
        let held = await storage.broker.hasVolume(root: cid)
        XCTAssertFalse(held, "the node is lost")
    }

    /// What each node of the state of `block` names, read from this store.
    private func stateTree(of block: String, in storage: NodeStorage) async throws -> [String: [String]] {
        let fact = try await storage.store.blockFact(block, at: ["Nexus"])
        let state = try await LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID))
            .resolveRecursive(fetcher: storage.localFetcher)
        var tree: [String: [String]] = [:]
        func walk(_ header: any Header) {
            guard tree[header.rawCID] == nil, let node = header.node else { return }
            let children = node.properties().sorted().compactMap { node.get(property: $0) }
            tree[header.rawCID] = children.map(\.rawCID)
            for child in children { walk(child) }
        }
        walk(state)
        return tree
    }

    /// The kept state at the end of a heal: counted whole, marked so, the
    /// heal's pins let go of, and the state scope pinning what is counted.
    private func assertHealed(_ tip: String, _ storage: NodeStorage) async throws {
        try await eventually("the state is healed from the peer and counted whole") {
            guard let whole = try await self.stateNodes(of: tip, in: storage) else { return false }
            let counted = try await storage.store.stateCounts(at: ["Nexus"]) == whole
            let marked = try await storage.store.stateWhole(at: ["Nexus"])
            return counted && marked
        }
        try await eventually("the heal's pins are let go of") {
            try await storage.broker.retainedRoots(scope: storage.scopes.stateHeal(at: ["Nexus"])).isEmpty
        }
        let pinned = Set(try await storage.broker.retainedRoots(scope: storage.scopes.state(at: ["Nexus"])))
        let counted = Set(try await storage.store.stateCounts(at: ["Nexus"]).keys)
        XCTAssertEqual(pinned, counted, "the state scope pins exactly what is counted")
    }

    /// A store from before the state window, which lost a node of its tip's
    /// state (the testnet host that refused claims): its start heals the
    /// state from a peer, with no block reading it, and then a transaction
    /// passes this node's preflight, which reads this store alone.
    func testAStartHealsAStoreThatLostKeptState() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try host(keyByte: 0xbc)
        let (producerRuntime, _) = try await start(producer)
        var tip = ""
        for _ in 0..<3 { tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID }

        var node = try host(keyByte: 0xbd, peers: [producer.endpoint], state: .tip)
        var lost = ""
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await assertKeepsExactlyTheStateOf(tip, storage, "before the loss")
            try await eventually("the first heal ends") { try await storage.store.stateWhole(at: ["Nexus"]) }
            await runtime.stop()
            let fact = try await storage.store.blockFact(tip, at: ["Nexus"])
            let root = try XCTUnwrap(fact?.postStateCID)
            let counts = try await storage.store.stateCounts(at: ["Nexus"])
            lost = try XCTUnwrap(counts.keys.sorted().first { $0 != root && counts[$0] == 1 })
            try await storage.store.setStateWhole(false, at: ["Nexus"])
            try await lose(lost, in: storage)
            let whole = try await stateNodes(of: tip, in: storage)
            XCTAssertNil(whole, "the tip's state is not whole")
        }
        node = try host(
            keyByte: 0xbd, peers: [producer.endpoint], storageDirectory: node.configuration.storagePath, state: .tip
        )
        let (runtime, storage) = try await start(node)
        try await assertHealed(tip, storage)
        let held = await storage.broker.hasVolume(root: lost)
        XCTAssertTrue(held, "the lost node is held again")
        _ = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(payer, nonce: 0, moves: [(address(payer), -1)])
        ))
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A node of the kept state lost while no peer has it, with what it
    /// names still held: runs that cannot heal keep what sits below it,
    /// across restarts that sweep, and stay marked as not whole. A run with
    /// a peer heals it.
    func testWhatALostNodeNamesStaysUntilAPeerHealsIt() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try host(keyByte: 0xbe)
        let (producerRuntime, _) = try await start(producer)
        var tip = ""
        for _ in 0..<4 { tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID }

        var node = try host(keyByte: 0xbf, peers: [producer.endpoint], state: .tip)
        var below: [String] = []
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await eventually("the first heal ends") { try await storage.store.stateWhole(at: ["Nexus"]) }
            await runtime.stop()
            let fact = try await storage.store.blockFact(tip, at: ["Nexus"])
            let root = try XCTUnwrap(fact?.postStateCID)
            let counts = try await storage.store.stateCounts(at: ["Nexus"])
            let tree = try await stateTree(of: tip, in: storage)
            // An interior node, named once, whose children are named once too.
            let lost = try XCTUnwrap(tree.keys.sorted().first { cid in
                cid != root && counts[cid] == 1 && !(tree[cid] ?? []).isEmpty
                    && (tree[cid] ?? []).allSatisfy { counts[$0] == 1 }
            }, "an interior node of the state")
            below = tree[lost] ?? []
            try await storage.store.setStateWhole(false, at: ["Nexus"])
            try await lose(lost, in: storage)
        }
        for run in 1...2 {
            node = try host(keyByte: 0xbf, storageDirectory: node.configuration.storagePath, state: .tip)
            let (runtime, storage) = try await start(node)
            let deadline = ContinuousClock.now + .seconds(2)
            try await eventually("run \(run) tries to heal") { ContinuousClock.now > deadline }
            await runtime.stop()
            let whole = try await storage.store.stateWhole(at: ["Nexus"])
            XCTAssertFalse(whole, "run \(run): the state is not marked whole")
            for cid in below {
                let held = await storage.broker.hasVolume(root: cid)
                XCTAssertTrue(held, "run \(run): what the lost node names stays")
            }
        }
        node = try host(
            keyByte: 0xbf, peers: [producer.endpoint], storageDirectory: node.configuration.storagePath, state: .tip
        )
        let (runtime, storage) = try await start(node)
        try await assertHealed(tip, storage)
        await runtime.stop()
        await producerRuntime.stop()
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
            // The tip is published within the step that executed it; what it
            // read is let go of at the end of that step.
            try await eventually("nothing a block read is held once it has executed") {
                (try? await storage.broker.retainedScopes(prefix: storage.scopes.chain + ":reads:"))?.isEmpty == true
            }
            for block in blocks.dropLast() {
                let state = try await stateNodes(of: block, in: storage)
                XCTAssertNil(state, "an older block's state is not held")
            }
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

    /// A start on `tip` over a large state, then blocks that set a value
    /// back to one a block before them replaced: the node that value is
    /// stays, the kept state is the tip's exactly, and the value can be
    /// written again.
    func testAValueSetBackWhileTheKeptStateMovesBehindTheTipStays() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        var node = try host(keyByte: 0xbe)
        var nonce: UInt64 = 0
        do {
            let (runtime, _) = try await start(node)
            _ = try await runtime.mineBlock(paid)
            _ = try await runtime.mineBlock(paid)
            for _ in 0..<3 {
                let accounts = (0..<500).map { _ in (address(CryptoUtils.generateKeyPair()), Int64(1)) }
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(miner, nonce: nonce, moves: accounts + [(address(miner), -500)])
                ))
                nonce += 1
                _ = try await runtime.mineBlock(paid)
            }
            _ = try await runtime.submitTransaction(SubmitTransactionRequest(
                transaction: try transaction(miner, nonce: nonce, actions: [Action(key: "t", oldValue: nil, newValue: "0")])
            ))
            nonce += 1
            _ = try await runtime.mineBlock(paid)
            await runtime.stop()
        }
        node = try host(keyByte: 0xbe, storageDirectory: node.configuration.storagePath, state: .tip)
        let (runtime, storage) = try await start(node)
        var (value, tip) = ("0", "")
        for next in ["1", "2", "1", "9"] {
            _ = try await runtime.submitTransaction(SubmitTransactionRequest(
                transaction: try transaction(miner, nonce: nonce, actions: [Action(key: "t", oldValue: value, newValue: next)])
            ))
            nonce += 1
            tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
            value = next
        }
        try await assertKeepsExactlyTheStateOf(tip, storage, "after the values were set back")
        XCTAssertEqual(runtime.published.value?.mempoolCount, 0, "every write of the value is mined")
        await runtime.stop()
    }

    /// A node on `none` follows a chain whose blocks delete keys and empty
    /// accounts: a deletion merges a node's neighbour into its parent, and
    /// the neighbour, which no block's read set names, is read from a peer.
    func testANodeOnNoneFollowsBlocksThatDeleteState() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let producer = try host(keyByte: 0xc4)
        let (producerRuntime, _) = try await start(producer)
        var nonce: UInt64 = 0
        var payees: [Key] = []
        var tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID
        tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID
        for round in 0..<40 {
            let payee: Key = CryptoUtils.generateKeyPair()
            payees.append(payee)
            var actions = [Action(key: "k\(round)", oldValue: nil, newValue: "v\(round)")]
            if round >= 3 { actions.append(Action(key: "k\(round - 3)", oldValue: "v\(round - 3)", newValue: nil)) }
            _ = try await producerRuntime.submitTransaction(SubmitTransactionRequest(transaction: try transaction(
                miner, nonce: nonce, moves: [(address(miner), -4), (address(payee), 3)], actions: actions
            )))
            nonce += 1
            if round >= 4, round % 4 == 0 {
                // An earlier payee spends all it has.
                let drained = payees[round - 4]
                _ = try await producerRuntime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(drained, nonce: 0, moves: [(address(drained), -3), (address(miner), 2)])
                ))
            }
            tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID
        }
        XCTAssertEqual(producerRuntime.published.value?.mempoolCount, 0)

        let node = try host(keyByte: 0xc5, peers: [producer.endpoint], state: .none)
        let (runtime, _) = try await start(node)
        try await eventually("the node on none executes every block") { runtime.published.value?.actOnTip == tip }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A run on `none` between runs on `tip` lets the tip's state go: the
    /// next run on `tip` counts afresh what it holds.
    func testARunOnNoneBetweenRunsOnTipLeavesNoStaleCounts() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        var node = try host(keyByte: 0xc6, state: .tip)
        for (round, state) in [StateRetention.tip, .none, .tip].enumerated() {
            node = try host(keyByte: 0xc6, storageDirectory: node.configuration.storagePath, state: state)
            let (runtime, storage) = try await start(node)
            var tip = ""
            for _ in 0..<3 { tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID }
            if state == .tip {
                try await eventually("the kept state is moved to the tip (run \(round))") {
                    try await storage.store.stateTip(at: ["Nexus"]) == tip
                }
                let counted = try await storage.store.stateCounts(at: ["Nexus"])
                let held = try await heldStateNodes(of: tip, in: storage)
                XCTAssertEqual(counted, held, "run \(round)")
            } else {
                let counted = try await storage.store.stateCounts(at: ["Nexus"])
                XCTAssertEqual(counted, [:], "a run on none counts nothing")
            }
            await runtime.stop()
        }
    }

    /// Whatever ran before, the state scope of a node on `tip` pins exactly
    /// what it counts, and it counts what it holds of the tip's state:
    /// after a run on `none` and a block that reads state without changing
    /// it, and after a run on `all` between runs on `tip`.
    func testTheStateScopePinsExactlyWhatIsCounted() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        var node = try host(keyByte: 0xc8)
        var nonce: UInt64 = 0
        func check(_ runtime: NodeRuntime, _ storage: NodeStorage, _ phase: String) async throws {
            let tip = try XCTUnwrap(runtime.published.value?.actOnTip)
            try await eventually("the kept state is moved to the tip (\(phase))") {
                try await storage.store.stateTip(at: ["Nexus"]) == tip
            }
            let counted = try await storage.store.stateCounts(at: ["Nexus"])
            let held = try await heldStateNodes(of: tip, in: storage)
            XCTAssertEqual(counted, held, phase)
            // What left the state is let go of after the counts commit.
            try await eventually("\(phase): pinned is what is counted") {
                let pinned = try await storage.broker.retainedRoots(scope: storage.scopes.state(at: ["Nexus"]))
                return Set(pinned) == Set(counted.keys)
            }
        }
        for (phase, state) in [("tip", StateRetention.tip), ("all", .all), ("tip again", .tip), ("none", .none), ("tip after none", .tip)] {
            node = try host(keyByte: 0xc8, storageDirectory: node.configuration.storagePath, state: state)
            let (runtime, storage) = try await start(node)
            if nonce == 0 {
                _ = try await runtime.mineBlock(paid)
                _ = try await runtime.mineBlock(paid)
            }
            _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: try transaction(
                miner, nonce: nonce, actions: [Action(key: "a\(nonce)", oldValue: nil, newValue: "1")]
            )))
            nonce += 1
            _ = try await runtime.mineBlock(paid)
            if state == .tip {
                try await check(runtime, storage, phase)
                // A block that reads state and changes nothing.
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: try transaction(
                    miner, nonce: nonce, actions: [Action(key: "a0", oldValue: "1", newValue: "1")]
                )))
                nonce += 1
                _ = try await runtime.mineBlock(paid)
                try await check(runtime, storage, "\(phase), after a block that changes nothing")
            }
            await runtime.stop()
        }
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
