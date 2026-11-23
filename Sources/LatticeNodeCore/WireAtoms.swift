// The wire's atoms (CIDs, directories, work IDs): bounded printable ASCII.
// Peers, clients and template assembly all check against the same bound.

/// The wire's structural atom capacity. Real CIDs and directories are much
/// smaller; canonical decoding supplies their semantic validation.
package let _wireAtomCapacity = Int(UInt16.max)

package func _isBoundedWireAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.count <= maximumBytes
        && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

package func _isBoundedDirectoryAtom(_ value: String, maximumBytes: Int = _wireAtomCapacity) -> Bool {
    _isBoundedWireAtom(value, maximumBytes: maximumBytes) && !value.contains("/")
}
