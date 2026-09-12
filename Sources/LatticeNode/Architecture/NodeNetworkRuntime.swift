import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

/// Public explorer peer DTOs. Defined here (module LatticeNode) so both the
/// runtime and the daemon's HTTP handlers (module LatticeNodeDaemon) can see
/// them; the handlers only `json()` these.
public struct ExplorerPeerSummary: Codable, Sendable, Equatable {
    public let key: String
    public let role: String
}

public struct ExplorerPeersResponse: Codable, Sendable, Equatable {
    public let count: Int
    public let peers: [ExplorerPeerSummary]

    public init(count: Int, peers: [ExplorerPeerSummary]) {
        self.count = count
        self.peers = peers
    }
}

public typealias ContextualChildCandidateBuilder = @Sendable (
    _ context: ChildCandidateRequestContext,
    _ parentContentSource: any ContentSource
) async throws -> DirectChildCandidate?

public struct NetworkCandidateAdmission: Sendable {
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

public typealias NetworkAdmissionHandler = @Sendable (
    _ admission: NetworkCandidateAdmission
) async throws -> NodeAdmissionOutcome

public typealias NetworkTransactionHandler = @Sendable (
    _ transaction: Transaction
) async throws -> Bool

public typealias TransactionInventoryProvider = @Sendable () async -> [String]
public struct NetworkCandidateReservationUpdate: Sendable {
    public let candidateCIDs: [String]
    public let handoffCIDs: [String]

    public init(candidateCIDs: [String], handoffCIDs: [String]) {
        self.candidateCIDs = candidateCIDs
        self.handoffCIDs = handoffCIDs
    }
}

public typealias NetworkCandidateReservationHandler = @Sendable (
    _ update: NetworkCandidateReservationUpdate
) async -> Bool

/// All service callbacks used by one network-runtime generation. Supplying the
/// complete value at startup prevents a live runtime from being partially
/// wired or changing behavior beneath authenticated sessions.
public struct NodeNetworkHandlers: Sendable {
    public let childCandidateBuilder: ContextualChildCandidateBuilder?
    public let candidateReservations: NetworkCandidateReservationHandler?
    public let admission: NetworkAdmissionHandler
    public let transaction: NetworkTransactionHandler?
    public let transactionInventory: TransactionInventoryProvider?

    public init(
        childCandidateBuilder: ContextualChildCandidateBuilder? = nil,
        candidateReservations: NetworkCandidateReservationHandler? = nil,
        admission: @escaping NetworkAdmissionHandler,
        transaction: NetworkTransactionHandler? = nil,
        transactionInventory: TransactionInventoryProvider? = nil
    ) {
        self.childCandidateBuilder = childCandidateBuilder
        self.candidateReservations = candidateReservations
        self.admission = admission
        self.transaction = transaction
        self.transactionInventory = transactionInventory
    }
}

private enum ChildCandidateBudget {
    @TaskLocal static var deadline: ContinuousClock.Instant?
}

private final class RuntimeCallbackEpoch: @unchecked Sendable {
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
    let capacity: Int
    private(set) var peers = Set<PeerKey>()

    mutating func acquire(_ peer: PeerKey) -> Bool {
        guard peers.count < capacity else { return false }
        return peers.insert(peer).inserted
    }

    mutating func release(_ peer: PeerKey) {
        peers.remove(peer)
    }

    mutating func removeAll() {
        peers.removeAll()
    }
}

private enum NodePolicyDecline: Error {
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

actor ProvisionalVolumeRegistry {
    private struct Key: Hashable {
        let generation: UInt64
        let cid: String
    }

    private let broker: any VolumeBroker
    private var leases: [Key: Int] = [:]
    private var epoch: UInt64 = 0

    init(
        broker: any VolumeBroker = MemoryBroker(evictUnpinnedGrace: .zero)
    ) {
        self.broker = broker
    }

    func retain(_ volume: SerializedVolume, generation: UInt64) async -> Bool {
        let key = Key(generation: generation, cid: volume.root)
        let operationEpoch = epoch
        do {
            try await broker.store(volume: volume)
            guard epoch == operationEpoch else {
                _ = try? await broker.evictUnpinned()
                return false
            }
            try await broker.pin(
                root: volume.root,
                owner: Self.owner(generation)
            )
        } catch {
            return false
        }
        guard epoch == operationEpoch else {
            try? await broker.unpin(
                root: volume.root,
                owner: Self.owner(generation)
            )
            _ = try? await broker.evictUnpinned()
            return false
        }
        leases[key, default: 0] += 1
        return true
    }

    func release(_ cid: String, generation: UInt64) async {
        let key = Key(generation: generation, cid: cid)
        guard let count = leases[key] else { return }
        leases[key] = count == 1 ? nil : count - 1
        try? await broker.unpin(root: cid, owner: Self.owner(generation))
        if count == 1 { _ = try? await broker.evictUnpinned() }
    }

    func volume(_ cid: String, generation: UInt64) async -> SerializedVolume? {
        guard leases[Key(generation: generation, cid: cid)] != nil else {
            return nil
        }
        return await broker.fetchVolumeLocal(root: cid)
    }

    func removeAll() async {
        epoch &+= 1
        let retained = leases
        leases.removeAll()
        for (key, count) in retained {
            try? await broker.unpin(
                root: key.cid,
                owner: Self.owner(key.generation),
                count: count
            )
        }
        _ = try? await broker.evictUnpinned()
    }

    private static func owner(_ generation: UInt64) -> String {
        "runtime-provisional:\(generation)"
    }
}

/// Two deliberately separate Ivy planes for one recovered chain process.
/// The public overlay carries same-chain candidates and CAS content. The
/// private hierarchy plane carries only direct parent/child facts.
public actor NodeNetworkRuntime: IvyDelegate {
    private typealias Candidate = CandidateAcquirer.Candidate
    private typealias CandidateSeed = CandidateAcquirer.Seed
    private typealias CandidateWaitReason = CandidateAcquirer.WaitReason
    private typealias DurableDescendant = CandidateAcquirer.DurableDescendant
    private typealias ParentEvidenceResult = ParentEvidenceFlow.Result
    private typealias ParentEvidenceSession = ParentEvidenceFlow.Session

    enum HierarchyPeer: Equatable {
        case parent
        case child([String])
    }

    private struct PendingChildEvidenceIndex: Sendable {
        let peer: AuthenticatedPeer
        let request: ChildEvidenceIndexRequestMessage
    }

    private struct PendingParentChainFact: Sendable {
        let peer: AuthenticatedPeer
        let request: ParentChainFactMessage
        let blockCID: String
        let package: AuthenticatedChildPackage
        /// Set by the validate walk's evidence request: the fact's arrival (or
        /// its timeout) is handed back as the merged package (or nil) instead
        /// of re-seeding a live candidate.
        var continuation: CheckedContinuation<AuthenticatedChildPackage?, Never>? = nil
    }

    private struct PendingGenesisVerification: Sendable {
        let peer: AuthenticatedPeer
        let request: ParentChainFactMessage
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct PendingGenesisResolve: Sendable {
        let peer: AuthenticatedPeer
        let continuation: CheckedContinuation<String?, Never>
    }

    private struct EvidenceVolumeLease: Hashable {
        let plane: CandidateSourcePlane
        let sessionID: Data
        let attachmentCID: String
    }

    private struct PendingReadEndpoint {
        let peer: AuthenticatedPeer
        let genesisCID: String
        let continuation: CheckedContinuation<[String], Never>
        let timeout: Task<Void, Never>
    }

    private struct ReadURLDiscovery {
        let urls: [String]
        let expires: Date
    }

    private struct PendingTransactionInventory: Sendable {
        let peer: AuthenticatedPeer
        let request: TransactionInventoryRequestMessage
        let remainingRoots: Int
        let seenRoots: Set<String>
        let timeout: Task<Void, Never>
    }

    private struct TransactionVolumeLease: Hashable {
        let sessionID: Data
        let rootCID: String
    }

    private struct HelloDeadline {
        let token: UInt64
        let sessionID: Data
        let task: Task<Void, Never>
    }

    private struct PendingChildCandidateRequest {
        let peerKey: PeerKey
        let childPath: [String]
        let parentCID: String
        let continuation: CheckedContinuation<DirectChildCandidate?, Never>
    }

    private struct ChildCandidateBuild {
        let peerKey: PeerKey
        let token: UInt64
        let task: Task<Void, Never>
    }

    private struct ChildEvidenceReadyWaiter {
        let sessionID: Data
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ChildEvidenceSession: Hashable {
        let peerKey: PeerKey
        let sessionID: Data
    }

    private struct PendingCandidateReservation {
        let peer: AuthenticatedPeer
        let childPath: [String]
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct CandidateReservationAttempt: Sendable {
        let peerKey: PeerKey
        let target: Set<String>
        let accepted: Bool
    }

    private struct CandidateReservationRemovalFlush {
        let token: UInt64
        let task: Task<Void, Never>
    }

    private struct PortableEvidenceWork: Sendable {
        let summary: PortableAttachmentSummary
        let peer: AuthenticatedPeer
        let generation: UInt64
        let process: ChainProcess
    }

    private enum CandidateSourcePlane: Hashable {
        case overlay
        case hierarchy
    }

    private static let maximumPendingRequests = 1_024
    /// Each suspended hierarchy stage is capped.
    private static let maximumEvidenceCandidates = 64
    private static let maximumCandidateWaitTicks = 64
    /// Direct advertisers probed (each up to one request timeout) before the
    /// recovery source. candidate.providers is bounded only by live sessions, so
    /// an announcement flood could otherwise force O(N) sequential timeouts per
    /// block; this caps the fan-out to a small constant.
    private static let maximumExactContentSources = 8
    private static let futureCandidateRetryInterval: Duration = .seconds(1)
    private static let maximumDirectChildren = 64
    private static let maximumConcurrentChildBuilds = 8
    private static let maximumConcurrentParentStateQueries = 64
    private static let maximumPeersPerChildPath = 4
    private static let maximumReconnectEvidenceAnnouncements = 64
    private static let maximumReconnectCarrierRoots = 64
    private static let maximumConcurrentTransactionVolumes = 64
    private static let maximumTransactionInventoryRootsPerSync = 1_024
    private static let childCandidateFinalizeReserveMilliseconds: UInt64 = 100

    public nonisolated let remoteContentSource: IvyRootContentSource
    public nonisolated let hierarchyContentSource: IvyRootContentSource

    let planeConfigurations: NodeNetworkPlaneConfigurations
    let hierarchy: Ivy
    private let configuration: NodeConfiguration
    private let overlay: Ivy
    private let hello: ChainHello

    private var lifecycleTail: Task<Void, Never>?
    /// Nonzero only while a process is the active runtime. Delegate callbacks
    /// take their stamp from `callbackEpoch`; clearing this value before either
    /// plane stops makes callbacks delivered during teardown invalid too.
    private var runtimeGeneration: UInt64 = 0
    private let callbackEpoch = RuntimeCallbackEpoch()
    private var process: ChainProcess?
    private var isRunning = false
    private var overlaySessions: [PeerKey: AuthenticatedPeer] = [:]
    private var overlayPeers: [PeerKey: AuthenticatedPeer] = [:]
    private var hierarchyPeers: [PeerKey: HierarchyPeer] = [:]
    private var hierarchySessions: [PeerKey: AuthenticatedPeer] = [:]
    private let provisionalRoots = ProvisionalVolumeRegistry()
    private var childEvidenceReadyPeers: Set<PeerKey> = []
    private var childEvidenceReadyWaiters:
        [PeerKey: [ChildEvidenceReadyWaiter]] = [:]
    /// A final index page permits reservation cleanup only after every live
    /// publication that began before it has been ordered into the same Ivy
    /// session. Counts are session-scoped so reconnect cannot inherit a fence.
    private var childEvidenceIndexCompleteSessions: Set<ChildEvidenceSession> = []
    private var childEvidencePublicationFailedSessions: Set<ChildEvidenceSession> = []
    private var childEvidencePublicationsInFlight:
        [ChildEvidenceSession: Int] = [:]
    private var overlayHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var hierarchyHelloDeadlines: [PeerKey: HelloDeadline] = [:]
    private var waitingCandidateRetryTask: Task<Void, Never>?
    private var waitingCandidateRetryGeneration: UInt64?
    private var pendingTransactionInventories:
        [UInt64: PendingTransactionInventory] = [:]
    private var activeTransactionVolumes = Set<TransactionVolumeLease>()
    private var servingAcceptedLeaves: Set<Data> = []
    /// The one frontier (accepted-leaves) pull per overlay session: sent once
    /// we are at the live edge with respect to the peer, answered by exactly
    /// the page whose requestID matches (`requestID` is cleared on receipt).
    /// The session ID rejects a stale entry after a reconnect.
    private struct FrontierPull {
        let sessionID: Data
        var requestID: UInt64?
    }
    private var frontierPulls: [PeerKey: FrontierPull] = [:]
    private var servingAncestorRange: Set<Data> = []
    private var servingReadEndpoints: Set<Data> = []
    /// Public read URLs declared by wired children in their hierarchy hellos,
    /// per authenticated child connection. Self-declared and unverified — a
    /// browser verifies the served genesis against the parent's anchor.
    private var childDeclaredReadURLs: [PeerKey: String] = [:]
    private var pendingReadEndpoints: [UInt64: PendingReadEndpoint] = [:]
    private var readURLDiscoveries: [String: ReadURLDiscovery] = [:]
    private var readURLDiscoveryTasks:
        [String: (token: UInt64, task: Task<[String], Never>)] = [:]
    private var rangeSync: RangeSyncState?
    /// Monotonic across all range syncs so a stale progress-deadline task from a
    /// previous sync can never alias a new sync's epoch.
    private var nextRangeSyncProgressEpoch: UInt64 = 0
    /// A gap larger than this (announced height minus ours) starts a forward-apply
    /// range sync (negotiated locator, pages, progress watchdog, peer rotation);
    /// only the true live edge uses the direct predecessor path.
    private static let rangeSyncDepthThreshold: UInt64 = 2
    private var childProofRecoveryTask: Task<Void, Never>?
    private var childProofRecoveryGeneration: UInt64?
    /// Periodically re-announces this node as a DHT provider of its chain's
    /// genesis block, so other nodes (and the explorer's /api/chain/endpoints)
    /// can discover it via `findProviders(genesisCID)` with no registry.
    private var genesisAnnounceTask: Task<Void, Never>?
    /// Drives a child this node ADOPTED (no local genesis seed) out of
    /// `awaitingGenesis` by resolving its recorded genesis CID off the
    /// authenticated parent and fetching+admitting the self-contained genesis.
    private var adoptedGenesisTask: Task<Void, Never>?
    /// Widens the peer search while this node's own acquired tip stands still,
    /// so an eclipsed or stalled node goes looking instead of waiting on the
    /// peers it already holds.
    private var peerSearchTask: Task<Void, Never>?
    /// Endpoints dialled from the one provider lookup a widening performs.
    private static let maximumPeerSearchDials = 4
    private var childProofRecoveryNeedsRefresh = false
    private var candidateAcquirer = CandidateAcquirer()
    private var candidateWorker: Task<Void, Never>?
    private var candidateWorkerGeneration: UInt64?
    private var pendingEvidenceIndexes: [UInt64: PendingChildEvidenceIndex] = [:]
    private var pendingParentChainFacts:
        [UInt64: PendingParentChainFact] = [:]
    private var pendingGenesisVerifications:
        [UInt64: PendingGenesisVerification] = [:]
    private var pendingGenesisResolves:
        [UInt64: PendingGenesisResolve] = [:]
    private var parentStateQueryGuard = ParentStateQueryGuard(
        capacity: NodeNetworkRuntime.maximumConcurrentParentStateQueries
    )
    private var announcedTips: [PeerKey: (height: UInt64, peer: AuthenticatedPeer)] = [:]
    private var rangeSyncReentryTask: Task<Void, Never>?
    private var activeEvidenceVolumes = Set<EvidenceVolumeLease>()
    private var portableEvidenceOrder: [EvidenceVolumeLease] = []
    private var portableEvidenceWork:
        [EvidenceVolumeLease: PortableEvidenceWork] = [:]
    private var portableEvidenceWorker: Task<Void, Never>?
    /// Orders parent evidence and reservation transfer within one authenticated
    /// session. Transport effects remain in this actor.
    private var parentEvidence = ParentEvidenceFlow()
    private var handlers: NodeNetworkHandlers?
    private var pendingChildCandidates: [UInt64: PendingChildCandidateRequest] = [:]
    private var childCandidateBuilds: [UInt64: ChildCandidateBuild] = [:]
    private var pendingCandidateReservations:
        [UInt64: PendingCandidateReservation] = [:]
    private var desiredCandidateReservations: [PeerKey: Set<String>] = [:]
    private var dirtyCandidateReservationPeers: Set<PeerKey> = []
    private var candidateReservationReconciliationInFlight = false
    private var candidateReservationRemovalFlushes:
        [PeerKey: CandidateReservationRemovalFlush] = [:]
    private var nextCandidateReservationRemovalFlushToken: UInt64 = 0
    private var candidateReservationReconciliationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var childPeerRotation: [String: Int] = [:]
    private var childPathRotation = 0
    private var childProofPathRotation = 0
    /// Directories already backfilled this generation, so the late-child
    /// evidence backfill runs once per connection instead of on every recovery
    /// pass (which would churn routes for non-committing carriers). Cleared when
    /// a directory's last child peer disconnects and on generation reset.
    private var backfilledChildDirectories: Set<String> = []
    private var nextRequestID: UInt64 = 0
    private var nextHelloDeadlineToken: UInt64 = 0
    private var nextChildCandidateBuildToken: UInt64 = 0

    /// Callback work may outlive a stop/start boundary. Keep its captured
    /// process tied to the generation that began it, rather than letting an
    /// old continuation touch the next runtime.
    private func isCurrentRuntime(
        generation: UInt64,
        process expectedProcess: ChainProcess
    ) -> Bool {
        runtimeGeneration != 0
            && runtimeGeneration == generation
            && process === expectedProcess
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        runtimeGeneration != 0 && runtimeGeneration == generation
    }

    private func resolvedRuntimeFence(
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

    public init(configuration: NodeConfiguration) throws {
        try self.init(
            configuration: configuration,
            planeConfigurations: NodeNetworkPlaneConfigurations(configuration)
        )
    }

    init(
        configuration: NodeConfiguration,
        planeConfigurations: NodeNetworkPlaneConfigurations
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
    }

    /// Installs both delegates and the recovered process's local content source
    /// before either listener becomes visible. The private plane starts first.
    public func start(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) async throws {
        try await enqueueStart(process: process, handlers: handlers).value
    }

    func enqueueStart(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) -> Task<Void, any Error> {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            try await self.startNow(process: process, handlers: handlers)
        }
        lifecycleTail = Task { _ = try? await operation.value }
        return operation
    }

    private func startNow(
        process: ChainProcess,
        handlers: NodeNetworkHandlers
    ) async throws {
        guard !isRunning else { throw NodeNetworkRuntimeError.alreadyRunning }
        var recoveredDescendants: [String: Set<DurableDescendant>] = [:]
        for requirement in await process.unresolvedSameChainPredecessors() {
            let roots = try await process.recoveredIncomingCarrierRootCIDs(
                for: requirement.descendantCID
            )
            let descendants = roots.isEmpty
                ? [DurableDescendant(
                    blockCID: requirement.descendantCID,
                    rootCID: nil
                )]
                : roots.map {
                    DurableDescendant(
                        blockCID: requirement.descendantCID,
                        rootCID: $0
                    )
                }
            recoveredDescendants[
                requirement.predecessorCID,
                default: []
            ].formUnion(descendants)
        }
        runtimeGeneration = callbackEpoch.advance()
        self.process = process
        self.handlers = handlers
        candidateAcquirer.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks,
            durableDescendants: recoveredDescendants
        )
        await overlay.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(process: process)
        )
        await hierarchy.install(
            delegate: self,
            contentSource: ChainProcessIvyContentSource(
                process: process,
                authorizes: { [weak self] peer in
                    await self?.canServeHierarchyContent(to: peer) == true
                },
                transientRootVolume: { [weak self] rootCID in
                    await self?.provisionalVolume(forRoot: rootCID)
                }
            )
        )
        do {
            let recoveredParentCandidates =
                try await prepareParentEvidenceInbox(process: process)
            try await Self.startPlanes(
                startHierarchy: { try await self.hierarchy.start() },
                startOverlay: { try await self.overlay.start() },
                stopOverlay: { await self.overlay.stop() },
                stopHierarchy: { await self.hierarchy.stop() }
            )
            isRunning = true
            for candidate in recoveredParentCandidates {
                guard await enqueueRetainedParentCandidate(
                    candidate,
                    generation: runtimeGeneration,
                    process: process
                ) else {
                    throw NodeStoreError.corrupt(
                        "durable parent evidence could not be replayed"
                    )
                }
            }
            // A peer may complete its hello while the listeners are starting.
            // Replay the evidence-index pull after ingress becomes runnable so
            // an early response cannot be the only copy we ever request.
            if !configuration.address.isNexus {
                await requestEvidenceIndex(
                    generation: runtimeGeneration,
                    process: process
                )
            }
            scheduleChildProofRecovery(
                generation: runtimeGeneration,
                process: process
            )
            scheduleGenesisProviderAnnounce(
                generation: runtimeGeneration,
                process: process
            )
            scheduleAdoptedGenesisBootstrap(
                generation: runtimeGeneration,
                process: process
            )
            schedulePeerSearch(
                generation: runtimeGeneration,
                process: process
            )
        } catch {
            isRunning = false
            _ = callbackEpoch.advance()
            runtimeGeneration = 0
            await clearRuntimeState()
            throw error
        }
    }

    public func stop() async {
        let previous = lifecycleTail
        let operation = Task { [weak self] in
            await previous?.value
            await self?.stopNow()
        }
        lifecycleTail = operation
        await operation.value
    }

    private func prepareParentEvidenceInbox(
        process: ChainProcess
    ) async throws -> [CandidateSeed] {
        var candidates: [CandidateSeed] = []
        for item in try await process.parentEvidenceInbox() {
            let directHop = await item.package.package.proof.directHop()
            guard let childCID = directHop?.childCID else {
                throw NodeStoreError.corrupt(
                    "durable parent evidence could not be replayed"
                )
            }
            candidates.append(CandidateSeed(
                blockCID: childCID,
                package: item.package
            ))
        }
        return candidates
    }

    private func enqueueRetainedParentCandidate(
        _ candidate: CandidateSeed,
        peer: AuthenticatedPeer? = nil,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        while isCurrentRuntime(generation: generation, process: process),
              peer.map({
                  hierarchySessions[$0.key]?.sessionID == $0.sessionID
                    && hierarchyPeers[$0.key] == .parent
              }) ?? true {
            if enqueueCandidate(candidate) { return true }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return false
    }

    private func stopNow() async {
        guard isRunning || process != nil else { return }
        _ = callbackEpoch.advance()
        runtimeGeneration = 0
        isRunning = false
        await Self.stopPlanes(
            stopOverlay: { await self.overlay.stop() },
            stopHierarchy: { await self.hierarchy.stop() }
        )
        await clearRuntimeState()
    }

    private func clearRuntimeState() async {
        process = nil
        overlaySessions.removeAll()
        overlayPeers.removeAll()
        hierarchyPeers.removeAll()
        hierarchySessions.removeAll()
        childDeclaredReadURLs.removeAll()
        servingReadEndpoints.removeAll()
        readURLDiscoveries.removeAll()
        for inFlight in readURLDiscoveryTasks.values {
            inFlight.task.cancel()
        }
        readURLDiscoveryTasks.removeAll()
        let readEndpointWaiters = pendingReadEndpoints.values
        pendingReadEndpoints.removeAll()
        for pending in readEndpointWaiters {
            pending.timeout.cancel()
            pending.continuation.resume(returning: [])
        }
        await provisionalRoots.removeAll()
        childEvidenceReadyPeers.removeAll()
        childEvidenceIndexCompleteSessions.removeAll()
        childEvidencePublicationFailedSessions.removeAll()
        childEvidencePublicationsInFlight.removeAll()
        let evidenceReadyWaiters = childEvidenceReadyWaiters.values.flatMap {
            $0
        }
        childEvidenceReadyWaiters.removeAll()
        for waiter in evidenceReadyWaiters {
            waiter.continuation.resume(returning: false)
        }
        for deadline in overlayHelloDeadlines.values { deadline.task.cancel() }
        overlayHelloDeadlines.removeAll()
        for deadline in hierarchyHelloDeadlines.values { deadline.task.cancel() }
        hierarchyHelloDeadlines.removeAll()
        waitingCandidateRetryTask?.cancel()
        waitingCandidateRetryTask = nil
        waitingCandidateRetryGeneration = nil
        for pending in pendingTransactionInventories.values {
            pending.timeout.cancel()
        }
        pendingTransactionInventories.removeAll()
        activeTransactionVolumes.removeAll()
        childProofRecoveryTask?.cancel()
        childProofRecoveryTask = nil
        genesisAnnounceTask?.cancel()
        genesisAnnounceTask = nil
        adoptedGenesisTask?.cancel()
        adoptedGenesisTask = nil
        // Joined, not just cancelled: `Task.sleep` unwinds on cancellation but
        // an in-flight dial does not, and the search holds the ChainProcess
        // strongly, so an unjoined task can outlive stop() still holding the
        // storage lock. Actors are reentrant, so awaiting here lets the task's
        // own callbacks into this actor run to completion.
        let peerSearch = peerSearchTask
        peerSearchTask = nil
        peerSearch?.cancel()
        await peerSearch?.value
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
        servingAcceptedLeaves.removeAll()
        frontierPulls.removeAll()
        servingAncestorRange.removeAll()
        clearRangeSync()
        candidateWorker?.cancel()
        candidateWorker = nil
        candidateWorkerGeneration = nil
        candidateAcquirer.reset(
            retryWindow: planeConfigurations.overlay.requestTimeout
                * Self.maximumCandidateWaitTicks
        )
        pendingEvidenceIndexes.removeAll()
        discardPendingParentChainFacts(where: { _ in true }, requeue: false)
        for pending in pendingGenesisVerifications.values {
            pending.continuation.resume(returning: false)
        }
        pendingGenesisVerifications.removeAll()
        for pending in pendingGenesisResolves.values {
            pending.continuation.resume(returning: nil)
        }
        pendingGenesisResolves.removeAll()
        parentStateQueryGuard.removeAll()
        announcedTips.removeAll()
        rangeSyncReentryTask?.cancel()
        rangeSyncReentryTask = nil
        activeEvidenceVolumes.removeAll()
        portableEvidenceWorker?.cancel()
        portableEvidenceWorker = nil
        portableEvidenceOrder.removeAll()
        portableEvidenceWork.removeAll()
        parentEvidence.reset()
        let pendingChildCandidates = Array(self.pendingChildCandidates.values)
        self.pendingChildCandidates.removeAll()
        for pending in pendingChildCandidates {
            pending.continuation.resume(returning: nil)
        }
        for build in childCandidateBuilds.values { build.task.cancel() }
        childCandidateBuilds.removeAll()
        let pendingReservations = Array(pendingCandidateReservations.values)
        pendingCandidateReservations.removeAll()
        for pending in pendingReservations {
            pending.continuation.resume(returning: false)
        }
        for flush in candidateReservationRemovalFlushes.values {
            flush.task.cancel()
        }
        candidateReservationRemovalFlushes.removeAll()
        childPeerRotation.removeAll()
        childPathRotation = 0
        childProofPathRotation = 0
        backfilledChildDirectories.removeAll()
        handlers = nil
    }

    public func announceBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        try await announceBlock(
            blockCID,
            generation: runtimeGeneration,
            process: process
        )
    }

    private func announceBlock(
        _ blockCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async throws {
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        // The announced block's OWN height, not the validated tip's: every
        // accepted block is announced (weighed pages and frontier leaves
        // included), and a receiver's gap test reads the pair as one claim. A
        // catching-up node announcing (block@1000, height 100) would hide the
        // gap and record a stale tip at every receiver.
        let height = await process.acceptedBlockHeight(blockCID)
        guard isCurrentRuntime(generation: generation, process: process) else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let payload = try BlockAnnouncementMessage(
            blockCID: blockCID,
            height: height
        ).encoded()
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
        }
    }

    /// Ungated overlay-peer summary for the public explorer API. Reads only the
    /// in-memory authenticated overlay set — no mutation, no gate. Hard-capped
    /// at `limit` (the daemon passes ≤ 200).
    public func peerSummaries(limit: Int) async -> ExplorerPeersResponse {
        let boundedLimit = min(max(limit, 0), 200)
        let peers = overlayPeers.values
        let summaries = peers.prefix(boundedLimit).map { peer in
            ExplorerPeerSummary(
                key: peer.key.hex,
                role: peer.role == .carrier ? "carrier" : "endpoint"
            )
        }
        return ExplorerPeersResponse(count: peers.count, peers: Array(summaries))
    }

    /// The public read URLs declared for the chain whose genesis is
    /// `genesisCID`: this node's own declaration plus those of the providers
    /// it discovers via the DHT. Only declared URLs; bounded, cached briefly.
    public func discoverProviderReadURLs(genesisCID: String) async -> [String] {
        guard CIDIdentity.isCanonical(genesisCID) else { return [] }
        if let cached = readURLDiscoveries[genesisCID],
           cached.expires > Date() {
            return cached.urls
        }
        // Coalesce concurrent HTTP callers onto one discovery so a request
        // burst cannot multiply overlay asks.
        if let inFlight = readURLDiscoveryTasks[genesisCID] {
            return await inFlight.task.value
        }
        let token = makeRequestID()
        let task = Task { [weak self] in
            await self?.performReadURLDiscovery(genesisCID: genesisCID) ?? []
        }
        readURLDiscoveryTasks[genesisCID] = (token: token, task: task)
        let urls = await task.value
        // Only the creator un-registers, and only its own entry: a stop/start
        // cycle clears the map, and a fresh discovery registered under the
        // same key must not be evicted by this stale resume.
        if readURLDiscoveryTasks[genesisCID]?.token == token {
            readURLDiscoveryTasks.removeValue(forKey: genesisCID)
        }
        return urls
    }

    /// Resolve the browsable read URLs for the chain whose genesis is
    /// `genesisCID`. A read URL is only ever a self-DECLARATION — the P2P
    /// plane traffics in IP literals a browser cannot dial, so browsability is
    /// its own declaration, carried from a child's hierarchy hello to its
    /// parent and served here; no URL is ever derived from a provider's
    /// announced host. This node's own declaration leads, read directly: it
    /// must not hinge on Ivy holding a provider record under our own key,
    /// which exists only once this node advertises a P2P address and an
    /// announce has landed. Then DHT-discover the other provider nodes (Ivy
    /// caches, else walks) and ask each one we hold an overlay session with.
    /// Providers that declare nothing, stay silent until the ask times out,
    /// or hold no session contribute nothing. All self-declared and
    /// unverified — the consumer verifies the served genesis against the
    /// parent's on-chain anchor. Deduped, bounded, briefly cached.
    private func performReadURLDiscovery(genesisCID: String) async -> [String] {
        let generation = runtimeGeneration
        var own: [String] = []
        // Same cheap precheck as serving an ask: the state walk runs only
        // when this node has anything to declare.
        if let process,
           configuration.publicReadURL != nil || !childDeclaredReadURLs.isEmpty {
            own = await declaredReadURLs(
                genesisCID: genesisCID,
                process: process
            )
        }
        let endpoints = await overlay.discoverProviders(rootCID: genesisCID)
        // One candidate per provider identity, not per host: the ask goes to
        // the identity's session, so several providers behind one IP are
        // each asked, and one identity's several routes take one ask slot.
        var seenKeys: Set<PeerKey> = []
        var candidates: [PeerKey] = []
        for endpoint in endpoints {
            guard let key = try? PeerKey(endpoint.publicKey),
                  key.hex != configuration.processPublicKey,
                  seenKeys.insert(key).inserted else { continue }
            candidates.append(key)
            if candidates.count >= 32 { break }
        }
        var urlsByCandidate = [[String]](
            repeating: [],
            count: candidates.count
        )
        // Asks run concurrently: a legacy peer never answers (it drops the
        // unknown topic), so a sequential walk would stall the explorer route
        // for asks-times-deadline against an unupgraded fleet.
        await withTaskGroup(of: (Int, [String]).self) { group in
            var asked = 0
            for (index, key) in candidates.enumerated() {
                guard asked < Self.maximumReadEndpointAsks,
                      let peer = overlayPeers[key] else { continue }
                asked += 1
                group.addTask { [weak self] in
                    guard let self else { return (index, []) }
                    return (index, await self.askDeclaredReadURLs(
                        genesisCID: genesisCID,
                        from: peer,
                        generation: generation
                    ))
                }
            }
            for await (index, urls) in group {
                urlsByCandidate[index] = urls
            }
        }
        var seenURLs: Set<String> = []
        var declared: [String] = []
        for urls in [own] + urlsByCandidate {
            // Per-responder cap: a declaration is self-described hint data,
            // so one responder must not be able to flood the merged answer.
            for url in urls.prefix(Self.maximumDeclaredURLsPerResponder)
            where seenURLs.insert(url).inserted {
                declared.append(url)
            }
        }
        let bounded = Array(declared.prefix(16))
        guard isCurrentGeneration(generation) else { return bounded }
        let now = Date()
        readURLDiscoveries = readURLDiscoveries.filter { $0.value.expires > now }
        if readURLDiscoveries.count < Self.maximumReadURLDiscoveryCacheEntries {
            readURLDiscoveries[genesisCID] = ReadURLDiscovery(
                urls: bounded,
                expires: now.addingTimeInterval(Self.readURLDiscoveryCacheSeconds)
            )
        }
        return bounded
    }

    private static let maximumReadEndpointAsks = 8
    private static let maximumDeclaredURLsPerResponder = 2
    private static let maximumReadURLDiscoveryCacheEntries = 64
    private static let readURLDiscoveryCacheSeconds: TimeInterval = 30
    private static let readEndpointAskTimeout: Duration = .seconds(2)

    /// This node's own self-description for `genesisCID`: its configured
    /// public read URL when that is its own chain's genesis, plus the URLs its
    /// wired children declared in their hierarchy hellos when the CID is one
    /// this node anchored for a child directory. Deduped, bounded.
    private func declaredReadURLs(
        genesisCID: String,
        process: ChainProcess
    ) async -> [String] {
        var urls: [String] = []
        if let own = configuration.publicReadURL,
           await process.mainChainBlockCID(atHeight: 0) == genesisCID {
            urls.append(own)
        }
        // One sample of the wired children, taken before the resolve suspends
        // and iterated below: the answer then describes a single consistent
        // moment. Reading live `hierarchyPeers` after the suspension instead
        // would mix a child admitted mid-resolve into a lookup that never
        // asked for its directory, and drop it anyway. It is served from the
        // next ask on.
        let wiredChildren = hierarchyPeers.compactMap { key, role -> (PeerKey, String)? in
            guard case .child(let path) = role, let directory = path.last else {
                return nil
            }
            return (key, directory)
        }
        let anchored = await process.anchoredChildGenesisCIDs(
            directories: Set(wiredChildren.map(\.1))
        )
        let directories = Set(
            anchored.filter { $0.value == genesisCID }.map(\.key)
        )
        if !directories.isEmpty {
            // Shuffled, not dictionary order: wired-child roles are
            // permissionless, and a stable iteration order would let a batch
            // of sybil declarants shadow the honest child's URL from every
            // answer for the process lifetime. Random selection keeps every
            // declarant reachable across repeated asks.
            for (key, directory) in wiredChildren.shuffled() {
                guard directories.contains(directory),
                      let url = childDeclaredReadURLs[key],
                      !urls.contains(url) else { continue }
                urls.append(url)
                if urls.count >= ReadEndpointResponseMessage.maximumURLs {
                    break
                }
            }
        }
        return Array(urls.prefix(ReadEndpointResponseMessage.maximumURLs))
    }

    /// One bounded ask against an authenticated overlay session. Registered
    /// before the send so the response can never race the pending entry;
    /// resolves empty on send failure, timeout (legacy peers drop the topic
    /// silently), or runtime teardown.
    private func askDeclaredReadURLs(
        genesisCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64
    ) async -> [String] {
        guard isRunning, isCurrentGeneration(generation) else { return [] }
        let requestID = makeRequestID()
        guard let payload = try? ReadEndpointRequestMessage(
            requestID: requestID,
            genesisCID: genesisCID
        ).encoded() else { return [] }
        // A dedicated short deadline, NOT the overlay's content-pull timeout:
        // a legacy peer never answers, and this wait sits on the public
        // explorer route's critical path.
        let timeoutNanoseconds = Self.nanoseconds(Self.readEndpointAskTimeout)
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                await self?.readEndpointAskTimedOut(requestID: requestID)
            }
            pendingReadEndpoints[requestID] = PendingReadEndpoint(
                peer: peer,
                genesisCID: genesisCID,
                continuation: continuation,
                timeout: timeoutTask
            )
            Task { [weak self] in
                guard let self else { return }
                guard case .enqueued = await self.overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.readEndpointRequest,
                    payload: payload
                ) else {
                    await self.readEndpointAskTimedOut(requestID: requestID)
                    return
                }
            }
        }
    }

