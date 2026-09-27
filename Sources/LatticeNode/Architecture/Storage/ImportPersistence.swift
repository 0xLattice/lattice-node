/// What one admission batch persists beyond its facts and Volume roots.
struct ImportPersistence: Sendable {
    var status: BlockStatus = .executed
    var pendingChildProofRoutes: [PendingChildProofRoute] = []
    var pendingChildProofCapacity: Int = 16
    var hierarchyArtifacts: AdmissionHierarchyArtifacts? = nil
    var incomingCarrierEvidence: AdmissionCarrierEvidence? = nil
    var consensusRevisionFloor: UInt64? = nil

    /// Facts only: replay, validation and parent-report batches.
    static let factsOnly = ImportPersistence()
}
