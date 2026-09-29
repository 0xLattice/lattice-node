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
    typealias AcceptedBlockPublisher = @Sendable (_ blockCID: String) async throws -> Void
    typealias AcceptedTransactionPublisher = @Sendable (
        _ volumeRootCID: String
    ) async throws -> Void
    /// Runs `admit` inside a body session bound to `blockCID`.
    typealias ExecutionBodyImport = @Sendable (
        _ blockCID: String,
        _ admit: @Sendable (_ remoteSource: any ContentSource) async throws
            -> NodeImportOutcome
    ) async throws -> NodeImportOutcome

    private let childCandidateProvider: ChildCandidateProvider
    private let chainStateChangePublisher: ChainStateChangePublisher
    private let descendantPlanPublisher: DescendantPlanPublisher
    private let childCandidateDigestProvider: ChildCandidateDigestProvider
    private let childProofPublisher: ChildProofPublisher
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let executionBodySource: ExecutionBodyImport?

    init(
        childCandidateProvider: @escaping ChildCandidateProvider,
        chainStateChangePublisher: @escaping ChainStateChangePublisher = {},
        descendantPlanPublisher: @escaping DescendantPlanPublisher = { _, _ in },
        childCandidateDigestProvider: @escaping ChildCandidateDigestProvider = { _ in [] },
        childProofPublisher: @escaping ChildProofPublisher,
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        acceptedTransactionPublisher: @escaping AcceptedTransactionPublisher = { _ in },
        executionBodySource: ExecutionBodyImport? = nil
    ) {
        self.childCandidateProvider = childCandidateProvider
        self.chainStateChangePublisher = chainStateChangePublisher
        self.descendantPlanPublisher = descendantPlanPublisher
        self.childCandidateDigestProvider = childCandidateDigestProvider
        self.childProofPublisher = childProofPublisher
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.acceptedTransactionPublisher = acceptedTransactionPublisher
        self.executionBodySource = executionBodySource
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

    func publishAcceptedBlock(_ blockCID: String) async throws {
        try await acceptedBlockPublisher(blockCID)
    }

    func publishTransaction(_ volumeRootCID: String) async throws {
        try await acceptedTransactionPublisher(volumeRootCID)
    }

    func withExecutionBodySource(
        blockCID: String,
        _ admit: @Sendable (
            _ remoteSource: (any ContentSource)?
        ) async throws -> NodeImportOutcome
    ) async throws -> NodeImportOutcome {
        guard let executionBodySource else { return try await admit(nil) }
        return try await executionBodySource(blockCID) { remoteSource in
            try await admit(remoteSource)
        }
    }
}
