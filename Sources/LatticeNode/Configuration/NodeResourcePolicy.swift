/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    /// The bytes one content session may hold: a block's body and everything
    /// fetched with it to validate it.
    public let maximumAcquisitionStorageBytes: Int

    /// The bytes every content session holds at once, every hosted chain
    /// together (`--max-acquisition-bytes`): each session reserves its
    /// worst case from it when it starts, and waits while that does not
    /// fit. At least one session's bytes, so any one session can run.
    /// It bounds what sessions reserve, not the transient copies a walk
    /// makes beside them (about 1 to 1.5 times a body): not a hard limit
    /// on the process's memory.
    public let maximumAcquisitionBytes: Int

    public static let defaultMaximumAcquisitionBytes = 256 * 1_024 * 1_024

    /// The bytes of verified content finished sessions leave in memory for
    /// later reads (a fetched body for its connect, a template's reads for
    /// the block mined on it): a quarter of `maximumAcquisitionBytes`, on
    /// top of it. What goes first is in `ReadCache`.
    public var maximumCachedContentBytes: Int { maximumAcquisitionBytes / 4 }

    /// The bytes of post-state executions hold in memory before a flush
    /// writes them (`--max-unflushed-bytes`, Bitcoin's `-dbcache`, geth's
    /// `--cache`); executions are flushed at one per MiB of it too, since
    /// an empty block's leaves the state as it was. It bounds what a crash
    /// executes again.
    public let maximumUnflushedBytes: Int

    public static let defaultMaximumUnflushedBytes = 64 * 1_024 * 1_024

    public init(
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024,
        maximumAcquisitionBytes: Int = Self.defaultMaximumAcquisitionBytes,
        maximumUnflushedBytes: Int = Self.defaultMaximumUnflushedBytes
    ) {
        precondition(maximumAcquisitionStorageBytes > 0)
        precondition(maximumAcquisitionBytes >= maximumAcquisitionStorageBytes)
        precondition(maximumUnflushedBytes > 0)
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
        self.maximumAcquisitionBytes = maximumAcquisitionBytes
        self.maximumUnflushedBytes = maximumUnflushedBytes
    }
}
