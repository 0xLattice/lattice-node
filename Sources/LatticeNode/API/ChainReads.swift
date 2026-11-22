import Foundation
import Ivy
import Lattice
import LatticeLightClient
import LatticeNodeCore
import cashew
import LatticeNodeAPI

/// The node's read surface — chain status, blocks, transactions, state reads
/// and the explorer API — over content-verified, by-CID reads of this
/// chain's store and a tip source. Nothing here takes a gate or mutates:
/// content is immutable by CID, so only the tip, the canonical height index
/// and the mempool listing are read live from `NodeRuntime`'s published view.
public struct ChainReads: Sendable {
    public struct MempoolListing: Sendable {
        public let count: Int
        public let bytes: Int
        /// The pooled transaction CIDs.
        public let cids: [String]
        /// The pool's next blocks, for fee pricing (`Mempool.projectedBlocks`).
        public let projected: [ProjectedBlock]
        /// What their rates are over, from the spec they were projected with.
        public let weight: FeeWeight?

        public init(count: Int, bytes: Int, cids: [String], projected: [ProjectedBlock] = [], weight: FeeWeight? = nil) {
            self.count = count
            self.bytes = bytes
            self.cids = cids
            self.projected = projected
            self.weight = weight
        }
    }

    static let maximumReadResponseBytes = Int(IvyConfig.defaultProtocolMaxFrameSize)
    static let maximumExplorerPageLimit = 100
    static let maximumExplorerMempoolListing = 200
    /// Each listed height costs three local reads (index, block, transactions
    /// root), and the list is billed as a cheap read: a page stays small.
    public static let maximumExplorerBlocksPage = 25

    static func boundedExplorerLimit(_ limit: Int) -> Int {
        min(max(limit, 0), maximumExplorerPageLimit)
    }

    let storage: NodeStorage
    /// What state reads (an executed block's post-state: accounts, nonces,
    /// deposits, receipts) read through when this store lacks it (nil: this
    /// store alone), and a child chain's hosts, asked first. State is a
    /// cache: a node of it this store let go of is read again, never
    /// answered as absent. Block bodies (a block's transactions and children
    /// index) and anything asked for by CID are read from this store alone:
    /// which bodies a node keeps is the operator's choice (`blockBodies`),
    /// and a reader cannot make this node fetch whatever it names.
    let remote: IvyRootContentSource?
    let hosts: ChainHosts?
    /// The tip readers see: the tip this node acts on, its heaviest executed tip.
    let tip: @Sendable () async -> ChainStatus
    /// The block at a height of the chain to that tip.
    let canonicalCID: @Sendable (UInt64) async -> String?
    /// The child directories this chain's executed blocks commit (the level
    /// core's grow-only list).
    let childDirectories: @Sendable () async -> ExecutedChildren?
    /// The pool's size, and its CIDs only when `listing` (status reads
    /// never build the listing).
    let mempool: @Sendable (_ listing: Bool) async -> MempoolListing
    /// The chain these reads serve: the root, or a hosted child level.
    public let chainPath: [String]
    /// Whether this chain durably accepted a block (its own journal).
    let accepted: @Sendable (String) async -> Bool
    /// This chain's current peers: the open sessions that serve it.
    public let peerCount: @Sendable () -> Int
    /// `committedChild`'s walk, done once per tip for every name.
    let committedChildren = CommittedChildren()

    init(
        storage: NodeStorage,
        remote: IvyRootContentSource? = nil,
        chainPath: [String]? = nil,
        accepted: (@Sendable (String) async -> Bool)? = nil,
        tip: @escaping @Sendable () async -> ChainStatus,
        canonicalCID: @escaping @Sendable (UInt64) async -> String?,
        childDirectories: @escaping @Sendable () async -> ExecutedChildren? = { nil },
        mempool: @escaping @Sendable (_ listing: Bool) async -> MempoolListing,
        peerCount: @escaping @Sendable () -> Int = { 0 }
    ) {
        self.storage = storage
        let chainPath = chainPath ?? storage.configuration.chainPath
        self.remote = remote
        self.hosts = ChainHosts.of(chainPath, nexusGenesisCID: storage.configuration.nexusGenesisCID)
        self.chainPath = chainPath
        if let accepted {
            self.accepted = accepted
        } else {
            self.accepted = { await storage.hasAcceptedBlock($0) }
        }
        self.tip = tip
        self.canonicalCID = canonicalCID
        self.childDirectories = childDirectories
        self.mempool = mempool
        self.peerCount = peerCount
    }