    private func readEndpointAskTimedOut(requestID: UInt64) {
        guard let pending = pendingReadEndpoints.removeValue(
            forKey: requestID
        ) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(returning: [])
    }

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

    public func publishAcceptedBlock(_ blockCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        try await announceBlock(
            blockCID,
            generation: generation,
            process: process
        )
    }

    /// Announces an already admitted complete transaction Volume to same-chain
    /// overlay peers. The process content source serves the Volume itself.
    public func publishTransaction(_ volumeRootCID: String) async throws {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: volumeRootCID
        ).encoded() else { return }
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                throw NodeNetworkRuntimeError.notRunning
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    /// Requests contextual templates from authenticated immediate children for
    /// one exact provisional carrier. Missing or slow children are omitted.
    public func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async -> [DirectChildCandidate] {
        guard isRunning,
            let process,
              let parentData = context.parentCarrier.toData(),
              let parentCID = try? BlockHeader(node: context.parentCarrier).rawCID,
            let deadline = childCandidateRequestDeadline()
        else {
            return []
        }
        let parentBoundary = try? VolumeImpl<Block>(node: context.parentCarrier)
        let provisionalBroker = MemoryBroker()
        try? await parentBoundary?.store(storer: provisionalBroker)
        guard let parentVolume = await provisionalBroker.fetchVolumeLocal(
            root: parentCID
        ), (try? parentVolume.validate()) != nil else { return [] }
        let generation = runtimeGeneration
        guard await provisionalRoots.retain(
            parentVolume,
            generation: generation
        ) else { return [] }
        let children = selectedChildPeers().filter {
            guard let directory = $0.2.last else { return false }
            return !context.excludedDirectories.contains(directory)
        }

        var candidates: [(Int, DirectChildCandidate)] = []
        await withTaskGroup(of: (Int, DirectChildCandidate?).self) { group in
            for (rank, key, path) in children {
                let rewards = context.rewards.filter {
                    $0.chainPath.count >= path.count
                        && Array($0.chainPath.prefix(path.count)) == path
                }
                let minimumWork = context.minimumWork.filter {
                    $0.chainPath.count >= path.count
                        && Array($0.chainPath.prefix(path.count)) == path
                }
                group.addTask {
                    let candidate = await self.requestChildCandidate(
                        from: key,
                        childPath: path,
                        parentCID: parentCID,
                        parentData: parentData,
                        rewards: rewards,
                        minimumWork: minimumWork,
                        deadline: deadline,
                        generation: generation,
                        process: process
                    )
                    return (rank, candidate)
                }
            }
            for await (rank, candidate) in group {
                if let candidate { candidates.append((rank, candidate)) }
            }
        }
        await provisionalRoots.release(parentCID, generation: generation)
        guard isCurrentRuntime(generation: generation, process: process) else {
            return []
        }

        // A path claim is not authority. Query several authenticated claimants
        // and rotate priority so a grindable lexicographic key cannot own a slot.
        var selectedDirectories: Set<String> = []
        let selected = candidates.sorted { $0.0 < $1.0 }.compactMap {
            selectedDirectories.insert($0.1.directory).inserted ? $0.1 : nil
        }
        return selected.sorted { $0.directory < $1.directory }
    }

    /// Replaces the complete bounded candidate reservation set at every exact
    /// direct-child process. Additions require a durable authenticated ack;
    /// disconnected removals are retried on the next session.
    public func reconcileChildCandidateReservations(
        _ update: ChildCandidateReservationUpdate
    ) async -> Bool {
        guard isRunning else {
            return update.reservations.isEmpty && update.handoffs.isEmpty
        }
        var desired: [PeerKey: Set<String>] = [:]
        for reference in Set(update.reservations) {
            desired[reference.peerKey, default: []].insert(
                reference.candidateCID
            )
            guard desired[reference.peerKey]!.count
                    <= ChildCandidateReservationRequestMessage.maximumCandidateCIDs
            else { return false }
        }
        var handoffs: [PeerKey: Set<String>] = [:]
        for reference in Set(update.handoffs) {
            handoffs[reference.peerKey, default: []].insert(
                reference.candidateCID
            )
            guard (desired[reference.peerKey]?.count ?? 0)
                    + handoffs[reference.peerKey]!.count
                    <= ChildCandidateReservationRequestMessage.maximumCandidateCIDs,
                  desired[reference.peerKey]?.contains(reference.candidateCID)
                    != true
            else { return false }
        }
        let currentPeers = Set(desiredCandidateReservations.keys)
            .union(desired.keys).union(handoffs.keys)
        let alreadyTargeted = currentPeers.allSatisfy {
            (desired[$0] ?? []) == (desiredCandidateReservations[$0] ?? [])
        }
        if !candidateReservationReconciliationInFlight,
           alreadyTargeted,
           handoffs.isEmpty,
           dirtyCandidateReservationPeers.allSatisfy({
               candidateReservationRemovalFlushes[$0] != nil
           }) {
            return true
        }
        await acquireCandidateReservationReconciliation()
        defer { releaseCandidateReservationReconciliation() }
        guard isRunning, let process else {
            return update.reservations.isEmpty && update.handoffs.isEmpty
        }
        let peers = Set(desiredCandidateReservations.keys)
            .union(desired.keys).union(handoffs.keys)
            .sorted()
        let changedPeers = peers.filter { peerKey in
            let next = desired[peerKey] ?? []
            let previous = desiredCandidateReservations[peerKey] ?? []
            return next != previous
                || !(handoffs[peerKey] ?? []).isEmpty
                || dirtyCandidateReservationPeers.contains(peerKey)
        }
        let removalTargets = Dictionary(uniqueKeysWithValues:
            changedPeers.compactMap { peerKey in
                let next = desired[peerKey] ?? []
                let previous = desiredCandidateReservations[peerKey] ?? []
                return next.subtracting(previous).isEmpty
                    ? (peerKey, next)
                    : nil
            }
        )
        for (peerKey, target) in removalTargets {
            desiredCandidateReservations[peerKey] = target
            dirtyCandidateReservationPeers.insert(peerKey)
        }
        var requests: [(
            peerKey: PeerKey,
            target: Set<String>,
            handoffs: Set<String>,
            childPath: [String],
            peer: AuthenticatedPeer
        )] = []
        var rejected = false
        let generation = runtimeGeneration
        for peerKey in peers {
            guard removalTargets[peerKey] == nil else { continue }
            let next = desired[peerKey] ?? []
            let previous = desiredCandidateReservations[peerKey] ?? []
            let changed = next != previous
                || dirtyCandidateReservationPeers.contains(peerKey)
            guard changed else { continue }
            if let removal = candidateReservationRemovalFlushes[peerKey] {
                await removal.task.value
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else {
                    return update.reservations.isEmpty
                        && update.handoffs.isEmpty
                }
            }
            guard case .child(let childPath)? = hierarchyPeers[peerKey],
                  let peer = hierarchySessions[peerKey],
                  childEvidenceReadyPeers.contains(peerKey) else {
                if !next.subtracting(previous).isEmpty {
                    dirtyCandidateReservationPeers.insert(peerKey)
                    rejected = true
                    continue
                }
                desiredCandidateReservations[peerKey] = next
                dirtyCandidateReservationPeers.insert(peerKey)
                continue
            }
            requests.append((
                peerKey,
                next,
                handoffs[peerKey] ?? [],
                childPath,
                peer
            ))
        }
        await withTaskGroup(of: CandidateReservationAttempt.self) { group in
            for request in requests {
                group.addTask {
                    CandidateReservationAttempt(
                        peerKey: request.peerKey,
                        target: request.target,
                        accepted: await self.requestCandidateReservation(
                            candidateCIDs: request.target.sorted(),
                            handoffCIDs: request.handoffs.sorted(),
                            childPath: request.childPath,
                            peer: request.peer,
                            generation: generation,
                            process: process
                        )
                    )
                }
            }
            for await attempt in group {
                if attempt.accepted {
                    desiredCandidateReservations[attempt.peerKey] = attempt.target
                    dirtyCandidateReservationPeers.remove(attempt.peerKey)
                } else {
                    dirtyCandidateReservationPeers.insert(attempt.peerKey)
                    rejected = true
                }
            }
        }
        for (peerKey, target) in removalTargets {
            scheduleCandidateReservationRemoval(
                peerKey: peerKey,
                target: target,
                handoffs: handoffs[peerKey] ?? [],
                generation: generation,
                process: process
            )
        }
        return !rejected
    }

    private func scheduleCandidateReservationRemoval(
        peerKey: PeerKey,
        target: Set<String>,
        handoffs: Set<String>,
        generation: UInt64,
        process: ChainProcess
    ) {
        let previous = candidateReservationRemovalFlushes[peerKey]?.task
        nextCandidateReservationRemovalFlushToken &+= 1
        let token = nextCandidateReservationRemovalFlushToken
        let task = Task { [weak self] in
            await previous?.value
            await self?.flushCandidateReservationRemoval(
                peerKey: peerKey,
                target: target,
                handoffs: handoffs,
                token: token,
                generation: generation,
                process: process
            )
        }
        candidateReservationRemovalFlushes[peerKey] =
            CandidateReservationRemovalFlush(token: token, task: task)
    }

