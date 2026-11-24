import Foundation
@testable import Ivy
import Tally
import XCTest
@testable import LatticeNode

/// Where a node tells its peers browsers reach it, as a peer sees it
/// (`Ivy.webAddresses(of:)`): the URL its operator declared, or else a
/// peer that relays and listens itself, to be reached through.
final class WebAddressRuntimeTests: XCTestCase {
    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
        let key: PeerKey
        var id: PeerID { PeerID(publicKey: endpoint.publicKey) }
    }

    /// `relays`: the node's hello says it relays.
    private func start(
        keyByte: UInt8, url: String? = nil, relays: Bool = true, peers: [PeerEndpoint] = []
    ) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: url == nil ? .off : .required(NetworkTransportTestPorts.allocate()),
            bootstrapPeers: peers,
            externalAddress: "127.0.0.1",
            peerSearchInterval: 3_600,
            webSocketURL: url
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: port,
            bootstrapPeers: peers,
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            routingRefreshInterval: .seconds(3_600),
            externalAddress: ("127.0.0.1", port),
            relayEnabled: relays,
            mode: .overlay
        )
        let storage = try await NodeStorage.openWhenFree(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        addTeardownBlock { await runtime.stop() }
        return Node(
            runtime: runtime,
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port),
            key: try PeerKey(configuration.processPublicKey)
        )
    }

    /// What `node` advertised, as `observer` holds it.
    private func advertised(by node: Node, to observer: Node) async -> [WebAddress]? {
        await observer.runtime.ivy.webAddresses(of: node.id)
    }

    func testADeclaredURLIsAdvertised() async throws {
        let declared = try await start(keyByte: 0x71, url: "wss://node.example.org/ivy")
        let peer = try await start(keyByte: 0x72, peers: [declared.endpoint])
        try await eventually("the peer holds the declared URL") {
            await self.advertised(by: declared, to: peer) == [WebAddress(url: "wss://node.example.org/ivy")]
        }
    }

    func testWithoutAURLANodeIsReachedThroughAPeerThatRelays() async throws {
        let relay = try await start(keyByte: 0x75, url: "wss://relay.example.org/ivy")
        let node = try await start(keyByte: 0x77, peers: [relay.endpoint])
        try await eventually("the node advertises the relay") {
            await self.advertised(by: node, to: relay)
                == [WebAddress(url: "wss://relay.example.org/ivy", via: relay.key)]
        }
    }

    /// Only a peer that relays can carry a browser to this node: one that
    /// listens itself but does not relay is not chosen.
    func testAPeerThatDoesNotRelayIsNotChosen() async throws {
        let silent = try await start(keyByte: 0x78, url: "wss://silent.example.org/ivy", relays: false)
        let relay = try await start(keyByte: 0x79, url: "wss://relay.example.org/ivy")
        let node = try await start(keyByte: 0x7A, peers: [silent.endpoint])
        try await eventually("the node is a ready session of the peer that does not relay") {
            await self.advertised(by: node, to: silent) != nil && node.runtime.peerCount == 1
        }
        try await alwaysDuring("the node does not advertise the peer that does not relay", .milliseconds(500)) {
            await self.advertised(by: node, to: silent) == []
        }

        try await node.runtime.ivy.connect(to: relay.endpoint)
        try await eventually("the node advertises the peer that relays") {
            await self.advertised(by: node, to: silent)
                == [WebAddress(url: "wss://relay.example.org/ivy", via: relay.key)]
        }
    }
}
