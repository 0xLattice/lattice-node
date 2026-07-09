import Lattice
import Foundation
import Ivy
import VolumeBroker
import Tally
import cashew
import UInt256
import OrderedCollections
import Synchronization

/// Outcome of a gossip-received transaction's mempool admission. Only
/// `rejected(consensusInvalid: true)` may drive a peer penalty. A capacity
/// rejection is reported distinctly so the gossip layer can apply its
/// availability/DoS defense for peers that keep flooding an already-full
/// mempool without treating pool-full as consensus-invalid.
public enum GossipAdmission: Sendable {
    case accepted
    case rejected(consensusInvalid: Bool)
    case rejectedMempoolFull
}

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, height: UInt64, from peer: PeerID) async
    /// Child block received with sparse proof paths for PoW validation. Each proof
    /// reconstructs its own carrier root hash; no root hash is trusted from wire.
    func chainNetwork(_ network: ChainNetwork, didReceiveChildBlock cid: String, data: Data, proofs: [ChildBlockProof], from peer: PeerID) async
    /// Validate + classify + admit a gossip-received transaction. Delegate
    /// owns the full mempool admission decision (valid vs pending vs reject)
    /// so receipt-blocked child-chain withdrawals can sit in pending instead
    /// of being silently dropped. The result distinguishes a capacity rejection
    /// (mempool full) so ChainNetwork can exclude/penalize a peer that keeps
    /// flooding a full mempool rather than uniformly dropping. Only
    /// `.rejected(consensusInvalid: true)` is a peer-penalizable validation
    /// failure; policy, transient, missing-input, and capacity rejects are not.
    func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> GossipAdmission
    func chainNetwork(_ network: ChainNetwork, didConnectPeer peer: PeerID) async
    /// a peer completed the identify handshake and is now tracked under its
    /// real (canonical) identity. For inbound peers this is the first admission point
    /// that sees the real id — `didConnectPeer` only ever saw the temporary
    /// `inbound-<uuid>`. Enforce durable bans here. Ivy fires this once per identify
    /// FRAME (re-identify re-fires), so conformers MUST be idempotent: re-check the
    /// ban and re-disconnect, with no per-call accumulation.
    func chainNetwork(_ network: ChainNetwork, didIdentifyPeer peer: PeerID) async
    /// Fired when a peer's spawn-cert chain arrives (a separate frame after
    /// identify), so the node can (re)classify spawn-tree trust once
    /// the chain is actually present.
    func chainNetwork(_ network: ChainNetwork, didReceiveSpawnCertChain peer: PeerID) async
    /// (serve): a trusted descendant asked for a chain block's
    /// authoritative weight. Returns the response payload to send back on THIS
    /// network, or nil to stay silent (undecodable / out-of-scope peer).
    func chainNetwork(_ network: ChainNetwork, handleConsensusRequest payload: Data, from peer: PeerID) async -> Data?
    /// (client): a response to one of our own consensus-weight requests.
    /// `peer` is the responder — the client only accepts it if it matches the peer
    /// the request was sent to (anti-forgery).
    func chainNetwork(_ network: ChainNetwork, handleConsensusResponse payload: Data, from peer: PeerID) async
    /// A connected child advertised its chain-gossip `(pubkey, port)` over this
    /// (parent) chain's link. The node stores it against the peer and pairs it with
    /// the observed host when serving `getChildPeers`.
    func chainNetwork(_ network: ChainNetwork, handleChildPeerAdvertise payload: Data, from peer: PeerID) async
    /// (serve): a connected child pushed its genesis content over the parent link.
    /// The node verifies each entry's CID + that the genesis matches the anchored
    /// child genesis, then durably re-serves it on the parent network.
    func chainNetwork(_ network: ChainNetwork, handleChildGenesisAdvertise payload: Data, from peer: PeerID) async
    /// (serve): a followed child asked for the chain endpoints of this chain's
    /// `directory` children. Returns the response payload to send back on THIS
    /// network, or nil to stay silent (undecodable).
    func chainNetwork(_ network: ChainNetwork, handleChildPeerRequest payload: Data, from peer: PeerID) async -> Data?
    /// (client): a response to one of our own getChildPeers requests. `peer` is the
    /// responder — accepted only if it matches the peer we asked (anti-forgery).
    func chainNetwork(_ network: ChainNetwork, handleChildPeerResponse payload: Data, from peer: PeerID) async
    /// Penalize a peer that has repeatedly flooded an already-full mempool by
    /// adding it to the durable, cross-restart ban store. The node disconnects
    /// the peer and refuses future connections until the ban expires.
    func chainNetwork(_ network: ChainNetwork, banPeer peer: PeerID) async
    /// The serialized ChildBlockProof this node has stored for an accepted block,
    /// keyed by block CID (F5-4 `block_proofs`). Lets a serving peer bundle the
    /// anchored proof alongside child-chain headers during sync so the syncing
    /// node can verify PoW against the cross-chain root instead of the self-hash.
    /// nil for the root chain or any block with no stored proof.
    func chainNetwork(_ network: ChainNetwork, blockProofData cid: String) async -> Data?
    /// size-policy admission for an inline childBlock gossip payload,
    /// evaluated on the RAW wire byte lengths at the earliest node-controlled
    /// point — before the block is materialized via `Block(data:)` and before the
    /// proof is deserialized via `ChildBlockProof.deserialize`. Returns false when
    /// the inline block exceeds the spec block cap or the inline proof exceeds the
    /// derived `maxProofSize`. The handler rejects + penalizes the peer on false,
    /// so an oversized-but-malformed proof (which deserializes to nil and would
    /// otherwise skip the post-decode cap) is still rejected. Fail closed.
    func chainNetwork(_ network: ChainNetwork, allowsChildBlockSize blockBytes: Int, proofBytes: Int?) -> Bool
}

