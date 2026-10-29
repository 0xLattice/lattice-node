import Crypto
import Ivy
import UInt256
import XCTest
@testable import LatticeNode

final class NodeConfigurationTests: XCTestCase {
    func testChainAddressUsesConsensusDirectoryGrammar() throws {
        let address = try XCTUnwrap(ChainAddress(["Nexus", "Payments-1"]))
        XCTAssertNoThrow(try ChainHandshake(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: address.components
        ).encode())

        // Directory length is now bounded by the proof wire format (a UInt16
        // field width) rather than a central 64-byte cap, so a 65-char atom is
        // valid. This test covers the consensus GRAMMAR: printable ASCII, no
        // separator, and the Nexus-rooted path rule.
        XCTAssertNil(ChainAddress(["Nexus", "日本語-☃"]))
        XCTAssertNil(ChainAddress(["Nexus", "line\nbreak"]))
        XCTAssertNil(ChainAddress(["Nexus", "has/slash"]))
        XCTAssertNil(ChainAddress(["Payments"]))
        XCTAssertThrowsError(try ChainHandshake(
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            chainPath: ["Payments"]
        ).encode())
    }

    /// Every announcement lasts the operator's one lifetime; one peers would
    /// drop, too long or none at all, is refused at start.
    func testAnnouncementsLastTheOperatorsLifetime() throws {
        func configuration(_ lifetime: UInt64) throws -> NodeConfiguration {
            try NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
                privateKeyHex: String(repeating: "01", count: 32),
                announceLifetime: lifetime
            )
        }
        XCTAssertEqual(try configuration(3_600).announcementExpiry(at: 10_000), 3_610)
        XCTAssertEqual(
            try configuration(NodeConfiguration.maximumAnnounceLifetime).announcementExpiry(at: 10_000),
            10 + NodeConfiguration.maximumAnnounceLifetime
        )
        XCTAssertThrowsError(try configuration(0)) {
            XCTAssertEqual($0 as? NodeConfigurationError, .invalidAnnounceLifetime)
        }
        XCTAssertThrowsError(try configuration(NodeConfiguration.maximumAnnounceLifetime + 1)) {
            XCTAssertEqual($0 as? NodeConfigurationError, .invalidAnnounceLifetime)
        }
    }

    /// A pass announces what is new or would lapse before the pass after
    /// next, and stops what is no longer wanted. Kept among connected
    /// peers, every pass announces everything.
    func testAPassAnnouncesOnlyWhatIsNewOrDue() throws {
        func configuration(walkSessions: Int) throws -> NodeConfiguration {
            try NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
                privateKeyHex: String(repeating: "01", count: 32),
                peerSearchInterval: 600,
                announceLifetime: 1_200,
                providerWalkSessions: walkSessions
            )
        }
        let walking = try configuration(walkSessions: 64)
        let now: Int64 = 10_000_000
        // Announced at 10_000 s, the pass that time; renewable once 900 s
        // (one and a half cadences) or less remain.
        let announced: [String: UInt64] = ["fresh": 11_200, "due": 10_900, "dropped": 11_200]
        let renewal = walking.announcementRenewal(
            wanted: ["fresh", "due", "new"], announced: announced, at: now
        )
        XCTAssertEqual(renewal.announce, ["due", "new"])
        XCTAssertEqual(renewal.withdraw, ["dropped"])

        let connected = try configuration(walkSessions: 0)
        XCTAssertEqual(
            connected.announcementRenewal(wanted: ["fresh", "due"], announced: announced, at: now).announce,
            ["due", "fresh"]
        )
    }

    func testNexusIdentityIsFixed() throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )

        XCTAssertEqual(configuration.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(configuration.minPeerKeyBits, 0)
        XCTAssertEqual(configuration.webSocket, .ifAvailable(4002), "browsers are listened for by default")

        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32),
            rpcPort: 4001
        )) { error in
            XCTAssertEqual(error as? NodeConfigurationError, .invalidPorts)
        }
    }

    func testTheBrowserPortIsOneOfTheNodesOwn() throws {
        func configuration(_ webSocket: WebSocketListener) throws -> NodeConfiguration {
            try NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
                privateKeyHex: String(repeating: "01", count: 32),
                listenPort: 4002,
                rpcPort: 8080,
                webSocket: webSocket
            )
        }
        XCTAssertEqual(try configuration(.required(4003)).webSocket, .required(4003))
        XCTAssertEqual(try configuration(.off).webSocket, .off)
        for taken: UInt16 in [0, 4002, 8080] {
            XCTAssertThrowsError(try configuration(.required(taken))) { error in
                XCTAssertEqual(error as? NodeConfigurationError, .invalidPorts)
            }
            XCTAssertEqual(
                try configuration(.ifAvailable(taken)).webSocket, .off,
                "a port given to something else is not available")
        }

        // A node that browsers reach is the one that carries them to each other.
        XCTAssertTrue(try OverlayConfiguration(configuration(.ifAvailable(4003))).overlay.relayEnabled)
        XCTAssertFalse(try OverlayConfiguration(configuration(.off)).overlay.relayEnabled)
    }

    func testZeroMinimumRootWorkIsValidLocalPolicy() throws {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertNoThrow(try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: FileManager.default.temporaryDirectory,
            privateKeyHex: key.rawRepresentation.map {
                String(format: "%02x", $0)
            }.joined()
        ))
    }

    func testSigningKeyRecreatesConfiguredIdentity() throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let message = Data("lattice".utf8)
        let first = configuration.signingKey
        let second = configuration.signingKey

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(
            try PeerKey(rawRepresentation: first.publicKey.rawRepresentation).hex,
            configuration.processPublicKey
        )
        XCTAssertTrue(
            second.publicKey.isValidSignature(
                try first.signature(for: message),
                for: message
            )
        )
    }

    func testHostedChildrenMustBeUniqueAndParentFirst() throws {
        let arguments = (
            storagePath: FileManager.default.temporaryDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        XCTAssertNoThrow(try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: arguments.storagePath,
            privateKeyHex: arguments.privateKeyHex,
            hostedChildren: [["Nexus", "Alpha"], ["Nexus", "Alpha", "Beta"]]
        ))
        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: arguments.storagePath,
            privateKeyHex: arguments.privateKeyHex,
            hostedChildren: [["Nexus", "Alpha", "Beta"], ["Nexus", "Alpha"]]
        ))
        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: arguments.storagePath,
            privateKeyHex: arguments.privateKeyHex,
            hostedChildren: [["Nexus", "Alpha"], ["Nexus", "Alpha"]]
        ))
    }

}
