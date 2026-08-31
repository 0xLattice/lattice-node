import Foundation
import Lattice

/// Exact session-bound route to one advertised block Volume. Authority is
/// deliberately absent: providers supply only CID-verifiable bytes.
struct CandidateProvider: Hashable, Sendable {
    let publicKey: String
    let sessionID: Data
}

/// Synchronous per-chain acquisition reducer. The enclosing runtime actor is
/// its serialization domain; Ivy and consensus admission are injected by the
/// runtime as effects of `next()`.
struct CandidateAcquirer {
    static let readyCapacity = 1_024
    static let retainedCapacity = 64

    enum WaitReason: Equatable, Sendable {
        case evidence
        case content
        case later
    }

    struct AttemptKey: Hashable, Sendable {
        let blockCID: String
        let rootCID: String?
    }

    struct Ticket: Hashable, Sendable {
        fileprivate let epoch: UInt64
        fileprivate let sequence: UInt64
        fileprivate let key: AttemptKey
        fileprivate let providerRevision: UInt64
        fileprivate let attemptRevision: UInt64
    }

    struct Candidate: Sendable {
        let ticket: Ticket
        let blockCID: String
        let recoveryRootCID: String?
        let package: AuthenticatedChildPackage?
        let providers: [CandidateProvider]
    }

    struct Seed: Sendable {
        let blockCID: String
        let recoveryRootCID: String?
        let package: AuthenticatedChildPackage?
        let provider: CandidateProvider?

        init(
            blockCID: String,
            package: AuthenticatedChildPackage?,
            recoveryRootCID: String? = nil,
            provider: CandidateProvider? = nil
        ) {
            self.blockCID = blockCID
            self.package = package
            self.recoveryRootCID = package?.package.proof.rootCID
                ?? recoveryRootCID
            self.provider = provider
        }
    }

    struct DurableDescendant: Hashable, Sendable {
        let blockCID: String
        let rootCID: String?
    }

    enum Resolution: Sendable {
        case terminal
        case wait(WaitReason)
        case predecessor(String)
        case connected
    }

    private enum AttemptState {
        case ready
        case active(Ticket)
        case waiting(WaitReason, ContinuousClock.Instant)
        case predecessor(String)
    }

    private struct Attempt {
        var package: AuthenticatedChildPackage?
        let recoveryRootCID: String?
        var revision: UInt64
        let order: UInt64
        var expiresAt: ContinuousClock.Instant?
        var state: AttemptState
    }

    private struct BlockRecord {
        var providers: [String: CandidateProvider] = [:]
        var providerRevision: UInt64 = 0
        var predecessorCID: String?
        var attempts: [String?: Attempt] = [:]
    }

    private var epoch: UInt64 = 1
    private var nextSequence: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var records: [String: BlockRecord] = [:]
    private var readyOrder: [AttemptKey] = []
    private var readySet = Set<AttemptKey>()
    private var waitingOn: [String: Set<AttemptKey>] = [:]
    private var active: Ticket?
    private var reservedReadySlots = 0
    private var inventoryRestartNeeded = false
    private var retryWindow: Duration

    init(retryWindow: Duration = .seconds(64)) {
        self.retryWindow = retryWindow
    }

    var hasReadyCandidate: Bool { !readySet.isEmpty }
    var hasTimedWait: Bool {
        records.values.contains { record in
            record.attempts.values.contains {
                guard $0.expiresAt != nil else { return false }
                if case .waiting = $0.state { return true }
                return false
            }
        }
    }

