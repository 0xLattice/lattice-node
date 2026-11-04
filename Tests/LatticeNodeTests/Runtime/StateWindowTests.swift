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
/// state of its chains and what their recent blocks replaced; on `none`
/// what the last executions read and created. Either reads the rest from
/// peers.
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
        stateWindow: UInt64? = nil, hosted: Bool = false, peerSearchInterval: TimeInterval = 600
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
            peerSearchInterval: peerSearchInterval,
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
    /// account tree's root, which every account read goes through, with the
    /// counts that kept it) is read from a peer when a submitted
    /// transaction's preflight needs it, and the transaction is pooled.
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
            try await storage.broker.dropCountedScope(scope: storage.scopes.counted(at: ["Nexus"]))
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

    /// Every node of the state of `block` with the places it holds in it,
    /// read from this store alone, walked apart from the node's own walk.
    private func places(of block: String, in storage: NodeStorage, at path: [String] = ["Nexus"]) async throws -> [String: Int] {
        let fact = try await storage.store.blockFact(block, at: path)
        let state = try await LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID))
            .resolveRecursive(fetcher: storage.localFetcher)
        var places: [String: Int] = [:]
        func count(_ header: any Header) {
            places[header.rawCID, default: 0] += 1
            guard let node = header.node else { return }
            for property in node.properties() {
                if let child = node.get(property: property) { count(child) }
            }
        }
        count(state)
        return places
    }

    /// The chain's counts and their marker.
    private func counted(_ storage: NodeStorage, at path: [String] = ["Nexus"]) async throws -> (marker: CountedMarker?, counts: [String: Int]) {
        let state = try await storage.broker.countedState(scope: storage.scopes.counted(at: path))
        return (state.marker.flatMap(CountedMarker.init), state.counts)
    }

    /// The oracle: the counts, and what they should be: the places of the
    /// tip's state, walked fresh from this store (so every node of it is
    /// held), plus the places each block above the cursor replaced, on the
    /// tip's chain. Throws when a node or fact is missing or the cursor is
    /// not on the tip's chain.
    fileprivate func oracle(
        _ storage: NodeStorage, at path: [String] = ["Nexus"]
    ) async throws -> (marker: CountedMarker, counts: [String: Int], expected: [String: Int]) {
        let (marker, counts) = try await counted(storage, at: path)
        let at = try XCTUnwrap(marker, "the counts have a marker")
        var expected = try await places(of: at.tip.cid, in: storage, at: path)
        var block = at.tip.cid
        while true {
            let fact = try await storage.store.blockFact(block, at: path)
            let held = try XCTUnwrap(fact)
            if held.blockHeight <= at.cursor.height {
                guard block == at.cursor.cid else { throw TestWaitError.timedOut("the cursor is not on the tip's chain") }
                break
            }
            for (cid, count) in NodeStore.net(held.stateDiff).replaced { expected[cid, default: 0] += count }
            block = try XCTUnwrap(held.parentBlockHash)
        }
        return (at, counts, expected)
    }

    fileprivate func assertCountsHold(
        _ storage: NodeStorage, at path: [String] = ["Nexus"], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (at, counts, expected) = try await oracle(storage, at: path)
        XCTAssertEqual(counts, expected, "counts at \(at.text) \(message)", file: file, line: line)
    }

    /// Whether the counts are moved to `tip` and their cursor is a window
    /// below it, or above that.
    private func settled(_ storage: NodeStorage, at tip: String, path: [String] = ["Nexus"]) async throws -> Bool {
        try await counted(storage, at: path).marker?.tip.cid == tip
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
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            try await assertCountsHold(storage)
            let cursor = try await counted(storage).marker?.cursor.height
            XCTAssertEqual(cursor, 7, "the cursor is a window below the tip")
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

    /// What a block replaced goes once the tip is a window above it: on a
    /// miner on `recent` with a window of 2 whose blocks pay it, the
    /// account tree block 2 produced, which block 3 replaced and the tip's
    /// state does not hold, is held while the tip is 4 and gone at 5,
    /// while the tip's whole state stays.
    func testRecentLetsGoOfWhatABlockReplacedAWindowLater() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xdc, state: .recent, stateWindow: 2)
        let (runtime, storage) = try await start(node)
        var blocks: [String] = []
        for _ in 0..<4 { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
        let fact = try await storage.store.blockFact(blocks[1], at: ["Nexus"])
        let state = try await LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID)).resolve(fetcher: storage.localFetcher)
        let replaced = try XCTUnwrap(state.node).accountState.rawCID
        let tipState = try await places(of: blocks[3], in: storage)
        XCTAssertNil(tipState[replaced], "the tip's state does not hold block 2's account tree")
        try await eventually("the counts reach 4") { try await self.settled(storage, at: blocks[3]) }
        var held = await storage.broker.hasVolume(root: replaced)
        XCTAssertTrue(held, "the tip is 4: block 3 is in the window, and what it replaced is held")
        let tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
        try await eventually("the counts reach 5") { try await self.settled(storage, at: tip) }
        held = await storage.broker.hasVolume(root: replaced)
        XCTAssertFalse(held, "the tip is 5: what block 3 replaced went")
        await runtime.stop()
        try await assertCountsHold(storage)
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
            let tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            return tip
        }
        try await mine()
        let written = try await mine([
            Action(key: "ax", oldValue: nil, newValue: "v"), Action(key: "ay", oldValue: nil, newValue: "w"),
            Action(key: "bx", oldValue: nil, newValue: "v"), Action(key: "by", oldValue: nil, newValue: "w"),
        ])
        let leaf = try VolumeRadixHeaderImpl<String>(node: VolumeRadixNodeImpl<String>(prefix: "x", value: "v", children: [:])).rawCID
        let places = try await places(of: written, in: storage)[leaf]
        XCTAssertEqual(places, 2, "the leaf sits in two places of block 2's state")
        try await mine([Action(key: "ax", oldValue: "v", newValue: "v2")])
        try await mine()
        try await mine()
        var count = try await counted(storage).counts[leaf]
        XCTAssertEqual(count, 1, "in one place still, the leaf is counted once")
        try await mine([Action(key: "bx", oldValue: "v", newValue: "v2")])
        try await mine()
        try await mine()
        count = try await counted(storage).counts[leaf]
        XCTAssertNil(count, "in no place, the leaf is not counted")
        let held = await storage.broker.hasVolume(root: leaf)
        XCTAssertFalse(held, "in no place, the leaf went")
        await runtime.stop()
        try await assertCountsHold(storage)
    }

    /// A store that lacks part of the current state, as one an earlier
    /// version kept only a window of (no counts, swept), syncs it from a
    /// peer at its next start, and keeps it. The sync that ran before the
    /// peer connected runs again once it does, not a maintenance pass (10
    /// minutes here) later.
    func testRecentFillsTheCurrentStateItLacksFromAPeer() async throws {
        let payer: Key = CryptoUtils.generateKeyPair()
        let (producer, producerRuntime, tip) = try await produceAnAccountPaidOnce(keyByte: 0xda, payer: payer)
        let node = try host(keyByte: 0xdb, peers: [producer.endpoint], state: .recent, stateWindow: 2)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            await runtime.stop()
            try await storage.broker.dropCountedScope(scope: storage.scopes.counted(at: ["Nexus"]))
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: tip, in: storage)
            XCTAssertNil(whole, "the store lacks the payer's account, which no block of the window touched")
        }
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the state sync completes and the counts reach the tip") {
                try await self.settled(storage, at: tip)
            }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            try await assertCountsHold(storage, "after a state sync read from a peer")
            let staged = try await storage.broker.retainedRoots(scope: storage.scopes.staging(at: ["Nexus"]))
            XCTAssertEqual(staged, [], "what the sync read is let go of from staging once counted")
        }
        await producerRuntime.stop()
    }

    /// Counts left at block 7 of a chain whose every block pays, with what
    /// blocks 8 and 9 created lost (their windows released, swept): the
    /// move to the tip finds it missing, heals it from a peer (again once
    /// the peer connects, if it was not yet), and moves.
    func testRecentHealsWhatAMoveFindsMissing() async throws {
        let (producer, producerRuntime, blocks) = try await produce(0xf4, paying: CryptoUtils.generateKeyPair(), 9)
        let tip = try XCTUnwrap(blocks.last)
        let node = try host(keyByte: 0xf5, peers: [producer.endpoint], state: .recent, stateWindow: 2)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's blocks") { runtime.published.value?.actOnTip == tip }
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            await runtime.stop()
            // The counts of block 7's state alone, as if the moves to 8
            // and 9 had not happened, and what 8 and 9 stored let go of.
            let (marker, counts) = try await counted(storage)
            let cursor = try XCTUnwrap(marker?.cursor)
            var deltas = try await places(of: cursor.cid, in: storage)
            for (root, count) in counts { deltas[root, default: 0] -= count }
            try await storage.broker.adjustCountedRoots(
                scope: storage.scopes.counted(at: ["Nexus"]), deltas: deltas.filter { $0.value != 0 },
                marker: CountedMarker(cursor: cursor, tip: cursor).text, expectedMarker: marker?.text
            )
            for scope in try await storage.broker.retainedScopes(prefix: storage.scopes.windowPrefix(at: ["Nexus"])) {
                try await storage.release(scope: scope)
            }
            _ = try await storage.broker.sweep()
            let whole = try await stateNodes(of: tip, in: storage)
            XCTAssertNil(whole, "the store lacks what blocks 8 and 9 created")
        }
        let (runtime, storage) = try await start(node)
        try await eventually("the counts heal and reach the tip") { try await self.settled(storage, at: tip) }
        await runtime.stop()
        try await assertCountsHold(storage, "after a heal")
        let cursor = try await counted(storage).marker?.cursor.height
        XCTAssertEqual(cursor, 7, "a heal is no state sync: the cursor stays")
        await producerRuntime.stop()
    }

    /// Two producers' chains from genesis, a shorter and a longer: each
    /// block pays `payee`.
    private func produce(_ keyByte: UInt8, paying payee: Key, _ count: Int) async throws -> (Host, NodeRuntime, [String]) {
        let producer = try host(keyByte: keyByte)
        let (runtime, _) = try await start(producer)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payee))])
        var blocks: [String] = []
        for _ in 0..<count { blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID) }
        return (producer, runtime, blocks)
    }

    /// A reorg deeper than the window: a node on `recent` with a window of
    /// 2 that followed one producer's 4 blocks moves to another's 7 from
    /// genesis. The cursor's block is no longer on its chain, so a state
    /// sync replaces the counts: it ends holding that chain's whole current
    /// state, and none of the state the old counts described.
    func testAReorgDeeperThanTheWindowResyncs() async throws {
        let (first, second): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let (shorter, shorterRuntime, abandoned) = try await produce(0xde, paying: first, 4)
        let (longer, longerRuntime, adopted) = try await produce(0xdf, paying: second, 7)

        var node = try host(keyByte: 0xe0, peers: [shorter.endpoint], state: .recent, stateWindow: 2)
        let counted: String
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node follows the shorter chain") { runtime.published.value?.actOnTip == abandoned[3] }
            try await eventually("the counts reach its tip") { try await self.settled(storage, at: abandoned[3]) }
            await runtime.stop()
            let fact = try await storage.store.blockFact(abandoned[3], at: ["Nexus"])
            let state = try await LatticeStateHeader(rawCID: try XCTUnwrap(fact?.postStateCID)).resolve(fetcher: storage.localFetcher)
            counted = try XCTUnwrap(state.node).accountState.rawCID
        }
        await shorterRuntime.stop()
        node = try host(
            keyByte: 0xe0, peers: [longer.endpoint], storageDirectory: node.configuration.storagePath,
            state: .recent, stateWindow: 2
        )
        let (runtime, storage) = try await start(node)
        try await eventually("the node moves to the longer chain") { runtime.published.value?.actOnTip == adopted[6] }
        try await eventually("the counts reach its tip") { try await self.settled(storage, at: adopted[6]) }
        await runtime.stop()
        await longerRuntime.stop()
        _ = try await storage.broker.sweep()
        try await assertCountsHold(storage, "after a reorg deeper than the window")
        let held = await storage.broker.hasVolume(root: counted)
        XCTAssertFalse(held, "the shorter chain's state the old counts described went")
    }

    /// A reorg within the window is undone, not resynced: a node on
    /// `recent` follows a producer to 3, mines 4' and 5' alone with a
    /// window of 2 (its cursor reaches 3), then meets the producer's longer
    /// chain to 9 with a window of 50. Its counts move down to 3 and up the
    /// other chain, the cursor staying at 3; a state sync would have put it
    /// 6 below the tip the node then had, which is below 3 until the node
    /// is at 9.
    func testAReorgWithinTheWindowIsUndone() async throws {
        let forked = try await forkedStore(keyBytes: (0xe1, 0xe2), aloneWindow: 2, window: 50)
        try await assertCountsHold(forked.storage, "after the reorg")
        let marker = try await counted(forked.storage).marker
        XCTAssertEqual(marker?.tip.cid, forked.main.last)
        XCTAssertEqual(marker?.cursor.cid, forked.main[3], "the cursor stays at the fork point")
    }

    /// One store holding two forks' executed blocks, every node of them
    /// kept by a window wider than both: a producer's chain `main` (genesis,
    /// then 9 blocks) and `fork` (4' and 5', from main's 3), which the node
    /// mined alone (with a window of `aloneWindow`) before meeting the
    /// producer's longer chain again (with `window`). Both write keys and
    /// pay. The runtimes are stopped; `remote` reads only this store then.
    private func forkedStore(
        keyBytes: (UInt8, UInt8), aloneWindow: UInt64 = 50, window: UInt64
    ) async throws -> (storage: NodeStorage, remote: IvyRootContentSource, main: [String], fork: [String]) {
        let miner: Key = CryptoUtils.generateKeyPair()
        let producer = try host(keyByte: keyBytes.0)
        let (producerRuntime, _) = try await start(producer)
        let genesis = try XCTUnwrap(producerRuntime.published.value?.actOnTip)
        func mine(_ runtime: NodeRuntime, nonce: UInt64?, _ actions: [Action], paying payee: Key) async throws -> String {
            if let nonce {
                _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: try transaction(
                    miner, nonce: nonce, moves: [(address(miner), -2), (address(CryptoUtils.generateKeyPair()), 1)], actions: actions
                )))
            }
            return try BlockHeader(node: try await runtime.mineBlock(MiningTemplateRequest(
                recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payee))]
            ))).rawCID
        }
        var main = [genesis]
        main.append(try await mine(producerRuntime, nonce: nil, [], paying: miner))
        main.append(try await mine(producerRuntime, nonce: 0, [
            Action(key: "abc", oldValue: nil, newValue: "1"), Action(key: "abd", oldValue: nil, newValue: "1"),
            Action(key: "xbc", oldValue: nil, newValue: "1"), Action(key: "a", oldValue: nil, newValue: "1"),
        ], paying: miner))
        main.append(try await mine(producerRuntime, nonce: 1, [
            Action(key: "abe", oldValue: nil, newValue: "1"), Action(key: "ab", oldValue: nil, newValue: "1"),
        ], paying: miner))

        let node = try host(keyByte: keyBytes.1, peers: [producer.endpoint], state: .recent, stateWindow: 50)
        do {
            let (runtime, storage) = try await start(node)
            try await eventually("the node executes the producer's 3 blocks") { runtime.published.value?.actOnTip == main[3] }
            try await eventually("the counts reach 3") { try await self.settled(storage, at: main[3]) }
            await runtime.stop()
        }
        var fork: [String] = []
        do {
            let alone = try host(
                keyByte: keyBytes.1, storageDirectory: node.configuration.storagePath, state: .recent, stateWindow: aloneWindow
            )
            let (runtime, storage) = try await start(alone)
            fork.append(try await mine(runtime, nonce: 2, [
                Action(key: "abd", oldValue: "1", newValue: nil), Action(key: "f1", oldValue: nil, newValue: "1"),
            ], paying: CryptoUtils.generateKeyPair()))
            fork.append(try await mine(runtime, nonce: 3, [
                Action(key: "abc", oldValue: "1", newValue: "2"), Action(key: "f2", oldValue: nil, newValue: "1"),
            ], paying: CryptoUtils.generateKeyPair()))
            try await eventually("the counts reach 5'") { try await self.settled(storage, at: fork[1]) }
            await runtime.stop()
        }
        main.append(try await mine(producerRuntime, nonce: 2, [
            Action(key: "abe", oldValue: "1", newValue: nil), Action(key: "abc", oldValue: "1", newValue: nil),
        ], paying: miner))
        main.append(try await mine(producerRuntime, nonce: 3, [
            Action(key: "abc", oldValue: nil, newValue: "1"), Action(key: "xbc", oldValue: "1", newValue: "2"),
        ], paying: miner))
        main.append(try await mine(producerRuntime, nonce: 4, [
            Action(key: "ab", oldValue: "1", newValue: nil), Action(key: "a", oldValue: "1", newValue: nil),
        ], paying: miner))
        main.append(try await mine(producerRuntime, nonce: nil, [], paying: miner))
        main.append(try await mine(producerRuntime, nonce: 5, [Action(key: "abd", oldValue: "1", newValue: "3")], paying: miner))
        main.append(try await mine(producerRuntime, nonce: nil, [], paying: miner))
        let rejoined = try host(
            keyByte: keyBytes.1, peers: [producer.endpoint], storageDirectory: node.configuration.storagePath,
            state: .recent, stateWindow: window
        )
        let (runtime, storage) = try await start(rejoined)
        try await eventually("the node moves to the producer's chain") { runtime.published.value?.actOnTip == main[9] }
        try await eventually("the counts reach 9") { try await self.settled(storage, at: main[9]) }
        await runtime.stop()
        await producerRuntime.stop()
        return (storage, IvyRootContentSource(ivy: runtime.ivy, policy: rejoined.configuration.resourcePolicy), main, fork)
    }

    /// The oracle over every move the counts make, on one store with two
    /// forks: extending a block at a time, a reorg to the other fork within
    /// the window, a jump of several blocks, the tip back down to the fork
    /// point, the window shrinking and growing (as across a restart), a
    /// settle that wrote nothing (a store failure, or a stop before the
    /// write: the next one moves from the marker), counts the store refuses
    /// (a count taken below 0, a stale marker) and a fork below the cursor,
    /// both answered by a state sync; then a seeded random walk over every
    /// block and windows of 1 to 6. After each move the counts are the
    /// places of the tip's state plus what the blocks above the cursor
    /// replaced.
    func testTheCountsFollowEveryMoveOfTheTip() async throws {
        let forked = try await forkedStore(keyBytes: (0xe3, 0xe4), window: 50)
        let (main, fork) = (forked.main, forked.fork)
        let counts = CountsDriver(test: self, storage: forked.storage, remote: forked.remote)
        func isResync(_ outcome: CountedOutcome) -> Bool { if case .resync = outcome { true } else { false } }
        func isSettled(_ outcome: CountedOutcome) -> Bool { if case .settled = outcome { true } else { false } }

        // From block 1's state.
        try await counts.resync(main[1], 1)
        var at = try await counts.cursor()
        XCTAssertEqual(at, main[1])
        // A block at a time.
        for block in main[2...5] { try await counts.settle(block, 50) }
        // A reorg within the window, to the other fork.
        try await counts.settle(fork[1], 50)
        // A jump of several blocks, back to the first fork.
        try await counts.settle(main[9], 50)
        // Back down to the fork point, and up again, walking the counts'
        // chain again instead of the one the last move left.
        try await counts.settle(main[3], 50)
        try await counts.settle(fork[0], 50, forget: true)
        // A window shrunk: the cursor moves to 6.
        try await counts.settle(main[9], 3)
        at = try await counts.cursor()
        XCTAssertEqual(at, main[6])
        // A window grown: the cursor stays.
        try await counts.settle(main[8], 50)
        at = try await counts.cursor()
        XCTAssertEqual(at, main[6])
        // A settle to 9 that wrote nothing; the next one, to 9 with a
        // window of 2, moves from the marker.
        try await counts.settle(main[9], 2)
        // A fork below the cursor, and a tip below it: a state sync.
        var outcome = try await counts.settle(fork[1], 2)
        XCTAssertTrue(isResync(outcome), "a fork below the cursor")
        outcome = try await counts.settle(main[5], 2)
        XCTAssertTrue(isResync(outcome), "a tip below the cursor")
        try await counts.resync(fork[1], 4)
        // A stale marker: the store's is read again, and the move made
        // from it.
        let stale = try await counts.marker()
        try await counts.settle(main[9], 4)
        outcome = try await counts.settle(main[8], 4, marker: stale)
        XCTAssertTrue(isSettled(outcome), "a stale marker is read again from the store")
        // A count taken below 0: the state root of the cursor's block,
        // which the block above it replaced, uncounted behind the node's
        // back; moving the cursor past that block is refused.
        try await counts.settle(main[9], 4)
        let cursorNow = try await counts.cursor()
        let below = try XCTUnwrap(cursorNow)
        let fact = try await forked.storage.store.blockFact(below, at: ["Nexus"])
        let root = try XCTUnwrap(fact?.postStateCID)
        let current = try await counts.marker()
        try await forked.storage.broker.adjustCountedRoots(
            scope: forked.storage.scopes.counted(at: ["Nexus"]), deltas: [root: -1], marker: current, expectedMarker: current
        )
        outcome = try await counts.settle(main[9], 2, check: false)
        XCTAssertTrue(isResync(outcome), "a count taken below 0")
        try await counts.resync(main[9], 2)

        // A seeded random walk, the chain the last move left forgotten now
        // and then.
        var random = SeededGenerator(seed: 0x5eed)
        let blocks = main + fork
        for _ in 0..<40 {
            let tip = blocks[Int.random(in: 0..<blocks.count, using: &random)]
            let window = UInt64.random(in: 1...6, using: &random)
            switch try await counts.settle(tip, window, forget: Bool.random(using: &random)) {
            case .settled: break
            case .resync: try await counts.resync(tip, window)
            case .missing(let roots): XCTFail("every node is held: \(roots)")
            case .failed(let reason): XCTFail(reason)
            }
        }
    }

    /// Lattice's case of a diff that was not exact on a radix split: the
    /// general state holds `aaa` and `aaab`, a block inserts `aab` (which
    /// splits the node `aaa` and `aaab` share), and the next updates `aaab`.
    /// The counts follow both blocks without a state sync.
    func testTheCountsFollowARadixSplit() async throws {
        try XCTSkipIf(true, "enabled with Lattice 56.1.2, whose diffs are exact on a radix split")
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xf8, state: .recent, stateWindow: 50)
        let (runtime, storage) = try await start(node)
        var blocks = [try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID]
        for (nonce, actions) in [
            [Action(key: "aaa", oldValue: nil, newValue: "1"), Action(key: "aaab", oldValue: nil, newValue: "3")],
            [Action(key: "aab", oldValue: nil, newValue: "3")],
            [Action(key: "aaab", oldValue: "3", newValue: "2")],
        ].enumerated() {
            _ = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: try transaction(
                miner, nonce: UInt64(nonce), moves: [(address(miner), -1)], actions: actions
            )))
            blocks.append(try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID)
        }
        let tip = try XCTUnwrap(blocks.last)
        try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
        await runtime.stop()
        let counts = CountsDriver(
            test: self, storage: storage,
            remote: IvyRootContentSource(ivy: runtime.ivy, policy: node.configuration.resourcePolicy)
        )
        try await counts.resync(blocks[0], 1)
        for block in blocks.dropFirst() {
            let outcome = try await counts.settle(block, 50)
            guard case .settled = outcome else { return XCTFail("the counts follow \(block): \(outcome)") }
        }
    }

    /// At a start the counts are checked against the store: counts that
    /// count a node once too often (as a rollback, or a fault, may leave
    /// them) are found, and a state sync replaces them.
    func testAStartChecksTheCountsAndResyncsWrongOnes() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xf9, state: .recent, stateWindow: 2)
        do {
            let (runtime, storage) = try await start(node)
            var tip = ""
            for _ in 0..<4 { tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID }
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            await runtime.stop()
            let fact = try await storage.store.blockFact(tip, at: ["Nexus"])
            let root = try XCTUnwrap(fact?.postStateCID)
            let marker = try await counted(storage).marker?.text
            try await storage.broker.adjustCountedRoots(
                scope: storage.scopes.counted(at: ["Nexus"]), deltas: [root: 1], marker: try XCTUnwrap(marker), expectedMarker: marker
            )
            let wrong = try await oracle(storage)
            XCTAssertNotEqual(wrong.counts, wrong.expected)
        }
        let (runtime, storage) = try await start(node)
        try await eventually("the check finds the counts wrong and a state sync replaces them") {
            let now = try await self.oracle(storage)
            return now.counts == now.expected
        }
        await runtime.stop()
        try await assertCountsHold(storage, "after the start's check")
    }

    /// A child chain behaves as Nexus does: a node hosting Nexus/Alpha on
    /// `recent` with a window of 2 keeps Alpha's last 2 heights and its
    /// whole current state. After its store is swept, with no peer, it
    /// answers a read of an account Alpha paid long ago and pools an Alpha
    /// transaction spending from it. A chain no longer hosted keeps no
    /// window, counts or staging.
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
            try await eventually("Alpha's counts reach its tip") { try await self.settled(storage, at: alphaTip, path: Self.alpha) }
            await runtime.stop()
            _ = try await storage.broker.sweep()
            try await assertCountsHold(storage, at: Self.alpha)
        }
        await producerRuntime.stop()
        let alone = try host(keyByte: 0xd6, storageDirectory: node.configuration.storagePath, state: .recent, stateWindow: 2, hosted: true)
        let (runtime, storage) = try await start(alone)
        try await eventually("the node is at Alpha's tip") {
            await runtime.levelReads[Self.alpha]?.readSnapshot().tipCID == alphaTip
        }
        XCTAssertEqual(runtime.peerCount, 0)
        let read = await runtime.levelReads[Self.alpha]?.account(owner: address(payer), blockCID: alphaTip)?.balance
        XCTAssertEqual(read, paid, "Alpha's account is read from this store")
        let response = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try transaction(payer, nonce: 0, moves: [(address(payer), -1)], chainPath: Self.alpha)
        ))
        XCTAssertEqual(response.mempoolCount, 1, "the Alpha transaction is checked against this store's state, and pooled")
        try await storage.broker.mergeRetainedRoots(
            scope: storage.scopes.staging(at: Self.alpha), roots: [node.configuration.nexusGenesisCID]
        )
        try await runtime.host([])
        let kept = try await windowHeights(storage, at: Self.alpha)
        XCTAssertEqual(kept, [], "a chain no longer hosted keeps no state window")
        let counts = try await storage.broker.countedScopes(prefix: storage.scopes.counted(at: Self.alpha))
        XCTAssertEqual(counts, [], "nor counts")
        let staged = try await storage.broker.retainedRoots(scope: storage.scopes.staging(at: Self.alpha))
        XCTAssertEqual(staged, [], "nor staging")
        await runtime.stop()
    }

    /// A start moves what an earlier version kept a hosted chain's tip
    /// state under into the chain's window at its tip's height, and forgets
    /// that version's counts. What either kept for a chain no longer hosted
    /// goes.
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
        let counts = try await storage.store.legacyStateCountRows()
        XCTAssertEqual(counts, 0, "the counts are forgotten")
        await runtime.stop()
    }

    /// A start on `recent` lets go of the counts of a chain no longer
    /// hosted with its staging, and of the staging of a chain whose counts
    /// have a marker, and hands the loop that marker.
    func testAStartLetsGoOfCountsNoLongerNeeded() async throws {
        let node = try host(keyByte: 0xf6, state: .recent)
        let genesis = node.configuration.nexusGenesisCID
        let storage = try await NodeStorage.open(configuration: node.configuration)
        do {
            let scopes = storage.scopes
            try await storage.broker.adjustCountedRoots(
                scope: scopes.counted(at: ["Nexus", "Gone"]), deltas: [genesis: 1], marker: "0 x 0 x", expectedMarker: nil
            )
            try await storage.broker.mergeRetainedRoots(scope: scopes.staging(at: ["Nexus", "Gone"]), roots: [genesis])
            // Counts of Nexus at its genesis, which hold nothing of its
            // state, but have a marker.
            try await storage.broker.adjustCountedRoots(
                scope: scopes.counted(at: ["Nexus"]), deltas: [genesis: 1], marker: "0 \(genesis) 0 \(genesis)",
                expectedMarker: nil
            )
            try await storage.broker.mergeRetainedRoots(scope: scopes.staging(at: ["Nexus"]), roots: [genesis])
        }
        let markers = await storage.settleCountedScopes(hosted: [["Nexus"]])
        XCTAssertEqual(markers, [["Nexus"]: "0 \(genesis) 0 \(genesis)"])
        let counts = try await storage.broker.countedScopes(prefix: storage.scopes.countedPrefix)
        XCTAssertEqual(counts, [storage.scopes.counted(at: ["Nexus"])], "the counts of a chain no longer hosted go")
        let staging = try await storage.broker.retainedScopes(prefix: storage.scopes.stagingPrefix)
        XCTAssertEqual(staging, [], "with its staging, and the staging of counts with a marker")
    }

    /// Counts kept on `recent` are kept with the chain on `all`, then
    /// dropped: the tip's whole state stays after a sweep. On `none` they
    /// are dropped.
    func testLeavingRecentDropsTheCounts() async throws {
        let miner: Key = CryptoUtils.generateKeyPair()
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(miner))])
        let node = try host(keyByte: 0xf7, state: .recent, stateWindow: 2)
        var tip = ""
        do {
            let (runtime, storage) = try await start(node)
            for _ in 0..<5 { tip = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID }
            try await eventually("the counts reach the tip") { try await self.settled(storage, at: tip) }
            await runtime.stop()
        }
        for state in [StateRetention.all, .none] {
            let next = try host(keyByte: 0xf7, storageDirectory: node.configuration.storagePath, state: state)
            let (runtime, storage) = try await start(next)
            try await eventually("the node is at the tip") { runtime.published.value?.actOnTip == tip }
            await runtime.stop()
            let counts = try await storage.broker.countedScopes(prefix: storage.scopes.countedPrefix)
            XCTAssertEqual(counts, [], "no counts on \(state)")
            if state == .all {
                _ = try await storage.broker.sweep()
                let whole = try await stateNodes(of: tip, in: storage)
                XCTAssertNotNil(whole, "what the counts kept is kept with the chain")
            }
        }
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

