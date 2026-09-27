import Foundation
import Lattice
import VolumeBroker
import cashew

/// A `NetworkInterface` assembled from closures, one per operation. Omitted
/// operations are no-ops; an omitted body source admits broker-only and an
/// omitted evidence source finds nothing.
final class ClosureNetworkInterface: NetworkInterface {
    private let childCandidateProvider: ChildCandidateProvider
    private let chainStateChangePublisher: ChainStateChangePublisher
    private let descendantPlanPublisher: DescendantPlanPublisher
    private let childCandidateDigestProvider: ChildCandidateDigestProvider
    private let childProofPublisher: ChildProofPublisher
    private let parentRunReportPublisher: ParentRunReportPublisher
    private let parentRunReportRequester: ParentRunReportRequester
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let validateBodySource: ValidateBodyAdmission?
    private let validateEvidenceSource: ChainService.ValidateEvidenceSource?

    init(
        childCandidateProvider: @escaping ChildCandidateProvider,
        chainStateChangePublisher: @escaping ChainStateChangePublisher = {},
        descendantPlanPublisher: @escaping DescendantPlanPublisher = { _, _ in },
        childCandidateDigestProvider: @escaping ChildCandidateDigestProvider = { _ in [] },
        childProofPublisher: @escaping ChildProofPublisher,
        parentRunReportPublisher: @escaping ParentRunReportPublisher = { _ in },
        parentRunReportRequester: @escaping ParentRunReportRequester = { _ in },
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        acceptedTransactionPublisher: @escaping AcceptedTransactionPublisher = { _ in },
        validateBodySource: ValidateBodyAdmission? = nil,
        validateEvidenceSource: ChainService.ValidateEvidenceSource? = nil
    ) {
        self.childCandidateProvider = childCandidateProvider
        self.chainStateChangePublisher = chainStateChangePublisher
        self.descendantPlanPublisher = descendantPlanPublisher
        self.childCandidateDigestProvider = childCandidateDigestProvider
        self.childProofPublisher = childProofPublisher
        self.parentRunReportPublisher = parentRunReportPublisher
        self.parentRunReportRequester = parentRunReportRequester
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.acceptedTransactionPublisher = acceptedTransactionPublisher
        self.validateBodySource = validateBodySource
        self.validateEvidenceSource = validateEvidenceSource
    }

    func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async throws -> [DirectChildCandidate] {
        try await childCandidateProvider(context)
    }

    func chainStateChanged() async {
        await chainStateChangePublisher()
    }

    func updateDescendantPlan(
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork]
    ) async {
        await descendantPlanPublisher(rewards, minimumWork)
    }

    func childCandidateDigestInput(parentStateCID: String) async -> [String] {
        await childCandidateDigestProvider(parentStateCID)
    }

    func publishChildProof(_ publication: DirectChildProofPublication) async throws {
        try await childProofPublisher(publication)
    }

    func announceParentRunReport(_ report: ParentRunReport) async throws {
        try await parentRunReportPublisher(report)
    }

    func requestParentRunReports(committers: [String]) async {
        await parentRunReportRequester(committers)
    }

    func publishAcceptedBlock(_ blockCID: String) async throws {
        try await acceptedBlockPublisher(blockCID)
    }

    func publishTransaction(_ volumeRootCID: String) async throws {
        try await acceptedTransactionPublisher(volumeRootCID)
    }

    func withValidateBodySource(
        blockCID: String,
        _ admit: @Sendable (
            _ remoteSource: (any ContentSource)?
        ) async throws -> NodeAdmissionOutcome
    ) async throws -> NodeAdmissionOutcome {
        guard let validateBodySource else { return try await admit(nil) }
        return try await validateBodySource(blockCID) { remoteSource in
            try await admit(remoteSource)
        }
    }

    func resolveValidateEvidence(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage? {
        guard let validateEvidenceSource else { return nil }
        return await validateEvidenceSource(blockCID, requirement)
    }
}
