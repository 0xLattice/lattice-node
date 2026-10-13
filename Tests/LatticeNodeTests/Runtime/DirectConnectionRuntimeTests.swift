import Foundation
import Ivy
import XCTest
@testable import LatticeNode

/// Two nodes that cannot dial each other meet through a peer that relays.
final class DirectConnectionRuntimeTests: XCTestCase {
    private func runtime(
        keyByte: UInt8, peers: [PeerEndpoint] = [], relays: Bool = false
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            bootstrapPeers: peers
        )
        let runtime = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                relayEnabled: relays, mode: .overlay
            )
        )
        addTeardownBlock { await runtime.stop() }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    func testAPeerThatCannotBeDialledIsReachedThroughOneThatSaidItRelays() async throws {
        let relay = try await runtime(keyByte: 0x61, relays: true)
        let a = try await runtime(keyByte: 0x62, peers: [relay.endpoint])
        let b = try await runtime(keyByte: 0x63, peers: [relay.endpoint])
        try await eventually("both know the relay") { a.runtime.peerCount == 1 && b.runtime.peerCount == 1 }

        // The hello says who relays, and only a node whose overlay does says so.
        XCTAssertEqual(
            a.runtime.peerCapabilities.sessions(speaking: ChainHandshake.relay).map(\.key.hex),
            [relay.endpoint.publicKey])
        try await eventually("the relay knows both") { relay.runtime.peerCount == 2 }
        XCTAssertTrue(relay.runtime.peerCapabilities.sessions(speaking: ChainHandshake.relay).isEmpty)

        // Nothing listens where `b` is said to be, so the dial fails and the
        // node asks the relay for a route. Without one this throws.
        let unreachable = PeerEndpoint(publicKey: b.endpoint.publicKey, host: "127.0.0.1", port: 1)
        try await a.runtime.ivy.connect(to: unreachable)

        // Neither node knows an address the other could reach it at, so the
        // session cannot be made direct, and a peer is not kept through
        // another: both let it go, and keep the relay.
        let known = await relay.runtime.ivy.connectedPeers
        let bID = try XCTUnwrap(known.first { $0.publicKey == b.endpoint.publicKey })
        try await eventually("the relayed session is let go") {
            await a.runtime.ivy.session(with: bID) == nil
        }
        XCTAssertEqual(a.runtime.peerCount, 1)
        XCTAssertEqual(b.runtime.peerCount, 1)
        let relayPeers = await relay.runtime.ivy.connectedPeers.count
        XCTAssertEqual(relayPeers, 2)
    }

    func testAPeerThatDidNotSayItRelaysIsNotAsked() async throws {
        let hub = try await runtime(keyByte: 0x64, relays: false)
        let a = try await runtime(keyByte: 0x65, peers: [hub.endpoint])
        let b = try await runtime(keyByte: 0x66, peers: [hub.endpoint])
        try await eventually("all three are connected") {
            a.runtime.peerCount == 1 && b.runtime.peerCount == 1 && hub.runtime.peerCount == 2
        }
        XCTAssertTrue(a.runtime.peerCapabilities.sessions(speaking: ChainHandshake.relay).isEmpty)

        let unreachable = PeerEndpoint(publicKey: b.endpoint.publicKey, host: "127.0.0.1", port: 1)
        do {
            try await a.runtime.ivy.connect(to: unreachable)
            XCTFail("a route was found through a peer that does not relay")
        } catch {}
        // Asking would have cost the session with the hub.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(a.runtime.peerCount, 1)
        XCTAssertEqual(hub.runtime.peerCount, 2)
    }
}