/// Drives a stopped node's counts as its loop does, and checks them
/// against the oracle after each move that wrote.
private final class CountsDriver {
    let test: StateWindowTests
    let storage: NodeStorage
    let remote: IvyRootContentSource
    let path = ["Nexus"]
    /// The chain the last move left, as the loop keeps it.
    var known: [String]?

    init(test: StateWindowTests, storage: NodeStorage, remote: IvyRootContentSource) {
        (self.test, self.storage, self.remote) = (test, storage, remote)
    }

    func marker() async throws -> String {
        let marker = try await storage.broker.countedState(scope: storage.scopes.counted(at: path)).marker
        return try XCTUnwrap(marker)
    }

    func cursor() async throws -> String? { CountedMarker(try await marker())?.cursor.cid }

    @discardableResult
    func settle(
        _ tip: String, _ window: UInt64, forget: Bool = false, marker given: String? = nil, check: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> CountedOutcome {
        let marker = if let given { given } else { try await marker() }
        let outcome = await storage.settleCounted(
            at: path, tip: tip, window: window, marker: marker, known: forget || given != nil ? nil : known
        )
        if case .settled(_, let next) = outcome {
            known = next
            if check { try await test.assertCountsHold(storage, "settled at \(tip.suffix(6)) w\(window)", file: file, line: line) }
        }
        return outcome
    }

    /// A state sync of a block a few below `tip`, committed moved to it.
    func resync(_ tip: String, _ window: UInt64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let block = try await storage.countedSyncBlock(at: path, below: tip, window: window)
        let places = try await storage.syncCountedState(at: path, block: block, remote: remote)
        let outcome = await storage.commitCounted(at: path, block: block, places: places, tip: tip, window: window)
        guard case .settled(_, let next) = outcome else {
            return XCTFail("the state sync commits: \(outcome)", file: file, line: line)
        }
        known = next
        await storage.releaseStaging(at: path)
        try await test.assertCountsHold(storage, "synced at \(block.height), moved to \(tip.suffix(6))", file: file, line: line)
    }
}

/// SplitMix64: the same walk on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
