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
/// already has, a stopped one is gone from reads, and starting it again
/// resumes from what it journaled.
final class HostChainsRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func start(
        keyByte: UInt8, hosted: [[String]], peers: [PeerEndpoint] = []
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
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
        addTeardownBlock { await runtime.stop() }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
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
        XCTAssertEqual(follower.runtime.hostedChildren, [])
        try await eventually("the connected peer learns the follower no longer hosts Alpha") { !hostSeesAlphaHosted() }
        let held = await followerAlpha.readSnapshot().height ?? 0

        try await follower.runtime.host([Self.alpha])
        let resumed = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        let restored = await resumed.readSnapshot().height ?? 0
        XCTAssertGreaterThanOrEqual(restored, held, "a level hosted again resumes from what it journaled")
        try await eventually("the follower follows Alpha again", within: .seconds(20)) {
            (await resumed.readSnapshot().height ?? 0) > held
        }
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

    /// A child catching up is left out of the template, which its tip
    /// moving does not rebuild: mining on its history makes blocks nobody
    /// uses. It joins the template once it latches (`ChainCore.catchingUp`).
    func testAChildJoinsTheTemplateOnceItLatches() async throws {
        let host = try await start(keyByte: 0x85, hosted: [Self.alpha])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let plan = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: Self.alpha, address: recipient)])
        let hostAlpha = try XCTUnwrap(host.runtime.levelReads[Self.alpha])
        while (await hostAlpha.readSnapshot().height ?? 0) < 6 { _ = try await host.runtime.mineBlock(plan) }

        let follower = try await start(keyByte: 0x86, hosted: [Self.alpha], peers: [host.endpoint])
        let levels = LiveLevels(inputs: follower.runtime.inputs)
        func alphaCatchingUp() async -> Bool { await levels.read { $0[Self.alpha]?.catchingUp } == true }
        func carriesAlpha(_ template: MiningTemplateResponse) -> Bool {
            template.chains?.contains { $0.chainPath == Self.alpha } == true
        }
        // Before it meets a peer, Alpha has nothing to catch up from.
        try await eventually("the follower's Alpha meets the host") {
            await levels.read { $0[Self.alpha]?.sync.peers.isEmpty == false } == true
        }
        try await eventually("a template carries Alpha once it latches", within: .seconds(30)) {
            let before = await alphaCatchingUp()
            guard let template = try? await follower.runtime.miningTemplate(plan) else { return false }
            // Latched is never unset: catching up after the build means
            // catching up when it was built.
            if before, await alphaCatchingUp() { XCTAssertFalse(carriesAlpha(template)) }
            return carriesAlpha(template)
        }
        let synced = await levels.read { $0[Self.alpha]?.synced }
        XCTAssertEqual(synced, true)
    }

    private static func alphaHealth(_ client: some TestClientProtocol, _ status: HTTPResponse.Status) async throws {
        try await client.execute(
            uri: "/health?chainPath=Nexus/Alpha", method: .get, headers: [.authorization: testOperatorAuthorization]
        ) { XCTAssertEqual($0.status, status) }
    }
}
