/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    public let maximumAcquisitionVolumes: Int
    public let maximumAcquisitionMembers: Int
    public let maximumAcquisitionStorageBytes: Int

    public init(
        maximumAcquisitionVolumes: Int = 20_548,
        maximumAcquisitionMembers: Int = Int(UInt16.max),
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024
    ) {
        precondition(
            maximumAcquisitionVolumes > 0
                && maximumAcquisitionMembers > 0
                && maximumAcquisitionStorageBytes > 0
        )
        self.maximumAcquisitionVolumes = maximumAcquisitionVolumes
        self.maximumAcquisitionMembers = maximumAcquisitionMembers
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
    }
}
