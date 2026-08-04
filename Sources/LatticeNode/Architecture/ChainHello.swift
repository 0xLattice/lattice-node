import Foundation
import Lattice

public enum ChainHelloError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case incompatibleProtocol
    case wrongNexusGenesis
    case wrongChainPath
}

/// Authenticated application handshake for both the same-chain overlay and a
/// pinned parent link. Synchronization state is advertised separately because
/// competing roots on one child path remain ordinary fork-choice candidates.
public struct ChainHello: Codable, Equatable, Sendable {
    /// Version 4 removes node-local policy from peer compatibility.
    public static let protocolVersion: UInt16 = 4
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
            throw ChainHelloError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ChainHello {
        guard data.count <= Self.maximumEncodedSize else {
            throw ChainHelloError.oversized
        }
        guard let hello = try? JSONDecoder().decode(ChainHello.self, from: data) else {
            throw ChainHelloError.malformed
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
            throw ChainHelloError.incompatibleProtocol
        }
        guard nexusGenesisCID == expectedNexusGenesisCID else {
            throw ChainHelloError.wrongNexusGenesis
        }
        guard chainPath == expectedChainPath else {
            throw ChainHelloError.wrongChainPath
        }
    }

    private func validateShape() throws {
        guard _isBoundedWireAtom(nexusGenesisCID),
              _isAbsoluteChainPath(chainPath) else {
            throw ChainHelloError.malformed
        }
    }
}

func _isAbsoluteChainPath(_ path: [String]) -> Bool {
    ChainAddress(path) != nil
}

/// Default wire-atom byte bound: the structural wire capacity (a UInt16 length
/// prefix), not an invented sub-capacity constant. Matches Lattice's
/// `CIDIdentity.maximumTextBytes`/`ChildProofWireLimits.maximumDirectoryBytes`,
/// which the simplified architecture raised from an arbitrary cap to `UInt16.max`:
/// real CIDs/directories are ~59 bytes, the canonical round-trip is the true
/// identity check, and this only bounds parse work to what the wire can represent.
let _wireAtomCapacity = Int(UInt16.max)

func _isBoundedWireAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= maximumBytes
        && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

/// A well-formed directory atom: the same printable-ASCII grammar as any wire
/// atom, plus no path separator (Lattice's `isValidDirectoryAtom`). Lattice 27.0.0
/// keeps this grammar internal after removing the central state-atom limits, so
/// the node validates locally, bounded by the same wire capacity.
func _isBoundedDirectoryAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    _isBoundedWireAtom(value, maximumBytes: maximumBytes) && !value.contains("/")
}

/// Bounds an untrusted path parameter (e.g. a public read RPC's `{cid}`) to a
/// plausible CID BEFORE any storage lookup: non-empty, within wire capacity,
/// and a canonical CID round-trip.
public func isPlausibleCID(_ value: String) -> Bool {
    _isBoundedWireAtom(value) && CIDIdentity.isCanonical(value)
}

func _canonicalJSONEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
