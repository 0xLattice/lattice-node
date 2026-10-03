import Foundation

func _isAbsoluteChainPath(_ path: [String]) -> Bool {
    ChainAddress(path) != nil
}

/// The wire's structural atom capacity. Real CIDs and directories are much
/// smaller; canonical decoding supplies their semantic validation.
let _wireAtomCapacity = Int(UInt16.max)

func _isBoundedWireAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= maximumBytes
        && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

func _isBoundedDirectoryAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    _isBoundedWireAtom(value, maximumBytes: maximumBytes) && !value.contains("/")
}

func _canonicalJSONEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