    mutating func reset(
        retryWindow: Duration,
        durableDescendants: [String: Set<DurableDescendant>] = [:]
    ) {
        var nextEpoch = epoch &+ 1
        if nextEpoch == 0 { nextEpoch = 1 }
        self = CandidateAcquirer(retryWindow: retryWindow)
        epoch = nextEpoch
        var descendantCIDs = Set<String>()
        // Recovery seeding respects the SAME retained budget as live parking:
        // a history-heavy store can carry thousands of stale unresolved side
        // edges, and seeding them all would exhaust the budget from second
        // zero (starving live predecessor walks) while making every capacity
        // check O(thousands). Deterministic order; the remainder re-derives
        // from the accepted graph at the next restart or resolves organically
        // through the live walk.
        var seeded = 0
        seeding: for (predecessorCID, descendants) in durableDescendants
            .sorted(by: { $0.key < $1.key }) {
            for descendant in descendants.sorted(by: {
                ($0.blockCID, $0.rootCID ?? "") < ($1.blockCID, $1.rootCID ?? "")
            }) {
                guard seeded < Self.retainedCapacity else {
                    inventoryRestartNeeded = true
                    break seeding
                }
                descendantCIDs.insert(descendant.blockCID)
                let key = observe(Seed(
                    blockCID: descendant.blockCID,
                    package: nil,
                    recoveryRootCID: descendant.rootCID
                ), retainingOverflow: true).key
                guard let key else { continue }
                setState(.predecessor(predecessorCID), for: key)
                waitingOn[predecessorCID, default: []].insert(key)
                seeded += 1
            }
        }
        for predecessorCID in durableDescendants.keys.sorted()
            where !descendantCIDs.contains(predecessorCID) {
            _ = observe(Seed(
                blockCID: predecessorCID,
                package: nil
            ), retainingOverflow: true)
        }
    }

    @discardableResult
    mutating func observe(_ seed: Seed) -> (
        accepted: Bool,
        key: AttemptKey?
    ) {
        observe(seed, retainingOverflow: false)
    }

    private mutating func observe(
        _ seed: Seed,
        retainingOverflow: Bool
    ) -> (
        accepted: Bool,
        key: AttemptKey?
    ) {
        var record = records[seed.blockCID] ?? BlockRecord()
        if let provider = seed.provider,
           record.providers[provider.publicKey] != provider {
            record.providers[provider.publicKey] = provider
            record.providerRevision &+= 1
            for rootCID in Array(record.attempts.keys) {
                guard case .waiting(.content, _) =
                        record.attempts[rootCID]?.state else {
                    continue
                }
                record.attempts[rootCID]?.state = .ready
            }
        }

        let rootCID = seed.recoveryRootCID
        if rootCID == nil, seed.package == nil,
           record.attempts.contains(where: {
               $0.key != nil && $0.value.package != nil
           }) {
            records[seed.blockCID] = record
            fillReadyCapacity()
            return (true, nil)
        }
        let key = AttemptKey(blockCID: seed.blockCID, rootCID: rootCID)
        let created: Bool
        if var attempt = record.attempts[rootCID] {
            created = false
            let previous = attempt.package
            if let package = seed.package,
               let merged = Self.mergePackages(previous, package) {
                attempt.package = merged
                if previous == nil
                    || !Self.packagesEqual(previous!, merged) {
                    attempt.revision &+= 1
                }
            }
            if case .waiting(.evidence, _) = attempt.state,
               attempt.package != nil {
                attempt.state = .ready
            }
            record.attempts[rootCID] = attempt
        } else {
            created = true
            nextOrder &+= 1
            record.attempts[rootCID] = Attempt(
                package: seed.package,
                recoveryRootCID: seed.recoveryRootCID,
                revision: 1,
                order: nextOrder,
                expiresAt: nil,
                state: .ready
            )
        }
        records[seed.blockCID] = record
        if rootCID != nil, seed.package != nil {
            removeSupersededRootlessAttempt(for: seed.blockCID)
        }

        let accepted = scheduleIfReady(key)
        if !accepted, created, !retainingOverflow {
            removeAttempt(key)
            inventoryRestartNeeded = true
            return (false, nil)
        }
        fillReadyCapacity()
        return (accepted, key)
    }

