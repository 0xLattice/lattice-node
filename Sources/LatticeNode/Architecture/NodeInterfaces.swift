import Foundation
import Lattice
import VolumeBroker
import cashew

/// Internal publication passed directly to the hierarchy runtime. Deliberately
/// not Codable so it cannot accidentally become an HTTP DTO.
public struct DirectChildProofPublication: Sendable {
    public let directory: String
    public let childCID: String
    public let proof: ChildBlockProof
}

/// What a parent level asks each hosted child level to build its candidate
/// against: the provisional carrier, and the miner's plan for the child's
/// subtree. The template's deadline (`ChildCandidateBudget`) bounds the ask; a
/// child that misses it is not carried this round.
public struct ChildCandidateRequestContext: Sendable {
    public let parentCarrier: Block
    public let rewards: [MiningReward]
    /// The requesting miner's minimum work for descendant chains.
    public let minimumWork: [MiningMinimumWork]
    public let excludedDirectories: Set<String>

    public init(
        parentCarrier: Block,
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork] = [],
        excludedDirectories: Set<String> = []
    ) {
        self.parentCarrier = parentCarrier
        self.rewards = rewards
        self.minimumWork = minimumWork
        self.excludedDirectories = excludedDirectories
    }
}

/// What `ChainService` needs from the network runtime.
public protocol NetworkInterface: AnyObject, Sendable {
    /// Something changed on this chain: the validated tip, the mempool, a
    /// credit. The runtime re-sends the evidence hints its send budget refused.
    func chainStateChanged() async
    func publishChildProof(_ publication: DirectChildProofPublication) async throws
    func publishAcceptedBlock(_ blockCID: String) async throws
    func publishTransaction(_ volumeRootCID: String) async throws
    /// Opens a network body-acquisition session bound to one block's root and
    /// runs the caller's admission inside it. A weighed admit (deferred
    /// execution) stores only the block boundary, so the validate-on-candidacy
    /// walk must pull the deferred body (tier-3: tx bodies, validation-path
    /// states, WASM modules) over the network before it can execute the block.
    /// The session composes broker-first under `admit`, so an already-local
    /// boundary is served free and only the missing body is fetched. An
    /// interface with no network body source runs `admit(nil)`: broker-only,
    /// as unit contexts that admit empty blocks (whose boundary already is the
    /// whole block) do.
    func withExecutionBodySource(
        blockCID: String,
        _ admit: @Sendable (
            _ remoteSource: (any ContentSource)?
        ) async throws -> NodeImportOutcome
    ) async throws -> NodeImportOutcome
}

/// Which optional `ChainInterface` operations a network-runtime generation
/// may use. A missing capability disables the network behaviour behind it
/// (transaction relay, inventory sync).
public struct ChainNetworkCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let transactions = ChainNetworkCapabilities(rawValue: 1 << 1)
    public static let transactionInventory = ChainNetworkCapabilities(rawValue: 1 << 2)

    public static let all: ChainNetworkCapabilities = [
        .transactions, .transactionInventory,
    ]
}

/// What `NodeNetworkRuntime` needs from the chain service. Admission is
/// always available; every other operation is used only when its capability
/// is in `networkCapabilities`.
public protocol ChainInterface: AnyObject, Sendable {
    var networkCapabilities: ChainNetworkCapabilities { get }
    func importNetworkCandidate(
        _ admission: NetworkCandidateImport
    ) async throws -> NodeImportOutcome
    func submitNetworkTransaction(_ transaction: Transaction) async throws -> Bool
    func transactionInventoryRoots() async -> [String]
    /// This chain's genesis activated outside candidate admission (adopted
    /// from the parent's record): its tip moved from nothing.
    func genesisActivatedOutOfBand() async
}

/// The service's view of the runtime. Holds the runtime weakly, so the
/// service never keeps the network alive (the runtime reaches the service
/// through `WeakChain`); a released runtime answers each call with the
/// fallback below.
final class WeakNetwork: @unchecked Sendable, NetworkInterface {
    private weak var runtime: NodeNetworkRuntime?

    init(_ runtime: NodeNetworkRuntime) {
        self.runtime = runtime
    }

    func chainStateChanged() async {
        await runtime?.chainStateChanged()
    }

    func publishChildProof(_ publication: DirectChildProofPublication) async throws {
        guard let runtime else { throw CancellationError() }
        _ = try await runtime.publishChildProof(
            publication.proof,
            childDirectory: publication.directory,
            childCID: publication.childCID
        )
    }

    func publishAcceptedBlock(_ blockCID: String) async throws {
        guard let runtime else { throw CancellationError() }
        try await runtime.publishAcceptedBlock(blockCID)
    }

    func publishTransaction(_ volumeRootCID: String) async throws {
        guard let runtime else { throw CancellationError() }
        try await runtime.publishTransaction(volumeRootCID)
    }

    func withExecutionBodySource(
        blockCID: String,
        _ admit: @Sendable (
            _ remoteSource: (any ContentSource)?
        ) async throws -> NodeImportOutcome
    ) async throws -> NodeImportOutcome {
        // A weighed admit stored only the boundary; pull the deferred body
        // over the network by opening a root session on the block CID (the
        // same public-pin resolution the candidate fetcher falls back to),
        // and admit `.execution` inside it so [broker, session] serves the
        // local boundary free and fetches only the missing body.
        guard let runtime else { throw CancellationError() }
        return try await runtime.remoteContentSource
            .withRoot(blockCID) { session in
                try await admit(session)
            }
    }
}

/// The runtime's view of the service. Holds the service weakly (the service
/// reaches the runtime through `WeakNetwork`); a released service answers
/// each call with the fallback below. Every capability is on.
final class WeakChain: @unchecked Sendable, ChainInterface {
    private weak var service: ChainService?
    let networkCapabilities = ChainNetworkCapabilities.all

    init(_ service: ChainService) {
        self.service = service
    }

    func importNetworkCandidate(
        _ admission: NetworkCandidateImport
    ) async throws -> NodeImportOutcome {
        guard let service else { throw CancellationError() }
        return try await service.importNetworkCandidate(
            admission.header,
            authenticatedChildPackage: admission.authenticatedChildPackage,
            preparingChildDirectories: admission.preparingChildDirectories,
            contentSource: admission.contentSource,
            weighed: admission.weighed
        )
    }

    func submitNetworkTransaction(_ transaction: Transaction) async throws -> Bool {
        guard let service else { throw CancellationError() }
        return try await service.submitNetworkTransaction(transaction)
    }

    func transactionInventoryRoots() async -> [String] {
        guard let service else { return [] }
        return await service.transactionInventoryRoots()
    }

    func genesisActivatedOutOfBand() async {
        await service?.genesisActivatedOutOfBand()
    }
}
