import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

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

        // Through the operator API, as `lattice` asks: Alpha's reads answer
        // on the same running listener once it is hosted, and not after.
        let app = makeApplication(service: follower.runtime, host: "127.0.0.1", port: 0)
        try await app.test(.router) { client in
            try await Self.hostedChains(client, ["Nexus/Alpha"])
            try await client.execute(
                uri: "/hosted-chains", method: .get, headers: [.authorization: testOperatorAuthorization]
            ) { XCTAssertEqual(String(buffer: $0.body), #"{"chains":["Nexus\/Alpha"]}"#) }
            try await Self.alphaHealth(client, .ok)
        }
        XCTAssertEqual(follower.runtime.hostedChildren, [Self.alpha])
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

        try await app.test(.router) { client in
            try await Self.hostedChains(client, [])
            try await Self.alphaHealth(client, .notFound)
        }
        XCTAssertNil(follower.runtime.levelReads[Self.alpha])
        XCTAssertEqual(follower.runtime.hostedChildren, [])
        let held = await followerAlpha.readSnapshot().height ?? 0

        try await follower.runtime.host([Self.alpha])
        let resumed = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        let restored = await resumed.readSnapshot().height ?? 0
        XCTAssertGreaterThanOrEqual(restored, held, "a level hosted again resumes from what it journaled")
        try await eventually("the follower follows Alpha again", within: .seconds(20)) {
            (await resumed.readSnapshot().height ?? 0) > held
        }
    }

    private static func hostedChains(_ client: some TestClientProtocol, _ chains: [String]) async throws {
        try await client.execute(
            uri: "/hosted-chains", method: .post,
            headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
            body: ByteBuffer(bytes: try JSONEncoder().encode(HostedChainsRequest(
                hostChain: chains, premineTo: nil, chainPeer: nil, policyModule: nil
            )))
        ) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
    }

    private static func alphaHealth(_ client: some TestClientProtocol, _ status: HTTPResponse.Status) async throws {
        try await client.execute(
            uri: "/health?chainPath=Nexus/Alpha", method: .get, headers: [.authorization: testOperatorAuthorization]
        ) { XCTAssertEqual($0.status, status) }
    }
}
