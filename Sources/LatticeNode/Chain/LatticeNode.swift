import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256
import Crypto
import OrderedCollections

public enum NodeError: Error, CustomStringConvertible {
    case parentChainNotFound(String)
    case chainUnavailable(String)
    case chainNetworkNotRegistered(String)
    case chainSpecUnavailableForSubscription(String)
    case chainSpecExceedsFrameLimit(chainPath: [String], maxBlockSize: Int, requiredFrameSize: UInt64, maxFrameSize: UInt32)
    case emptyChainPath
    case corruptPersistedChainState(directory: String)
    case genesisStoreFailed(directory: String)
    case invalidGenesisBootstrapEntry(String)

    public var description: String {
        switch self {
        case .parentChainNotFound(let dir): return "Parent chain not found: \(dir)"
        case .chainUnavailable(let dir): return "Chain unavailable: \(dir)"
        case .chainNetworkNotRegistered(let dir): return "Chain network not registered: \(dir)"
        case .chainSpecUnavailableForSubscription(let dir): return "Chain spec unavailable for subscription: \(dir)"
        case .emptyChainPath: return "ChainNetwork requires a non-empty chainPath (the leaf is this chain's directory)"
        case .corruptPersistedChainState(let dir): return "Persisted chain state for \(dir) has undecodable block target (corrupt work); reindex required"
        case .genesisStoreFailed(let dir): return "Genesis content for \(dir) could not be stored durably"
        case .invalidGenesisBootstrapEntry(let cid): return "Genesis bootstrap entry does not hash to its CID: \(String(cid.prefix(16)))…"
        case .chainSpecExceedsFrameLimit(let chainPath, let maxBlockSize, let requiredFrameSize, let maxFrameSize):
            let path = chainPath.joined(separator: "/")
            return "Chain \(path) maxBlockSize \(maxBlockSize) requires Ivy maxFrameSize >= \(requiredFrameSize) bytes; configured maxFrameSize is \(maxFrameSize). Raise --max-frame-size to subscribe."
        }
    }
}

enum ChainHealthRecovery: Sendable, Equatable {
    case committedTipFrontier
}

enum ChainHealthState: Sendable, Equatable {
    case degraded(reason: String, sinceUnixMillis: Int64, recovery: ChainHealthRecovery)
    case fatal(reason: String, sinceUnixMillis: Int64)

    var isUnavailable: Bool { true }

    var isRecoverable: Bool {
        if case .degraded = self { return true }
        return false
    }

    var recovery: ChainHealthRecovery? {
        if case .degraded(_, _, let recovery) = self { return recovery }
        return nil
    }

    var reason: String {
        switch self {
        case .degraded(let reason, _, _), .fatal(let reason, _):
            return reason
        }
    }

    var label: String {
        switch self {
        case .degraded:
            return "degraded"
        case .fatal:
            return "fatal"
        }
    }
}

private struct CoinbaseAuthorityFile: Codable {
    let publicKey: String
    let privateKey: String
}

private func loadOrCreateCoinbaseAuthority(storagePath: URL) -> MinerIdentity {
    let url = storagePath.appendingPathComponent("coinbase-authority.json")
    let decoder = JSONDecoder()
    if let data = try? Data(contentsOf: url),
       let file = try? decoder.decode(CoinbaseAuthorityFile.self, from: data),
       !file.publicKey.isEmpty,
       !file.privateKey.isEmpty {
        return MinerIdentity(publicKeyHex: file.publicKey, privateKeyHex: file.privateKey)
    }

    let keyPair = CryptoUtils.generateKeyPair()
    let file = CoinbaseAuthorityFile(publicKey: keyPair.publicKey, privateKey: keyPair.privateKey)
    do {
        try FileManager.default.createDirectory(at: storagePath, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: [.atomic])
    } catch {
        NodeLogger("startup").warn("Failed to persist coinbase authority at \(url.path): \(error)")
    }
    return MinerIdentity(publicKeyHex: keyPair.publicKey, privateKeyHex: keyPair.privateKey)
}

private final class ChainMutationGateCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