    /// Re-observe a candidate after an external dependency was interrupted.
    /// If admission is active, its completion sees the revision change and
    /// retries. Otherwise the exact attempt becomes ready immediately.
    @discardableResult
    mutating func requeue(_ seed: Seed) -> Bool {
        guard let key = observe(seed).key,
              var record = records[key.blockCID],
              var attempt = record.attempts[key.rootCID] else {
            return false
        }
        attempt.revision &+= 1
        if case .active = attempt.state {
            record.attempts[key.rootCID] = attempt
            records[key.blockCID] = record
            return true
        }
        attempt.expiresAt = nil
        attempt.state = .ready
        record.attempts[key.rootCID] = attempt
        records[key.blockCID] = record
        let accepted = scheduleIfReady(key)
        fillReadyCapacity()
        return accepted
    }

    mutating func disconnect(_ provider: CandidateProvider) {
        for blockCID in Array(records.keys) {
            guard var record = records[blockCID],
                  record.providers[provider.publicKey] == provider else {
                continue
            }
            record.providers.removeValue(forKey: provider.publicKey)
            if record.attempts.isEmpty {
                records.removeValue(forKey: blockCID)
            } else {
                records[blockCID] = record
            }
        }
    }

    /// Number of candidates currently queued ready-to-fetch.
    var readyDepth: Int { readyOrder.count }

    mutating func next() -> Candidate? {
        guard active == nil else { return nil }
        while !readyOrder.isEmpty {
            let key = readyOrder.removeFirst()
            readySet.remove(key)
            guard var record = records[key.blockCID],
                  var attempt = record.attempts[key.rootCID],
                  case .ready = attempt.state else { continue }
            nextSequence &+= 1
            let ticket = Ticket(
                epoch: epoch,
                sequence: nextSequence,
                key: key,
                providerRevision: record.providerRevision,
                attemptRevision: attempt.revision
            )
            attempt.state = .active(ticket)
            record.attempts[key.rootCID] = attempt
            records[key.blockCID] = record
            active = ticket
            return Candidate(
                ticket: ticket,
                blockCID: key.blockCID,
                recoveryRootCID: attempt.recoveryRootCID,
                package: attempt.package,
                providers: record.providers.values.sorted {
                    $0.publicKey < $1.publicKey
                }
            )
        }
        return nil
    }

