import Foundation
import Ivy
import XCTest
@testable import LatticeNode

final class DefaultBootstrapPeersTests: XCTestCase {
    private func operatorPeer(_ byte: UInt8) throws -> PeerEndpoint {
        PeerEndpoint(
            publicKey: try PeerKey(
                rawRepresentation: Data(repeating: byte, count: PeerKey.byteCount)
            ).hex,
            host: "203.0.113.\(byte)",
            port: 4001
        )
    }

    /// LATTICE_FORBID_DEFAULT_PEERS=1 trips exactly when the built-in set
    /// would be used; an explicit list (even empty) never trips it.
    func testForbidDefaultPeersGuard() throws {
        let forbid = [DefaultBootstrapPeers.forbidEnvironmentKey: "1"]
        XCTAssertTrue(DefaultBootstrapPeers.forbidden(configured: nil, environment: forbid))
        XCTAssertFalse(DefaultBootstrapPeers.forbidden(configured: [], environment: forbid))
        XCTAssertFalse(DefaultBootstrapPeers.forbidden(
            configured: [try operatorPeer(1)], environment: forbid
        ))
        XCTAssertFalse(DefaultBootstrapPeers.forbidden(configured: nil, environment: [:]))
        XCTAssertFalse(DefaultBootstrapPeers.forbidden(
            configured: nil, environment: [DefaultBootstrapPeers.forbidEnvironmentKey: "0"]
        ))
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
        // The seeds are the project's own names, seed1 onward: a host can
        // move provider with a DNS change, and no release names a provider.
        XCTAssertEqual(
            DefaultBootstrapPeers.nexus.map(\.host),
            (1...DefaultBootstrapPeers.nexus.count).map { "seed\($0).lattice.build" }
        )
    }

    /// The fixed addresses are the named seeds again, for when names cannot be
    /// resolved: the same identities and ports, each at a literal IPv4
    /// address, so that dialling one needs no lookup at all.
    func testFixedSeedsAreTheNamedSeedsAtLiteralAddresses() {
        XCTAssertEqual(
            DefaultBootstrapPeers.nexusFixed.map(\.publicKey),
            DefaultBootstrapPeers.nexus.map(\.publicKey)
        )
        XCTAssertEqual(DefaultBootstrapPeers.nexusFixed.map(\.port), DefaultBootstrapPeers.nexus.map(\.port))
        for endpoint in DefaultBootstrapPeers.nexusFixed {
            let octets = endpoint.host.split(separator: ".", omittingEmptySubsequences: false)
            XCTAssertTrue(
                octets.count == 4 && octets.allSatisfy { UInt8($0) != nil },
                "\(endpoint.host) is not a literal IPv4 address"
            )
        }
        XCTAssertEqual(Set(DefaultBootstrapPeers.nexusFixed.map(\.host)).count, DefaultBootstrapPeers.nexusFixed.count)
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
    /// plane.
    func testDefaultsReachOnlyTheOverlayPlaneAndCarryNoTrust() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lattice-default-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }

        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "3f", count: 32),
            bootstrapPeers: DefaultBootstrapPeers.resolved(
                chainPath: ["Nexus"],
                configured: nil
            )
        )
        let planes = try OverlayConfiguration(configuration)

        XCTAssertEqual(planes.overlay.bootstrapPeers, DefaultBootstrapPeers.nexus)
        XCTAssertTrue(
            planes.overlay.carriers.isEmpty,
            "a default peer is not a carrier"
        )
    }
}
