import Foundation
import Lattice
import VolumeBroker
import cashew
@testable import LatticeNode

/// A `NetworkInterface` assembled from closures, one per operation. Omitted
/// operations are no-ops; an omitted body source admits broker-only and an
/// omitted evidence source finds nothing.
final class ClosureNetworkInterface: NetworkInterface {
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

    private let acceptedBlockPublisher: AcceptedBlockPublisher
    private let acceptedTransactionPublisher: AcceptedTransactionPublisher
    private let executionBodySource: ExecutionBodyImport?

    init(
        acceptedBlockPublisher: @escaping AcceptedBlockPublisher,
        acceptedTransactionPublisher: @escaping AcceptedTransactionPublisher = { _ in },
        executionBodySource: ExecutionBodyImport? = nil
    ) {
        self.acceptedBlockPublisher = acceptedBlockPublisher
        self.acceptedTransactionPublisher = acceptedTransactionPublisher
        self.executionBodySource = executionBodySource
    }

    func announceCarriedEvidence(_ package: AuthenticatedChildPackage) async {}

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
