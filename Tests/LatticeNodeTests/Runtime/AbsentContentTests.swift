import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// Content a fact names and the store lacks is no fault: the node reads what
/// its own work needs from peers, checked against its CID.
final class AbsentContentTests: XCTestCase {
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
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        storageDirectory reused: URL? = nil,
        hosted: Bool = false
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-absent-\(UUID().uuidString)", isDirectory: true
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
            hostedChildren: hosted ? [Self.alpha] : [],
            childSpecs: hosted ? [Self.alpha: Self.alphaSpec] : [:]
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                bootstrapPeers: peers,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    private func mine(
        _ runtime: NodeRuntime, _ request: MiningTemplateRequest = MiningTemplateRequest()
    ) async throws -> String {
        try BlockHeader(node: try await runtime.mineBlock(request)).rawCID
    }

    private func paying(_ address: String, child: String? = nil) -> MiningTemplateRequest {
        MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address)]
            + (child.map { [MiningRecipient(chainPath: Self.alpha, address: $0)] } ?? []))
    }

    private func address() -> String {
        CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
    }

    private func empty(_ host: Host) {
        for file in ["volumes.db", "volumes.db-wal", "volumes.db-shm"] {
            try? FileManager.default.removeItem(at: host.configuration.storagePath.appendingPathComponent(file))
        }
    }

    /// A node whose Volume store was emptied starts on its facts, builds on
    /// its tip with what a peer serves, keeps what it read, and goes on
    /// following the chain.
    func testANodeWithAnEmptiedVolumeStoreMinesAndFollowsTheChain() async throws {
        let first = address()
        let second = address()
        let producer = try host(keyByte: 0x61)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var tip = ""
        for _ in 0..<3 { tip = try await mine(producerRuntime, paying(first)) }

        let joiner = try host(keyByte: 0x62, peers: [producer.endpoint])
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            await runtime.stop()
        }
        empty(joiner)

        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        XCTAssertEqual(runtime.published.value?.actOnTip, tip, "the facts alone give the tip")
        let held = await storage.volume(tip)
        XCTAssertNil(held, "nothing of the tip's body is held")
        let unread = await runtime.reads.account(owner: first, blockCID: tip)
        XCTAssertNil(unread, "the public reads answer from this store alone")

        // Its tip's spec and state come from the producer once it is reached.
        // What the template read is remembered, not written to the store: a
        // peer decides what it sends with a Volume, and the store's Volumes
        // are only the ones this node derives when it stores a block.
        try await eventually("the joiner builds a template on its tip") {
            (try? await runtime.miningTemplate(self.paying(second))) != nil
        }
        let tipBytes = await storage.blockNodeBytes(tip)
        let state = try XCTUnwrap(tipBytes.flatMap(Block.init(data:))).postState.rawCID
        let unstored = await storage.volume(state)
        XCTAssertNil(unstored, "a template's reads are not written to the store")
        let remembered = await storage.readCache.isEmpty
        XCTAssertFalse(remembered)

        // The producer goes: the block mined on that template needs nothing more from it.
        await producerRuntime.stop()
        let mined = try await mine(runtime, paying(second))
        XCTAssertEqual(runtime.published.value?.actOnTip, mined)
        let stored = await storage.volume(state)
        XCTAssertNotNil(stored, "storing the mined block stores what it names")
        let paid = await runtime.reads.account(owner: second, blockCID: mined)
        XCTAssertNotNil(paid)
        await runtime.stop()
    }

    /// The emptied node's mined block is one its peers execute, and it goes
    /// on executing theirs.
    func testAnEmptiedNodeAndItsPeerFollowEachOther() async throws {
        let first = address()
        let producer = try host(keyByte: 0x68)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var tip = ""
        for _ in 0..<3 { tip = try await mine(producerRuntime, paying(first)) }
        let joiner = try host(keyByte: 0x69, peers: [producer.endpoint])
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            await runtime.stop()
        }
        empty(joiner)
        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        try await eventually("the joiner builds a template on its tip") {
            (try? await runtime.miningTemplate(self.paying(first))) != nil
        }
        let mined = try await mine(runtime, paying(first))
        try await eventually("the producer executes the block the joiner mined") {
            producerRuntime.published.value?.actOnTip == mined
        }

        let next = try await mine(producerRuntime, paying(first))
        try await eventually("the joiner executes the producer's next block") {
            runtime.published.value?.actOnTip == next
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// The Nexus genesis block has no header record, so nothing but the
    /// block itself can stand under block 1: boot stores it again when the
    /// store lacks it.
    func testANodeEmptiedAtItsGenesisTipExecutesTheFirstBlock() async throws {
        let producer = try host(keyByte: 0x64)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        let joiner = try host(keyByte: 0x65, peers: [producer.endpoint])
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            await runtime.stop()
        }
        empty(joiner)

        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let genesis = await storage.volume(joiner.configuration.nexusGenesisCID)
        XCTAssertNotNil(genesis, "every node holds the genesis block")
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        let first = try await mine(producerRuntime)
        try await eventually("the joiner executes block 1 on its genesis") {
            runtime.published.value?.actOnTip == first
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A node that hosts a child chain starts on an emptied store too: the
    /// child's genesis spec is its operator's own, and the blocks a mined
    /// root carries read what they need the same way the root does.
    func testANodeHostingAChildChainStartsAndMinesOnAnEmptiedStore() async throws {
        let producer = try host(keyByte: 0x66, hosted: true)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        // Paid on both chains, so the child has state of its own to be read.
        let paid = paying(address(), child: address())
        var tip = ""
        for _ in 0..<4 { tip = try await mine(producerRuntime, paid) }

        let joiner = try host(keyByte: 0x67, peers: [producer.endpoint], hosted: true)
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            try await eventually("the joiner executes the child chain's tip") {
                // The producer's child level may still be executing its own last block.
                guard let childTip = await producerRuntime.levelReads[Self.alpha]?.readSnapshot().tipCID else {
                    return false
                }
                return await runtime.levelReads[Self.alpha]?.readSnapshot().tipCID == childTip
            }
            await runtime.stop()
        }
        empty(joiner)

        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        try await eventually("the joiner builds a template on its tips") {
            (try? await runtime.miningTemplate(paid)) != nil
        }
        let childBefore = await runtime.levelReads[Self.alpha]?.readSnapshot().height
        let mined = try await mine(runtime, paid)
        XCTAssertEqual(runtime.published.value?.actOnTip, mined)
        try await eventually("the joiner's child chain advances with the block it carried") {
            let height = await runtime.levelReads[Self.alpha]?.readSnapshot().height
            return (height ?? 0) > (childBefore ?? 0)
        }
        try await eventually("the producer executes the block the joiner mined") {
            producerRuntime.published.value?.actOnTip == mined
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A transaction anyone may submit is checked from this store alone:
    /// on a store that lacks the state it needs, nothing is asked of peers
    /// for it, and it stays pooled.
    func testASubmittedTransactionSpendsNoRequestsToPeers() async throws {
        let producer = try host(keyByte: 0x6A)
        let producerStorage = try await NodeStorage.open(configuration: producer.configuration)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.configuration, overlay: producer.overlay
        )
        var tip = ""
        for _ in 0..<3 { tip = try await mine(producerRuntime, paying(address())) }
        let joiner = try host(keyByte: 0x6B, peers: [producer.endpoint])
        do {
            let storage = try await NodeStorage.open(configuration: joiner.configuration)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
            )
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            await runtime.stop()
        }
        empty(joiner)
        let storage = try await NodeStorage.open(configuration: joiner.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: joiner.configuration, overlay: joiner.overlay
        )
        try await eventually("the joiner reaches its peer") { runtime.reads.peerCount() > 0 }

        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: ["Nexus"]
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
        _ = try? await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction))
        try await alwaysDuring("no content is taken from a peer for the check", .milliseconds(300)) {
            await storage.readCache.isEmpty
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// Retaining names content the store may have lost since it was
    /// fetched: what is held is retained, and the rest is no error.
    func testRetainingKeepsWhatIsHeldAndIgnoresWhatIsNot() async throws {
        let node = try host(keyByte: 0x63)
        let storage = try await NodeStorage.open(configuration: node.configuration)
        let genesis = node.configuration.nexusGenesisCID
        let absent = try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: 7, maxStateGrowth: 7, premine: 0,
            targetBlockTime: 7, initialReward: 7, halvingInterval: 7, halfLife: 7
        )).rawCID
        let unheld = await storage.volume(absent)
        XCTAssertNil(unheld)

        try await storage.retainHeld([genesis, absent])

        let retained = try await storage.broker.retainedRoots(scope: storage.retentionScope)
        XCTAssertTrue(retained.contains(genesis))
        XCTAssertFalse(retained.contains(absent))
    }

    /// What a read asked of peers is remembered: only what it asked for,
    /// an answer whole or not at all, and within the bound.
    func testTheReadCacheRemembersOnlyWhatWasAskedWithinItsBound() async throws {
        struct Peer: ContentSource {
            let held: [String: Data]
            func fetch(_ cids: Set<String>) async -> [String: Data] { held }
        }
        let entry = { (name: String) in (name, Data(repeating: 7, count: 100)) }
        let charge = 1 + 100 + IvyRootContentSource.retainedEntryOverhead
        let cache = ReadCache(maximumBytes: 2 * charge)

        // A peer answers with more than it was asked for: none of the rest is kept.
        let padded = cache.remembering(Peer(held: Dictionary(uniqueKeysWithValues: ["a", "x", "y"].map(entry))))
        let answer = await padded.fetch(["a"])
        XCTAssertEqual(answer.count, 3)
        let afterPadding = await cache.fetch(["a", "x", "y"])
        XCTAssertEqual(Set(afterPadding.keys), ["a"])

        // The second answer fits beside the first.
        await cache.put(Dictionary(uniqueKeysWithValues: ["b"].map(entry)))
        let both = await cache.fetch(["a", "b"])
        XCTAssertEqual(Set(both.keys), ["a", "b"])

        // One that would pass the bound starts the cache again, and is kept whole.
        await cache.put(Dictionary(uniqueKeysWithValues: ["c", "d"].map(entry)))
        let afterFull = await cache.fetch(["a", "b", "c", "d"])
        XCTAssertEqual(Set(afterFull.keys), ["c", "d"])

        // One larger than the bound is not kept, and costs nothing held.
        await cache.put(Dictionary(uniqueKeysWithValues: ["e", "f", "g"].map(entry)))
        let afterTooLarge = await cache.fetch(["c", "d", "e", "f", "g"])
        XCTAssertEqual(Set(afterTooLarge.keys), ["c", "d"])
    }
}
