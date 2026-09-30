import Foundation
import VolumeBroker
import cashew
@testable import LatticeNode

/// One broker write a test can fail or park at: a Volume store naming a
/// root, a retained-root merge or advance of a scope, or a batch pin for an
/// owner.
enum BrokerStep: Hashable, Sendable {
    case store(root: String)
    case merge(scope: String)
    case advance(scope: String)
    case pinBatch(owner: String)
    case unpinBatch(owner: String)
}

/// The error an armed step throws, before the wrapped broker sees the call.
struct InjectedBrokerFault: Error, Equatable {
    let step: BrokerStep
}

/// Wraps a `DiskBroker`. Each armed step fails (or parks until released) the
/// next time it is reached, BEFORE the wrapped broker applies it, so a test
/// sees exactly what a crash or refusal at that boundary leaves behind.
/// Unarmed calls, and every requirement without a step, pass straight
/// through to the wrapped broker.
actor FaultInjectingBroker: RetainedRootMergeBroker {
    private let broker: DiskBroker
    private var failures: Set<BrokerStep> = []
    private var parks: Set<BrokerStep> = []
    private var parked: [BrokerStep: CheckedContinuation<Void, Never>] = [:]
    private var reached: [BrokerStep] = []

    nonisolated var near: (any VolumeBroker)? { broker.near }
    nonisolated var far: (any VolumeBroker)? { broker.far }

    init(broker: DiskBroker) {
        self.broker = broker
    }

    /// The next call reaching `step` throws `InjectedBrokerFault`.
    func failNext(_ step: BrokerStep) {
        failures.insert(step)
    }

    /// The next call reaching `step` parks until `release(step)`.
    func parkNext(_ step: BrokerStep) {
        parks.insert(step)
    }

    /// Returns once a call is parked at `step`, and throws
    /// `TestWaitError.timedOut` if none parks within the (scaled) deadline,
    /// so a park no call reaches fails the test instead of hanging it.
    nonisolated func waitUntilParked(
        _ step: BrokerStep,
        within: Duration = .seconds(10)
    ) async throws {
        try await eventually("a call parks at \(step)", within: within) {
            await self.isParked(step)
        }
    }

    private func isParked(_ step: BrokerStep) -> Bool {
        parked[step] != nil
    }

    func release(_ step: BrokerStep) {
        parked.removeValue(forKey: step)?.resume()
    }

    /// Every step reached, in order, armed or not.
    func reachedSteps() -> [BrokerStep] {
        reached
    }

    private func reach(_ step: BrokerStep) async throws {
        reached.append(step)
        if failures.remove(step) != nil {
            throw InjectedBrokerFault(step: step)
        }
        guard parks.remove(step) != nil else { return }
        await withCheckedContinuation { parked[step] = $0 }
    }

    func storeVolumesLocal(_ volumes: [SerializedVolume]) async throws {
        for volume in volumes {
            try await reach(.store(root: volume.root))
        }
        try await broker.storeVolumesLocal(volumes)
    }

    func mergeRetainedRoots(scope: String, roots: [String]) async throws {
        try await reach(.merge(scope: scope))
        try await broker.mergeRetainedRoots(scope: scope, roots: roots)
    }

    func advanceRetainedRoots(scope: String, roots: [String]) async throws {
        try await reach(.advance(scope: scope))
        try await broker.advanceRetainedRoots(scope: scope, roots: roots)
    }

    func pinBatch(roots: [String], owner: String) async throws {
        try await reach(.pinBatch(owner: owner))
        try await broker.pinBatch(roots: roots, owner: owner)
    }

    func store(volume: SerializedVolume) async throws {
        try await storeVolumesLocal([volume])
    }

    func hasVolume(root: String) async -> Bool {
        await broker.hasVolume(root: root)
    }

    func fetchVolumeLocal(root: String) async -> SerializedVolume? {
        await broker.fetchVolumeLocal(root: root)
    }

    func fetchDataLocal(cid: String) async -> Data? {
        await broker.fetchDataLocal(cid: cid)
    }

    func fetchDataLocal(cids: Set<String>) async -> [String: Data] {
        await broker.fetchDataLocal(cids: cids)
    }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        await broker.fetch(cids)
    }

    func fetch(rawCid: String) async throws -> Data {
        try await broker.fetch(rawCid: rawCid)
    }

    func retainedRoots(scope: String) async throws -> [String] {
        try await broker.retainedRoots(scope: scope)
    }

    func pin(
        root: String,
        owner: String,
        count: Int,
        ttl: Duration?
    ) async throws {
        try await broker.pin(root: root, owner: owner, count: count, ttl: ttl)
    }

    func unpinBatch(
        items: [(root: String, owner: String, count: Int)]
    ) async throws {
        if let owner = items.first?.owner {
            try await reach(.unpinBatch(owner: owner))
        }
        try await broker.unpinBatch(items: items)
    }

    func unpin(root: String, owner: String, count: Int) async throws {
        try await broker.unpin(root: root, owner: owner, count: count)
    }

    func unpinAll(owner: String) async throws {
        try await broker.unpinAll(owner: owner)
    }

    func owners(root: String) async -> Set<String> {
        await broker.owners(root: root)
    }

    func evictUnpinned() async throws -> Int {
        try await broker.evictUnpinned()
    }
}
