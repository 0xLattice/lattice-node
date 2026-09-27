import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: after a network session ends, no per-peer record and no
/// pending request in `NodeNetworkRuntime` still holds that peer's key — on
/// the overlay plane and on the hierarchy plane alike.
///
/// The runtime keeps ~30 per-peer maps and pending-request tables (sessions,
/// hello deadlines, announced tips, range sync, frontier pulls, inventory and
/// read-endpoint requests, evidence waiters and leases, candidate offers,
/// pushed context sequences, candidate providers, evidence-flow sessions…).
/// `NodeNetworkRuntime.heldPeerKeysForTesting()` (DEBUG-only, added for this
/// test) unions the keys held across all of them, so the assertion here is
/// one line and the refactor cannot drop a map from the audit by moving it.
///
/// Non-vacuous by construction: each peer's key must first APPEAR in the held
/// set (the overlay peer completes its hello and announces a deep tip, which
/// also starts a range sync against it; the hierarchy peer completes a child
/// hello), and only then is its disconnect required to clear it.
///
/// The `overlayRuntime` / `connectAndHello` / `NetworkTransportTestPorts`
/// helpers are copies of the private ones in `NetworkTrustTests` (that file's
/// helpers are `private`, so they cannot be shared without editing it).
final class SafetyNetDisconnectInvariantTests: XCTestCase {

    func testDisconnectedPeersLeaveNoPerPeerRecordOnEitherPlane() async throws {
        let target = try await overlayRuntime(keyByte: 0xd1, requestTimeout: .seconds(2))
        let overlayKey = signingKey(0xd2)
        let overlayPeer = Ivy(config: IvyConfig(
            signingKey: overlayKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let overlayStub = SafetyNetSilentPeer()
        await overlayPeer.installSafetyNetDelegate(overlayStub)
        let childKey = signingKey(0xd3)
        let childPeer = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
        let childStub = SafetyNetSilentPeer()
        await childPeer.installSafetyNetDelegate(childStub)
        let overlayPeerKey = peerKey(overlayKey)
        let childPeerKey = peerKey(childKey)

        try await target.runtime.start(
            process: target.process,
            handlers: NodeNetworkHandlers(admission: { _ in throw CancellationError() })
        )
        defer { Task { await target.runtime.stop() } }
        do {
            // Overlay: hello, then a deep tip announcement so the runtime
            // records the peer as a candidate provider and range-sync source.
            try await connectAndHello(
                overlayPeer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitUntil("overlay peer recorded after hello") {
                await target.runtime.heldPeerKeysForTesting().contains(overlayPeerKey)
            }
            let announcement = try BlockAnnouncementMessage(
                blockCID: testCID("safety-net-deep-tip"),
                height: 40
            ).encoded()
            guard case .enqueued = await overlayPeer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: announcement
            ) else {
                throw SafetyNetNetworkError.failedSend
            }
            try await waitUntil("deep tip announcement recorded") {
                await target.runtime.rangeSyncAnchorForTesting() != nil
            }

            // Hierarchy: an immediate-child hello grants the `.child` role.
            try await childPeer.start()
            try await childPeer.connect(to: target.hierarchyEndpoint)
            try await waitUntil("child peer connected on the hierarchy plane") {
                (await childPeer.connectedPeers).contains(target.peerID)
            }
            let childHello = try ChainHello(
                nexusGenesisCID: target.process.configuration.nexusGenesisCID,
                chainPath: ["Nexus", "Payments"]
            ).encode()
            guard case .enqueued = await childPeer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: childHello
            ) else {
                throw SafetyNetNetworkError.failedSend
            }
            try await waitUntil("child peer recorded after hierarchy hello") {
                await target.runtime.heldPeerKeysForTesting().contains(childPeerKey)
            }

            // Both sessions end.
            await overlayPeer.stop()
            await childPeer.stop()
            try await waitUntil("per-peer records cleared after disconnect") {
                await target.runtime.heldPeerKeysForTesting()
                    .isDisjoint(with: [overlayPeerKey, childPeerKey])
            }
        } catch {
            await overlayPeer.stop()
            await childPeer.stop()
            throw error
        }

        let held = await target.runtime.heldPeerKeysForTesting()
        XCTAssertFalse(
            held.contains(overlayPeerKey),
            "overlay peer \(overlayPeerKey.hex.prefix(8)) still held after disconnect"
        )
        XCTAssertFalse(
            held.contains(childPeerKey),
            "hierarchy child peer \(childPeerKey.hex.prefix(8)) still held after disconnect"
        )
        let rangeSyncAnchor = await target.runtime.rangeSyncAnchorForTesting()
        XCTAssertNil(
            rangeSyncAnchor,
            "range sync must not survive its source peer's disconnect"
        )
    }

    // MARK: - Helpers (copied from NetworkTrustTests, which keeps them private)

    private func testCID(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }

    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    /// Bounded poll; never a fixed settle sleep for a positive assertion.
    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
        throw SafetyNetNetworkError.failedPhase(what)
    }

    private func overlayRuntime(
        keyByte: UInt8,
        requestTimeout: Duration
    ) async throws -> (
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hierarchyEndpoint: PeerEndpoint,
        hello: Data
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-safety-net-disconnect-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = SafetyNetTestPorts.allocate()
        let hierarchyPort = SafetyNetTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: SafetyNetTestPorts.allocate()
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    requestTimeout: requestTimeout,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(configuration: configuration)
        return (
            runtime,
            process,
            PeerID(publicKey: configuration.processPublicKey),
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ),
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            ),
            try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
        )
    }

    private func connectAndHello(
        _ peer: Ivy,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) async throws {
        try await peer.start()
        try await peer.connect(to: endpoint)
        try await waitUntil("overlay peer connected") {
            (await peer.connectedPeers).contains(peerID)
        }
        guard case .enqueued = await peer.sendMessage(
            to: peerID,
            topic: NodeNetworkTopic.overlayHello,
            payload: hello
        ) else {
            throw SafetyNetNetworkError.failedSend
        }
    }
}

private enum SafetyNetNetworkError: Error {
    case failedSend
    case failedPhase(String)
}

/// A delegate that records nothing: the test reads the runtime's side only.
private final class SafetyNetSilentPeer: IvyDelegate, Sendable {}

private extension Ivy {
    func installSafetyNetDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}

/// Copy of `NetworkTransportTestPorts` (private to `NetworkTrustTests`): a
/// free loopback port per plane, remembered so one run never reuses one.
private enum SafetyNetTestPorts {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var allocated = Set<UInt16>()

    static func allocate() -> UInt16 {
        lock.withLock {
            while true {
                #if canImport(Darwin)
                let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                #else
                let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
                #endif
                precondition(descriptor >= 0)
                defer { _ = close(descriptor) }

                var address = sockaddr_in()
                #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                precondition(bound == 0)
                var assigned = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &assigned) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(descriptor, $0, &length)
                    }
                }
                precondition(named == 0)
                let port = UInt16(bigEndian: assigned.sin_port)
                if allocated.insert(port).inserted { return port }
            }
        }
    }
}