    @discardableResult
    mutating func complete(
        _ ticket: Ticket,
        resolution: Resolution,
        deficientProviders: Set<CandidateProvider> = [],
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard active == ticket,
              ticket.epoch == epoch,
              var record = records[ticket.key.blockCID],
              var attempt = record.attempts[ticket.key.rootCID],
              case .active(ticket) = attempt.state else {
            return false
        }

        for provider in deficientProviders
            where record.providers[provider.publicKey] == provider {
            record.providers.removeValue(forKey: provider.publicKey)
            record.providerRevision &+= 1
        }
        active = nil

        switch resolution {
        case .terminal:
            if attempt.revision > ticket.attemptRevision {
                attempt.state = .ready
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
            } else {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
            }
        case .wait(let reason):
            if reason == .evidence,
               ticket.key.rootCID == nil,
               record.attempts.contains(where: {
                   $0.key != nil && $0.value.package != nil
               }) {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
                break
            }
            let gainedRelevantFact =
                reason == .content
                    ? record.providerRevision > ticket.providerRevision
                    : reason == .evidence
                        && attempt.revision > ticket.attemptRevision
                        && attempt.package != nil
            if gainedRelevantFact {
                attempt.state = .ready
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
            } else if retainedCount() >= Self.retainedCapacity,
                      !evictOldestRetained() {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
                inventoryRestartNeeded = true
            } else {
                // A successful eviction may have removed a sibling attempt of
                // THIS block: re-read the record so the pre-eviction snapshot
                // cannot resurrect the victim on write-back.
                record = records[ticket.key.blockCID] ?? record
                if attempt.expiresAt == nil {
                    attempt.expiresAt = now.advanced(
                        by: reason == .later
                            ? .seconds(2 * 60 * 60)
                            : retryWindow
                    )
                }
                attempt.state = .waiting(
                    reason,
                    attempt.expiresAt!
                )
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
            }
        case .predecessor(let predecessorCID):
            if let existing = record.predecessorCID,
               existing != predecessorCID {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
            } else if retainedCount() >= Self.retainedCapacity,
                      !evictOldestRetained() {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
                inventoryRestartNeeded = true
            } else {
                // See the wait branch: never write a pre-eviction snapshot
                // back over a same-block eviction.
                record = records[ticket.key.blockCID] ?? record
                record.predecessorCID = predecessorCID
                attempt.expiresAt = nil
                attempt.state = .predecessor(predecessorCID)
                record.attempts[ticket.key.rootCID] = attempt
                waitingOn[predecessorCID, default: []].insert(ticket.key)
                records[ticket.key.blockCID] = record
                _ = observe(Seed(
                    blockCID: predecessorCID,
                    package: nil
                ), retainingOverflow: true)
                // Carry the descendant's providers onto the predecessor seed:
                // a provider-less candidate can only be fetched by dialing a
                // pin holder, which is unreachable when the sole holder is
                // behind NAT and dials us. Whoever supplied the descendant is
                // the best-known holder of its ancestry.
                for provider in record.providers.values.sorted(by: {
                    $0.publicKey < $1.publicKey
                }) {
                    _ = observe(Seed(
                        blockCID: predecessorCID,
                        package: nil,
                        provider: provider
                    ), retainingOverflow: true)
                }
                fillReadyCapacity()
                return true
            }
        case .connected:
            if attempt.revision > ticket.attemptRevision {
                attempt.state = .ready
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
            } else {
                record.attempts[ticket.key.rootCID] = attempt
                records[ticket.key.blockCID] = record
                removeAttempt(ticket.key)
            }
        }

        if case .connected = resolution {
            connectPredecessor(ticket.key.blockCID)
        } else if case .wait = resolution {
            _ = scheduleIfReady(ticket.key)
        }
        fillReadyCapacity()
        return true
    }

    mutating func retry(now: ContinuousClock.Instant = .now) {
        for blockCID in Array(records.keys) {
            guard var record = records[blockCID] else { continue }
            for rootCID in Array(record.attempts.keys) {
                guard var attempt = record.attempts[rootCID],
                      case .waiting(let reason, let deadline) = attempt.state
                else { continue }
                guard attempt.expiresAt != nil else { continue }
                if deadline <= now {
                    if waitingOn[blockCID]?.isEmpty == false {
                        if reason == .evidence {
                            // The evidence solicitation is a lossy single
                            // round-trip fired only from inside an admission
                            // attempt: the locate send, the remote reply, and
                            // the session it rides can each drop silently. A
                            // depended-upon candidate must therefore re-enter
                            // admission (re-firing the solicitation) when its
                            // window expires — fossilizing it would wedge the
                            // whole successor chain behind one lost message.
                            // A fresh window is armed at the next park.
                            attempt.expiresAt = nil
                            attempt.state = .ready
                            record.attempts[rootCID] = attempt
                        } else {
                            attempt.expiresAt = nil
                            record.attempts[rootCID] = attempt
                            inventoryRestartNeeded = true
                        }
                    } else {
                        record.attempts.removeValue(forKey: rootCID)
                    }
                } else if reason == .content || reason == .later {
                    attempt.state = .ready
                    record.attempts[rootCID] = attempt
                }
            }
            if record.attempts.isEmpty {
                records.removeValue(forKey: blockCID)
            } else {
                records[blockCID] = record
            }
        }
        fillReadyCapacity()
    }

