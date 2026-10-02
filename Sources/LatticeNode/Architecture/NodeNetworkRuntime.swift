import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

public struct NetworkCandidateImport: Sendable {
    public let header: BlockHeader
    public let authenticatedChildPackage: AuthenticatedChildPackage?
    public let contentSource: any ContentSource
    /// Admit on the weighed (deferred-execution) tier: enter fork choice on
    /// verified work without executing. True for every network-sourced block
    /// (live gossip, frontier leaves, range-sync pages, predecessor walks);
    /// only locally produced blocks stay eager.
    public let weighed: Bool

    public init(
        header: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage?,
        contentSource: any ContentSource,
        weighed: Bool = false
    ) {
        self.header = header
        self.authenticatedChildPackage = authenticatedChildPackage
        self.contentSource = contentSource
        self.weighed = weighed
    }
}

final class RuntimeCallbackEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func current() -> UInt64 {
        lock.withLock { value }
    }
}

struct ParentStateQueryGuard {
    /// What one `acquire` took: releasing it frees the peer's slot only
    /// while the slot is still the one this acquire took.
    struct Hold {
        let peer: PeerKey
        fileprivate let token: LifetimeToken
    }

    let capacity: Int
    /// Each held peer, with the token of the acquire holding it.
    private(set) var peers: [PeerKey: LifetimeToken] = [:]

    mutating func acquire(_ peer: PeerKey) -> Hold? {
        guard peers.count < capacity, peers[peer] == nil else { return nil }
        let token = LifetimeToken.next()
        peers[peer] = token
        return Hold(peer: peer, token: token)
    }

    /// A handler that suspended across a stop and restart still holds its
    /// old token, so its release cannot free the slot a handler of the new
    /// generation took for the same peer.
    mutating func release(_ hold: Hold) {
        guard peers[hold.peer] == hold.token else { return }
        peers.removeValue(forKey: hold.peer)
    }

    mutating func removeAll() {
        peers.removeAll()
    }
}

enum NodePolicyDecline: Error {
    case chainSpecTooLarge
    case tooManyWasmPolicies
}

public enum NodeNetworkRuntimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
}

struct NodeNetworkPlaneConfigurations {
    let overlay: IvyConfig

    init(_ configuration: NodeConfiguration) throws {
        try self.init(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: configuration.listenPort,
                bootstrapPeers: configuration.bootstrapPeers,
                // Always keep headroom for outbound dials so an inbound burst from
                // a single source cannot exhaust total capacity and starve the
                // dials a node needs to bootstrap/cold-sync. Matters most when the
                // per-netgroup cap is relaxed (proxy-fronted nodes, below).
                reservedOutboundConnectionSlots: min(
                    NodeConfiguration.overlayReservedOutboundSlots,
                    IvyConfig.defaultMaxConnections - 1
                ),
                // Default: permissive (= the total connection cap). This is a
                // PUBLIC plane, and a per-netgroup connection cap is weak defense here: bad
                // data is rejected on CID/PoW verification, the reserved
                // outbound sync slots are protected by a separate inbound
                // ceiling, and behind an L4 proxy every peer shares one address
                // so a low cap just strangles the mesh. Operator-tunable; the
                // real per-source cost for a public direct-IP node is
                // minPeerKeyBits, not this bucket.
                maxConnectionsPerNetgroup: configuration.overlayMaxConnectionsPerNetgroup,
                minPeerKeyBits: configuration.minPeerKeyBits,
                // Self-described reachable address: provider announcements and
                // rendezvous records advertise this instead of the observed
                // (NAT/proxy-mangled) one.
                externalAddress: configuration.externalAddress.map {
                    (host: $0, port: configuration.listenPort)
                },
                mode: .overlay
            )
        )
    }

    init(overlay: IvyConfig) throws {
        guard overlay.mode == .overlay,
              overlay.inboundAdmissionBypassPeerKeys.isEmpty
        else {
            throw IvyModeError.invalidConfiguration(
                "network runtime requires an overlay plane"
            )
        }
        try overlay.validate()
        self.overlay = overlay
    }
}

