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

    func testNexusIdentityIsFixed() throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32)
        )

        XCTAssertEqual(configuration.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(configuration.minPeerKeyBits, 0)

        XCTAssertThrowsError(try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: URL(fileURLWithPath: "/tmp/lattice-node-test"),
            privateKeyHex: String(repeating: "01", count: 32),
            rpcPort: 4001
        )) { error in
            XCTAssertEqual(error as? NodeConfigurationError, .invalidPorts)
        }
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