    mutating func retryExternalDependency(blockCID: String, rootCID: String?) {
        let key = AttemptKey(blockCID: blockCID, rootCID: rootCID)
        guard var record = records[blockCID],
              var attempt = record.attempts[rootCID],
              case .waiting(let reason, _) = attempt.state,
              reason == .evidence || reason == .later else { return }
        attempt.state = .ready
        record.attempts[rootCID] = attempt
        records[blockCID] = record
        _ = scheduleIfReady(key)
    }

    mutating func takeInventoryRestart() -> Bool {
        defer { inventoryRestartNeeded = false }
        return inventoryRestartNeeded
    }

    mutating func reserveAcceptedLeafPage(_ count: Int) -> Bool {
        guard reservedReadySlots == 0,
              readySet.count <= Self.readyCapacity - count else {
            return false
        }
        reservedReadySlots = count
        return true
    }

    mutating func releaseAcceptedLeafPage(_ count: Int) {
        precondition(reservedReadySlots == count)
        reservedReadySlots = 0
        fillReadyCapacity()
    }

    mutating func consumeAcceptedLeafPage(_ seeds: [Seed]) -> Bool {
        guard seeds.count <= reservedReadySlots else {
            reservedReadySlots = 0
            fillReadyCapacity()
            return false
        }
        for seed in seeds {
            reservedReadySlots -= 1
            guard observe(seed).accepted else {
                reservedReadySlots = 0
                fillReadyCapacity()
                return false
            }
        }
        reservedReadySlots = 0
        fillReadyCapacity()
        return true
    }

    /// Wake successors parked behind `predecessorCID` when it became canonical
    /// through a path OUTSIDE candidate admission — e.g. an adopted, self-contained
    /// child genesis that bootstraps directly to active. Such a predecessor never
    /// resolves `.connected` through `complete`, so its one-shot connect signal is
    /// never fired and every successor that parked on it while `awaitingGenesis`
    /// (see ChainProcess successor-before-genesis handling) is stranded, orphaning
    /// the entire chain above the genesis.
    mutating func predecessorConnectedOutOfBand(_ predecessorCID: String) {
        connectPredecessor(predecessorCID)
        fillReadyCapacity()
    }

    private mutating func connectPredecessor(_ blockCID: String) {
        let waiting = waitingOn.removeValue(forKey: blockCID) ?? []
        for key in waiting {
            guard var record = records[key.blockCID],
                  var attempt = record.attempts[key.rootCID],
                  case .predecessor(blockCID) = attempt.state else {
                continue
            }
            attempt.state = .ready
            record.attempts[key.rootCID] = attempt
            records[key.blockCID] = record
            _ = scheduleIfReady(key)
        }
    }

    private mutating func scheduleIfReady(_ key: AttemptKey) -> Bool {
        guard case .ready? =
                records[key.blockCID]?.attempts[key.rootCID]?.state else {
            return true
        }
        guard !readySet.contains(key) else { return true }
        guard readySet.count + reservedReadySlots < Self.readyCapacity else {
            return false
        }
        readySet.insert(key)
        readyOrder.append(key)
        return true
    }

    private mutating func fillReadyCapacity() {
        var candidates: [(key: AttemptKey, order: UInt64)] = []
        for (blockCID, record) in records {
            for (rootCID, attempt) in record.attempts {
                guard case .ready = attempt.state else { continue }
                candidates.append((
                    key: AttemptKey(blockCID: blockCID, rootCID: rootCID),
                    order: attempt.order
                ))
            }
        }
        candidates.sort { $0.order < $1.order }
        for candidate in candidates {
            guard scheduleIfReady(candidate.key) else { return }
        }
    }

    private mutating func removeReady(_ key: AttemptKey) {
        guard readySet.remove(key) != nil else { return }
        readyOrder.removeAll { $0 == key }
    }

