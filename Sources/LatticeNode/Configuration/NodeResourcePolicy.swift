/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    /// The bytes one content session may hold: a block's body and everything
    /// fetched with it to validate it.
    public let maximumAcquisitionStorageBytes: Int

    public init(maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024) {
        precondition(maximumAcquisitionStorageBytes > 0)
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
    }
}
