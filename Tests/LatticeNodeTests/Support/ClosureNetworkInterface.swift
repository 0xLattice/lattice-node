import Foundation
import Lattice
import VolumeBroker
import cashew
@testable import LatticeNode

/// A `NetworkInterface` assembled from closures, one per operation. Omitted
/// operations are no-ops; an omitted body source admits broker-only and an
/// omitted evidence source finds nothing.
final class ClosureNetworkInterface: NetworkInterface {
    typealias ChildCandidateProvider = @Sendable (
        ChildCandidateRequestContext
    ) async throws -> [DirectChildCandidate]
    typealias ChainStateChangePublisher = @Sendable () async -> Void
    typealias DescendantPlanPublisher = @Sendable (
        _ rewards: [MiningReward],
        _ minimumWork: [MiningMinimumWork]
    ) async -> Void
    typealias ChildCandidateDigestProvider = @Sendable (
        _ parentStateCID: String
    ) async -> [String]
    typealias ChildProofPublisher = @Sendable (
        DirectChildProofPublication
    ) async throws -> Void
    typealias ParentRunReportPublisher = @Sendable (ParentRunReport) async throws -> Void
    typealias ParentRunReportRequester = @Sendable ([String]) async -> Void
    typealias AcceptedBlockPublisher = @Sendable (_ blockCID: String) async throws -> Void
    typealias AcceptedTransactionPublisher = @Sendable (
        _ volumeRootCID: String
    ) async throws -> Void
    /// Runs `admit` inside a body session bound to `blockCID`.
    typealias ValidateBodyImport = @Sendable (
        _ blockCID: String,
        _ admit: @Sendable (_ remoteSource: any ContentSource) async throws
            -> NodeImportOutcome
    ) async throws -> NodeImportOutcome
    typealias ValidateEvidenceSource = @Sendable (
        _ blockCID: String,
        _ requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage?

    private let childCandidateProvider: ChildCandidateProvider
    private let chainStateChangePublisher: ChainStateChangePublisher
    private let descendantPlanPublisher: DescendantPlanPublisher
    private let childCandidateDigestProvider: ChildCandidateDigestProvider
    private let childProofPublisher: ChildProofPublisher
    private let parentRunReportPublisher: ParentRunReportPublisher
    private let parentRunReportRequester: ParentRunReportRequester
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let validateBodySource: ValidateBodyImport?
    private let validateEvidenceSource: ValidateEvidenceSource?

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
        validateBodySource: ValidateBodyImport? = nil,
        validateEvidenceSource: ValidateEvidenceSource? = nil
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
        ) async throws -> NodeImportOutcome
    ) async throws -> NodeImportOutcome {
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
