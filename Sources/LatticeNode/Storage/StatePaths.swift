import Foundation
import cashew

/// Where each node of a chain's state sits when the state is stored by
/// position, not by hash (rule 13 of the sync architecture): one row per
/// node, at a path, replaced in place when a block changes it.
///
/// A path is the node's place in the state, never its hash. The state's root
/// is at the empty path. A child of a node that is no trie (the state's four
/// sub-tries under `LatticeState`) is at its parent's path, its property's
/// name and a 0 byte. A trie node is at its parent's path and its own
/// prefix: in a compressed radix trie a node's path is the part of every key
/// below it that it and its ancestors spell, which a split or a merge of a
/// node does not change for anything below it. A 0xFF byte occurs in no
/// path (no UTF-8 text holds it), so a node's path followed by 0xFF bounds
/// every path below it.
///
/// A block's new state, as execution leaves it, holds a node for every node
/// the block changed or read; a node it did not touch is a hash only. What
/// it did not touch is where it was: execution loads a node before it
/// changes, splits or merges it, and a node it never loaded keeps its path.
/// So the rows of the new state are the old rows with each loaded node put
/// at its path, and every row below a loaded node removed but those under
/// its children.
enum StatePaths {
    /// A change to a chain's rows, applied in any order.
    enum Change: Equatable, Sendable {
        /// The node `cid`, `bytes` its encoding, is the row at `path`.
        case put(path: Data, cid: String, bytes: Data)
        /// No row has a path in `from..<to`.
        case clear(from: Data, to: Data)
    }

    enum Failure: Error, Equatable {
        /// A loaded node that does not encode.
        case unencodable(String)
    }

    /// What follows every path below a node's.
    static let end: UInt8 = 0xFF
    /// What follows a property's name in a path.
    static let separator: UInt8 = 0x00

    /// The changes that turn the rows of the state `root` was produced from
    /// into the rows of `root`. Applied to an empty table, the rows of the
    /// nodes of `root` that are loaded.
    static func changes(to root: any Header) throws -> [Change] {
        var changes: [Change] = []
        try walk(root, at: Data(), into: &changes)
        return changes
    }

    private static func walk(_ header: any Header, at path: Data, into changes: inout [Change]) throws {
        // Not loaded: not touched, so where it was, with all below it.
        guard let node = header.node else { return }
        guard let bytes = node.toData() else { throw Failure.unencodable(header.rawCID) }
        changes.append(.put(path: path, cid: header.rawCID, bytes: bytes))
        let trie = node is any RadixNode || node is any MerkleDictionary
        // The paths below this node that stay as they are or are written
        // below: each child's, and for a child not loaded every path that
        // starts as its edge does.
        var kept: [(from: Data, to: Data)] = []
        for property in node.properties().sorted() {
            guard let child = node.get(property: property) else { continue }
            let childPath: Data
            if trie {
                guard let loaded = child.node as? any RadixNode else {
                    let edge = path + Data(property.utf8)
                    kept.append((edge, edge + [end]))
                    continue
                }
                childPath = path + Data(loaded.prefix.utf8)
            } else {
                childPath = path + Data(property.utf8) + [separator]
            }
            kept.append((childPath, childPath + [end]))
            try walk(child, at: childPath, into: &changes)
        }
        // Every other path below this node is a node it no longer has.
        var from = path + [separator]
        let to = path + [end]
        for range in kept.sorted(by: { $0.from.lexicographicallyPrecedes($1.from) }) {
            if from.lexicographicallyPrecedes(range.from) {
                changes.append(.clear(from: from, to: range.from))
            }
            if from.lexicographicallyPrecedes(range.to) { from = range.to }
        }
        if from.lexicographicallyPrecedes(to) { changes.append(.clear(from: from, to: to)) }
    }
}
