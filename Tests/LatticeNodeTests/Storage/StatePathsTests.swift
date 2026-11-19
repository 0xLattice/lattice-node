import Foundation
import XCTest
import cashew
@testable import LatticeNode

/// A state stored by position: after every block, the rows the changes of
/// its new state leave are exactly the rows of that state, read whole. So
/// a node that applies them holds the state each block committed to, and
/// nothing else.
final class StatePathsTests: XCTestCase {
    private typealias Trie = VolumeMerkleDictionaryImpl<String>
    private typealias TrieHeader = VolumeImpl<Trie>

    /// Content by CID, as a store holds it.
    private final class Store: Fetcher, @unchecked Sendable {
        private let lock = NSLock()
        private var nodes: [String: Data] = [:]

        func fetch(rawCid: String) async throws -> Data {
            guard let data = lock.withLock({ nodes[rawCid] }) else { throw DataErrors.nodeNotAvailable }
            return data
        }

        /// Every loaded node of `header`.
        func add(_ header: any Header) {
            guard let node = header.node, let data = node.toData() else { return }
            lock.withLock { nodes[header.rawCID] = data }
            for property in node.properties() {
                if let child = node.get(property: property) { add(child) }
            }
        }
    }

    /// Rows by path, sorted as a table keeps them.
    private struct Table: Equatable {
        var rows: [Data: String] = [:]

        mutating func apply(_ changes: [StatePaths.Change]) {
            for change in changes {
                switch change {
                case .put(let path, let cid, _):
                    rows[path] = cid
                case .clear(let from, let to):
                    for path in rows.keys
                    where !path.lexicographicallyPrecedes(from) && path.lexicographicallyPrecedes(to) {
                        rows[path] = nil
                    }
                }
            }
        }
    }

    /// The rows of `header`'s state read whole.
    private func wholeRows(_ header: TrieHeader, from store: Store) async throws -> Table {
        let whole = try await header.resolveRecursive(fetcher: store)
        var table = Table()
        table.apply(try StatePaths.changes(to: whole))
        return table
    }

    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        /// Keys over a small alphabet, so tries split and merge often.
        mutating func key() -> String {
            String((0..<(1 + next(6))).map { _ in Array("abc")[next(3)] })
        }
    }

    /// A block changes some keys as execution does: it loads what it
    /// reads, proves what it writes, and transforms the trie.
    private func block(
        on header: TrieHeader, model: inout [String: String], store: Store, _ random: inout Generator
    ) async throws -> TrieHeader {
        var proofs: [[String]: SparseMerkleProof] = [:]
        var transforms: [[String]: Transform] = [:]
        var resolve: [[String]: ResolutionStrategy] = [:]
        for _ in 0..<(1 + random.next(5)) {
            let key = random.key()
            guard transforms[[key]] == nil else { continue }
            resolve[[key]] = .targeted
            let value = "v\(random.next(1_000))"
            switch (model[key], random.next(3)) {
            case (nil, _):
                (proofs[[key]], transforms[[key]], model[key]) = (.insertion, .insert(value), value)
            case (_?, 0):
                (proofs[[key]], transforms[[key]], model[key]) = (.deletion, .delete, nil)
            default:
                (proofs[[key]], transforms[[key]], model[key]) = (.mutation, .update(value), value)
            }
        }
        // A key read, not written: loaded and left as it was.
        resolve[[random.key()]] = .targeted
        let resolved = try await header.resolve(paths: resolve, fetcher: store)
        let proven = try await resolved.proof(paths: proofs, fetcher: store)
        return try XCTUnwrap(try proven.transform(transforms: transforms))
    }

    func testTheRowsAfterEachBlockAreTheRowsOfItsState() async throws {
        for seed in 1...40 {
            var random = Generator(state: UInt64(seed))
            let store = Store()
            var model: [String: String] = [:]
            var header = try TrieHeader(node: Trie(children: [:], count: 0))
            header = try XCTUnwrap(try header.transform(transforms: [["ab"]: .insert("v0"), ["b"]: .insert("v1")]))
            (model["ab"], model["b"]) = ("v0", "v1")
            store.add(header)
            var table = Table()
            table.apply(try StatePaths.changes(to: header))
            for height in 1...60 {
                // As a block finds it: its root's hash only.
                let stored = TrieHeader(rawCID: header.rawCID)
                header = try await block(on: stored, model: &model, store: store, &random)
                table.apply(try StatePaths.changes(to: header))
                store.add(header)
                let expected = try await wholeRows(header, from: store)
                XCTAssertEqual(table, expected, "seed \(seed), block \(height): the rows are not the state's")
                if table != expected { return }
            }
            let whole = try await TrieHeader(rawCID: header.rawCID).resolveRecursive(fetcher: store)
            let keys = try whole.node?.allKeysAndValues()
            XCTAssertEqual(keys, model, "seed \(seed): the trie holds what was written")
        }
    }
}
