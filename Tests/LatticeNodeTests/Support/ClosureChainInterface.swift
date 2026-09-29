import Foundation
import Lattice
import VolumeBroker
import cashew
@testable import LatticeNode

/// A `ChainInterface` assembled from closures. Admission is required; each
/// optional closure supplied grants its capability, and an omitted one
/// leaves the network behaviour behind it disabled.
final class ClosureChainInterface: ChainInterface {
    typealias ChildCandidateBuilder = @Sendable (
        _ context: ChildCandidateRequestContext,
        _ parentContentSource: any ContentSource
    ) async throws -> DirectChildCandidate?
    typealias ImportHandler = @Sendable (
        _ admission: NetworkCandidateImport
    ) async throws -> NodeImportOutcome
    typealias TransactionHandler = @Sendable (
        _ transaction: Transaction
    ) async throws -> Bool
    typealias TransactionInventoryProvider = @Sendable () async -> [String]

    private let childCandidateBuilder: ChildCandidateBuilder?
    private let admission: ImportHandler
    private let transaction: TransactionHandler?
    private let transactionInventory: TransactionInventoryProvider?
    let networkCapabilities: ChainNetworkCapabilities

    init(
        childCandidateBuilder: ChildCandidateBuilder? = nil,
        admission: @escaping ImportHandler,
        transaction: TransactionHandler? = nil,
        transactionInventory: TransactionInventoryProvider? = nil
    ) {
        self.childCandidateBuilder = childCandidateBuilder
        self.admission = admission
        self.transaction = transaction
        self.transactionInventory = transactionInventory
        var capabilities: ChainNetworkCapabilities = []
        if childCandidateBuilder != nil { capabilities.insert(.childCandidates) }
        if transaction != nil { capabilities.insert(.transactions) }
        if transactionInventory != nil { capabilities.insert(.transactionInventory) }
        networkCapabilities = capabilities
    }

    func miningCandidate(
        for context: ChildCandidateRequestContext,
        parentContentSource: any ContentSource
    ) async throws -> DirectChildCandidate? {
        guard let childCandidateBuilder else { return nil }
        return try await childCandidateBuilder(context, parentContentSource)
    }

    func importNetworkCandidate(
        _ admission: NetworkCandidateImport
    ) async throws -> NodeImportOutcome {
        try await self.admission(admission)
    }

    func submitNetworkTransaction(_ transaction: Transaction) async throws -> Bool {
        guard let handler = self.transaction else { throw CancellationError() }
        return try await handler(transaction)
    }

    func transactionInventoryRoots() async -> [String] {
        await transactionInventory?() ?? []
    }

    func genesisActivatedOutOfBand() async {}
}
