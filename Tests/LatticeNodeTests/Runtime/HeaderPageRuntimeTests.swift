import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeNode

/// A server whose headers answers hold one header each still brings a
/// follower to its child level's tip: each answer is cut at the page cap and
/// the follower asks again for the rest.
final class HeaderPageRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func start(
        keyByte: UInt8, coreConfig: ChainCoreConfig = ChainCoreConfig(), peers: [PeerEndpoint] = []
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
            hostedChildren: [Self.alpha],
            childSpecs: [Self.alpha: Self.spec]
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
            storage: storage, configuration: configuration, overlay: overlay, coreConfig: coreConfig
        )
        addTeardownBlock { await runtime.stop() }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    func testAFollowerSyncsAChildLevelThroughOneHeaderPages() async throws {
        let host = try await start(keyByte: 0x71, coreConfig: ChainCoreConfig(maxPageBytes: 1))
        let hostAlpha = try XCTUnwrap(host.runtime.levelReads[Self.alpha])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        try await eventually("the host mines Alpha to height 6") {
            _ = try await host.runtime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: Self.alpha, address: recipient),
            ]))
            return (await hostAlpha.readSnapshot().height ?? 0) >= 6
        }
        let hostHeight = await hostAlpha.readSnapshot().height
        let tip = try XCTUnwrap(hostHeight)

        let follower = try await start(keyByte: 0x72, peers: [host.endpoint])
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("the follower reaches the host's Alpha tip") {
            (await followerAlpha.readSnapshot().height ?? 0) >= tip
        }
    }
}