public extension ChainNetworkDelegate {
    // Default no-op: non-node conformers (test mocks) enforce no ban at identify.
    func chainNetwork(_ network: ChainNetwork, didIdentifyPeer peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, didReceiveSpawnCertChain peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, handleConsensusRequest payload: Data, from peer: PeerID) async -> Data? { nil }
    func chainNetwork(_ network: ChainNetwork, handleConsensusResponse payload: Data, from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, handleChildPeerAdvertise payload: Data, from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, handleChildGenesisAdvertise payload: Data, from peer: PeerID) async {}
    func chainNetwork(_ network: ChainNetwork, handleChildPeerRequest payload: Data, from peer: PeerID) async -> Data? { nil }
    func chainNetwork(_ network: ChainNetwork, handleChildPeerResponse payload: Data, from peer: PeerID) async {}
    // Default: no proof available. Keeps non-node conformers (test mocks) source-compatible.
    func chainNetwork(_ network: ChainNetwork, blockProofData cid: String) async -> Data? { nil }
    // Default: permit. Non-node conformers (test mocks) impose no size policy.
    func chainNetwork(_ network: ChainNetwork, allowsChildBlockSize blockBytes: Int, proofBytes: Int?) -> Bool { true }
}

/// Per-chain network actor. Composes the transport (Ivy), the broker cascade,
/// the mempool, and the gossip / mempool-relay / sync-request / Ivy-delegate
/// roles. The role implementations live in same-module extensions:
///   - `ChainNetwork+Gossip.swift`        — gossip codec + publish/relay (Dandelion++)
///   - `ChainNetwork+SyncRequests.swift`  — bulk header fetch + pending-request registry
///   - `ChainNetwork+IvyDelegate.swift`   — IvyDataSource/IvyDelegate handlers + pin-request
public actor ChainNetwork: IvyDelegate, IvyDataSource {
    /// Full chain path from root, e.g. ["Nexus", "Mid", "AlphaChain"].
    /// The leaf is this chain's directory; the path encodes the full ancestry
    /// so chains with the same directory name at different levels are distinct.
    public let chainPath: [String]
    #if DEBUG
    private var broadcastChainAnnounceCallCountForTesting = 0
    private var lastBroadcastChainAnnounceTipForTesting: String?
    #endif
    /// Leaf directory name — derived from chainPath.
    /// `last!` is safe: `init` rejects an empty `chainPath` (`NodeError.emptyChainPath`)
    /// and `chainPath` is an immutable `let`, so the leaf always exists.
    public nonisolated var directory: String { chainPath.last! }
    /// Stable owner namespace for broker pins. Non-root chains use the full
    /// path so duplicate leaf directories under different parents do not
    /// collide in the shared DiskBroker.
    public nonisolated var ownerNamespace: String {
        Self.ownerNamespace(directory: directory, chainPath: chainPath)
    }
    /// Parent directory — derived from chainPath, nil for the root chain.
    public nonisolated var parentDirectory: String? { chainPath.count >= 2 ? chainPath[chainPath.count - 2] : nil }
    /// RPC endpoint for this chain's process, registered at startup.
    /// nil until the per-process node announces itself.
    public private(set) var rpcEndpoint: String?

    public func setRPCEndpoint(_ endpoint: String) {
        rpcEndpoint = endpoint
    }
    public let ivy: Ivy
    public let ivyFetcher: IvyFetcher
    public let nodeMempool: NodeMempool
    /// Per-chain broker cascade: MemoryBroker -> DiskBroker
    public let broker: any VolumeBroker
    /// Direct reference to the per-chain DiskBroker for storage-maintenance paths
    /// that need the local SQLite broker specifically.
    public let diskBroker: DiskBroker
    // Visibility widened from `private` to module-internal: the
    // gossip / sync-request / Ivy-delegate role implementations live in
    // same-module ChainNetwork+*.swift extensions and read this shared state.
    let durableBroker: any VolumeBroker
    let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    /// Operational tunables threaded from `config.tuning` at construction.
    /// Stored as `nonisolated let`s so the nonisolated gossip/announce spawners
    /// can read the caps synchronously.
    nonisolated let gossipTuning: NodeTuning.Gossip
    nonisolated let rateLimitTuning: NodeTuning.RateLimit
    nonisolated let syncTuning: NodeTuning.Sync
    var recentTxCIDs: OrderedDictionary<String, ContinuousClock.Instant> = [:]
    nonisolated var maxRecentTxCIDs: Int { gossipTuning.maxRecentTxCIDs }
    nonisolated var txDeduplicationWindow: Duration { gossipTuning.txDedupWindow }
    /// Recently published pin-announce CIDs. Since the pin-announce signature fix
    /// these announcements are real wire traffic, and every send consumes a token
    /// from Ivy's per-peer Tally admission bucket on BOTH ends (`fireToPeer` and
    /// `handlePinAnnounce` each call `tally.shouldAllow`). The block publish/accept
    /// paths re-announce the same boundary CIDs (spec, children, state roots) for
    /// every block, so a fast block burst floods enough duplicate announces to
    /// drain the bucket — at which point Ivy silently drops the NEXT newBlock
    /// broadcast and peers stall behind the lost tip. Deduplicate at this choke
    /// point: a CID announced within the window is already recorded by the same
    /// closest-K peers, so the repeat carries zero information. The periodic
    /// re-announce loop (reannounceInterval, default 24h) is far above the window
    /// and refreshes normally.
    var recentPinAnnounces: OrderedDictionary<String, ContinuousClock.Instant> = [:]
    nonisolated var maxRecentPinAnnounces: Int { gossipTuning.maxRecentPinAnnounces }
    nonisolated var pinAnnounceDeduplicationWindow: Duration { gossipTuning.pinAnnounceDedupWindow }

    // MARK: - Dandelion++ stem relay [Fanti et al. 2018]
    // Two-phase propagation: transactions first travel a random single-peer
    // "stem" path for stemEpochDuration, then fluff-broadcast to all peers.
    // This reduces transaction-to-IP linkability from O(1) to O(1/n).
    var dandelionStemPeer: PeerID?
    var dandelionEpochStart: ContinuousClock.Instant = .now
    nonisolated var dandelionStemEpochDuration: Duration { gossipTuning.dandelionStemEpoch }

    /// Per-peer token bucket for mempool-full gossip admission. A peer that
    /// floods distinct valid txs would otherwise saturate mempool capacity
    /// and validation CPU; cap at ~100 sustained / 200 burst per peer.
    var mempoolGossipBuckets: PeerRateBuckets
    /// Per-peer token bucket for pinRequest admission. Each pinRequest may
    /// trigger a DHT fetch; cap at ~10 sustained / 30 burst per peer.
    var pinRequestBuckets: PeerRateBuckets
    /// Per-peer token bucket for getHeaders2 (proof-carrying header) admission.
    /// A single cheap request fans out to up to `maxHeaderBatchSize` disk fetches
    /// + block decodes, so it is the classic cheap-request/expensive-response
    /// amplification vector; gate it the same way as pinRequest.
    var getHeadersBuckets: PeerRateBuckets
    /// Per-peer token bucket for chainAnnounce control messages. chainAnnounce
    /// is dispatched on its own bounded spawner (it bypasses the gossip cap so
    /// partition heals don't stall), so a per-peer bucket is the second line of
    /// defense against one peer monopolizing that spawner.
    var chainAnnounceBuckets: PeerRateBuckets
    /// Per-peer token bucket for consensus-weight requests (cw-request) —
    /// a cheap request that triggers a chain-path resolution + weight lookup +
    /// response, the same amplification class as getHeaders; gate it the same way.
    var consensusRequestBuckets: PeerRateBuckets
    /// Per-peer token bucket for same-chain-peer requests (childpeers-request and
    /// childpeers-advertise) — cheap requests that trigger a subscriber scan +
    /// reply, the same amplification class as cw-request; gate them the same way.
    var childPeerRequestBuckets: PeerRateBuckets
    nonisolated var mempoolGossipCapacity: Double { rateLimitTuning.mempoolGossipCapacity }
    nonisolated var mempoolGossipRefillPerSec: Double { rateLimitTuning.mempoolGossipRefillPerSec }
    nonisolated var getHeadersCapacity: Double { rateLimitTuning.getHeadersCapacity }
    nonisolated var getHeadersRefillPerSec: Double { rateLimitTuning.getHeadersRefillPerSec }
    nonisolated var chainAnnounceCapacity: Double { rateLimitTuning.chainAnnounceCapacity }
    nonisolated var chainAnnounceRefillPerSec: Double { rateLimitTuning.chainAnnounceRefillPerSec }
    /// Per-peer count of consecutive gossip txs rejected because the mempool was
    /// at capacity. A peer that keeps flooding a full mempool is the abuser; once
    /// it crosses `mempoolFullBanThreshold` it is banned (source-exclusion) rather
    /// than letting it keep burning validation work for every peer. Reset on any
    /// accepted tx from that peer. LRU-bounded so a spoofed-key flood cannot evict
    /// the real flooder's accumulating count (which would reset it to zero and
    /// defeat the ban trigger): when at capacity the LEAST-recently-touched entry
    /// is dropped, never the entry we are about to increment.
    var mempoolFullFailures = LRUCounter(maxEntries: maxBucketEntries)
    nonisolated var mempoolFullBanThreshold: Int { rateLimitTuning.mempoolFullBanThreshold }
    nonisolated var pinRequestCapacity: Double { rateLimitTuning.pinRequestCapacity }
    nonisolated var pinRequestRefillPerSec: Double { rateLimitTuning.pinRequestRefillPerSec }
    /// Maximum entries in per-peer bucket dicts. Peers that disconnect are
    /// never removed automatically; without this cap the dicts grow with
    /// every unique peer public key seen over the node's lifetime.
    static let maxBucketEntries = 2_048
    /// Hard cap on unstructured Tasks spawned from nonisolated Ivy callbacks.
    /// Each unstructured Task queues on the actor even after being rate-limited
    /// inside the handler. Without this cap a flooding peer creates unbounded
    /// task accumulation before any actor-level rate limit is reached.
    nonisolated let pendingGossipTasks = Mutex(0)
    nonisolated var maxPendingGossipTasks: Int { gossipTuning.maxPendingGossipTasks }
    /// Hard cap on concurrent chainAnnounce control Tasks. chainAnnounce bypasses
    /// the gossip cap (it must process even when the gossip queue is saturated so
    /// partition heals don't stall), so without its own cap a chainAnnounce flood
    /// spawns unbounded concurrent Tasks. This dedicated cap bounds that path.
    nonisolated let pendingChainAnnounceTasks = Mutex(0)
    nonisolated var maxPendingChainAnnounceTasks: Int { gossipTuning.maxPendingChainAnnounceTasks }

    // PendingHeaderRequest / PendingHeaderProofRequest / HeaderBatchResponseOutcome
    // are defined in ChainNetwork+SyncRequests.swift (module-internal so these
    // stored properties can reference them across files).

    /// Pending bulk header requests waiting for a headerBatch response.
    /// Key = 16-byte request ID, value = target peer plus completion sink.
    var pendingHeaderRequests: [Data: PendingHeaderRequest] = [:]
    /// Pending proof-carrying header requests (getHeaders2 → headerBatch2). Same as
    /// above but each header carries the serving peer's stored ChildBlockProof so a
    /// syncing child chain can verify anchored PoW (F5-4 proof-carrying sync).
    var pendingHeaderProofRequests: [Data: PendingHeaderProofRequest] = [:]
    static let maxHeaderBatchSize = 1_000

    // MARK: - Header batch byte budget
    //
    // Ivy's `Message.serialize` returns EMPTY Data when the encoded frame
    // exceeds `maxFrameSize` (4 MiB) — the message is silently dropped, never
    // truncated. An unbudgeted headerBatch/headerBatch2 response over that
    // limit therefore vanishes on the wire: the requester times out, retries,
    // and loops on whatever tiny batch DOES fit ("Downloaded 1 headers"). The
    // serving side must budget the batch while building it; the requesting
    // side's multi-batch continuation already handles short batches.

    /// Encoded response budget: the frame cap minus headroom for the
    /// peerMessage envelope (tag + topic + length prefixes) and codec slack.
    static let headerBatchByteBudget = Int(IvyConfig.defaultMaxFrameSize) - 64 * 1024

    /// Fixed head of a headerBatch/headerBatch2 response body:
    /// requestID(16) + numHeaders(u32).
    static let headerBatchBaseBytes = 20

    /// Encoded size of one batch entry — mirrors
    /// `NetworkWireCodecs.appendHeaderEntry` (+ proof length field for
    /// headerBatch2, where a nil proof still encodes a 4-byte zero length).
    static func headerBatchEntryBytes(cidByteCount: Int, dataByteCount: Int, proofByteCount: Int?) -> Int {
        let entry = 2 + cidByteCount + 4 + dataByteCount
        guard let proofByteCount else { return entry }
        return entry + 4 + proofByteCount
    }

    /// The batch-size decision: may an entry of this shape still be appended
    /// to a response currently totalling `currentBytes`?
    static func headerBatchHasRoom(
        currentBytes: Int,
        cidByteCount: Int,
        dataByteCount: Int,
        proofByteCount: Int?,
        budget: Int = headerBatchByteBudget
    ) -> Bool {
        currentBytes + headerBatchEntryBytes(
            cidByteCount: cidByteCount,
            dataByteCount: dataByteCount,
            proofByteCount: proofByteCount
        ) <= budget
    }

    public init(
        chainPath: [String],
        config: IvyConfig,
        resources: NodeResourceConfig = .default,
        chainCount: Int = 1,
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections,
        minFeeRate: UInt64 = 0,
        gossipTuning: NodeTuning.Gossip = .init(),
        rateLimitTuning: NodeTuning.RateLimit = .init(),
        syncTuning: NodeTuning.Sync = .init(),
        sharedDiskBroker: DiskBroker,
        sharedTally: Tally? = nil,
        mempoolByteLimiter: MempoolByteLimiter? = nil
    ) async throws {
        // The leaf is this chain's directory; an empty path has no chain
        // identity, so fail loudly at the single construction chokepoint
        // rather than crashing later in `directory`/`ownerNamespace`.
        guard !chainPath.isEmpty else { throw NodeError.emptyChainPath }
        self.chainPath = chainPath
        self.gossipTuning = gossipTuning
        self.rateLimitTuning = rateLimitTuning
        self.syncTuning = syncTuning
        self.mempoolGossipBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.mempoolGossipCapacity,
            refillPerSec: rateLimitTuning.mempoolGossipRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.pinRequestBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.pinRequestCapacity,
            refillPerSec: rateLimitTuning.pinRequestRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.getHeadersBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.getHeadersCapacity,
            refillPerSec: rateLimitTuning.getHeadersRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.chainAnnounceBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.chainAnnounceCapacity,
            refillPerSec: rateLimitTuning.chainAnnounceRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.consensusRequestBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.getHeadersCapacity,
            refillPerSec: rateLimitTuning.getHeadersRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.childPeerRequestBuckets = PeerRateBuckets(
            capacity: rateLimitTuning.getHeadersCapacity,
            refillPerSec: rateLimitTuning.getHeadersRefillPerSec,
            maxEntries: Self.maxBucketEntries
        )
        self.rpcEndpoint = nil
        self.resources = resources
        let mempoolSize = resources.mempoolSizePerChain(chainCount: chainCount)
        // INTERFACE CONTRACT (mempool agent owns NodeMempool + NodeResourceConfig):
        // NodeMempool gains maxBytes/maxNonceGap/maxPerAccount/minFeeFloor (with
        // defaults) and NodeResourceConfig gains mempoolByteBudgetBytes/
        // mempoolMaxNonceGap/mempoolMaxPerAccount.
        // H7: the byte budget is a NODE-wide memory cap, enforced through a SHARED
        // cross-chain limiter (one accountant every chain's mempool debits) — NOT a
        // per-chain slice. This holds the total regardless of how many chains exist
        // or are registered later (a per-chain slice would either amplify via its
        // floor or grow as chains are added with stale immutable caps). A standalone
        // ChainNetwork (no shared limiter passed, e.g. tests) gets a private limiter
        // at the full budget — it IS one chain. A zero/unset budget => unbounded
        // bytes (count cap still applies), so `--mempool 0` admits.
        let byteLimiter = mempoolByteLimiter ?? MempoolByteLimiter(
            maxBytes: resources.mempoolByteBudgetBytes > 0 ? resources.mempoolByteBudgetBytes : nil
        )
        self.nodeMempool = NodeMempool(
            maxSize: mempoolSize,
            byteLimiter: byteLimiter,
            maxPerAccount: resources.mempoolMaxPerAccount,
            maxNonceGap: resources.mempoolMaxNonceGap,
            minFeeRate: minFeeRate
        )

        self.diskBroker = sharedDiskBroker

        let memoryBytes = resources.memoryBytesPerChain(chainCount: chainCount)
        let memory = MemoryBroker(byteBudget: memoryBytes)

        let tallyWithMaxPeers = TallyConfig(rateLimitBytesPerSecond: .infinity, maxPeers: maxPeerConnections)
        let ivyConfig = IvyConfig(
            publicKey: config.publicKey,
            listenPort: config.listenPort,
            bootstrapPeers: config.bootstrapPeers,
            enableLocalDiscovery: config.enableLocalDiscovery,
            tallyConfig: tallyWithMaxPeers,
            kBucketSize: config.kBucketSize,
            maxConcurrentRequests: config.maxConcurrentRequests,
            requestTimeout: config.requestTimeout,
            relayTimeout: config.relayTimeout,
            serviceType: config.serviceType,
            stunServers: config.stunServers,
            defaultTTL: config.defaultTTL,
            healthConfig: config.healthConfig,
            signingKey: config.signingKey,
            baseThresholdMultiplier: config.baseThresholdMultiplier,
            maxFrameSize: config.maxFrameSize,
            minPeerKeyBits: config.minPeerKeyBits,
            externalAddress: config.externalAddress,
            relayEnabled: config.relayEnabled,
            knownRelays: config.knownRelays
        )
        let ivy = Ivy(config: ivyConfig, tally: sharedTally)

        self.ivy = ivy

        memory.setNear(sharedDiskBroker)
        self.durableBroker = sharedDiskBroker
        self.broker = memory
        self.ivyFetcher = IvyFetcher(
            ivy: ivy, broker: memory,
            fetchDeadline: syncTuning.fetchDeadline, fetchPollInterval: syncTuning.fetchPollInterval
        )
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        await ivy.setDataSource(self)
        try await ivy.start()
    }

    public func stop() async {
        await ivy.stop()
    }

    // MARK: - Fetcher (unified read path)

    /// Volume-aware fetcher for all Cashew resolution: state, blocks, proofs.
    /// Local cache first, then Ivy's fee-based DHT.
    public var fetcher: IvyFetcher { ivyFetcher }

    // MARK: - Store (unified write path)

    /// Store data locally so it can be served after publish.
    ///
    /// B1(a): this is store-only. It must NOT pin under the bare `ownerNamespace`
    /// owner — that pin was never height-scoped, so `evictUnpinned` kept the root
    /// forever and retention could never reclaim it (a permanent pin leak). The
    /// published block is retained by `publishBlock`'s height-scoped pin (and by
    /// `commitBlockStorage`'s `ownerNamespace:<height>` pin), both of which prune
    /// releases on schedule.
    public func storeAndPublish(cid: String, data: Data) async {
        let payload = SerializedVolume(root: cid, entries: [cid: data])
        do {
            try await durableBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): storeAndPublish/storeVolumeLocal cid=\(String(cid.prefix(16)))… failed: \(error)")
        }
    }

    /// Store data locally only (no network publish).
    public func storeLocally(cid: String, data: Data) async {
        let payload = SerializedVolume(root: cid, entries: [cid: data])
        do {
            try await durableBroker.storeVolumeLocal(payload)
        } catch {
            NodeLogger("storage").error("\(directory): storeLocally cid=\(String(cid.prefix(16)))… failed: \(error)")
        }
    }

    /// Store a transaction as its proper OBJECT CLOSURE — the `VolumeImpl<Transaction>`
    /// volume with its body inline, the SAME grain block storage produces. A block
    /// references each transaction by its Transaction-volume root, so resolving a
    /// synced block needs that whole volume (Transaction node + body) served by
    /// root. If a node that admitted the tx only stored the body node standalone
    /// (`storeLocally`), it cannot serve the Transaction volume, and a peer syncing
    /// the block strands on the body it can't fetch as an internal entry. Storing
    /// the closure here makes every admitter a complete holder; body bytes dedup
    /// against the standalone copy via `INSERT OR IGNORE`.
    public func storeTransactionClosure(_ transaction: Transaction) async {
        do {
            let header = try VolumeImpl<Transaction>(node: transaction)
            let storer = BrokerStorer(broker: MemoryBroker())
            try header.storeRecursively(storer: storer)
            let volumes = storer.collectVolumes(root: header.rawCID)
            if !volumes.isEmpty {
                try await durableBroker.storeVolumesLocal(volumes)
                // Volumes are served by pins: admitting a tx is a commitment to
                // serve its closure to syncing peers until it lands in a block
                // (whose height-owner pin takes over) or goes stale. TTL-only —
                // no release path to leak; eviction reclaims after expiry.
                for volume in volumes {
                    try await durableBroker.pin(
                        root: volume.root, owner: "mempool", ttl: .seconds(86_400))
                }
            }
        } catch {
            NodeLogger("storage").error("\(directory): storeTransactionClosure failed: \(error)")
        }
    }

    public func storeBatch(_ entries: [(String, Data)]) async {
        guard !entries.isEmpty else { return }
        // P-702: one storeVolumesLocal transaction instead of N separate storeVolumeLocal calls
        let payloads = entries.map { SerializedVolume(root: $0.0, entries: [$0.0: $0.1]) }
        do {
            try await durableBroker.storeVolumesLocal(payloads)
        } catch {
            NodeLogger("storage").error("\(directory): storeBatch failed (\(entries.count) entries): \(error)")
        }
    }

    /// Store a batch that comprises a single Volume's merkle subtree.
    public func storeBlockBatch(rootCID: String, entries: [(String, Data)]) async {
        guard !rootCID.isEmpty else { return }
        var dict: [String: Data] = [:]
        dict.reserveCapacity(entries.count)
        for (cid, data) in entries {
            dict[cid] = data
        }
        let payload = SerializedVolume(root: rootCID, entries: dict)
        do {
            try await durableBroker.storeVolumesLocal([payload])
        } catch {
            NodeLogger("storage").error("\(directory): storeBlockBatch root=\(String(rootCID.prefix(16)))… (\(entries.count) entries) failed: \(error)")
        }
    }

    /// True iff the durable broker already has bytes for `cid`, whether `cid`
    /// is a volume root or an internal entry inside a stored volume.
    public func hasCID(_ cid: String) async -> Bool {
        await durableBroker.fetchDataLocal(cid: cid) != nil
    }

    public func storeVolumeDurably(_ payload: SerializedVolume) async throws {
        try await durableBroker.storeVolumesLocal([payload])
    }

    public func storeVolumesDurably(_ payloads: [SerializedVolume]) async throws {
        try await durableBroker.storeVolumesLocal(payloads)
    }

    public func pinDurably(root: String, owner: String) async throws {
        try await durableBroker.pin(root: root, owner: owner)
    }

    public func unpinDurably(root: String, owner: String) async throws {
        try await durableBroker.unpin(root: root, owner: owner)
    }

    public func pinBatchDurably(roots: [String], owner: String) async throws {
        try await diskBroker.pinBatch(roots: roots, owner: owner)
    }

    public func advanceRetainedRootsDurably(scope: String, roots: [String], operationID: String) async throws {
        guard let retainedBroker = durableBroker as? any RetainedRootBroker else {
            throw NodeError.chainNetworkNotRegistered(directory)
        }
        try await retainedBroker.advanceRetainedRoots(scope: scope, roots: roots, operationID: operationID)
    }

    public func mergeRetainedRootsDurably(scope: String, roots: [String], operationID: String) async throws {
        guard let retainedBroker = durableBroker as? any RetainedRootMergeBroker else {
            throw NodeError.chainNetworkNotRegistered(directory)
        }
        try await retainedBroker.mergeRetainedRoots(scope: scope, roots: roots, operationID: operationID)
    }

    public func retainedRootsDurably(scope: String) async -> [String] {
        guard let retainedBroker = durableBroker as? any RetainedRootBroker else { return [] }
        return await retainedBroker.retainedRoots(scope: scope)
    }

    public func retainedRootsDurablyRequired(scope: String) async throws -> [String] {
        return await diskBroker.retainedRoots(scope: scope)
    }

    public func unpinAllDurably(owner: String) async throws {
        try await durableBroker.unpinAll(owner: owner)
    }

    /// Owner enumeration for maintenance paths. Candidate pins are written through
    /// the durable broker, so stale-candidate release enumerates the same backend.
    public func pinnedOwners(prefix: String) async -> [String] {
        return await diskBroker.pinnedOwners(prefix: prefix)
    }

    /// The ValidatorPinReleaser seam for prune/reconcile. Validator pins live on
    /// the local nexus DiskBroker, so release targets the broker the pins were
    /// written to.
    nonisolated func validatorPinReleaser() -> any LatticeNode.ValidatorPinReleaser {
        diskBroker
    }

    /// DHT-free fetcher for canonical chain content.
    public nonisolated func canonicalContentFetcher() -> BrokerFetcher {
        BrokerFetcher(broker: durableBroker)
    }

    /// Storer for canonical chain content, paired with `canonicalContentFetcher()`.
    public nonisolated func canonicalContentStorer() -> BrokerStorer {
        BrokerStorer(broker: durableBroker)
    }

    /// Root-keyed, CID-verified local volume lookup.
    ///
    /// This is the bundle-grain counterpart to `canonicalContentFetcher()`: callers
    /// ask for the semantic content root they need. The in-process fetch cache is a
    /// secondary source only for already-held root-keyed bundles.
    public func verifiedLocalVolume(root: String) async -> SerializedVolume? {
        guard !root.isEmpty else { return nil }

        if let payload = await durableBroker.fetchVolumeLocal(root: root),
           Self.volume(payload, isVerifiedForRoot: root) {
            return payload
        }

        if let payload = await broker.fetchVolumeLocal(root: root),
           Self.volume(payload, isVerifiedForRoot: root) {
            return payload
        }

        return nil
    }

    private static func volume(_ payload: SerializedVolume, isVerifiedForRoot root: String) -> Bool {
        payload.root == root &&
            payload.entries[root] != nil &&
            payload.entries.allSatisfy { ContentAddressVerifier.data($0.value, matches: $0.key) }
    }

    /// Fetcher over the in-process FETCH-CACHE tier (the memory `broker` that
    /// `ivyFetcher.fetchVolumeBundle` persists freshly network-fetched bundles
    /// into, cascading to disk via `.near`). Use this — never
    /// `canonicalContentFetcher()` — to ENUMERATE a just-fetched bundle's
    /// sub-volume roots: the canonical fetcher reads the durable tier only and
    /// cannot see a bundle that has landed in the fetch cache but not yet been
    /// committed, so `.list` would enumerate nothing and strand sync. Not a
    /// content-serving path (it never reads the detached DiskBroker), so it is
    /// outside the RPC broker-selection guard.
    public nonisolated func fetchCacheFetcher() -> BrokerFetcher {
        BrokerFetcher(broker: broker)
    }

    static func acceptsChainAnnounce(_ announce: ChainAnnounceData, for directory: String) -> Bool {
        announce.chainDirectory == directory &&
        acceptsChainAnnounceMetadata(announce)
    }

    static func acceptsChainAnnounceMetadata(_ announce: ChainAnnounceData) -> Bool {
        LatticeProtocol.isCompatible(peerVersion: announce.protocolVersion) &&
        !announce.tipCID.isEmpty &&
        !announce.specCID.isEmpty
    }

    static func blockCIDMatches(_ cid: String, block: Block) -> Bool {
        // known-valid local node; CID cannot fail
        try! VolumeImpl<Block>(node: block).rawCID == cid
    }

    static func blockCIDMatches(_ cid: String, data: Data) -> Bool {
        guard let block = Block(data: data) else { return false }
        return blockCIDMatches(cid, block: block)
    }

    public func reannounceablePinnedRoots() async -> [String] {
        let query = Self.reannounceOwnerQuery(directory: directory, chainPath: chainPath)
        let pinnedRoots = await diskBroker.pinnedRoots(
            owners: query.owners,
            ownerPrefixes: query.ownerPrefixes
        )
        let retainedRoots = await retainedRootsDurably(scope: Self.stateRetainedRootScope(ownerNamespace: ownerNamespace))
        return Self.mergeRoots(primary: pinnedRoots, preserving: retainedRoots)
    }

    static func ownerNamespace(directory: String, chainPath: [String]) -> String {
        let path = chainPath.joined(separator: "/")
        return path.isEmpty ? directory : path
    }

    static func stateRetainedRootScope(ownerNamespace: String) -> String {
        "\(ownerNamespace):state-retained-roots"
    }

    static func mergeRoots(primary: [String], preserving existing: [String]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for root in primary + existing where !root.isEmpty {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    static func reannounceOwnerQuery(directory: String, chainPath: [String]) -> (owners: [String], ownerPrefixes: [String]) {
        let namespace = ownerNamespace(directory: directory, chainPath: chainPath)
        // The legacy bare `account:<ns>` owner is swept at startup by
        // `rebuildAccountPins`; nothing writes it anymore, so it is not
        // reannounced.
        let owners = [
            namespace,
        ]
        var ownerPrefixes = [
            "\(namespace):",
            "candidate:\(namespace):",
            // Own-tx pins are height-scoped (`account:<ns>:txwindow:<h>`,
            // pinAccountData/rebuildAccountPins); cover the whole window so the
            // node keeps announcing itself as a provider of its own tx data.
            "account:\(namespace):txwindow:",
        ]
        if chainPath.count == 1 {
            // `validates:` anchors are emitted by the single root/nexus chain
            // sharing this broker. Non-root chains must not reannounce them.
            ownerPrefixes.append("validates:")
        }
        return (owners, ownerPrefixes)
    }

    static func isReannounceOwner(_ owner: String, directory: String, chainPath: [String]) -> Bool {
        let query = reannounceOwnerQuery(directory: directory, chainPath: chainPath)
        if query.owners.contains(owner) {
            return true
        }
        return query.ownerPrefixes.contains { owner.hasPrefix($0) }
    }

    // MARK: - Mempool Operations

    public func pruneConfirmedTransactions(txCIDs: Set<String>) async {
        await nodeMempool.removeAll(txCIDs: txCIDs)
    }

    public func allMempoolTransactions() async -> [Transaction] {
        await nodeMempool.allTransactions()
    }

    // MARK: - Chain Announce (Tip Exchange)

    /// Send our chain tip to a specific peer so they can discover they're behind.
    public func sendChainAnnounce(to peer: PeerID, tipCID: String, tipHeight: UInt64, specCID: String) async {
        let announce = ChainAnnounceData(
            chainDirectory: directory,
            tipHeight: tipHeight,
            tipCID: tipCID,
            specCID: specCID
        )
        await ivy.sendMessage(to: peer, topic: "chainAnnounce", payload: announce.serialize())
    }

    /// Broadcast our chain tip to all connected peers.
    public func broadcastChainAnnounce(tipCID: String, tipHeight: UInt64, specCID: String) async {
        #if DEBUG
        broadcastChainAnnounceCallCountForTesting += 1
        lastBroadcastChainAnnounceTipForTesting = tipCID
        #endif
        let announce = ChainAnnounceData(
            chainDirectory: directory,
            tipHeight: tipHeight,
            tipCID: tipCID,
            specCID: specCID
        )
        await ivy.broadcastMessage(topic: "chainAnnounce", payload: announce.serialize())
    }

    #if DEBUG
    func resetTipPublishCountsForTesting() {
        broadcastChainAnnounceCallCountForTesting = 0
        lastBroadcastChainAnnounceTipForTesting = nil
    }

    func broadcastChainAnnounceCountForTesting() -> Int {
        broadcastChainAnnounceCallCountForTesting
    }

    func lastBroadcastChainAnnounceTipCIDForTesting() -> String? {
        lastBroadcastChainAnnounceTipForTesting
    }
    #endif
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }

    func setDataSource(_ ds: IvyDataSource) {
        self.dataSource = ds
    }
}

extension MemoryBroker {
    func setNear(_ broker: any VolumeBroker) {
        self.near = broker
    }
}

/// `DiskBroker` already implements `unpinAllBatch`; this conformance lets it stand
/// in for the validator-pin release seam the prune/reconcile core depends on.
extension DiskBroker: LatticeNode.ValidatorPinReleaser {}
