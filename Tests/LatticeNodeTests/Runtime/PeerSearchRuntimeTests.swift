import Foundation
@testable import Ivy
import Lattice
import XCTest
@testable import LatticeNode

/// A fresh node finds the peers hosting a child level through the level's
/// rendezvous, while Nexus keeps advancing. The host and the follower share
/// only a Nexus-only hub, which cannot sync the child for them. Each node
/// advertises a routable address - a loopback address is never accepted as a
/// referral - and dials to those addresses are rewritten to loopback.
final class PeerSearchRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
    }

    /// Routable stand-in address → loopback port, shared by every node's dialer.
    private static func advertised(_ port: UInt16) -> String { "8.8.\(port >> 8).\(port & 0xFF)" }

    private func start(keyByte: UInt8, hosted: [[String]], peers: [PeerEndpoint] = []) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let host = Self.advertised(port)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            bootstrapPeers: peers,
            externalAddress: host,
            peerSearchInterval: 5,
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
            // No background routing refresh: only the node's peer search
            // may connect the follower to the host.
            routingRefreshInterval: .seconds(3_600),
            externalAddress: (host, port),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        await runtime.ivy.setDialEndpointRewriteForTesting { endpoint in
            endpoint.host.hasPrefix("8.8.")
                ? PeerEndpoint(publicKey: endpoint.publicKey, host: "127.0.0.1", port: endpoint.port)
                : endpoint
        }
        addTeardownBlock { await runtime.stop() }
        return Node(
            runtime: runtime,
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    func testAFollowerFindsTheChildsHostWhileNexusAdvances() async throws {
        let hub = try await start(keyByte: 0x61, hosted: [])
        let host = try await start(keyByte: 0x62, hosted: [Self.alpha], peers: [hub.endpoint])
        let follower = try await start(keyByte: 0x63, hosted: [Self.alpha], peers: [hub.endpoint])

        // The host keeps mining Nexus and Alpha, well inside the 5 s search
        // interval, so Nexus never stalls on the follower: only Alpha's own
        // rendezvous can lead it to the host.
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
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        let followerNexus = follower.runtime.reads
        try await eventually("the host mines Alpha past genesis") {
            (await hostAlpha.readSnapshot().height ?? 0) >= 2
        }
        try await eventually("the follower follows Nexus through the hub") {
            (await followerNexus.readSnapshot().height ?? 0) >= 2
        }
        // Within the 30 s sync-request deadline: a node that only finds the
        // host after a stalled request has churned its Nexus peers (stalling
        // Nexus, which the Nexus-only search waits for) does not pass.
        try await eventually("the follower finds Alpha's host and syncs Alpha", within: .seconds(20)) {
            (await followerAlpha.readSnapshot().height ?? 0) >= 2
        }
    }
}
