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

/// The runtime requests authenticated direct-child candidates against this
/// exact provisional carrier. It owns the bounded deadline and returns partial
/// success when only some children respond.
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
    /// Authenticated direct-child candidates bound to this exact provisional
    /// carrier.
    func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async throws -> [DirectChildCandidate]
    /// Something a template or a child candidate is a function of changed on
    /// this chain: the validated tip, the mempool, a credit. The runtime
    /// re-pushes the parent context to children and rebuilds this chain's own
    /// candidate.
    func chainStateChanged() async
    /// The miner's reward plan and minimum work for this chain's descendants,
    /// as supplied with a template request; pushed to children with the tip.
    func updateDescendantPlan(
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork]
    ) async
    /// The child candidates a template built on the given parent state can
    /// carry, as `directory:cid` lines: one input of the template digest.
    func childCandidateDigestInput(parentStateCID: String) async -> [String]
    func publishChildProof(_ publication: DirectChildProofPublication) async throws
    /// A parent pushes the run it credits to a committing block to the
    /// children of that directory (§9.10), on every change to that run.
    func announceParentRunReport(_ report: ParentRunReport) async throws
    /// Ask this chain's configured parent for the runs of the committing
    /// blocks behind one block admitted here (§9.10) — one ask per admission,
    /// so the credit for those runs never waits for a push or a reconnect.
    func requestParentRunReports(committers: [String]) async
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
    func withValidateBodySource(
        blockCID: String,
        _ admit: @Sendable (
            _ remoteSource: (any ContentSource)?
        ) async throws -> NodeImportOutcome
    ) async throws -> NodeImportOutcome
    /// Cross-chain evidence for the validate walk: a weighed CHILD block's
    /// `.execution` needs the parent fact (state continuity / genesis link) the
    /// live path obtains from the configured parent. Nil is an availability
    /// gap; the walk parks on its retry timer.
    func resolveValidateEvidence(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage?
}

/// Which optional `ChainInterface` operations a network-runtime generation
/// may use. A missing capability disables the network behaviour behind it
/// (transaction relay, inventory sync, candidate offers, run reports).
public struct ChainNetworkCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let childCandidates = ChainNetworkCapabilities(rawValue: 1 << 0)
    public static let transactions = ChainNetworkCapabilities(rawValue: 1 << 1)
    public static let transactionInventory = ChainNetworkCapabilities(rawValue: 1 << 2)
    public static let parentRunReports = ChainNetworkCapabilities(rawValue: 1 << 3)
    public static let runReportServing = ChainNetworkCapabilities(rawValue: 1 << 4)
    public static let recentCommitters = ChainNetworkCapabilities(rawValue: 1 << 5)

    public static let all: ChainNetworkCapabilities = [
        .childCandidates, .transactions, .transactionInventory,
        .parentRunReports, .runReportServing, .recentCommitters,
    ]
}

/// What `NodeNetworkRuntime` needs from the chain service. Admission is
/// always available; every other operation is used only when its capability
/// is in `networkCapabilities`.
public protocol ChainInterface: AnyObject, Sendable {
    var networkCapabilities: ChainNetworkCapabilities { get }
    func miningCandidate(
        for context: ChildCandidateRequestContext,
        parentContentSource: any ContentSource
    ) async throws -> DirectChildCandidate?
    func importNetworkCandidate(
        _ admission: NetworkCandidateImport
    ) async throws -> NodeImportOutcome
    func submitNetworkTransaction(_ transaction: Transaction) async throws -> Bool
    func transactionInventoryRoots() async -> [String]
    /// A run report from the configured parent, to be credited at the child
    /// block it names (§9.10). The service derives the credit under its own
    /// lease.
    func applyParentRunReport(_ report: ParentRunReport) async throws
    /// A child wired in for `directory`: start serving its runs.
    func serveRuns(for directory: String) async
    /// The committers this chain asks its parent to re-serve after each
    /// evidence catch-up round.
    func recentCommitters() async -> [String]
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

    func directChildCandidates(
        _ context: ChildCandidateRequestContext
    ) async throws -> [DirectChildCandidate] {
        guard let runtime else { return [] }
        return await runtime.directChildCandidates(context)
    }

    func chainStateChanged() async {
        await runtime?.chainStateChanged()
    }

    func updateDescendantPlan(
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork]
    ) async {
        await runtime?.updateDescendantPlan(
            rewards: rewards,
            minimumWork: minimumWork
        )
    }

    func childCandidateDigestInput(parentStateCID: String) async -> [String] {
        await runtime?.childCandidateDigestInput(
            parentStateCID: parentStateCID
        ) ?? []
    }

    func publishChildProof(_ publication: DirectChildProofPublication) async throws {
        guard let runtime else { throw CancellationError() }
        _ = try await runtime.publishChildProof(
            publication.proof,
            childDirectory: publication.directory,
            childCID: publication.childCID
        )
    }

    func announceParentRunReport(_ report: ParentRunReport) async throws {
        guard let runtime else { throw CancellationError() }
        await runtime.announceParentRunReport(report)
    }

    func requestParentRunReports(committers: [String]) async {
        await runtime?.requestParentRunReports(committers: committers)
    }

    func publishAcceptedBlock(_ blockCID: String) async throws {
        guard let runtime else { throw CancellationError() }
        try await runtime.publishAcceptedBlock(blockCID)
    }

    func publishTransaction(_ volumeRootCID: String) async throws {
        guard let runtime else { throw CancellationError() }
        try await runtime.publishTransaction(volumeRootCID)
    }

    func withValidateBodySource(
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

    func resolveValidateEvidence(
        for blockCID: String,
        requirement: CrossChainEvidenceRequirement
    ) async -> AuthenticatedChildPackage? {
        // A weighed child block's validate tier needs the parent fact (state
        // continuity / genesis link) the live path requests from the
        // configured parent; the same request, awaited.
        await runtime?.resolveValidateEvidence(
            for: blockCID,
            requirement: requirement
        )
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

    func miningCandidate(
        for context: ChildCandidateRequestContext,
        parentContentSource: any ContentSource
    ) async throws -> DirectChildCandidate? {
        guard let service else { return nil }
        return try await service.miningCandidate(
            for: context,
            parentContentSource: parentContentSource
        )
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

    func applyParentRunReport(_ report: ParentRunReport) async throws {
        guard let service else { throw CancellationError() }
        _ = try await service.applyParentRunReport(report)
    }

    func serveRuns(for directory: String) async {
        await service?.serveRuns(for: directory)
    }

    func recentCommitters() async -> [String] {
        guard let service else { return [] }
        return (try? await service.recentCommitters()) ?? []
    }
}
