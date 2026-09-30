/// Node-local resource willingness. Exceeding one of these limits means this
/// node declines the work; it does not make otherwise valid chain data invalid.
public struct NodeResourcePolicy: Sendable, Equatable {
    public static let `default` = NodeResourcePolicy()

    public let maximumChainSpecBytes: Int
    public let maximumWasmPolicies: Int
    public let maximumAcquisitionVolumes: Int
    public let maximumAcquisitionMembers: Int
    public let maximumAcquisitionStorageBytes: Int
    /// Candidates this chain built for its parent and still keeps — body,
    /// transactions, post-state — so a parent block that carries one can be
    /// admitted from what is held here. A local budget, never a parent's
    /// reservation; the oldest offer goes first.
    public let maximumRetainedCandidateOffers: Int
    /// Storage budget for walk-validated state OFF the canonical chain (fork
    /// loss = cache eviction): how many losing-fork blocks keep their
    /// materialized body + post-state, nearest the validated head first. The
    /// rest are demoted to weighed and their state reclaimed; the blocks stay
    /// accepted, and a demoted block whose fork returns is simply re-validated
    /// by the walk. Operator choice with no protocol meaning; `0` keeps none.
    public let maximumRetainedOffChainValidatedBlocks: Int
    /// How far below the validated head an off-chain walk-validated block must
    /// be before it is a demotion candidate at all, whatever the budget: a
    /// fork still within this depth may yet win. Operator choice with no
    /// protocol meaning; `0` makes every block below the head a candidate.
    public let offChainValidatedRetentionDepth: Int

    public init(
        maximumChainSpecBytes: Int = 1 * 1_024 * 1_024,
        maximumWasmPolicies: Int = 64,
        maximumAcquisitionVolumes: Int = 20_548,
        maximumAcquisitionMembers: Int = Int(UInt16.max),
        maximumAcquisitionStorageBytes: Int = 64 * 1_024 * 1_024,
        maximumRetainedCandidateOffers: Int = 64,
        maximumRetainedOffChainValidatedBlocks: Int = 1_024,
        offChainValidatedRetentionDepth: Int = 256
    ) {
        precondition(
            maximumChainSpecBytes > 0
                && maximumWasmPolicies > 0
                && maximumAcquisitionVolumes > 0
                && maximumAcquisitionMembers > 0
                && maximumAcquisitionStorageBytes > 0
                && maximumRetainedCandidateOffers > 0
                && maximumRetainedOffChainValidatedBlocks >= 0
                && offChainValidatedRetentionDepth >= 0
        )
        self.maximumChainSpecBytes = maximumChainSpecBytes
        self.maximumWasmPolicies = maximumWasmPolicies
        self.maximumAcquisitionVolumes = maximumAcquisitionVolumes
        self.maximumAcquisitionMembers = maximumAcquisitionMembers
        self.maximumAcquisitionStorageBytes = maximumAcquisitionStorageBytes
        self.maximumRetainedCandidateOffers = maximumRetainedCandidateOffers
        self.maximumRetainedOffChainValidatedBlocks =
            maximumRetainedOffChainValidatedBlocks
        self.offChainValidatedRetentionDepth = offChainValidatedRetentionDepth
    }
}
import Ivy
