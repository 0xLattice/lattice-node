/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    public let maximumChainSpecBytes: Int
    public let maximumParentWitnessBytes: Int
    public let maximumPendingParentEvidence: Int
    public let maximumWasmPolicies: Int
    public let maximumAcquisitionVolumes: Int
    public let maximumAcquisitionMembers: Int
    public let maximumAcquisitionStorageBytes: Int
    /// Per-query visit budget for serving a child's parent-state continuity
    /// question. The walk runs on the consensus actor, so this bounds how
    /// long one fact-plane query can hold it. Exhaustion is served as
    /// silence, which a child already treats as retryable unavailability.
    public let maximumContinuityBlockVisits: Int
    /// Storage budget for handed-off contextual candidates awaiting
    /// admission. A handoff is a local cache of durable ownership, not a
    /// consensus commitment: an evicted candidate whose branch returns is
    /// re-acquired through ordinary verified acquisition. Oldest first.
    public let maximumRetainedHandoffCandidates: Int

    public init(
        maximumChainSpecBytes: Int = 1 * 1_024 * 1_024,
        maximumParentWitnessBytes: Int =
            Int(IvyConfig.defaultProtocolMaxFrameSize) - 1_024,
        maximumPendingParentEvidence: Int = 64,
        maximumWasmPolicies: Int = 64,
        maximumAcquisitionVolumes: Int = 20_548,
        maximumAcquisitionMembers: Int = Int(UInt16.max),
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024,
        maximumContinuityBlockVisits: Int = 4_096,
        maximumRetainedHandoffCandidates: Int = 1_024
    ) {
        precondition(
            maximumChainSpecBytes > 0
                && maximumParentWitnessBytes > 0
                && maximumPendingParentEvidence > 0
                && maximumWasmPolicies > 0
                && maximumAcquisitionVolumes > 0
                && maximumAcquisitionMembers > 0
                && maximumAcquisitionStorageBytes > 0
                && maximumContinuityBlockVisits > 0
                && maximumRetainedHandoffCandidates > 0
        )
        self.maximumChainSpecBytes = maximumChainSpecBytes
        self.maximumParentWitnessBytes = maximumParentWitnessBytes
        self.maximumPendingParentEvidence = maximumPendingParentEvidence
        self.maximumWasmPolicies = maximumWasmPolicies
        self.maximumAcquisitionVolumes = maximumAcquisitionVolumes
        self.maximumAcquisitionMembers = maximumAcquisitionMembers
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
        self.maximumContinuityBlockVisits = maximumContinuityBlockVisits
        self.maximumRetainedHandoffCandidates = maximumRetainedHandoffCandidates
    }
}
import Ivy
