import Foundation
import Ivy
import cashew
@testable import LatticeNode

/// The one in-memory content store for tests: keyed entries (first write
/// wins; `insert` overwrites) plus every serialized volume stored through it,
/// served through each content protocol the node speaks.
actor InMemoryContentStore: Fetcher, Storer, VolumeStorer, ContentSource, IvyContentSource {
    private var entries: [String: Data] = [:]
    private var volumes: [String: SerializedVolume] = [:]

    init() {}

    // MARK: Fetcher / ContentSource

    func fetch(rawCid: String) throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        entries.filter { cids.contains($0.key) }
    }

    // MARK: Storer / VolumeStorer

    func store(entries newEntries: [String: Data]) {
        entries.merge(newEntries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) {
        entries.merge(volume.entries) { existing, _ in existing }
        volumes[volume.root] = volume
    }

    /// Overwrites `cid` (the stores above keep the first write).
    func insert(_ data: Data, for cid: String) {
        entries[cid] = data
    }

    func allEntries() -> [String: Data] { entries }

    func volume(root: String) -> SerializedVolume? { volumes[root] }

    // MARK: IvyContentSource

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        var total = 0
        var served: [ContentEntry] = []
        for cid in cids {
            guard let data = entries[cid] else { return [] }
            total += data.count
            guard total <= maxDataBytes else { return [] }
            served.append(ContentEntry(cid: cid, data: data))
        }
        return served
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard let volume = volumes[rootCID],
              volume.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}