    /// Public status read over the immutable published view.
    public func readSnapshot() async -> NodeStatusResponse {
        let status = await tip()
        let pool = await mempool(false)
        let phase: NodeAPIPhase = status.phase == .active
            ? .active
            : .awaitingGenesis
        return NodeStatusResponse(
            phase: phase,
            chainPath: status.chainPath,
            nexusGenesisCID: status.nexusGenesisCID,
            tipCID: status.tipCID,
            height: status.height,
            revision: status.revision,
            mempoolCount: pool.count,
            mempoolBytes: pool.bytes,
            templateDigest: nil,
            bestHeaderHeight: status.bestHeaderHeight,
            waiting: status.waiting
        )
    }

    /// A decoded, content-verified block, gated to only what this node has
    /// durably accepted. It reads `NodeStorage` directly without entering the
    /// runtime loop.
    func block(cid: String) async -> Block? {
        guard await accepted(cid) else { return nil }
        guard let data = await storage.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        return _contentBoundBlock(cid: cid, data: data)
    }

    /// An executed block's own node, for reading the state it commits to:
    /// held here even when the block's body is not. A block this node has
    /// only weighed commits to a state nobody here has checked, and is not
    /// answered for.
    func blockNode(cid: String) async -> Block? {
        guard await storage.hasExecutedBlock(cid, at: chainPath),
              let data = await storage.blockNodeBytes(cid),
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        return _contentBoundBlock(cid: cid, data: data)
    }

    /// Bounded public read: a decoded, content-verified transaction. Resolving
    /// and content-binding as a `Transaction` is itself the gate that keeps
    /// internal (non-transaction) objects from being served by CID.
    public func transaction(cid: String) async -> Transaction? {
        guard let data = await storage.content([cid])[cid],
              data.count <= Self.maximumReadResponseBytes else {
            return nil
        }
        guard let transaction = Transaction(data: data),
              (try? VolumeImpl<Transaction>(node: transaction).rawCID) == cid
        else { return nil }
        return transaction
    }

    /// One read's state, in one session: this store, then what is in memory,
    /// then peers (a child chain's hosts first). The session reserves one
    /// frame, the most a peer's answer holds, and only once something is
    /// missing: a read of what this store holds costs no budget, and one
    /// read can never fetch more than a frame. Peers' answers are not kept
    /// for later reads, so readers do not evict what the node's own work
    /// fetched. A reader that went away stops the session.
    func readingState<T: Sendable>(
        _ rootCID: String, _ work: @Sendable (any Fetcher) async throws -> T
    ) async rethrows -> T {
        guard let remote else { return try await work(storage) }
        let storage = storage
        return try await remote.withRootTracing(
            rootCID, bundle: false, hosts: hosts, reserving: Int(IvyConfig.defaultProtocolMaxFrameSize)
        ) { session in
            try await work(storage.readersReads(through: session, .anyChain))
        }.value
    }

    /// Bounded public read: an account's balance and next-expected nonce as of
    /// one accepted block's post-state. It uses direct storage reads plus
    /// targeted trie resolution without entering the runtime loop.
    public func account(
        owner: String,
        blockCID: String
    ) async -> (balance: UInt64, nonce: UInt64)? {
        guard let block = await blockNode(cid: blockCID) else { return nil }
        return await readingState(blockCID) { fetcher in await Self.account(owner: owner, in: block, fetcher: fetcher) }
    }

    private static func account(
        owner: String, in block: Block, fetcher: any Fetcher
    ) async -> (balance: UInt64, nonce: UInt64)? {
        guard let state = try? await block.postState.resolve(fetcher: fetcher).node else {
            return nil
        }
        guard let nonce = try? await state.accountState.nextExpectedNonce(
                for: owner,
                fetcher: fetcher
              ),
              let resolved = try? await state.accountState.resolve(
                paths: [[owner]: .targeted],
                fetcher: fetcher
              ),
              let accountNode = resolved.node else {
            return nil
        }
        let balance: UInt64 = (try? accountNode.get(key: owner)) ?? 0
        return (balance: balance, nonce: nonce)
    }
}

actor CommittedChildren {
    private var latest: (tip: String, build: Task<[String: String], Never>)?

    func at(_ tip: String, build: @escaping @Sendable () async -> [String: String]) async -> [String: String] {
        if let latest, latest.tip == tip { return await latest.build.value }
        let task = Task { await build() }
        latest = (tip, task)
        return await task.value
    }
}
