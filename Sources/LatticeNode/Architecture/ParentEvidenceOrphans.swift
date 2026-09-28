import Foundation

/// Parent evidence whose import could not decide on a fact the parent will
/// send, held in memory only (Bitcoin's orphan pool). Such an entry leaves
/// the durable inbox; the pool keeps its place in the parent's index (a
/// pointer, not the evidence) and what makes it worth fetching again. An
/// entry evicted here, or lost with a restart, returns through ordinary
/// acquisition. Bounded; at the bound a random entry gives way
/// (LimitOrphans).
struct ParentEvidenceOrphans {
    struct Key: Hashable, Sendable {
        let childCID: String
        let rootCID: String
    }

    /// What makes an orphan worth trying again: its missing same-chain
    /// predecessor accepted; its time (milliseconds) reached; for one the
    /// parent could not serve, the request timeout passed or the parent's
    /// next hello (the session that could not serve it may have been
    /// ending); or, for any other undecided import, the next trigger.
    enum Retry: Equatable, Sendable {
        case predecessor(String)
        case notBefore(Int64)
        case unservedUntil(Int64)
        case nextTrigger
    }

    struct Orphan: Sendable {
        let sourceID: String
        let summary: IssuedChildEvidenceSummary
        var retry: Retry
    }

    private(set) var entries: [Key: Orphan] = [:]
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func contains(childCID: String, rootCID: String) -> Bool {
        entries[Key(childCID: childCID, rootCID: rootCID)] != nil
    }

    mutating func insert(
        sourceID: String,
        summary: IssuedChildEvidenceSummary,
        retry: Retry
    ) {
        let key = Key(childCID: summary.childCID, rootCID: summary.rootCID)
        if entries[key] == nil, entries.count >= capacity,
           let victim = entries.keys.randomElement() {
            entries.removeValue(forKey: victim)
        }
        entries[key] = Orphan(sourceID: sourceID, summary: summary, retry: retry)
    }

    mutating func remove(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    /// A pooled orphan takes a new retry (its block was imported again).
    mutating func updateRetry(_ key: Key, _ retry: Retry) {
        entries[key]?.retry = retry
    }

    /// Takes the orphans `isReady` releases out of the pool.
    mutating func release(where isReady: (Orphan) -> Bool) -> [Orphan] {
        let released = entries.filter { isReady($0.value) }
        for key in released.keys { entries.removeValue(forKey: key) }
        return released.values.sorted {
            ($0.sourceID, $0.summary.ordinal) < ($1.sourceID, $1.summary.ordinal)
        }
    }

    mutating func removeAll() { entries.removeAll() }

    /// What an undecided parent-backed import leaves the inbox for, if
    /// anything. The inbox keeps an undecided entry only while a parent
    /// fact decides it (its genesis or continuity answer): an allowlist.
    /// Every other undecided outcome is an orphan — behind its missing
    /// predecessor; until its time, when a clock-ahead refusal names one
    /// still ahead; otherwise until the next trigger. Nil for a decision
    /// (the import consumed the entry). `decision` is nil when the runtime
    /// settled the attempt without an import outcome.
    static func retry(
        resolution: BlockFetcher.Resolution,
        decision: NodeImportDecision?,
        notBefore: Int64?,
        now: Int64
    ) -> Retry? {
        if let decision {
            guard decision.shouldRetryWhenEvidenceChanges
                    || decision.shouldRetryLater else { return nil }
            switch decision {
            case .unavailable(.parentGenesis?), .unavailable(.parentStateContinuity?):
                return nil
            default:
                break
            }
        }
        if case .predecessor(let missing) = resolution {
            return .predecessor(missing)
        }
        if decision == .temporarilyInvalid, let notBefore, notBefore > now {
            return .notBefore(notBefore)
        }
        return .nextTrigger
    }

    /// The wall clock orphan times are read against, in milliseconds (a
    /// block's timestamp unit).
    static func clock() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
