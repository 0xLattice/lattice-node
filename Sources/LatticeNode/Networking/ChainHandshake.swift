import Foundation

public enum ChainHandshakeError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case incompatibleProtocol
    case wrongNexusGenesis
    case wrongChainPath
}

/// Authenticated application handshake for the shared hosted-tree overlay.
/// Synchronization state is advertised separately because
/// competing roots on one child path remain ordinary fork-choice candidates.
public struct ChainHandshake: Codable, Equatable, Sendable {
    /// Version 6: one process hosts a Nexus-rooted tree on one overlay. There
    /// is no per-chain endpoint or public-read URL in the session handshake.
    public static let protocolVersion: UInt16 = 6
    /// Deliberately tight pre-decode guard: `decode` runs on an UNAUTHENTICATED
    /// peer's bytes, so unlike post-session messages (bounded by the transport
    /// frame) this caps unauthenticated JSON parse work. A hello is only a version
    /// + one CID + a short chain path; ~64 KiB is far above any real hello while
    /// staying well under the frame size. `validateShape()` is the real check.
    public static let maximumEncodedSize = 64 * 1024

    public let version: UInt16
    public let nexusGenesisCID: String
    public let chainPath: [String]
    public init(
        nexusGenesisCID: String,
        chainPath: [String]
    ) {
        version = Self.protocolVersion
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
    }

    public func encode() throws -> Data {
        try validateShape()
        let data = try _canonicalJSONEncode(self)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChainHandshakeError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ChainHandshake {
        guard data.count <= Self.maximumEncodedSize else {
            throw ChainHandshakeError.oversized
        }
        guard let hello = try? JSONDecoder().decode(ChainHandshake.self, from: data) else {
            throw ChainHandshakeError.malformed
        }
        try hello.validateShape()
        return hello
    }

    /// Ivy authenticates the peer key. This handshake only establishes that an
    /// authenticated peer speaks for the same chain setup; it grants no fact
    /// authority.
    public func validateCompatibility(
        expectedNexusGenesisCID: String,
        expectedChainPath: [String]
    ) throws {
        try validateShape()
        guard version == Self.protocolVersion else {
            throw ChainHandshakeError.incompatibleProtocol
        }
        guard nexusGenesisCID == expectedNexusGenesisCID else {
            throw ChainHandshakeError.wrongNexusGenesis
        }
        guard chainPath == expectedChainPath else {
            throw ChainHandshakeError.wrongChainPath
        }
    }

    private func validateShape() throws {
        guard _isBoundedWireAtom(nexusGenesisCID),
              _isAbsoluteChainPath(chainPath) else {
            throw ChainHandshakeError.malformed
        }
    }
}
