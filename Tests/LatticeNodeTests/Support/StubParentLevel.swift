import Lattice
@testable import LatticeNode

/// A `ParentLevel` whose facts the test sets. Records each continuity
/// question it is asked. With `base`, a state it does not hold falls
/// through to that level (a real parent's process), unless `withheld`.
actor StubParentLevel: ParentLevel {
    private var produced: Set<String>
    private var withheld: Bool
    private let base: (any ParentLevel)?
    private(set) var continuityQuestions: [String] = []
    private var onWithheldQuestion: (@Sendable () async -> Void)?

    init(
        produced: Set<String> = [],
        withheld: Bool = false,
        base: (any ParentLevel)? = nil
    ) {
        self.produced = produced
        self.withheld = withheld
        self.base = base
    }

    func hasProducedState(_ stateCID: String) async -> Bool {
        continuityQuestions.append(stateCID)
        if withheld {
            // The fact lands while this question is in flight: it answers as
            // of when it was asked.
            if let hook = onWithheldQuestion {
                onWithheldQuestion = nil
                withheld = false
                await hook()
            }
            return false
        }
        if produced.contains(stateCID) { return true }
        return await base?.hasProducedState(stateCID) ?? false
    }

    func recordedGenesisLink(
        directory: String, childGenesisCID: String
    ) async -> ParentGenesisLink? {
        await base?.recordedGenesisLink(
            directory: directory, childGenesisCID: childGenesisCID
        )
    }

    func anchoredGenesisCID(directory: String) async -> String? {
        await base?.anchoredGenesisCID(directory: directory)
    }

    /// The parent now answers from what it holds.
    func release() { withheld = false }

    /// On the next question asked while withheld: release, then run `hook`
    /// before answering that question (still withheld).
    func onNextWithheldQuestion(_ hook: @escaping @Sendable () async -> Void) {
        onWithheldQuestion = hook
    }
}
