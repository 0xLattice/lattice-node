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
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func start(
        keyByte: UInt8, hosted: [[String]], peers: [PeerEndpoint] = [], storagePath: URL? = nil,
        stopAtTeardown: Bool = true
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
            childSpecs: hosted.isEmpty ? [:] : [Self.alpha: Self.spec]
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
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        // A node the test stops itself is not held: its store is opened again.
        if stopAtTeardown { addTeardownBlock { await runtime.stop() } }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port), storage)
    }

    /// A host that mines Alpha, one block every 200 ms, until the test ends.
    private func miningAlpha(keyByte: UInt8) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let host = try await start(keyByte: keyByte, hosted: [Self.alpha])
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
        addTeardownBlock { mining.cancel() }
        return (host.runtime, host.endpoint)
    }

    /// Two of Alpha's blocks `runtime` executed, the first below the second.
    private func twoAlphaBlocks(_ runtime: NodeRuntime) async throws -> (lower: String, upper: String) {
        let alpha = try XCTUnwrap(runtime.levelReads[Self.alpha])
        try await eventually("the node syncs Alpha past genesis", within: .seconds(20)) {
            (await alpha.readSnapshot().height ?? 0) >= 2
        }
        let lower = await alpha.readSnapshot()
        try await eventually("the node syncs Alpha's next block", within: .seconds(20)) {
            (await alpha.readSnapshot().height ?? 0) > (lower.height ?? 0)
        }
        let upper = await alpha.readSnapshot().tipCID
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

    /// What the store keeps for Alpha: its facts, and the bodies pinned
    /// under its blocks' names.
    private static func heldForAlpha(_ storage: NodeStorage) async throws -> (facts: Int, bodies: Int) {
        let facts = try await storage.store.storedFacts(at: alpha).facts.count
        let bodies = try await storage.broker.retainedScopes(prefix: storage.scopes.bodyPrefix + "Nexus/Alpha:").count
        return (facts, bodies)
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

    /// An operator unhosts a chain: the node lets go of what it kept for
    /// it, and no longer serves its blocks; a block the operator pinned
    /// stays. Hosting it again syncs it again from peers.
    func testUnhostingAChainLetsGoOfItsDataAndHostingItAgainSyncsIt() async throws {
        let host = try await miningAlpha(keyByte: 0x85)
        let follower = try await start(keyByte: 0x86, hosted: [Self.alpha], peers: [host.endpoint])
        let (pinned, dropped) = try await twoAlphaBlocks(follower.runtime)
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await app.test(.router) { client in
            try await Self.pin(client, pinned)
            let served = try await Self.volumeStatus(client, dropped)
            XCTAssertEqual(served, .ok)
        }
        let kept = try await Self.heldForAlpha(follower.storage)
        XCTAssertGreaterThan(kept.facts, 0)
        XCTAssertGreaterThan(kept.bodies, 0)

        try await follower.runtime.host([])
        try await app.test(.router) { client in
            let gone = try await Self.volumeStatus(client, dropped)
            XCTAssertEqual(gone, .notFound, "a block of a chain no longer hosted is not served")
            let stays = try await Self.volumeStatus(client, pinned)
            XCTAssertEqual(stays, .ok, "a block the operator pinned is")
        }
        let left = try await Self.heldForAlpha(follower.storage)
        XCTAssertEqual(left.facts, 0, "its facts go")
        XCTAssertEqual(left.bodies, 0, "and its blocks' bodies")

        try await follower.runtime.host([Self.alpha])
        try await eventually("the follower syncs Alpha again", within: .seconds(20)) {
            await self.servesAgain(app, dropped)
        }
    }

    /// The same at a start whose configuration no longer lists the chain.
    func testAStartWithoutAChainLetsGoOfItsData() async throws {
        let host = try await miningAlpha(keyByte: 0x87)
        let directory = temporaryDirectory()
        let (pinned, dropped): (String, String)
        do {
            let follower = try await start(
                keyByte: 0x88, hosted: [Self.alpha], peers: [host.endpoint], storagePath: directory, stopAtTeardown: false
            )
            (pinned, dropped) = try await twoAlphaBlocks(follower.runtime)
            try await makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0).test(.router) { client in
                try await Self.pin(client, pinned)
            }
            await follower.runtime.stop()
        }

        let follower = try await start(keyByte: 0x88, hosted: [], peers: [host.endpoint], storagePath: directory)
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await eventually("the start lets go of Alpha") {
            (try? await Self.heldForAlpha(follower.storage)).map { $0 == (0, 0) } ?? false
        }
        try await app.test(.router) { client in
            let gone = try await Self.volumeStatus(client, dropped)
            XCTAssertEqual(gone, .notFound, "a block of a chain no longer hosted is not served")
            let stays = try await Self.volumeStatus(client, pinned)
            XCTAssertEqual(stays, .ok, "a block the operator pinned is")
        }

        try await follower.runtime.host([Self.alpha])
        try await eventually("the follower syncs Alpha again", within: .seconds(20)) {
            await self.servesAgain(app, dropped)
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
