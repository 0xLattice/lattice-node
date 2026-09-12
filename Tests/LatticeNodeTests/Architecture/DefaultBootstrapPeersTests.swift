import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import XCTest
@testable import LatticeNode

private enum DialListenerError: Error {
    case unavailable
}

/// Wall-clock stamps of every inbound dial, in arrival order.
private actor DialRecorder {
    private var stamps: [ContinuousClock.Instant] = []

    func record(_ stamp: ContinuousClock.Instant) {
        stamps.append(stamp)
    }

    func snapshot() -> [ContinuousClock.Instant] {
        stamps
    }
}

/// A loopback listener that answers every dial and immediately drops it, so a
/// configured peer is reachable at the TCP layer but never completes a
/// session — exactly the shape of a bootstrap peer that has been lost.
private final class DialCountingListener: Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let acceptLoop: Task<Void, Never>

    init(recorder: DialRecorder) throws {
        #if canImport(Darwin)
        let handle = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let handle = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard handle >= 0 else { throw DialListenerError.unavailable }

        var reuse: Int32 = 1
        _ = setsockopt(
            handle, SOL_SOCKET, SO_REUSEADDR, &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(handle, 16) == 0 else {
            _ = close(handle)
            throw DialListenerError.unavailable
        }

        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named_ok = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named_ok == 0 else {
            _ = close(handle)
            throw DialListenerError.unavailable
        }
        _ = fcntl(handle, F_SETFL, O_NONBLOCK)

        descriptor = handle
        port = UInt16(bigEndian: named.sin_port)
        acceptLoop = Task {
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let connection = accept(handle, nil, nil)
                if connection >= 0 {
                    _ = close(connection)
                    await recorder.record(clock.now)
                } else {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    func stop() {
        acceptLoop.cancel()
        _ = close(descriptor)
    }
}

final class DefaultBootstrapPeersTests: XCTestCase {
    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: byte, count: 32)
        )
    }

    private func operatorPeer(_ byte: UInt8) throws -> PeerEndpoint {
        PeerEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: Data(repeating: byte, count: PeerKey.byteCount)
            ).hex,
            host: "203.0.113.\(byte)",
            port: 4001
        )
    }

    /// A fresh node with nothing configured joins through the shipped set.
    func testDefaultsAreUsedWhenNothingIsConfigured() {
        let resolved = DefaultBootstrapPeers.resolved(
            chainPath: ["Nexus"],
            configured: nil
        )

        XCTAssertFalse(
            resolved.isEmpty,
            "a node with no configured peer source must still have somewhere to dial"
        )
        XCTAssertEqual(resolved, DefaultBootstrapPeers.nexus)

        // Diversity is by address, not merely by identity: distinct keys on
        // distinct hosts, so the set is not one machine.
        XCTAssertEqual(
            Set(DefaultBootstrapPeers.nexus.map(\.publicKey)).count,
            DefaultBootstrapPeers.nexus.count
        )
        XCTAssertGreaterThan(
            Set(DefaultBootstrapPeers.nexus.map(\.host)).count,
            1
        )
        // Every shipped endpoint must be a dialable, well-formed identity.
        for endpoint in DefaultBootstrapPeers.nexus {
            XCTAssertNoThrow(try PeerKey(endpoint.publicKey))
            XCTAssertFalse(endpoint.host.isEmpty)
            XCTAssertNotEqual(endpoint.port, 0)
        }
    }

    /// An operator peer source REPLACES the defaults; it never merges.
    func testOperatorPeersFullyReplaceTheDefaults() throws {
        let mine = [try operatorPeer(0x11), try operatorPeer(0x12)]

        let resolved = DefaultBootstrapPeers.resolved(
            chainPath: ["Nexus"],
            configured: mine
        )

        XCTAssertEqual(resolved, mine)
        let defaultKeys = Set(DefaultBootstrapPeers.nexus.map(\.publicKey))
        XCTAssertTrue(
            resolved.allSatisfy { !defaultKeys.contains($0.publicKey) },
            "a configured peer source must not be merged with the built-ins"
        )
    }

    /// "No bootstrap peers at all" has to be expressible, and an explicitly
    /// empty setting is how it is said.
    func testExplicitEmptySettingYieldsNoBootstrapPeers() {
        XCTAssertEqual(
            DefaultBootstrapPeers.resolved(chainPath: ["Nexus"], configured: []),
            []
        )
    }

    /// Child chains never inherit the root defaults: Nexus backbone processes
    /// do not carry a child's chain, and seeding them would mask the
    /// same-chain peers the child actually needs.
    func testChildChainsDoNotGetRootChainDefaults() throws {
        XCTAssertEqual(
            DefaultBootstrapPeers.resolved(
                chainPath: ["Nexus", "Payments"],
                configured: nil
            ),
            []
        )
        XCTAssertEqual(
            DefaultBootstrapPeers.resolved(
                chainPath: ["Nexus", "Payments", "Receipts"],
                configured: nil
            ),
            []
        )

        // A child's own explicitly configured peers still apply.
        let childPeers = [try operatorPeer(0x21)]
        XCTAssertEqual(
            DefaultBootstrapPeers.resolved(
                chainPath: ["Nexus", "Payments"],
                configured: childPeers
            ),
            childPeers
        )
    }

    /// Defaults are discovery, not trust: they reach only the public overlay
    /// plane, and they carry no admission bypass — the hierarchy plane still
    /// holds exactly the configured parent.
    func testDefaultsReachOnlyTheOverlayPlaneAndCarryNoTrust() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lattice-default-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }

        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "3f", count: 32),
            bootstrapPeers: DefaultBootstrapPeers.resolved(
                chainPath: ["Nexus"],
                configured: nil
            )
        )
        let planes = try NodeNetworkPlaneConfigurations(configuration)

        XCTAssertEqual(planes.overlay.bootstrapPeers, DefaultBootstrapPeers.nexus)
        XCTAssertTrue(
            planes.overlay.inboundAdmissionBypassPeerKeys.isEmpty,
            "a default peer gets no admission bypass"
        )
        XCTAssertTrue(
            planes.hierarchy.bootstrapPeers.isEmpty,
            "root defaults must never reach the private hierarchy plane"
        )
        XCTAssertTrue(planes.hierarchy.inboundAdmissionBypassPeerKeys.isEmpty)
        XCTAssertTrue(
            planes.overlay.carriers.isEmpty,
            "a default peer is not a carrier"
        )
    }

    /// A lost bootstrap peer is re-dialled for the life of the process, under
    /// backoff — one failed dial must not remove it. The listener answers
    /// every dial and drops it, so no session ever completes.
    func testLostBootstrapPeerIsRedialledWithBackoff() async throws {
        let recorder = DialRecorder()
        let listener = try DialCountingListener(recorder: recorder)

        let lost = PeerEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: Data(repeating: 0x5c, count: PeerKey.byteCount)
            ).hex,
            host: "127.0.0.1",
            port: listener.port
        )
        let node = Ivy(config: IvyConfig(
            signingKey: signingKey(0x5d),
            listenPort: 0,
            bootstrapPeers: [lost],
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))

        var stamps: [ContinuousClock.Instant] = []
        do {
            try await node.start()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while clock.now < deadline {
                stamps = await recorder.snapshot()
                if stamps.count >= 3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            await node.stop()
            listener.stop()
            throw error
        }
        await node.stop()
        listener.stop()

        XCTAssertGreaterThanOrEqual(
            stamps.count, 3,
            "a lost bootstrap peer must be re-dialled repeatedly, not tried once"
        )
        // Report that one failure rather than trapping on the indices below:
        // an index-out-of-range would abort the whole test binary and take
        // every other test in the run with it.
        guard stamps.count >= 3 else { return }

        // Lower bounds only: a busy machine can lengthen a gap but never
        // shorten it, so these cannot flake on scheduling noise. The first gap
        // proves the retry is not a spin; the second proves the delay grows.
        let firstGap = stamps[1] - stamps[0]
        let secondGap = stamps[2] - stamps[1]
        XCTAssertGreaterThanOrEqual(
            firstGap, .milliseconds(400),
            "re-dial must back off rather than spin"
        )
        XCTAssertGreaterThanOrEqual(
            secondGap, .milliseconds(900),
            "the backoff must grow between attempts"
        )
    }
}
