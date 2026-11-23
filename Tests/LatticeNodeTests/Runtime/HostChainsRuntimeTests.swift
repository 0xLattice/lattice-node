import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon
import LatticeNodeAPI

/// A running node starts and stops hosting a child chain when its operator
/// says so, without a restart: a started level syncs from the peers it
/// already has, a stopped one is gone from reads and its data from the
/// store, and starting it again syncs it again.
final class HostChainsRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let beta = ["Nexus", "Beta"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )
    static let betaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 20, halvingInterval: 10_000, halfLife: 10
    )

    private func start(
        keyByte: UInt8, hosted: [[String]], peers: [PeerEndpoint] = [], storagePath: URL? = nil,
        stopAtTeardown: Bool = true, observe: NodeRuntime.JobObserver? = nil
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint, storage: NodeStorage) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storagePath ?? temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            bootstrapPeers: peers,
            externalAddress: "127.0.0.1",
            hostedChildren: hosted,
            childSpecs: [Self.alpha: Self.spec, Self.beta: Self.betaSpec].filter { hosted.contains($0.key) },
            // One block per connect: a held connect holds one block.
            connectBatch: observe == nil ? NodeConfiguration.defaultConnectBatch : 1
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: port,
            bootstrapPeers: peers,
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", port),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: configuration, overlay: overlay,
            workers: observe == nil ? max(1, ProcessInfo.processInfo.activeProcessorCount - 1) : 2, observeJob: observe
        )
        // A node the test stops itself is not held: its store is opened again.
        if stopAtTeardown { addTeardownBlock { await runtime.stop() } }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port), storage)
    }

    /// A host that mines `chains`, one block every 200 ms, until the test ends.
    private func mining(keyByte: UInt8, _ chains: [ChainPath]) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let host = try await start(keyByte: keyByte, hosted: chains)
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let miner = host.runtime
        let mining = Task { [miner, chains, recipient] in
            while !Task.isCancelled {
                _ = try? await miner.mineBlock(MiningTemplateRequest(recipients: chains.map {
                    MiningRecipient(chainPath: $0, address: recipient)
                }))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        addTeardownBlock { mining.cancel() }
        return (host.runtime, host.endpoint)
    }

    /// Two blocks of the chain at `path` that `runtime` executed, the first
    /// below the second.
    private func twoBlocks(_ runtime: NodeRuntime, _ path: ChainPath) async throws -> (lower: String, upper: String) {
        let chain = try XCTUnwrap(runtime.levelReads[path])
        try await eventually("the node syncs \(path) past genesis", within: .seconds(20)) {
            (await chain.readSnapshot().height ?? 0) >= 2
        }
        let lower = await chain.readSnapshot()
        try await eventually("the node syncs \(path)'s next block", within: .seconds(20)) {
            (await chain.readSnapshot().height ?? 0) > (lower.height ?? 0)
        }
        let upper = await chain.readSnapshot().tipCID
        return (try XCTUnwrap(lower.tipCID), try XCTUnwrap(upper))
    }

    private static func volumeStatus(_ client: some TestClientProtocol, _ cid: String) async throws -> HTTPResponse.Status {
        try await client.execute(
            uri: "/volumes/\(cid)", method: .get, headers: [.authorization: testOperatorAuthorization]
        ) { $0.status }
    }

    private static func pin(_ client: some TestClientProtocol, _ cid: String) async throws {
        try await client.execute(
            uri: "/pins", method: .post,
            headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
            body: ByteBuffer(bytes: try JSONEncoder().encode(PinRequest(cid: cid)))
        ) { XCTAssertEqual($0.status, .ok) }
    }

    func testANodeStartsAndStopsHostingAChildWhileRunning() async throws {
        let host = try await start(keyByte: 0x81, hosted: [Self.alpha])
        let follower = try await start(keyByte: 0x82, hosted: [], peers: [host.endpoint])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let (miner, alpha) = (host.runtime, Self.alpha)
        let mining = Task { [miner, alpha, recipient] in
            while !Task.isCancelled {
                _ = try? await miner.mineBlock(MiningTemplateRequest(recipients: [
                    MiningRecipient(chainPath: alpha, address: recipient),
                ]))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { mining.cancel() }
        let hostAlpha = try XCTUnwrap(host.runtime.levelReads[Self.alpha])
        try await eventually("the host mines Alpha past genesis") {
            (await hostAlpha.readSnapshot().height ?? 0) >= 2
        }
        try await eventually("the follower joins the host") { follower.runtime.peerCount == 1 }
        XCTAssertNil(follower.runtime.levelReads[Self.alpha])

        // A child whose parent is not hosted is refused, and nothing changes.
        do {
            try await follower.runtime.host([["Nexus", "Alpha", "Beta"]])
            XCTFail("a child without its parent was hosted")
        } catch NodeConfigurationError.invalidChainPath {}
        XCTAssertEqual(follower.runtime.hostedChildren, [])

        // Alpha's reads answer on the same running listener once it is
        // hosted, and not after.
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await follower.runtime.host([Self.alpha])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/hosted-chains", method: .get, headers: [.authorization: testOperatorAuthorization]
            ) { XCTAssertEqual(String(buffer: $0.body), #"{"chains":["Nexus\/Alpha"]}"#) }
            try await Self.alphaHealth(client, .ok)
        }
        XCTAssertEqual(follower.runtime.hostedChildren, [Self.alpha])
        // The peer it was already connected to is told too, by a hello sent
        // again on the open session.
        func hostSeesAlphaHosted() -> Bool {
            host.runtime.peerCapabilities.sessions(speaking: ChainHandshake.hosting(Self.alpha))
                .contains { $0.key.hex == follower.endpoint.publicKey }
        }
        try await eventually("the connected peer learns the follower hosts Alpha") { hostSeesAlphaHosted() }
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("the follower syncs Alpha from the peer it already has", within: .seconds(20)) {
            (await followerAlpha.readSnapshot().height ?? 0) >= 2
        }
        let alphaStatus = await follower.runtime.status(chainPath: Self.alpha)
        XCTAssertEqual(alphaStatus?.chainPath, Self.alpha, "operator status answers for the hosted child")
        XCTAssertNotNil(alphaStatus?.sync)
        XCTAssertNil(alphaStatus?.templateDigest, "the template digest is the root's")
        // A peer that connects now is told Alpha is hosted.
        let late = try await start(keyByte: 0x83, hosted: [], peers: [follower.endpoint])
        try await eventually("the follower's hello names Alpha") {
            late.runtime.peerCapabilities.sessions(speaking: ChainHandshake.hosting(Self.alpha))
                .contains { $0.key.hex == follower.endpoint.publicKey }
        }

        try await follower.runtime.host([])
        try await app.test(.router) { client in
            try await Self.alphaHealth(client, .notFound)
        }
        XCTAssertNil(follower.runtime.levelReads[Self.alpha])
        let unhosted = await follower.runtime.status(chainPath: Self.alpha)
        XCTAssertNil(unhosted)
        XCTAssertEqual(follower.runtime.hostedChildren, [])
        try await eventually("the connected peer learns the follower no longer hosts Alpha") { !hostSeesAlphaHosted() }
        let held = await followerAlpha.readSnapshot().height ?? 0

        try await follower.runtime.host([Self.alpha])
        let resumed = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("the follower follows Alpha again", within: .seconds(20)) {
            (await resumed.readSnapshot().height ?? 0) > held
        }
    }

    /// A chain the configuration no longer hosts has its data let go of:
    /// its blocks are not served, a block the operator pinned is, and a
    /// sibling still hosted is served and keeps syncing. Hosting it again
    /// syncs it again from peers.
    func testAChainRemovedFromTheConfigurationHasItsDataLetGoOf() async throws {
        let host = try await mining(keyByte: 0x85, [Self.alpha, Self.beta])
        let follower = try await start(keyByte: 0x86, hosted: [Self.alpha, Self.beta], peers: [host.endpoint])
        let (pinned, dropped) = try await twoBlocks(follower.runtime, Self.alpha)
        let (_, sibling) = try await twoBlocks(follower.runtime, Self.beta)
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await app.test(.router) { client in try await Self.pin(client, pinned) }

        try await follower.runtime.host([Self.beta])
        try await assertLetGo(app, dropped: dropped, pinned: pinned, sibling: sibling)
        try await assertSyncs(follower.runtime, Self.beta)

        try await follower.runtime.host([Self.alpha, Self.beta])
        try await eventually("the follower syncs Alpha again", within: .seconds(20)) {
            await self.servesAgain(app, dropped)
        }
    }

    /// A chain dropped while one of its blocks is being executed: the
    /// change returns at once, the node keeps answering, and the chain's
    /// data is let go of once that execution ends.
    func testAChainDroppedWhileItsBlockExecutesIsLetGoOfAfter() async throws {
        actor Gate {
            private(set) var holding = false
            private(set) var held = 0
            func hold() { holding = true }
            func release() { holding = false }
            func pass() async {
                guard holding else { return }
                held += 1
                while holding { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        actor Flag {
            private(set) var set = false
            func raise() { set = true }
        }
        let gate = Gate()
        let host = try await mining(keyByte: 0x8b, [Self.alpha])
        let follower = try await start(
            keyByte: 0x8c, hosted: [Self.alpha], peers: [host.endpoint],
            observe: { kind, path, _ in if kind == .connect, path == Self.alpha { await gate.pass() } }
        )
        let (_, dropped) = try await twoBlocks(follower.runtime, Self.alpha)
        await gate.hold()
        try await eventually("a block of Alpha is being executed (held)", within: .seconds(20)) { await gate.held > 0 }

        let returned = Flag()
        let change = Task {
            try await follower.runtime.host([])
            await returned.raise()
        }
        defer { change.cancel() }
        do {
            try await eventually("the change returns while the execution is held", within: .seconds(10)) { await returned.set }
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await eventually("Alpha's data is let go of once the execution ends") {
            (try? await app.test(.router) { client in try await Self.volumeStatus(client, dropped) }) == .notFound
        }
        // Whenever the held execution stores its block, none of Alpha's
        // blocks is served, that one included.
        let blocks = await LiveLevels(inputs: host.runtime.inputs).read { levels -> [String] in
            guard let alpha = levels[Self.alpha] else { return [] }
            return (1...max(1, alpha.snapshot.bestHeaderHeight)).compactMap { alpha.tree.canonicalBlockHash(atHeight: $0) }
        } ?? []
        XCTAssertFalse(blocks.isEmpty)
        try await alwaysDuring("none of Alpha's blocks is served", .seconds(1), poll: .milliseconds(100)) {
            try await app.test(.router) { client in
                for cid in blocks where try await Self.volumeStatus(client, cid) != .notFound { return false }
                return true
            }
        }
        let status = await follower.runtime.status()
        XCTAssertEqual(status.chainPath, ["Nexus"], "the node still answers")
    }

    /// The same for a chain a start's configuration does not host.
    func testAChainAStartDoesNotHostHasItsDataLetGoOf() async throws {
        let host = try await mining(keyByte: 0x87, [Self.alpha, Self.beta])
        let (layout, directory) = try Self.layout()
        let (pinned, dropped, sibling): (String, String, String)
        do {
            let follower = try await start(
                keyByte: 0x88, hosted: [Self.alpha, Self.beta], peers: [host.endpoint], storagePath: directory,
                stopAtTeardown: false
            )
            (pinned, dropped) = try await twoBlocks(follower.runtime, Self.alpha)
            (_, sibling) = try await twoBlocks(follower.runtime, Self.beta)
            try await makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0).test(.router) { client in
                try await Self.pin(client, pinned)
            }
            await follower.runtime.stop()
        }

        let follower = try await start(keyByte: 0x88, hosted: [Self.beta], peers: [host.endpoint], storagePath: directory)
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await eventually("the start lets go of Alpha") {
            !Self.holdsAlpha(layout)
        }
        try await assertLetGo(app, dropped: dropped, pinned: pinned, sibling: sibling)
        try await assertSyncs(follower.runtime, Self.beta)

        try await follower.runtime.host([Self.alpha, Self.beta])
        try await eventually("the follower syncs Alpha again", within: .seconds(20)) {
            await self.servesAgain(app, dropped)
        }
    }

    /// A release a stop cut short, after the chain's blocks' bodies went
    /// and before its facts did, is finished at the next start.
    func testAReleaseCutShortIsFinishedAtTheNextStart() async throws {
        let host = try await mining(keyByte: 0x89, [Self.alpha])
        let (layout, directory) = try Self.layout()
        do {
            let follower = try await start(
                keyByte: 0x8a, hosted: [Self.alpha], peers: [host.endpoint], storagePath: directory, stopAtTeardown: false
            )
            _ = try await twoBlocks(follower.runtime, Self.alpha)
            await follower.runtime.stop()
        }
        do {
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: "8a", count: 32)
            )
            // The stopped node's lock goes with its last reference, which
            // its tasks can hold a moment past `stop()`.
            var opened: NodeStorage?
            try await eventually("the stopped node lets go of its storage") {
                do { opened = try await NodeStorage.open(configuration: configuration) } catch NodeStorageError.storageInUse {}
                return opened != nil
            }
            let storage = try XCTUnwrap(opened)
            let bodies = try await storage.broker.retainedScopes(prefix: storage.scopes.bodyPrefix + "Nexus/Alpha:")
            try await storage.broker.releaseRetainedScopes(bodies)
        }
        XCTAssertTrue(Self.holdsAlpha(layout), "a create of Alpha is refused: this node holds it")

        _ = try await start(keyByte: 0x8a, hosted: [], storagePath: directory)
        try await eventually("the start finishes the release") {
            !Self.holdsAlpha(layout)
        }
    }

    private func assertLetGo(
        _ app: some ApplicationProtocol, dropped: String, pinned: String, sibling: String
    ) async throws {
        try await app.test(.router) { client in
            let gone = try await Self.volumeStatus(client, dropped)
            XCTAssertEqual(gone, .notFound, "a block of a chain not hosted is not served")
            let stays = try await Self.volumeStatus(client, pinned)
            XCTAssertEqual(stays, .ok, "a block the operator pinned is")
            let kept = try await Self.volumeStatus(client, sibling)
            XCTAssertEqual(kept, .ok, "and a block of a sibling still hosted")
        }
    }

    private func assertSyncs(_ runtime: NodeRuntime, _ path: ChainPath) async throws {
        let chain = try XCTUnwrap(runtime.levelReads[path])
        let height = await chain.readSnapshot().height ?? 0
        try await eventually("\(path) keeps syncing", within: .seconds(20)) {
            (await chain.readSnapshot().height ?? 0) > height
        }
    }

    /// A host root (`lattice init`'s layout) and its node's storage.
    private static func layout() throws -> (HostLayout, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-chains-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"listen":4001,"rpc":4003,"peers":[]}"#.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        let layout = HostLayout(root: root.path)
        return (layout, layout.chainDirectory(for: ChainAddress.nexus))
    }

    /// Whether creating Alpha (`POST /chains`, `lattice child create`) is
    /// refused because this node holds it.
    private static func holdsAlpha(_ layout: HostLayout) -> Bool {
        do {
            try ChainCreation.create(HostedChain(path: "Nexus/Alpha", spec: spec), layout: layout)
            return false
        } catch is ChainCreation.Synced {
            return true
        } catch {
            return false
        }
    }

    private func servesAgain(_ app: some ApplicationProtocol, _ cid: String) async -> Bool {
        (try? await app.test(.router) { client in try await Self.volumeStatus(client, cid) }) == .ok
    }

    /// The hosted set changing sends a new digest at once: a template
    /// carries every hosted level, so a miner fetches again with its plan.
    func testHostedChainsChangingSendsAMiningEvent() async throws {
        let node = try await start(keyByte: 0x84, hosted: [Self.alpha])
        var events = node.runtime.miningEvents().makeAsyncIterator()
        let hostingEvent = await events.next()
        let hosting = try XCTUnwrap(hostingEvent)
        try await node.runtime.host([])
        let unhostedEvent = await events.next()
        let unhosted = try XCTUnwrap(unhostedEvent)
        XCTAssertNotEqual(unhosted, hosting)
        try await node.runtime.host([Self.alpha])
        let rehostedEvent = await events.next()
        let rehosted = try XCTUnwrap(rehostedEvent)
        XCTAssertNotEqual(rehosted, unhosted)
    }

    private static func alphaHealth(_ client: some TestClientProtocol, _ status: HTTPResponse.Status) async throws {
        try await client.execute(
            uri: "/health?chainPath=Nexus/Alpha", method: .get, headers: [.authorization: testOperatorAuthorization]
        ) { XCTAssertEqual($0.status, status) }
    }
}
