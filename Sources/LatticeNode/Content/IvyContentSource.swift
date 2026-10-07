import Foundation
import Ivy
import Lattice
import Tally
import VolumeBroker
import cashew

/// A cashew source whose network request is always bound to the candidate root
/// selected by the caller. The root is never guessed from a frontier of CIDs.
public struct IvyRootContentSource: Sendable {
    private static let defaultPolicy = NodeResourcePolicy.default
    /// What a session is charged for each entry it holds, beyond the entry's
    /// CID and bytes: the heap a held entry costs in the session's set and
    /// its store's three tables (hash slots at their load, the owner set, the
    /// string and data headers). Measured at 273 to 430 bytes an entry
    /// (1,000 to 300,000 entries of 1 to 113 bytes, arm64 macOS) and rounded
    /// up, so the byte budget bounds memory however small a peer makes the
    /// entries it sends.
    static let retainedEntryOverhead = 512

    public struct Attribution: Sendable, Equatable {
        public let servedByPublicKeys: Set<String>
        public let allResponsesComplete: Bool
        public let localCapacityUnavailable: Bool
        /// Verified content this session received was past its byte budget
        /// by this node's own count: this node's choice, not content nobody
        /// served. Never a size a peer only declared.
        public let byteBudgetExceeded: Bool
        public let contentUnavailable: Bool
        public let deficientVolumeSuppliers: [String: Set<String>]

        public var soleRemoteSupplierPublicKey: String? {
            servedByPublicKeys.count == 1 ? servedByPublicKeys.first : nil
        }
    }

    public final class AttributionCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Attribution?

        public init() {}

        fileprivate func record(_ attribution: Attribution) {
            lock.withLock { value = attribution }
        }

        public func snapshot() -> Attribution? {
            lock.withLock { value }
        }
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var peerPublicKeys: Set<String> = []
        private var complete = true
        private var locallyLimited = false
        private var overBudget = false
        private var unavailable = false
        private var deficientVolumeSuppliers: [String: Set<String>] = [:]

        func record(
            _ response: AttributedVolumeResponse,
            requestedRoot: String,
            complete: Bool,
            providerDeficient: Bool
        ) {
            lock.lock()
            if let peer = response.servedBy {
                peerPublicKeys.insert(peer.publicKey)
                if providerDeficient {
                    deficientVolumeSuppliers[
                        requestedRoot,
                        default: []
                    ].insert(peer.publicKey)
                }
            }
            self.complete = self.complete && complete
            locallyLimited = locallyLimited
                || response.failure == .localCapacityUnavailable
            unavailable = unavailable || response == .empty
            lock.unlock()
        }

        func snapshot() -> Attribution {
            lock.lock()
            defer { lock.unlock() }
            return Attribution(
                servedByPublicKeys: peerPublicKeys,
                allResponsesComplete: complete,
                localCapacityUnavailable: locallyLimited,
                byteBudgetExceeded: overBudget,
                contentUnavailable: unavailable,
                deficientVolumeSuppliers: deficientVolumeSuppliers
            )
        }

        func markIncomplete() {
            lock.withLock { complete = false }
        }

