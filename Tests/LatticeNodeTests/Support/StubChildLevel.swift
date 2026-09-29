import Foundation
import Lattice
@testable import LatticeNode

/// A hosted child level whose snapshot the test publishes: the test double
/// for `LocalChildLevel`.
final class StubChildLevel: ChildLevel, Sendable {
    let directory: String
    private let snapshot = Published<ReadyCandidate>()
    private let notify: @Sendable (ParentChange) -> Void
    private let admit: @Sendable (String, ChildBlockProof) async -> Bool

    /// `admit` answers each mined handoff; by default the child admits.
    init(
        directory: String,
        candidate: DirectChildCandidate? = nil,
        notify: @escaping @Sendable (ParentChange) -> Void = { _ in },
        admit: @escaping @Sendable (String, ChildBlockProof) async -> Bool = { _, _ in true }
    ) {
        self.directory = directory
        self.notify = notify
        self.admit = admit
        publish(candidate)
    }

    func parentChanged(_ change: ParentChange) {
        notify(change)
    }

    func admitMined(childCID: String, proof: ChildBlockProof) async -> Bool {
        await admit(childCID, proof)
    }

    var readyCandidate: ReadyCandidate? { snapshot.value }

    /// Publishes `candidate`, built on `plan`, as this child's snapshot (nil
    /// withdraws it).
    func publish(
        _ candidate: DirectChildCandidate?,
        plan: DescendantPlan = DescendantPlan()
    ) {
        snapshot.swap(candidate.flatMap { ReadyCandidate($0, plan: plan) })
    }
}

extension ChainService {
    /// A hosted child level in `directory` that only hears `notify`.
    func attachChildLevel(
        directory: String,
        _ notify: @escaping @Sendable (ParentChange) -> Void
    ) {
        attachChildLevel(StubChildLevel(directory: directory, notify: notify))
    }

    /// One stub child level per directory, each publishing `provider`'s
    /// candidate in its directory, built — as a hosted child's rebuild
    /// builds — against a provisional carrier on `process`'s validated tip
    /// (`process` is this level's own) and published as built on `plan`.
    /// Returns that carrier.
    @discardableResult
    func attachStubChildren(
        _ directories: [String],
        on process: ChainProcess,
        plan: DescendantPlan = DescendantPlan(),
        provider: @escaping @Sendable (
            ChildCandidateRequestContext
        ) async throws -> [DirectChildCandidate]
    ) async throws -> Block {
        let tip = try await process.validatedTipBlock()
        guard let carrier = ChainService.provisionalCarrier(
            on: tip,
            tipCID: try BlockHeader(node: tip).rawCID,
            timestamp: tip.timestamp + 1
        ) else { throw ChainServiceError.invalidParentCarrier }
        let built = try await provider(
            ChildCandidateRequestContext(
                parentCarrier: carrier, recipients: plan.recipients
            )
        )
        for directory in directories {
            let level = StubChildLevel(directory: directory)
            level.publish(built.first { $0.directory == directory }, plan: plan)
            attachChildLevel(level)
        }
        return carrier
    }

    /// The co-hosted parent mailbox without the candidate hooks: this level
    /// never builds a snapshot.
    func openParentMailbox(
        tipChanged: @escaping @Sendable () async -> Void,
        serveParentRuns: @escaping @Sendable () async -> Void
    ) -> ParentMailbox {
        openParentMailbox(
            tipChanged: tipChanged,
            serveParentRuns: serveParentRuns,
            candidateGate: { _ in false },
            candidateChanged: {}
        )
    }
}
