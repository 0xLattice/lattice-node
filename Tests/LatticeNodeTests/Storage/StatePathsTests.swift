import Foundation
import Lattice
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

    /// Rows by path, as a table keeps them.
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

    /// The rows of a state read whole, placed here, not by `StatePaths`:
    /// the root at the empty path, a sub-trie under its name and a 0 byte,
    /// a trie node at its trie's path and the key part it and its
    /// ancestors spell.
    private func oracle(_ header: any Header, from store: Store) async throws -> [Data: String] {
        let whole = try await header.resolveRecursive(fetcher: store)
        var rows: [Data: String] = [:]
        func place(_ header: any Header, at path: Data) {
            guard let node = header.node else { return }
            rows[path] = header.rawCID
            for property in node.properties() {
                guard let child = node.get(property: property) else { continue }
                if let radix = child.node as? any RadixNode {
                    place(child, at: path + Data(radix.prefix.utf8))
                } else {
                    place(child, at: path + Data(property.utf8) + [0])
                }
            }
        }
        place(whole, at: Data())
        return rows
    }

    private struct Generator {
        var state: UInt64
        let alphabet: [Character]
        let longest: Int

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        /// Keys that share prefixes, so tries split and merge often.
        mutating func key() -> String {
            String((0..<(1 + next(longest))).map { _ in alphabet[next(alphabet.count)] })
        }
    }

    /// A block changes some keys as execution does: it loads what it
    /// reads, proves what it writes, and transforms the trie. One write in
    /// `deletes` to a key that is there deletes it.
    private func block(
        on header: TrieHeader, model: inout [String: String], store: Store, deletes: Int, _ random: inout Generator
    ) async throws -> TrieHeader {
        var proofs: [[String]: SparseMerkleProof] = [:]
        var transforms: [[String]: Transform] = [:]
        var resolve: [[String]: ResolutionStrategy] = [:]
        for _ in 0..<(1 + random.next(5)) {
            let key = random.key()
            guard transforms[[key]] == nil else { continue }
            resolve[[key]] = .targeted
            let value = "v\(random.next(1_000))"
            switch (model[key], random.next(deletes)) {
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

    /// A block that deletes every key the trie holds.
    private func emptying(_ header: TrieHeader, model: inout [String: String], store: Store) async throws -> TrieHeader {
        guard !model.isEmpty else { return header }
        let keys = model.keys.map { [$0] }
        let resolved = try await header.resolve(
            paths: Dictionary(uniqueKeysWithValues: keys.map { ($0, ResolutionStrategy.targeted) }), fetcher: store
        )
        let proven = try await resolved.proof(
            paths: Dictionary(uniqueKeysWithValues: keys.map { ($0, SparseMerkleProof.deletion) }), fetcher: store
        )
        model = [:]
        return try XCTUnwrap(try proven.transform(
            transforms: Dictionary(uniqueKeysWithValues: keys.map { ($0, Transform.delete) })
        ))
    }

    /// Each key's value is in the row at `base` and the key.
    private func checkValues(_ model: [String: String], under base: Data, in table: Table, store: Store) async throws {
        for (key, value) in model {
            let row = try XCTUnwrap(table.rows[base + Data(key.utf8)], "no row for \(key)")
            let data = try await store.fetch(rawCid: row)
            XCTAssertEqual(VolumeRadixNodeImpl<String>(data: data)?.value, value, key)
        }
    }

    /// One trie, block after block; with `emptyEvery`, every so many blocks
    /// one deletes every key.
    private func runTrie(
        alphabet: String, longest: Int, deletes: Int, seeds: ClosedRange<Int>, blocks: Int, emptyEvery: Int? = nil
    ) async throws {
        for seed in seeds {
            var random = Generator(state: UInt64(seed), alphabet: Array(alphabet), longest: longest)
            let store = Store()
            var model: [String: String] = [:]
            var header = try TrieHeader(node: Trie(children: [:], count: 0))
            store.add(header)
            var table = Table()
            table.apply(try StatePaths.changes(to: header))
            for height in 1...blocks {
                // As a block finds it: its root's hash only.
                let found = TrieHeader(rawCID: header.rawCID)
                if let emptyEvery, height % emptyEvery == 0 {
                    header = try await emptying(found, model: &model, store: store)
                    XCTAssertEqual(model, [:])
                } else {
                    header = try await block(on: found, model: &model, store: store, deletes: deletes, &random)
                }
                table.apply(try StatePaths.changes(to: header))
                store.add(header)
                let expected = try await oracle(header, from: store)
                XCTAssertEqual(table.rows, expected, "seed \(seed), block \(height): the rows are not the state's")
                if table.rows != expected { return }
                try await checkValues(model, under: Data(), in: table, store: store)
            }
            let whole = try await TrieHeader(rawCID: header.rawCID).resolveRecursive(fetcher: store)
            XCTAssertEqual(try whole.node?.allKeysAndValues(), model, "seed \(seed): the trie holds what was written")
        }
    }

    func testTheRowsAfterEachBlockAreTheRowsOfItsState() async throws {
        try await runTrie(alphabet: "abc", longest: 6, deletes: 3, seeds: 1...40, blocks: 60)
    }

    /// Few keys, half the writes to them deletes, and every 20th block
    /// deleting them all: tries empty and fill again, and keys that begin
    /// others go and come back.
    func testATrieThatEmptiesAndFillsAgain() async throws {
        try await runTrie(alphabet: "ab", longest: 3, deletes: 2, seeds: 1...40, blocks: 80, emptyEvery: 20)
    }

    /// A chain's state: a root over four sub-tries. A block changes some of
    /// them; the others are their hashes only, and their rows stay.
    func testTheRowsOfAChainsStateWhoseBlocksChangeSomeSubTries() async throws {
        let generalBase = Data("generalState".utf8) + [0]
        for seed in 1...30 {
            var random = Generator(state: UInt64(seed), alphabet: Array("ab/c"), longest: 5)
            let store = Store()
            var general: [String: String] = [:]
            var receipts: [String: String] = [:]
            var state = LatticeState.emptyHeader
            store.add(state)
            var table = Table()
            table.apply(try StatePaths.changes(to: state))
            for height in 1...60 {
                let found = try await LatticeStateHeader(rawCID: state.rawCID).resolve(fetcher: store)
                let root = try XCTUnwrap(found.node)
                // Each sub-trie as a block finds it: its hash only.
                var properties: [String: any Header] = [
                    "accountState": AccountStateHeader(rawCID: root.accountState.rawCID),
                    "depositState": DepositStateHeader(rawCID: root.depositState.rawCID),
                    "generalState": TrieHeader(rawCID: root.generalState.rawCID),
                    "receiptState": TrieHeader(rawCID: root.receiptState.rawCID),
                ]
                let which = random.next(3)
                if which != 1 {
                    properties["generalState"] = try await block(
                        on: TrieHeader(rawCID: root.generalState.rawCID), model: &general, store: store, deletes: 3, &random
                    )
                }
                if which != 0 {
                    properties["receiptState"] = try await block(
                        on: TrieHeader(rawCID: root.receiptState.rawCID), model: &receipts, store: store, deletes: 3, &random
                    )
                }
                state = try LatticeStateHeader(node: root.set(properties: properties))
                table.apply(try StatePaths.changes(to: state))
                store.add(state)
                let expected = try await oracle(state, from: store)
                XCTAssertEqual(table.rows, expected, "seed \(seed), block \(height): the rows are not the state's")
                if table.rows != expected { return }
                try await checkValues(general, under: generalBase, in: table, store: store)
            }
        }
    }

    /// A key the path bytes cannot place exactly is refused, never placed
    /// wrong: with a combining mark, "é" begins with the byte of "e".
    func testAKeyThatIsNotASCIIIsRefused() throws {
        var header = try TrieHeader(node: Trie(children: [:], count: 0))
        header = try XCTUnwrap(try header.transform(transforms: [["e"]: .insert("v"), ["e\u{301}a"]: .insert("w")]))
        XCTAssertThrowsError(try StatePaths.changes(to: header)) { error in
            guard case StatePaths.Failure.unplaceableKey = error else { return XCTFail("\(error)") }
        }
    }
}
