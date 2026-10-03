import Foundation
import Lattice

/// Decode only canonical block bytes whose header identity matches `cid`.
func _contentBoundBlock(cid: String, data: Data) -> Block? {
    guard let block = Block(data: data), block.toData() == data,
          let header = try? BlockHeader(node: block), header.rawCID == cid else {
        return nil
    }
    return block
}
