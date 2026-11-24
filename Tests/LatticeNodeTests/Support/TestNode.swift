import Foundation
import Ivy
import XCTest
@testable import LatticeNode

/// A node a test runs on loopback: its configuration, its overlay, and the
/// endpoint other test nodes dial it at.
struct TestNode {
    let configuration: NodeConfiguration
    let overlay: IvyConfig
    var endpoint: PeerEndpoint {
        PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: overlay.listenPort)
    }
}

/// What every test node is given: its storage, its key and its ports. A
/// test's configuration is built from these and whatever else it needs.
struct TestNodeBasics {
    let storagePath: URL
    let privateKeyHex: String
    let listenPort: UInt16
    let rpcPort: UInt16

    /// A Nexus node with the defaults and nothing else.
    func configuration() throws -> NodeConfiguration {
        try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storagePath, privateKeyHex: privateKeyHex,
            listenPort: listenPort, rpcPort: rpcPort
        )
    }
}

extension XCTestCase {
    /// A test node keyed by `keyByte`, on fresh ports, dialling `peers`. Its
    /// storage is a fresh directory removed at teardown, or `reusing` a
    /// stopped node's, as a restart does. The overlay advertises the
    /// configuration's external address, if it has one, on the listen port.
    func testNode(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        reusing storage: URL? = nil,
        routingRefreshInterval: Duration = .seconds(120),
        _ configure: (TestNodeBasics) throws -> NodeConfiguration = { try $0.configuration() }
    ) throws -> TestNode {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try configure(TestNodeBasics(
            storagePath: storage ?? temporaryDirectory(prefix: "lattice-node"),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate()
        ))
        return TestNode(configuration: configuration, overlay: IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            routingRefreshInterval: routingRefreshInterval,
            externalAddress: configuration.externalAddress.map { (host: $0, port: port) }, mode: .overlay
        ))
    }

    /// `node`'s storage opened (once a stopped node on it lets go) and its
    /// runtime started. The test stops it.
    func start(_ node: TestNode) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.openWhenFree(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay
        )
        return (runtime, storage)
    }
}