    private func flushCandidateReservationRemoval(
        peerKey: PeerKey,
        target: Set<String>,
        handoffs: Set<String>,
        token: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer {
            if candidateReservationRemovalFlushes[peerKey]?.token == token {
                candidateReservationRemovalFlushes.removeValue(forKey: peerKey)
            }
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        // Flush every transition in order, even if a newer target arrived
        // before this task started. A committed handoff belongs to this exact
        // release and must never be collapsed away; the queued newer update
        // will replace this target afterward.
        guard case .child(let childPath)? = hierarchyPeers[peerKey],
              let peer = hierarchySessions[peerKey],
              childEvidenceReadyPeers.contains(peerKey) else { return }
        let accepted = await requestCandidateReservation(
            candidateCIDs: target.sorted(),
            handoffCIDs: handoffs.sorted(),
            childPath: childPath,
            peer: peer,
            generation: generation,
            process: process
        )
        if accepted, desiredCandidateReservations[peerKey] == target {
            dirtyCandidateReservationPeers.remove(peerKey)
        }
    }

    private func acquireCandidateReservationReconciliation() async {
        guard candidateReservationReconciliationInFlight else {
            candidateReservationReconciliationInFlight = true
            return
        }
        await withCheckedContinuation {
            candidateReservationReconciliationWaiters.append($0)
        }
    }

    private func releaseCandidateReservationReconciliation() {
        guard !candidateReservationReconciliationWaiters.isEmpty else {
            candidateReservationReconciliationInFlight = false
            return
        }
        candidateReservationReconciliationWaiters.removeFirst().resume()
    }

    private func parentEvidenceSession(
        for peer: AuthenticatedPeer
    ) -> ParentEvidenceSession? {
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else { return nil }
        return ParentEvidenceSession(
            peerID: peer.key.hex,
            sessionID: peer.sessionID
        )
    }

    /// Outcome of scheduling a batch of parent-announced evidence. LOCAL
    /// backpressure is deliberately distinct from rejection: recycling the
    /// authenticated parent link because THIS node's evidence lane is busy
    /// severs the only eager delivery path and caps recovery at one scan per
    /// reconnect — the announcement is droppable (the durable index re-serves
    /// it), the session is not.
    private enum ParentEvidenceAppend {
        case scheduled(Task<ParentEvidenceResult, Never>)
        case backpressured
        case rejected
    }

    private func appendParentEvidence(
        _ summaries: [IssuedChildEvidenceSummary],
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> ParentEvidenceAppend {
        guard !summaries.isEmpty else { return .backpressured }
        guard isCurrentRuntime(generation: generation, process: process),
              let session = parentEvidenceSession(for: peer) else {
            return .rejected
        }
        let activePortable = activeEvidenceVolumes.lazy.filter {
            $0.plane == .overlay
        }.count
        guard let append = parentEvidence.beginAppend(
            for: session,
            competingOperationCount: portableEvidenceWork.count
                + activePortable,
            capacity: Self.maximumEvidenceCandidates
        ) else { return .backpressured }
        let task = Task { [weak self] in
            guard let self else { return ParentEvidenceResult.failed }
            var result = if let predecessor = append.predecessor {
                await predecessor.value
            } else {
                ParentEvidenceResult.handled
            }
            if Task.isCancelled { result = .failed }
            for summary in summaries where result == .handled {
                result = await self.recoverParentEvidence(
                    summary,
                    sourceID: sourceID,
                    advanceScan: advanceScan,
                    from: peer,
                    generation: generation,
                    process: process
                )
            }
            await self.finishParentEvidence(
                session: session,
                token: append.token,
                result: result,
                peer: peer,
                generation: generation,
                process: process
            )
            return result
        }
        parentEvidence.install(
            task,
            token: append.token,
            for: session
        )
        return .scheduled(task)
    }

    private func finishParentEvidence(
        session: ParentEvidenceSession,
        token: UInt64,
        result: ParentEvidenceResult,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let shouldRecycle = parentEvidence.finish(
            token: token,
            result: result,
            for: session
        )
        guard parentEvidenceSession(for: peer) == session else { return }
        if shouldRecycle {
            await hierarchy.recycleSession(ifCurrent: peer)
        }
    }

    private func respondToCandidateReservation(
        _ request: ChildCandidateReservationRequestMessage,
        from peer: AuthenticatedPeer,
        session: ParentEvidenceSession,
        after evidenceTail: Task<ParentEvidenceResult, Never>?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        defer { parentEvidence.finishReservation(for: session) }
        let evidenceResult = await evidenceTail?.value ?? .handled
        guard evidenceResult != .failed,
              isCurrentRuntime(generation: generation, process: process),
              parentEvidenceSession(for: peer) == session,
              !parentEvidence.isFailed(session) else {
            await hierarchy.recycleSession(ifCurrent: peer)
            return
        }
        let accepted = if parentEvidence.allowsReservation(
            for: session,
            after: evidenceResult
        ) {
            await handlers?.candidateReservations?(
                NetworkCandidateReservationUpdate(
                    candidateCIDs: request.candidateCIDs,
                    handoffCIDs: request.handoffCIDs
                )
            ) ?? false
        } else {
            false
        }
        guard isCurrentRuntime(generation: generation, process: process),
              parentEvidenceSession(for: peer) == session,
              let payload = try? ChildCandidateReservationResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                accepted: accepted
              ).encoded() else { return }
        _ = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateReservationResponse,
            payload: payload
        )
    }

    private func cancelParentEvidence(for key: PeerKey) {
        parentEvidence.cancel(peerID: key.hex)
    }

    private func waitForChildEvidenceReady(
        peer: AuthenticatedPeer
    ) async -> Bool {
        guard !childEvidenceReadyPeers.contains(peer.key) else { return true }
        return await withCheckedContinuation { continuation in
            childEvidenceReadyWaiters[peer.key, default: []].append(
                ChildEvidenceReadyWaiter(
                    sessionID: peer.sessionID,
                    continuation: continuation
                )
            )
        }
    }

