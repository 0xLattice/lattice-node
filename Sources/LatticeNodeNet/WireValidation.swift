import LatticeNodeConfig
import Foundation

package func _isAbsoluteChainPath(_ path: [String]) -> Bool {
    ChainAddress(path) != nil
}

package func _canonicalJSONEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