public actor LatticeNode: ChainNetworkDelegate {
    public var config: LatticeNodeConfig
    public let lattice: Lattice
    public let genesisConfig: GenesisConfig
    public let genesisResult: GenesisResult
    /// Process-per-chain supervisor. Non-nil when `--supervise-children`
    /// is set: deploying a child chain spawns + supervises one OS process for it,
    /// and `stop()` quiesces the whole subtree. See docs/design/process-supervisor.md.
    public let childSupervisor: ChildProcessSupervisor?
    /// Parent RPC port base for deriving a supervised child's RPC port deterministically.
    let childRPCBasePort: UInt16?
    /// Config a supervised child inherits from this parent, as argv pairs.
    let childInheritedArguments: [String]
    /// This node's own spawn-cert chain (root→…→self), delivered at spawn. Empty
    /// for a federated/root node. Presented to peers after identify (2b).
    public let spawnCertChain: [SpawnCertificate]
    /// Node-wide spawn-tree trust: verifies peers' presented chains against this
    /// node's tree root and records each peer's proven scope. See SpawnTrust.
    public let spawnTrust: SpawnTrust
    /// serves a chain block's authoritative fork-choice weight to
    /// verified descendants (and, in 2c-c, requests an ancestor's weight to feed
    /// the inherited-weight provider). See ConsensusProvider.
    public private(set) var consensusProvider: ConsensusProvider!
    /// Same-chain peer bootstrap: a followed child queries a parent for its
    /// connected children's chain endpoints; a parent serves them from the live
    /// spawn-trusted subscriber set. See ChildPeerProvider.
    public private(set) var childPeerProvider: ChildPeerProvider!
    /// The `(directory, pubkey@host:port)` a connected child advertised over a
    /// parent chain's link, keyed by the (parent-subscription) peer that
    /// advertised. Served to a follower asking for `directory`; the directory is
    /// self-declared and verified on dial. Evicted when the peer disconnects.
    var advertisedChildEndpoints: [PeerID: (directory: String, endpoint: String, rpcUrl: String?)] = [:]
    /// This child's own genesis CAS entries (from `--genesis-hex` boot), retained so it can
    /// re-advertise its genesis to its parent(s) — the parent durably re-serves them so later
    /// followers can resolve the genesis even after the original deployer leaves. Empty on a
    /// root/Nexus node (no parent to advertise to).
    var childGenesisBootstrapEntries: [(cid: String, data: Data)] = []
    func setChildGenesisBootstrapEntries(_ entries: [(cid: String, data: Data)]) { childGenesisBootstrapEntries = entries }
    /// the parent-subscription link(s) as node-managed trusted
    /// consensus channels, keyed by child directory. The `ivy` lets us send
    /// cw-requests to the parent; `peer` is captured when the parent identifies.
    /// Converges the bespoke siloed parent subscription toward the trusted-peer
    /// model (the consumer + demolition build on this).
    var parentConsensusLinks: [String: (ivy: Ivy, peer: PeerID?)] = [:]
    var networks: [String: ChainNetwork]
    /// Per-process child only: a fetcher into the parent chain's P2P subscription,
    /// keyed by the child directory. A per-process child validates blocks that
    /// carry cross-chain proofs against the parent's state (e.g. a withdrawal
    /// proves a receipt in `parentState.receiptState`), but its own broker holds
    /// only the parentState ROOT, not the subtree. This fetcher lets block
    /// validation pull the missing parent-state nodes from the parent over P2P.
    /// Set by `startParentChainSubscription` once the parent Ivy is up.
    var parentStateFetchers: [String: Fetcher] = [:]
    func setParentStateFetcher(directory: String, fetcher: Fetcher) {
        parentStateFetchers[directory] = fetcher
    }
    var persisters: [String: ChainStatePersister]
    var blocksSinceLastPersist: [String: UInt64]
    var recentPeerBlocks: OrderedDictionary<String, ContinuousClock.Instant>
    /// Dedup window for bare block ANNOUNCEMENTS (CID-only hints). Kept separate
    /// from `recentPeerBlocks` (which is primed only by VALIDATED block bytes):
    /// an announcement carries no bytes, so priming the validated-bytes map from
    /// it would let a peer announce a CID it doesn't possess and dedup-suppress
    /// the genuine full block arriving from an honest peer within the window.
    /// Same discipline the childBlock path documents (recordChildBlockSeen).
    var recentBlockAnnounces: OrderedDictionary<String, ContinuousClock.Instant>
    /// Latest announced tip (CID, height) per peer public key, keyed by chain address.
    /// Used to pick the best connected peer when retrying sync after a failure.
    var knownPeerTips: [String: [String: (tipCID: String, height: UInt64)]] = [:]

    /// H2: per-chain cap on `knownPeerTips` so a Sybil/churn flood of distinct
    /// peer keys can't grow the map without bound (entries are also pruned on
    /// disconnect via `didDisconnectPeer`, but a peer can announce a tip without
    /// staying connected, so the insert path needs its own ceiling). Sized at a
    /// few multiples of the connection cap per chain: well above any honest
    /// connected set, but still O(maxPeers).
    var maxKnownPeerTipsPerChain: Int { max(64, config.maxPeerConnections * 4) }

    func recordPeerTip(chainPath: [String], peerKey: String, tipCID: String, height: UInt64) {
        let key = chainKey(forPath: chainPath)
        knownPeerTips[key, default: [:]][peerKey] = (tipCID: tipCID, height: height)
        // Cap per-chain growth. We only ever exceed the cap by one (single
        // insert above), so evict one entry: drop the lowest-height tip, which
        // is the least useful for picking the best peer to sync from. Never
        // evict the peer we just recorded (it is the freshest, and at the cap it
        // is not the global minimum unless every entry ties — in which case any
        // victim is fine and we explicitly skip `peerKey`).
        if var tips = knownPeerTips[key], tips.count > maxKnownPeerTipsPerChain {
            if let victim = tips
                .filter({ $0.key != peerKey })
                .min(by: { $0.value.height < $1.value.height })?.key {
                tips.removeValue(forKey: victim)
                knownPeerTips[key] = tips
            }
        }
    }

    func recordPeerTip(directory: String, peerKey: String, tipCID: String, height: UInt64) {
        recordPeerTip(chainPath: chainPath(forDirectory: directory), peerKey: peerKey, tipCID: tipCID, height: height)
    }

    /// H2: prune all per-peer state for a disconnected peer so churn/Sybil
    /// connect-disconnect cycles can't leave residue in the unbounded maps.
    /// Removes the peer's tip from every chain's `knownPeerTips`. The Tally
    /// ledger reset happens at the ChainNetwork disconnect handler (it owns the
    /// shared Ivy/Tally), so this method is node-state only.
    func didDisconnectPeer(publicKey: String) {
        // Drop any recorded spawn-tree trust so it never outlives the connection
        // (a reconnect re-classifies on its next identify).
        Task { [spawnTrust] in await spawnTrust.forget(PeerID(publicKey: publicKey)) }
        // Drop any chain endpoint this peer advertised — eviction is by disconnect,
        // so a stale endpoint is never served after the subscriber is gone.
        advertisedChildEndpoints.removeValue(forKey: PeerID(publicKey: publicKey))
        for key in Array(knownPeerTips.keys) {
            knownPeerTips[key]?.removeValue(forKey: publicKey)
            if knownPeerTips[key]?.isEmpty == true {
                knownPeerTips.removeValue(forKey: key)
            }
        }
    }

    /// M2: record a HARD protocol violation (provable fraud: invalid PoW, CID
    /// mismatch, oversized block). Repeats escalate to a durable ban via the same
    /// PeerBanStore path the mempool-full flood uses; a single offense keeps the
    /// existing disconnect-only behavior at the call site. Returns true once the
    /// peer was banned so the caller can skip a redundant transient disconnect.
    @discardableResult
    func recordHardFault(peer: PeerID, network: ChainNetwork) async -> Bool {
        let count = hardFaultCounts.increment(peer)
        guard count >= hardFaultBanThreshold else { return false }
        hardFaultCounts.reset(peer)
        await chainNetwork(network, banPeer: peer)
        return true
    }

    /// Tips that repeatedly failed to sync — excluded from headers-first peer selection.
    var failedSyncTips: Set<String> = []
    /// "peerTip|localTip" pairs for synced chains that were fully downloaded and
    /// REFUSED admission (not more work / tiebreak kept local). While the local
    /// tip is unchanged, re-syncing the same refused tip is pure churn: it
    /// re-downloads the whole chain every announce round and drains the peer's
    /// getHeaders rate budget, starving the peer's own catch-up sync.
    var refusedSyncTipPairs: Set<String> = []
    var chainHealth: [String: ChainHealthState] = [:]
    var unhealthyChains: Set<String> {
        Set(chainHealth.compactMap { key, state in state.isUnavailable ? key : nil })
    }

    func recordFailedSyncTip(_ tipCID: String) {
        failedSyncTips.insert(tipCID)
    }

    private func healthTimestampMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func markChainUnhealthy(chainPath: [String], reason: String) async {
        let key = chainKey(forPath: chainPath)
        chainHealth[key] = .fatal(reason: reason, sinceUnixMillis: healthTimestampMillis())
        let display = chainPath.joined(separator: "/")
        NodeLogger("recovery").error("\(display): \(reason); stopping chain network")
        if let network = network(forPath: chainPath) {
            await network.stop()
        }
    }

    func markChainUnhealthy(directory: String, reason: String) async {
        let path = chainAddress(forDirectory: directory)?.components ?? resolvedChainPath(for: directory)
        await markChainUnhealthy(chainPath: path, reason: reason)
    }

    func markChainStorageDegraded(chainPath: [String], reason: String) async {
        let key = chainKey(forPath: chainPath)
        if case .fatal? = chainHealth[key] { return }
        chainHealth[key] = .degraded(
            reason: reason,
            sinceUnixMillis: healthTimestampMillis(),
            recovery: .committedTipFrontier
        )
        let display = chainPath.joined(separator: "/")
        NodeLogger("recovery").error("\(display): \(reason); stopping chain network until committed tip frontier resolves")
        if let network = network(forPath: chainPath) {
            await network.stop()
        }
    }

    func markChainStorageDegraded(directory: String, reason: String) async {
        let path = chainAddress(forDirectory: directory)?.components ?? resolvedChainPath(for: directory)
        await markChainStorageDegraded(chainPath: path, reason: reason)
    }

    func markChainHealthy(chainPath: [String]) {
        chainHealth.removeValue(forKey: chainKey(forPath: chainPath))
    }
    var peerBlockCounts: OrderedDictionary<PeerID, (count: Int, windowStart: ContinuousClock.Instant)>
    /// CIDs currently being validated by `processBlockAndRecoverReorg`. The actor
    /// suspends during `lattice.processBlockHeader`, so a gossip echo of a block
    /// we just submitted (or just received) can re-enter while the first call is
    /// still in flight — `chain.contains` can't see it until validation finishes.
    /// Tracking in-flight CIDs here lets the re-entrant call short-circuit
    /// instead of burning ~1.5s re-validating a block that will be rejected as a
    /// duplicate anyway.
    var inFlightBlockCIDs: Set<String> = []
    /// M2: per-peer count of HARD protocol violations (invalid PoW, CID
    /// mismatch, oversized block). These are unforgeable fraud — unlike soft
    /// fork-divergence rejections — so a peer that repeats them is escalated to
    /// a durable cross-restart ban (same mechanism as the mempool-full flood
    /// path) instead of getting only a transient disconnect. LRU-bounded so a
    /// spoofed-key flood can't evict the real offender's accumulating count.
    var hardFaultCounts = LRUCounter(maxEntries: 2_048)
    /// Hard-fault count that triggers a durable ban. Low (a handful) because each
    /// of these is provable fraud, not a benign race; honest peers never hit it.
    var hardFaultBanThreshold: Int { config.tuning.rateLimit.hardFaultBanThreshold }
    // Max concurrent gossip blocks being validated. Beyond this the block is
    // dropped — it will be re-announced shortly and processed when the queue drains.
    var maxConcurrentGossipValidations: Int { config.tuning.gossip.maxConcurrentBlockValidations }
    // The rate limiter exists to bound validation cost from a misbehaving
    // peer; it is not meant to throttle legitimate gossip. `validateNexus`
    // costs ~25ms/block, so even 30/s is bounded (<=75% of one core). Setting
    // this below burst block-production rates silently strands catch-up sync.
    static let maxBlocksPerPeerPerWindow = 300
    var peerRateWindow: Duration { config.tuning.rateLimit.peerRateWindow }
    public nonisolated static let subscriptionFrameOverheadBytes: UInt32 = 1024
    struct PendingGossipBlock {
        let cid: String
        let data: Data
        let network: ChainNetwork
        let peer: PeerID
    }
    var pendingGossipBlocks: [ObjectIdentifier: [PendingGossipBlock]] = [:]

    var syncTasks: [String: Task<Void, Never>] = [:]
    /// Height gap of each in-flight chain sync. Shallow catch-ups
    /// (≤ shallowSyncThreshold) keep that chain readable and mining; only
    /// deep/initial syncs gate reads via `isChainUnavailable`.
    var activeSyncGaps: [String: UInt64] = [:]
    var peerRefreshTask: Task<Void, Never>?
    private var mempoolPruneTask: Task<Void, Never>?
    private var pinReannounceTask: Task<Void, Never>?
    private var evictionTask: Task<Void, Never>?
    private var storageMaintenanceTask: Task<Void, Never>?
    private var unhealthyRecoveryTask: Task<Void, Never>?
    // Item 2 (supervisor reconciler): the continuous reconcile loop and per-child
    // health-grace tracking (first time a tracked-but-RPC-dead child was seen wedged).
    var supervisedReconcileTask: Task<Void, Never>?
    var supervisedRPCDownSince: [String: Date] = [:]
    /// Per-followed-child count of consecutive failed genesis-resolve attempts, so a
    /// garbage/withheld announced CID drops to a slow re-probe instead of a hot loop.
    var followedGenesisResolveFailures: [String: Int] = [:]
    public var feeEstimators: [String: FeeEstimator]
    public let subscriptions: SubscriptionManager
    public let anchorPeers: AnchorPeers
    public let peerStore: PeerStore
    public let metrics: NodeMetrics
    nonisolated let rateLimiter: RPCRateLimiter
    /// Persistent, cross-restart peer ban store. A peer banned for repeated
    /// abuse stays banned for `banDuration` even across a node restart so a
    /// flooding peer cannot simply wait for (or trigger) a restart to clear
    /// its penalty. Checked at peer-connect; populated by repeated admission
    /// failures (mempool-full flooding).
    public let banStore: PeerBanStore
    public var stateStores: [String: StateStore]
    var tipCaches: [String: TipCache]
    var postStateCaches: [String: PostStateCache]
    private var chainMutationGate: [String: Task<Void, Never>] = [:]

    struct CachedTemplate {
        let tipCID: String
        let mempoolGeneration: UInt64
        let builtBlock: Block
        let builtData: Data
        let storedCandidateVolumeRoots: [String]
        let effectiveTarget: UInt256
        let childBlocksHex: [String: String]
        let timestamp: Int64
    }

    var templateCache: [String: CachedTemplate] = [:]
    var mempoolNonceFloorRefreshKeys: [String: (tipCID: String, mempoolGeneration: UInt64)] = [:]
    public struct DeployedChainMetadata: Sendable, Codable {
        public let chainPath: [String]
        public let directory: String
        public let parentDirectory: String
        public let genesisHash: String
        public let genesisHex: String
        public let timestamp: Int64
        // Contract 4 (supervised lifecycle): set when the operator explicitly detaches
        // this child via unregister-rpc. A detached child is never auto-respawned on
        // restart or by idempotent deploy; re-deploying the same path clears it.
        public var detached: Bool
        // Subscription provenance: a FOLLOWED child is one this node did NOT deploy but chose
        // to follow (`chain follow`). Its genesisHash/genesisHex start empty and are resolved
        // from the parent's on-chain GenesisState + CAS on the first reconcile pass. A deployed
        // child has them at record time, so followed=false and resolution is skipped.
        public var followed: Bool
        // The 14-bit port slot this child was assigned on its FIRST successful spawn,
        // persisted so the child's ports are a stable function of its OWN identity — not
        // of the (attacker-influenceable, permissionlessly-grown) set of sibling
        // announcements. Without this, recomputing the slot from the live collision set
        // each sweep lets a colliding announcement shift a healthy victim's port and
        // force-restart it. nil until first assignment; assigned by probing a free slot.
        public var portSlot: UInt16?

        public init(chainPath: [String], directory: String, parentDirectory: String,
                    genesisHash: String, genesisHex: String, timestamp: Int64,
                    detached: Bool = false, followed: Bool = false, portSlot: UInt16? = nil) {
            self.chainPath = chainPath
            self.directory = directory
            self.parentDirectory = parentDirectory
            self.genesisHash = genesisHash
            self.genesisHex = genesisHex
            self.timestamp = timestamp
            self.detached = detached
            self.followed = followed
            self.portSlot = portSlot
        }

        // Persisted files are protocol formats, not internal structs: decode tolerantly.
        // A NEW field (here `detached`) must default when absent so metadata written by
        // an older schema still decodes — Swift's synthesized Codable does NOT apply
        // stored-property defaults to missing non-optional keys (it throws keyNotFound),
        // which would otherwise silently wipe a parent's deployed-child set on upgrade.
        enum CodingKeys: String, CodingKey {
            case chainPath, directory, parentDirectory, genesisHash, genesisHex, timestamp, detached, followed, portSlot
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chainPath = try c.decode([String].self, forKey: .chainPath)
            directory = try c.decode(String.self, forKey: .directory)
            parentDirectory = try c.decode(String.self, forKey: .parentDirectory)
            genesisHash = try c.decode(String.self, forKey: .genesisHash)
            genesisHex = try c.decode(String.self, forKey: .genesisHex)
            timestamp = try c.decode(Int64.self, forKey: .timestamp)
            detached = try c.decodeIfPresent(Bool.self, forKey: .detached) ?? false
            followed = try c.decodeIfPresent(Bool.self, forKey: .followed) ?? false
            portSlot = try c.decodeIfPresent(UInt16.self, forKey: .portSlot)
        }
    }
    var deployedChildChains: [String: DeployedChainMetadata]
    var registeredRPCEndpoints: [String: String]
    var registeredRPCAuthTokens: [String: String]

    public func registerRPCEndpoint(chainPath: [String], endpoint: String, authToken: String? = nil) {
        let key = chainKey(forPath: chainPath)
        registeredRPCEndpoints[key] = endpoint
        if let token = authToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            registeredRPCAuthTokens[key] = token
        }
        persistRegisteredRPCRegistrations()
    }

    public func unregisterRPCEndpoint(chainPath: [String]) {
        let key = chainKey(forPath: chainPath)
        registeredRPCEndpoints.removeValue(forKey: key)
        registeredRPCAuthTokens.removeValue(forKey: key)
        persistRegisteredRPCRegistrations()
    }

    public func registeredRPCMap() -> [String: String] {
        registeredRPCEndpoints
    }

    /// Direct children of `parentPath` this node currently serves — i.e. the supervised /
    /// followed children whose loopback RPC is in the registered-RPC map — as
    /// (apiURL, authToken?). Used to auto-include them in the merged mining template so a
    /// coordinator mines "this node + whatever it follows" with no explicit --child-node.
    /// Registrations are loopback-validated at ingress; a defensive subset check keeps a
    /// stray non-loopback entry from poisoning the template's SSRF-safe fan-out.
    func registeredDirectChildEndpoints(parentPath: [String]) -> [(url: String, auth: String?)] {
        func isLoopbackAPIBase(_ s: String) -> Bool {
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = u.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "::1" || host == "localhost"
        }
        var out: [(url: String, auth: String?)] = []
        for (key, endpoint) in registeredRPCEndpoints {
            let path = key.split(separator: "/").map(String.init)
            guard path.count == parentPath.count + 1,
                  Array(path.prefix(parentPath.count)) == parentPath,
                  isLoopbackAPIBase(endpoint) else { continue }
            out.append((url: endpoint, auth: registeredRPCAuthTokens[key]))
        }
        return out
    }

    public func registeredRPCEndpoint(chainPath: [String]) -> String? {
        registeredRPCEndpoints[chainKey(forPath: chainPath)]
    }

    public func registeredRPCAuthToken(chainPath: [String]) -> String? {
        registeredRPCAuthTokens[chainKey(forPath: chainPath)]
    }
    /// F5-4 (Hierarchical GHOST): verified proof contribution accumulator retained
    /// for proof accounting and compatibility. Fork choice is driven by
    /// `liveInheritedWeightIndexInit`, which derives the inherited term fresh from
    /// the parent projection at decision time.
    var inheritedWeightStoreInit: [String: Task<InheritedWeightStore, Never>] = [:]
    var liveInheritedWeightIndexInit: [String: Task<LiveInheritedWeightIndex, Never>] = [:]
    public let nodeAddress: String
    public let coinbaseAuthority: MinerIdentity
    public let sharedDiskBroker: DiskBroker

    /// Test-only seam for the `chain_tip:<key>` meta write. `sharedDiskBroker` is a
    /// concrete `final class DiskBroker` from an external package and isn't
    /// injectable, so tests install this hook to force the meta write to throw and
    /// exercise the non-silent failure path in `persistChainState`. Production leaves
    /// it nil and writes straight through to `sharedDiskBroker.setChainMeta`.
    var setChainMetaHook: ((_ key: String, _ value: String) throws -> Void)?
    /// SHADOW state refcount-index (reference-counting retention foundation): default
    /// OFF so it adds ZERO per-accept cost on the production hot path. When enabled
    /// the shadow computes the membership-faithful prev/post state node-sets + their
    /// edges per accept (~O(delta)) and increments the durable edge refcounts; this is
    /// pure validation overhead until retention is actually cut over to it. Enabled
    /// explicitly by the shadow proof tests (and a future cutover).
    var stateDeathIndexShadowEnabled = false
    /// PRODUCTION VERIFICATION gate for the SHADOW refcount index (default OFF,
    /// independent of `stateDeathIndexShadowEnabled`). When BOTH are ON, each prune
    /// additionally recomputes the live DiskBroker reachability ground truth and
    /// ASSERTS the refcount index's reclaim verdict agrees with it — the in-production
    /// proof that the eventual reclamation flip is safe. It drives NO unpin: the live
    /// object-grain pin/CTE stays the sole retention mechanism. Best-effort, never
    /// perturbs prune.
    var stateRefcountVerifyAgainstReachability = false
    /// Production state-retention driver. When ON, the object-grain consensus pin
    /// set drops `postState.rawCID`; the state frontier is retained instead by the
    /// storage layer's named retained-root scope, advanced as one atomic root set.
    /// Non-state content (blockHash closure, tx bodies, children, spec) stays
    /// object-grain.
    var stateRetentionViaRetainedRoots = true
    /// Legacy refcount-retention driver. Kept as an explicit test/shadow facility,
    /// but no longer the production default: retained-root scopes are simpler and
    /// avoid per-node pin ownership. When tests turn this on, the old per-node
    /// refcount path still drops `postState.rawCID` from consensus pins.
    var stateRetentionViaRefcount = false
    /// Perf cache for `recordStateRefcountOnAccept` (SHADOW; populated only when the
    /// shadow is enabled). The accept path already resolves the post-state frontier
    /// in `storeAcceptedStateDiffRoots`; we capture that already-resolved node-set +
    /// edges there (`stateRefcountPendingPost`) so the accept hook consumes it instead
    /// of re-resolving the post frontier. After the hook runs, the consumed post graph
    /// becomes `stateRefcountLastPost` — the NEXT block's prev (prevState_{N+1} ==
    /// postState_N), eliminating the redundant prev re-resolution too. Keyed by
    /// `chainKey(forDirectory:)`.
    var stateRefcountPendingPost: [String: (cid: String, graph: StateGraph)] = [:]
    var stateRefcountLastPost: [String: (cid: String, graph: StateGraph)] = [:]
    /// Chains whose genesis frontier has already been refcount-seeded at genesis-commit
    /// time (`seedGenesisStateRefcountIfNeeded`, run from `start()`). When a chain is in
    /// this set the first non-genesis accept (height 1) SKIPS its redundant genesis
    /// re-seed/re-pin — the commit-time seed already recorded height 0 and pinned the
    /// genesis nodes. Keyed by `chainKey(forDirectory:)`. Empty when the commit-seed did
    /// not run (flags off at start, or the seed is enabled only later in a test), so the
    /// height-1 path still seeds genesis in that case.
    var genesisRefcountSeeded: Set<String> = []

    /// Route the canonical-tip meta write through the test seam when installed,
    /// otherwise through the real DiskBroker. Throws on failure so callers cannot
    /// treat a lost meta write as success.
    func writeChainMeta(key: String, value: String) async throws {
        if let hook = setChainMetaHook {
            try hook(key, value)
        } else {
            try await sharedDiskBroker.setChainMeta(key: key, value: value)
        }
    }

    // MARK: - Test-only seams 

    /// Install/replace the `setChainMetaHook` so a test can force the canonical-tip
    /// meta write to fail and exercise the non-silent persist path.
    func installSetChainMetaHookForTests(_ hook: @escaping (_ key: String, _ value: String) throws -> Void) {
        setChainMetaHook = hook
    }

    func setBlocksSinceLastPersistForTests(key: String, value: UInt64) {
        blocksSinceLastPersist[key] = value
    }

    func blocksSinceLastPersistForTests(key: String) -> UInt64? {
        blocksSinceLastPersist[key]
    }
    public let sharedTally: Tally
    /// H7: one node-wide mempool byte budget shared by every chain's NodeMempool,
    /// so the byte cap bounds total node memory across all chains (including ones
    /// registered after startup) rather than per-chain independently.
    let sharedMempoolByteLimiter: MempoolByteLimiter

    var validatorPinReleaserOverride: (any ValidatorPinReleaser)?

    // nextTarget for each known block CID. Populated on block acceptance,
    // pruned on persist. Allows nonisolated PoW validation to check claimed
    // target without a DiskBroker read or crossing the actor boundary.
    private let nextTargetLock = NSLock()
    nonisolated(unsafe) private var nextTargetByBlockCID: [String: UInt256] = [:]

    nonisolated func cacheNextTarget(blockCID: String, value: UInt256) {
        nextTargetLock.withLock { nextTargetByBlockCID[blockCID] = value }
    }

    nonisolated func cachedNextTarget(for blockCID: String) -> UInt256? {
        nextTargetLock.withLock { nextTargetByBlockCID[blockCID] }
    }

    func pruneNextTargetCache(keepingCIDs validCIDs: Set<String>) {
        nextTargetLock.withLock {
            nextTargetByBlockCID = nextTargetByBlockCID.filter { validCIDs.contains($0.key) }
        }
    }

    func withChainMutation<T>(_ key: String, _ body: () async throws -> sending T) async rethrows -> sending T {
        let previous = chainMutationGate[key]
        let completion = ChainMutationGateCompletion()
        let current = Task<Void, Never> {
            await completion.wait()
        }
        chainMutationGate[key] = current

        if let previous {
            await previous.value
        }

        defer { completion.complete() }
        return try await body()
    }

    func cachedTemplate(forKey key: String) -> CachedTemplate? {
        templateCache[key]
    }

    func storeTemplate(_ template: CachedTemplate, forKey key: String) {
        templateCache[key] = template
    }

    func removeCachedTemplate(forKey key: String) {
        templateCache.removeValue(forKey: key)
    }

    // MARK: - Initialization

    public typealias GenesisBuilder = (GenesisConfig, Fetcher) async throws -> Block

    public init(
        config: LatticeNodeConfig,
        genesisConfig: GenesisConfig,
        genesisBuilder: GenesisBuilder? = nil,
        prebuiltGenesisBlock: Block? = nil,
        prebuiltGenesisTransactions: [Transaction]? = nil,
        superviseChildren: Bool = false,
        childRPCBasePort: UInt16? = nil,
        childInheritedArguments: [String] = [],
        spawnCertChain: [SpawnCertificate] = []
    ) async throws {
        self.config = config
        self.genesisConfig = genesisConfig
        self.childSupervisor = superviseChildren ? ChildProcessSupervisor() : nil
        self.childRPCBasePort = childRPCBasePort
        self.childInheritedArguments = childInheritedArguments
        self.spawnCertChain = spawnCertChain
        // The tree root every trusted chain must terminate at is the issuer of our
        // own chain's first link; a node with no chain trusts no one (federated).
        self.spawnTrust = SpawnTrust(trustedRoot: spawnCertChain.first?.issuerPublicKey)

        let resourcesWithIdentity = config.resources.withIdentity(publicKey: config.publicKey)
        let chainCount = 1

        let fm = FileManager.default
        let volumesDir = config.storagePath
        if !fm.fileExists(atPath: volumesDir.path) {
            try fm.createDirectory(at: volumesDir, withIntermediateDirectories: true)
        }
        let dbPath = volumesDir.appendingPathComponent("volumes.sqlite").path
        // I4 store-then-pin grace: evictUnpinned protects content younger than this
        // many seconds so the periodic sweep can't reclaim a freshly-stored block
        // before its retention pin lands. The default is conservative (covers any
        // realistic store->pin latency with wide margin); it is tunable via env so
        // operators and fast tests (which mine past retention in seconds) can lower
        // it. Read here directly, mirroring RETENTION_DEPTH/EVICTION_INTERVAL env knobs.
        let evictGraceSeconds = ProcessInfo.processInfo.environment["EVICT_GRACE_SECONDS"].flatMap(Int.init) ?? 600
        let disk = try DiskBroker(path: dbPath, evictUnpinnedGraceSeconds: evictGraceSeconds)
        self.sharedDiskBroker = disk

        let tally = Tally(config: TallyConfig(maxPeers: config.maxPeerConnections))
        self.sharedTally = tally

        // H7: one shared node-wide mempool byte budget for every chain (0 = unbounded).
        let mempoolByteLimiter = MempoolByteLimiter(
            maxBytes: resourcesWithIdentity.mempoolByteBudgetBytes > 0 ? resourcesWithIdentity.mempoolByteBudgetBytes : nil
        )
        self.sharedMempoolByteLimiter = mempoolByteLimiter

        let nexusNetwork = try await ChainNetwork(
            chainPath: config.fullChainPath ?? [genesisConfig.directory],
            config: IvyConfig(
                publicKey: config.p2pPublicKey,
                listenPort: config.listenPort,
                bootstrapPeers: config.bootstrapPeers,
                enableLocalDiscovery: config.enableLocalDiscovery,
                stunServers: [],
                signingKey: Data(hex: config.privateKey) ?? Data(),
                baseThresholdMultiplier: UInt64.max,
                maxFrameSize: config.maxFrameSize,
                minPeerKeyBits: config.minPeerKeyBits,
                externalAddress: config.externalAddress,
                relayEnabled: config.relayEnabled,
                knownRelays: config.knownRelays
            ),
            resources: resourcesWithIdentity,
            chainCount: chainCount,
            maxPeerConnections: config.maxPeerConnections,
            minFeeRate: config.minFeeRate,
            gossipTuning: config.tuning.gossip,
            rateLimitTuning: config.tuning.rateLimit,
            syncTuning: config.tuning.sync,
            sharedDiskBroker: disk,
            sharedTally: tally,
            mempoolByteLimiter: mempoolByteLimiter
        )


        let persister = ChainStatePersister(
            storagePath: config.storagePath,
            directory: genesisConfig.directory
        )
        let persisted = try? await persister.load()

        // CFC-A3 : fail closed on a corrupt persisted artifact. A loaded
        // chain_state.json whose block target is present-but-undecodable is
        // corruption: ChainState.restore/resetFrom would map it to UInt256.zero
        // work, silently understating accumulated work and inviting a spurious
        // fork. Detect it on the loaded snapshot BEFORE the rebuild/fast-path
        // decision — rebuilding around a corrupt durable artifact would mask the
        // corruption rather than surface it. Refuse to start so the operator
        // reindexes. (Throwing here halts before any chain state is projected;
        // `self`/markChainUnhealthy aren't available yet at this point in init.)
        if let persisted, Self.persistedHasUndecodableTarget(persisted) {
            NodeLogger("init").error("\(genesisConfig.directory): persisted chain_state.json has undecodable block target (corrupt work); refusing to start — reindex required")
            throw NodeError.corruptPersistedChainState(directory: genesisConfig.directory)
        }

        let buildGenesisBlock: (Fetcher) async throws -> Block = { fetcher in
            // Per-process child chain bootstrap: rebuild genesis from scratch using the
            // reconstructed transactions (from genesis hex TX body entries). This produces
            // a fully-inline genesis block with all state sub-volumes, so storeBlockRecursively
            // persists the state trie to DiskBroker and validation works without parent help.
            if let prebuilt = prebuiltGenesisBlock {
                let txs = prebuiltGenesisTransactions ?? []
                return try await BlockBuilder.buildGenesis(
                    spec: genesisConfig.spec,
                    transactions: txs,
                    timestamp: prebuilt.timestamp,
                    target: prebuilt.target,
                    fetcher: fetcher
                )
            }
            if let genesisBuilder {
                return try await genesisBuilder(genesisConfig, fetcher)
            }
            return try await BlockBuilder.buildGenesis(
                spec: genesisConfig.spec,
                timestamp: genesisConfig.timestamp,
                target: genesisConfig.target,
                fetcher: fetcher
            )
        }

        let genesis: GenesisResult
        // The DiskBroker chain_tip meta (volumes.sqlite) and chain_state.json are
        // coarse BOOTSTRAP CACHES, not the canonical authority: this init seeds
        // ChainState from the (possibly lagging or absent) meta tip, then
        // start()→recoverFromCAS rolls ChainState FORWARD to the durable StateStore
        // (state.db) tip, which is the canonical restart authority. The meta is
        // written in the same SQLite file as cas_data (so the cache and its
        // referenced blocks stay mutually consistent) and on the persistInterval
        // cadence (so it can lag the per-block StateStore tip). chain_state.json is
        // a fast startup cache: if its tip matches the meta tip we skip the rebuild;
        // if it's stale or missing we rebuild from the meta instead of falling back
        // to genesis (which throws away valid persisted blocks). Either way recovery
        // overrides this bootstrap with the StateStore tip.
        let directory = genesisConfig.directory
        let bootKey = (config.fullChainPath ?? [directory]).joined(separator: "/")
        let diskMetaTip = await disk.getChainMeta(key: "chain_tip:\(bootKey)")
        let resolvedPersisted: PersistedChainState?
        if let metaTip = diskMetaTip {
            if let cached = persisted,
               cached.chainTip == metaTip,
               await LatticeNode.isPersistedChainStateUsable(cached, diskBroker: disk) {
                // Fast path: chain_state.json is current.
                resolvedPersisted = cached
            } else {
                // chain_state.json is stale or missing — rebuild from DiskBroker.
                NodeLogger("init").info("Rebuilding chain state from DiskBroker (meta tip=\(String(metaTip.prefix(16)))…)")
                let rebuilt = await LatticeNode.rebuildChainState(
                    tipCID: metaTip,
                    diskBroker: disk,
                    retentionDepth: config.retentionDepth
                )
                if let rebuilt,
                   await LatticeNode.isPersistedChainStateUsable(rebuilt, diskBroker: disk) {
                    resolvedPersisted = rebuilt
                } else {
                    NodeLogger("init").warn("Discarding persisted chain state: tip or frontier roots are missing from volumes.sqlite — starting from genesis")
                    resolvedPersisted = nil
                }
            }
        } else {
            // Fresh install (no chain_meta yet): fall back to
            // chain_state.json with the existing hasVolume safety check.
            let usable: Bool
            if let persisted {
                usable = await LatticeNode.isPersistedChainStateUsable(persisted, diskBroker: disk)
            } else {
                usable = false
            }
            resolvedPersisted = (persisted != nil && usable) ? persisted : nil
            if persisted != nil && !usable {
                NodeLogger("init").warn("Discarding chain_state.json: tip or frontier roots not found in volumes.sqlite — starting from genesis")
            }
        }

        try await Self.seedEmptyStateVolume(network: nexusNetwork)

        // CFC-A3 : fail closed on corrupted persisted work. A block whose
        // stored target string is present-but-undecodable would be silently
        // mapped to UInt256.zero work by ChainState.restore/resetFrom, understating
        // this chain's accumulated work and inviting a spurious fork. Do NOT restore
        // onto a zeroed tip and do NOT silently fall back to genesis (that discards a
        // real chain): refuse to start so the operator reindexes. Throwing from init
        // halts the node before any chain state is projected (markChainUnhealthy is a
        // post-init runtime control and `self` is not yet available here).
        if let resolvedPersisted, Self.persistedHasUndecodableTarget(resolvedPersisted) {
            NodeLogger("init").error("\(directory): persisted chain state has undecodable block target (corrupt work); refusing to start — reindex required")
            throw NodeError.corruptPersistedChainState(directory: directory)
        }

        if let resolvedPersisted {
            let restoredChain = try ChainState.restore(
                from: resolvedPersisted,
                retentionDepth: config.retentionDepth
            )
            let initLog = NodeLogger("init")
            let restoredHeight = await restoredChain.getHighestBlockHeight()
            let restoredTipHash = await restoredChain.getMainChainTip()
            let tipBlockPresent = await restoredChain.getMainChainBlockHash(atIndex: restoredHeight) != nil
            initLog.info("Restored chain: height=\(restoredHeight) tip=\(String(restoredTipHash.prefix(16)))… tipHeightPresent=\(tipBlockPresent)")
            let genesisBlock = try await buildGenesisBlock(nexusNetwork.ivyFetcher)
            let blockHash = try VolumeImpl<Block>(node: genesisBlock).rawCID
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: restoredChain)
        } else {
            let genesisBlock = try await buildGenesisBlock(nexusNetwork.ivyFetcher)
            let blockHash = try VolumeImpl<Block>(node: genesisBlock).rawCID
            let chainState = ChainState.fromGenesis(block: genesisBlock, retentionDepth: config.retentionDepth)
            genesis = GenesisResult(block: genesisBlock, blockHash: blockHash, chainState: chainState)
        }

        let genesisHeader = try VolumeImpl<Block>(node: genesis.block)
        // Store genesis through canonical content storage.
        let storer = nexusNetwork.canonicalContentStorer()
        do {
            try genesisHeader.storeRecursively(storer: storer)
            let volumes = storer.collectVolumes(root: genesisHeader.rawCID)
            if !volumes.isEmpty {
                try await nexusNetwork.storeVolumesDurably(volumes)
            }
            let owner = "\(nexusNetwork.ownerNamespace):0"
            for root in storer.storedRoots {
                try await nexusNetwork.pinDurably(root: root, owner: owner)
            }

        } catch {
            NodeLogger("genesis").error("Failed to store genesis block recursively: \(error)")
            throw NodeError.genesisStoreFailed(directory: directory)
        }
        guard let specData = genesis.block.spec.node?.toData() else {
            NodeLogger("genesis").error("Failed to serialize genesis spec for durable storage")
            throw NodeError.genesisStoreFailed(directory: directory)
        }
        let specCID = genesis.block.spec.rawCID
        let specPayload = SerializedVolume(root: specCID, entries: [specCID: specData])
        do {
            try await nexusNetwork.storeVolumeDurably(specPayload)
            try await nexusNetwork.pinDurably(root: specCID, owner: "\(nexusNetwork.ownerNamespace):spec")
            let fee = await nexusNetwork.ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry * 365
            await nexusNetwork.announce(cid: specCID, expiry: expiry, fee: fee)
        } catch {
            NodeLogger("genesis").error("Failed to store genesis spec durably: \(error)")
            throw NodeError.genesisStoreFailed(directory: directory)
        }

        self.genesisResult = genesis
        let nexusLevel = ChainLevel(chain: genesis.chainState, children: [:])
        let latticeInstance = Lattice(nexus: nexusLevel)
        self.lattice = latticeInstance
        let nexusKey = nexusNetwork.chainPath.joined(separator: "/")
        self.networks = [nexusKey: nexusNetwork]
        self.persisters = [nexusKey: persister]
        self.blocksSinceLastPersist = [:]
        self.recentPeerBlocks = [:]
        self.recentBlockAnnounces = [:]
        self.peerBlockCounts = [:]
        self.feeEstimators = [nexusKey: FeeEstimator()]
        self.subscriptions = SubscriptionManager()
        self.anchorPeers = AnchorPeers(dataDir: config.storagePath)
        self.peerStore = PeerStore(dataDir: config.storagePath)
        self.metrics = NodeMetrics()
        self.rateLimiter = RPCRateLimiter(
            requestsPerSecond: config.resources.rpcRequestsPerSecond,
            burstSize: config.resources.rpcBurstSize
        )
        self.banStore = PeerBanStore(dataDir: config.storagePath)
        let nexusStore = try? StateStore(storagePath: config.storagePath, chain: genesisConfig.directory)
        if nexusStore == nil {
            NodeLogger("startup").error("Failed to open nexus StateStore — receipt indexing and tx history will not be persisted this session")
        }
        if let nexusStore {
            self.stateStores = [nexusKey: nexusStore]
        } else {
            self.stateStores = [:]
        }
        let restoredTip = await genesis.chainState.getMainChainTip()
        self.tipCaches = [nexusKey: TipCache(tip: restoredTip)]
        self.postStateCaches = [nexusKey: PostStateCache()]
        self.deployedChildChains = [:]
        self.registeredRPCEndpoints = [:]
        self.registeredRPCAuthTokens = [:]
        self.nodeAddress = CryptoUtils.createAddress(from: config.publicKey)
        self.coinbaseAuthority = loadOrCreateCoinbaseAuthority(storagePath: config.storagePath)
    }

    private static func seedEmptyStateVolume(network: ChainNetwork) async throws {
        // The empty state is a deterministic Volume frontier. Genesis building
        // can resolve through it before any blocks exist. It also remains a
        // long-lived Reference root (for example Nexus parentState), so retain it
        // under a non-height owner rather than letting block-retention pruning
        // reclaim the bootstrap reference.
        let emptyStorer = network.canonicalContentStorer()
        do {
            try LatticeState.emptyHeader.storeRecursively(storer: emptyStorer)
            let emptyVolumes = emptyStorer.collectVolumes(root: LatticeState.emptyHeader.rawCID)
            if !emptyVolumes.isEmpty {
                try await network.storeVolumesDurably(emptyVolumes)
            }
            let emptyOwner = "\(network.ownerNamespace):empty-state"
            if !(await network.pinnedOwners(prefix: emptyOwner).contains(emptyOwner)) {
                try await network.pinDurably(
                    root: LatticeState.emptyHeader.rawCID,
                    owner: emptyOwner
                )
            }
        } catch {
            NodeLogger("genesis").error("Failed to seed empty state volume: \(error)")
            throw NodeError.genesisStoreFailed(directory: network.directory)
        }
    }

    public func stateStore(for directory: String) -> StateStore? {
        stateStores[chainKey(forDirectory: directory)]
    }

    public func stateStore(forPath chainPath: [String]) -> StateStore? {
        stateStores[chainKey(forPath: chainPath)]
    }

    func feeEstimator(for directory: String) -> FeeEstimator {
        feeEstimator(forPath: chainPath(forDirectory: directory))
    }

    func feeEstimator(forPath chainPath: [String]) -> FeeEstimator {
        let key = chainKey(forPath: chainPath)
        if let existing = feeEstimators[key] {
            return existing
        }
        let estimator = FeeEstimator()
        feeEstimators[key] = estimator
        return estimator
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // build the trusted consensus provider before any peer link is
        // live. Serve = answer a verified descendant's weight query from our own
        // chain's authoritative effectiveWeight; mayServe = spawn-tree scope gate.
        // (The client `send` is best-effort over chain links here; the parent-link
        // consumer wiring lands in 2c-c.)
        consensusProvider = ConsensusProvider(
            // Short timeout: the 2c-c.2 consumer awaits this inline before a divergent
            // block's fork-choice decision, so an unreachable parent must not stall
            // extraction for long (a missed answer is safe — only-grows + durable floor).
            // TODO(2c-c follow-up): make the consumer query non-blocking (promote +
            // reevaluate on response) to fully remove the per-divergent-block stall.
            requestTimeout: .seconds(2),
            weightLookup: { [weak self] path, committerHashes in
                guard let self, let chain = await self.chain(forPath: path) else { return nil }
                // Faithful Hierarchical-GHOST union over the child's committers, each
                // grinding block once. A single committer reduces to its trueCumWork.
                return await chain.unionInheritedWeight(committerHashes: Set(committerHashes))
            },
            mayServe: { [weak self] peer, path in
                guard let self else { return false }
                return await self.spawnTrust.mayServeConsensus(to: peer, forChainPath: path)
            },
            send: { [weak self] peer, topic, payload in
                guard let self else { return }
                // Reach the peer wherever it is connected: chain-gossip links AND
                // the parent-subscription link (the trusted ancestor we query lives
                // on the latter). sendMessage is a no-op where `peer` isn't connected.
                for network in await self.networks.values {
                    await network.ivy.sendMessage(to: peer, topic: topic, payload: payload)
                }
                for link in await self.parentConsensusLinks.values {
                    await link.ivy.sendMessage(to: peer, topic: topic, payload: payload)
                }
            })
        childPeerProvider = ChildPeerProvider(
            send: { [weak self] peer, topic, payload in
                guard let self else { return }
                // Reach the queried parent wherever it is connected — the parent we
                // ask for same-chain peers lives on the parent-subscription link.
                for network in await self.networks.values {
                    await network.ivy.sendMessage(to: peer, topic: topic, payload: payload)
                }
                for link in await self.parentConsensusLinks.values {
                    await link.ivy.sendMessage(to: peer, topic: topic, payload: payload)
                }
            })
        if config.bootstrapPeers.isEmpty && !config.enableLocalDiscovery {
            let log = NodeLogger("startup")
            log.warn("No bootstrap peers configured and local discovery disabled — node may not find peers")
        }
        // present our spawn-cert chain on every chain network's link so
        // ancestors/peers can verify our spawn-tree membership after identify. No-op
        // for a federated/root node (empty chain).
        if !spawnCertChain.isEmpty {
            for (_, network) in networks {
                await network.ivy.setSpawnCertChain(spawnCertChain)
            }
        }
        // Reload persisted peer bans so a peer banned before the last shutdown
        // stays banned across the restart (it cannot clear its penalty by waiting
        // for or provoking a restart). Expired bans are pruned on load.
        // Fail closed: corrupt/unreadable ban state aborts startup rather than
        // silently re-admitting every previously banned peer.
        try await banStore.load()
        // Recover parents before children: per-process child extraction depends
        // on each parent chain's accepted view before descendants replay.
        // Dictionary iteration order is non-deterministic, so without an
        // explicit topological order children frequently replay first and
        // their CAS recovery silently fails — leaving in-memory chain state
        // stuck at 0 even though SQLite holds the real tip.
        for chainPath in topologicallyOrderedChainPaths() {
            let dir = chainPath.last ?? genesisConfig.directory
            guard let network = network(forPath: chainPath) else { continue }
            // Start networking before recovery so the fetcher is available for
            // any blocks that need to be resolved over the wire. The delegate is
            // set AFTER recovery so that didConnectPeer (and the tip announce it
            // sends) only fires once the local chain height is correct. Any peers
            // that connected during recovery are caught by the broadcast below.
            try await network.start()
            if !config.discoveryOnly {
                // Restore fork-choice inputs before projecting ChainState from the
                // committed StateStore head. Inherited-weight promotions must remain
                // reproducible after restart or ChainState can select a different tip
                // than the durable canonical commitment.
                await restoreInheritedWeight(directory: dir)
                // Project ChainState from StateStore's authoritative committed tip first.
                let projected = await recoverFromCAS(directory: dir)
                guard projected else {
                    await markChainUnhealthy(directory: dir, reason: "failed to project ChainState to committed tip")
                    continue
                }
                // block_index helpers below write FROM the in-memory ChainState, so they
                // run ONLY when ChainState now equals StateStore's committed tip. If
                // recovery couldn't fully project it (e.g. a reorg whose branch isn't in
                // CAS), skip both rather than overwrite the authoritative commitment from a
                // stale projection — block_index is already correct (atomic commits) and
                // doesn't need repair from a behind ChainState (F5-4).
                if let st = stateStore(for: dir), let committed = st.getChainTip(),
                   await chain(for: dir)?.getMainChainTip() == committed {
                    // Fill any missing rows (pre-upgrade / gaps)…
                    await backfillBlockIndex(directory: dir)
                    // …re-materialize any retained block's root-keyed Volume grouping that CID-only
                    // recovery / parent-embedding left absent, so getHeaders2 serves every block over
                    // P2P (else a follower syncs 0 headers though the data is intact locally)…
                    await reconstructBlockVolumes(directory: dir)
                    // …and reconcile to repair the narrow two-transaction window a crash
                    // mid-reorg can leave (per-block tip apply, then segment commit).
                    do {
                        try await reconcileBlockIndex(directory: dir)
                    } catch {
                        NodeLogger("recovery").error("\(dir): failed startup block_index audit: \(error)")
                    }
                } else {
                    NodeLogger("recovery").warn("\(dir): ChainState != committed tip after recovery — skipping block_index audit (commitment stays authoritative)")
                }
                await rebuildAccountPins(directory: dir)
                // a crash between commitBlockStorage's pin and pruneBlocks
                // strands a canonical block-height owner below the retention floor
                // forever; startup is a choke point every node passes through, so
                // reclaim those leaked owners here (mirrors the account-pin sweep).
                do {
                    try await sweepStaleBlockStoragePins(directory: dir, network: network)
                } catch {
                    NodeLogger("recovery").error("\(dir): startup block-storage pin sweep failed: \(error)")
                }
                await advanceStateRetainedRootsFromCurrentTip(directory: dir, network: network)
                // Seed the genesis frontier's refcount index entry + per-node pins at
                // startup (the choke point every node passes through). Genesis is
                // committed outside the accept hook, so without this the genesis state
                // is refcount-pin-protected only from the first non-genesis accept —
                // leaving a gate-ON eviction window if the node stalls before height 1.
                // Gated + idempotent + best-effort: a no-op with the flags default-OFF.
                await seedGenesisStateRefcountIfNeeded(directory: dir, network: network)
                await restoreMempool(directory: dir, network: network, fetcher: network.ivyFetcher)
                await warmNextTargetCache(directory: dir)
            }
            await network.setDelegate(self)
            if !config.discoveryOnly, let chainState = await chain(for: dir) {
                let tipCID = await chainState.getMainChainTip()
                let tipHeight = await chainState.getHighestBlockHeight()
                let specCID = genesisResult.block.spec.rawCID
                await network.broadcastChainAnnounce(tipCID: tipCID, tipHeight: tipHeight, specCID: specCID)
            }
        }
        if !config.discoveryOnly {
            mempoolPruneTask = startMempoolLoop(node: self)
            pinReannounceTask = startPinReannounceLoop(node: self, interval: config.reannounceInterval)
            evictionTask = startEvictionLoop(node: self, interval: config.evictionInterval)
            storageMaintenanceTask = startStorageMaintenanceLoop(node: self)
            unhealthyRecoveryTask = startUnhealthyChainRecoveryLoop(node: self)
        }
    }

    public func stop() async {
        // Stop the reconcile loop before quiescing so it can't respawn a child we
        // are about to tear down.
        supervisedReconcileTask?.cancel()
        let reconcileTask = supervisedReconcileTask
        supervisedReconcileTask = nil
        await reconcileTask?.value
        // Quiesce the supervised subtree first: each child's own SIGTERM path
        // quiesces ITS children in turn, so stopping the root stops the tree.
        if let childSupervisor { await childSupervisor.quiesce() }
        let cancellableMaintenanceTasks = [
            mempoolPruneTask,
            pinReannounceTask,
            evictionTask,
            storageMaintenanceTask,
            unhealthyRecoveryTask
        ].compactMap { $0 }
        for task in cancellableMaintenanceTasks {
            task.cancel()
        }
        mempoolPruneTask = nil
        pinReannounceTask = nil
        evictionTask = nil
        storageMaintenanceTask = nil
        unhealthyRecoveryTask = nil
        for task in cancellableMaintenanceTasks {
            await task.value
        }
        let cancellableNetworkTasks = [peerRefreshTask].compactMap { $0 } + Array(syncTasks.values)
        for task in cancellableNetworkTasks {
            task.cancel()
        }
        peerRefreshTask = nil
        syncTasks.removeAll()
        activeSyncGaps.removeAll()
        for task in cancellableNetworkTasks {
            await task.value
        }
        // Drain any in-flight per-chain block processing before snapshotting state.
        // A block's in-memory tip advances (processBlockHeader) before its durable
        // applyBlock commit, both under `withChainMutation`; if SIGTERM arrives between
        // them, `persistChainState` (which snapshots the IN-MEMORY tip into chain_state.json
        // + the DiskBroker chain_tip meta) would record a tip the StateStore never committed.
        // On restart, recovery then projects the in-memory tip DOWN to the lower committed
        // tip — and the RPC can briefly serve that never-committed phantom tip. Awaiting the
        // gate lets the last in-flight applyBlock commit first (maintenance/sync/mining tasks
        // are already cancelled above, so no new mutation starts), keeping the persisted tip
        // == the durable StateStore tip. (Geth posture: never persist a head ahead of its
        // committed state.)
        for (_, network) in networks {
            await chainMutationGate[chainKey(forPath: network.chainPath)]?.value
        }
        // One last WAL checkpoint + incremental vacuum on a graceful stop so
        // the file on disk is consistent-and-compact before the process exits.
        // Keep shutdown flush-only: cleanup/reconcile passes are periodic
        // maintenance work and must not silently consume durable retry ledgers.
        await checkpointStorage()
        for (_, network) in networks {
            await persistChainState(chainPath: network.chainPath)
            await persistMempool(network: network)
        }
        let currentPeers = await connectedPeerEndpoints()
        let scoring = await nexusReputationScoring()
        await anchorPeers.update(peers: currentPeers, scoring: scoring)
        for (_, network) in networks {
            await network.stop()
        }
    }

    // MARK: - Chain Network Management

    /// The primary (genesis) network for this node.
    /// For per-process child nodes, this IS the only network.
    /// In multi-chain mode, this is the root chain (Nexus).
    public var primaryNetwork: ChainNetwork? {
        let rootPath = (config.fullChainPath ?? [genesisConfig.directory]).joined(separator: "/")
        return networks[rootPath]
    }

    func chainAddress(forDirectory directory: String) -> ChainAddress? {
        if directory == genesisConfig.directory {
            return ChainAddress(config.fullChainPath ?? [genesisConfig.directory])
        }
        if let network = network(for: directory) {
            return ChainAddress(network.chainPath)
        }
        return nil
    }

    func chainKey(forPath chainPath: [String]) -> String {
        ChainAddress(chainPath)?.key ?? chainPath.joined(separator: "/")
    }

    func chainKey(forDirectory directory: String) -> String {
        chainAddress(forDirectory: directory)?.key ?? directory
    }

    func chainPath(forDirectory directory: String) -> [String] {
        chainAddress(forDirectory: directory)?.components ?? resolvedChainPath(for: directory)
    }

    func storageNamespace(forPath chainPath: [String]) -> String {
        let address = chainKey(forPath: chainPath)
        if address == (config.fullChainPath ?? [genesisConfig.directory]).joined(separator: "/") {
            return genesisConfig.directory
        }
        return "chains/" + address
    }

    /// Look up a network by its full chain path.
    public func network(forPath chainPath: [String]) -> ChainNetwork? {
        networks[chainKey(forPath: chainPath)]
    }

    /// Look up a network by its leaf directory name.
    /// Scans registered networks — O(n) but n is small (direct children only).
    public func network(for directory: String) -> ChainNetwork? {
        networks.values.first { $0.directory == directory }
    }

    public func allDirectories() -> [String] {
        networks.values.map { $0.directory }.sorted()
    }

    /// Order registered chain paths so every parent appears before its
    /// children. Used by `start()` so CAS recovery replays parent blocks
    /// before the children that reference them. Falls back to alphabetical
    /// order within each tier for stability.
    func topologicallyOrderedChainPaths() -> [[String]] {
        var ordered: [[String]] = []
        var visited: Set<String> = []
        func visit(_ path: [String]) {
            let key = chainKey(forPath: path)
            guard !visited.contains(key), networks[key] != nil else { return }
            if path.count > 1 {
                visit(Array(path.dropLast()))
            }
            visited.insert(key)
            ordered.append(path)
        }
        if let root = primaryNetwork?.chainPath {
            visit(root)
        }
        for path in networks.values.map(\.chainPath).sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
            visit(path)
        }
        return ordered
    }

    func topologicallyOrderedDirectories() -> [String] {
        topologicallyOrderedChainPaths().compactMap(\.last)
    }

    public nonisolated static func maxSubscribableBlockSize(maxFrameSize: UInt32) -> UInt64 {
        UInt64(maxFrameSize) > UInt64(subscriptionFrameOverheadBytes)
            ? UInt64(maxFrameSize - subscriptionFrameOverheadBytes)
            : 0
    }

    public nonisolated static func requiredSubscriptionFrameSize(maxBlockSize: Int) -> UInt64 {
        let blockBytes = UInt64(max(0, maxBlockSize))
        return blockBytes + UInt64(subscriptionFrameOverheadBytes)
    }

    public nonisolated static func validateSubscriptionFrameBudget(
        chainPath: [String],
        spec: ChainSpec,
        maxFrameSize: UInt32
    ) throws {
        let required = requiredSubscriptionFrameSize(maxBlockSize: spec.maxBlockSize)
        guard required <= UInt64(maxFrameSize) else {
            throw NodeError.chainSpecExceedsFrameLimit(
                chainPath: chainPath,
                maxBlockSize: spec.maxBlockSize,
                requiredFrameSize: required,
                maxFrameSize: maxFrameSize
            )
        }
    }

    private func resolvedChainPath(for directory: String) -> [String] {
        if directory == genesisConfig.directory { return [directory] }
        var path = [directory]
        var current = directory
        // Stop at this node's own root: when the node is itself deployed as a
        // child chain, the nexus network's chainPath extends above the local
        // genesis, and walking past it would splice global components into a
        // node-local path.
        while current != genesisConfig.directory,
              let parent = network(for: current)?.parentDirectory, parent != current {
            path.insert(parent, at: 0)
            current = parent
        }
        if path.first != genesisConfig.directory {
            path.insert(genesisConfig.directory, at: 0)
        }
        return path
    }

    /// GLOBAL chain path for `directory`: the node-local `resolvedChainPath(for:)`
    /// re-rooted under `config.fullChainPath` when this node is itself deployed as
    /// a child chain (e.g. ["Nexus","Mid","AlphaChain"] for a grandchild). Returns
    /// nil for the node's own root chain when no fullChainPath is configured —
    /// callers treat nil as "the process-local nexus".
    func globalChainPath(for directory: String) -> [String]? {
        if let fullPath = config.fullChainPath, fullPath.last == directory { return fullPath }
        if directory == genesisConfig.directory { return config.fullChainPath }
        let localPath = resolvedChainPath(for: directory)
        guard let prefix = config.fullChainPath else { return localPath }
        // localPath is rooted at this node's own genesis directory, which is the
        // last component of fullChainPath — splice the global prefix in its place.
        return prefix + localPath.dropFirst()
    }

    // MARK: - Chain Lookup

    public func chain(for directory: String) async -> ChainState? {
        if let address = chainAddress(forDirectory: directory) {
            return await chain(forPath: address.components)
        }
        let nexusDir = genesisConfig.directory
        if directory == nexusDir {
            return await lattice.nexus.chain
        }
        guard let hit = await lattice.nexus.findLevel(directory: directory, chainPath: [nexusDir]) else {
            return nil
        }
        return await hit.level.chain
    }

    public func chain(forPath chainPath: [String]) async -> ChainState? {
        guard let address = ChainAddress(chainPath) else { return nil }
        if address.components == (config.fullChainPath ?? [genesisConfig.directory]) {
            return await lattice.nexus.chain
        }
        let allLevels = await lattice.nexus.collectAllLevels(chainPath: [genesisConfig.directory])
        guard let hit = allLevels.first(where: { $0.chainPath == address.components }) else { return nil }
        return await hit.level.chain
    }

    /// `Lattice.processBlockHeader` always applies fork choice to the actor's
    /// `nexus` level. When this node processes blocks for a chain other than its
    /// own (e.g. extracted child blocks in per-process topology), route them
    /// through a temporary Lattice view rooted at that child level so the same
    /// validation logic updates the intended chain.
    func latticeView(for chainPath: [String]?) async -> Lattice {
        guard let chainPath,
              let address = ChainAddress(chainPath),
              address.components != (config.fullChainPath ?? [genesisConfig.directory]) else {
            return lattice
        }
        let allLevels = await lattice.nexus.collectAllLevels(chainPath: [genesisConfig.directory])
        guard let hit = allLevels.first(where: { $0.chainPath == address.components }) else {
            return lattice
        }
        return Lattice(nexus: hit.level)
    }

    /// Full chain path from nexus down to `directory`, e.g. `[nexus, child, grandchild]`,
    /// resolved by searching the lattice's level tree. Returns nil for unknown
    /// directories. Distinct from the synchronous `chainPath(forDirectory:)`,
    /// which resolves via registered networks.
    func latticeChainPath(for directory: String) async -> [String]? {
        let nexusDir = genesisConfig.directory
        if directory == nexusDir { return [nexusDir] }
        return await lattice.nexus.findLevel(directory: directory, chainPath: [nexusDir])?.chainPath
    }

    // MARK: - Mempool Maintenance

    public func pruneExpiredTransactions(olderThan age: Duration? = nil) async {
        // Default to the configured mempool TTL (must exceed the block interval —
        // see NodeTuning.Storage.mempoolTxExpirySeconds), not a hardcoded 600s.
        let effectiveAge = age ?? .seconds(config.tuning.storage.mempoolTxExpirySeconds)
        for (_, network) in networks {
            await network.nodeMempool.pruneExpired(olderThan: effectiveAge)
        }
    }

    /// Drop tx_history rows for foreign addresses older than `retentionBlocks`
    /// behind the chain tip. Own-address rows are always retained — startup pin
    /// rebuild (`rebuildAccountPinsFromTxHistory`) depends on them. Without
    /// this, `tx_history` grows forever on disk (UNSTOPPABLE_LATTICE P0 #4).
    public func pruneTransactionHistory(retentionBlocks: UInt64) async {
        for (dir, store) in stateStores {
            guard let chain = await chain(for: dir) else { continue }
            let height = await chain.getHighestBlockHeight()
            guard height > retentionBlocks else { continue }
            let below = height - retentionBlocks
            do {
                let removed = try await store.pruneTransactionHistory(
                    belowHeight: below,
                    keepAddress: nodeAddress
                )
                if removed > 0 {
                    NodeLogger("gc").info("Pruned \(removed) tx_history rows on \(dir) below height \(below)")
                }
            } catch {
                NodeLogger("gc").error("Pruning tx_history on \(dir) below height \(below) failed: \(error)")
            }
            // F5-4: block_index is the durable height→hash main-chain commitment — the
            // "keep the headers, prune the bodies" anchor. We keep it for EVERY chain,
            // not just the absolute root: Lattice is self-similar, so any chain can be a
            // PoW-root anchor for children (now or later), and a child must be able to
            // verify a proof's root canonically even after that root's body is pruned.
            // The commitment is tiny (height→hash), so this holds uniformly across chains.
        }
    }

    /// Capture a scoring closure bound to the nexus network's Tally ledger so
    /// `AnchorPeers` can evict peers that have degraded since they were
    /// promoted. Returns nil when the nexus network hasn't started yet (the
    /// caller should skip scoring in that case and accept raw endpoints).
    func nexusReputationScoring() async -> ReputationScoring? {
        let nexusDir = genesisConfig.directory
        guard let network = network(for: nexusDir) else { return nil }
        let tally = await network.ivy.tally
        return { endpoint in
            tally.reputation(for: PeerID(publicKey: endpoint.publicKey))
        }
    }

    /// Drop anchor peers whose Tally reputation has fallen at or below zero.
    /// Called on the same cadence as pin re-announcement so a Byzantine
    /// bootstrap peer doesn't linger across restarts (UNSTOPPABLE_LATTICE S9).
    public func demoteLowScoringAnchors() async {
        guard let scoring = await nexusReputationScoring() else { return }
        let removed = await anchorPeers.evictLowScoring(scoring: scoring)
        if removed > 0 {
            NodeLogger("anchor").info("Demoted \(removed) anchor peers below reputation floor")
        }
    }

    /// Checkpoint WAL and reclaim freelist pages on every chain's StateStore.
    /// Scheduled on a slow cadence so the per-chain SQLite file doesn't bloat
    /// across a long mining session (UNSTOPPABLE_LATTICE S7).
    private func checkpointStorage() async {
        let storesToMaintain = Array(stateStores)
        await withTaskGroup(of: Void.self) { group in
            for (dir, store) in storesToMaintain {
                group.addTask {
                    do {
                        try await store.maintain()
                        NodeLogger("gc").debug("Storage maintenance pass on \(dir)")
                    } catch {
                        NodeLogger("gc").error("Storage maintenance pass on \(dir) failed: \(error)")
                    }
                }
            }
        }
        // All networks share one DiskBroker — checkpoint once, not once per network.
        await sharedDiskBroker.checkpoint()
    }

    public func maintainStorage() async {
        // P-1301: parallel per-chain StateStore maintenance (each has its own SQLite file)
        await checkpointStorage()
        // reclaim validator pins leaked by a swallowed delete failure.
        await reconcileValidatorPins()
        // reclaim canonical block-height pins a crash-skipped prune stranded
        // below the retention floor.
        await sweepStaleBlockStoragePins()
    }

    // MARK: - Pin Re-announcement

    /// Re-announce the current chain tip block and its Volume boundaries.
    /// Called periodically to keep pin announcements alive in the DHT.
    public func reannouncePinnedVolumes(directory: String) async {
        guard let network = network(for: directory) else { return }
        let roots = await network.reannounceablePinnedRoots()
        // P-401: parallelize — sequential announce of ~50k roots blocked the
        // LatticeNode actor for ~50ms and delayed all gossip during reannounce.
        let fee = await network.ivy.config.relayFee * 2
        let expiry = UInt64(Date().timeIntervalSince1970) + config.pinAnnounceExpiry
        await withTaskGroup(of: Void.self) { group in
            for root in roots {
                group.addTask { await network.announce(cid: root, expiry: expiry, fee: fee) }
            }
        }
    }

    /// Broadcast current chain tip to all connected peers so they can compare
    /// and trigger sync if they're behind. This is the periodic status heartbeat
    /// (analogous to Ethereum's eth_status) that catches cases where the initial
    /// didConnectPeer announce was sent with stale height (e.g. before CAS recovery
    /// completed) or where peers connected after the startup broadcast.
    public func broadcastChainTip(directory: String) async {
        guard let network = network(for: directory),
              let chainState = await chain(for: directory) else { return }
        let tipCID = await chainState.getMainChainTip()
        guard !tipCID.isEmpty else { return }
        let tipHeight = await chainState.getHighestBlockHeight()
        let specCID = genesisResult.block.spec.rawCID
        await network.broadcastChainAnnounce(tipCID: tipCID, tipHeight: tipHeight, specCID: specCID)
    }

    // MARK: - Peer Persistence

    public func connectedPeerEndpoints(directory: String? = nil) async -> [PeerEndpoint] {
        let dir = directory ?? genesisConfig.directory
        guard let network = network(for: dir) else { return [] }
        return await network.ivy.connectedPeerEndpoints
    }

    public func connectedPeerEndpoints(chainPath: [String]) async -> [PeerEndpoint] {
        guard let network = network(forPath: chainPath) else { return [] }
        return await network.ivy.connectedPeerEndpoints
    }
}

extension ChainNetwork {
    public func setDelegate(_ delegate: ChainNetworkDelegate) {
        self.delegate = delegate
    }
}