    private func markChildEvidenceReady(_ peer: AuthenticatedPeer) {
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
            return
        }
        childEvidenceReadyPeers.insert(peer.key)
        let waiters = childEvidenceReadyWaiters.removeValue(
            forKey: peer.key
        ) ?? []
        for waiter in waiters {
            waiter.continuation.resume(
                returning: waiter.sessionID == peer.sessionID
            )
        }
    }

    private func cancelChildEvidenceReadyWaiters(for peerKey: PeerKey) {
        childEvidenceIndexCompleteSessions =
            childEvidenceIndexCompleteSessions.filter {
                $0.peerKey != peerKey
            }
        childEvidencePublicationFailedSessions =
            childEvidencePublicationFailedSessions.filter {
                $0.peerKey != peerKey
            }
        childEvidencePublicationsInFlight =
            childEvidencePublicationsInFlight.filter {
                $0.key.peerKey != peerKey
            }
        let waiters = childEvidenceReadyWaiters.removeValue(
            forKey: peerKey
        ) ?? []
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
    }

    private func canServeHierarchyContent(to peer: AuthenticatedPeer) -> Bool {
        runtimeGeneration != 0
            && hierarchyPeers[peer.key] != nil
            && hierarchySessions[peer.key]?.sessionID == peer.sessionID
    }

    private func provisionalVolume(
        forRoot cid: String
    ) async -> SerializedVolume? {
        await provisionalRoots.volume(cid, generation: runtimeGeneration)
    }

    /// Publishes an already-promoted absolute proof prepared durably by the
    /// process admission boundary.
    @discardableResult
    public func publishChildProof(
        _ proof: ChildBlockProof,
        childDirectory: String,
        childCID: String
    ) async throws -> ChildBlockProof {
        guard isRunning, let process else {
            throw NodeNetworkRuntimeError.notRunning
        }
        let generation = runtimeGeneration
        let childPath = configuration.chainPath + [childDirectory]
        guard _isBoundedWireAtom(childCID),
              proof.directoryPath == Array(childPath.dropFirst()),
              !childDirectory.isEmpty,
              (try? proof.serialize()) != nil,
              let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID
        else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard (try? await process.issuedChildEvidence(
            childCID: childCID,
            directory: childDirectory,
            rootCID: proof.rootCID
        )) != nil else {
            throw NodeNetworkRuntimeError.invalidChildProof
        }
        guard
            await announceChildEvidenceAvailability(
                childPath: childPath,
                childCID: childCID,
                rootCID: proof.rootCID,
                generation: generation,
                process: process
            )
        else {
            throw NodeNetworkRuntimeError.notRunning
        }
        return proof
    }

    /// Tell authenticated direct children about evidence that has already been
    /// made durable. This closes the reconnect race where the child asks for
    /// its index just before the parent finishes preparing the proof.
    private func announceChildEvidenceAvailability(
        childPath: [String],
        childCID: String,
        rootCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return false
        }
        let bootstrappingPeers = hierarchyPeers.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  !childEvidenceReadyPeers.contains(key) else { return nil }
            return hierarchySessions[key]
        }
        for peer in bootstrappingPeers {
            let session = ChildEvidenceSession(
                peerKey: peer.key,
                sessionID: peer.sessionID
            )
            childEvidencePublicationsInFlight[session, default: 0] += 1
        }
        guard let directory = childPath.last,
            let evidence = try? await process.issuedChildEvidence(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            let indexed = try? await process.issuedChildEvidenceSummary(
                childCID: childCID,
                directory: directory,
                rootCID: rootCID
            ),
            isCurrentRuntime(generation: generation, process: process),
            let payload = try? ChildEvidenceAvailableMessage(
                childPath: childPath,
                sourceID: indexed.sourceID,
                ordinal: indexed.summary.ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: evidence.attachmentCID
            ).encoded()
        else {
            for peer in bootstrappingPeers {
                finishChildEvidencePublication(
                    to: peer,
                    permitsCleanup: false
                )
                await hierarchy.recycleSession(ifCurrent: peer)
            }
            return false
        }
        let readyPeers = hierarchyPeers.compactMap {
            key, role -> AuthenticatedPeer? in
            guard case .child(let path) = role,
                  path == childPath,
                  childEvidenceReadyPeers.contains(key) else { return nil }
            return hierarchySessions[key]
        }
        for peer in bootstrappingPeers + readyPeers {
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
                if !childEvidenceReadyPeers.contains(peer.key) {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                continue
            }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceAvailable,
                payload: payload
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return false
            }
            let bootstrapping = !childEvidenceReadyPeers.contains(peer.key)
            switch result {
            case .enqueued:
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: true
                    )
                }
            case .notConnected, .backpressured, .locallyRejected:
                if bootstrapping {
                    finishChildEvidencePublication(
                        to: peer,
                        permitsCleanup: false
                    )
                }
                await hierarchy.recycleSession(ifCurrent: peer)
            }
        }
        return isCurrentRuntime(generation: generation, process: process)
    }

    private func finishChildEvidencePublication(
        to peer: AuthenticatedPeer,
        permitsCleanup: Bool
    ) {
        let session = ChildEvidenceSession(
            peerKey: peer.key,
            sessionID: peer.sessionID
        )
        guard let count = childEvidencePublicationsInFlight[session] else {
            return
        }
        if !permitsCleanup {
            childEvidencePublicationFailedSessions.insert(session)
        }
        if count == 1 {
            childEvidencePublicationsInFlight.removeValue(forKey: session)
            if permitsCleanup,
               !childEvidencePublicationFailedSessions.contains(session),
               childEvidenceIndexCompleteSessions.contains(session),
               hierarchySessions[peer.key]?.sessionID == peer.sessionID {
                markChildEvidenceReady(peer)
            }
        } else {
            childEvidencePublicationsInFlight[session] = count - 1
        }
    }

    private func completeChildEvidenceIndex(for peer: AuthenticatedPeer) {
        let session = ChildEvidenceSession(
            peerKey: peer.key,
            sessionID: peer.sessionID
        )
        childEvidenceIndexCompleteSessions.insert(session)
        if childEvidencePublicationsInFlight[session] == nil,
           !childEvidencePublicationFailedSessions.contains(session) {
            markChildEvidenceReady(peer)
        }
    }

    /// A direct child pulls its bounded index once on authentication. If that
    /// pull races durable proof preparation, re-advertise only evidence for
    /// this local carrier in its authenticated root context(s).
    private func announceCurrentCarrierChildEvidence(
        directories: [String],
        carrierCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        let directories = Set(directories)
        var afterRootCID: String?
        var announcements = 0
        var rootsExamined = 0
        while announcements < Self.maximumReconnectEvidenceAnnouncements,
            rootsExamined < Self.maximumReconnectCarrierRoots
        {
            let remainingRoots = Self.maximumReconnectCarrierRoots - rootsExamined
            guard
                let roots = try? await process.parentCarrierRootPage(
                    carrierCID: carrierCID,
                    afterRootCID: afterRootCID,
                    limit: remainingRoots
                )
            else {
                return isCurrentRuntime(generation: generation, process: process)
            }
            guard !roots.isEmpty else { break }
            rootsExamined += roots.count
            for rootCID in roots {
                guard
                    let proofs = try? await process.durableDirectChildProofs(
                        carrierCID: carrierCID,
                        rootCID: rootCID,
                        directories: directories
                    )
                else { continue }
                for proof in proofs {
                    guard
                        await announceChildEvidenceAvailability(
                            childPath: configuration.chainPath + [proof.directory],
                            childCID: proof.childCID,
                            rootCID: proof.proof.rootCID,
                            generation: generation,
                            process: process
                        )
                    else { return false }
                    announcements += 1
                    if announcements == Self.maximumReconnectEvidenceAnnouncements {
                        return isCurrentRuntime(
                            generation: generation,
                            process: process
                        )
        }
                }
            }
            afterRootCID = roots.last
            guard roots.count == remainingRoots else { break }
        }
        return isCurrentRuntime(generation: generation, process: process)
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
            if let previous = overlayPeers[peer.key] {
                candidateAcquirer.disconnect(candidateProvider(previous))
            }
            overlayPeers.removeValue(forKey: peer.key)
            discardServingSessions(for: peer.key)
            frontierPulls.removeValue(forKey: peer.key)
            overlaySessions[peer.key] = peer
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
            _ = clearHierarchyAuthorization(for: peer.key)
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
            // asynchronous disconnect callback arrives.
            guard !(await ivy.connectedPeers).contains(peer) else { return }
            overlayHelloDeadlines.removeValue(forKey: key)?.task.cancel()
            if let disconnected = overlayPeers[key] {
                candidateAcquirer.disconnect(candidateProvider(disconnected))
            }
            discardServingSessions(for: key)
            frontierPulls.removeValue(forKey: key)
            if rangeSync?.peer.key == key {
                clearRangeSync()
            }
            overlaySessions.removeValue(forKey: key)
            overlayPeers.removeValue(forKey: key)
            announcedTips.removeValue(forKey: key)
            let disconnectedInventories = pendingTransactionInventories.filter {
                $0.value.peer.key == key
            }
            for pending in disconnectedInventories.values {
                pending.timeout.cancel()
            }
            pendingTransactionInventories = pendingTransactionInventories.filter {
                $0.value.peer.key != key
            }
            // A response can never arrive on a gone session (a reconnect gets
            // a fresh sessionID the response guard rejects), so resolve the
            // ask empty now instead of burning its timeout.
            let disconnectedReadEndpoints = pendingReadEndpoints.filter {
                $0.value.peer.key == key
            }
            pendingReadEndpoints = pendingReadEndpoints.filter {
                $0.value.peer.key != key
            }
            for pending in disconnectedReadEndpoints.values {
                pending.timeout.cancel()
                pending.continuation.resume(returning: [])
            }
        } else if ivy === hierarchy {
            // Ivy may already have promoted a replacement session for this
            // identity before this asynchronous delegate callback reaches us.
            // In that case this is the old connection ending, not a loss of
            // the authenticated parent/child relationship.
            guard !(await ivy.connectedPeers).contains(peer) else { return }
            _ = clearHierarchyAuthorization(for: key)
        }
    }

    @discardableResult
    private func clearHierarchyAuthorization(for key: PeerKey) -> HierarchyPeer? {
        hierarchyHelloDeadlines.removeValue(forKey: key)?.task.cancel()
        cancelParentEvidence(for: key)
        let removedRole = hierarchyPeers.removeValue(forKey: key)
        hierarchySessions.removeValue(forKey: key)
        childDeclaredReadURLs.removeValue(forKey: key)
        childEvidenceReadyPeers.remove(key)
        cancelChildEvidenceReadyWaiters(for: key)
        dirtyCandidateReservationPeers.remove(key)
        if desiredCandidateReservations[key]?.isEmpty == true {
            desiredCandidateReservations.removeValue(forKey: key)
        }
        Self.pruneChildPeerRotations(
            &childPeerRotation,
            activeRoles: Array(hierarchyPeers.values)
        )
        if case .child(let path)? = removedRole, let directory = path.last,
           !hierarchyPeers.values.contains(where: { role in
               guard case .child(let other) = role else { return false }
               return other.last == directory
           }) {
            // Last peer for this directory left: let a reconnecting child
            // re-run the late-child backfill for carriers admitted while it was
            // gone (those got no admission-time route seeded for it).
            backfilledChildDirectories.remove(directory)
        }
        if case .parent? = removedRole {
            pendingEvidenceIndexes.removeAll()
            // A response can never arrive on the gone session: requeue the
            // live candidates now, and resolve a validate walk's request nil
            // (it is not a candidate — re-seeding an accepted main-chain block
            // would be wrong — and an unresumed continuation would suspend
            // the walk for the process lifetime).
            discardPendingParentChainFacts(
                where: { $0.peer.key == key },
                requeue: true
            )
        }
        cancelChildCandidateWork(for: key)
        let reservations = pendingCandidateReservations.filter {
            $0.value.peer.key == key
        }
        pendingCandidateReservations = pendingCandidateReservations.filter {
            $0.value.peer.key != key
        }
        for reservation in reservations.values {
            reservation.continuation.resume(returning: false)
        }
        return removedRole
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

    private func handleOverlay(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.overlayHello {
            SyncTrace.log(
                "overlay hello peer=\(peer.key.hex.prefix(8)) "
                    + "expected=\(expectsOverlayHello(from: peer))"
            )
            guard expectsOverlayHello(from: peer) else { return }
            guard let remote = try? ChainHello.decode(message.payload),
                  (try? remote.validateCompatibility(
                    expectedNexusGenesisCID: configuration.nexusGenesisCID,
                    expectedChainPath: configuration.chainPath
                )) != nil
            else {
                await overlay.disconnectSession(ifCurrent: peer)
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  expectsOverlayHello(from: peer) else { return }
            overlayHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
            overlaySessions.removeValue(forKey: peer.key)
            overlayPeers[peer.key] = peer
            // Advertise the ACQUIRED (canonical, weighed-inclusive) tip: every
            // receiver measures its gap, its range-sync target and its edge
            // against acquired heights, so advertising the validated tip would
            // strand a joiner at our validated height on a quiet network and
            // make it pull our frontier while genuinely deep.
            let helloTip = await process.canonicalTip()
            if let helloTip,
                let payload = try? BlockAnnouncementMessage(
                    blockCID: helloTip.cid,
                    height: helloTip.height
                ).encoded()
            {
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                    return
                }
                let sent = await overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
                SyncTrace.log(
                    "hello reply peer=\(peer.key.hex.prefix(8)) "
                        + "tip=\(helloTip.height) sent=\(sent)"
                )
            }
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            // The peer's frontier is pulled by `pullFrontierIfAtEdge` once its
            // tip is known (its own hello-reply announcement) and we are at
            // the live edge with respect to it — never blindly here.
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
            await requestTransactionInventory(
                from: peer,
                after: nil,
                generation: generation,
                process: process
            )
            return
        }

        guard overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        switch message.topic {
        case NodeNetworkTopic.transactionAvailable:
            guard let available = try? TransactionAvailableMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionVolume(
                available.volumeRootCID,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryRequest:
            guard let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
            ) else { return }
            await serveTransactionInventory(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.transactionInventoryResponse:
            guard let response = try? TransactionInventoryResponseMessage.decoded(
                message.payload
            ) else { return }
            scheduleTransactionInventory(
                response,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.portableAttachmentAvailable:
            guard let available = try? PortableAttachmentAvailableMessage
                .decoded(message.payload) else { return }
            let handled = enqueuePortableEvidence(
                PortableAttachmentSummary(
                    edgeCID: available.edgeCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                ),
                from: peer,
                generation: generation,
                process: process
            )
            if !handled { await overlay.recycleSession(ifCurrent: peer) }
        case NodeNetworkTopic.portableAttachmentIndexRequest:
            guard let request = try? PortableAttachmentIndexRequestMessage
                .decoded(message.payload) else { return }
            await servePortableAttachmentIndex(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.portableAttachmentLocateRequest:
            guard let request = try? PortableAttachmentLocateRequestMessage
                .decoded(message.payload) else { return }
            await servePortableAttachmentLocate(
                request,
                to: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.readEndpointRequest:
            guard let request = try? ReadEndpointRequestMessage.decoded(
                    message.payload
                )
            else { return }
            // The state walk behind declaredReadURLs runs only when this node
            // has anything to declare, single-flight per session, AND under
            // the same global parent-state query capacity as the
            // hierarchy-plane resolve of the identical subtrie — an overlay
            // peer flood cannot multiply tip-state walks. Every other outcome
            // still answers empty: a fast negative beats making the asker
            // burn its timeout.
            var urls: [String] = []
            if configuration.publicReadURL != nil
                || !childDeclaredReadURLs.isEmpty,
                servingReadEndpoints.insert(peer.sessionID).inserted {
                defer {
                    if isCurrentRuntime(
                        generation: generation,
                        process: process
                    ) {
                        servingReadEndpoints.remove(peer.sessionID)
                    }
                }
                if parentStateQueryGuard.acquire(peer.key) {
                    defer {
                        parentStateQueryGuard.release(peer.key)
                    }
                    urls = await declaredReadURLs(
                        genesisCID: request.genesisCID,
                        process: process
                    )
                }
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  let payload = try? ReadEndpointResponseMessage(
                      requestID: request.requestID,
                      genesisCID: request.genesisCID,
                      readURLs: urls
                  ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.readEndpointResponse,
                payload: payload
            )
        case NodeNetworkTopic.readEndpointResponse:
            guard let response = try? ReadEndpointResponseMessage.decoded(
                    message.payload
                ),
                let pending = pendingReadEndpoints[response.requestID],
                pending.peer.key == peer.key,
                pending.peer.sessionID == peer.sessionID,
                pending.genesisCID == response.genesisCID
            else { return }
            pendingReadEndpoints.removeValue(forKey: response.requestID)
            pending.timeout.cancel()
            pending.continuation.resume(returning: response.readURLs)
        case NodeNetworkTopic.blockAnnouncement:
            guard let announcement = try? BlockAnnouncementMessage.decoded(message.payload) else {
                return
            }
            await overlay.rememberProvider(
                rootCID: announcement.blockCID,
                peer: peer.id
            )
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
            // Only a genuinely deep gap — far more than a predecessor pull should
            // bridge — starts a forward-apply range sync; shallow and
            // steady-state propagation and child-chain rounds keep the fast
            // direct path below, with no wasted range-sync round-trips. The
            // announced height is the gap signal (absent for legacy peers, which
            // then just use the direct path).
            if await process.hasAcceptedBlock(announcement.blockCID) == false {
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
                let ourHeight = await acquiredHeight(process)
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
                if let announced = announcement.height {
                    // Remember the claim so a cleared range sync can re-enter
                    // on the receiver's own initiative: on a quiet network no
                    // further announcement ever arrives to restart it.
                    let known = announcedTips[peer.key]?.height ?? 0
                    if announced > known
                        || announcedTips[peer.key]?.peer.sessionID
                            != peer.sessionID {
                        announcedTips[peer.key] = (announced, peer)
                    }
                }
                if let announced = announcement.height,
                   announced > ourHeight + Self.rangeSyncDepthThreshold {
                    await startRangeSync(
                        peer: peer,
                        targetHeight: announced,
                        generation: generation,
                        process: process
                    )
                    guard isCurrentRuntime(generation: generation, process: process),
                          overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
                }
            }
            // At-edge evaluation happens whether or not we hold the block:
            // holding the peer's tip IS being at its edge. The peer's height
            // is its best claim this session (this announcement or a taller
            // recorded one), so a losing-sibling announcement below its tip
            // cannot read as "at edge" while we are still deep.
            if let announced = announcement.height {
                let recorded = announcedTips[peer.key]
                let peerHeight = recorded?.peer.sessionID == peer.sessionID
                    ? max(announced, recorded?.height ?? 0)
                    : announced
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: peerHeight,
                    generation: generation,
                    process: process
                )
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
            }
            // Network-sourced: weighed. It ranks on verified work and the
            // validate-on-candidacy walk executes it exactly when canonical.
            let candidate = CandidateSeed(
                blockCID: announcement.blockCID,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            )
            guard enqueueCandidate(candidate) else { return }
        case NodeNetworkTopic.acceptedLeavesRequest:
            // Answers a peer's one-shot frontier pull (see
            // `pullFrontierIfAtEdge`) with one page of accepted leaves; older
            // peers' cursored descent still pages through the same handler.
            // The portable-attachment-index pair stays legacy-served only.
            guard
                let request = try? AcceptedLeavesRequestMessage.decoded(
                    message.payload
                ), servingAcceptedLeaves.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(
                    generation: generation,
                    process: process
                ) {
                    servingAcceptedLeaves.remove(peer.sessionID)
                }
            }
            guard
                let leaves = try? await process.acceptedLeafPage(
                    afterCID: request.afterCID,
                    snapshotSequence: request.snapshotSequence,
                    limit: AcceptedLeavesResponseMessage.maximumLeaves + 1
                ), isCurrentRuntime(generation: generation, process: process)
            else {
                return
            }
            // The cursor-less page is the most recently admitted leaves (the
            // frontier pull); the wire carries a page CID-sorted, and the
            // receiver never depends on order. A cursored (legacy descent)
            // page is already in CID order.
            let page = Array(
                leaves.blockCIDs.prefix(AcceptedLeavesResponseMessage.maximumLeaves)
            ).sorted()
            SyncTrace.log(
                "frontier serve peer=\(peer.key.hex.prefix(8)) leaves=\(page.count)"
            )
            guard
                let payload = try? AcceptedLeavesResponseMessage(
                    requestID: request.requestID,
                    afterCID: request.afterCID,
                    snapshotSequence: leaves.snapshotSequence,
                    blockCIDs: page,
                    hasMore: leaves.blockCIDs.count > page.count
                ).encoded()
            else { return }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.acceptedLeavesResponse,
                payload: payload
            )
        case NodeNetworkTopic.acceptedLeavesResponse:
            // The frontier page (see `pullFrontierIfAtEdge`): accepted only as
            // the one answer to the one request we sent this session —
            // correlated by requestID like every other response, then the
            // request is consumed, so an unsolicited, mismatched or repeated
            // page seeds nothing. Every leaf we lack seeds weighed; its
            // predecessor walk parks on missing ancestors that range sync or
            // the walk itself fills. No cursor, no retry state.
            guard let response = try? AcceptedLeavesResponseMessage.decoded(
                message.payload
            ) else { return }
            guard var pull = frontierPulls[peer.key],
                  pull.sessionID == peer.sessionID,
                  pull.requestID == response.requestID else {
                SyncTrace.log(
                    "frontier page rejected peer=\(peer.key.hex.prefix(8)) "
                        + "leaves=\(response.blockCIDs.count)"
                )
                return
            }
            pull.requestID = nil
            frontierPulls[peer.key] = pull
            SyncTrace.log(
                "frontier page peer=\(peer.key.hex.prefix(8)) "
                    + "leaves=\(response.blockCIDs.count)"
            )
            for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
                await overlay.rememberProvider(rootCID: cid, peer: peer.id)
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
                if await process.hasAcceptedBlock(cid) { continue }
                guard isCurrentRuntime(generation: generation, process: process),
                      overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
                _ = enqueueCandidate(CandidateSeed(
                    blockCID: cid,
                    package: nil,
                    provider: candidateProvider(peer),
                    weighed: true
                ))
            }
        case NodeNetworkTopic.forwardRangeRequest:
            guard
                let request = try? ForwardRangeRequestMessage.decoded(
                    message.payload
                ), servingAncestorRange.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(generation: generation, process: process) {
                    servingAncestorRange.remove(peer.sessionID)
                }
            }
            let page = await process.forwardMainChainRange(
                afterCID: request.afterCID,
                limit: ForwardRangeResponseMessage.maximumBlocks
            )
            guard
                isCurrentRuntime(generation: generation, process: process),
                let payload = try? ForwardRangeResponseMessage(
                    requestID: request.requestID,
                    afterCID: request.afterCID,
                    blockCIDs: page.blockCIDs,
                    hasMore: page.hasMore
                ).encoded()
            else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.forwardRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.forwardRangeResponse:
            await handleForwardRangeResponse(
                message,
                from: peer,
                generation: generation,
                process: process
            )
        case NodeNetworkTopic.ancestorRangeRequest:
            guard
                let request = try? AncestorRangeRequestMessage.decoded(
                    message.payload
                ), servingAncestorRange.insert(peer.sessionID).inserted
            else {
                return
            }
            defer {
                if isCurrentRuntime(generation: generation, process: process) {
                    servingAncestorRange.remove(peer.sessionID)
                }
            }
            let page = await process.commonAncestorRange(
                locator: request.locator,
                limit: AncestorRangeResponseMessage.maximumBlocks
            )
            guard
                isCurrentRuntime(generation: generation, process: process),
                let payload = try? AncestorRangeResponseMessage(
                    requestID: request.requestID,
                    commonAncestor: page.commonAncestor,
                    blockCIDs: page.blockCIDs,
                    hasMore: page.hasMore
                ).encoded()
            else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.ancestorRangeResponse,
                payload: payload
            )
        case NodeNetworkTopic.ancestorRangeResponse:
            await handleAncestorRangeResponse(
                message,
                from: peer,
                generation: generation,
                process: process
            )
        default:
            break
        }
    }

    private func requestTransactionInventory(
        from peer: AuthenticatedPeer,
        after: String?,
        generation: UInt64,
        process: ChainProcess,
        remainingRoots requestedRemainingRoots: Int? = nil,
        seenRoots: Set<String> = []
    ) async {
        let remainingRoots = requestedRemainingRoots
            ?? Self.maximumTransactionInventoryRootsPerSync
        guard remainingRoots > 0,
              handlers?.transaction != nil,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              !pendingTransactionInventories.values.contains(where: {
                  $0.peer.sessionID == peer.sessionID
              }) else { return }
        let request = TransactionInventoryRequestMessage(
            requestID: makeRequestID(),
            afterRootCID: after
        )
        guard let payload = try? request.encoded() else { return }
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.transactionInventoryTimedOut(
                requestID: request.requestID,
                generation: generation
            )
        }
        pendingTransactionInventories[request.requestID] = .init(
            peer: peer,
            request: request,
            remainingRoots: remainingRoots,
            seenRoots: seenRoots,
            timeout: timeout
        )
        let result = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryRequest,
            payload: payload
        )
        switch result {
        case .enqueued:
            break
        case .backpressured, .locallyRejected, .notConnected:
            pendingTransactionInventories.removeValue(
                forKey: request.requestID
            )?.timeout.cancel()
        }
    }

    private func transactionInventoryTimedOut(
        requestID: UInt64,
        generation: UInt64
    ) async {
        guard isCurrentGeneration(generation),
              let pending = pendingTransactionInventories.removeValue(
                forKey: requestID
              ) else { return }
        await overlay.recycleSession(ifCurrent: pending.peer)
    }

    private func serveTransactionInventory(
        _ request: TransactionInventoryRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let transactionInventoryProvider = handlers?.transactionInventory,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        let roots = Array(Set(await transactionInventoryProvider())).sorted()
            .filter { root in
                request.afterRootCID.map { root > $0 } ?? true
            }
        let page = Array(
            roots.prefix(TransactionInventoryResponseMessage.maximumRoots)
        )
        guard let payload = try? TransactionInventoryResponseMessage(
            requestID: request.requestID,
            afterRootCID: request.afterRootCID,
            volumeRootCIDs: page,
            hasMore: roots.count > page.count
        ).encoded() else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: payload
        )
    }

    private func scheduleTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let pending = pendingTransactionInventories[response.requestID],
              pending.peer.sessionID == peer.sessionID,
              pending.request.afterRootCID == response.afterRootCID else { return }
        pendingTransactionInventories.removeValue(
            forKey: response.requestID
        )?.timeout.cancel()
        Task { [weak self] in
            await self?.receiveTransactionInventory(
                response,
                pending: pending,
                from: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func receiveTransactionInventory(
        _ response: TransactionInventoryResponseMessage,
        pending: PendingTransactionInventory,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let transactionInventoryProvider = handlers?.transactionInventory,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        let knownRoots = Set(await transactionInventoryProvider())
        let roots = response.volumeRootCIDs.filter {
            !knownRoots.contains($0) && !pending.seenRoots.contains($0)
        }
        let selected = Array(roots.prefix(pending.remainingRoots))
        for rootCID in selected {
            guard let work = reserveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process
            ) else { continue }
            await receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                transactionHandler: work.handler,
                lease: work.lease
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
        }
        // Every page costs at least one unit of the session budget, so a
        // peer serving roots we already know cannot page for free — while an
        // all-known page still continues the scan, because honest mempools
        // overlap and later pages may hold roots we lack. The wire contract
        // (strictly ascending, unique, full page when hasMore) already
        // prevents replaying the same roots within a session.
        let remainingRoots = pending.remainingRoots - max(selected.count, 1)
        if response.hasMore,
           remainingRoots > 0,
           let cursor = response.volumeRootCIDs.last {
            await requestTransactionInventory(
                from: peer,
                after: cursor,
                generation: generation,
                process: process,
                remainingRoots: remainingRoots,
                seenRoots: pending.seenRoots.union(response.volumeRootCIDs)
            )
        }
    }

    private func scheduleTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard let work = reserveTransactionVolume(
            rootCID,
            from: peer,
            generation: generation,
            process: process
        ) else { return }
        Task { [weak self] in
            await self?.receiveTransactionVolume(
                rootCID,
                from: peer,
                generation: generation,
                process: process,
                transactionHandler: work.handler,
                lease: work.lease
            )
        }
    }

    private func reserveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> (handler: NetworkTransactionHandler, lease: TransactionVolumeLease)? {
        guard let transactionHandler = handlers?.transaction,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return nil }
        let lease = TransactionVolumeLease(
            sessionID: peer.sessionID,
            rootCID: rootCID
        )
        guard !activeTransactionVolumes.contains(lease),
              activeTransactionVolumes.count
                  < Self.maximumConcurrentTransactionVolumes,
              activeTransactionVolumes.insert(lease).inserted else { return nil }
        return (transactionHandler, lease)
    }

    private func receiveTransactionVolume(
        _ rootCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess,
        transactionHandler: @escaping NetworkTransactionHandler,
        lease: TransactionVolumeLease
    ) async {
        defer { activeTransactionVolumes.remove(lease) }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        if let transactionInventoryProvider = handlers?.transactionInventory,
           await transactionInventoryProvider().contains(rootCID) {
            return
        }

        let response: AttributedVolumeResponse
        while true {
            let fetched = await overlay.fetchVolume(rootCID: rootCID, from: peer)
            guard fetched.failure == .localCapacityUnavailable else {
                response = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return
            }
        }
        let volume = SerializedVolume(
            root: response.rootCID,
            entries: response.entries
        )
        guard response.servedBy == peer.id,
              response.rootCID == rootCID else {
            await overlay.recycleSession(ifCurrent: peer)
            return
        }
        guard (try? volume.validate()) != nil,
              let resolved = try? await VolumeImpl<Transaction>(
                rawCID: rootCID,
                node: nil,
                encryptionInfo: nil
            ).resolveRecursive(source: InMemoryContentSource(volume.entries)),
              resolved.rawCID == rootCID,
              let transaction = resolved.node else {
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer.id
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        do {
            guard try await transactionHandler(transaction) else { return }
        } catch {
            return
        }
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        guard let payload = try? TransactionAvailableMessage(
            volumeRootCID: rootCID
        ).encoded() else { return }
        for candidate in overlayPeers.values
        where candidate.sessionID != peer.sessionID {
            _ = await overlay.sendMessage(
                to: candidate,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: payload
            )
        }
    }

    private func announcePortableAttachmentAvailability(
        edgeCID: String,
        rootCID: String,
        attachmentCID: String,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let payload = try? PortableAttachmentAvailableMessage(
            edgeCID: edgeCID,
            rootCID: rootCID,
            attachmentCID: attachmentCID
        ).encoded() else { return }
        for peer in overlayPeers.values {
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            _ = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.portableAttachmentAvailable,
                payload: payload
            )
        }
    }

    /// Legacy-served: this node no longer walks a peer's evidence index (a
    /// never-validated carrier's proof is solicited per block through the
    /// locate path instead), but keeps answering so an older child still
    /// recovers from it. Scheduled for deletion with the accepted-leaves
    /// server the release after the fleet upgrades past this one.
    private func servePortableAttachmentIndex(
        _ request: PortableAttachmentIndexRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus else { return }
        let after = request.after.map {
            ChildRootAttachmentSummary(
                edgeCID: $0.edgeCID,
                rootCID: $0.rootCID,
                attachmentCID: $0.attachmentCID
            )
        }
        guard let entries = try? await process.childRootAttachmentSummaries(
            scope: .incomingCarrier,
            directory: configuration.address.directory,
            after: after,
            limit: PortableAttachmentIndexResponseMessage.maximumEntries + 1
        ), isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let page = entries.prefix(
            PortableAttachmentIndexResponseMessage.maximumEntries
        ).map {
            PortableAttachmentSummary(
                edgeCID: $0.edgeCID,
                rootCID: $0.rootCID,
                attachmentCID: $0.attachmentCID
            )
        }
        guard let payload = try? PortableAttachmentIndexResponseMessage(
            requestID: request.requestID,
            after: request.after,
            entries: Array(page),
            hasMore: entries.count > page.count
        ).encoded() else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.portableAttachmentIndexResponse,
            payload: payload
        )
    }

    /// Answer a per-block evidence request: if this process holds the recovered
    /// incoming-carrier package for the asked child block, tell the requester the
    /// attachment is available (the same message the live announce path emits), so
    /// it recovers the package through the ordinary portable-evidence path. A peer
    /// that cannot recover the block stays silent.
    private func servePortableAttachmentLocate(
        _ request: PortableAttachmentLocateRequestMessage,
        to peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus else { return }
        guard let package = try? await process
                .recoveredAuthenticatedChildPackage(for: request.childCID),
              let edge = await DirectChildEdge.derive(from: package.package.proof),
              let edgeCID = edge.edgeCID,
              let attachmentCID = try? await process.portableEvidenceVolumeCID(
                scope: .incomingCarrier,
                edgeCID: edgeCID,
                rootCID: package.package.proof.rootCID
              )
        else {
            // A silent miss here on a block only this node can prove is a
            // chain-liveness event: no follower can ever cross that block.
            SyncTrace.log("locate-serve \(request.childCID) miss")
            return
        }
        SyncTrace.log("locate-serve \(request.childCID) hit")
        guard isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              let payload = try? PortableAttachmentAvailableMessage(
                edgeCID: edgeCID,
                rootCID: package.package.proof.rootCID,
                attachmentCID: attachmentCID
              ).encoded()
        else { return }
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.portableAttachmentAvailable,
            payload: payload
        )
    }

    /// Solicit per-block evidence from the peers that can serve the block: the
    /// candidate's advertisers and the peer that supplied its content. Used when a
    /// cold-synced block needs a child proof this node cannot recover locally
    /// (its own parent never mined the carriers), so the block's supplier conveys
    /// the portable package the live path would have carried.
    private func requestPortableAttachmentLocate(
        for childCID: String,
        candidate: Candidate,
        supplierPublicKey: String?,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard !configuration.address.isNexus else { return }
        var peers: [AuthenticatedPeer] = candidate.providers
            .compactMap(overlayPeer(for:))
        if let supplierPublicKey, let key = try? PeerKey(supplierPublicKey),
           let peer = overlayPeers[key],
           !peers.contains(where: { $0.key == key }) {
            peers.append(peer)
        }
        // Blocks reached through the predecessor walk carry no advertiser, and
        // pin-resolved content need not attribute a sole supplier. Fall back to
        // the current overlay peers so the block's holder is still asked; each
        // peer either has the package or stays silent (same reach as the live
        // announce broadcast), bounded by the exact-source cap.
        if peers.isEmpty {
            peers = Array(overlayPeers.values)
        }
        guard !peers.isEmpty,
              let payload = try? PortableAttachmentLocateRequestMessage(
                requestID: makeRequestID(),
                childCID: childCID
              ).encoded() else { return }
        for peer in peers.prefix(Self.maximumExactContentSources) {
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            let sent = await overlay.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.portableAttachmentLocateRequest,
                payload: payload
            )
            SyncTrace.log(
                "locate-request \(childCID) "
                    + "peer=\(peer.key.hex.prefix(8)) sent=\(sent)"
            )
        }
    }

    private func enqueuePortableEvidence(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) -> Bool {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            return false
        }
        let lease = EvidenceVolumeLease(
            plane: .overlay,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        guard !activeEvidenceVolumes.contains(lease),
              portableEvidenceWork[lease] == nil else { return true }
        let work = PortableEvidenceWork(
            summary: summary,
            peer: peer,
            generation: generation,
            process: process
        )
        let activePortable = activeEvidenceVolumes.lazy.filter {
            $0.plane == .overlay
        }.count
        guard portableEvidenceWork.count + parentEvidence.activeOperationCount
                + activePortable
                < Self.maximumEvidenceCandidates - 1 else {
            // Overflow drops the item, never the session: for a NATed
            // follower the announcing peer may be the ONLY session, and a
            // catch-up burst would tear down its own evidence source. The
            // dropped item is re-solicited when the waiting candidate's
            // window expires and re-enters admission.
            SyncTrace.log(
                "evidence-overflow drop \(summary.attachmentCID)"
            )
            return true
        }
        portableEvidenceWork[lease] = work
        portableEvidenceOrder.append(lease)
        startPortableEvidenceWorker()
        return true
    }

    private func startPortableEvidenceWorker() {
        guard portableEvidenceWorker == nil else { return }
        portableEvidenceWorker = Task { [weak self] in
            await self?.drainPortableEvidence()
        }
    }

    private func drainPortableEvidence() async {
        defer {
            portableEvidenceWorker = nil
            if !portableEvidenceOrder.isEmpty {
                startPortableEvidenceWorker()
            }
        }
        while !portableEvidenceOrder.isEmpty {
            let lease = portableEvidenceOrder.removeFirst()
            guard let work = portableEvidenceWork.removeValue(forKey: lease)
            else { continue }
            let handled = await recoverPortableAttachment(
                work.summary,
                from: work.peer,
                generation: work.generation,
                process: work.process
            )
            SyncTrace.log(
                "evidence-recover \(work.summary.attachmentCID) "
                    + "handled=\(handled)"
            )
            if !handled {
                await overlay.recycleSession(ifCurrent: work.peer)
            }
        }
    }

    private func recoverPortableAttachment(
        _ summary: PortableAttachmentSummary,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            return false
        }
        let lease = EvidenceVolumeLease(
            plane: .overlay,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if activeEvidenceVolumes.contains(lease) { return true }
        // Reserve one slot for the structurally-required parent endpoint (a
        // connectivity reservation, NOT validation trust — parent facts are still
        // verified and never vouch for the child transition) so overlay churn
        // cannot starve consensus-critical hierarchy evidence.
        while activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates - 1 {
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return false
            }
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
            if activeEvidenceVolumes.contains(lease) { return true }
        }
        activeEvidenceVolumes.insert(lease)
        defer { activeEvidenceVolumes.remove(lease) }
        if let evidence = try? await process.childRootAttachment(
            scope: .incomingCarrier,
            edgeCID: summary.edgeCID,
            rootCID: summary.rootCID
        ) {
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
            // A rejected enqueue is LOCAL congestion (ready pool full), not
            // peer misbehavior: the recovery succeeded, so never let callers
            // recycle the session over it. The rejection already requested
            // inventory recovery, which re-derives the item later.
            _ = enqueueCandidate(CandidateSeed(
                blockCID: evidence.edge.childCID,
                package: AuthenticatedChildPackage(
                    package: ChildValidationPackage(proof: evidence.proof)
                )
            ))
            return true
        }
        // The peer advertising an attachment is responsible for serving its
        // immutable CAS graph. Binding resolution to that exact authenticated
        // session prevents a false summary from being blamed on an honest
        // third-party content provider.
        let source = IvyRootContentSource(
            ivy: overlay,
            peer: peer,
            maximumMembers: 1,
            maximumStorageBytes: ChildEvidenceVolume.maximumFramedBytes,
            maximumArchiveBytes: ChildEvidenceVolume.maximumArchiveBytes
        )
        let resolved: (
            value: ChildEvidenceVolume?,
            attribution: IvyRootContentSource.Attribution
        )
        while true {
            let fetched = await source.withRootTracing(
                summary.attachmentCID
            ) { session in
                await Self.resolveEvidenceVolume(
                    summary.attachmentCID,
                    source: session
                )
            }
            guard fetched.attribution.localCapacityUnavailable else {
                resolved = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.overlay.requestTimeout
                    )
                )
            } catch {
                return true
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                return true
            }
        }
        guard let attachment = resolved.value,
              let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes,
                maximumEncodedSize:
                    configuration.resourcePolicy.maximumParentWitnessBytes
              ),
              let package = try? envelope.makeValidationPackage(),
              package.proof.rootCID == summary.rootCID,
              let edge = await DirectChildEdge.derive(from: package.proof),
              edge.edgeCID == summary.edgeCID,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[peer.key]?.sessionID == peer.sessionID else {
            if resolved.attribution.allResponsesComplete,
               let supplier = resolved.attribution.soleRemoteSupplierPublicKey {
                await overlay.reportDeficientContent(
                    rootCID: summary.attachmentCID,
                    servedBy: PeerID(publicKey: supplier)
                )
            }
            return false
        }
        let gated = AuthenticatedChildPackage(package: package)
        // See above: a rejected enqueue after a VERIFIED recovery is local
        // congestion; only verification failures return false (and recycle).
        _ = enqueueCandidate(CandidateSeed(
            blockCID: edge.childCID,
            package: gated
        ))
        return true
    }

    private nonisolated static func resolveEvidenceVolume(
        _ cid: String,
        childCID: String? = nil,
        source: IvyRootContentSource.Session
    ) async -> ChildEvidenceVolume? {
        guard let serialized = await source.volume(rootCID: cid) else {
            return nil
        }
        return try? ChildEvidenceVolume(
            serialized: serialized,
            childCID: childCID
        )
    }

    private func scheduleParentEvidencePage(
        _ response: ChildEvidenceIndexResponseMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        let tail: Task<ParentEvidenceResult, Never>?
        if response.entries.isEmpty {
            tail = nil
        } else {
            switch appendParentEvidence(
                response.entries,
                sourceID: response.sourceID,
                advanceScan: true,
                from: peer,
                generation: generation,
                process: process
            ) {
            case .scheduled(let appended):
                tail = appended
            case .backpressured:
                // The evidence lane is momentarily full. Keep the session and
                // retry THIS page after a beat — the scan must make progress
                // through congestion, not restart from a fresh reconnect.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(
                        self?.planeConfigurations.hierarchy.requestTimeout
                            ?? .seconds(15)
                    ))
                    await self?.requestEvidenceIndex(
                        sourceID: response.sourceID,
                        cursor: response.cursor,
                        through: response.through,
                        generation: generation,
                        process: process
                    )
                }
                return
            case .rejected:
                Task { [hierarchy] in
                    await hierarchy.recycleSession(ifCurrent: peer)
                }
                return
            }
        }
        Task { [weak self] in
            guard let self else { return }
            guard (await tail?.value ?? .handled) == .handled else { return }
            // The scan cursor advances only through evidence this child has
            // durably retained (the per-item advanceScan path). The parent's
            // asserted `through` is never persisted directly: a lying parent
            // must not move the high-water mark past ordinals it never served.
            if response.next < response.through {
                await self.requestEvidenceIndex(
                    sourceID: response.sourceID,
                    cursor: response.next,
                    through: response.through,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func recoverParentEvidence(
        _ summary: IssuedChildEvidenceSummary,
        sourceID: String,
        advanceScan: Bool,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> ParentEvidenceResult {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else {
            return .failed
        }
        let lease = EvidenceVolumeLease(
            plane: .hierarchy,
            sessionID: peer.sessionID,
            attachmentCID: summary.attachmentCID
        )
        if activeEvidenceVolumes.contains(lease) { return .handled }
        while activeEvidenceVolumes.count >= Self.maximumEvidenceCandidates {
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.hierarchy.requestTimeout
                    )
                )
            } catch {
                return .handled
            }
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ), hierarchySessions[peer.key]?.sessionID == peer.sessionID,
               hierarchyPeers[peer.key] == .parent else {
                return .failed
            }
            if activeEvidenceVolumes.contains(lease) { return .handled }
        }
        activeEvidenceVolumes.insert(lease)
        defer { activeEvidenceVolumes.remove(lease) }
        let source = IvyRootContentSource(
            ivy: hierarchy,
            peer: peer,
            maximumMembers: 1,
            maximumStorageBytes: ChildEvidenceVolume.maximumFramedBytes,
            maximumArchiveBytes: ChildEvidenceVolume.maximumArchiveBytes
        )
        let resolved: (
            value: ChildEvidenceVolume?,
            attribution: IvyRootContentSource.Attribution
        )
        while true {
            let fetched = await source.withRootTracing(
                summary.attachmentCID,
                operation: { session in
                    await Self.resolveEvidenceVolume(
                        summary.attachmentCID,
                        childCID: summary.childCID,
                        source: session
                    )
                }
            )
            guard fetched.attribution.localCapacityUnavailable else {
                resolved = fetched
                break
            }
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        planeConfigurations.hierarchy.requestTimeout
                    )
                )
            } catch {
                return .failed
            }
            guard isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID,
                  hierarchyPeers[peer.key] == .parent else {
                return .failed
            }
        }
        guard let attachment = resolved.value else {
            // Mirror the overlay gate: only a complete response that still
            // failed to resolve is malformed and worth recycling. A parent
            // momentarily unable to serve an advertised attachment is
            // retried on the next scan, without blame.
            return resolved.attribution.allResponsesComplete
                ? .failed
                : .unavailable
        }
        guard let envelope = try? ChildValidationPackageEnvelope.decode(
            attachment.envelopeBytes,
            maximumEncodedSize:
                configuration.resourcePolicy.maximumParentWitnessBytes
        ) else {
            return .failed
        }
        guard let package = try? envelope.makeValidationPackage() else {
            return .failed
        }
        let gated = AuthenticatedChildPackage(package: package)
        guard gated.package.proof.rootCID == summary.rootCID,
              let directHop = await gated.package.proof.directHop(),
              directHop.childCID == summary.childCID else {
            return .failed
        }
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent else {
            return .failed
        }
        do {
            try await process.retainParentEvidence(
                sourceID: sourceID,
                ordinal: summary.ordinal,
                attachment: attachment,
                package: gated,
                advanceScan: advanceScan
            )
        } catch NodeStoreError.parentEvidenceInboxFull {
            return .backpressured
        } catch {
            return .failed
        }
        return await enqueueRetainedParentCandidate(
            CandidateSeed(blockCID: summary.childCID, package: gated),
            generation: generation,
            process: process
        ) ? .handled : .failed
    }

    private func handleHierarchy(
        _ message: PeerMessage,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        if message.topic == NodeNetworkTopic.hierarchyHello {
            await handleHierarchyHello(
                message.payload,
                peer: peer,
                generation: generation,
                process: process
            )
            return
        }
        guard hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              let role = hierarchyPeers[peer.key] else { return }

        switch (message.topic, role) {
        case (NodeNetworkTopic.parentChainFactRequest,
              .child(let childPath)):
            guard let request = try?
                    ParentChainFactMessage.decoded(message.payload),
                  parentStateQueryGuard.acquire(peer.key)
            else { return }
            defer {
                parentStateQueryGuard.release(peer.key)
            }
            let found: Bool
            switch request.fact {
            case .genesis(let childGenesisCID, let parentStateCID):
                guard let directory = childPath.last else { return }
                found = (try? await process.issuedParentGenesisLink(
                    directory: directory,
                    childGenesisCID: childGenesisCID,
                    parentStateCID: parentStateCID
                )) != nil
            case .continuity(let fromStateCID, let toStateCID):
                found = await process.hasParentStateContinuity(
                    from: fromStateCID,
                    to: toStateCID
                )
            }
            guard found else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.parentChainFactResponse,
                payload: message.payload
            )

        case (NodeNetworkTopic.parentChainFactResponse, .parent):
            guard let response = try?
                    ParentChainFactMessage.decoded(
                        message.payload
                    ) else { return }
            if let verification = pendingGenesisVerifications[
                response.requestID
            ], verification.peer.key == peer.key,
               verification.peer.sessionID == peer.sessionID,
               response == verification.request {
                resolveGenesisVerification(
                    response.requestID,
                    confirmed: true
                )
                return
            }
            guard let pending = pendingParentChainFacts[
                    response.requestID
                  ],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID,
                  response == pending.request else {
                return
            }
            pendingParentChainFacts.removeValue(
                forKey: response.requestID
            )
            await acceptParentChainFact(
                pending: pending,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childGenesisAnchorRequest,
              .child(let childPath)):
            guard let request = try?
                    ChildGenesisAnchorRequestMessage.decoded(message.payload),
                  let directory = childPath.last,
                  parentStateQueryGuard.acquire(peer.key)
            else { return }
            defer {
                parentStateQueryGuard.release(peer.key)
            }
            // Read the CID the parent committed for this child's directory from
            // its own genesisState. Silence (not an error) when unanchored, so
            // an adopting child that raced ahead of the parent's anchor just
            // retries once the record lands.
            guard let genesisCID = await process
                    .anchoredChildGenesisCIDs(directories: [directory])[directory],
                  let payload = try? ChildGenesisAnchorResponseMessage(
                      requestID: request.requestID,
                      genesisCID: genesisCID
                  ).encoded() else { return }
            _ = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childGenesisAnchorResponse,
                payload: payload
            )

        case (NodeNetworkTopic.childGenesisAnchorResponse, .parent):
            guard let response = try?
                    ChildGenesisAnchorResponseMessage.decoded(message.payload),
                  let pending = pendingGenesisResolves[response.requestID],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID else {
                return
            }
            resolveGenesisAnchor(
                response.requestID, genesisCID: response.genesisCID
            )

        case (NodeNetworkTopic.childEvidenceAvailable, .parent):
            guard
                let available = try? ChildEvidenceAvailableMessage.decoded(
                message.payload
                ), available.childPath == configuration.chainPath
            else { return }
            let handled = appendParentEvidence(
                [IssuedChildEvidenceSummary(
                    ordinal: available.ordinal,
                    childCID: available.childCID,
                    rootCID: available.rootCID,
                    attachmentCID: available.attachmentCID
                )],
                sourceID: available.sourceID,
                advanceScan: false,
                from: peer,
                generation: generation,
                process: process
            )
            // A backpressured announcement is simply dropped: the parent's
            // durable index re-serves it on the next scan. Only a rejected
            // session (stale/unknown) is recycle-worthy.
            if case .rejected = handled {
                await hierarchy.recycleSession(ifCurrent: peer)
            }

        case (NodeNetworkTopic.childEvidenceIndexRequest, .child(let childPath)):
            guard let directory = childPath.last,
                  let request = try? ChildEvidenceIndexRequestMessage.decoded(
                    message.payload
                ), request.childPath == childPath
            else { return }
            guard let head = try? await process.issuedChildEvidenceScanHead(
                    directory: directory
                  )
            else { return }
            let sameSource = request.sourceID == head.sourceID
            let cursor = sameSource ? request.cursor : 0
            let through = sameSource
                ? (request.through ?? head.throughOrdinal)
                : head.throughOrdinal
            guard through <= head.throughOrdinal,
                  let summaries = try? await process.issuedChildEvidenceSummaries(
                    directory: directory,
                    afterOrdinal: cursor,
                    throughOrdinal: through,
                    limit: ChildEvidenceIndexResponseMessage.maximumEntries + 1
                  ), isCurrentRuntime(
                    generation: generation,
                    process: process
                  )
            else {
                return
            }
            let page = Array(
                summaries.prefix(
                ChildEvidenceIndexResponseMessage.maximumEntries
            ))
            guard
                let payload = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: childPath,
                sourceID: head.sourceID,
                cursor: cursor,
                through: through,
                entries: page,
                next: summaries.count > page.count
                    ? (page.last?.ordinal ?? cursor)
                    : through
                ).encoded()
            else { return }
            let result = await hierarchy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: payload
            )
            guard case .enqueued = result else { return }
            if summaries.count <= page.count {
                completeChildEvidenceIndex(for: peer)
            }
        case (NodeNetworkTopic.childEvidenceIndexResponse, .parent):
            guard
                let response = try? ChildEvidenceIndexResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingEvidenceIndexes[response.requestID],
                  pending.peer.sessionID == peer.sessionID,
                  response.childPath == pending.request.childPath,
                  (response.sourceID == pending.request.sourceID
                    ? response.cursor == pending.request.cursor
                        && pending.request.through.map({
                            response.through == $0
                        }) ?? true
                    : response.cursor == 0)
            else { return }
            pendingEvidenceIndexes.removeValue(forKey: response.requestID)
            scheduleParentEvidencePage(
                response,
                from: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childCandidateRequest, .parent):
            guard
                let request = try? ChildCandidateRequestMessage.decoded(
                    message.payload
                  ), request.childPath == configuration.chainPath,
                  let parent = _contentBoundBlock(
                    cid: request.parentCID,
                    data: request.parentData
                )
            else { return }
            startChildCandidateBuild(
                request,
                parent: parent,
                peer: peer,
                generation: generation,
                process: process
            )

        case (NodeNetworkTopic.childCandidateResponse, .child(let childPath)):
            guard
                let response = try? ChildCandidateResponseMessage.decoded(
                    message.payload
                  ), let pending = pendingChildCandidates[response.requestID],
                  pending.peerKey == peer.key,
                  pending.childPath == childPath,
                  response.childPath == childPath,
                  pending.parentCID == response.parentCID,
                  let directory = childPath.last,
                  let block = _contentBoundBlock(
                    cid: response.childCID,
                    data: response.blockData
                )
            else { return }
            let candidate = DirectChildCandidate(
                directory: directory,
                block: block,
                searchWitness: response.searchWitness,
                advertiserPeerKey: peer.key
            )
            guard await schedulingTargets(for: candidate) != nil else {
                return
            }
            pendingChildCandidates.removeValue(forKey: response.requestID)
            pending.continuation.resume(returning: candidate)

        case (NodeNetworkTopic.childCandidateReservationRequest, .parent):
            guard let request = try?
                    ChildCandidateReservationRequestMessage.decoded(
                        message.payload
                    ),
                  request.childPath == configuration.chainPath else { return }
            guard let session = parentEvidenceSession(for: peer),
                  let reservation = parentEvidence.beginReservation(
                    for: session
                  )
            else {
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            Task { [weak self] in
                await self?.respondToCandidateReservation(
                    request,
                    from: peer,
                    session: session,
                    after: reservation.evidenceTail,
                    generation: generation,
                    process: process
                )
            }

        case (NodeNetworkTopic.childCandidateReservationResponse,
              .child(let childPath)):
            guard let response = try?
                    ChildCandidateReservationResponseMessage.decoded(
                        message.payload
                    ),
                  let pending = pendingCandidateReservations[
                    response.requestID
                  ],
                  pending.peer.key == peer.key,
                  pending.peer.sessionID == peer.sessionID,
                  pending.childPath == childPath,
                  response.childPath == childPath else { return }
            finishCandidateReservation(
                response.requestID,
                accepted: response.accepted,
                generation: generation
            )

        default:
            break
        }
    }

    private func handleHierarchyHello(
        _ payload: Data,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard expectsHierarchyHello(from: peer) else { return }
        guard peer.role == .endpoint, peer.route == .direct,
            let remote = try? ChainHello.decode(payload)
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        guard
            let role = Self.hierarchyRole(
            for: remote,
            peerKey: peer.key.hex,
            configuration: configuration
        )
        else {
            await hierarchy.disconnectSession(ifCurrent: peer)
            return
        }

        guard isCurrentRuntime(generation: generation, process: process),
              expectsHierarchyHello(from: peer) else {
            return
        }
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        if let existing = hierarchyPeers[peer.key] {
            if existing != role {
                await hierarchy.disconnectSession(ifCurrent: peer)
                return
            }
        }
        if hierarchySessions[peer.key]?.sessionID != peer.sessionID {
            childEvidenceReadyPeers.remove(peer.key)
            cancelChildEvidenceReadyWaiters(for: peer.key)
        }
        hierarchyPeers[peer.key] = role
        hierarchySessions[peer.key] = peer
        if case .child = role {
            dirtyCandidateReservationPeers.insert(peer.key)
            // Tolerant ingest of the child's self-declared read URL: invalid
            // or absent just isn't carried (never a session cost).
            if let url = normalizedPublicReadURL(remote.publicReadURL) {
                childDeclaredReadURLs[peer.key] = url
            } else {
                childDeclaredReadURLs.removeValue(forKey: peer.key)
            }
        }
        scheduleHierarchyHelloFollowup(
            role: role,
            peer: peer,
            generation: generation,
            process: process
        )
    }

    private func scheduleHierarchyHelloFollowup(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        Task { [weak self] in
            await self?.finishHierarchyHello(
                role: role,
                peer: peer,
                generation: generation,
                process: process
            )
        }
    }

    private func finishHierarchyHello(
        role: HierarchyPeer,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
            return
        }
        if case .parent = role {
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        } else if case .child(let childPath) = role {
            guard await waitForChildEvidenceReady(peer: peer) else {
                _ = clearHierarchyAuthorization(for: peer.key)
                await hierarchy.recycleSession(ifCurrent: peer)
                return
            }
            await acquireCandidateReservationReconciliation()
            defer { releaseCandidateReservationReconciliation() }
            if let removal = candidateReservationRemovalFlushes[peer.key] {
                await removal.task.value
            }
            guard
                  isCurrentRuntime(generation: generation, process: process),
                  hierarchySessions[peer.key]?.sessionID == peer.sessionID else {
                return
            }
            let accepted = await requestCandidateReservation(
                candidateCIDs: (desiredCandidateReservations[peer.key] ?? [])
                    .sorted(),
                childPath: childPath,
                peer: peer,
                generation: generation,
                process: process
            )
            if accepted {
                dirtyCandidateReservationPeers.remove(peer.key)
            } else {
                dirtyCandidateReservationPeers.insert(peer.key)
            }
            scheduleChildProofRecovery(
                generation: generation,
                process: process
            )
        }
    }

    private func scheduleChildProofRecovery(
        generation: UInt64,
        process: ChainProcess
    ) {
        if childProofRecoveryTask != nil {
            if childProofRecoveryGeneration == generation {
                childProofRecoveryNeedsRefresh = true
            }
            return
        }
        childProofRecoveryGeneration = generation
        childProofRecoveryNeedsRefresh = false
        childProofRecoveryTask = Task { [weak self] in
            await self?.recoverChildProofs(
                generation: generation,
                process: process
            )
        }
    }

    private func schedulePeerSearch(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard configuration.peerSearchInterval > 0,
              peerSearchTask == nil else { return }
        let search = makePeerSearch(process: process)
        peerSearchTask = Task { [weak self] in
            await self?.peerSearchLoop(search, generation: generation)
        }
    }

    /// Observe our own tip on a fixed cadence and let the search decide. The
    /// first observation only records where the tip stands, so a node that has
    /// just started is never treated as idle.
    private func peerSearchLoop(
        _ search: StaleTipPeerSearch,
        generation: UInt64
    ) async {
        let delay = Self.peerSearchPollSeconds(
            configuration.peerSearchInterval
        ) &* 1_000_000_000
        while isRunning, runtimeGeneration == generation {
            await search.tick()
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
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
            acquiredHeight: { await process.canonicalTipHeight() },
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
            return overlayPeers[key] == nil
        }
    }

    /// One provider lookup for this chain's own genesis — the rendezvous every
    /// node of the chain already announces itself into — minus ourselves and
    /// the peers we already hold. A lying provider record costs one failed dial
    /// and nothing else.
    private func discoveredPeersWithoutSession(
        process: ChainProcess
    ) async -> [PeerEndpoint] {
        guard let genesis = await process.mainChainBlockCID(atHeight: 0) else {
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

    private func scheduleGenesisProviderAnnounce(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard genesisAnnounceTask == nil else { return }
        genesisAnnounceTask = Task { [weak self] in
            await self?.announceGenesisProviderLoop(
                generation: generation,
                process: process
            )
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
        while isRunning, runtimeGeneration == generation {
            await announceGenesisProviders(
                expiresAt: UInt64(Date().timeIntervalSince1970) + ttl,
                process: process
            )
            do {
                try await Task.sleep(nanoseconds: interval &* 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private func announceGenesisProviders(
        expiresAt: UInt64,
        process: ChainProcess
    ) async {
        // (1) This node's own chain genesis, on its own overlay — peers of
        // this chain can find providers of it.
        if let ownGenesis = await process.mainChainBlockCID(atHeight: 0) {
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

    /// Directories of the immediate children currently wired to this node.
    private func wiredChildDirectories() -> Set<String> {
        Set(hierarchyPeers.values.compactMap { role -> String? in
            guard case .child(let path) = role else { return nil }
            return path.last
        })
    }

    #if DEBUG
    /// Test seam: one pass of the genesis-provider announce loop, which
    /// otherwise repeats only once a minute.
    func announceGenesisProvidersForTesting(process: ChainProcess) async {
        await announceGenesisProviders(
            expiresAt: UInt64(Date().timeIntervalSince1970) + 600,
            process: process
        )
    }
    #endif

    private func recoverChildProofs(
        generation: UInt64,
        process: ChainProcess
    ) async {
        // Late-child backfill: a child that connected AFTER its carriers were
        // admitted — or whose carriers were recovered durably on restart rather
        // than re-admitted — has no pending proof route for those historical
        // carriers, so the retry loop below would have nothing to issue. A node
        // that MINED a carrier issues for every child eagerly; this restores the
        // same for a node that SYNCED it. Seed routes across the recent
        // accepted-carrier window for every connected direct child (the whole
        // set, not the rotated serving subset); the retry loop then generates
        // and announces them from local or peer content. Carriers older than the
        // window rely on the verified any-peer proof fallback — a bounded
        // window, not silent completeness.
        let connectedChildDirectories = Set(
            hierarchyPeers.values.compactMap { role -> String? in
                guard case .child(let path) = role else { return nil }
                return path.last
            }
        ).sorted()
        for directory in connectedChildDirectories
        where !backfilledChildDirectories.contains(directory) {
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await process.backfillChildProofRoutes(directory: directory)
            // Mark only after completion, so an interrupted backfill retries on
            // the next recovery pass rather than being skipped as done.
            backfilledChildDirectories.insert(directory)
        }
        repeat {
            childProofRecoveryNeedsRefresh = false
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryRecoveredChildProofs(
                generation: generation,
                process: process
            )
            guard !Task.isCancelled,
                  isCurrentRuntime(generation: generation, process: process) else {
                break
            }
            await retryCurrentTipChildProofs(
                generation: generation,
                process: process
            )
        } while childProofRecoveryNeedsRefresh

        guard childProofRecoveryGeneration == generation,
              self.process === process else { return }
        childProofRecoveryTask = nil
        childProofRecoveryGeneration = nil
        childProofRecoveryNeedsRefresh = false
    }

    private func scheduleHierarchyHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        nextHelloDeadlineToken &+= 1
        let token = nextHelloDeadlineToken
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.hierarchyHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        hierarchyHelloDeadlines[peer.key] = HelloDeadline(
            token: token,
            sessionID: peer.sessionID,
            task: task
        )
    }

    private func scheduleOverlayHelloDeadline(
        for peer: AuthenticatedPeer,
        generation: UInt64
    ) {
        overlayHelloDeadlines.removeValue(forKey: peer.key)?.task.cancel()
        nextHelloDeadlineToken &+= 1
        let token = nextHelloDeadlineToken
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.overlayHelloTimedOut(
                peer: peer,
                generation: generation,
                token: token
            )
        }
        overlayHelloDeadlines[peer.key] = HelloDeadline(
            token: token,
            sessionID: peer.sessionID,
            task: task
        )
    }

    private func expectsOverlayHello(from peer: AuthenticatedPeer) -> Bool {
        overlaySessions[peer.key]?.sessionID == peer.sessionID
            && overlayHelloDeadlines[peer.key]?.sessionID == peer.sessionID
    }

    private func overlayHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: UInt64
    ) async {
        guard isCurrentGeneration(generation), isRunning,
              overlayHelloDeadlines[peer.key]?.token == token,
              overlayHelloDeadlines[peer.key]?.sessionID == peer.sessionID,
              overlayPeers[peer.key]?.sessionID != peer.sessionID else { return }
        overlayHelloDeadlines.removeValue(forKey: peer.key)
        overlaySessions.removeValue(forKey: peer.key)
        await overlay.recycleSession(ifCurrent: peer)
    }

    private func expectsHierarchyHello(from peer: AuthenticatedPeer) -> Bool {
        Self.hierarchyHelloMatches(
            sessionID: peer.sessionID,
            deadlineSessionID: hierarchyHelloDeadlines[peer.key]?.sessionID
        )
    }

    static func hierarchyHelloMatches(
        sessionID: Data,
        deadlineSessionID: Data?
    ) -> Bool {
        deadlineSessionID == sessionID
    }

    private func hierarchyHelloTimedOut(
        peer: AuthenticatedPeer,
        generation: UInt64,
        token: UInt64
    ) async {
        guard isCurrentGeneration(generation),
            isRunning,
            hierarchyHelloDeadlines[peer.key]?.token == token,
            hierarchyHelloDeadlines[peer.key]?.sessionID == peer.sessionID,
            hierarchyPeers[peer.key] == nil
        else { return }
        hierarchyHelloDeadlines.removeValue(forKey: peer.key)
        await hierarchy.recycleSession(ifCurrent: peer)
    }


    @discardableResult
    private func enqueueCandidate(_ seed: CandidateSeed) -> Bool {
        guard isRunning else { return false }
        let result = candidateAcquirer.observe(seed)
        serviceCandidateAcquirer()
        return result.accepted
    }

    @discardableResult
    private func requeueCandidate(_ seed: CandidateSeed) -> Bool {
        guard isRunning else { return false }
        let accepted = candidateAcquirer.requeue(seed)
        serviceCandidateAcquirer()
        return accepted
    }

    private func candidateProvider(
        _ peer: AuthenticatedPeer
    ) -> CandidateProvider {
        CandidateProvider(
            publicKey: peer.id.publicKey,
            sessionID: peer.sessionID
        )
    }

    private func overlayPeer(
        for provider: CandidateProvider
    ) -> AuthenticatedPeer? {
        guard let key = try? PeerKey(provider.publicKey),
              let peer = overlayPeers[key],
              peer.sessionID == provider.sessionID else { return nil }
        return peer
    }

    private func serviceCandidateAcquirer() {
        if candidateAcquirer.hasTimedWait {
            scheduleWaitingCandidateRetry()
        }
        if candidateAcquirer.hasReadyCandidate {
            startCandidateWorker()
        }
    }

    private func startCandidateWorker() {
        guard candidateWorker == nil else { return }
        let generation = runtimeGeneration
        candidateWorkerGeneration = generation
        candidateWorker = Task { [weak self] in
            await self?.drainCandidateAdmissions(generation: generation)
        }
    }

    private func drainCandidateAdmissions(generation: UInt64) async {
        defer { finishCandidateWorker(generation: generation) }
        while isRunning, runtimeGeneration == generation,
              let candidate = candidateAcquirer.next() {
            guard let process,
                  isCurrentRuntime(
                    generation: generation,
                    process: process
                  ) else { return }
            await admitCandidate(
                candidate,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(
                generation: generation,
                process: process
            ) else { return }
            serviceCandidateAcquirer()
            await advanceRangeSync(generation: generation, process: process)
        }
    }

    private func finishCandidateWorker(generation: UInt64) {
        guard candidateWorkerGeneration == generation else { return }
        candidateWorker = nil
        candidateWorkerGeneration = nil
        if isRunning, candidateAcquirer.hasReadyCandidate {
            startCandidateWorker()
        }
    }

    private func completeCandidate(
        _ candidate: Candidate,
        resolution: CandidateAcquirer.Resolution,
        deficientProviders: Set<CandidateProvider> = []
    ) {
        SyncTrace.log(
            "complete \(candidate.blockCID) \(resolution) "
                + "deficient=\(deficientProviders.count)"
        )
        _ = candidateAcquirer.complete(
            candidate.ticket,
            resolution: resolution,
            deficientProviders: deficientProviders
        )
        serviceCandidateAcquirer()
    }

    private func admitCandidate(
        _ candidate: Candidate,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard let admissionHandler = handlers?.admission else { return }
        let authenticatedPackage: AuthenticatedChildPackage?
        if let package = candidate.package {
            authenticatedPackage = package
        } else if let rootCID = candidate.recoveryRootCID {
            guard let recovered = try? await process
                .recoveredAuthenticatedChildPackage(
                    for: candidate.blockCID,
                    rootCID: rootCID
                ) else {
                completeCandidate(candidate, resolution: .wait(.evidence))
                return
            }
            authenticatedPackage = recovered
        } else {
            authenticatedPackage = nil
        }
        var failedOverlayProviders = Set<CandidateProvider>()
        let childDirectories = authenticatedChildDirectories()
        var attempt: (
            value: NodeAdmissionOutcome,
            attribution: IvyRootContentSource.Attribution
        )?
        let header = BlockHeader(
                        rawCID: candidate.blockCID,
                        node: nil,
                        encryptionInfo: nil
        )
        var exactSources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )]
        // Order the direct advertisers by a per-process-seeded hash of
        // (publicKey, blockCID) — NOT raw publicKey — so an attacker cannot grind
        // Sybil keys to sort ahead of the genuine supplier for a given block, and
        // CAP the fan-out so an announcement flood cannot force O(N) sequential
        // timeouts before the recovery source (below) is reached. The recovery
        // source's full pin cascade still reaches the genuine supplier if every
        // capped slot is a Sybil, so the worst case is bounded, not unbounded.
        let overlaySources: [(
            peer: AuthenticatedPeer?,
            source: IvyRootContentSource,
            plane: CandidateSourcePlane?
        )] = Self.boundedOrderedExactPeers(
            candidate.providers.compactMap(overlayPeer(for:)),
            blockCID: candidate.blockCID
        ).map {
            (
                peer: $0,
                source: candidateContentSource(
                    preferred: overlay,
                    peer: $0
                ),
                plane: .overlay
            )
        }
        exactSources = []
        if authenticatedPackage != nil,
           let parent = configuredParentPeer() {
            exactSources.append((
                parent,
                candidateContentSource(
                    preferred: hierarchy,
                    peer: parent
                ),
                .hierarchy
            ))
        }
        exactSources.append(contentsOf: overlaySources)
        // A verified CID remains discoverable even when its first advertiser
        // fails. Ivy resolves public pins to an exact authenticated supplier.
        exactSources.append((nil, remoteContentSource, .overlay))
        for exact in exactSources {
            let initialResponse: AttributedVolumeResponse?
            if let peer = exact.peer, let plane = exact.plane {
                let response: AttributedVolumeResponse
                switch plane {
                case .overlay:
                    response = await overlay.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                case .hierarchy:
                    response = await hierarchy.fetchVolume(
                        rootCID: candidate.blockCID,
                        from: peer
                    )
                }
                if response.failure == .localCapacityUnavailable {
                    continue
                }
                if response == .empty {
                    // Empty has no attributable supplier: Ivy also uses it for
                    // transient session, timeout, and enqueue failures. Keep
                    // the exact advertiser available for a quick retry.
                    continue
                }
                let volume = SerializedVolume(
                    root: response.rootCID,
                    entries: response.entries
                )
                guard response.servedBy == peer.id,
                      response.rootCID == candidate.blockCID else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard (try? volume.validate()) != nil else {
                    if plane == .overlay {
                        failedOverlayProviders.insert(
                            candidateProvider(peer)
                        )
                    }
                    await reportDeficientVolume(
                        candidate.blockCID,
                        servedBy: peer.id,
                        on: plane
                    )
                    continue
                }
                guard isCurrentRuntime(
                    generation: generation,
                    process: process
                ) else { return }
                switch plane {
                case .overlay:
                    guard overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                        continue
                    }
                case .hierarchy:
                    guard configuredParentPeer()?.sessionID == peer.sessionID else {
                        continue
                    }
                }
                initialResponse = response
            } else {
                initialResponse = nil
            }
            let capture = IvyRootContentSource.AttributionCapture()
            do {
                let resolved = try await exact.source.withRootTracing(
                    candidate.blockCID,
                    initialResponse: initialResponse,
                    capture: capture
                ) { session in
                    try await Self.enforceLocalAdmissionPolicy(
                        candidateCID: candidate.blockCID,
                        source: session,
                        configuration: configuration
                    )
                    let admitted = try await admissionHandler(NetworkCandidateAdmission(
                        header: header,
                        authenticatedChildPackage: authenticatedPackage,
                        preparingChildDirectories: childDirectories,
                        contentSource: session,
                        weighed: candidate.weighed
                    ))
                    return admitted
                }
                await reportDeficientVolumes(resolved.attribution)
                // Admission durably records any unresolved direct-child
                // routes. The runtime's single coalesced worker owns their
                // availability retry and publishes each completed proof.
                scheduleChildProofRecovery(
                    generation: generation,
                    process: process
                )
                attempt = resolved
                break
            } catch {
                guard isCurrentRuntime(generation: generation, process: process) else {
                    return
                }
                if error is NodePolicyDecline {
                    completeCandidate(
                        candidate,
                        resolution: .terminal,
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let failure = error as? ChainAdmissionFailure {
                    let decision = NodeAdmissionDecision(failure)
                    if decision.shouldRetryWhenEvidenceChanges {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.evidence),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                    if decision.shouldRetryLater {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                if error is CancellationError {
                    completeCandidate(
                        candidate,
                        resolution: .wait(.content),
                        deficientProviders: failedOverlayProviders
                    )
                    return
                }
                if let attribution = capture.snapshot() {
                    await reportDeficientVolumes(attribution)
                    if attribution.allResponsesComplete,
                       !attribution.localCapacityUnavailable,
                       !attribution.contentUnavailable {
                        completeCandidate(
                            candidate,
                            resolution: .wait(.later),
                            deficientProviders: failedOverlayProviders
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
            }
        }
        guard let attempt else {
            completeCandidate(
                candidate,
                resolution: .wait(.content),
                deficientProviders: failedOverlayProviders
            )
            return
        }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        let outcome = attempt.value
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }

        if outcome.parentCarrierLink != nil {
            _ = await announceCurrentCarrierChildEvidence(
                directories: childDirectories,
                carrierCID: candidate.blockCID,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process) else {
                return
            }
            if let authenticated = authenticatedPackage,
               let edge = await DirectChildEdge.derive(
                    from: authenticated.package.proof
               ), let edgeCID = edge.edgeCID {
                if let portableAttachmentCID = try? await process
                        .portableEvidenceVolumeCID(
                            scope: .incomingCarrier,
                            edgeCID: edgeCID,
                            rootCID: authenticated.package.proof.rootCID
                        ) {
                    await announcePortableAttachmentAvailability(
                        edgeCID: edgeCID,
                        rootCID: authenticated.package.proof.rootCID,
                        attachmentCID: portableAttachmentCID,
                        generation: generation,
                        process: process
                    )
                }
            }
        }

        // Only the peer that supplied a COMPLETE invalid candidate can be blamed
        // for it, and only when it was the sole remote supplier: parent evidence
        // authenticates only parent facts and never vouches for the child
        // transition. "Blame" is a per-root routing suppression, never a ban.
        if outcome.decision == .invalid {
            if attempt.attribution.allResponsesComplete,
               let supplierKey = attempt.attribution.soleRemoteSupplierPublicKey,
               let supplier = try? PeerKey(supplierKey),
               overlayPeers[supplier] != nil,
               configuration.address.isNexus || outcome.parentCarrierLink != nil {
                await overlay.reportDeficientContent(
                    rootCID: candidate.blockCID,
                    servedBy: PeerID(publicKey: supplierKey)
                )
            }
        }
        if case .unavailable(let requirement?) = outcome.decision,
           let authenticatedPackage {
            let parentPath = Array(configuration.chainPath.dropLast())
            switch requirement {
            case .parentGenesis(
                let requiredPath,
                let directory,
                let childGenesisCID,
                let parentStateCID
            ) where requiredPath == parentPath
                    && directory == configuration.address.directory:
                await requestParentChainFact(
                    .genesis(
                        childGenesisCID: childGenesisCID,
                        parentStateCID: parentStateCID
                    ),
                    for: candidate.blockCID,
                    package: authenticatedPackage,
                    generation: generation,
                    process: process
                )
            case .parentStateContinuity(
                let requiredPath,
                let fromStateCID,
                let toStateCID
            ) where requiredPath == parentPath:
                await requestParentChainFact(
                    .continuity(
                        fromStateCID: fromStateCID,
                        toStateCID: toStateCID
                    ),
                    for: candidate.blockCID,
                    package: authenticatedPackage,
                    generation: generation,
                    process: process
                )
            default:
                break
            }
        }
        // A cold-synced block arrives without the portable package the live path
        // carries. When it needs a child proof this node cannot recover locally
        // (its own parent never mined the carriers), solicit the package from the
        // block's supplier so the retry admits it exactly like the live path.
        if authenticatedPackage == nil,
           case .unavailable(.childProof(_, let childCID)?) = outcome.decision {
            await requestPortableAttachmentLocate(
                for: childCID,
                candidate: candidate,
                supplierPublicKey: attempt.attribution.soleRemoteSupplierPublicKey,
                generation: generation,
                process: process
            )
        }
        let resolution: CandidateAcquirer.Resolution
        if let predecessor = outcome.sameChainPredecessor,
           await process.hasAcceptedBlock(predecessor.predecessorCID) == false {
            // Park only when the predecessor is genuinely still missing. An
            // already-accepted predecessor already fired its one-shot connect
            // signal, so parking on it now would wedge this candidate forever.
            resolution = .predecessor(predecessor.predecessorCID)
        } else if let predecessor = outcome.sameChainPredecessor,
                  let missing = await process.deepestMissingAncestor(
                      of: predecessor.predecessorCID
                  ) {
            // The immediate predecessor is accepted but itself DISCONNECTED:
            // its connect signal fired long ago, so parking on it would wedge
            // — but stopping here wedges just the same, because the segment is
            // missing a deeper ancestor. Park on the deepest genuinely-missing
            // block (the wake that actually unblocks this candidate); the park
            // also seeds its acquisition, and each arrival re-walks one level
            // until the segment connects and fork choice promotes it. This is
            // both the gap fast-forward and the fresh deep-sync descent.
            resolution = .predecessor(missing)
        } else if outcome.decision.isAccepted {
            resolution = .connected
        } else if outcome.decision == .unavailable(nil),
                  (
                    attempt.attribution.contentUnavailable
                        || attempt.attribution.localCapacityUnavailable
                  ) {
            resolution = .wait(.content)
        } else if case .unavailable(.parentGenesis?) = outcome.decision {
            resolution = .wait(.later)
        } else if case .unavailable(.parentStateContinuity?) = outcome.decision {
            resolution = .wait(.later)
        } else if outcome.decision.shouldRetryWhenEvidenceChanges {
            resolution = .wait(.evidence)
        } else if outcome.decision.shouldRetryLater {
            resolution = .wait(.later)
        } else {
            resolution = .terminal
        }
        completeCandidate(
            candidate,
            resolution: resolution,
            deficientProviders: failedOverlayProviders
        )
        if outcome.decision.isAccepted, authenticatedPackage != nil,
           (try? await process.parentEvidenceInboxHasCapacity()) == true {
            if let parent = configuredParentPeer(),
               let session = parentEvidenceSession(for: parent) {
                parentEvidence.capacityBecameAvailable(for: session)
            }
            await requestEvidenceIndex(
                generation: generation,
                process: process
            )
        }
    }

    private nonisolated static func enforceLocalAdmissionPolicy(
        candidateCID: String,
        source: any ContentSource,
        configuration: NodeConfiguration
    ) async throws {
        let rootData = await source.fetch(Set([candidateCID]))[candidateCID]
        if let rootData, let block = Block(data: rootData) {
            let specCID = block.spec.rawCID
            if let specData = await source.fetch(Set([specCID]))[specCID] {
                guard specData.count
                        <= configuration.resourcePolicy.maximumChainSpecBytes
                else {
                    throw NodePolicyDecline.chainSpecTooLarge
                }
                if let resolvedSpec = try? await block.spec.resolve(
                    source: source
                ),
                   let spec = resolvedSpec.node,
                   spec.wasmPolicies.count
                    > configuration.resourcePolicy.maximumWasmPolicies {
                    throw NodePolicyDecline.tooManyWasmPolicies
                }
            }
        }
    }

    private func reportDeficientVolume(
        _ rootCID: String,
        servedBy peer: PeerID,
        on plane: CandidateSourcePlane
    ) async {
        switch plane {
        case .overlay:
            await overlay.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        case .hierarchy:
            await hierarchy.reportDeficientContent(
                rootCID: rootCID,
                servedBy: peer
            )
        }
    }

    private func reportDeficientVolumes(
        _ attribution: IvyRootContentSource.Attribution
    ) async {
        for (rootCID, suppliers) in attribution.deficientVolumeSuppliers {
            for supplier in suppliers {
                await overlay.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: PeerID(publicKey: supplier)
                )
            }
        }
    }

    /// Per-process-seeded ordering key for a candidate's direct advertisers.
    /// Swift's Hasher is seeded per process, so a remote attacker cannot grind
    /// Sybil keys to sort ahead of the genuine supplier for a given block; the
    /// order stays deterministic within a node's lifetime. publicKey breaks ties.
    private static func exactSourceOrder(
        _ peer: AuthenticatedPeer,
        blockCID: String
    ) -> (Int, String) {
        var hasher = Hasher()
        hasher.combine(peer.id.publicKey)
        hasher.combine(blockCID)
        return (hasher.finalize(), peer.id.publicKey)
    }

    /// Direct advertisers to probe before the recovery source: de-ground order
    /// (see exactSourceOrder) capped to a small constant, so an announcement flood
    /// cannot force O(N) sequential fetch timeouts per block.
    static func boundedOrderedExactPeers(
        _ peers: [AuthenticatedPeer],
        blockCID: String
    ) -> [AuthenticatedPeer] {
        peers
            .sorted {
                exactSourceOrder($0, blockCID: blockCID)
                    < exactSourceOrder($1, blockCID: blockCID)
            }
            .prefix(maximumExactContentSources)
            .map { $0 }
    }

    private func candidateContentSource(
        preferred ivy: Ivy,
        peer: AuthenticatedPeer
    ) -> IvyRootContentSource {
        let fallback = overlay
        return IvyRootContentSource { rootCID in
            let response = await ivy.fetchVolume(
                rootCID: rootCID,
                from: peer
            )
            if response.failure == .localCapacityUnavailable {
                return response
            }
            guard response != .empty,
                  response.servedBy == peer.id else {
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            let volume = SerializedVolume(
                root: response.rootCID,
                entries: response.entries
            )
            guard response.rootCID == rootCID,
                  (try? volume.validate()) != nil else {
                await ivy.reportDeficientContent(
                    rootCID: rootCID,
                    servedBy: peer.id
                )
                return await fallback.fetchVolume(rootCID: rootCID)
            }
            return response
        }
    }


    private func scheduleWaitingCandidateRetry() {
        guard waitingCandidateRetryTask == nil,
              candidateAcquirer.hasTimedWait else { return }
        let generation = runtimeGeneration
        waitingCandidateRetryGeneration = generation
        let delay = Self.nanoseconds(Self.futureCandidateRetryInterval)
        waitingCandidateRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.retryWaitingCandidates(generation: generation)
        }
    }

    private func retryWaitingCandidates(generation: UInt64) {
        guard waitingCandidateRetryGeneration == generation else { return }
        waitingCandidateRetryTask = nil
        waitingCandidateRetryGeneration = nil
        guard isCurrentGeneration(generation), isRunning else { return }
        candidateAcquirer.retry()
        serviceCandidateAcquirer()
    }

    // MARK: - Forward-apply range sync
    //
    // Catch up to a heavier peer by paging its MAIN chain FORWARD from our own
    // frontier and applying each bounded page through the ordinary candidate
    // worker. Blocks arrive genesis-ward and admit parent-first
    // (appendCanonicalTip), so nothing is retained — the working set is a small,
    // fixed window regardless of chain depth (no depth ceiling, no gap buffer).
    // Pages are pipelined by block CID and bounded to a few ahead of our applied
    // tip. One range sync runs at a time; a peer that stops advancing our tip
    // (withheld bodies / off-chain blocks) is rotated off so an honest heavier
    // tip is not starved.

    struct RangeSyncState {
        let peer: AuthenticatedPeer
        var requestID: UInt64
        var awaiting: Bool
        var hasMore: Bool
        /// Anchor for the NEXT request — the last block we have requested, not
        /// the last we have applied — so paging pipelines ahead of application.
        var requestedAfterCID: String
        var requestedHeight: UInt64
        /// The peer's advertised height when this sync began: paging is only
        /// DONE once our applied tip reaches it. Every requested page can be
        /// enqueued while the applied tip is still far behind, so we cannot
        /// treat "no more pages to request" as "caught up".
        var targetHeight: UInt64
        var progressEpoch: UInt64
        var progressBaselineHeight: UInt64
        /// Consecutive re-drives that produced no applied progress. Reset every
        /// time the applied tip climbs; once it hits the cap the slot is released
        /// so a peer that advertises a tall tip but withholds one block cannot
        /// occupy the single sync slot indefinitely.
        var redriveAttempts: Int
        /// Whether `requestedAfterCID` was fixed by a common-ancestor response.
        /// Until it is, the anchor is only our own frontier — possibly a losing
        /// sibling off the peer's main chain — so an unanswered request must
        /// re-negotiate, never page forward from it.
        var negotiated: Bool
        var responseTimeout: Task<Void, Never>?
        var progressTimeout: Task<Void, Never>?
    }

    /// Cap on requested-but-not-yet-applied pages, so a deep sync never buffers
    /// more than this window no matter how far behind we are.
    private static let rangeSyncMaxPagesAhead: UInt64 = 2

    /// Consecutive no-progress re-drives before the sync slot is released for a
    /// different peer. Any applied progress resets the count, so this only trips
    /// on a peer that has genuinely stopped advancing our tip.
    private static let rangeSyncMaxRedrives: Int = 8

    private func startRangeSync(
        peer: AuthenticatedPeer,
        targetHeight: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
              rangeSync == nil,
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        let acquired = await process.canonicalTip()
        guard isCurrentRuntime(generation: generation, process: process),
              rangeSync == nil,
              overlayPeers[peer.key]?.sessionID == peer.sessionID else { return }
        SyncTrace.log(
            "range-sync start target=\(targetHeight) "
                + "peer=\(peer.key.hex.prefix(8))"
        )
        // The anchor is the ACQUIRED tip — one (cid, height) pair describing
        // the same block — until the common-ancestor negotiation below
        // replaces it; a validated-tip CID under an acquired height would
        // re-page every held block above it.
        rangeSync = RangeSyncState(
            peer: peer,
            requestID: 0,
            awaiting: false,
            hasMore: true,
            requestedAfterCID: acquired?.cid ?? configuration.nexusGenesisCID,
            requestedHeight: acquired?.height ?? 0,
            targetHeight: targetHeight,
            progressEpoch: 0,
            progressBaselineHeight: acquired?.height ?? 0,
            redriveAttempts: 0,
            negotiated: false,
            responseTimeout: nil,
            progressTimeout: nil
        )
        scheduleRangeSyncProgress(generation: generation, process: process)
        // Negotiate the common ancestor before streaming, so a frontier that
        // sits on a losing sibling is not told "empty = caught up" and marooned.
        await sendAncestorRangeRequest(generation: generation, process: process)
    }

    /// Request the next forward page if one is due: the common ancestor is
    /// negotiated, not already awaiting a response, the peer has more, and we
    /// are within the outstanding-window bound (requested minus applied). The
    /// `negotiated` guard matters: an admission drain can pump during the
    /// locator build inside `sendAncestorRangeRequest` (awaiting is still
    /// false there), and a forward page from the un-negotiated anchor would
    /// re-page held history and bump the requestID the negotiation reply
    /// must match.
    private func pumpRangeSync(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = rangeSync, sync.negotiated, !sync.awaiting, sync.hasMore,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[sync.peer.key]?.sessionID == sync.peer.sessionID else { return }
        let applied = await acquiredHeight(process)
        guard var current = rangeSync, current.requestID == sync.requestID,
              current.negotiated, !current.awaiting, current.hasMore,
              isCurrentRuntime(generation: generation, process: process) else { return }
        let window = Self.rangeSyncMaxPagesAhead
            * UInt64(ForwardRangeResponseMessage.maximumBlocks)
        guard current.requestedHeight < applied + window else { return }
        let requestID = makeRequestID()
        guard let payload = try? ForwardRangeRequestMessage(
            requestID: requestID,
            afterCID: current.requestedAfterCID
        ).encoded() else {
            clearRangeSync()
            return
        }
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        current.requestID = requestID
        current.awaiting = true
        current.responseTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            await self?.rangeSyncTimedOut(requestID: requestID, generation: generation)
        }
        let peer = current.peer
        rangeSync = current
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.forwardRangeRequest,
            payload: payload
        )
    }

    private func handleForwardRangeResponse(
        _ message: PeerMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = rangeSync, sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              sync.peer.sessionID == peer.sessionID,
              let response = try? ForwardRangeResponseMessage.decoded(message.payload),
              response.requestID == sync.requestID else {
            return
        }
        // Leave the response timeout ARMED through the apply loop: if we bail
        // early below it remains a live backstop that reclaims the slot. It is
        // cancelled only once we commit the advanced state.
        var lastCID: String?
        var enqueued: UInt64 = 0
        for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
            await overlay.rememberProvider(rootCID: cid, peer: peer.id)
            guard isCurrentRuntime(generation: generation, process: process),
                  rangeSync?.requestID == sync.requestID else { return }
            guard overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                // The peer we were syncing from is gone (or reconnected as a new
                // session) mid-page — release the slot so another peer can drive
                // catch-up instead of stranding it until the progress deadline.
                clearRangeSync()
                return
            }
            // Below-tip range-sync page: admit on the weighed tier so a fresh
            // node catches its header chain up to the tip without executing every
            // historical block inline. The validate-on-candidacy walk executes
            // them forward once the branch is canonical.
            _ = enqueueCandidate(CandidateSeed(
                blockCID: cid,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            ))
            lastCID = cid
            enqueued += 1
        }
        guard var current = rangeSync, current.requestID == sync.requestID else { return }
        current.responseTimeout?.cancel()
        current.awaiting = false
        current.responseTimeout = nil
        current.hasMore = response.hasMore
        // Empty page: caught up, our frontier is off this peer's main chain, or
        // every entry was non-canonical — nothing more to pull here. Demote
        // the peer's recorded claim so the re-entry probe falls through to
        // the next-tallest recorded tip instead of re-picking this peer
        // every backoff forever (a fresh announcement re-records it — a liar
        // must keep actively re-announcing to re-capture the slot).
        guard enqueued > 0, let lastCID else {
            var claimed: UInt64?
            if let claim = announcedTips[peer.key],
               claim.peer.sessionID == peer.sessionID {
                announcedTips.removeValue(forKey: peer.key)
                claimed = claim.height
            }
            clearRangeSync()
            // Demoted, so the re-entry probe will not evaluate this peer: if
            // the empty page means we caught up to its claim, this is the
            // edge moment for its one frontier pull (a liar's claim fails
            // the edge test and pulls nothing).
            if let claimed {
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: claimed,
                    generation: generation,
                    process: process
                )
            }
            return
        }
        current.requestedAfterCID = lastCID
        current.requestedHeight += enqueued
        // Reached the peer's tip: every page is REQUESTED, but the blocks still
        // have to be fetched and applied through the single-active worker. Keep
        // the sync (and its progress watchdog) alive until the applied tip
        // actually reaches the target — a single wedged content fetch mid-apply
        // would otherwise strand catch-up with no path to re-request the block.
        rangeSync = current
        serviceCandidateAcquirer()
        await pumpRangeSync(generation: generation, process: process)
    }

    /// The receiver's block locator: its own accepted main-chain CIDs,
    /// newest-first at exponentially increasing height gaps back to and
    /// including genesis. Bounded, so it spans any depth in a handful of
    /// entries. Every entry is a block THIS node accepted, so the ancestor the
    /// responder picks can never rewind us past our own verified history.
    private func buildBlockLocator(process: ChainProcess) async -> [String] {
        // Anchored at the ACQUIRED tip: the locator negotiates what we hold,
        // and a validated-tip base would re-page the weighed history above it.
        guard let tip = await process.canonicalTipHeight() else {
            return [configuration.nexusGenesisCID]
        }
        var heights: [UInt64] = []
        var step: UInt64 = 1
        var height = tip
        while heights.count < AncestorRangeRequestMessage.maximumLocatorEntries - 1 {
            heights.append(height)
            if height == 0 { break }
            height = height > step ? height - step : 0
            step = step > UInt64.max / 2 ? step : step &* 2
        }
        if heights.last != 0 { heights.append(0) }
        var locator: [String] = []
        for height in heights {
            if let cid = await process.mainChainBlockCID(atHeight: height) {
                locator.append(cid)
            }
        }
        return locator.isEmpty ? [configuration.nexusGenesisCID] : locator
    }

    /// Send the common-ancestor negotiation request that opens a range sync.
    private func sendAncestorRangeRequest(
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = rangeSync, !sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              overlayPeers[sync.peer.key]?.sessionID == sync.peer.sessionID else { return }
        let locator = await buildBlockLocator(process: process)
        guard var current = rangeSync, current.requestID == sync.requestID,
              !current.awaiting,
              isCurrentRuntime(generation: generation, process: process) else { return }
        let requestID = makeRequestID()
        guard let payload = try? AncestorRangeRequestMessage(
            requestID: requestID,
            locator: locator
        ).encoded() else {
            clearRangeSync()
            return
        }
        let timeoutNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        )
        current.requestID = requestID
        current.awaiting = true
        current.responseTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            await self?.rangeSyncTimedOut(requestID: requestID, generation: generation)
        }
        let peer = current.peer
        rangeSync = current
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.ancestorRangeRequest,
            payload: payload
        )
    }

    /// Handle the negotiated common-ancestor response — the three outcomes.
    private func handleAncestorRangeResponse(
        _ message: PeerMessage,
        from peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = rangeSync, sync.awaiting,
              isCurrentRuntime(generation: generation, process: process),
              sync.peer.sessionID == peer.sessionID,
              let response = try? AncestorRangeResponseMessage.decoded(message.payload),
              response.requestID == sync.requestID else {
            return
        }
        // Like the forward page: stay `awaiting` (timeout armed) through the
        // enqueue loop below. The loop suspends per CID and the worker it
        // starts drains into `pumpRangeSync`; flipping `awaiting`/`negotiated`
        // here would let that pump page forward from the PRE-negotiation
        // anchor (our own tip) and bump the requestID, so the negotiated
        // anchor committed after the loop would be discarded. The flags flip
        // only in the committed block.
        // Outcome (c): no locator entry on the peer's main chain — disjoint
        // retention. End this peer's stream and drop its recorded claim so the
        // re-entry probe tries the next-tallest peer instead of re-picking it.
        // Never punish (a slow and a stalling peer are indistinguishable), and
        // never conclude "caught up".
        guard let ancestor = response.commonAncestor else {
            SyncTrace.log("ancestor-range no-overlap peer=\(peer.key.hex.prefix(8))")
            if announcedTips[peer.key]?.peer.sessionID == peer.sessionID {
                announcedTips.removeValue(forKey: peer.key)
            }
            clearRangeSync()
            return
        }
        // Outcomes (a)/(b): anchor at the negotiated common ancestor — a block
        // on OUR own accepted chain, so this never rewinds us. Enqueue the first
        // page, then hand off to the forward-range pump. An empty page here is
        // now genuinely "caught up", because the anchor is a real common block
        // rather than our (possibly off-chain) frontier.
        var lastCID: String?
        var enqueued: UInt64 = 0
        for cid in response.blockCIDs where CIDIdentity.isCanonical(cid) {
            await overlay.rememberProvider(rootCID: cid, peer: peer.id)
            guard isCurrentRuntime(generation: generation, process: process),
                  rangeSync?.requestID == sync.requestID else { return }
            guard overlayPeers[peer.key]?.sessionID == peer.sessionID else {
                clearRangeSync()
                return
            }
            // First page of a range sync anchored at the negotiated common
            // ancestor: below-tip, so weighed like the forward-range pages that
            // follow it.
            _ = enqueueCandidate(CandidateSeed(
                blockCID: cid,
                package: nil,
                provider: candidateProvider(peer),
                weighed: true
            ))
            lastCID = cid
            enqueued += 1
        }
        guard enqueued > 0, let lastCID else {
            // Caught up to this peer from a real common ancestor — or a peer
            // whose claim was a lie (a tall height, then nothing to page).
            // Demote its recorded claim exactly like the empty forward page:
            // left in place, `candidates.max(by: height)` would re-pick it
            // at every re-entry probe and it would own the single sync slot
            // forever. A fresh announcement re-records it. Caught up to an
            // honest claim, this is the edge moment for its frontier pull.
            var claimed: UInt64?
            if let claim = announcedTips[peer.key],
               claim.peer.sessionID == peer.sessionID {
                announcedTips.removeValue(forKey: peer.key)
                claimed = claim.height
            }
            clearRangeSync()
            if let claimed {
                await pullFrontierIfAtEdge(
                    from: peer,
                    peerHeight: claimed,
                    generation: generation,
                    process: process
                )
            }
            return
        }
        // Anchor the request-height window at the ANCESTOR's height, not our own
        // frontier: if the frontier is a losing sibling far above the ancestor,
        // a window measured against the frozen canonical tip would stall the
        // stream after two pages, before the streamed main chain can outweigh
        // the sibling. Fall back to the frontier height if the lookup fails.
        let anchorHeight = await process.acceptedBlockHeight(ancestor)
        guard var committed = rangeSync, committed.requestID == sync.requestID else { return }
        committed.responseTimeout?.cancel()
        committed.responseTimeout = nil
        committed.awaiting = false
        committed.negotiated = true
        let base = anchorHeight ?? committed.requestedHeight
        committed.requestedAfterCID = lastCID
        committed.requestedHeight = base + enqueued
        committed.progressBaselineHeight = min(committed.progressBaselineHeight, base)
        committed.hasMore = response.hasMore
        rangeSync = committed
        serviceCandidateAcquirer()
        await pumpRangeSync(generation: generation, process: process)
    }

    /// Hooked into the admission drain: as our tip advances, pull more pages.
    private func advanceRangeSync(
        generation: UInt64,
        process: ChainProcess
    ) async {
        await pumpRangeSync(generation: generation, process: process)
    }

    /// Rotate off a peer whose pages never advance our applied tip within a
    /// deadline (withheld bodies or off-chain CIDs), so an honest heavier tip is
    /// not starved. Rearms itself while progress continues.
    private func scheduleRangeSyncProgress(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard var sync = rangeSync else { return }
        nextRangeSyncProgressEpoch &+= 1
        let epoch = nextRangeSyncProgressEpoch
        sync.progressEpoch = epoch
        sync.progressTimeout?.cancel()
        let deadlineNanoseconds = Self.nanoseconds(
            planeConfigurations.overlay.requestTimeout
        ) &* 3
        sync.progressTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: deadlineNanoseconds) }
            catch { return }
            await self?.rangeSyncProgressDeadline(
                epoch: epoch,
                generation: generation,
                process: process
            )
        }
        rangeSync = sync
    }

    private func rangeSyncProgressDeadline(
        epoch: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard let sync = rangeSync, sync.progressEpoch == epoch,
              isCurrentGeneration(generation) else { return }
        let acquired = await process.canonicalTip()
        let applied = acquired?.height ?? 0
        guard var current = rangeSync, current.progressEpoch == epoch,
              isCurrentGeneration(generation) else { return }
        if applied >= current.targetHeight {
            // Caught up to the peer's advertised tip: release the slot so the
            // next deep peer can drive, and let direct propagation carry any
            // blocks the peer has mined since.
            clearRangeSync()
            return
        }
        guard overlayPeers[current.peer.key]?.sessionID == current.peer.sessionID
        else {
            // The peer went away before we caught up: release the slot so a new
            // deep peer can take over instead of re-driving into a dead session.
            clearRangeSync()
            return
        }
        if applied > current.progressBaselineHeight {
            // The applied tip is still climbing — the worker is draining the
            // enqueued pages. Re-arm and keep watching; do not re-request.
            current.progressBaselineHeight = applied
            current.redriveAttempts = 0
            rangeSync = current
            scheduleRangeSyncProgress(generation: generation, process: process)
            return
        }
        guard current.redriveAttempts < Self.rangeSyncMaxRedrives else {
            // Re-driving this peer has not advanced our tip across the cap: it is
            // withholding a block we need. Demote its recorded claim (see the
            // empty-page site) and release the slot so a different deep
            // peer can drive catch-up instead.
            if announcedTips[current.peer.key]?.peer.sessionID
                == current.peer.sessionID {
                announcedTips.removeValue(forKey: current.peer.key)
            }
            clearRangeSync()
            return
        }
        current.redriveAttempts += 1
        // Stalled below the target with no applied progress in a full window:
        // a content fetch has wedged (e.g. its only provider was dropped as
        // deficient), and every already-enqueued successor is blocked behind
        // it. Rewind the request anchor to the current applied tip and page
        // forward again — re-delivering the wedged block re-attaches its
        // provider (bumping providerRevision re-readies the waiting candidate),
        // and rotates onto whatever the peer still serves.
        current.requestedAfterCID = acquired?.cid ?? configuration.nexusGenesisCID
        current.requestedHeight = applied
        current.progressBaselineHeight = applied
        current.hasMore = true
        current.awaiting = false
        current.negotiated = false
        current.responseTimeout?.cancel()
        current.responseTimeout = nil
        rangeSync = current
        scheduleRangeSyncProgress(generation: generation, process: process)
        // The rewound anchor is our frontier again: negotiate the common
        // ancestor before streaming, so a frontier that sits on a losing
        // sibling is not told "empty = caught up" and marooned.
        await sendAncestorRangeRequest(generation: generation, process: process)
    }

    private func rangeSyncTimedOut(requestID: UInt64, generation: UInt64) async {
        guard let sync = rangeSync, sync.requestID == requestID, sync.awaiting,
              isCurrentGeneration(generation), let process else { return }
        guard overlayPeers[sync.peer.key]?.sessionID == sync.peer.sessionID else {
            // Peer we were paging from is gone: release the slot so another
            // deep peer's announcement can start a fresh sync.
            clearRangeSync()
            return
        }
        // The request went unanswered but the peer is still connected — clear
        // the awaiting latch and re-issue it rather than tearing down the whole
        // sync (the progress watchdog remains the backstop for a peer that has
        // genuinely stopped serving). An unanswered NEGOTIATION is re-sent as a
        // negotiation: paging forward from the un-negotiated frontier would
        // re-open the marooned-follower bug on one dropped packet.
        var current = sync
        current.awaiting = false
        current.responseTimeout?.cancel()
        current.responseTimeout = nil
        rangeSync = current
        if current.negotiated {
            await pumpRangeSync(generation: generation, process: process)
        } else {
            await sendAncestorRangeRequest(generation: generation, process: process)
        }
    }

    private func clearRangeSync(from caller: String = #function) {
        SyncTrace.log("range-sync clear (\(caller))")
        rangeSync?.responseTimeout?.cancel()
        rangeSync?.progressTimeout?.cancel()
        rangeSync = nil
        scheduleRangeSyncReentry()
    }

    /// A cleared sync must not depend on a further announcement to restart:
    /// on a quiet network (nobody minting) none ever arrives, and a node
    /// still far behind would idle forever. Re-entry is the receiver's own
    /// assessment, probed one request-timeout after each clear.
    private func scheduleRangeSyncReentry() {
        guard rangeSyncReentryTask == nil, !announcedTips.isEmpty else {
            return
        }
        let generation = runtimeGeneration
        let delay = Self.nanoseconds(planeConfigurations.overlay.requestTimeout)
        rangeSyncReentryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.maybeRestartRangeSync(generation: generation)
        }
    }

    private func maybeRestartRangeSync(generation: UInt64) async {
        rangeSyncReentryTask = nil
        guard isCurrentGeneration(generation), isRunning,
              rangeSync == nil, let process else { return }
        let ourHeight = await acquiredHeight(process)
        guard isCurrentRuntime(generation: generation, process: process),
              rangeSync == nil else { return }
        // Every recorded peer we are now at the edge with (the sync that just
        // cleared brought us there, or nothing beyond the edge remains) gets
        // its one frontier pull; the helper re-checks the edge per peer.
        for (key, claim) in announcedTips.sorted(by: { $0.key.hex < $1.key.hex })
            where overlayPeers[key]?.sessionID == claim.peer.sessionID {
            await pullFrontierIfAtEdge(
                from: claim.peer,
                peerHeight: claim.height,
                generation: generation,
                process: process
            )
            guard isCurrentRuntime(generation: generation, process: process),
                  rangeSync == nil else { return }
        }
        let candidates = announcedTips.filter { key, value in
            overlayPeers[key]?.sessionID == value.peer.sessionID
                && value.height > ourHeight + Self.rangeSyncDepthThreshold
        }
        guard let best = candidates.max(by: {
            $0.value.height < $1.value.height
        }) else { return }
        await startRangeSync(
            peer: best.value.peer,
            targetHeight: best.value.height,
            generation: generation,
            process: process
        )
        // The peer may refuse or stall again; the next clear re-probes.
    }

    /// The height acquisition compares against: the canonical (weighed-
    /// inclusive) tip — what we HOLD. `status().height` is the validated tip,
    /// the act-on gate (templates, reads, hello tip); under deferred execution
    /// weighed admissions never advance it, so gap tests, the paging window
    /// and the locator measured against it would pace range sync on the
    /// validate walk and re-page history already held.
    private func acquiredHeight(_ process: ChainProcess) async -> UInt64 {
        await process.canonicalTipHeight() ?? 0
    }

    /// One-shot frontier pull, once per session, at the live edge. The tip
    /// announcement and main-chain range sync never carry losing forks, yet
    /// fork choice weighs subtrees; a peer's accepted LEAVES plus parent links
    /// determine its whole header graph, so one page per session is the
    /// entire discovery — each unknown leaf's predecessor walk reassembles
    /// its ancestry down to known history. That walk is short only when we
    /// already hold the peer's main chain up to the live edge: pulled while
    /// deep, every leaf would descend the whole gap top-down in competition
    /// with range sync (and the parks would evict the leaves themselves). So
    /// the pull waits for the moment `peerHeight` is within
    /// `rangeSyncDepthThreshold` of our acquired tip — evaluated wherever
    /// that is decided: on the peer's announcements and when a range sync
    /// clears. No cursor: the live frontier is small under the losing-fork
    /// budget, and any remainder re-enters through announcements.
    private func pullFrontierIfAtEdge(
        from peer: AuthenticatedPeer,
        peerHeight: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        // An in-flight range sync is by definition not the edge, whatever any
        // peer attests about its own height.
        guard rangeSync == nil,
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              frontierPulls[peer.key]?.sessionID != peer.sessionID else { return }
        let ourHeight = await acquiredHeight(process)
        guard isCurrentRuntime(generation: generation, process: process),
              rangeSync == nil,
              overlayPeers[peer.key]?.sessionID == peer.sessionID,
              frontierPulls[peer.key]?.sessionID != peer.sessionID,
              peerHeight <= ourHeight + Self.rangeSyncDepthThreshold else { return }
        let requestID = makeRequestID()
        guard let payload = try? AcceptedLeavesRequestMessage(
            requestID: requestID,
            afterCID: nil
        ).encoded() else { return }
        frontierPulls[peer.key] = FrontierPull(
            sessionID: peer.sessionID,
            requestID: requestID
        )
        SyncTrace.log(
            "frontier pull peer=\(peer.key.hex.prefix(8)) "
                + "peerHeight=\(peerHeight) ours=\(ourHeight)"
        )
        _ = await overlay.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.acceptedLeavesRequest,
            payload: payload
        )
    }

    #if DEBUG
    /// Test seam: the range sync's current request anchor (the block the next
    /// page is requested after, and its height).
    func rangeSyncAnchorForTesting() -> (afterCID: String, requestedHeight: UInt64)? {
        rangeSync.map { ($0.requestedAfterCID, $0.requestedHeight) }
    }
    #endif

    private func discardServingSessions(for peerKey: PeerKey) {
        var sessionIDs = Set<Data>()
        if let session = overlaySessions[peerKey] {
            sessionIDs.insert(session.sessionID)
        }
        if let session = overlayPeers[peerKey] {
            sessionIDs.insert(session.sessionID)
        }
        for sessionID in sessionIDs {
            servingAcceptedLeaves.remove(sessionID)
            servingAncestorRange.remove(sessionID)
        }
    }

    /// Verify-not-trust gate for deployer-seeded self-admission: ask the
    /// authenticated immediate parent whether it recorded exactly this child
    /// genesis CID (bound to the empty parent state a self-contained genesis
    /// commits to). The parent answers only on a positive match and stays silent
    /// otherwise, so an unrecorded — or mismatched — CID resolves `false` when the
    /// request times out. `false` on a missing parent session too; the caller
    /// retries until the parent connects and confirms.
    public func confirmParentRecordedChildGenesis(
        childGenesisCID: String
    ) async -> Bool {
        guard !configuration.address.isNexus,
              pendingGenesisVerifications.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            return false
        }
        let request = ParentChainFactMessage(
            requestID: makeRequestID(),
            fact: .genesis(
                childGenesisCID: childGenesisCID,
                parentStateCID: LatticeState.emptyHeader.rawCID
            )
        )
        guard let payload = try? request.encoded() else { return false }
        let delay = Self.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        return await withCheckedContinuation { continuation in
            pendingGenesisVerifications[request.requestID] =
                PendingGenesisVerification(
                    peer: parent,
                    request: request,
                    continuation: continuation
                )
            Task { [weak self] in
                _ = await self?.hierarchy.sendMessage(
                    to: parent,
                    topic: NodeNetworkTopic.parentChainFactRequest,
                    payload: payload
                )
                try? await Task.sleep(nanoseconds: delay)
                await self?.resolveGenesisVerification(
                    request.requestID,
                    confirmed: false
                )
            }
        }
    }

    private func resolveGenesisVerification(
        _ requestID: UInt64,
        confirmed: Bool
    ) {
        guard let pending = pendingGenesisVerifications.removeValue(
            forKey: requestID
        ) else { return }
        pending.continuation.resume(returning: confirmed)
    }

    /// Ask the authenticated immediate parent for the genesis CID it recorded for
    /// THIS child's own directory (read from the parent's committed genesisState).
    /// Returns nil on a missing parent session or timeout, for the caller to
    /// retry. Verify-not-trust: the CID is content-addressed and re-confirmed
    /// against the parent record before any admission.
    private func resolveParentAnchoredGenesis() async -> String? {
        guard !configuration.address.isNexus,
              pendingGenesisResolves.count < Self.maximumPendingRequests,
              let parent = configuredParentPeer() else {
            return nil
        }
        let requestID = makeRequestID()
        guard let payload = try? ChildGenesisAnchorRequestMessage(
            requestID: requestID
        ).encoded() else { return nil }
        let delay = Self.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        return await withCheckedContinuation { continuation in
            pendingGenesisResolves[requestID] = PendingGenesisResolve(
                peer: parent,
                continuation: continuation
            )
            Task { [weak self] in
                _ = await self?.hierarchy.sendMessage(
                    to: parent,
                    topic: NodeNetworkTopic.childGenesisAnchorRequest,
                    payload: payload
                )
                try? await Task.sleep(nanoseconds: delay)
                await self?.resolveGenesisAnchor(requestID, genesisCID: nil)
            }
        }
    }

    private func resolveGenesisAnchor(
        _ requestID: UInt64,
        genesisCID: String?
    ) {
        guard let pending = pendingGenesisResolves.removeValue(
            forKey: requestID
        ) else { return }
        pending.continuation.resume(returning: genesisCID)
    }

    private func scheduleAdoptedGenesisBootstrap(
        generation: UInt64,
        process: ChainProcess
    ) {
        guard !configuration.address.isNexus,
              adoptedGenesisTask == nil else { return }
        adoptedGenesisTask = Task { [weak self] in
            await self?.adoptedGenesisBootstrapLoop(
                generation: generation,
                process: process
            )
        }
    }

    /// A child this node ADOPTED (no local genesis seed) sits `awaitingGenesis`
    /// until it obtains its self-contained genesis: resolve the recorded CID off
    /// the authenticated parent, fetch the genesis volume from a child-overlay
    /// provider, and self-admit it (fail-closed on the parent record). A seeded
    /// deployer activates from its local seed before this ever fires; this drives
    /// the no-seed follower case the candidate machinery cannot (a self-contained
    /// genesis carries no ChildBlockProof to package). Once active, kick the
    /// ordinary follower sync so the child catches up to the parent's tip.
    private func adoptedGenesisBootstrapLoop(
        generation: UInt64,
        process: ChainProcess
    ) async {
        var lastTraced = ""
        func traceOnce(_ outcome: String) {
            guard outcome != lastTraced else { return }
            lastTraced = outcome
            SyncTrace.log("adopt-genesis \(outcome)")
        }
        while isRunning, runtimeGeneration == generation {
            if await process.status().phase != .awaitingGenesis { return }
            if let genesisCID = await resolveParentAnchoredGenesis() {
                traceOnce("resolved \(genesisCID)")
                let activated = (try? await remoteContentSource.withRoot(
                    genesisCID
                ) { session in
                    try await process.activateAdoptedChildGenesis(
                        genesisCID: genesisCID,
                        remoteSource: session,
                        confirmParentRecordedGenesis: { [weak self] cid in
                            await self?.confirmParentRecordedChildGenesis(
                                childGenesisCID: cid
                            ) ?? false
                        }
                    )
                }) ?? false
                traceOnce(activated
                    ? "activated \(genesisCID)"
                    : "fetch-or-confirm failed \(genesisCID)")
                guard isCurrentRuntime(
                    generation: generation, process: process
                ) else { return }
                if activated {
                    // The genesis just bootstrapped to active OUT OF BAND (not via
                    // candidate admission), so it never fired its one-shot connect
                    // signal. Wake the successors that parked behind it while
                    // awaitingGenesis, or the whole chain above the genesis stays
                    // orphaned and the child never canonicalizes past height 0.
                    candidateAcquirer.predecessorConnectedOutOfBand(genesisCID)
                    serviceCandidateAcquirer()
                    await requestEvidenceIndex(
                        generation: generation,
                        process: process
                    )
                    return
                }
            } else {
                traceOnce("parent record unresolved")
            }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    /// Validate-tier evidence (deferred execution): a weighed CHILD block's
    /// `.validate` admission recovers its own proof package from the store but
    /// still needs the cross-chain fact the live path obtains from the
    /// configured parent — the parent-state continuity (or genesis) link. The
    /// walk hands the requirement here; this is the SAME request the live
    /// candidate path sends (`requestParentChainFact`), awaited, and the merged
    /// package is returned for the `.validate` re-admit. Nil when the fact is
    /// not obtainable now (no parent session, request budget, timeout); the
    /// walk then parks and retries. Without this, every weighed child block
    /// parks the walk on `.unavailable(.parentStateContinuity)` forever.
    public func resolveValidateEvidence(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage? {
        guard isRunning, let process, !configuration.address.isNexus,
              let fact = parentFact(for: requirement) else {
            return nil
        }
        let generation = runtimeGeneration
        guard let package = try? await process.recoveredAuthenticatedChildPackage(
            for: blockCID
        ), isCurrentRuntime(generation: generation, process: process) else {
            return nil
        }
        return await awaitParentFact(
            fact,
            for: blockCID,
            package: package,
            generation: generation,
            process: process
        )
    }

    #if DEBUG
    /// Test seam: `resolveValidateEvidence` with the block's package supplied
    /// instead of recovered from the store — the request, await and every
    /// resumption path are the production ones.
    public func resolveValidateEvidenceForTesting(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement,
        package: AuthenticatedChildPackage
    ) async -> AuthenticatedChildPackage? {
        guard isRunning, let process, let fact = parentFact(for: requirement) else {
            return nil
        }
        return await awaitParentFact(
            fact,
            for: blockCID,
            package: package,
            generation: runtimeGeneration,
            process: process
        )
    }
    #endif

    private func parentFact(
        for requirement: CrossChainEvidenceRequirement
    ) -> ParentChainFact? {
        let parentPath = Array(configuration.chainPath.dropLast())
        switch requirement {
        case .parentGenesis(
            let requiredPath, let directory, let childGenesisCID, let parentStateCID
        ) where requiredPath == parentPath
                && directory == configuration.address.directory:
            return .genesis(
                childGenesisCID: childGenesisCID,
                parentStateCID: parentStateCID
            )
        case .parentStateContinuity(let requiredPath, let fromStateCID, let toStateCID)
            where requiredPath == parentPath:
            return .continuity(fromStateCID: fromStateCID, toStateCID: toStateCID)
        default:
            return nil
        }
    }

    /// Send the parent-fact request and await its outcome: the merged package
    /// on a fact, nil on refusal, timeout, parent disconnect or reset. Every
    /// removal of the pending entry resumes the continuation (see
    /// `discardPendingParentChainFacts`), so the walk never stays suspended.
    private func awaitParentFact(
        _ fact: ParentChainFact,
        for blockCID: String,
        package: AuthenticatedChildPackage,
        generation: UInt64,
        process: ChainProcess
    ) async -> AuthenticatedChildPackage? {
        SyncTrace.log(
            "validate evidence request block=\(blockCID.prefix(12)) fact=\(fact)"
        )
        return await withCheckedContinuation { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                await self.requestParentChainFact(
                    fact,
                    for: blockCID,
                    package: package,
                    generation: generation,
                    process: process,
                    continuation: continuation
                )
            }
        }
    }

    /// The one teardown path for pending parent-fact requests: a walk's
    /// continuation is resumed nil, a live candidate's entry is requeued when
    /// asked. No other site may drop an entry without going through here.
    private func discardPendingParentChainFacts(
        where predicate: (PendingParentChainFact) -> Bool,
        requeue: Bool
    ) {
        let discarded = pendingParentChainFacts.values.filter(predicate)
        pendingParentChainFacts = pendingParentChainFacts.filter {
            !predicate($0.value)
        }
        for pending in discarded {
            if let continuation = pending.continuation {
                continuation.resume(returning: nil)
            } else if requeue {
                retryParentFactCandidate(pending)
            }
        }
    }

    private func requestParentChainFact(
        _ fact: ParentChainFact,
        for blockCID: String,
        package: AuthenticatedChildPackage,
        generation: UInt64,
        process: ChainProcess,
        continuation: CheckedContinuation<AuthenticatedChildPackage?, Never>? = nil
    ) async {
        guard !configuration.address.isNexus,
              isCurrentRuntime(generation: generation, process: process),
              pendingParentChainFacts.count
                < Self.maximumPendingRequests,
              !pendingParentChainFacts.values.contains(where: {
                  $0.blockCID == blockCID
                    && $0.request.fact == fact
              }),
              let parent = configuredParentPeer() else {
            continuation?.resume(returning: nil)
            return
        }
        let request = ParentChainFactMessage(
            requestID: makeRequestID(),
            fact: fact
        )
        guard let payload = try? request.encoded() else {
            continuation?.resume(returning: nil)
            return
        }
        pendingParentChainFacts[request.requestID] =
            PendingParentChainFact(
                peer: parent,
                request: request,
                blockCID: blockCID,
                package: package,
                continuation: continuation
            )
        // Armed BEFORE the send suspends: the entry must always have a
        // bounded life, whatever happens during or after the send. A failed
        // enqueue is transient — the same timeout used for an unanswered
        // parent response requeues the candidate (or resolves the walk's
        // request nil); a disconnect does so sooner.
        let delay = Self.nanoseconds(
            planeConfigurations.hierarchy.requestTimeout
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.parentChainFactRequestTimedOut(
                request.requestID,
                generation: generation
            )
        }
        _ = await hierarchy.sendMessage(
            to: parent,
            topic: NodeNetworkTopic.parentChainFactRequest,
            payload: payload
        )
        guard isCurrentRuntime(
            generation: generation,
            process: process
        ) else {
            discardPendingParentChainFacts(
                where: { $0.request.requestID == request.requestID },
                requeue: false
            )
            return
        }
    }

    private func acceptParentChainFact(
        pending: PendingParentChainFact,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            pending.continuation?.resume(returning: nil)
            return
        }
        let parentPath = Array(configuration.chainPath.dropLast())
        let localFact: AuthenticatedChildPackage
        switch pending.request.fact {
        case .genesis(let childGenesisCID, let parentStateCID):
            localFact = AuthenticatedChildPackage(package: ChildValidationPackage(
                proof: pending.package.package.proof,
                parentGenesisLink: ParentGenesisLink(
                    parentPath: parentPath,
                    directory: configuration.address.directory,
                    childGenesisCID: childGenesisCID,
                    parentStateCID: parentStateCID
                )
            ))
        case .continuity(let fromStateCID, let toStateCID):
            localFact = AuthenticatedChildPackage(package: ChildValidationPackage(
                proof: pending.package.package.proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: parentPath,
                    fromStateCID: fromStateCID,
                    toStateCID: toStateCID
                )
            ))
        }
        guard let merged = CandidateAcquirer.mergePackages(
            pending.package,
            localFact
        ) else {
            pending.continuation?.resume(returning: nil)
            return
        }
        // The validate walk asked for this fact: hand the merged package back
        // to its `.validate` re-admit; there is no live candidate to re-ready.
        if let continuation = pending.continuation {
            continuation.resume(returning: merged)
            return
        }
        // A parent fact that arrives SUCCESSFULLY must re-ready the candidate that
        // was blocked waiting for it. observe()/enqueueCandidate only flips a
        // `.waiting(.evidence)` attempt back to `.ready`, never a `.waiting(.later)`
        // one, so without retryExternalDependency the candidate would wedge until
        // the wall-clock poll (or 2h expiry). Mirror the timeout path
        // (retryParentFactCandidate) so the fact's arrival is itself the trigger.
        _ = candidateAcquirer.observe(CandidateSeed(
            blockCID: pending.blockCID,
            package: merged
        ))
        candidateAcquirer.retryExternalDependency(
            blockCID: pending.blockCID,
            rootCID: pending.package.package.proof.rootCID
        )
        serviceCandidateAcquirer()
    }

    private func parentChainFactRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
              let pending = pendingParentChainFacts.removeValue(
                forKey: requestID
              ) else { return }
        if let continuation = pending.continuation {
            continuation.resume(returning: nil)
            return
        }
        retryParentFactCandidate(pending)
    }

    private func retryParentFactCandidate(_ pending: PendingParentChainFact) {
        _ = candidateAcquirer.observe(CandidateSeed(
            blockCID: pending.blockCID,
            package: pending.package
        ))
        candidateAcquirer.retryExternalDependency(
            blockCID: pending.blockCID,
            rootCID: pending.package.package.proof.rootCID
        )
        serviceCandidateAcquirer()
    }

    private func requestEvidenceIndex(
        sourceID: String? = nil,
        cursor: UInt64? = nil,
        through: UInt64? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            isRunning,
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), !configuration.address.isNexus,
              pendingEvidenceIndexes.isEmpty,
            let parent = configuredParentPeer()
        else { return }
        let durableCursor: ParentEvidenceScanCursor
        if let sourceID, let cursor {
            durableCursor = ParentEvidenceScanCursor(
                sourceID: sourceID,
                ordinal: cursor
            )
        } else {
            guard let persisted = try? await fence.process
                .parentEvidenceScanCursor()
            else { return }
            durableCursor = persisted
        }
        let request = ChildEvidenceIndexRequestMessage(
            requestID: makeRequestID(),
            childPath: configuration.chainPath,
            sourceID: durableCursor.sourceID,
            cursor: durableCursor.ordinal,
            through: through
        )
        guard let payload = try? request.encoded() else { return }
        pendingEvidenceIndexes[request.requestID] = .init(
            peer: parent,
            request: request
        )
        let result = await hierarchy.sendMessage(
                to: parent,
                topic: NodeNetworkTopic.childEvidenceIndexRequest,
                payload: payload
        )
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
            return
        }
        if result != .notConnected {
            if pendingEvidenceIndexes[request.requestID] != nil {
                scheduleEvidenceIndexTimeout(
                    request.requestID,
                    generation: fence.generation
                )
            }
        } else {
            pendingEvidenceIndexes.removeValue(forKey: request.requestID)
        }
    }

    private func scheduleEvidenceIndexTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.evidenceIndexRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func evidenceIndexRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) async {
        guard isRunning,
            isCurrentGeneration(generation),
            let process,
              let request = pendingEvidenceIndexes.removeValue(
                forKey: requestID
            )
        else { return }
        await requestEvidenceIndex(
            sourceID: request.request.sourceID,
            cursor: request.request.cursor,
            through: request.request.through,
            generation: generation,
            process: process
        )
    }

    private func requestChildCandidate(
        from peerKey: PeerKey,
        childPath: [String],
        parentCID: String,
        parentData: Data,
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork],
        deadline: ContinuousClock.Instant,
        generation: UInt64,
        process: ChainProcess
    ) async -> DirectChildCandidate? {
        guard isRunning,
            isCurrentRuntime(generation: generation, process: process),
            pendingChildCandidates.count < Self.maximumDirectChildren
        else {
            return nil
        }
        guard
            let rewards = await resolvedMiningRewards(
            rewards,
                process: process,
                generation: generation
            )
        else { return nil }
        guard isCurrentRuntime(generation: generation, process: process) else {
            return nil
        }
        let remaining = Self.milliseconds(
            ContinuousClock.now.duration(to: deadline)
        )
        guard
            let remoteBudget = Self.remoteChildCandidateBudget(
            parentWaitMilliseconds: remaining
            )
        else { return nil }
        // The receiver starts its monotonic deadline after transit. Give it a
        // strictly smaller budget so serialization and the response have room
        // before our local continuation times out.
        let request = ChildCandidateRequestMessage(
            requestID: makeRequestID(),
            budgetMilliseconds: remoteBudget,
            childPath: childPath,
            parentCID: parentCID,
            parentData: parentData,
            rewards: rewards,
            minimumWork: minimumWork
        )
        guard let payload = try? request.encoded() else { return nil }
        return await withCheckedContinuation { continuation in
            guard isCurrentRuntime(generation: generation, process: process) else {
                continuation.resume(returning: nil)
                return
            }
            pendingChildCandidates[request.requestID] = PendingChildCandidateRequest(
                peerKey: peerKey,
                childPath: childPath,
                parentCID: parentCID,
                continuation: continuation
            )
            scheduleChildCandidateTimeout(
                request.requestID,
                after: .milliseconds(Int64(remaining)),
                generation: generation
            )
            Task { [weak self] in
                await self?.sendChildCandidateRequest(
                    requestID: request.requestID,
                    peerKey: peerKey,
                    payload: payload,
                    generation: generation,
                    process: process
                )
            }
        }
    }

    private func requestCandidateReservation(
        candidateCIDs: [String],
        handoffCIDs: [String] = [],
        childPath: [String],
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) async -> Bool {
        guard isCurrentRuntime(generation: generation, process: process),
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              pendingCandidateReservations.count < Self.maximumPendingRequests
        else { return false }
        let request = ChildCandidateReservationRequestMessage(
            requestID: makeRequestID(),
            childPath: childPath,
            candidateCIDs: candidateCIDs,
            handoffCIDs: handoffCIDs
        )
        guard let payload = try? request.encoded() else { return false }
        let accepted = await withCheckedContinuation { continuation in
            pendingCandidateReservations[request.requestID] =
                PendingCandidateReservation(
                    peer: peer,
                    childPath: childPath,
                    continuation: continuation
                )
            scheduleCandidateReservationTimeout(
                request.requestID,
                generation: generation
            )
            Task { [weak self] in
                guard let self else { return }
                let result = await self.hierarchy.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.childCandidateReservationRequest,
                    payload: payload
                )
                guard case .enqueued = result else {
                    await self.finishCandidateReservation(
                        request.requestID,
                        accepted: false,
                        generation: generation
                    )
                    return
                }
            }
        }
        return accepted
            && isCurrentRuntime(generation: generation, process: process)
            && hierarchySessions[peer.key]?.sessionID == peer.sessionID
            && hierarchyPeers[peer.key] == .child(childPath)
    }

    private func scheduleCandidateReservationTimeout(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        let timeout = planeConfigurations.hierarchy.requestTimeout
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
            } catch {
                return
            }
            await self?.finishCandidateReservation(
                requestID,
                accepted: false,
                generation: generation
            )
        }
    }

    private func finishCandidateReservation(
        _ requestID: UInt64,
        accepted: Bool,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
              let pending = pendingCandidateReservations.removeValue(
                forKey: requestID
              ) else { return }
        pending.continuation.resume(returning: accepted)
    }

    private func resolvedMiningRewards(
        _ rewards: [MiningReward],
        process: ChainProcess,
        generation: UInt64
    ) async -> [MiningReward]? {
        var resolved: [MiningReward] = []
        resolved.reserveCapacity(rewards.count)
        for reward in rewards {
            if reward.transaction.body.node != nil {
                resolved.append(reward)
                continue
            }
            guard
                let data = try? await process.fetch(
                    rawCid: reward.transaction.body.rawCID
                  ), let body = TransactionBody(data: data),
                isCurrentRuntime(generation: generation, process: process),
                  body.toData() == data,
                  let header = try? HeaderImpl<TransactionBody>(node: body),
                header.rawCID == reward.transaction.body.rawCID
            else {
                return nil
            }
            resolved.append(
                MiningReward(
                chainPath: reward.chainPath,
                transaction: Transaction(
                    signatures: reward.transaction.signatures,
                    body: header
                )
            ))
        }
        return resolved
    }

    private func selectedChildPeers() -> [(Int, PeerKey, [String])] {
        var paths: [String: [String]] = [:]
        var peers: [String: [PeerKey]] = [:]
        for (key, role) in hierarchyPeers {
            guard case .child(let path) = role,
                  childEvidenceReadyPeers.contains(key),
                  !dirtyCandidateReservationPeers.contains(key) else {
                continue
            }
            let pathKey = path.joined(separator: "/")
            paths[pathKey] = path
            peers[pathKey, default: []].append(key)
        }

        let pathKeys = peers.keys.sorted()
        let pathRotation = Self.rotatedPeerIndices(
            peerCount: pathKeys.count,
            start: childPathRotation,
            limit: min(pathKeys.count, Self.maximumDirectChildren)
        )
        childPathRotation = pathRotation.next

        var selectedPaths: [(path: [String], peers: [PeerKey])] = []
        for pathIndex in pathRotation.indices {
            let pathKey = pathKeys[pathIndex]
            guard let path = paths[pathKey] else { continue }
            let keys = peers[pathKey]!.sorted { $0.hex < $1.hex }
            let start = (childPeerRotation[pathKey] ?? 0) % keys.count
            let rotation = Self.rotatedPeerIndices(
                peerCount: keys.count,
                start: start,
                limit: min(Self.maximumPeersPerChildPath, keys.count)
            )
            selectedPaths.append((path, rotation.indices.map { keys[$0] }))
            childPeerRotation[pathKey] = rotation.next
        }

        var selected: [(Int, PeerKey, [String])] = []
        for (pathIndex, peerIndex) in Self.interleavedChildPeerIndices(
            peerCounts: selectedPaths.map { $0.peers.count },
            limit: Self.maximumDirectChildren
        ) {
            let path = selectedPaths[pathIndex]
            selected.append((selected.count, path.peers[peerIndex], path.path))
        }
        return selected
    }

    private func authenticatedChildDirectories() -> [String] {
        let directories: [String] = Array(
            Set<String>(
            hierarchyPeers.values.compactMap { role in
            guard case .child(let path) = role else { return nil }
            return path.last
            }
            )
        ).sorted()
        let rotation = Self.rotatedPeerIndices(
            peerCount: directories.count,
            start: childProofPathRotation,
            limit: min(directories.count, Self.maximumDirectChildren)
        )
        childProofPathRotation = rotation.next
        return rotation.indices.map { directories[$0] }
    }

    private func retryCurrentTipChildProofs(
        tipCID: String? = nil,
        directories: [String]? = nil,
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            )
        else { return }
        let resolvedTipCID: String
        if let tipCID {
            resolvedTipCID = tipCID
        } else {
            guard let currentTipCID = await fence.process.status().tipCID,
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            resolvedTipCID = currentTipCID
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        let directories = directories ?? authenticatedChildDirectories()
        guard !directories.isEmpty else { return }
        try? await remoteContentSource.withRoot(resolvedTipCID) { session in
            try await fence.process.prepareChildProofs(
                for: BlockHeader(
                    rawCID: resolvedTipCID,
                    node: nil,
                    encryptionInfo: nil
                ),
                directories: directories,
                remoteSource: session
            )
        }
        guard
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        guard
            await announceCurrentCarrierChildEvidence(
                directories: directories,
                carrierCID: resolvedTipCID,
                generation: fence.generation,
                process: fence.process
            )
        else {
            return
        }
    }

    private func retryRecoveredChildProofs(
        generation: UInt64? = nil,
        process expectedProcess: ChainProcess? = nil
    ) async {
        guard
            let fence = resolvedRuntimeFence(
                generation: generation,
                process: expectedProcess
            ), let carrierCIDs = try? await fence.process.pendingChildProofCarrierCIDs(),
            isCurrentRuntime(
                generation: fence.generation,
                process: fence.process
            )
        else { return }
        for carrierCID in carrierCIDs {
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            let directories = try? await remoteContentSource.withRoot(carrierCID) { session in
                try await fence.process.retryPendingChildProofs(
                    carrierCID: carrierCID,
                    remoteSource: session
                )
            }
            guard
                isCurrentRuntime(
                    generation: fence.generation,
                    process: fence.process
                )
            else { return }
            if let directories, !directories.isEmpty {
                guard
                    await announceCurrentCarrierChildEvidence(
                        directories: directories,
                        carrierCID: carrierCID,
                        generation: fence.generation,
                        process: fence.process
                    )
                else { return }
            }
        }
    }

    private func sendChildCandidateRequest(
        requestID: UInt64,
        peerKey: PeerKey,
        payload: Data,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard pendingChildCandidates[requestID] != nil,
              case .child? = hierarchyPeers[peerKey],
              let peer = hierarchySessions[peerKey]
        else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
        let result = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateRequest,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process) else {
            return
        }
        guard case .enqueued = result else {
            finishChildCandidateRequest(requestID, with: nil)
            return
        }
    }

    private func startChildCandidateBuild(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer,
        generation: UInt64,
        process: ChainProcess
    ) {
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID] == nil,
              childCandidateBuilds.count < Self.maximumConcurrentChildBuilds,
            let builder = handlers?.childCandidateBuilder
        else { return }
        let budget = min(
            UInt64(request.budgetMilliseconds),
            Self.milliseconds(planeConfigurations.hierarchy.requestTimeout)
        )
        guard budget > 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(Int64(budget))
        nextChildCandidateBuildToken &+= 1
        let token = nextChildCandidateBuildToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.buildChildCandidate(
                request,
                parent: parent,
                peer: peer,
                deadline: deadline,
                builder: builder,
                token: token,
                generation: generation,
                process: process
            )
        }
        childCandidateBuilds[request.requestID] = ChildCandidateBuild(
            peerKey: peer.key,
            token: token,
            task: task
        )
        scheduleChildCandidateBuildTimeout(
            request.requestID,
            after: .milliseconds(Int64(budget)),
            token: token,
            generation: generation
        )
    }

    private func buildChildCandidate(
        _ request: ChildCandidateRequestMessage,
        parent: Block,
        peer: AuthenticatedPeer,
        deadline: ContinuousClock.Instant,
        builder: ContextualChildCandidateBuilder,
        token: UInt64,
        generation: UInt64,
        process: ChainProcess
    ) async {
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token
        else {
            return
        }
        defer {
            if isCurrentRuntime(generation: generation, process: process),
                childCandidateBuilds[request.requestID]?.token == token
            {
                childCandidateBuilds.removeValue(forKey: request.requestID)
            }
        }
        let parentSource = IvyRootContentSource(
            ivy: hierarchy,
            peer: peer,
            policy: configuration.resourcePolicy
        )
        guard let candidate = try? await parentSource.withRoot(
            request.parentCID,
            operation: { session in
                try await ChildCandidateBudget.$deadline.withValue(deadline) {
                    try await builder(
                        ChildCandidateRequestContext(
                            parentCarrier: parent,
                            rewards: request.rewards,
                            minimumWork: request.minimumWork
                        ),
                        session
                    )
                }
            }
        ) else { return }
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token,
              !Task.isCancelled,
              hierarchySessions[peer.key]?.sessionID == peer.sessionID,
              hierarchyPeers[peer.key] == .parent,
              candidate.directory == configuration.address.directory,
              let blockData = candidate.block.toData(),
              let childCID = try? BlockHeader(node: candidate.block).rawCID
        else { return }
        guard let payload = try? ChildCandidateResponseMessage(
                requestID: request.requestID,
                childPath: configuration.chainPath,
                parentCID: request.parentCID,
                childCID: childCID,
                blockData: blockData,
                searchWitness: candidate.searchWitness
            ).encoded() else { return }
        _ = await hierarchy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childCandidateResponse,
            payload: payload
        )
        guard isCurrentRuntime(generation: generation, process: process),
            childCandidateBuilds[request.requestID]?.token == token
        else {
            return
        }
    }

    private func scheduleChildCandidateTimeout(
        _ requestID: UInt64,
        after timeout: Duration,
        generation: UInt64
    ) {
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.childCandidateRequestTimedOut(
                requestID,
                generation: generation
            )
        }
    }

    private func scheduleChildCandidateBuildTimeout(
        _ requestID: UInt64,
        after timeout: Duration,
        token: UInt64,
        generation: UInt64
    ) {
        let timeoutNanoseconds = Self.nanoseconds(timeout)
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await self?.cancelChildCandidateBuild(
                requestID,
                token: token,
                generation: generation
            )
        }
    }

    private func childCandidateRequestTimedOut(
        _ requestID: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation) else { return }
        finishChildCandidateRequest(requestID, with: nil)
    }

    private func cancelChildCandidateBuild(
        _ requestID: UInt64,
        token: UInt64,
        generation: UInt64
    ) {
        guard isCurrentGeneration(generation),
            childCandidateBuilds[requestID]?.token == token
        else { return }
        childCandidateBuilds.removeValue(forKey: requestID)?.task.cancel()
    }

    private func finishChildCandidateRequest(
        _ requestID: UInt64,
        with candidate: DirectChildCandidate?
    ) {
        pendingChildCandidates.removeValue(
            forKey: requestID
        )?.continuation.resume(returning: candidate)
    }

    private func cancelChildCandidateWork(for peerKey: PeerKey) {
        let pendingIDs = pendingChildCandidates.compactMap { requestID, pending in
            pending.peerKey == peerKey ? requestID : nil
        }
        for requestID in pendingIDs {
            finishChildCandidateRequest(requestID, with: nil)
        }
        let buildIDs = childCandidateBuilds.compactMap { requestID, build in
            build.peerKey == peerKey ? requestID : nil
        }
        for requestID in buildIDs {
            childCandidateBuilds.removeValue(forKey: requestID)?.task.cancel()
        }
    }

    private func childCandidateRequestDeadline() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        let overallDeadline =
            ChildCandidateBudget.deadline
            ?? now + planeConfigurations.hierarchy.requestTimeout
        let remaining = Self.milliseconds(now.duration(to: overallDeadline))
        guard remaining > Self.childCandidateFinalizeReserveMilliseconds else {
            return nil
        }
        return now
            + .milliseconds(
                Int64(
            remaining - Self.childCandidateFinalizeReserveMilliseconds
        ))
    }

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

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        // Keep Duration out of optimized async task frames: the generic Clock
        // sleep overload can trip Swift's task allocator during teardown.
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max }
        let (total, additionOverflow) = scaled.addingReportingOverflow(nanoseconds)
        return additionOverflow ? UInt64.max : total
    }

    static func remoteChildCandidateBudget(
        parentWaitMilliseconds: UInt64
    ) -> UInt32? {
        guard parentWaitMilliseconds > 1 else { return nil }
        let budget =
            parentWaitMilliseconds
            - max(1, parentWaitMilliseconds / 4)
        return UInt32(
            min(
            budget,
            UInt64(ChildCandidateRequestMessage.maximumBudgetMilliseconds)
        ))
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

    private func configuredParentPeer() -> AuthenticatedPeer? {
        guard let parentKey = configuration.parentEndpoint?.publicKey,
              let key = try? PeerKey(parentKey),
              case .parent? = hierarchyPeers[key]
        else { return nil }
        return hierarchySessions[key]
    }

    private func makeRequestID() -> UInt64 {
        repeat { nextRequestID &+= 1 } while nextRequestID == 0
        return nextRequestID
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
        CandidateAcquirer.mergePackages(current, received)
    }

}

extension Ivy {
    fileprivate func install(
        delegate: IvyDelegate,
        contentSource: (any IvyContentSource)?
    ) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
