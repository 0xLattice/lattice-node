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

        func record(_ response: AttributedVolumeResponse, complete: Bool) {
            lock.lock()
            if let peer = response.servedBy {
                peerPublicKeys.insert(peer.publicKey)
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
                contentUnavailable: unavailable
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
        private var bundle: Task<AuthenticatedPeer?, Never>?
        /// Bundled Volumes not yet asked for, and what holding them costs.
        private var held: [String: AttributedVolumeResponse] = [:]
        private var heldByteCount = 0
        private var accountedMembers = Set<String>()
        private var storageByteCount = 0
        private var storedRoots: [String] = []

        init(rootCID: String, maximumStorageBytes: Int) {
            self.rootCID = rootCID
            self.maximumStorageBytes = maximumStorageBytes
        }

        func cached(_ cids: Set<String>) async -> [String: Data] {
            await broker.fetch(cids)
        }

        var accountedBytes: Int { lock.withLock { storageByteCount } }

        /// Whether the session may fetch at all: false when it was cancelled
        /// waiting for its reservation, which it then never got.
        var reserved: Bool { maximumStorageBytes > 0 }

        /// The Volumes this session requested and verified, whole.
        func verifiedVolumes() async -> [SerializedVolume] {
            var volumes: [SerializedVolume] = []
            for root in lock.withLock({ storedRoots }) {
                if let volume = await broker.fetchVolume(root: root) { volumes.append(volume) }
            }
            return volumes
        }

        func reserve(rootCID: String) -> Bool {
            lock.withLock { attemptedRoots.insert(rootCID).inserted }
        }

        /// The Volume a peer's bundle of this session's root holds for
        /// `rootCID`, and the session that sent it. The bundle is requested
        /// once, on the session's first miss. A Volume from it is unverified
        /// and uncredited until it is taken as the answer to a request for
        /// its root.
        func bundled(
            _ rootCID: String,
            fetch: @escaping BundleFetch
        ) async -> (volume: AttributedVolumeResponse, session: AuthenticatedPeer?)? {
            let task = lock.withLock {
                if let bundle { return bundle }
                let task = Task { [root = self.rootCID] in
                    let answer = await fetch(root)
                    self.hold(answer.volumes)
                    return answer.session
                }
                bundle = task
                return task
            }
            let session = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            let volume: AttributedVolumeResponse? = lock.withLock {
                guard let volume = held.removeValue(forKey: rootCID) else { return nil }
                heldByteCount -= Self.retainedBytes(volume)
                return volume
            }
            return volume.map { ($0, session) }
        }

        private static func retainedBytes(_ volume: AttributedVolumeResponse) -> Int {
            volume.entries.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.count + IvyRootContentSource.retainedEntryOverhead
            }
        }

        /// What is held aside shares the session's one byte budget with what
        /// is stored; Volumes past it are dropped, and requested if the
        /// traversal needs them.
        private func hold(_ volumes: [AttributedVolumeResponse]) {
            lock.withLock {
                for volume in volumes where held[volume.rootCID] == nil {
                    let bytes = Self.retainedBytes(volume)
                    guard bytes <= maximumStorageBytes - storageByteCount - heldByteCount else { break }
                    heldByteCount += bytes
                    held[volume.rootCID] = volume
                }
            }
        }

        /// The session is over: a bundle still on its way is not waited for.
        func cancelBundle() {
            lock.withLock { bundle }?.cancel()
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
                // Stored content takes the budget from what is only held aside.
                while heldByteCount > maximumStorageBytes - storageByteCount,
                      let dropped = held.popFirst() {
                    heldByteCount -= Self.retainedBytes(dropped.value)
                }
                return true
            }
            guard fits else {
                trace.markOverBudget()
                return false
            }
            do {
                try await broker.store(volume: volume)
                lock.withLock { storedRoots.append(volume.root) }
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
    /// stored with that block), or none, and the session that sent them.
    /// Whatever a bundle lacks is fetched with `fetch`. The capable sessions
    /// the DHT names under the block's chain rendezvous are asked before the
    /// others; the record is a hint for whom to ask, never for what to accept.
    fileprivate typealias BundleFetch =
        @Sendable (String) async -> (volumes: [AttributedVolumeResponse], session: AuthenticatedPeer?)
    private let fetchBundle: @Sendable (_ rootCID: String, _ hosts: ChainHosts?) async
        -> (volumes: [AttributedVolumeResponse], session: AuthenticatedPeer?)
    /// Credits the peer that served a requested Volume once it verifies, so
    /// the overlay favours peers that serve this node when it is contended.
    private let credit: @Sendable (PeerID, Int) async -> Void
    /// Reports the peer that served a Volume failing its check for a root:
    /// the bytes it sent are not what their CIDs name.
    private let report: @Sendable (String, PeerID) async -> Void
    /// What the connected peers' hellos said they speak: who a bundle is asked of.
    let peerCapabilities = PeerCapabilities()
    /// The most bytes one session may hold: what a session reserves when
    /// nothing smaller bounds its content.
    let maximumStorageBytes: Int
    /// The node's one budget every session reserves from.
    let budget: AcquisitionBudget

    public final class Session: ContentSource {
        private let fetchVolume: @Sendable (String) async -> AttributedVolumeResponse
        private let fetchBundle: BundleFetch
        private let credit: @Sendable (PeerID, Int) async -> Void
        private let report: @Sendable (String, PeerID) async -> Void
        private let peerCapabilities: PeerCapabilities
        private let context: Context

        fileprivate init(
            rootCID: String,
            maximumStorageBytes: Int,
            fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse,
            fetchBundle: @escaping BundleFetch,
            credit: @escaping @Sendable (PeerID, Int) async -> Void,
            report: @escaping @Sendable (String, PeerID) async -> Void,
            peerCapabilities: PeerCapabilities
        ) {
            self.fetchVolume = fetch
            self.fetchBundle = fetchBundle
            self.credit = credit
            self.report = report
            self.peerCapabilities = peerCapabilities
            context = Context(rootCID: rootCID, maximumStorageBytes: maximumStorageBytes)
        }

        fileprivate func acceptInitialResponse(
            _ response: AttributedVolumeResponse
        ) async {
            guard context.reserved else { return context.trace.markIncomplete() }
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            let valid = response.rootCID == context.rootCID
                && (try? volume.validate()) != nil
                && context.reserve(rootCID: context.rootCID)
            let complete = valid ? await context.store(volume) : false
            if complete { await creditServer(of: response, volume: volume) }
            if !valid, let peer = response.servedBy { await report(context.rootCID, peer) }
            context.trace.record(response, complete: complete)
        }

        public func fetch(_ cids: Set<String>) async -> [String: Data] {
            guard !cids.isEmpty,
                  cids.allSatisfy({ _isBoundedWireAtom($0) }) else {
                return [:]
            }
            let cached = await context.cached(cids)
            // Cancelled before its reservation: nothing is asked of peers.
            for rootCID in cids.subtracting(cached.keys).sorted() where context.reserved {
                guard context.reserve(rootCID: rootCID) else { continue }
                // A Volume that does not verify, bundled or requested, reports
                // the peer that sent it, and the Volume is then requested
                // again: a bad Volume costs its server, never the block.
                // A Volume nobody sent (none found, or this node's own
                // capacity or cancellation) blames no one and is not retried,
                // nor is one from a peer already reported here.
                var bundled = await context.bundled(rootCID, fetch: fetchBundle)
                var reported = Set<PeerID>()
                while true {
                    let response = if let bundled { bundled.volume } else { await fetchVolume(rootCID) }
                    let volume = SerializedVolume(
                        root: response.rootCID,
                        entries: response.entries
                    )
                    let valid = response.rootCID == rootCID
                        && (try? volume.validate()) != nil
                    let complete = valid ? await context.store(volume) : false
                    if complete { await creditServer(of: response, volume: volume) }
                    let blamed = valid ? nil : response.servedBy.flatMap { reported.insert($0).inserted ? $0 : nil }
                    if let blamed { await report(rootCID, blamed) }
                    context.trace.record(response, complete: complete)
                    guard !valid, bundled != nil || blamed != nil else { break }
                    if let session = bundled?.session {
                        peerCapabilities.revoke(ChainHandshake.volumeBundle, from: session)
                    }
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

        fileprivate func cancelBundle() { context.cancelBundle() }

        /// What the entries this session holds are charged against its budget.
        var accountedBytes: Int { context.accountedBytes }

        /// The Volumes this session requested and verified, whole: what a
        /// finished session leaves for later reads.
        func verifiedVolumes() async -> [SerializedVolume] { await context.verifiedVolumes() }

        /// Holds `volume`, which an earlier session requested and verified,
        /// as if this one had: within this session's reservation, crediting
        /// and blaming no one. Its reader checks what it reads again.
        func adopt(_ volume: SerializedVolume) async {
            guard context.reserved, context.reserve(rootCID: volume.root) else { return }
            _ = await context.store(volume)
        }

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
        report = Self.tallyReport(ivy)
        maximumStorageBytes = policy.maximumAcquisitionStorageBytes
        budget = AcquisitionBudget(capacity: policy.maximumAcquisitionBytes)
        // A Volume is taken at whatever size the wire carries and measured
        // here once verified: the size a peer declares is its claim, and a
        // declared size past the budget would say nothing about the block.
        fetch = { rootCID in await ivy.fetchVolume(rootCID: rootCID) }
        // Asked only of the sessions whose hello said they answer it, one at
        // a time, each read as still capable when its turn comes. A session
        // keeps the capability only while every bundle it is asked for ends
        // (whole, or "no bundle"): one whose answer ends any other way is
        // then fetched from one Volume at a time, like a peer that speaks no
        // bundles. An answer this node cut short or never asked for (its
        // own capacity or boundary, a request not sent, its cancellation)
        // reports a failure and is not the peer's. The current peers of the
        // block's chain are asked before the others.
        fetchBundle = { rootCID, hosts in
            var named = Set<Data>()
            if let hosts {
                named = Set(await capabilities.sessions(hosting: hosts, ivy: ivy).map(\.sessionID))
            }
            var asked = Set<Data>()
            while let peer = ({
                let left = capabilities.sessions(speaking: ChainHandshake.volumeBundle)
                    .filter { !asked.contains($0.sessionID) }
                return left.filter { named.contains($0.sessionID) }.randomElement() ?? left.randomElement()
            })() {
                asked.insert(peer.sessionID)
                let answer = await ivy.fetchVolumeBundle(rootCID: rootCID, from: [peer])
                if !answer.ended, answer.failure == nil, !Task.isCancelled {
                    capabilities.revoke(ChainHandshake.volumeBundle, from: peer)
                }
                if !answer.volumes.isEmpty { return (answer.volumes, peer) }
            }
            return ([], nil)
        }
    }

    /// Credit verified content to the serving peer in the overlay's Tally.
    private static func tallyCredit(_ ivy: Ivy) -> @Sendable (PeerID, Int) async -> Void {
        { peer, bytes in await ivy.tally.recordUsefulReceived(peer: peer, bytes: bytes) }
    }

    /// A peer that served a Volume failing its check broke the protocol
    /// provably: Tally records the violation.
    private static func tallyReport(_ ivy: Ivy) -> @Sendable (String, PeerID) async -> Void {
        { _, peer in await ivy.tally.recordProtocolViolation(peer: peer) }
    }

    init(
        maximumStorageBytes: Int = Self.defaultPolicy.maximumAcquisitionStorageBytes,
        budget: AcquisitionBudget? = nil,
        fetch: @escaping @Sendable (String) async -> AttributedVolumeResponse,
        fetchBundle: @escaping @Sendable (String) async -> [AttributedVolumeResponse] = { _ in [] },
        credit: @escaping @Sendable (PeerID, Int) async -> Void = { _, _ in },
        report: @escaping @Sendable (String, PeerID) async -> Void = { _, _ in }
    ) {
        self.credit = credit
        self.report = report
        self.maximumStorageBytes = maximumStorageBytes
        self.budget = budget ?? AcquisitionBudget(
            capacity: max(maximumStorageBytes, Self.defaultPolicy.maximumAcquisitionBytes)
        )
        self.fetch = fetch
        self.fetchBundle = { rootCID, _ in (await fetchBundle(rootCID), nil) }
    }

    public func withRoot<T: Sendable>(
        _ rootCID: String,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> T {
        let result = try await withRootTracing(rootCID, operation: operation)
        return result.value
    }

    /// Runs `operation` over a session for `rootCID`. The session reserves
    /// `reserving` bytes (at most `maximumStorageBytes`, which is also the
    /// default) from the node's budget before it starts, waiting in line
    /// at `priority` while they do not fit, holds at most that much, and
    /// releases it all when `operation` ends. It never reserves again: a
    /// bundle is held within the same reservation. A session cancelled
    /// while it waits reserves nothing and asks no peer.
    public func withRootTracing<T: Sendable>(
        _ rootCID: String,
        bundle: Bool = true,
        hosts: ChainHosts? = nil,
        initialResponse: AttributedVolumeResponse? = nil,
        capture: AttributionCapture? = nil,
        reserving bytes: Int? = nil,
        priority: AcquisitionBudget.Priority = .ownWork,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let bytes = min(max(bytes ?? maximumStorageBytes, 1), maximumStorageBytes)
        return try await budget.withReservation(bytes, priority: priority) { reserved in
            try await withSession(
                rootCID, bundle: bundle, hosts: hosts, initialResponse: initialResponse,
                capture: capture, maximumStorageBytes: reserved ?? 0, operation: operation
            )
        }
    }

    private func withSession<T: Sendable>(
        _ rootCID: String,
        bundle: Bool,
        hosts: ChainHosts?,
        initialResponse: AttributedVolumeResponse?,
        capture: AttributionCapture?,
        maximumStorageBytes: Int,
        operation: @Sendable (Session) async throws -> T
    ) async rethrows -> (value: T, attribution: Attribution) {
        let fetchBundle = fetchBundle
        let bundled: BundleFetch = { rootCID in
            bundle ? await fetchBundle(rootCID, hosts) : ([], nil)
        }
        let session = Session(
            rootCID: rootCID,
            maximumStorageBytes: maximumStorageBytes,
            fetch: fetch,
            fetchBundle: bundled,
            credit: credit,
            report: report,
            peerCapabilities: peerCapabilities
        )
        defer { session.cancelBundle() }
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
