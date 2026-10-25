import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import Synchronization
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
        keyByte: UInt8, coreConfig: ChainCoreConfig = ChainCoreConfig(), peers: [PeerEndpoint] = [],
        storagePath: URL? = nil, stopAtTeardown: Bool = true,
        failStop: @escaping @Sendable (any Error) -> Void = { fatalError("node runtime: persist failed: \($0)") }
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storagePath ?? temporaryDirectory(),
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
            storage: storage, configuration: configuration, overlay: overlay, coreConfig: coreConfig,
            failStop: failStop
        )
        if stopAtTeardown { addTeardownBlock { await runtime.stop() } }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    func testAFollowerSyncsAChildLevelThroughOneHeaderPages() async throws {
        try await followerSyncs(from: ChainCoreConfig(maxPageBytes: 1), keys: (0x71, 0x72))
    }

    /// The same through a server with no time to gather more than one header.
    func testAFollowerSyncsAChildLevelFromAServerOutOfTime() async throws {
        try await followerSyncs(from: ChainCoreConfig(servingBudget: -1), keys: (0x73, 0x74))
    }

    /// Child proofs saved before a restart are read from the store: the
    /// restarted host serves Alpha's headers with them, so a new follower
    /// still reaches its tip.
    func testARestartedHostServesTheChildProofsItSavedBefore() async throws {
        let hostPath = temporaryDirectory()
        // The first run is stopped and released before the same storage reopens.
        let tip = try await mineAlpha(
            on: start(keyByte: 0x75, storagePath: hostPath, stopAtTeardown: false).runtime, stop: true
        )
        let host = try await start(keyByte: 0x75, storagePath: hostPath)
        try await followerReaches(tip, from: host.endpoint, key: 0x76)
    }

    /// A saved-proof query that fails is a store fault: serving a child
    /// page through it fail-stops the host, never serves the page bare.
    func testAHostWhoseProofQueryFailsFailStopsWhenServing() async throws {
        let hostPath = temporaryDirectory()
        let stopped = Mutex<(any Error)?>(nil)
        let host = try await start(keyByte: 0x77, storagePath: hostPath) { error in
            stopped.withLock { $0 = $0 ?? error }
        }
        let tip = try await mineAlpha(on: host.runtime)
        _ = try NodeSQLite(path: hostPath.appendingPathComponent("state.db").path).execute("DROP TABLE child_proofs")
        _ = try await start(keyByte: 0x78, peers: [host.endpoint])
        try await eventually("the host fail-stops on the failed proof query") {
            stopped.withLock { $0 != nil }
        }
        XCTAssertGreaterThan(tip, 0)
    }

    private func followerSyncs(from serverConfig: ChainCoreConfig, keys: (UInt8, UInt8)) async throws {
        let host = try await start(keyByte: keys.0, coreConfig: serverConfig)
        let tip = try await mineAlpha(on: host.runtime)
        try await followerReaches(tip, from: host.endpoint, key: keys.1)
    }

    private func mineAlpha(on host: NodeRuntime, stop: Bool = false) async throws -> UInt64 {
        let hostAlpha = try XCTUnwrap(host.levelReads[Self.alpha])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        try await eventually("the host mines Alpha to height 6") {
            _ = try await host.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: Self.alpha, address: recipient),
            ]))
            return (await hostAlpha.readSnapshot().height ?? 0) >= 6
        }
        let hostHeight = await hostAlpha.readSnapshot().height
        if stop { await host.stop() }
        return try XCTUnwrap(hostHeight)
    }

    private func followerReaches(_ tip: UInt64, from host: PeerEndpoint, key: UInt8) async throws {
        let follower = try await start(keyByte: key, peers: [host])
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("the follower reaches the host's Alpha tip") {
            (await followerAlpha.readSnapshot().height ?? 0) >= tip
        }
    }
}
