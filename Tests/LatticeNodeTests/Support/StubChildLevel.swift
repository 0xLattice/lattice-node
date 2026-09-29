import Foundation
import Lattice
@testable import LatticeNode

/// A hosted child level answered by closures: the test double for
/// `LocalChildLevel`.
final class StubChildLevel: ChildLevel, Sendable {
    typealias Build = @Sendable (
        ChildCandidateRequestContext
    ) async throws -> DirectChildCandidate?

    let directory: String
    private let build: Build
    private let cid: @Sendable (_ parentStateCID: String) async -> String?
    private let notify: @Sendable (ParentChange) -> Void

    init(
        directory: String,
        build: @escaping Build = { _ in nil },
        candidateCID: @escaping @Sendable (_ parentStateCID: String) async -> String? = { _ in nil },
        notify: @escaping @Sendable (ParentChange) -> Void = { _ in }
    ) {
        self.directory = directory
        self.cid = candidateCID
        self.notify = notify
        self.build = build
    }

    func parentChanged(_ change: ParentChange) {
        notify(change)
    }

    func candidate(
        for context: ChildCandidateRequestContext
    ) async -> DirectChildCandidate? {
        await ChildCandidateBudget.withinDeadline { [build] in
            try? await build(context)
        }
    }

    func candidateCID(parentStateCID: String) async -> String? {
        await cid(parentStateCID)
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

    /// One stub child level per directory, each answering with `provider`'s
    /// candidate in its directory.
    func attachStubChildren(
        _ directories: [String],
        provider: @escaping @Sendable (
            ChildCandidateRequestContext
        ) async throws -> [DirectChildCandidate]
    ) {
        for directory in directories {
            attachChildLevel(StubChildLevel(directory: directory) { context in
                try await provider(context).first { $0.directory == directory }
            })
        }
    }
}