/// The Ivy overlay for one recovered chain process: it carries same-chain
/// candidates and CAS content. A child reads its parent's facts in-process
/// through `ParentLevel`.
public actor NodeNetworkRuntime: IvyDelegate {
    typealias Candidate = BlockFetcher.Candidate
    typealias CandidateSeed = BlockFetcher.Seed
    private typealias CandidateWaitReason = BlockFetcher.WaitReason
    typealias DurableDescendant = BlockFetcher.DurableDescendant
    struct PendingTransactionInventory: Sendable {
        let peer: AuthenticatedPeer
        let request: TransactionInventoryRequestMessage
        let remainingRoots: Int
        let seenRoots: Set<String>
        let timeout: Task<Void, Never>
    }

    struct TransactionVolumeLease: Hashable {
        let sessionID: Data
        let rootCID: String
    }

    struct OverlayPeerRecord: PeerRecord {
        /// A key holds at most one session: connected and awaiting its
        /// hello, or hello accepted.
        enum Session {
            case awaitingHello(AuthenticatedPeer)
            case ready(AuthenticatedPeer)
        }

        var session: Session?
        var helloDeadline: HelloDeadline?
        /// Carries its own session ID (see `FrontierPull`).
        var frontierPull: FrontierPull?
        /// This session's tip claim, recorded for every claim — held tip or
        /// not — and whether the session has been asked, once, to page its
        /// chain from our fork point because blocks here park on missing
        /// ancestry (`syncMissingAncestryIfNeeded`).
        var ancestryClaim: AncestryClaim?
        /// The tallest tip the peer announced, with the session it came on.
        /// Kept across a reconnect: every reader compares its session.
        var announcedTip: (height: UInt64, peer: AuthenticatedPeer)?
        /// The peer's latest child-evidence index root (only the latest is
        /// kept: it supersedes every earlier one), and whether it is still
        /// to be walked against ours or searched for wanted blocks.
        /// Owner: Overlay.receiveChildEvidenceRoot / Overlay.wantChildEvidence /
        ///     Overlay.markChildEvidenceWalks / Overlay.runChildEvidenceSync /
        ///     Overlay.syncChildEvidence.
        var evidenceRoot: PeerEvidenceRoot?
        var evidenceWalkDirty = false
        var evidenceLookupDirty = false

        var isEmpty: Bool {
            session == nil && helloDeadline == nil && frontierPull == nil
                && ancestryClaim == nil
                && announcedTip == nil
                && evidenceRoot == nil
                && !evidenceWalkDirty && !evidenceLookupDirty
        }

        var liveSessionID: Data? { sessionPeer?.sessionID }

        /// The session whose hello was accepted.
        var readyPeer: AuthenticatedPeer? {
            guard case .ready(let peer)? = session else { return nil }
            return peer
        }

        /// The session still awaiting its hello.
        var awaitingHelloPeer: AuthenticatedPeer? {
            guard case .awaitingHello(let peer)? = session else { return nil }
            return peer
        }

        /// The session in either state.
        var sessionPeer: AuthenticatedPeer? {
            switch session {
            case .awaitingHello(let peer)?, .ready(let peer)?: return peer
            case nil: return nil
            }
        }
    }

    /// The overlay sessions whose hello was accepted, as a snapshot (a
    /// send loop over it is unaffected by a record removed mid-loop).
    var readyOverlayPeers: [AuthenticatedPeer] {
        overlayState.overlayRecords.records.values.compactMap(\.readyPeer)
    }

    /// Takes the key's overlay hello deadline out of its record: any
    /// session's (`session` nil, a connect replacing it), or only
    /// `session`'s.
    @discardableResult
    func removeOverlayHelloDeadline(
        for key: PeerKey,
        session: Data?
    ) -> HelloDeadline? {
        overlayState.overlayRecords.updateExisting(key) { record in
            let deadline = record.helloDeadline
            guard session == nil || deadline?.sessionID == session else { return nil }
            record.helloDeadline = nil
            return deadline
        } ?? nil
    }

    /// Every recorded announced tip with its key, as a snapshot.
    var recordedAnnouncedTips: [
        (key: PeerKey, value: (height: UInt64, peer: AuthenticatedPeer))
    ] {
        overlayState.overlayRecords.records.compactMap { key, record in
            record.announcedTip.map { (key: key, value: $0) }
        }
    }

    struct HelloDeadline {
        let token: LifetimeToken
        let sessionID: Data
        let task: Task<Void, Never>
    }

    /// An overlay peer's latest child-evidence index root, bound to the
    /// session that pushed it.
    struct PeerEvidenceRoot: Equatable {
        let sessionID: Data
        let rootCID: String
    }

    /// State keyed by session ID rather than peer key: in-flight serves and
    /// content leases. Each entry is released by its own task's `defer`,
    /// which checks the runtime fence, so a reconnect (a new session ID)
    /// never lets an old task's release touch the new session. A session's
    /// end discards only the accepted-leaves and ancestor-range serves;
    /// `servingReadEndpoints` is released by its task alone (or restart).
    struct SessionLeases {
        var servingAcceptedLeaves: Set<Data> = []
        var servingAncestorRange: Set<Data> = []
        var servingReadEndpoints: Set<Data> = []
        var activeTransactionVolumes = Set<TransactionVolumeLease>()

        mutating func discardServing(_ sessionID: Data) {
            servingAcceptedLeaves.remove(sessionID)
            servingAncestorRange.remove(sessionID)
        }
    }

    /// Owner: constant; read by +Overlay.
    static let maximumEvidenceCandidates = 64
    /// Owner: constant; read by +Lifecycle.
    static let maximumCandidateWaitTicks = 64
    /// Direct advertisers probed (each up to one request timeout) before the
    /// recovery source. candidate.providers is bounded only by live sessions, so
    /// an announcement flood could otherwise force O(N) sequential timeouts per
    /// block; this caps the fan-out to a small constant.
    /// Owner: constant; read by +Candidates, +Overlay.
    static let maximumExactContentSources = 8
    /// Owner: constant; read by +Candidates.
    static let futureCandidateRetryInterval: Duration = .seconds(1)
    private static let maximumConcurrentParentStateQueries = 64
    /// Owner: constant; read by +Overlay.
    static let maximumConcurrentTransactionVolumes = 64
    /// Owner: constant; read by +Overlay.
    static let maximumTransactionInventoryRootsPerSync = 1_024

    public nonisolated let remoteContentSource: IvyRootContentSource

    let planeConfigurations: NodeNetworkPlaneConfigurations
    /// Owner: init; immutable.
    let configuration: NodeConfiguration
    /// Owner: init; immutable.
    let overlay: Ivy
    /// The co-hosted parent level's facts; nil on Nexus.
    /// Owner: init; immutable.
    nonisolated let parentLevel: (any ParentLevel)?
    private let hello: ChainHello

    /// Owner: Lifecycle.enqueueStart / Lifecycle.stop.
    var lifecycleTail: Task<Void, Never>?
    /// Nonzero only while a process is the active runtime. Delegate callbacks
    /// take their stamp from `callbackEpoch`; clearing this value before the
    /// plane stops makes callbacks delivered during teardown invalid too.
    /// Owner: Lifecycle.startNow / Lifecycle.stopNow.
    var runtimeGeneration: UInt64 = 0
    /// Owner: init; immutable.
    let callbackEpoch = RuntimeCallbackEpoch()
    /// Owner: Lifecycle.startNow / Lifecycle.clearRuntimeState.
    var process: ChainProcess?
    /// Owner: Lifecycle.startNow / Lifecycle.stopNow.
    var isRunning = false
    /// Overlay-plane state: sessions and records of the public overlay,
    /// its request tables, range sync, read-URL discovery, peer search and
    /// the child-evidence index sync. Only overlay code touches it.
    struct OverlayState {
        /// Per overlay peer key: the one authenticated session (pre- or
        /// post-hello) and the state bound to it.
        /// Owner: Lifecycle.clearRuntimeState / Overlay.handleOverlay /
        ///     Overlay.scheduleOverlayHelloDeadline / Overlay.overlayHelloTimedOut /
        ///     Overlay.pullFrontierIfAtEdge / RangeSync.handleForwardRangeResponse /
        ///     RangeSync.handleAncestorRangeResponse / RangeSync.rangeSyncProgressDeadline /
        ///     NodeNetworkRuntime.removeOverlayHelloDeadline / NodeNetworkRuntime.didConnect /
        ///     NodeNetworkRuntime.didDisconnect.
        var overlayRecords = PeerSet<OverlayPeerRecord>()
        /// Owner: Lifecycle.clearRuntimeState / Overlay.requestTransactionInventory /
        ///     Overlay.transactionInventoryTimedOut / Overlay.scheduleTransactionInventory /
        ///     Overlay.purgeOverlayRequests.
        var pendingTransactionInventories:
            [UInt64: PendingTransactionInventory] = [:]
        /// Owner: Lifecycle.clearRuntimeState / Overlay.handleOverlay /
        ///     ReadURL.discoverProviderReadURLs / ReadURL.performReadURLDiscovery /
        ///     ReadURL.readEndpointAskTimedOut / Overlay.purgeOverlayRequests.
        var readURLDiscovery = ReadURLDiscovery()
        /// Owner: Lifecycle.clearRuntimeState / RangeSync.startRangeSync /
        ///     RangeSync.pumpRangeSync / RangeSync.handleForwardRangeResponse /
        ///     RangeSync.sendAncestorRangeRequest / RangeSync.handleAncestorRangeResponse /
        ///     RangeSync.scheduleRangeSyncProgress / RangeSync.rangeSyncProgressDeadline /
        ///     RangeSync.rangeSyncTimedOut / RangeSync.clearRangeSync /
        ///     RangeSync.scheduleRangeSyncReentry / RangeSync.maybeRestartRangeSync.
        var rangeSync = RangeSync()
        /// Widens the peer search while this node's own acquired tip stands still,
        /// so an eclipsed or stalled node goes looking instead of waiting on the
        /// peers it already holds.
        /// Owner: Lifecycle.clearRuntimeState / NodeNetworkRuntime.schedulePeerSearch.
        var peerSearchTask = TaskSlot()
        /// The last parked block a lookup pass searched for: the next pass
        /// starts past it.
        /// Owner: Lifecycle.clearRuntimeState / Overlay.syncChildEvidence.
        var childProofLookupCursor: String?
        /// The one serial worker that looks up and walks peers' roots, and
        /// the peer it served last (the round-robin's position).
        /// Owner: Lifecycle.clearRuntimeState / Overlay.startChildEvidenceSync /
        ///     Overlay.runChildEvidenceSync.
        var childEvidenceSync = TaskSlot()
        var lastChildEvidencePeer: PeerKey?
        /// Pushes this node's root when it changes; the dirty flag coalesces
        /// every change made while a push runs into one more push.
        /// Owner: Lifecycle.clearRuntimeState / Overlay.scheduleChildEvidenceRootAnnounce /
        ///     Overlay.announceChildEvidenceRoot.
        var childEvidenceAnnounce = TaskSlot()
        var childEvidenceAnnounceDirty = false
        var announcedChildEvidenceRoot: String?
    }

    /// Owner: overlay code (+Overlay, +RangeSync, overlay +ReadURL).
    var overlayState = OverlayState()
    /// Owner: Candidates.scheduleWaitingCandidateRetry / Candidates.retryWaitingCandidates /
    ///     Lifecycle.clearRuntimeState.
    var waitingCandidateRetryTask = TaskSlot()
    /// The one frontier (accepted-leaves) pull per overlay session: sent once
    /// we are at the live edge with respect to the peer, answered by exactly
    /// the page whose requestID matches (`requestID` is cleared on receipt).
    /// The session ID rejects a stale entry after a reconnect.
    struct FrontierPull {
        let sessionID: Data
        var requestID: UInt64?
    }

    /// A session's tip claim for the missing-ancestry range sync; `sequence`
    /// orders claims oldest first, so a reconnect goes to the back.
    struct AncestryClaim {
        let sessionID: Data
        let sequence: UInt64
        var height: UInt64
        var asked: Bool
    }
    /// Periodically re-announces this node as a DHT provider of its chain's
    /// genesis block, so other nodes (and the explorer's /api/chain/endpoints)
    /// can discover it via `findProviders(genesisCID)` with no registry.
    /// Owner: Lifecycle.clearRuntimeState / NodeNetworkRuntime.scheduleGenesisProviderAnnounce.
    var genesisAnnounceTask = TaskSlot()
    /// Endpoints dialled from the one provider lookup a widening performs.
    private static let maximumPeerSearchDials = 4
    /// Owner: Candidates (the planes reach it through its seams:
    ///     enqueueCandidate / reReadyCandidates / predecessorConnectedOutOfBand /
    ///     disconnectProvider / fetcherTracks) /
    ///     Lifecycle.startNow / Lifecycle.clearRuntimeState.
    var blockFetcher = BlockFetcher()
    /// Owner: Candidates.startCandidateWorker / Candidates.finishCandidateWorker /
    ///     Lifecycle.clearRuntimeState.
    var candidateWorker = TaskSlot()
    /// Counts the parent level's tip changes, so an admission that read a
    /// parent fact as missing can tell whether the tip moved before its
    /// candidate parked.
    /// Owner: Candidates.parentChanged / Candidates.importCandidate.
    var parentTipChanges: UInt64 = 0
    /// Owner: Lifecycle.clearRuntimeState / Overlay.handleOverlay.
    var parentStateQueryGuard = ParentStateQueryGuard(
        capacity: NodeNetworkRuntime.maximumConcurrentParentStateQueries
    )
    /// Owner: Lifecycle.clearRuntimeState /
    ///     Overlay.handleOverlay / Overlay.reserveTransactionVolume /
    ///     Overlay.receiveTransactionVolume / Overlay.discardServingSessions.
    var sessionLeases = SessionLeases()
    /// The service this generation calls into; `Node.build` passes a
    /// `WeakChain`, so the runtime never keeps the service alive.
    /// Owner: Lifecycle.startNow / Lifecycle.clearRuntimeState.
    var chain: (any ChainInterface)?

    /// Callback work may outlive a stop/start boundary. Keep its captured
    /// process tied to the generation that began it, rather than letting an
    /// old continuation touch the next runtime.
    func isCurrentRuntime(
        generation: UInt64,
        process expectedProcess: ChainProcess
    ) -> Bool {
        runtimeGeneration != 0
            && runtimeGeneration == generation
            && process === expectedProcess
    }

    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        runtimeGeneration != 0 && runtimeGeneration == generation
    }

    func resolvedRuntimeFence(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) -> (generation: UInt64, process: ChainProcess)? {
        if let generation, let expectedProcess {
            guard
                isCurrentRuntime(
                    generation: generation,
                    process: expectedProcess
                )
            else { return nil }
            return (generation, expectedProcess)
        }
        guard generation == nil,
            expectedProcess == nil,
            runtimeGeneration != 0,
            let process
        else { return nil }
        return (runtimeGeneration, process)
    }

    public init(
        configuration: NodeConfiguration,
        parentLevel: (any ParentLevel)? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            planeConfigurations: NodeNetworkPlaneConfigurations(configuration),
            parentLevel: parentLevel
        )
    }

    init(
        configuration: NodeConfiguration,
        planeConfigurations: NodeNetworkPlaneConfigurations,
        parentLevel: (any ParentLevel)? = nil
    ) throws {
        guard planeConfigurations.overlay.peerKey.hex == configuration.processPublicKey else {
            throw IvyModeError.invalidConfiguration(
                "network runtime plane identity must match the process identity"
            )
        }
        let overlay = Ivy(config: planeConfigurations.overlay)
        self.configuration = configuration
        self.planeConfigurations = planeConfigurations
        self.parentLevel = parentLevel
        self.overlay = overlay
        remoteContentSource = IvyRootContentSource(
            ivy: overlay,
            policy: configuration.resourcePolicy
        )
        hello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            publicReadURL: configuration.publicReadURL
        )
    }

    /// Ungated overlay-peer summary for the public explorer API. Reads only the
    /// in-memory authenticated overlay set — no mutation, no gate. Hard-capped
    /// at `limit` (the daemon passes ≤ 200).
    public func peerSummaries(limit: Int) async -> ExplorerPeersResponse {
        let boundedLimit = min(max(limit, 0), Self.maximumExplorerPeerSummaries)
        let peers = readyOverlayPeers
        let summaries = peers.prefix(boundedLimit).map { peer in
            ExplorerPeerSummary(
                key: peer.key.hex,
                role: peer.role == .carrier ? "carrier" : "endpoint"
            )
        }
        return ExplorerPeersResponse(count: peers.count, peers: Array(summaries))
    }

    private static let maximumExplorerPeerSummaries = 200

    /// Called after the process canonicalizes a new tip. Overlay peers learn
    /// the CID.
    public func canonicalTipDidChange() async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        try await canonicalTipDidChange(
            generation: runtimeGeneration,
            process: process
        )
    }

    private func canonicalTipDidChange(
        generation: UInt64,
        process: ChainProcess
    ) async throws {
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        if let tip = await process.status().tipCID {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            try await announceBlock(
                tip,
                generation: generation,
                process: process
            )
        }
    }

    nonisolated public func ivy(
        _ ivy: Ivy,
        didConnect peer: AuthenticatedPeer
    ) async {
        let generation = callbackEpoch.current()
        await didConnect(on: ivy, peer: peer, generation: generation)
    }

    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        let generation = callbackEpoch.current()
        Task { await self.didDisconnect(on: ivy, peer: peer, generation: generation) }
    }

    nonisolated public func ivy(
        _ ivy: Ivy,
        didDiscoverPublicAddress address: ObservedAddress
    ) {}

    nonisolated public func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        let generation = callbackEpoch.current()
        await didReceive(
            on: ivy,
            message: message,
            peer: peer,
            generation: generation
        )
    }

    private func didConnect(
        on ivy: Ivy,
        peer: AuthenticatedPeer,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), let process else { return }
        guard peer.role == .endpoint else {
            await ivy.disconnectSession(ifCurrent: peer)
            return
        }
        guard ivy === overlay else { return }
        // Overlay authorization belongs to one authenticated connection
        // rather than a long-lived key.
        // The record is updated in place: its announced tip survives
        // (every reader compares its session). Only a still-awaiting
        // previous session's serves are discarded here, as before; a
        // ready one's are released by their own tasks.
        let previous = overlayState.overlayRecords[peer.key]
        if let previous = previous?.readyPeer {
            disconnectProvider(previous)
        }
        discardServingSessions(of: previous?.awaitingHelloPeer)
        overlayState.overlayRecords.update(peer.key) {
            $0.session = .awaitingHello(peer)
            $0.frontierPull = nil
            $0.ancestryClaim = nil
        }
        scheduleOverlayHelloDeadline(for: peer, generation: generation)
        syncTrace("overlay connect peer=\(peer.key.hex.prefix(8))")
        guard let payload = try? hello.encode() else { return }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let result = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.overlayHello,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        switch result {
        case .enqueued, .notConnected:
            break
        case .backpressured, .locallyRejected:
            await ivy.recycleSession(ifCurrent: peer)
        }
    }

    private func didDisconnect(
        on ivy: Ivy,
        peer: PeerID,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), process != nil else { return }
        guard let key = try? PeerKey(peer.publicKey) else { return }
        if ivy === overlay {
            // A replacement may already be current when the old connection's
            // asynchronous disconnect callback arrives; one may also connect
            // while the check below is suspended. Only the binding sampled
            // here ends: a record a newer session took meanwhile stays.
            let ended = overlayState.overlayRecords[key]?.liveSessionID
            guard !(await ivy.connectedPeers).contains(peer),
                  let disconnected = overlayState.overlayRecords[key],
                  disconnected.liveSessionID == ended else { return }
            disconnected.helloDeadline?.task.cancel()
            if let ready = disconnected.readyPeer {
                disconnectProvider(ready)
            }
            discardServingSessions(of: disconnected.sessionPeer)
            // The record goes after the range sync clears: the re-entry that
            // clear arms still counts this peer's announced tip, as before.
            if overlayState.rangeSync.state?.peer.key == key {
                clearRangeSync()
            }
            overlayState.overlayRecords.remove(key, ifBoundTo: ended)
            purgeOverlayRequests(for: key)
        }
    }

    private func didReceive(
        on ivy: Ivy,
        message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation), let process else { return }
        guard let plane = NodeNetworkTopic.plane(for: message.topic) else { return }
        guard ivy === overlay, plane == .overlay else { return }
        await handleOverlay(
            message,
            peer: peer,
            generation: generation,
            process: process
        )
    }

    func schedulePeerSearch(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard configuration.peerSearchInterval > 0,
              isCurrentRuntime(generation: generation, process: process),
              overlayState.peerSearchTask.isEmpty else { return }
        let search = makePeerSearch(process: process)
        overlayState.peerSearchTask.start { _ in
            Task { [weak self] in
                await self?.peerSearchLoop(search, generation: generation)
            }
        }
    }

    /// Observe our own tip on a fixed cadence and let the search decide. The
    /// first observation only records where the tip stands, so a node that has
    /// just started is never treated as idle.
    private func peerSearchLoop(
        _ search: StaleTipPeerSearch,
        generation: UInt64
    ) async {
        await Timers.repeating(
            every: .seconds(Self.peerSearchPollSeconds(
                configuration.peerSearchInterval
            )),
            while: { isRunning && runtimeGeneration == generation }
        ) {
            await search.tick()
        }
    }

    /// Seconds between two observations of our own tip. Observing more often
    /// than the configured interval is harmless — the widening decision is
    /// `tick`'s, measured against the configured interval itself — and bounding
    /// the sleep keeps it representable for any value an operator can pass.
    /// `min`/`max` propagate NaN, so a non-finite value is replaced outright
    /// rather than clamped, which would otherwise trap on conversion.
    static func peerSearchPollSeconds(_ interval: TimeInterval) -> UInt64 {
        guard interval.isFinite else { return 600 }
        return UInt64(min(max(interval, 1), 86_400))
    }

    /// Hosts this node refuses to dial from an unvetted discovery answer. An
    /// attacker who lands provider records would otherwise steer a stalled
    /// node's automatic dials at loopback, an unspecified address, or a
    /// link-local or multicast target. Private ranges stay diallable: a LAN
    /// peer is a legitimate deployment, not an attack.
    static func isDiallableDiscoveredHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "localhost" else { return false }
        if trimmed.contains(":") {
            let address = String(trimmed.split(separator: "%").first ?? "")
            guard !address.isEmpty, address != "::", address != "::1" else {
                return false
            }
            return !address.hasPrefix("fe80") && !address.hasPrefix("ff")
        }
        let fields = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let octets = fields.compactMap { UInt8($0) }
        // Not an IPv4 literal: a hostname this node cannot classify, left alone.
        guard fields.count == 4, octets.count == 4 else { return true }
        switch octets[0] {
        case 0, 127: return false
        case 169 where octets[1] == 254: return false
        case 224...239, 255: return false
        default: return true
        }
    }

    private func makePeerSearch(process: ChainProcess) -> StaleTipPeerSearch {
        let overlay = self.overlay
        let configured = planeConfigurations.overlay.bootstrapPeers
        return StaleTipPeerSearch(
            interval: configuration.peerSearchInterval,
            maximumDiscoveredDials: Self.maximumPeerSearchDials,
            clock: { Date() },
            // The acquired (weighed-inclusive) tip: it advances only on work
            // this node verified itself. The validated tip lags behind it under
            // deferred execution and would read as staleness that is not there.
            fetchedHeight: { await process.canonicalTipHeight() },
            configuredPeersWithoutSession: { [weak self] in
                await self?.peersWithoutSession(configured) ?? []
            },
            discoveredPeersWithoutSession: { [weak self] in
                await self?.discoveredPeersWithoutSession(process: process) ?? []
            },
            dial: { endpoint in
                _ = try? await overlay.connect(to: endpoint)
            }
        )
    }

    /// The configured peers we hold no authenticated session with. Dialling one
    /// also clears the overlay's reconnect suppression, which is the one state
    /// in which it has permanently stopped retrying a peer the operator asked
    /// for.
    private func peersWithoutSession(
        _ endpoints: [PeerEndpoint]
    ) -> [PeerEndpoint] {
        endpoints.filter { endpoint in
            guard let key = try? PeerKey(endpoint.publicKey) else { return false }
            return overlayState.overlayRecords[key]?.readyPeer == nil
        }
    }

    /// One provider lookup for this chain's own genesis — the rendezvous every
    /// node of the chain already announces itself into — minus ourselves and
    /// the peers we already hold. A lying provider record costs one failed dial
    /// and nothing else.
    private func discoveredPeersWithoutSession(
        process: ChainProcess
    ) async -> [PeerEndpoint] {
        guard let genesis = await process.canonicalBlockCID(atHeight: 0) else {
            return []
        }
        let ownKey = try? PeerKey(configuration.processPublicKey)
        let discovered = await overlay.discoverProviders(rootCID: genesis)
        return peersWithoutSession(discovered).filter { endpoint in
            guard let key = try? PeerKey(endpoint.publicKey),
                  key != ownKey,
                  Self.isDiallableDiscoveredHost(endpoint.host) else {
                return false
            }
            return true
        }
    }

    func scheduleGenesisProviderAnnounce(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        genesisAnnounceTask.start { _ in
            Task { [weak self] in
                await self?.announceGenesisProviderLoop(
                    generation: generation,
                    process: process
                )
            }
        }
    }

    /// Announce this chain's genesis to the provider DHT and re-announce before
    /// the record's TTL lapses. Content-addressed and permissionless: a node
    /// becomes a discoverable "node of this chain" purely by serving its genesis
    /// — the CID is self-verifying, so a stale or lying announce is harmless.
    private func announceGenesisProviderLoop(
        generation: UInt64,
        process: ChainProcess
    ) async {
        let ttl = min(
            UInt64(20 * 60),
            planeConfigurations.overlay.maxProviderTTLSeconds
        )
        // Re-announce well within the TTL, and often enough to pick up a
        // newly-wired child within a minute (records are small).
        let interval = max(UInt64(30), min(ttl / 2, UInt64(60)))
        await Timers.repeating(
            every: .seconds(interval),
            while: { isRunning && runtimeGeneration == generation }
        ) {
            await announceGenesisProviders(
                expiresAt: UInt64(Date().timeIntervalSince1970) + ttl,
                process: process
            )
        }
    }

    private func announceGenesisProviders(
        expiresAt: UInt64,
        process: ChainProcess
    ) async {
        // This node's own chain genesis, on its own overlay — peers of this
        // chain can find providers of it.
        if let ownGenesis = await process.canonicalBlockCID(atHeight: 0) {
            await overlay.announceProvider(
                rootCID: ownGenesis,
                expiresAt: expiresAt
            )
        }
    }

    #if DEBUG
    /// Test view of the per-peer and per-session state (see
    /// `NetworkDebugSnapshot`). The safety net pins that a disconnected
    /// peer's key is absent from `heldPeerKeys`.
    func debugSnapshot() -> NetworkDebugSnapshot {
        var keys = Set<PeerKey>()
        keys.formUnion(overlayState.overlayRecords.keys)
        keys.formUnion(overlayState.pendingTransactionInventories.values.map(\.peer.key))
        keys.formUnion(overlayState.readURLDiscovery.pendingReadEndpoints.values.map(\.peer.key))
        if let sync = overlayState.rangeSync.state { keys.insert(sync.peer.key) }
        keys.formUnion(parentStateQueryGuard.peers.keys)
        for hex in blockFetcher.debugSnapshot().providerKeys {
            if let key = try? PeerKey(hex) { keys.insert(key) }
        }

        var sessions = Set<Data>()
        sessions.formUnion(sessionLeases.servingAcceptedLeaves)
        sessions.formUnion(sessionLeases.servingAncestorRange)
        sessions.formUnion(sessionLeases.servingReadEndpoints)
        sessions.formUnion(sessionLeases.activeTransactionVolumes.map(\.sessionID))

        return NetworkDebugSnapshot(
            overlay: overlayState.overlayRecords.records.mapValues {
                NetworkDebugSnapshot.OverlayPeer(
                    helloAccepted: $0.readyPeer != nil,
                    hasHelloDeadline: $0.helloDeadline != nil
                )
            },
            heldPeerKeys: keys,
            heldSessionIDs: sessions,
            liveSessionIDs: Set(
                overlayState.overlayRecords.records.values.compactMap(\.sessionPeer?.sessionID)
            ),
            rangeSyncAnchor: overlayState.rangeSync.state.map {
                ($0.requestedAfterCID, $0.requestedHeight)
            }
        )
    }

    /// Test seam: one pass of the genesis-provider announce loop, which
    /// otherwise repeats only once a minute.
    func announceGenesisProvidersForTesting(process: ChainProcess) async {
        await announceGenesisProviders(
            expiresAt: UInt64(Date().timeIntervalSince1970) + 600,
            process: process
        )
    }
    #endif

    private static func milliseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(milliseconds)
        return additionOverflow ? UInt64.max : total
    }

    /// A request ID is a lifetime token: never zero, never issued twice in
    /// this process. Every table keyed by one (pending requests, their
    /// timeouts, the range-sync slot) can therefore only be answered or
    /// expired by the request that registered the entry, never by a late
    /// response or timer from an earlier generation.
    func makeRequestID() -> UInt64 {
        LifetimeToken.next().rawValue
    }
}
