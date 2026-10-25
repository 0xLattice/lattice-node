import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import LatticeNodeSim
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

    /// The read cache keeps whole the Volumes a body's fetch derived, and
    /// on their own the entries a read asked for (never what else a peer
    /// sent), within the bound: the least recently read go first, what is
    /// put again replaces what is held, and one larger than the bound is
    /// not kept.
    func testTheReadCacheKeepsRecentContentWithinItsBound() async throws {
        let volume = { (name: String, byte: UInt8) in
            SerializedVolume(root: name, entries: [
                name: Data(repeating: byte, count: 100), name + "-leaf": Data(repeating: byte, count: 100),
            ])
        }
        let charge = { (name: String) in 2 * 100 + 2 * IvyRootContentSource.retainedEntryOverhead + 2 * name.utf8.count + 5 }
        let cache = ReadCache(maximumBytes: 2 * charge("a"))

        await cache.put([volume("a", 7)], block: "a")
        await cache.put([volume("b", 7)], block: "b")
        let both = await cache.fetch(["a", "a-leaf", "b-leaf"])
        XCTAssertEqual(Set(both.keys), ["a", "a-leaf", "b-leaf"])

        // "b" was read after "a" above; reading "a" again makes "b" the least recent.
        _ = await cache.fetch(["a"])
        await cache.put([volume("c", 7)], block: "c")
        let afterThird = await cache.fetch(["a", "b", "c"])
        XCTAssertEqual(Set(afterThird.keys), ["a", "c"])
        let kept = await cache.volume("a")
        XCTAssertEqual(kept?.entries, volume("a", 7).entries, "a Volume is kept whole")
        var held = await cache.heldBytes
        XCTAssertLessThanOrEqual(held, 2 * charge("a"))

        // Put again, a Volume replaces the one held under its root.
        await cache.put([volume("a", 9)], block: "a")
        let replaced = await cache.volume("a")
        XCTAssertEqual(replaced?.entries, volume("a", 9).entries)
        held = await cache.heldBytes
        XCTAssertLessThanOrEqual(held, 2 * charge("a"))

        // One larger than the bound is not kept, and evicts nothing.
        let large = SerializedVolume(root: "large", entries: ["large": Data(repeating: 9, count: 4 * charge("a"))])
        await cache.put([large], block: "large")
        let afterLarge = await cache.fetch(["a", "c", "large"])
        XCTAssertEqual(Set(afterLarge.keys), ["a", "c"])
        held = await cache.heldBytes
        XCTAssertLessThanOrEqual(held, 2 * charge("a"))

        // Bodies go furthest from their chain's next block to connect
        // first, whatever was read last; a block in no window before any.
        let ordered = ReadCache(maximumBytes: 2 * charge("a"))
        await ordered.order(bodies: ["a": 0, "b": 1, "c": 2])
        await ordered.put([volume("a", 7)], block: "a")
        await ordered.put([volume("b", 7)], block: "b")
        _ = await ordered.fetch(["a"])
        await ordered.put([volume("c", 7)], block: "c")
        let furthestNotKept = await ordered.fetch(["a", "b", "c"])
        XCTAssertEqual(Set(furthestNotKept.keys), ["a", "b"], "the furthest ahead is not kept over nearer ones")
        await ordered.order(bodies: ["b": 0, "c": 1])
        await ordered.put([volume("c", 7)], block: "c")
        let connectedFirst = await ordered.fetch(["a", "b", "c"])
        XCTAssertEqual(Set(connectedFirst.keys), ["b", "c"], "a block in no window goes first")
        await ordered.order(bodies: ["d": 0, "b": 1, "c": 2])
        await ordered.put([volume("d", 7)], block: "d")
        let nextKept = await ordered.fetch(["b", "c", "d"])
        XCTAssertEqual(Set(nextKept.keys), ["b", "d"], "the next to connect evicts the furthest ahead")

        // A read keeps only the entries it asked for, and none of them is a
        // Volume: a peer chooses what it sends with one.
        struct Peer: ContentSource {
            let held: [String: Data]
            func fetch(_ cids: Set<String>) async -> [String: Data] { held }
        }
        let reads = ReadCache(maximumBytes: 2 * charge("a"))
        let padded = reads.remembering(Peer(held: ["r": Data(repeating: 1, count: 10), "x": Data(repeating: 2, count: 10)]))
        let answer = await padded.fetch(["r"])
        XCTAssertEqual(answer.count, 2)
        let remembered = await reads.fetch(["r", "x"])
        XCTAssertEqual(Set(remembered.keys), ["r"])
        let asVolume = await reads.volume("r")
        XCTAssertNil(asVolume)
    }

    /// Making room keeps what the brute-force scan over every held item
    /// kept, over a random run of orders, puts and reads; and an entry that
    /// cannot fit while every held body is in a window is refused without
    /// looking at the bodies.
    func testTheReadCacheEvictsAsAFullScanWould() async throws {
        let overhead = IvyRootContentSource.retainedEntryOverhead
        let charge = { (entries: [String: Data]) in
            entries.reduce(0) { $0 + $1.key.utf8.count + $1.value.count + overhead }
        }
        typealias Rank = (Int, Int, UInt64)
        // The eviction rule before running counters: every candidate scanned
        // for each item evicted.
        struct Scan {
            let maximumBytes: Int
            var clock: UInt64 = 0
            var distances: [String: Int] = [:]
            var bodies: [String: (cids: [String: Data], bytes: Int, read: UInt64)] = [:]
            var entries: [String: (data: Data, bytes: Int, read: UInt64)] = [:]
            var bytes: Int {
                bodies.values.reduce(0) { $0 + $1.bytes } + entries.values.reduce(0) { $0 + $1.bytes }
            }
            var cids: Set<String> { Set(bodies.values.flatMap(\.cids.keys) + entries.keys) }
            func rank(body block: String, read: UInt64) -> Rank {
                guard let distance = distances[block] else { return (2, 0, UInt64.max - read) }
                return (0, distance, UInt64.max - read)
            }
            mutating func makeRoom(_ charge: Int, for rank: Rank) -> Bool {
                guard charge <= maximumBytes else { return false }
                while bytes + charge > maximumBytes {
                    var first: (rank: Rank, body: String?, entry: String?)?
                    for (block, body) in bodies {
                        let candidate = self.rank(body: block, read: body.read)
                        if first.map({ candidate > $0.rank }) ?? true { first = (candidate, block, nil) }
                    }
                    for (cid, entry) in entries {
                        let candidate: Rank = (1, 0, UInt64.max - entry.read)
                        if first.map({ candidate > $0.rank }) ?? true { first = (candidate, nil, cid) }
                    }
                    guard let first, first.rank > rank else { return false }
                    if let block = first.body { bodies[block] = nil }
                    if let cid = first.entry { entries[cid] = nil }
                }
                return true
            }
        }
        for seed in UInt64(0)..<20 {
            var rng = SplitMix64(state: 0xCAC4E + seed)
            let maximumBytes = Int.random(in: 600...2_000, using: &rng)
            let cache = ReadCache(maximumBytes: maximumBytes)
            var scan = Scan(maximumBytes: maximumBytes)
            let blocks = (0..<8).map { "block\($0)" }
            for step in 0..<300 {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    var distances: [String: Int] = [:]
                    for block in blocks where Bool.random(using: &rng) { distances[block] = Int.random(in: 0..<4, using: &rng) }
                    await cache.order(bodies: distances)
                    scan.distances = distances
                case 1:
                    let block = blocks.randomElement(using: &rng)!
                    let volumes = (0..<Int.random(in: 1...3, using: &rng)).map { index in
                        SerializedVolume(root: "\(block)-\(step)-\(index)", entries: [
                            "\(block)-\(step)-\(index)": Data(repeating: 1, count: Int.random(in: 0...300, using: &rng)),
                        ])
                    }
                    await cache.put(volumes, block: block)
                    scan.bodies[block] = nil
                    let all = volumes.reduce(into: [String: Data]()) { $0.merge($1.entries) { $1 } }
                    if scan.makeRoom(charge(all), for: scan.rank(body: block, read: scan.clock + 1)) {
                        scan.clock += 1
                        scan.bodies[block] = (all, charge(all), scan.clock)
                    }
                case 2:
                    var entries: [String: Data] = [:]
                    for _ in 0..<Int.random(in: 1...3, using: &rng) {
                        entries["entry\(Int.random(in: 0..<12, using: &rng))"] = Data(repeating: 2, count: Int.random(in: 0...200, using: &rng))
                    }
                    await cache.put(entries: entries)
                    for (cid, data) in entries {
                        scan.entries[cid] = nil
                        guard scan.makeRoom(charge([cid: data]), for: (1, 0, UInt64.max - (scan.clock + 1))) else { continue }
                        scan.clock += 1
                        scan.entries[cid] = (data, charge([cid: data]), scan.clock)
                    }
                default:
                    let held = Array(scan.cids)
                    let asked = Set(held.filter { _ in Bool.random(using: &rng) } + ["absent"])
                    let found = await cache.fetch(asked)
                    for cid in asked {
                        if scan.entries[cid] != nil {
                            scan.clock += 1
                            scan.entries[cid]?.read = scan.clock
                        } else if let block = scan.bodies.first(where: { $0.value.cids[cid] != nil })?.key {
                            scan.clock += 1
                            scan.bodies[block]?.read = scan.clock
                        }
                    }
                    XCTAssertEqual(Set(found.keys), asked.intersection(held))
                }
                let heldCIDs = await cache.heldCIDs
                let heldBytes = await cache.heldBytes
                XCTAssertEqual(heldCIDs, scan.cids, "seed \(seed) step \(step)")
                XCTAssertEqual(heldBytes, scan.bytes, "seed \(seed) step \(step)")
                if heldCIDs != scan.cids { return }
            }
        }

        // Full of bodies in a window: an entry that cannot fit is refused
        // without looking at them.
        let full = ReadCache(maximumBytes: 3 * charge(["b0": Data(count: 100)]))
        await full.order(bodies: ["b0": 0, "b1": 1, "b2": 2])
        for block in ["b0", "b1", "b2"] {
            await full.put([SerializedVolume(root: block, entries: [block: Data(count: 100)])], block: block)
        }
        let scansBefore = await full.bodyScans
        for index in 0..<50 { await full.put(entries: ["e\(index)": Data(count: 10)]) }
        let scansAfter = await full.bodyScans
        let fullCIDs = await full.heldCIDs
        XCTAssertEqual(scansAfter, scansBefore)
        XCTAssertEqual(fullCIDs, ["b0", "b1", "b2"])
    }
}
