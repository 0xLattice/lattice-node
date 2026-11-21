import Foundation
import Ivy
import VolumeBroker
import cashew
@testable import LatticeNode

/// Holds nothing: every fetch is a miss.
struct FailingFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

/// Content a chain assembles from more than one holder, in order.
struct UnionFetcher: Fetcher {
    let sources: [any Fetcher]
    init(_ sources: [any Fetcher]) { self.sources = sources }
    func fetch(rawCid: String) async throws -> Data {
        var last: any Error = DataErrors.nodeNotAvailable
        for source in sources {
            do { return try await source.fetch(rawCid: rawCid) } catch { last = error }
        }
        throw last
    }
}

/// Serves a fixed map and records every request set, in order.
actor RecordingContentSource: ContentSource {
    private let entries: [String: Data]
    private var recordedRequests: [Set<String>] = []

    init(entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) -> [String: Data] {
        recordedRequests.append(cids)
        return entries.filter { cids.contains($0.key) }
    }

    func requests() -> [Set<String>] {
        recordedRequests
    }
}

/// An Ivy content source holding exactly one serialized volume.
struct VolumeSource: IvyContentSource, Sendable {
    let value: SerializedVolume

    init(one value: SerializedVolume) {
        self.value = value
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        guard rootCID == value.root,
              value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}

/// Serves whole volumes only and records every root requested, in order.
actor RecordingVolumesSource: IvyContentSource {
    private let values: [String: SerializedVolume]
    private var requestedRoots: [String] = []

    init(_ values: [SerializedVolume]) {
        self.values = Dictionary(
            uniqueKeysWithValues: values.map { ($0.root, $0) }
        )
    }

    func volume(
        rootCID: String,
        maxDataBytes: Int
    ) -> [ContentEntry] {
        requestedRoots.append(rootCID)
        guard let value = values[rootCID],
              value.entries.values.reduce(0, { $0 + $1.count })
                <= maxDataBytes else { return [] }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }

    func requests() -> [String] { requestedRoots }
}
