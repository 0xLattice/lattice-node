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
    public let preparingChildDirectories: [String]
    public let contentSource: any ContentSource
    /// Admit on the weighed (deferred-execution) tier: enter fork choice on
    /// verified work without executing. True for every network-sourced block
    /// (live gossip, frontier leaves, range-sync pages, predecessor walks);
    /// only locally produced blocks stay eager.
    public let weighed: Bool

    public init(
        header: BlockHeader,
        authenticatedChildPackage: AuthenticatedChildPackage?,
        preparingChildDirectories: [String],
        contentSource: any ContentSource,
        weighed: Bool = false
    ) {
        self.header = header
        self.authenticatedChildPackage = authenticatedChildPackage
        self.preparingChildDirectories = preparingChildDirectories
        self.contentSource = contentSource
        self.weighed = weighed
    }
}

enum ChildCandidateBudget {
    @TaskLocal static var deadline: ContinuousClock.Instant?
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
    case invalidChildProof
}

struct NodeNetworkPlaneConfigurations {
    let overlay: IvyConfig
    let hierarchy: IvyConfig

    init(_ configuration: NodeConfiguration) throws {
        let parentAdmissionBypass: Set<PeerKey>
        if let parent = configuration.parentEndpoint {
            parentAdmissionBypass = [try PeerKey(parent.publicKey)]
        } else {
            parentAdmissionBypass = []
        }
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
                // PUBLIC plane (unlike the identity-pinned hierarchy plane), so
                // the justification is not "the other plane does it" — it is
                // that a per-netgroup connection cap is weak defense here: bad
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
            ),
            hierarchy: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: configuration.factListenPort,
                bootstrapPeers: configuration.parentEndpoint.map { [$0.ivy] } ?? [],
                inboundAdmissionBypassPeerKeys: parentAdmissionBypass,
                // Tally's per-peer request budget is one bucket per peer,
                // spent by this node's sends and the peer's inbound alike.
                // At merged-mining block rates a parent legitimately sends a
                // child a context, an evidence hint and
                // the content its candidate build fetches, every block; on
                // the overlay default the parent's own bucket refused those
                // sends and its children's chains crawled (traced: 427
                // Nexus blocks, Market at 11). The plane admits any peer
                // whose hello proves a path, so this also raises what such
                // a peer may send before the budget refuses it; what a
                // message may cost is bounded where it is handled (a
                // candidate is decoded only from a wired-in child with a
                // context, once per CID, within the plane's frame).
                tallyConfig: TallyConfig(
                    perPeerRequestCapacity: 4_000,
                    perPeerRequestRefillPerSecond: 1_000
                ),
                maxConnections: IvyConfig.defaultMaxConnections,
                reservedOutboundConnectionSlots: configuration.parentEndpoint == nil ? 0 : 1,
                maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                minPeerKeyBits: 0,
                relayEnabled: false,
                privateContentExchangeEnabled: true,
                carriers: [],
                mode: .privateNetwork
            )
        )
    }

    init(overlay: IvyConfig, hierarchy: IvyConfig) throws {
        guard overlay.mode == .overlay,
              hierarchy.mode == .privateNetwork,
              overlay.inboundAdmissionBypassPeerKeys.isEmpty,
            overlay.peerKey == hierarchy.peerKey
        else {
            throw IvyModeError.invalidConfiguration(
                "network runtime requires same-identity overlay and private hierarchy planes"
            )
        }
        try overlay.validate()
        try hierarchy.validate()
        self.overlay = overlay
        self.hierarchy = hierarchy
    }
}

