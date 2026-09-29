import Foundation
import Lattice
import VolumeBroker
import cashew
@testable import LatticeNode

/// A `NetworkInterface` assembled from closures, one per operation. Omitted
/// operations are no-ops; an omitted body source admits broker-only and an
/// omitted evidence source finds nothing.
final class ClosureNetworkInterface: NetworkInterface {
    typealias ChainStateChangePublisher = @Sendable () async -> Void
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

    private let chainStateChangePublisher: ChainStateChangePublisher
    private let childProofPublisher: ChildProofPublisher
    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let executionBodySource: ExecutionBodyImport?

    init(
        chainStateChangePublisher: @escaping ChainStateChangePublisher = {},
        childProofPublisher: @escaping ChildProofPublisher,
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        acceptedTransactionPublisher: @escaping AcceptedTransactionPublisher = { _ in },
        executionBodySource: ExecutionBodyImport? = nil
    ) {
        self.chainStateChangePublisher = chainStateChangePublisher
        self.childProofPublisher = childProofPublisher
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.acceptedTransactionPublisher = acceptedTransactionPublisher
        self.executionBodySource = executionBodySource
    }

    func chainStateChanged() async {
        await chainStateChangePublisher()
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