        func markOverBudget() {
            lock.withLock { overBudget = true }
        }
    }

    private final class Context: @unchecked Sendable {
        let rootCID: String
        let trace = Trace()
        private let maximumStorageBytes: Int
        private let broker = MemoryBroker()
        private let lock = NSLock()
        private var attemptedRoots = Set<String>()
        private var bundle: Task<[String: AttributedVolumeResponse], Never>?
        private var accountedMembers = Set<String>()
        private var storageByteCount = 0

        init(rootCID: String, maximumStorageBytes: Int) {
            self.rootCID = rootCID
            self.maximumStorageBytes = maximumStorageBytes
        }

        func cached(_ cids: Set<String>) async -> [String: Data] {
            await broker.fetch(cids)
        }

        var accountedBytes: Int { lock.withLock { storageByteCount } }

        func reserve(rootCID: String) -> Bool {
            lock.withLock { attemptedRoots.insert(rootCID).inserted }
        }

        /// The Volume a peer's bundle of this session's root holds for
        /// `rootCID`. The bundle is requested once, on the session's first
        /// miss. A Volume from it is unverified and uncharged until it is
        /// taken as the answer to a request for its root.
        func bundled(
            _ rootCID: String,
            fetch: @escaping @Sendable (String) async -> [AttributedVolumeResponse]
        ) async -> AttributedVolumeResponse? {
            let task = lock.withLock {
                if let bundle { return bundle }
                let task = Task { [root = self.rootCID] in
                    Dictionary(
                        await fetch(root).map { ($0.rootCID, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                bundle = task
                return task
            }
            return await task.value[rootCID]
        }

        func store(_ volume: SerializedVolume) async -> Bool {
            let fits = lock.withLock {
                var addedStorageBytes = 0
                for (cid, data) in volume.entries
                    where !accountedMembers.contains(cid) {
                    let framed = cid.utf8.count
                        .addingReportingOverflow(data.count)
                    guard !framed.overflow else { return false }
                    let framedWithOverhead = framed.partialValue
                        .addingReportingOverflow(IvyRootContentSource.retainedEntryOverhead)
                    guard !framedWithOverhead.overflow else { return false }
                    let next = addedStorageBytes.addingReportingOverflow(
                        framedWithOverhead.partialValue
                    )
                    guard !next.overflow else { return false }
                    addedStorageBytes = next.partialValue
                }
                let nextStorageBytes = storageByteCount.addingReportingOverflow(
                    addedStorageBytes
                )
                guard !nextStorageBytes.overflow,
                      nextStorageBytes.partialValue <= maximumStorageBytes else {
                    return false
                }
                accountedMembers.formUnion(volume.entries.keys)
                storageByteCount = nextStorageBytes.partialValue
                return true
            }
            guard fits else {
                trace.markOverBudget()
                return false
            }
            do {
                try await broker.store(volume: volume)
                return true
            } catch {
                return false
            }
        }

        func volume(rootCID: String) async -> SerializedVolume? {
            guard rootCID == self.rootCID else { return nil }
            return await broker.fetchVolume(root: rootCID)
        }
    }

    private let fetch: @Sendable (String) async -> AttributedVolumeResponse
    /// The Volumes a peer that speaks bundles holds under a root (what it
    /// stored with that block), or none. Whatever a bundle lacks is fetched
    /// with `fetch`.
    private let fetchBundle: @Sendable (String) async -> [AttributedVolumeResponse]
    /// Credits the peer that served a requested Volume once it verifies, so
    /// the overlay favours peers that serve this node when it is contended.
    private let credit: @Sendable (PeerID, Int) async -> Void
    /// What the connected peers' hellos said they speak: who a bundle is asked of.
    let peerCapabilities = PeerCapabilities()
    let maximumStorageBytes: Int

    public final class Session: ContentSource {
        private let fetchVolume: @Sendable (String) async -> AttributedVolumeResponse
        private let fetchBundle: @Sendable (String) async -> [AttributedVolumeResponse]
        private let credit: @Sendable (PeerID, Int) async -> Void
        private let context: Context

        fileprivate init(
            rootCID: String,
            maximumStorageBytes: Int,
            fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse,
            fetchBundle: @escaping @Sendable (String) async -> [AttributedVolumeResponse],
            credit: @escaping @Sendable (PeerID, Int) async -> Void
        ) {
            self.fetchVolume = fetch
            self.fetchBundle = fetchBundle
            self.credit = credit
            context = Context(rootCID: rootCID, maximumStorageBytes: maximumStorageBytes)
        }

        fileprivate func acceptInitialResponse(
            _ response: AttributedVolumeResponse
        ) async {
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            let valid = response.rootCID == context.rootCID
                && (try? volume.validate()) != nil
                && context.reserve(rootCID: context.rootCID)
            let complete = valid ? await context.store(volume) : false
            if complete { await creditServer(of: response, volume: volume) }
            context.trace.record(
                response,
                requestedRoot: context.rootCID,
                complete: complete,
                providerDeficient: !valid
            )
        }

        public func fetch(_ cids: Set<String>) async -> [String: Data] {
            guard !cids.isEmpty,
                  cids.allSatisfy({ _isBoundedWireAtom($0) }) else {
                return [:]
            }
            let cached = await context.cached(cids)
            for rootCID in cids.subtracting(cached.keys).sorted() {
                guard context.reserve(rootCID: rootCID) else { continue }
                // A bundled Volume that does not verify is its server's
                // deficiency, as a requested one's is, and the Volume is then
                // requested: a bad bundle costs its server, never the block.
                var bundled = await context.bundled(rootCID, fetch: fetchBundle)
                while true {
                    let response = if let bundled { bundled } else { await fetchVolume(rootCID) }
                    let volume = SerializedVolume(
                        root: response.rootCID,
                        entries: response.entries
                    )
                    let valid = response.rootCID == rootCID
                        && (try? volume.validate()) != nil
                    let complete = valid ? await context.store(volume) : false
                    if complete { await creditServer(of: response, volume: volume) }
                    context.trace.record(
                        response,
                        requestedRoot: rootCID,
                        complete: complete,
                        providerDeficient: !valid
                    )
                    guard bundled != nil, !valid else { break }
                    bundled = nil
                }
            }
            let result = await context.cached(cids)
            if result.count != cids.count {
                context.trace.markIncomplete()
                return [:]
            }
            return result
        }

        public var attribution: Attribution { context.trace.snapshot() }

        /// What the entries this session holds are charged against its budget.
        var accountedBytes: Int { context.accountedBytes }

        /// A Volume this session requested passed CID validation: credit the
        /// peer that served it with its bytes.
        private func creditServer(of response: AttributedVolumeResponse, volume: SerializedVolume) async {
            guard let peer = response.servedBy else { return }
            let bytes = volume.entries.values.reduce(0) { $0 + $1.count }
            await credit(peer, bytes)
        }

        func volume(rootCID: String) async -> SerializedVolume? {
            guard context.rootCID == rootCID else { return nil }
            if await context.volume(rootCID: rootCID) == nil {
                _ = await fetch([rootCID])
            }
            return await context.volume(rootCID: rootCID)
        }
    }

    public init(ivy: Ivy, policy: NodeResourcePolicy = .default) {
        let capabilities = peerCapabilities
        credit = Self.tallyCredit(ivy)
        maximumStorageBytes = policy.maximumAcquisitionStorageBytes
        // A Volume is taken at whatever size the wire carries and measured
        // here once verified: the size a peer declares is its claim, and a
        // declared size past the budget would say nothing about the block.
        fetch = { rootCID in await ivy.fetchVolume(rootCID: rootCID) }
        // Asked only of the sessions whose hello said they answer it.
        fetchBundle = { rootCID in
            await ivy.fetchVolumeBundle(
                rootCID: rootCID,
                from: capabilities.sessions(speaking: ChainHandshake.volumeBundle)
            ).volumes
        }
    }

    /// Credit verified content to the serving peer in the overlay's Tally.
    private static func tallyCredit(_ ivy: Ivy) -> @Sendable (PeerID, Int) async -> Void {
        { peer, bytes in await ivy.tally.recordUsefulReceived(peer: peer, bytes: bytes) }
    }

    init(
        maximumStorageBytes: Int = Self.defaultPolicy.maximumAcquisitionStorageBytes,
        fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse,
        fetchBundle: @escaping @Sendable (String) async -> [AttributedVolumeResponse] = { _ in [] },
        credit: @escaping @Sendable (PeerID, Int) async -> Void = { _, _ in }
    ) {
        self.credit = credit
        self.maximumStorageBytes = maximumStorageBytes
        self.fetch = fetch
        self.fetchBundle = fetchBundle
    }

    public func withRoot<T: Sendable>(
        _ rootCID: String,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> T {
        let result = try await withRootTracing(rootCID, operation: operation)
        return result.value
    }

    public func withRootTracing<T: Sendable>(
        _ rootCID: String,
        initialResponse: AttributedVolumeResponse? = nil,
        capture: AttributionCapture? = nil,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let session = Session(
            rootCID: rootCID,
            maximumStorageBytes: maximumStorageBytes,
            fetch: fetch,
            fetchBundle: fetchBundle,
            credit: credit
        )
        if let initialResponse {
            await session.acceptInitialResponse(initialResponse)
        }
        do {
            let value = try await operation(session)
            let attribution = session.attribution
            capture?.record(attribution)
            return (value, attribution)
        } catch {
            capture?.record(session.attribution)
            throw error
        }
    }
}

/// Serves complete local Volume boundaries from the recovered chain storage.
struct NodeStorageIvyContentSource: IvyContentSource {
    let storage: NodeStorage
    let transientRootVolume: (@Sendable (String) async -> SerializedVolume?)?

    init(
        storage: NodeStorage,
        transientRootVolume: (@Sendable (String) async -> SerializedVolume?)? = nil
    ) {
        self.storage = storage
        self.transientRootVolume = transientRootVolume
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry] {
        // Node protocol v3 exchanges complete Volumes. Entry selection cannot
        // prove membership in the named root and is therefore never served.
        []
    }

    func volumeBundle(rootCID: String) async -> [String] {
        await storage.volumeBundle(rootCID)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        let volume: SerializedVolume
        if let transient = await transientRootVolume?(rootCID) {
            volume = transient
        } else if let stored = await storage.volume(rootCID) {
            volume = stored
        } else {
            return []
        }
        guard (try? volume.validate()) != nil else { return [] }
        var remaining = maxDataBytes
        for data in volume.entries.values {
            guard data.count <= remaining else { return [] }
            remaining -= data.count
        }
        return volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }
    }
}