/// Two deliberately separate Ivy planes for one recovered chain process.
/// The public overlay carries same-chain candidates and CAS content. The
/// private hierarchy plane carries only direct parent/child facts.
public actor NodeNetworkRuntime: IvyDelegate {
    typealias Candidate = BlockFetcher.Candidate
    typealias CandidateSeed = BlockFetcher.Seed
    private typealias CandidateWaitReason = BlockFetcher.WaitReason
    typealias DurableDescendant = BlockFetcher.DurableDescendant
    typealias ParentEvidenceResult = ParentEvidenceFlow.Result
    typealias ParentEvidenceSession = ParentEvidenceFlow.Session

    enum HierarchyPeer: Equatable {
        case parent
        case child([String])
    }

    struct PendingChildEvidenceIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: ChildEvidenceIndexRequestMessage
    }

    struct EvidenceVolumeLease: Hashable {
        let plane: CandidateSourcePlane
        let sessionID: Data
        let attachmentCID: String
    }

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

        var isEmpty: Bool {
            session == nil && helloDeadline == nil && frontierPull == nil
                && ancestryClaim == nil
                && announcedTip == nil
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

    struct HierarchyPeerRecord: PeerRecord {
        var helloDeadline: HelloDeadline?
        /// Set together at an accepted hello (not at connect) and cleared
        /// together.
        var session: AuthenticatedPeer?
        var role: HierarchyPeer?
        /// The public read URL a wired child declared in its hierarchy
        /// hello, per authenticated child connection. Self-declared and
        /// unverified — a browser verifies the served genesis against the
        /// parent's anchor.
        var declaredReadURL: String?
        var evidence = ChildEvidenceState()
        /// The latest candidate the child pushed; carries its own session.
        var offer: CachedChildCandidate?
        /// The context sequence the child was last sent, so the push task
        /// sends it only what it lacks. Recorded after the send, and only
        /// while that session is still live; carries its own session.
        var pushedSequence: SessionSequence?
        /// The latest evidence hint this node's own send budget refused
        /// for the child, re-sent on the next push run. A hint carries one
        /// index entry; the admission it triggers scans the index from the
        /// child's cursor, so the newest re-sent hint also recovers older
        /// refused ones.
        var refusedHint: Data?

        var isEmpty: Bool {
            helloDeadline == nil && session == nil && role == nil
                && declaredReadURL == nil && evidence.isEmpty && offer == nil
                && pushedSequence == nil && refusedHint == nil
        }

        /// The accepted session; before its hello, the session the hello
        /// deadline waits on.
        var liveSessionID: Data? { session?.sessionID ?? helloDeadline?.sessionID }
    }

    func isChildEvidenceReady(_ key: PeerKey) -> Bool {
        hierarchyState.hierarchyRecords[key]?.evidence.ready == true
    }

    /// Every refused evidence hint with its key, as a snapshot.
    var recordedRefusedHints: [(key: PeerKey, value: Data)] {
        hierarchyState.hierarchyRecords.records.compactMap { key, record in
            record.refusedHint.map { (key: key, value: $0) }
        }
    }

    /// Every hierarchy peer's role with its key, as a snapshot.
    var hierarchyRoles: [(key: PeerKey, value: HierarchyPeer)] {
        hierarchyState.hierarchyRecords.records.compactMap { key, record in
            record.role.map { (key: key, value: $0) }
        }
    }

    /// Takes the key's hierarchy hello deadline out of its record: any
    /// session's (`session` nil, a connect replacing it), or only
    /// `session`'s.
    @discardableResult
    func removeHierarchyHelloDeadline(
        for key: PeerKey,
        session: Data?
    ) -> HelloDeadline? {
        hierarchyState.hierarchyRecords.updateExisting(key) { record in
            let deadline = record.helloDeadline
            guard session == nil || deadline?.sessionID == session else { return nil }
            record.helloDeadline = nil
            return deadline
        } ?? nil
    }

    struct HelloDeadline {
        let token: LifetimeToken
        let sessionID: Data
        let task: Task<Void, Never>
    }

    struct ChildEvidenceReadyWaiter {
        let sessionID: Data
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// A child peer's evidence readiness. `ready` and the waiters belong
    /// to the peer key; the three publication fences belong to one session,
    /// the one `sessionID` stamps.
    ///
    /// A final index page permits reservation cleanup only after every live
    /// publication that began before it has been ordered into the same Ivy
    /// session. The fences are session-scoped so reconnect cannot inherit
    /// one: a fence is read only under its own session's stamp, and the
    /// stamp clears with the last fence.
    struct ChildEvidenceState {
        var ready = false
        var waiters: [ChildEvidenceReadyWaiter] = []
        private(set) var sessionID: Data?
        private var indexComplete = false
        private var publicationFailed = false
        private var publicationsInFlight = 0

        var isEmpty: Bool {
            !ready && waiters.isEmpty && sessionID == nil
        }

        func publicationsInFlight(for sessionID: Data) -> Int? {
            self.sessionID == sessionID && publicationsInFlight > 0
                ? publicationsInFlight
                : nil
        }

        func indexComplete(for sessionID: Data) -> Bool {
            self.sessionID == sessionID && indexComplete
        }

        func publicationFailed(for sessionID: Data) -> Bool {
            self.sessionID == sessionID && publicationFailed
        }

        /// Sets the session's in-flight count; zero removes it.
        mutating func setPublicationsInFlight(_ count: Int, for sessionID: Data) {
            guard stamp(sessionID) else { return }
            publicationsInFlight = count
            unstampIfClear()
        }

        mutating func markIndexComplete(for sessionID: Data) {
            guard stamp(sessionID) else { return }
            indexComplete = true
        }

        mutating func markPublicationFailed(for sessionID: Data) {
            guard stamp(sessionID) else { return }
            publicationFailed = true
        }

        /// Drops every fence, whatever session holds them.
        mutating func clearFences() {
            sessionID = nil
            indexComplete = false
            publicationFailed = false
            publicationsInFlight = 0
        }

        /// Only the current session writes a fence, and a session change
        /// clears the fences first, so a live stamp is always the writer's.
        private mutating func stamp(_ sessionID: Data) -> Bool {
            if self.sessionID == nil { self.sessionID = sessionID }
            guard self.sessionID == sessionID else {
                assertionFailure("child evidence fence written for a stale session")
                return false
            }
            return true
        }

        private mutating func unstampIfClear() {
            if !indexComplete, !publicationFailed, publicationsInFlight == 0 {
                sessionID = nil
            }
        }
    }

    struct PortableEvidenceWork: Sendable {
        let summary: PortableAttachmentSummary
        let peer: AuthenticatedPeer
        let generation: UInt64
        let process: ChainProcess
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
        var activeEvidenceVolumes = Set<EvidenceVolumeLease>()
        var portableEvidenceOrder: [EvidenceVolumeLease] = []
        var portableEvidenceWork: [EvidenceVolumeLease: PortableEvidenceWork] = [:]

        mutating func discardServing(_ sessionID: Data) {
            servingAcceptedLeaves.remove(sessionID)
            servingAncestorRange.remove(sessionID)
        }
    }

    enum CandidateSourcePlane: Hashable {
        case overlay
        case hierarchy
    }

    /// Each suspended hierarchy stage is capped.
    /// Owner: constant; read by +Hierarchy, +Overlay.
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
    /// Owner: constant; read by +Hierarchy.
    static let maximumPendingRequests = 1_024
    /// How long an anchored genesis that could not be fetched or confirmed
    /// waits before it is tried again without a trigger.
    static let genesisRetryNanoseconds: UInt64 = 30_000_000_000
    /// Owner: constant; read by +Hierarchy.
    static let maximumDirectChildren = 64
    private static let maximumConcurrentParentStateQueries = 64
    /// Owner: constant; read by +Hierarchy.
    static let maximumPeersPerChildPath = 4
    /// Owner: constant; read by +Hierarchy.
    static let maximumReconnectEvidenceAnnouncements = 64
    /// Owner: constant; read by +Hierarchy.
    static let maximumReconnectCarrierRoots = 64
    /// Owner: constant; read by +Overlay.
    static let maximumConcurrentTransactionVolumes = 64
    /// Owner: constant; read by +Overlay.
    static let maximumTransactionInventoryRootsPerSync = 1_024

    public nonisolated let remoteContentSource: IvyRootContentSource
    public nonisolated let hierarchyContentSource: IvyRootContentSource

    let planeConfigurations: NodeNetworkPlaneConfigurations
    let hierarchy: Ivy
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
    /// take their stamp from `callbackEpoch`; clearing this value before either
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
    /// the portable-evidence worker. Only overlay code touches it; the
    /// hierarchy side reaches it through the named seams.
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
        /// Owner: Lifecycle.clearRuntimeState / Overlay.startPortableEvidenceWorker /
        ///     Overlay.drainPortableEvidence.
        var portableEvidenceWorker = TaskSlot()
    }

    /// Hierarchy-plane state: parent/child sessions and records, their
    /// request tables, the parent tip context pushed down and the one
    /// received from the parent, the child candidate offer and the carried
    /// hold, and the child rotations. Only hierarchy code touches it; the
    /// overlay side reaches it through the named seams.
    struct HierarchyState {
        /// Per hierarchy peer key: the state bound to its connection.
        /// Owner: Hierarchy.resendRefusedChildEvidenceHints / Hierarchy.pushParentTipContext /
        ///     Hierarchy.waitForChildEvidenceReady / Hierarchy.markChildEvidenceReady /
        ///     Hierarchy.cancelChildEvidenceReadyWaiters /
        ///     Hierarchy.announceChildEvidenceAvailability /
        ///     Hierarchy.finishChildEvidencePublication / Hierarchy.completeChildEvidenceIndex /
        ///     Hierarchy.clearHierarchyAuthorization / Hierarchy.handleHierarchy /
        ///     Hierarchy.handleHierarchyHello / Hierarchy.scheduleHierarchyHelloDeadline /
        ///     Lifecycle.clearRuntimeState / NodeNetworkRuntime.removeHierarchyHelloDeadline.
        var hierarchyRecords = PeerSet<HierarchyPeerRecord>()
        /// Owner: Hierarchy.scheduleChildProofRecovery / Hierarchy.recoverChildProofs /
        ///     Lifecycle.clearRuntimeState.
        var childProofRecoveryTask = TaskSlot()
        /// The one genesis activation attempt in flight, and whether a
        /// trigger asked for another since it started.
        /// Owner: Hierarchy.triggerGenesisActivation /
        ///     Hierarchy.runGenesisActivation / Lifecycle.clearRuntimeState.
        var genesisActivationTask = TaskSlot()
        /// Owner: Hierarchy.triggerGenesisActivation /
        ///     Hierarchy.runGenesisActivation / Lifecycle.clearRuntimeState.
        var genesisActivationRequested = false
        /// The one slow retry armed after an anchored genesis could not be
        /// fetched or confirmed.
        /// Owner: Hierarchy.armGenesisRetry / Hierarchy.genesisRetryFired /
        ///     Hierarchy.activateGenesisIfRecorded / Lifecycle.clearRuntimeState.
        var genesisRetryTask = TaskSlot()
        /// Owner: Hierarchy.scheduleChildProofRecovery / Hierarchy.recoverChildProofs /
        ///     Lifecycle.clearRuntimeState.
        var childProofRecoveryNeedsRefresh = false
        /// Owner: Hierarchy.handleHierarchy / Hierarchy.requestEvidenceIndex /
        ///     Hierarchy.evidenceIndexRequestTimedOut / Lifecycle.clearRuntimeState /
        ///     Hierarchy.purgeHierarchyRequests.
        var pendingEvidenceIndexes: [UInt64: PendingChildEvidenceIndex] = [:]
        /// Owner: Hierarchy.refreshParentTipContext / Lifecycle.clearRuntimeState.
        var parentTipContext: ParentTipContext?
        /// Owner: Hierarchy.refreshParentTipContext.
        var nextParentTipSequence: UInt64 = 0
        /// Owner: Hierarchy.scheduleParentTipPush / Hierarchy.runParentTipPushes /
        ///     Lifecycle.clearRuntimeState.
        var parentTipPushTask = TaskSlot()
        /// Parent evidence whose import could not decide on a fact the
        /// parent will send: in memory only, bounded, random eviction.
        /// Owner: Hierarchy.parentEvidenceOrphaned /
        ///     Hierarchy.parentEvidenceRetryTrigger / Hierarchy.parentEvidenceDecided /
        ///     Hierarchy.refetchReleasedOrphans / Hierarchy.repool /
        ///     Lifecycle.clearRuntimeState.
        var parentEvidenceOrphans = ParentEvidenceOrphans(
            capacity: NodeResourcePolicy.default.maximumOrphanedParentEvidence
        )
        /// The orphans a refetch put back at a full inbox: the capacity
        /// callback fetches exactly these again (`parentEvidenceRoomResumed`).
        /// Owner: Hierarchy.refetchReleasedOrphans /
        ///     Hierarchy.parentEvidenceRoomResumed /
        ///     Lifecycle.clearRuntimeState.
        var orphansAwaitingRoom: Set<ParentEvidenceOrphans.Key> = []
        /// Orphans fetched again from the pool whose import is queued:
        /// still undecided with no specific trigger afterwards, one is
        /// dropped. Only the parent's hello clears every mark.
        /// Owner: Hierarchy.parentEvidenceRetryTrigger /
        ///     Hierarchy.parentEvidenceOrphaned / Hierarchy.parentEvidenceDecided /
        ///     Hierarchy.recoverParentEvidence /
        ///     Lifecycle.clearRuntimeState.
        var refetchedOrphans: Set<ParentEvidenceOrphans.Key> = []
        /// The parent session whose hello last released the orphan pool:
        /// a refetch cut short by its predecessor's end finds that hello
        /// already past (`refetchReleasedOrphans`).
        /// Owner: Hierarchy.parentEvidenceRetryTrigger /
        ///     Lifecycle.clearRuntimeState.
        var parentHelloReleaseSession: Data?
        /// Owner: Hierarchy.scheduleParentTipPush / Hierarchy.runParentTipPushes /
        ///     Lifecycle.clearRuntimeState.
        var parentTipPushDirty = false
        /// Owner: Hierarchy.updateDescendantPlan / Lifecycle.clearRuntimeState.
        var descendantRewards: [MiningReward] = []
        /// Owner: Hierarchy.updateDescendantPlan / Lifecycle.clearRuntimeState.
        var descendantMinimumWork: [MiningMinimumWork] = []
        /// Owner: Hierarchy.clearHierarchyAuthorization / Hierarchy.handleHierarchy /
        ///     Lifecycle.clearRuntimeState.
        var receivedParentTip: ReceivedParentTipContext?
        /// A page request is being prepared (its cursor read) and not yet
        /// pending: no second round starts meanwhile.
        /// Owner: Hierarchy.requestEvidenceIndex / Lifecycle.clearRuntimeState.
        var evidenceRoundStarting = false
        /// One coalescing offer task: an input change while a build runs marks it
        /// dirty and the task runs again; nothing is queued.
        /// Owner: Hierarchy.scheduleCandidateOffer / Hierarchy.runCandidateOffers /
        ///     Lifecycle.clearRuntimeState.
        var candidateOfferTask = TaskSlot()
        /// Owner: Hierarchy.scheduleCandidateOffer / Hierarchy.runCandidateOffers /
        ///     Lifecycle.clearRuntimeState.
        var candidateOfferDirty = false
        /// Owner: Hierarchy.offerCandidate / Lifecycle.clearRuntimeState.
        var nextCandidateOfferSequence: UInt64 = 0
        /// Owner: Hierarchy.offerCandidate / Hierarchy.clearHierarchyAuthorization /
        ///     Lifecycle.clearRuntimeState.
        var lastOfferedCandidateCID: String?
        /// Owner: Hierarchy.clearHierarchyAuthorization / Hierarchy.selectedChildPeers /
        ///     Lifecycle.clearRuntimeState.
        var childPeerRotation: [String: Int] = [:]
        /// Owner: Hierarchy.selectedChildPeers / Lifecycle.clearRuntimeState.
        var childPathRotation = 0
        /// Owner: Hierarchy.authenticatedChildDirectories / Lifecycle.clearRuntimeState.
        var childProofPathRotation = 0
        /// Directories already backfilled this generation, so the late-child
        /// evidence backfill runs once per connection instead of on every recovery
        /// pass (which would churn routes for non-committing carriers). Cleared when
        /// a directory's last child peer disconnects and on generation reset.
        /// Owner: Hierarchy.clearHierarchyAuthorization / Hierarchy.recoverChildProofs /
        ///     Lifecycle.clearRuntimeState.
        var backfilledChildDirectories: Set<String> = []
    }

    /// Owner: overlay code (+Overlay, +RangeSync, overlay +ReadURL).
    var overlayState = OverlayState()
    /// Owner: hierarchy code (+Hierarchy, hierarchy +ReadURL).
    var hierarchyState = HierarchyState()
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
    ///     disconnectProvider / fetcherTracks / offerGate) /
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
    /// Owner: Hierarchy.recoverParentEvidence / Lifecycle.clearRuntimeState /
    ///     Overlay.handleOverlay / Overlay.reserveTransactionVolume /
    ///     Overlay.receiveTransactionVolume / Overlay.enqueuePortableEvidence /
    ///     Overlay.drainPortableEvidence / Overlay.recoverPortableAttachment /
    ///     Overlay.discardServingSessions.
    var sessionLeases = SessionLeases()
    /// Evidence recoveries waiting for an evidence Volume slot: each is
    /// woken when a slot is released, or by its own timeout (which also
    /// re-checks that its session still stands).
    /// Owner: NodeNetworkRuntime.wakeEvidenceSlotWaiters /
    ///     NodeNetworkRuntime.waitForEvidenceVolumeSlot /
    ///     NodeNetworkRuntime.wakeEvidenceSlotWaiter (teardown through
    ///     wakeEvidenceSlotWaiters).
    var evidenceSlotWaiters: [UInt64: EvidenceSlotWaiter] = [:]
    /// Owner: NodeNetworkRuntime.waitForEvidenceVolumeSlot.
    var nextEvidenceSlotWaiter: UInt64 = 0
    /// Orders parent evidence and reservation transfer within one authenticated
    /// session. Transport effects remain in this actor.
    /// Owner: Candidates.importCandidate / Hierarchy.appendParentEvidence /
    ///     Hierarchy.finishParentEvidence / Lifecycle.clearRuntimeState.
    var parentEvidence = ParentEvidenceFlow()
    /// The service this generation calls into; `Node.build` passes a
    /// `WeakChain`, so the runtime never keeps the service alive.
    /// Owner: Lifecycle.startNow / Lifecycle.clearRuntimeState.
    var chain: (any ChainInterface)?
    /// The template context this chain last pushed to its children: its
    /// validated tip and the miner's plan for the subtree. Re-pushed whenever
    /// any of it changes; a child builds its candidate against it.
    struct ParentTipContext {
        let sequence: UInt64
        let tipCID: String
        let tipData: Data
        let rewards: [MiningReward]
        let minimumWork: [MiningMinimumWork]
        /// Per child directory, the child block the tip's branch last
        /// committed into it (the nearest committer's commitment): what a
        /// template does not carry again.
        let carriedChildren: [String: String]
        /// The child directories the context was minted for: a directory
        /// that connects later is owed a fresh context on the same tip.
        let directories: Set<String>
    }
    /// The latest candidate each child peer pushed for this chain's tip. A
    /// template reads it; nothing is requested at template time.
    struct CachedChildCandidate {
        let sequence: UInt64
        let sessionID: Data
        let childCID: String
        let candidate: DirectChildCandidate
    }
    /// A sequence read on one session: a new session restarts sequences,
    /// so a value from an earlier session says nothing about this one.
    struct SessionSequence {
        let sessionID: Data
        let sequence: UInt64
    }
    /// The parent's context as last received (this chain being the child),
    /// bound to the session it came on: a new session restarts sequences.
    struct ReceivedParentTipContext {
        let sequence: UInt64
        let peer: AuthenticatedPeer
        let tipCID: String
        let tip: Block
        let rewards: [MiningReward]
        let minimumWork: [MiningMinimumWork]
    }
    /// Set when the offer gate deferred behind an own carried candidate's
    /// admission; the admission drain then re-arms the offer.
    /// Owner: Candidates.drainCandidateImports / Candidates.offerGate /
    ///     Lifecycle.clearRuntimeState.
    var candidateOfferDeferredByAdmission = false

    /// A recovery waiting for an evidence Volume slot, and the timer that
    /// ends its wait if no slot is released first.
    struct EvidenceSlotWaiter {
        let continuation: CheckedContinuation<Void, Never>
        let timeout: Task<Void, Never>

        func wake() {
            timeout.cancel()
            continuation.resume()
        }
    }

    /// Releases an evidence Volume slot and wakes every recovery waiting
    /// for one: the first to run takes it, the rest wait again.
    func releaseEvidenceVolume(_ lease: EvidenceVolumeLease) {
        sessionLeases.activeEvidenceVolumes.remove(lease)
        wakeEvidenceSlotWaiters()
    }

    /// Wakes every waiter, cancelling its timer. Also teardown's.
    func wakeEvidenceSlotWaiters() {
        let waiters = evidenceSlotWaiters.values
        evidenceSlotWaiters.removeAll()
        for waiter in waiters { waiter.wake() }
    }

    /// Suspends until an evidence Volume slot is released, `timeout`
    /// passes, or the waiting task is cancelled (its session ended).
    func waitForEvidenceVolumeSlot(
        timeout: Duration,
        generation: UInt64
    ) async {
        nextEvidenceSlotWaiter &+= 1
        let id = nextEvidenceSlotWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                evidenceSlotWaiters[id] = EvidenceSlotWaiter(
                    continuation: continuation,
                    timeout: Timers.deadline(
                        after: timeout, generation: generation
                    ) { [weak self] _ in
                        await self?.wakeEvidenceSlotWaiter(id)
                    }
                )
            }
        } onCancel: {
            Task { [weak self] in await self?.wakeEvidenceSlotWaiter(id) }
        }
    }

    private func wakeEvidenceSlotWaiter(_ id: UInt64) {
        evidenceSlotWaiters.removeValue(forKey: id)?.wake()
    }

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
        let expectedParentAdmissionBypass: Set<PeerKey>
        if let parent = configuration.parentEndpoint {
            expectedParentAdmissionBypass = [try PeerKey(parent.publicKey)]
        } else {
            expectedParentAdmissionBypass = []
        }
        guard planeConfigurations.hierarchy.inboundAdmissionBypassPeerKeys
            == expectedParentAdmissionBypass else {
            throw IvyModeError.invalidConfiguration(
                "hierarchy admission bypass must contain exactly the configured parent"
            )
        }
        let expectedHierarchyBootstrapPeers = configuration.parentEndpoint.map { [$0.ivy] } ?? []
        guard planeConfigurations.hierarchy.bootstrapPeers == expectedHierarchyBootstrapPeers else {
            throw IvyModeError.invalidConfiguration(
                "hierarchy bootstrap peers must contain exactly the configured parent"
            )
        }
        let overlay = Ivy(config: planeConfigurations.overlay)
        let hierarchy = Ivy(config: planeConfigurations.hierarchy)
        self.configuration = configuration
        self.planeConfigurations = planeConfigurations
        self.parentLevel = parentLevel
        self.overlay = overlay
        self.hierarchy = hierarchy
        remoteContentSource = IvyRootContentSource(
            ivy: overlay,
            policy: configuration.resourcePolicy
        )
        hierarchyContentSource = IvyRootContentSource(
            ivy: hierarchy,
            policy: configuration.resourcePolicy
        )
        hello = ChainHello(
            nexusGenesisCID: configuration.nexusGenesisCID,
            chainPath: configuration.chainPath,
            publicReadURL: configuration.publicReadURL
        )
        hierarchyState.parentEvidenceOrphans = ParentEvidenceOrphans(
            capacity: configuration.resourcePolicy.maximumOrphanedParentEvidence
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
    /// the CID, and authenticated direct-child routes get a targeted proof
    /// preparation retry against that exact root.
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
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            await retryCurrentTipChildProofs(
                tipCID: tip,
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

    static func startPlanes(
        startHierarchy: @Sendable () async throws -> Void,
        startOverlay: @Sendable () async throws -> Void,
        stopOverlay: @Sendable () async -> Void,
        stopHierarchy: @Sendable () async -> Void
    ) async throws {
        do {
            try await startHierarchy()
        } catch {
            await stopHierarchy()
            throw error
        }
        do {
            try await startOverlay()
        } catch {
            await stopOverlay()
            await stopHierarchy()
            throw error
        }
    }

    static func stopPlanes(
        stopOverlay: @Sendable () async -> Void,
        stopHierarchy: @Sendable () async -> Void
    ) async {
        await stopOverlay()
        await stopHierarchy()
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
        let topic: String
        if ivy === overlay {
            // Overlay authorization, like hierarchy authorization, belongs to
            // one authenticated connection rather than a long-lived key.
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
            SyncTrace.log("overlay connect peer=\(peer.key.hex.prefix(8))")
            topic = NodeNetworkTopic.overlayHello
        } else if ivy === hierarchy {
            guard peer.route == .direct else {
                await ivy.disconnectSession(ifCurrent: peer)
                return
            }
            topic = NodeNetworkTopic.hierarchyHello
        } else {
            return
        }
        guard let payload = try? hello.encode() else { return }
        if ivy === hierarchy {
            // A hierarchy role belongs to one authenticated connection.
            // The connect replaces whatever session the key held.
            clearHierarchyAuthorization(
                for: peer.key,
                removed: hierarchyState.hierarchyRecords.remove(peer.key)
            )
            scheduleHierarchyHelloDeadline(for: peer, generation: generation)
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let result = await ivy.sendMessage(
            to: peer,
            topic: topic,
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
        } else if ivy === hierarchy {
            // Ivy may already have promoted a replacement session for this
            // identity before this asynchronous delegate callback reaches us.
            // In that case this is the old connection ending, not a loss of
            // the authenticated parent/child relationship.
            // As on the overlay: only the binding sampled before the check
            // ends, never a newer session's record.
            let ended = hierarchyState.hierarchyRecords[key]?.liveSessionID
            guard !(await ivy.connectedPeers).contains(peer),
                  let removed = hierarchyState.hierarchyRecords.remove(
                    key, ifBoundTo: ended
                  ) else { return }
            clearHierarchyAuthorization(
                for: key, removed: removed
            )
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
        if ivy === overlay {
            guard plane == .overlay else { return }
            await handleOverlay(
                message,
                peer: peer,
                generation: generation,
                process: process
            )
        } else if ivy === hierarchy {
            guard plane == .hierarchy, peer.route == .direct else { return }
            await handleHierarchy(
                message,
                peer: peer,
                generation: generation,
                process: process
            )
        }
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
        // (1) This node's own chain genesis, on its own overlay — peers of
        // this chain can find providers of it.
        if let ownGenesis = await process.canonicalBlockCID(atHeight: 0) {
            await overlay.announceProvider(
                rootCID: ownGenesis,
                expiresAt: expiresAt
            )
        }
        // (2) Parent rendezvous: for every child ALREADY WIRED to this node
        // (a child that co-runs alongside its parent connects here), announce
        // that child's genesis on THIS parent overlay. Any node on the parent
        // chain can then discoverProviders(childGenesis) and reach a node
        // serving the child — permissionless, no registry, and discovery is
        // the global overlay DHT (not this node's connected-peer list).
        // The same sample drives the lookup and the announcements, so this
        // pass describes one consistent moment; a child wired mid-resolve is
        // announced by the next pass.
        let directories = wiredChildDirectories()
        let anchored = await process.anchoredChildGenesisCIDs(
            directories: directories
        )
        var announcedChildren: Set<String> = []
        for directory in directories {
            guard let childGenesis = anchored[directory],
                  announcedChildren.insert(childGenesis).inserted else {
                continue
            }
            await overlay.announceProvider(
                rootCID: childGenesis,
                expiresAt: expiresAt
            )
        }
    }

    #if DEBUG
    /// Test seam: awaited after a hierarchy send whose result a per-peer
    /// write follows, before that write, so a test can end the session
    /// while the sending task is suspended.
    var hierarchySendReturnedForTesting:
        (@Sendable (String, SendMessageResult) async -> Void)?

    func setHierarchySendReturnedForTesting(
        _ hook: (@Sendable (String, SendMessageResult) async -> Void)?
    ) {
        hierarchySendReturnedForTesting = hook
    }

    /// Test view of the per-peer and per-session state (see
    /// `NetworkDebugSnapshot`). The safety net pins that a disconnected
    /// peer's key is absent from `heldPeerKeys`.
    func debugSnapshot() -> NetworkDebugSnapshot {
        var keys = Set<PeerKey>()
        keys.formUnion(overlayState.overlayRecords.keys)
        keys.formUnion(hierarchyState.hierarchyRecords.keys)
        keys.formUnion(overlayState.pendingTransactionInventories.values.map(\.peer.key))
        keys.formUnion(overlayState.readURLDiscovery.pendingReadEndpoints.values.map(\.peer.key))
        if let sync = overlayState.rangeSync.state { keys.insert(sync.peer.key) }
        keys.formUnion(hierarchyState.pendingEvidenceIndexes.values.map(\.peer.key))
        keys.formUnion(parentStateQueryGuard.peers.keys)
        keys.formUnion(sessionLeases.portableEvidenceWork.values.map(\.peer.key))
        if let receivedParentTip = hierarchyState.receivedParentTip { keys.insert(receivedParentTip.peer.key) }
        for hex in blockFetcher.debugSnapshot().providerKeys
            .union(parentEvidence.debugSnapshot().peerIDs) {
            if let key = try? PeerKey(hex) { keys.insert(key) }
        }

        var sessions = Set<Data>()
        sessions.formUnion(sessionLeases.servingAcceptedLeaves)
        sessions.formUnion(sessionLeases.servingAncestorRange)
        sessions.formUnion(sessionLeases.servingReadEndpoints)
        sessions.formUnion(sessionLeases.activeTransactionVolumes.map(\.sessionID))
        sessions.formUnion(sessionLeases.activeEvidenceVolumes.map(\.sessionID))
        sessions.formUnion(sessionLeases.portableEvidenceOrder.map(\.sessionID))

        return NetworkDebugSnapshot(
            overlay: overlayState.overlayRecords.records.mapValues {
                NetworkDebugSnapshot.OverlayPeer(
                    helloAccepted: $0.readyPeer != nil,
                    hasHelloDeadline: $0.helloDeadline != nil
                )
            },
            hierarchy: hierarchyState.hierarchyRecords.records.mapValues {
                NetworkDebugSnapshot.HierarchyPeer(
                    role: $0.role,
                    hasHelloDeadline: $0.helloDeadline != nil
                )
            },
            heldPeerKeys: keys,
            heldSessionIDs: sessions,
            liveSessionIDs: Set(
                overlayState.overlayRecords.records.values.compactMap(\.sessionPeer?.sessionID)
                    + hierarchyState.hierarchyRecords.records.values.compactMap(\.session?.sessionID)
            ),
            rangeSyncAnchor: overlayState.rangeSync.state.map {
                ($0.requestedAfterCID, $0.requestedHeight)
            },
            candidateOfferHeld: candidateOfferDeferredByAdmission,
            refusedChildEvidenceHintCount: recordedRefusedHints.count
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

    static func rotatedPeerIndices(
        peerCount: Int,
        start: Int,
        limit: Int
    ) -> (indices: [Int], next: Int) {
        guard peerCount > 0, limit > 0 else { return ([], 0) }
        let normalizedStart = start % peerCount
        let count = min(peerCount, limit)
        let indices = (0..<count).map {
            (normalizedStart + $0) % peerCount
        }
        return (indices, (normalizedStart + 1) % peerCount)
    }

    static func interleavedChildPeerIndices(
        peerCounts: [Int],
        limit: Int
    ) -> [(path: Int, peer: Int)] {
        guard limit > 0, peerCounts.allSatisfy({ $0 >= 0 }) else { return [] }
        var result: [(Int, Int)] = []
        for peerIndex in 0..<(peerCounts.max() ?? 0) {
            for pathIndex in peerCounts.indices where peerIndex < peerCounts[pathIndex] {
                result.append((pathIndex, peerIndex))
                if result.count == limit { return result }
            }
        }
        return result
    }

    static func pruneChildPeerRotations(
        _ rotations: inout [String: Int],
        activeRoles: [HierarchyPeer]
    ) {
        let activePaths: Set<String> = Set(
            activeRoles.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.joined(separator: "/")
        })
        rotations = rotations.filter { activePaths.contains($0.key) }
    }

    func configuredParentPeer() -> AuthenticatedPeer? {
        guard let parentKey = configuration.parentEndpoint?.publicKey,
              let key = try? PeerKey(parentKey),
              case .parent? = hierarchyState.hierarchyRecords[key]?.role
        else { return nil }
        return hierarchyState.hierarchyRecords[key]?.session
    }

    /// A request ID is a lifetime token: never zero, never issued twice in
    /// this process. Every table keyed by one (pending requests, their
    /// timeouts, the range-sync slot) can therefore only be answered or
    /// expired by the request that registered the entry, never by a late
    /// response or timer from an earlier generation.
    func makeRequestID() -> UInt64 {
        LifetimeToken.next().rawValue
    }

    static func hierarchyRole(
        for remote: ChainHello,
        peerKey: String,
        configuration: NodeConfiguration
    ) -> HierarchyPeer? {
        if let parent = configuration.parentEndpoint,
            peerKey == parent.publicKey
        {
            let expectedPath = Array(configuration.chainPath.dropLast())
            return
                (try? remote.validateCompatibility(
                expectedNexusGenesisCID: configuration.nexusGenesisCID,
                expectedChainPath: expectedPath
            )).map { .parent }
        }
        guard remote.chainPath.count == configuration.chainPath.count + 1,
            Array(remote.chainPath.dropLast()) == configuration.chainPath
        else {
            return nil
        }
        return
            (try? remote.validateCompatibility(
            expectedNexusGenesisCID: configuration.nexusGenesisCID,
            expectedChainPath: remote.chainPath
        )).map { .child(remote.chainPath) }
    }

    static func merging(
        _ current: AuthenticatedChildPackage?,
        with received: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        BlockFetcher.mergePackages(current, received)
    }

}
