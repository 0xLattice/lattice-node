import Foundation
import XCTest
@testable import LatticeNode

/// The hello's `capabilities` is an addition a node that predates it never
/// sees: such a node decodes the new hello as the hello it always knew.
final class ChainHandshakeCapabilityTests: XCTestCase {
    /// `ChainHandshake` as it stood before `capabilities` (protocol version
    /// 6), decoded the way that node decodes it.
    private struct HelloBeforeCapabilities: Codable, Equatable {
        let version: UInt16
        let nexusGenesisCID: String
        let chainPath: [String]
    }

    func testAHelloWithCapabilitiesDecodesOnANodeThatPredatesThemAndTheReverse() throws {
        let genesis = NexusGenesis.expectedBlockHash
        let new = ChainHandshake(
            nexusGenesisCID: genesis, chainPath: ["Nexus"],
            capabilities: [ChainHandshake.volumeBundle, "a-later-addition"]
        )
        let newBytes = try new.encode()
        XCTAssertEqual(try ChainHandshake.decode(newBytes), new)
        XCTAssertEqual(new.capabilities, ["a-later-addition", ChainHandshake.volumeBundle])

        // The old node reads the same version, genesis and path, and nothing else.
        let old = HelloBeforeCapabilities(version: 6, nexusGenesisCID: genesis, chainPath: ["Nexus"])
        XCTAssertEqual(try JSONDecoder().decode(HelloBeforeCapabilities.self, from: newBytes), old)

        // The old node's hello is a hello with no capabilities, byte for byte.
        let oldBytes = try _canonicalJSONEncode(old)
        let decoded = try ChainHandshake.decode(oldBytes)
        XCTAssertNil(decoded.capabilities)
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: genesis, expectedChainPath: ["Nexus"]
        ))
        XCTAssertEqual(try ChainHandshake(nexusGenesisCID: genesis, chainPath: ["Nexus"]).encode(), oldBytes)

        // An empty list, repeats and names nobody knows are a valid hello; a
        // list of the wrong type is a malformed one, as any malformed field is.
        func hello(capabilities: String) -> Data {
            Data(#"{"capabilities":\#(capabilities),"chainPath":["Nexus"],"nexusGenesisCID":"\#(genesis)","version":6}"#.utf8)
        }
        XCTAssertEqual(try ChainHandshake.decode(hello(capabilities: "[]")).capabilities, [])
        XCTAssertEqual(
            Set(try ChainHandshake.decode(hello(capabilities: #"["x","x","volume-bundle"]"#)).capabilities ?? []),
            ["x", ChainHandshake.volumeBundle]
        )
        XCTAssertThrowsError(try ChainHandshake.decode(hello(capabilities: #""volume-bundle""#))) {
            XCTAssertEqual($0 as? ChainHandshakeError, .malformed)
        }
    }
}