    private mutating func removeSupersededRootlessAttempt(
        for blockCID: String
    ) {
        let key = AttemptKey(blockCID: blockCID, rootCID: nil)
        guard let attempt = records[blockCID]?.attempts[nil] else {
            return
        }
        switch attempt.state {
        case .ready, .waiting:
            removeAttempt(key)
        case .active, .predecessor:
            break
        }
    }

    /// Reclaims one retained slot by evicting the oldest waiting or parked
    /// attempt. Retention is an operator-budget cache, never a protocol rule:
    /// a live predecessor walk must always be able to park, and an evicted
    /// obligation is re-derivable (durable recovery edges re-derive from the
    /// accepted graph at restart; inventory restart re-supplies live waits).
    private mutating func evictOldestRetained() -> Bool {
        var victim: (key: AttemptKey, order: UInt64)?
        for (blockCID, record) in records {
            for (rootCID, attempt) in record.attempts {
                switch attempt.state {
                case .waiting, .predecessor:
                    if victim == nil || attempt.order < victim!.order {
                        victim = (
                            AttemptKey(blockCID: blockCID, rootCID: rootCID),
                            attempt.order
                        )
                    }
                default:
                    break
                }
            }
        }
        guard let victim else { return false }
        removeAttempt(victim.key)
        inventoryRestartNeeded = true
        return true
    }

    private mutating func removeAttempt(_ key: AttemptKey) {
        guard var record = records[key.blockCID],
              let attempt = record.attempts.removeValue(
                forKey: key.rootCID
              ) else { return }
        removeReady(key)
        if case .predecessor(let predecessorCID) = attempt.state {
            waitingOn[predecessorCID]?.remove(key)
            if waitingOn[predecessorCID]?.isEmpty == true {
                waitingOn.removeValue(forKey: predecessorCID)
            }
        }
        if record.attempts.isEmpty {
            records.removeValue(forKey: key.blockCID)
        } else {
            records[key.blockCID] = record
        }
    }

    private mutating func setState(
        _ state: AttemptState,
        for key: AttemptKey
    ) {
        guard var record = records[key.blockCID],
              var attempt = record.attempts[key.rootCID] else { return }
        attempt.state = state
        record.attempts[key.rootCID] = attempt
        records[key.blockCID] = record
        removeReady(key)
    }

    private func retainedCount() -> Int {
        records.values.reduce(0) { count, record in
            count + record.attempts.values.reduce(0) {
                switch $1.state {
                case .waiting, .predecessor: $0 + 1
                default: $0
                }
            }
        }
    }

    static func mergePackages(
        _ current: AuthenticatedChildPackage?,
        _ received: AuthenticatedChildPackage
    ) -> AuthenticatedChildPackage? {
        guard let current else { return received }
        let left = current.package
        let right = received.package
        guard let leftProof = try? left.proof.serialize(),
              let rightProof = try? right.proof.serialize(),
              leftProof == rightProof,
              left.parentGenesisLink == nil
                || right.parentGenesisLink == nil
                || left.parentGenesisLink == right.parentGenesisLink,
              left.parentStateContinuityLink == nil
                || right.parentStateContinuityLink == nil
                || left.parentStateContinuityLink
                    == right.parentStateContinuityLink else {
            return nil
        }
        return AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: left.proof,
                parentGenesisLink:
                    left.parentGenesisLink ?? right.parentGenesisLink,
                parentStateContinuityLink:
                    left.parentStateContinuityLink
                        ?? right.parentStateContinuityLink
            )
        )
    }

    private static func packagesEqual(
        _ left: AuthenticatedChildPackage,
        _ right: AuthenticatedChildPackage
    ) -> Bool {
        guard let leftProof = try? left.package.proof.serialize(),
              let rightProof = try? right.package.proof.serialize() else {
            return false
        }
        return leftProof == rightProof
            && left.package.parentGenesisLink
                == right.package.parentGenesisLink
            && left.package.parentStateContinuityLink
                == right.package.parentStateContinuityLink
    }
}
