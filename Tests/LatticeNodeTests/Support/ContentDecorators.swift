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

/// Serves a map but parks any request naming `blockedCID` until released;
/// `waitForBlockedFetch` resumes once that request has arrived.
actor BlockingContentSource: ContentSource {
    private struct Waiter {
        let entries: [String: Data]
        let continuation: CheckedContinuation<[String: Data], Never>
    }

    private let blockedCID: String
    private var entries: [String: Data] = [:]
    private var blockedFetchStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedFetchWaiters: [Waiter] = []

    init(blockedCID: String) {
        self.blockedCID = blockedCID
    }

    func setEntries(_ entries: [String: Data]) {
        self.entries = entries
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        let found = entries.filter { cids.contains($0.key) }
        guard cids.contains(blockedCID) else { return found }

        blockedFetchStarted = true
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        guard !released else { return found }

        return await withCheckedContinuation { continuation in
            blockedFetchWaiters.append(Waiter(
                entries: found,
                continuation: continuation
            ))
        }
    }

    func waitForBlockedFetch() async {
        guard !blockedFetchStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedFetch() {
        released = true
        let pending = blockedFetchWaiters
        blockedFetchWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: waiter.entries)
        }
    }
}

/// An Ivy content source holding exactly one serialized volume.
struct VolumeSource: IvyContentSource, Sendable {
    let value: SerializedVolume

    init(one value: SerializedVolume) {
        self.value = value
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        guard rootCID == value.root,
              cids.allSatisfy({ value.entries[$0] != nil }),
              cids.reduce(0, { $0 + value.entries[$1]!.count }) <= maxDataBytes
        else { return [] }
        return cids.map { cid in
            ContentEntry(cid: cid, data: value.entries[cid]!)
        }
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

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        []
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

/// Serves one volume, but parks the request for it until released.
actor BlockingVolumeSource: IvyContentSource {
    let value: SerializedVolume
    private var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: SerializedVolume) {
        self.value = value
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID == value.root else { return [] }
        started = true
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard value.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes else {
            return []
        }
        return value.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }

    func didStart() -> Bool { started }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

/// Serves `base`, except `gatedRoot`'s Volume, which it refuses until
/// `events` holds `opensOn`: a holder that serves a block only once the
/// exchange that should have found it has happened.
actor GatedVolumeSource: IvyContentSource {
    private let base: InMemoryContentStore
    private let gatedRoot: String
    private let opensOn: String
    private let events: NetworkEventRecorder

    init(
        base: InMemoryContentStore,
        gatedRoot: String,
        opensOn: String,
        events: NetworkEventRecorder
    ) {
        self.base = base
        self.gatedRoot = gatedRoot
        self.opensOn = opensOn
        self.events = events
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        guard await isOpen(rootCID) else { return [] }
        return await base.content(rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes)
    }

    private func isOpen(_ rootCID: String) async -> Bool {
        guard rootCID == gatedRoot else { return true }
        return await events.snapshot().contains(opensOn)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        // `base.volume(root:)`, not the `volume(rootCID:maxDataBytes:)`
        // requirement: in an async context that call resolves to Ivy's async
        // default, which serves nothing.
        guard await isOpen(rootCID),
              let volume = await base.volume(root: rootCID),
              volume.entries.values.reduce(0, { $0 + $1.count }) <= maxDataBytes
        else { return [] }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}
