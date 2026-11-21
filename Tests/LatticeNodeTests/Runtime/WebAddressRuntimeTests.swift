import Foundation
@testable import Ivy
import Tally
import XCTest
@testable import LatticeNode

/// Where a node tells its peers browsers reach it, as a peer sees it
/// (`Ivy.webAddresses(of:)`): the URL its operator declared, or else a
/// connected peer's own URL to relay through, or nothing.
final class WebAddressRuntimeTests: XCTestCase {
    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
        let key: PeerKey
        var id: PeerID { PeerID(publicKey: endpoint.publicKey) }
    }

    private func start(keyByte: UInt8, url: String? = nil, peers: [PeerEndpoint] = []) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
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
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
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

    func testANodeWithNoPeerThatListensAdvertisesNothing() async throws {
        let plain = try await start(keyByte: 0x73)
        let peer = try await start(keyByte: 0x74, peers: [plain.endpoint])
        try await eventually("the session is ready") { plain.runtime.peerCount == 1 && peer.runtime.peerCount == 1 }
        // Sent on every session, even empty: [] is "none", nil "never sent".
        let seen = await advertised(by: plain, to: peer)
        XCTAssertEqual(seen, [])
    }

    /// Without a URL of its own, a node advertises the first peer it met
    /// that listens, keeps it when a peer with a smaller key arrives, and
    /// moves to that one when the first is gone.
    func testANodeIsReachedThroughAPeerThatListensAndKeepsItsChoice() async throws {
        let first = try await start(keyByte: 0x75, url: "wss://first.example.org/ivy")
        let second = try await start(keyByte: 0x76, url: "wss://second.example.org/ivy")
        // `later` has the smaller key, so only stability keeps `earlier`.
        let (earlier, later) = first.key.hex > second.key.hex ? (first, second) : (second, first)
        let earlierURL = earlier.id == first.id ? "wss://first.example.org/ivy" : "wss://second.example.org/ivy"
        let laterURL = earlier.id == first.id ? "wss://second.example.org/ivy" : "wss://first.example.org/ivy"

        let node = try await start(keyByte: 0x77, peers: [earlier.endpoint])
        let throughEarlier = [WebAddress(url: earlierURL, via: earlier.key)]
        try await eventually("the node advertises the peer it met") {
            await self.advertised(by: node, to: earlier) == throughEarlier
        }

        try await node.runtime.ivy.connect(to: later.endpoint)
        try await eventually("the later peer is a ready session") {
            await self.advertised(by: node, to: later) != nil
                && node.runtime.peerCount == 2
        }
        // Time for the node to have weighed its new peer.
        try await Task.sleep(for: .seconds(1))
        let seenByLater = await advertised(by: node, to: later)
        XCTAssertEqual(seenByLater, throughEarlier, "a smaller key arriving does not move the choice")

        await earlier.runtime.stop()
        try await eventually("the node moves to the peer still connected") {
            await self.advertised(by: node, to: later) == [WebAddress(url: laterURL, via: later.key)]
        }
    }
}
