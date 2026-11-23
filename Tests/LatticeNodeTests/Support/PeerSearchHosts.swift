import Foundation
import Ivy
import XCTest
@testable import LatticeNode

/// Real runtimes on loopback for the peer-memory and seed tests, each with a
/// maintenance pass every second, where the book is kept and seeds asked.
extension XCTestCase {
    /// A node's configuration, overlay and endpoint. `peers` are dialled by
    /// the overlay itself; `seeds` and `fixed` only when the node is short.
    /// Every peer here is on loopback, one network group: the overlay's
    /// per-group connection limit is lifted so that is not what is tested.
    func loopbackHost(
        _ keyByte: String, directory: URL? = nil,
        peers: [PeerEndpoint] = [], seeds: [PeerEndpoint] = [], fixed: [PeerEndpoint] = []
    ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
        let directory = directory ?? temporaryDirectory(prefix: "lattice-peer-search")
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            seedPeers: seeds, fixedSeedPeers: fixed, peerSearchInterval: 1
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            maxConnectionsPerNetgroup: 64,
            mode: .overlay
        )
        return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    func startLoopbackHost(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> NodeRuntime {
        try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration, overlay: overlay
        )
    }
}

/// The peers `runtime` holds sessions with, by key.
func sessions(_ runtime: NodeRuntime) async -> Set<String> {
    Set(await runtime.ivy.connectedPeers.map(\.publicKey))
}
