import Foundation
import Ivy
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import BenchVFS
import cashew
import XCTest
@testable import LatticeNode

/// A node keeping recent state and no bodies beyond its working set is
/// crashed below the storage interface: after a number of writes to its
/// files every write, sync and truncate fails (`BenchVFS`, SQLite's own
/// fault-injection shape), as in a process that died there. Swept over the
/// writes of its start, its first sync of the counts, the blocks it follows
/// and a chain it lets go of, the crash lands in a persist, between it and
/// the retention after it, in the start's sweep and in a release. It starts
/// again over the same store: it follows its peer to the tip, its counts
/// match the store, it answers a read of the tip's state, the transaction
/// it acknowledged before the crash is pooled or on the chain, and what the
/// crash left kept is let go of: no executed block's reads, no body but the
/// tip's, no state below the window, nothing staged, nothing of a chain no
/// longer hosted.
final class RetentionCrashTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        XCTAssertEqual(bench_vfs_install(), 0)
    }

    /// The crash, for files under `directory`: after `writes` more writes.
    private enum Crash {
        static func after(_ writes: Int64, under directory: URL) {
            // SQLite opens the files by their real path, links resolved
            // (on macOS the temporary directory is under /private).
            let real = realpath(directory.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? directory.path
            bench_vfs_fail_after(real, writes)
        }

        static var came: Bool { bench_vfs_failed() != 0 }

        static func off() { bench_vfs_fail_off() }
    }

    private typealias Key = (privateKey: String, publicKey: String)

    private func address(_ key: Key) -> String { CryptoUtils.createAddress(from: key.publicKey) }

    private static let alpha = ["Nexus", "Alpha"]

    private func node(
        keyByte: UInt8, directory: URL, peers: [PeerEndpoint], state: StateRetention, bodies: BlockBodies,
        hosted: Bool = false
    ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), webSocket: .off,
            peerSearchInterval: 600, blockBodies: bodies, state: state,
            hostedChildren: hosted ? [Self.alpha] : [],
            childSpecs: hosted ? [Self.alpha: StateWindowTests.alphaSpec] : [:],
            stateWindows: FinalityWindows(all: 2)
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
        )
        return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-crash-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func transaction(_ signer: Key, nonce: UInt64, paying payee: String) throws -> Transaction {
        let header = try HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: address(signer), delta: -2), AccountAction(owner: payee, delta: 1)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(signer)], nonce: nonce, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [signer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: signer.privateKey
            ))],
            body: header
        )
    }

    func testACrashAtAnyWriteRecoversOnTheNextStart() async throws {
        // While the node starts and first syncs its counts.
        for writes: Int64 in [0, 2, 8, 30, 100] {
            try await crashAndRecover(afterWrites: writes, armedAtStart: true)
        }
        // While it follows blocks.
        for writes: Int64 in [0, 1, 2, 3, 5, 8, 13, 21, 34] {
            try await crashAndRecover(afterWrites: writes, armedAtStart: false)
        }
    }

    /// What the node keeps at `path` once its tip is `tip`: no reads of an
    /// executed block, no body of an executed block but the tip's and the
    /// genesis's, no state window below the tip's, and nothing staged.
    private func keepsOnlyWhatItShould(_ storage: NodeStorage, tip: String, at path: [String] = ["Nexus"]) async throws -> Bool {
        let scopes = storage.scopes
        for scope in try await storage.broker.retainedScopes(prefix: scopes.readsPrefix) {
            guard let (at, cid) = scopes.block(named: scope, after: scopes.readsPrefix) else { continue }
            if at == path, try await storage.store.hasExecutedBlock(cid, at: at) { return false }
        }
        for scope in try await storage.broker.retainedScopes(prefix: scopes.bodyPrefix) {
            guard let (at, cid) = scopes.block(named: scope), at == path, cid != tip else { continue }
            if try await storage.store.hasExecutedBlock(cid, at: at), !(try await storage.store.isGenesis(cid, at: at)) {
                return false
            }
        }
        let fact = try await storage.store.blockFact(tip, at: path)
        let height = try XCTUnwrap(fact?.blockHeight)
        let lowest = scopes.window(at: path, height: height - 1)
        let windows = try await storage.broker.retainedScopes(prefix: scopes.windowPrefix(at: path))
        guard windows.allSatisfy({ $0 >= lowest }) else { return false }
        return try await storage.broker.retainedScopes(prefix: scopes.stagingPrefix).isEmpty
    }

    /// Waits until the storage a stopped runtime opened is released.
    private func closed(_ storage: inout NodeStorage?) async throws {
        // Assigned after its declaration: Linux's compiler refuses a weak
        // `let`, and macOS's warns of a weak `var` never assigned.
        weak var released: NodeStorage?
        released = storage
        storage = nil
        try await eventually("the first storage is closed") { released == nil }
    }

    private func crashAndRecover(afterWrites writes: Int64, armedAtStart: Bool) async throws {
        let at = "\(armedAtStart ? "start" : "following"), \(writes) writes"
        let (payer, payee): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try node(keyByte: 0xc1, directory: directory(), peers: [], state: .all, bodies: .all)
        let producerStorage = try await NodeStorage.open(configuration: producer.0)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.0, overlay: producer.1
        )
        var tip = ""
        func mine(_ count: Int) async throws {
            for _ in 0..<count { tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID }
        }
        try await mine(3)

        let followerDirectory = directory()
        let follower = try node(
            keyByte: 0xc2, directory: followerDirectory, peers: [producer.2], state: .recent, bodies: .none
        )
        var acknowledged: String?
        var first: NodeStorage? = try await NodeStorage.open(configuration: follower.0)
        defer { Crash.off() }
        do {
            let storage = try XCTUnwrap(first)
            if armedAtStart { Crash.after(writes, under: followerDirectory) }
            // A crash fail-stops the persist it lands in; the loop ends there.
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: follower.0, overlay: follower.1, failStop: { _ in }, observeJob: nil
            )
            if !armedAtStart {
                try await eventually("\(at): the follower reaches the tip") {
                    runtime.published.value?.actOnTip == tip
                }
                let submitted = try await runtime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(payer, nonce: 0, paying: address(payee))
                ))
                acknowledged = submitted.transactionCID
                Crash.after(writes, under: followerDirectory)
            }
            var polls = 0
            try await eventually("\(at): the crash comes", within: .seconds(60)) {
                if Crash.came { return true }
                polls += 1
                if polls % 20 == 0 {
                    if !armedAtStart { try await mine(1) }
                    runtime.inputs.yield(.maintenance)
                }
                return false
            }
            await runtime.stop()
        }
        Crash.off()
        try await closed(&first)

        try await mine(2)
        let storage = try await NodeStorage.open(configuration: follower.0)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: follower.0, overlay: follower.1)
        var polls = 0
        try await eventually("\(at): after the restart the follower reaches the tip and its counts it", within: .seconds(60)) {
            polls += 1
            if polls % 50 == 0 { runtime.inputs.yield(.maintenance) }
            guard runtime.published.value?.actOnTip == tip else { return false }
            let counted = try await storage.broker.countedState(scope: storage.scopes.counted(at: ["Nexus"]))
            guard let marker = counted.marker, CountedMarker(marker)?.tip.cid == tip else { return false }
            guard await storage.auditCounted(at: ["Nexus"], marker: marker) != nil else { return false }
            return try await self.keepsOnlyWhatItShould(storage, tip: tip)
        }
        let account = await runtime.reads.account(owner: address(payer), blockCID: tip)
        XCTAssertNotNil(account, "\(at): the tip's state answers a read")
        if let acknowledged {
            try await eventually("\(at): the acknowledged transaction is pooled or on the chain") {
                let pooled = try await storage.localTransactions().contains { item in
                    (try? Mempool.cid(of: item.transaction)) == acknowledged
                }
                let onChain = await runtime.reads.account(owner: address(payee), blockCID: tip)?.balance == 1
                return pooled || onChain
            }
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A crash while a chain is let go: after its store went, before or
    /// while its facts go (its local and pooled transactions, its bundles,
    /// then its facts in one transaction). The next start, hosting Nexus
    /// alone, finishes it, and Nexus's counts still match the store.
    func testACrashWhileAChainIsLetGoRecoversOnTheNextStart() async throws {
        for writes: Int64 in [0, 1, 2] {
            try await crashWhileUnhosting(afterWrites: writes)
        }
    }

    private func crashWhileUnhosting(afterWrites writes: Int64) async throws {
        let boundary = "letting Alpha go, \(writes) writes"
        let producer = try node(keyByte: 0xc3, directory: directory(), peers: [], state: .all, bodies: .all, hosted: true)
        let producerStorage = try await NodeStorage.open(configuration: producer.0)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.0, overlay: producer.1
        )
        // Each Alpha block executes before the next template is built, so
        // each Nexus block carries one.
        for _ in 0..<5 {
            let before = await producerRuntime.levelReads[Self.alpha]?.readSnapshot().height
            _ = try await producerRuntime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: ["Nexus"], address: address(CryptoUtils.generateKeyPair())),
                MiningRecipient(chainPath: Self.alpha, address: address(CryptoUtils.generateKeyPair())),
            ]))
            try await eventually("\(boundary): the producer's Alpha executes the block it carried") {
                let height = await producerRuntime.levelReads[Self.alpha]?.readSnapshot().height
                return height.map { h in before.map { h > $0 } ?? true } ?? false
            }
        }
        let produced = await producerRuntime.levelReads[Self.alpha]?.readSnapshot()
        let alphaTip = try XCTUnwrap(produced?.tipCID)
        let nexusTip = try XCTUnwrap(producerRuntime.published.value?.actOnTip)

        let followerDirectory = directory()
        let follower = try node(
            keyByte: 0xc4, directory: followerDirectory, peers: [producer.2], state: .recent, bodies: .none, hosted: true
        )
        var first: NodeStorage? = try await NodeStorage.open(configuration: follower.0)
        defer { Crash.off() }
        do {
            let storage = try XCTUnwrap(first)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: follower.0, overlay: follower.1, failStop: { _ in }, observeJob: nil
            )
            // Counts less than a window below a tip that stopped wait for
            // a maintenance pass (`Retention.settleState`), as on a node.
            var polls = 0
            try await eventually("\(boundary): Alpha's counts reach its tip", within: .seconds(60)) {
                polls += 1
                if polls % 50 == 0 { runtime.inputs.yield(.maintenance) }
                let counted = try await storage.broker(at: Self.alpha).countedState(scope: storage.scopes.counted(at: Self.alpha))
                return counted.marker.flatMap(CountedMarker.init)?.tip.cid == alphaTip
            }
            Crash.after(writes, under: followerDirectory)
            try await runtime.host([])
            let file = followerDirectory.appendingPathComponent("volumes")
                .appendingPathComponent(VolumeStores.fileName(Self.alpha))
            // Its store goes first, then the crash stops the rest.
            try await eventually("\(boundary): the crash comes while Alpha is let go") { Crash.came }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(boundary): its store went first")
            let facts = try await storage.store.chainPaths()
            XCTAssertTrue(facts.contains(Self.alpha), "\(boundary): its facts outlived the crash")
            await runtime.stop()
        }
        Crash.off()
        try await closed(&first)

        let alone = try node(keyByte: 0xc4, directory: followerDirectory, peers: [producer.2], state: .recent, bodies: .none)
        let storage = try await NodeStorage.open(configuration: alone.0)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: alone.0, overlay: alone.1)
        var polls = 0
        try await eventually("\(boundary): after the restart Nexus is at its tip and its counts match", within: .seconds(60)) {
            polls += 1
            if polls % 50 == 0 { runtime.inputs.yield(.maintenance) }
            guard runtime.published.value?.actOnTip == nexusTip else { return false }
            let counted = try await storage.broker.countedState(scope: storage.scopes.counted(at: ["Nexus"]))
            guard let marker = counted.marker, CountedMarker(marker)?.tip.cid == nexusTip else { return false }
            guard await storage.auditCounted(at: ["Nexus"], marker: marker) != nil else { return false }
            return try await !storage.store.chainPaths().contains(Self.alpha)
        }
        // A chain's store holds all it kept: its windows, rules, counts,
        // staging and bodies; its facts went after it.
        let file = followerDirectory.appendingPathComponent("volumes")
            .appendingPathComponent(VolumeStores.fileName(Self.alpha))
        XCTAssertNil(storage.stores.opened(at: Self.alpha), "\(boundary): Alpha has no store open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(boundary): nor a file")
        await runtime.stop()
        await producerRuntime.stop()
    }
}
