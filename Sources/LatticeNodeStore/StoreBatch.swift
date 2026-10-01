import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// One durable write: the content it references and the log rows that
/// reference it, applied by `Store.apply` in one transaction.
public struct StoreBatch: Sendable {
    /// Content by CID: header nodes, child indexes, materialized states,
    /// level specs.
    public var content: [String: Data] = [:]
    /// Each level's facts, in the order the core emitted them.
    public var levels: [(path: ChainPath, facts: [BlockImportBatch])] = []
    /// Levels this host starts running (the root's record at first boot).
    /// A record for a path that already has one replaces it: replay starts
    /// that path's facts again from this record.
    public var added: [LevelRecord] = []
    /// Levels this host stops running: replay drops them.
    public var removed: [ChainPath] = []

    public init() {}

    /// One level's persist effect.
    public init(_ batch: PersistBatch, at path: ChainPath) throws {
        try add(batch, at: path)
    }

    /// The host core's persist effect. Its genesis links are not stored:
    /// Lattice 41 deletes them (decision 18d).
    // LATTICE 41: `issued` and `PersistBatch.genesisLinks` disappear.
    public init(_ batch: HostBatch) throws {
        removed = batch.removed
        for record in batch.added { try add(record) }
        for (path, level) in batch.levels { try add(level, at: path) }
    }

    public mutating func add(_ batch: PersistBatch, at path: ChainPath) throws {
        for header in batch.headers {
            try Self.materialized(BlockHeader(node: header.block), into: &content)
            try Self.materialized(HeaderImpl<ChildIndex>(node: header.children), into: &content)
        }
        for state in batch.states {
            try Self.materialized(LatticeStateHeader(node: state), into: &content)
        }
        levels.append((path, batch.facts))
    }

    public mutating func add(_ record: LevelRecord) throws {
        try Self.materialized(BlockHeader(node: record.genesis.block), into: &content)
        try Self.materialized(HeaderImpl<ChildIndex>(node: record.genesis.children), into: &content)
        try Self.materialized(VolumeImpl<ChainSpec>(node: record.spec), into: &content)
        added.append(record)
    }

    /// Every materialized node under `header`, by CID: what an in-memory
    /// value holds that the store must keep. Unresolved links are content
    /// held elsewhere (or not yet fetched) and are skipped.
    // cashew keeps its own materialized walk internal; a public one there
    // would replace this.
    static func materialized(_ header: any Header, into entries: inout [String: Data]) throws {
        guard entries[header.rawCID] == nil, let node = header.node else { return }
        guard header.encryptionInfo == nil, let data = node.toData() else {
            throw StoreError.corrupt("cannot serialize \(header.rawCID)")
        }
        // Verify, don't trust: the bytes stored under a CID hash to it.
        try header.verifyData(data, matches: header.rawCID)
        entries[header.rawCID] = data
        var links = node.properties().sorted().compactMap { node.get(property: $0) }
        if let radix = node as? any RadixNode, let value = radix.value as? any Header {
            links.append(value)
        }
        for link in links { try materialized(link, into: &entries) }
    }
}
