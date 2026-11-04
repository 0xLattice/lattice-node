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

/// `state: recent` and `none`: on `recent` a node keeps the whole current
/// state of each chain and what its last window of blocks replaced; on
/// `none` what its last execution read and created. It reads the rest
/// from peers.
final class StateWindowTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    static let alpha = ["Nexus", "Alpha"]
    static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func host(
        keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil, state: StateRetention = .all,
        stateWindow: UInt64? = nil, hosted: Bool = false
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
            hostedChildren: hosted ? [Self.alpha] : [],
            childSpecs: hosted ? [Self.alpha: Self.alphaSpec] : [:],
            stateWindows: FinalityWindows(all: stateWindow)
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
        _ signer: Key, nonce: UInt64, moves: [(String, Int64)] = [], actions: [Action] = [],
        chainPath: [String] = ["Nexus"]
    ) throws -> Transaction {
        let header = try HeaderImpl(node: TransactionBody(
            accountActions: moves.map { AccountAction(owner: $0.0, delta: $0.1) },
            actions: actions, depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(signer)], nonce: nonce, chainPath: chainPath
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
    private func stateNodes(
        of block: String, in storage: NodeStorage, at path: [String] = ["Nexus"]
    ) async throws -> [String: Int]? {
        let fact = try await storage.store.blockFact(block, at: path)
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

    /// State is a cache: a node of the tip's state this store lost (the
    /// account tree's root, which every account read goes through) is read
    /// from a peer when a submitted transaction's preflight needs it, and
    /// the transaction is pooled.
    func testAPreflightReadsWhatTheStoreLostFromAPeer() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try host(keyByte: 0xc8)
        let (producerRuntime, _) = try await start(producer)
        var tip = ""
        for _ in 0..<3 { tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID }

        var node = try host(keyByte: 0xc9, peers: [producer.endpoint], state: .recent)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            await runtime.stop()
            let fact = try await storage.store.blockFact(tip, at: ["Nexus"])
            let state = try await LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID))
                .resolve(fetcher: storage.localFetcher)
            let accounts = try XCTUnwrap(state.node).accountState.rawCID
            for scope in try await storage.broker.retainedScopes(prefix: storage.scopes.chain) {
                guard try await storage.broker.retainedRoots(scope: scope).contains(accounts) else { continue }
                _ = try await storage.broker.releaseRetainedRoots(scope: scope, roots: [accounts])
            }
            _ = try await storage.broker.sweep()
            let held = await storage.broker.hasVolume(root: accounts)
            XCTAssertFalse(held, "the store lost the account tree's root")
        }
        node = try host(keyByte: 0xc9, peers: [producer.endpoint], storageDirectory: node.configuration.storagePath, state: .recent)
        let (runtime, _) = try await start(node)
        try await eventually("the node is at the tip with a peer") {
            runtime.published.value?.actOnTip == tip && runtime.peerCount > 0
        }
        let response = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(payer, nonce: 0, moves: [(address(payer), -1)])
        ))
        XCTAssertEqual(response.mempoolCount, 1, "the transaction is pooled")
    }


    /// The heights a chain's state window scopes name, in order.
    private func windowHeights(_ storage: NodeStorage, at path: [String] = ["Nexus"]) async throws -> [UInt64] {
        let prefix = storage.scopes.windowPrefix(at: path)
        return try await storage.broker.retainedScopes(prefix: prefix).compactMap { UInt64($0.dropFirst(prefix.count)) }.sorted()
    }

    /// A miner on `recent` with a window of 3 keeps what the executions of
    /// its last 3 blocks stored, each under its height, and lets go of the
    /// rest as its tip moves.
    func testRecentKeepsWhatTheLastWindowOfBlocksStored() async throws {
        let node = try host(keyByte: 0xd0, state: .recent, stateWindow: 3)
        let (runtime, storage) = try await start(node)
        for _ in 0..<8 { _ = try await runtime.mineBlock() }
        let height = try XCTUnwrap(runtime.published.value?.actOnHeight)
        XCTAssertEqual(height, 8)
        try await eventually("the window is the last 3 blocks") {
            try await self.windowHeights(storage) == [6, 7, 8]
        }
        await runtime.stop()
    }

    /// A producer keeping all state whose first block pays `payer` and
    /// whose next 8 pay no one: the payer's account is written at height 1
    /// and no later block touches it. Returns the producer, its runtime,
    /// and its tip.
    private func produceAnAccountPaidOnce(
        keyByte: UInt8, payer: Key
    ) async throws -> (host: Host, runtime: NodeRuntime, tip: String) {
        let producer = try host(keyByte: keyByte)
        let (runtime, _) = try await start(producer)
        _ = try await runtime.mineBlock(MiningTemplateRequest(
            recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))]
        ))
        var tip = ""
        for _ in 0..<8 { tip = try BlockHeader(node: try await runtime.mineBlock()).rawCID }
        return (producer, runtime, tip)
    }

    /// The height of the block whose state the chain's current scope
    /// holds.
    private func currentHeight(_ storage: NodeStorage, at path: [String] = ["Nexus"]) async -> UInt64? {
        await storage.currentStateCursor(at: path)?.height
    }

    /// A node on `recent` with a window of 2 keeps the whole current state:
    /// an account paid at height 1 and untouched by the 8 blocks after is
    /// still held, its block far below the window, after the store is
    /// swept. With no peer at all, the node answers a read of that account
    /// and pools a transaction that spends from it.
    func testRecentKeepsStateNoRecentBlockTouchedAndServesItWithNoPeers() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let (producer, producerRuntime, tip) = try await produceAnAccountPaidOnce(keyByte: 0xd1, payer: payer)
        let produced = await producerRuntime.reads.account(owner: address(payer), blockCID: tip)?.balance
        let paid = try XCTUnwrap(produced)
        XCTAssertGreaterThan(paid, 0)

        let node = try host(keyByte: 0xd2, peers: [producer.endpoint], state: .recent, stateWindow: 2)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await eventually("the window is the last 2 blocks") { try await self.windowHeights(storage) == [8, 9] }
            try await eventually("the current state is the block's a window below the tip") {
                await self.currentHeight(storage) == 7
            }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: tip, in: storage)
            XCTAssertNotNil(whole, "the tip's whole state is held, the payer's account with it")
        }
        await producerRuntime.stop()
        let alone = try host(keyByte: 0xd2, storageDirectory: node.configuration.storagePath, state: .recent, stateWindow: 2)
        let (runtime, _) = try await start(alone)
        try await eventually("the node is at the tip") { runtime.published.value?.actOnTip == tip }
        XCTAssertEqual(runtime.peerCount, 0)
        let read = await runtime.reads.account(owner: address(payer), blockCID: tip)?.balance
        XCTAssertEqual(read, paid, "the account is read from this store")
        let response = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(payer, nonce: 0, moves: [(address(payer), -1)])
        ))
        XCTAssertEqual(response.mempoolCount, 1, "the transaction is checked against this store's state, and pooled")
        await runtime.stop()
    }

    /// A store that lacks part of the current state, as one an earlier
    /// version kept only a window of (no counts, no current scope, swept),
    /// reads it from a peer at its next start and keeps it.
    func testRecentFillsTheCurrentStateItLacksFromAPeer() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let (producer, producerRuntime, tip) = try await produceAnAccountPaidOnce(keyByte: 0xda, payer: payer)
        let node = try host(keyByte: 0xdb, peers: [producer.endpoint], state: .recent, stateWindow: 2)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await eventually("the current state is the block's a window below the tip") {
                await self.currentHeight(storage) == 7
            }
            await runtime.stop()
            try await storage.store.forgetCurrentState(at: ["Nexus"])
            try await storage.release(scope: storage.scopes.current(at: ["Nexus"]))
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: tip, in: storage)
            XCTAssertNil(whole, "the store lacks the payer's account, which no block of the window touched")
        }
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node is at the tip with a peer") {
                runtime.published.value?.actOnTip == tip && runtime.peerCount > 0
            }
            // A walk that found no peer yet is tried again as the tip moves.
            let next = try BlockHeader(node: try await producerRuntime.mineBlock()).rawCID
            try await eventually("the node executes the next block") { runtime.published.value?.actOnTip == next }
            try await eventually("the whole current state is held again") {
                let height = await self.currentHeight(storage)
                return try await self.stateNodes(of: next, in: storage) != nil && height == 8
            }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: next, in: storage)
            XCTAssertNotNil(whole, "what was read from the peer is kept")
        }
        await producerRuntime.stop()
    }

    /// What a block replaced goes once the tip is a window above it: on a
    /// miner on `recent` with a window of 2, the state block 2 produced,
    /// which block 3 replaced, is held while the tip is 4 and gone at 5.
    func testRecentLetsGoOfWhatABlockReplacedAWindowLater() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xdc, state: .recent, stateWindow: 2)
        let (runtime, storage) = try await start(node)
        var blocks: [String] = []
        for _ in 0..<4 { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
        let fact = try await storage.store.blockFact(blocks[1], at: ["Nexus"])
        let replaced = try XCTUnwrap(fact?.postStateCID)
        let stateOf3 = try await storage.store.blockFact(blocks[2], at: ["Nexus"])?.postStateCID
        XCTAssertNotEqual(replaced, stateOf3, "block 3 replaced the state block 2 produced")
        try await eventually("the current state is block 2's") { await self.currentHeight(storage) == 2 }
        var held = await storage.broker.hasVolume(root: replaced)
        XCTAssertTrue(held, "the tip is 4: block 3 is in the window, and what it replaced is held")
        _ = try await runtime.mineBlock(paid)
        try await eventually("the current state is block 3's") { await self.currentHeight(storage) == 3 }
        held = await storage.broker.hasVolume(root: replaced)
        XCTAssertFalse(held, "the tip is 5: what block 3 replaced went")
        await runtime.stop()
    }

    /// A node that sits in two places of the state stays until both are
    /// replaced. Keys `ax`, `bx` hold `v`, and `ay`, `by` hold `w`: the
    /// leaf `x` holding `v` sits under `a` and under `b`. Updating `ax`
    /// leaves it in one place, and it is held a window later; updating `bx`
    /// leaves it in none, and it goes a window after that.
    func testRecentKeepsANodeInTwoPlacesUntilBothAreReplaced() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xdd, state: .recent, stateWindow: 2)
        let (runtime, storage) = try await start(node)
        var nonce: UInt64 = 0
        @discardableResult
        func mine(_ actions: [Action] = []) async throws -> String {
            if !actions.isEmpty {
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(miner, nonce: nonce, moves: [(address(miner), -1)], actions: actions)
                ))
                nonce += 1
            }
            return try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
        }
        try await mine()
        let written = try await mine([
            Action(key: "ax", oldValue: nil, newValue: "v"), Action(key: "ay", oldValue: nil, newValue: "w"),
            Action(key: "bx", oldValue: nil, newValue: "v"), Action(key: "by", oldValue: nil, newValue: "w"),
        ])
        let leaf = try VolumeRadixHeaderImpl<String>(node: VolumeRadixNodeImpl<String>(prefix: "x", value: "v", children: [:])).rawCID
        let places = try await stateNodes(of: written, in: storage)?[leaf]
        XCTAssertEqual(places, 2, "the leaf sits in two places of block 2's state")
        try await mine([Action(key: "ax", oldValue: "v", newValue: "v2")])
        try await mine()
        try await mine()
        try await eventually("the current state is block 3's") { await self.currentHeight(storage) == 3 }
        var held = try await storage.broker.retainedRoots(scope: storage.scopes.current(at: ["Nexus"])).contains(leaf)
        XCTAssertTrue(held, "in one place still, the leaf is in the current state")
        try await mine([Action(key: "bx", oldValue: "v", newValue: "v2")])
        try await mine()
        try await mine()
        try await eventually("the current state is block 6's") { await self.currentHeight(storage) == 6 }
        held = await storage.broker.hasVolume(root: leaf)
        XCTAssertFalse(held, "in no place, the leaf went")
        await runtime.stop()
    }

    /// A reorg deeper than the window: a node on `recent` with a window of
    /// 2 that followed one producer's 4 blocks moves to another's 7 from
    /// genesis. The block its counts describe is no longer on its chain,
    /// so it walks the new chain's state: it ends holding that chain's
    /// whole current state, and none of the state its counts described.
    func testAReorgDeeperThanTheWindowWalksTheNewChainsState() async throws {
        let (first, second): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        func produce(_ keyByte: UInt8, paying payee: Key, _ count: Int) async throws -> (Host, NodeRuntime, [String]) {
            let producer = try host(keyByte: keyByte)
            let (runtime, _) = try await start(producer)
            let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payee))])
            var blocks: [String] = []
            for _ in 0..<count { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
            return (producer, runtime, blocks)
        }
        let (shorter, shorterRuntime, abandoned) = try await produce(0xde, paying: first, 4)
        let (longer, longerRuntime, adopted) = try await produce(0xdf, paying: second, 7)

        var node = try host(keyByte: 0xe0, peers: [shorter.endpoint], state: .recent, stateWindow: 2)
        let counted: String
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node follows the shorter chain") { runtime.published.value?.actOnTip == abandoned[3] }
            try await eventually("the current state is the shorter chain's block 2's") {
                await storage.currentStateCursor(at: ["Nexus"])?.block == abandoned[1]
            }
            await runtime.stop()
            let fact = try await storage.store.blockFact(abandoned[1], at: ["Nexus"])
            let root = try XCTUnwrap(fact?.postStateCID)
            let state = try await LatticeStateHeader(rawCID: root).resolve(fetcher: storage.localFetcher)
            counted = try XCTUnwrap(state.node).accountState.rawCID
        }
        await shorterRuntime.stop()
        node = try host(
            keyByte: 0xe0, peers: [longer.endpoint], storageDirectory: node.configuration.storagePath,
            state: .recent, stateWindow: 2
        )
        let (runtime, storage) = try await start(node)
        try await eventually("the node moves to the longer chain") { runtime.published.value?.actOnTip == adopted[6] }
        try await eventually("the current state is the longer chain's block 5's") {
            await storage.currentStateCursor(at: ["Nexus"])?.block == adopted[4]
        }
        await runtime.stop()
        await longerRuntime.stop()
        _ = try await storage.broker.sweep()
        let whole = try await stateNodes(of: adopted[6], in: storage)
        XCTAssertNotNil(whole, "the longer chain's whole current state is held")
        let held = await storage.broker.hasVolume(root: counted)
        XCTAssertFalse(held, "the shorter chain's state the counts described went")
    }

    /// A child chain behaves as Nexus does: a node hosting Nexus/Alpha on
    /// `recent` with a window of 2 keeps Alpha's last 2 heights and its
    /// whole current state. After its store is swept, with no peer, it
    /// answers a read of an account Alpha paid long ago and pools an Alpha
    /// transaction spending from it. A chain no longer hosted keeps
    /// neither.
    func testAChildChainOnRecentKeepsItsWindowAndItsWholeCurrentState() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let producer = try host(keyByte: 0xd5, hosted: true)
        let (producerRuntime, _) = try await start(producer)
        // The first block carries Alpha's genesis, which pays no one: the
        // payer is paid by Alpha's second block, and no later one.
        // Each Alpha block executes before the next template is built, so
        // each Nexus block carries one.
        for round in 0..<9 {
            let before = await producerRuntime.levelReads[Self.alpha]?.readSnapshot().height
            _ = try await producerRuntime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: ["Nexus"], address: address(CryptoUtils.generateKeyPair())),
                MiningRecipient(chainPath: Self.alpha, address: round == 1 ? address(payer) : address(CryptoUtils.generateKeyPair())),
            ]))
            try await eventually("the producer's Alpha executes the block it carried") {
                let height = await producerRuntime.levelReads[Self.alpha]?.readSnapshot().height
                return height.map { h in before.map { h > $0 } ?? true } ?? false
            }
        }
        let produced = await producerRuntime.levelReads[Self.alpha]?.readSnapshot()
        let (alphaTip, alphaHeight) = (try XCTUnwrap(produced?.tipCID), try XCTUnwrap(produced?.height))
        XCTAssertGreaterThan(alphaHeight, 3, "Alpha grew past the window")
        let paidRead = await producerRuntime.levelReads[Self.alpha]?.account(owner: address(payer), blockCID: alphaTip)
        let paid = try XCTUnwrap(paidRead?.balance)
        XCTAssertGreaterThan(paid, 0)

        let node = try host(keyByte: 0xd6, peers: [producer.endpoint], state: .recent, stateWindow: 2, hosted: true)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes Alpha's tip") {
                await runtime.levelReads[Self.alpha]?.readSnapshot().tipCID == alphaTip
            }
            try await eventually("Alpha's window is its last 2 blocks") {
                try await self.windowHeights(storage, at: Self.alpha) == [alphaHeight - 1, alphaHeight]
            }
            try await eventually("Alpha's current state is its block's a window below its tip") {
                await self.currentHeight(storage, at: Self.alpha) == alphaHeight - 2
            }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: alphaTip, in: storage, at: Self.alpha)
            XCTAssertNotNil(whole, "Alpha's tip's whole state is held")
        }
        await producerRuntime.stop()
        let alone = try host(
            keyByte: 0xd6, storageDirectory: node.configuration.storagePath, state: .recent, stateWindow: 2, hosted: true
        )
        let (runtime, storage) = try await start(alone)
        try await eventually("the node is at Alpha's tip") {
            await runtime.levelReads[Self.alpha]?.readSnapshot().tipCID == alphaTip
        }
        let read = await runtime.levelReads[Self.alpha]?.account(owner: address(payer), blockCID: alphaTip)?.balance
        XCTAssertEqual(read, paid, "Alpha's account is read from this store")
        let response = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(payer, nonce: 0, moves: [(address(payer), -1)], chainPath: Self.alpha)
        ))
        XCTAssertEqual(response.mempoolCount, 1, "the Alpha transaction is checked against this store's state, and pooled")
        try await eventually("Alpha keeps its window across the restart") {
            try await !self.windowHeights(storage, at: Self.alpha).isEmpty
        }
        try await runtime.host([])
        let kept = try await windowHeights(storage, at: Self.alpha)
        XCTAssertEqual(kept, [], "a chain no longer hosted keeps no state window")
        let current = try await storage.broker.retainedScopes(prefix: storage.scopes.current(at: Self.alpha))
        let height = await currentHeight(storage, at: Self.alpha)
        XCTAssertEqual(current, [], "nor its current state")
        XCTAssertNil(height, "and forgets its counts")
        await runtime.stop()
    }

    /// A start moves what an earlier version kept a hosted chain's tip
    /// state under into the chain's window at its tip's height, and forgets
    /// that version's counts. What any kept for a chain no longer hosted
    /// goes: its windows, and its current state and counts.
    func testAStartMovesWhatEarlierVersionsKeptIntoTheWindow() async throws {
        let node = try host(keyByte: 0xd3, state: .recent)
        do {
            let storage = try await NodeStorage.open(configuration: node.configuration)
            let genesis = node.configuration.nexusGenesisCID
            for prefix in storage.scopes.legacyStatePrefixes {
                try await storage.broker.mergeRetainedRoots(scope: prefix + "Nexus", roots: [genesis])
                try await storage.broker.mergeRetainedRoots(scope: prefix + "Nexus/Gone", roots: [genesis])
            }
            try await storage.broker.mergeRetainedRoots(
                scope: storage.scopes.window(at: ["Nexus", "Gone"], height: 5), roots: [genesis]
            )
            try await storage.broker.mergeRetainedRoots(
                scope: storage.scopes.current(at: ["Nexus", "Gone"]), roots: [genesis]
            )
            try await storage.store.writeCurrentState(at: ["Nexus", "Gone"], counts: [genesis: 1], cursor: (5, genesis))
            try await storage.store.writeLegacyStateCount()
        }
        let (runtime, storage) = try await start(node)
        try await eventually("the earlier scopes are moved") {
            var left: [String] = []
            for prefix in storage.scopes.legacyStatePrefixes {
                left += try await storage.broker.retainedScopes(prefix: prefix)
            }
            return left.isEmpty
        }
        let window = try await storage.broker.retainedRoots(scope: storage.scopes.window(at: ["Nexus"], height: 0))
        XCTAssertEqual(window, [node.configuration.nexusGenesisCID], "what they named is in the window at the tip's height")
        let gone = try await windowHeights(storage, at: ["Nexus", "Gone"])
        XCTAssertEqual(gone, [], "nothing is kept for a chain no longer hosted")
        let current = try await storage.broker.retainedScopes(prefix: storage.scopes.current(at: ["Nexus", "Gone"]))
        XCTAssertEqual(current, [], "nor its current state")
        let cursor = await currentHeight(storage, at: ["Nexus", "Gone"])
        XCTAssertNil(cursor, "whose counts are forgotten")
        let counts = try await storage.store.legacyStateCountRows()
        XCTAssertEqual(counts, 0, "the counts are forgotten")
        await runtime.stop()
    }

    /// The default keeps the state of every block, under no window.
    func testANodeOnAllKeepsEveryState() async throws {
        let node = try host(keyByte: 0xb6)
        let (runtime, storage) = try await start(node)
        var blocks: [String] = []
        for _ in 0..<3 { blocks.append(try BlockHeader(node: try await runtime.mineBlock()).rawCID) }
        for block in blocks {
            let state = try await stateNodes(of: block, in: storage)
            XCTAssertNotNil(state)
        }
        let heights = try await windowHeights(storage)
        XCTAssertEqual(heights, [])
        await runtime.stop()
    }

    /// The window each setting gives a chain: 64 unless the operator sets
    /// one, for every chain or for one; one block on `none`; none on `all`.
    func testTheStateWindowIsTheOperatorsWithASaneDefault() throws {
        func configuration(_ state: StateRetention, _ windows: FinalityWindows = FinalityWindows()) throws -> NodeConfiguration {
            try NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: FileManager.default.temporaryDirectory,
                privateKeyHex: String(repeating: "d4", count: 32),
                listenPort: 1, rpcPort: 2, webSocket: .off,
                state: state, stateWindows: windows
            )
        }
        XCTAssertEqual(StateRetention(named: "tip"), .recent, "the earlier name")
        XCTAssertNil(StateRetention(named: "some"))
        XCTAssertEqual(try configuration(.recent).stateWindow(for: ["Nexus"]), 64)
        let set = try configuration(.recent, FinalityWindows(all: 10, byChain: [["Nexus", "Alpha"]: 500]))
        XCTAssertEqual(set.stateWindow(for: ["Nexus"]), 10)
        XCTAssertEqual(set.stateWindow(for: ["Nexus", "Alpha"]), 500)
        XCTAssertEqual(try configuration(.none, FinalityWindows(all: 10)).stateWindow(for: ["Nexus"]), 1)
        XCTAssertNil(try configuration(.all, FinalityWindows(all: 10)).stateWindow(for: ["Nexus"]))
    }
}

extension NodeStore {
    /// A count as an earlier version kept of a tip's state.
    func writeLegacyStateCount() throws {
        _ = try database.execute("INSERT INTO core_meta (key, value) VALUES ('state_pin:Nexus:x', '1')")
        _ = try database.execute("INSERT INTO core_meta (key, value) VALUES ('state_tip:Nexus', 'x')")
    }

    func legacyStateCountRows() throws -> Int {
        try database.rows(
            ChainFactMetadataRow.self,
            "SELECT value FROM core_meta WHERE substr(key, 1, 10) IN ('state_pin:', 'state_tip:')"
        ).count
    }
}
