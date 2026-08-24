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
    /// Operator-declared public read URL for this node's chain (the browsable
    /// HTTPS base a browser can dial — a TLS-fronted hostname, not the P2P
    /// address, which Ivy constrains to IP literals). Optional and tolerant:
    /// absent on legacy hellos, ignored by legacy decoders, and self-declared —
    /// a consumer must verify the served genesis against the parent's on-chain
    /// anchor before trusting one.
    public let publicReadURL: String?

    public init(
        nexusGenesisCID: String,
        chainPath: [String],
        publicReadURL: String? = nil
    ) {
        version = Self.protocolVersion
        self.nexusGenesisCID = nexusGenesisCID
        self.chainPath = chainPath
        self.publicReadURL = publicReadURL
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

/// A declared public read URL, normalized (trimmed, no trailing slash) when it
/// is a plausible browser-dialable base: absolute http(s), a host, no
/// credentials/query/fragment, printable ASCII, bounded. Self-declared wire
/// data flows through here at every ingest point (config flag, hello, overlay
/// response); invalid values normalize to nil and are simply not carried —
/// tolerant, so a future grammar widening cannot cost a session.
public func normalizedPublicReadURL(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard _isBoundedWireAtom(trimmed, maximumBytes: maximumPublicReadURLBytes),
          // Relayed verbatim into explorer-facing JSON, so beyond the URL
          // grammar the string must never carry markup metacharacters.
          !trimmed.contains(where: { "\"'<>`\\".contains($0) }),
          var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil
    else { return nil }
    // Case-fold scheme and host so equal bases dedupe as equal strings — a
    // case variant must not consume an extra endpoint slot. Rebuild only on
    // an actual case change; the common already-lowercase input keeps its
    // exact bytes (no parser round-trip on the hot path).
    var normalized: String
    if components.scheme == scheme, host == host.lowercased() {
        normalized = trimmed
    } else {
        components.scheme = scheme
        components.host = host.lowercased()
        guard let rebuilt = components.string else { return nil }
        normalized = rebuilt
    }
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized.isEmpty ? nil : normalized
}

/// Far above any real base URL while keeping relayed self-declared strings
/// small on the wire and in per-peer state.
public let maximumPublicReadURLBytes = 2048

/// Bounds an untrusted path parameter (e.g. a public read RPC's `{cid}`) to a
/// plausible CID BEFORE any storage lookup: non-empty, within wire capacity,
/// and a canonical CID round-trip.
public func isPlausibleCID(_ value: String) -> Bool {
    _isBoundedWireAtom(value) && CIDIdentity.isCanonical(value)
}

/// Dispatch for a dual height-or-CID route parameter (the explorer's
/// `/api/block/:id`). Heights win: digit-only strings like "161" ALSO
/// round-trip as canonical CIDs (base58 CIDv0 with a 1-byte identity
/// multihash), so CID-first dispatch would permanently 404 every height
/// whose decimal form happens to parse that way. Real block CIDs are
/// digest CIDs, never bare digit runs, so height-first is unambiguous.
public enum ExplorerBlockID: Equatable {
    case height(UInt64)
    case cid(String)
    case invalid
}

public func explorerBlockID(_ value: String) -> ExplorerBlockID {
    if let height = UInt64(value) { return .height(height) }
    if isPlausibleCID(value) { return .cid(value) }
    return .invalid
}

func _canonicalJSONEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
