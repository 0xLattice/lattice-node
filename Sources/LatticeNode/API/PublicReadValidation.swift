import Lattice

/// Reject an untrusted route parameter before any storage lookup unless it is
/// a canonical CID that fits the wire representation.
public func isPlausibleCID(_ value: String) -> Bool {
    _isBoundedWireAtom(value) && CIDIdentity.isCanonical(value)
}

/// A public explorer block selector. Decimal heights win because some digit
/// strings also parse as identity CIDs, while real block CIDs are digests.
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
