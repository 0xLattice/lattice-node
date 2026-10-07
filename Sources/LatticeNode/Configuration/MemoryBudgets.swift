import LatticeNodeCore

/// Memory this node spends on peers' unverified input, its transaction pool
/// and its queued replies: operator policy, in bytes, with the node's
/// defaults.
public struct MemoryBudgets: Sendable, Equatable {
    /// Child proofs one peer may have queued or in flight, not yet verified.
    public var syncMaxUnverifiedBytesPerPeer: Int
    /// Headers held per level that do not yet connect.
    public var syncMaxPendingBytes: Int
    /// Transactions held in each level's pool.
    public var mempoolMaxBytes: Int
    /// Sync messages queued to one session that is not draining.
    public var syncMaxQueuedBytesPerSession: Int

    public init(
        syncMaxUnverifiedBytesPerPeer: Int = ChildProofConfig().maxSourceBytes,
        syncMaxPendingBytes: Int = ChainCoreConfig().pendingBudget,
        mempoolMaxBytes: Int = MempoolLimits().maxBytes,
        syncMaxQueuedBytesPerSession: Int = 8 * 1_024 * 1_024
    ) {
        self.syncMaxUnverifiedBytesPerPeer = syncMaxUnverifiedBytesPerPeer
        self.syncMaxPendingBytes = syncMaxPendingBytes
        self.mempoolMaxBytes = mempoolMaxBytes
        self.syncMaxQueuedBytesPerSession = syncMaxQueuedBytesPerSession
    }

    public static let `default` = MemoryBudgets()
}
