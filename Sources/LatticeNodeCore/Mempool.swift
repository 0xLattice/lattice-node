import Lattice
import cashew

/// Why the pool refused a transaction. Local-resource policy only: state and
/// consensus validity belong to Lattice's preflight, which the shell runs as a
/// job and reports back as a `MempoolDisposition`.
public enum MempoolError: Error, Sendable, Equatable {
    /// The body is not inline: the shell resolves content before the core
    /// sees it.
    case unresolved
    case tooLarge
    case full
    case invalidState
    case conflictingNonce
    case feeTooLow
}

/// Lattice's classification of a transaction against one executed tip.
public enum MempoolDisposition: Sendable, Equatable {
    case ready
    case future
    case unavailable
    case invalid
}

public struct MempoolItem: Sendable {
    public let cid: String
    public let transaction: Transaction
    public let disposition: MempoolDisposition
    /// Milliseconds since the epoch.
    public let addedAt: Int64
}

/// What one pool operation changed. The pool is a value: a caller that wants
/// to undo keeps the copy it had before.
public struct MempoolMutation: Sendable {
    public var transactionCID: String?
    public var inserted: MempoolItem?
    public var replaced: [MempoolItem] = []
    public var evicted: [MempoolItem] = []
    public var removed: [MempoolItem] = []
    public var reclassified: [MempoolItem] = []

    /// Every entry that left the pool.
    public var departed: [MempoolItem] { replaced + evicted + removed }
}

public struct MempoolLimits: Sendable, Equatable {
    public var maxCount: Int
    public var maxBytes: Int
    public var maxSignatures: Int
    public var maxNonReadyPerSigner: Int

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        maxNonReadyPerSigner: Int = 64
    ) {
        precondition(maxCount > 0 && maxBytes > 0 && maxSignatures > 0 && maxNonReadyPerSigner > 0)
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.maxNonReadyPerSigner = maxNonReadyPerSigner
    }
}

/// The transaction pool of one level as a value: no IO, no awaits. The same
/// admission, replacement, eviction and ordering rules as the shell's
/// `TransactionPool` actor, over transactions whose content is already
/// resolved. `version` moves on every change, so a job built from the pool
/// names the pool it read.
public struct Mempool: Sendable {
    /// Bound parse work by wire capacity (a 16-bit length), not an invented
    /// cap: the signature's crypto verification is the authoritative check.
    static let maximumSignatureFieldBytes = Int(UInt16.max)

    private struct Entry: Sendable {
        let cid: String
        let transaction: Transaction
        let size: Int
        let conflictKey: ConflictKey
        let minerSurplus: WorkSum
        var disposition: MempoolDisposition
        let addedAt: Int64
    }

    private struct ConflictKey: Hashable, Sendable {
        let signers: [String]
        let nonce: UInt64
    }

    private struct SignerNonce: Hashable, Sendable {
        let signer: String
        let nonce: UInt64
    }

    public let limits: MempoolLimits
    private var entries: [String: Entry] = [:]
    private var signerNonces: [SignerNonce: String] = [:]
    public private(set) var byteCount = 0
    public private(set) var version: UInt64 = 0

    public init(limits: MempoolLimits = MempoolLimits()) {
        self.limits = limits
    }

    public var count: Int { entries.count }

    public func contains(_ cid: String) -> Bool { entries[cid] != nil }

    public func item(_ cid: String) -> MempoolItem? { entries[cid].map(Self.item) }

    public var items: [MempoolItem] {
        entries.values.sorted { $0.cid < $1.cid }.map(Self.item)
    }

    /// The pool's content address of `transaction`.
    public static func cid(of transaction: Transaction) throws -> String {
        try VolumeImpl<Transaction>(node: transaction).rawCID
    }

    /// The size checks that need no state, run before a transaction costs a
    /// preflight job. `submit` runs them again.
    public func check(_ transaction: Transaction, spec: ChainSpec) throws -> String {
        try measure(transaction, spec: spec).cid
    }

    private func measure(
        _ transaction: Transaction,
        spec: ChainSpec
    ) throws -> (cid: String, body: TransactionBody, size: Int, surplus: WorkSum) {
        guard transaction.signatures.count <= limits.maxSignatures,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }) else {
            throw MempoolError.tooLarge
        }
        guard let body = transaction.body.node else { throw MempoolError.unresolved }
        guard let bodyData = body.toData() else { throw MempoolError.unresolved }
        guard bodyData.count <= spec.maxBlockSize,
              let envelopeData = transaction.toData(),
              envelopeData.count <= spec.maxBlockSize,
              body.signers.count <= limits.maxSignatures else {
            throw MempoolError.tooLarge
        }
        // A transaction that creates value (credits and deposits over debits
        // and withdrawals) breaks the fee rule in any block, so it is never
        // pooled: a template carrying it would be invalid.
        guard let surplus = body.minerSurplus() else { throw MempoolError.invalidState }
        let (size, overflow) = envelopeData.count.addingReportingOverflow(bodyData.count)
        guard !overflow, size <= spec.maxBlockSize else { throw MempoolError.tooLarge }
        return (try Self.cid(of: transaction), body, size, surplus)
    }

    @discardableResult
    public mutating func submit(
        _ transaction: Transaction,
        spec: ChainSpec,
        disposition: MempoolDisposition = .ready,
        addedAt: Int64
    ) throws -> MempoolMutation {
        guard disposition != .invalid else { throw MempoolError.invalidState }
        let measured = try measure(transaction, spec: spec)
        let cid = measured.cid
        if entries[cid] != nil {
            return MempoolMutation(transactionCID: cid)
        }
        guard measured.size <= limits.maxBytes else { throw MempoolError.tooLarge }
        let conflictKey = ConflictKey(
            signers: Array(Set(measured.body.signers)).sorted(),
            nonce: measured.body.nonce
        )
        let entry = Entry(
            cid: cid,
            transaction: transaction,
            size: measured.size,
            conflictKey: conflictKey,
            minerSurplus: measured.surplus,
            disposition: disposition,
            addedAt: addedAt
        )

        // Replace-by-fee on an exact (signers, nonce) match: a signer may
        // replace their OWN pending transaction at that nonce only by strictly
        // paying more to the miner (`minerSurplus`, the debit-over-credit
        // excess the block's recipient is credited). That excess is funds the
        // signer gives up, so the bid cannot be raised for free. A partial
        // signer overlap at the same nonce is an unresolvable conflict.
        let overlapping = Set(conflictKey.signers.compactMap {
            signerNonces[SignerNonce(signer: $0, nonce: conflictKey.nonce)]
        })
        let replacedCID: String?
        if overlapping.isEmpty {
            replacedCID = nil
        } else if overlapping.count == 1, let overlap = overlapping.first,
                  let existing = entries[overlap], existing.conflictKey == conflictKey {
            // Compared regardless of disposition: a non-ready entry's excess is
            // not yet funding-checked, so this permits monotonic self-churn on
            // that one slot, bounded by `maxNonReadyPerSigner` and never mineable.
            guard entry.minerSurplus > existing.minerSurplus else { throw MempoolError.feeTooLow }
            replacedCID = overlap
        } else {
            throw MempoolError.conflictingNonce
        }
        if disposition != .ready {
            var queuedBySigner: [String: Int] = [:]
            for existing in entries.values
            where existing.cid != replacedCID && existing.disposition != .ready {
                for signer in existing.conflictKey.signers {
                    queuedBySigner[signer, default: 0] += 1
                }
            }
            guard conflictKey.signers.allSatisfy({
                queuedBySigner[$0, default: 0] < limits.maxNonReadyPerSigner
            }) else {
                throw MempoolError.full
            }
        }

        var prospectiveCount = entries.count - (replacedCID == nil ? 0 : 1)
        var prospectiveBytes = byteCount - (replacedCID.flatMap { entries[$0]?.size } ?? 0)
        var evictions: [String] = []
        let candidates = entries.values
            .filter { $0.cid != replacedCID }
            .sorted { Self.retention($0, $1) < 0 }
        for candidate in candidates
        where prospectiveCount >= limits.maxCount || entry.size > limits.maxBytes - prospectiveBytes {
            guard Self.retention(entry, candidate) > 0 else { throw MempoolError.full }
            evictions.append(candidate.cid)
            prospectiveCount -= 1
            prospectiveBytes -= candidate.size
        }
        guard prospectiveCount < limits.maxCount,
              entry.size <= limits.maxBytes - prospectiveBytes else {
            throw MempoolError.full
        }

        var mutation = MempoolMutation(transactionCID: cid)
        if let replacedCID, let replaced = removeEntry(replacedCID) {
            mutation.replaced = [Self.item(replaced)]
        }
        mutation.evicted = evictions.compactMap { removeEntry($0).map(Self.item) }
        insert(entry)
        mutation.inserted = Self.item(entry)
        return mutation
    }

    /// Ready and future entries in template order.
    public func transactions(limit: Int) -> [Transaction] {
        ordered(limit: limit, includesUnavailable: false)
    }

    /// Candidate parent state can make a child withdrawal executable, so
    /// unavailable entries are offered too; the builder preflights them
    /// against that context.
    public func contextualTransactions(limit: Int) -> [Transaction] {
        ordered(limit: limit, includesUnavailable: true)
    }

    /// Fee-priority selection. The greedy assembler applies candidates in
    /// order and drops any that fail at their position, so a signer's nonce N
    /// must precede its nonce N+1, and a multi-signer transaction must follow
    /// every signer's lower-nonce transaction. A topological (Kahn) emission
    /// honors that: an entry is emittable once every signer's lower-nonce
    /// entry has been emitted, and among emittable entries the highest fee
    /// wins (CID breaks ties). Future entries stay eligible so a burst still
    /// packs in one block.
    private func ordered(limit: Int, includesUnavailable: Bool) -> [Transaction] {
        let maximum = max(0, limit)
        guard maximum > 0 else { return [] }
        let eligible = entries.values.filter {
            $0.disposition == .ready || $0.disposition == .future
                || (includesUnavailable && $0.disposition == .unavailable)
        }
        guard !eligible.isEmpty else { return [] }
        let ordinal = eligible.sorted {
            $0.conflictKey.nonce != $1.conflictKey.nonce
                ? $0.conflictKey.nonce < $1.conflictKey.nonce
                : $0.cid < $1.cid
        }
        // Each signer's entries ascending by nonce; a multi-signer entry sits
        // in every one of its signers' chains and depends on its predecessor
        // in each.
        var chains: [String: [Entry]] = [:]
        var positions: [String: [String: Int]] = [:]
        for entry in ordinal {
            for signer in entry.conflictKey.signers {
                positions[entry.cid, default: [:]][signer] = chains[signer]?.count ?? 0
                chains[signer, default: []].append(entry)
            }
        }
        var indegree: [String: Int] = [:]
        for entry in ordinal {
            indegree[entry.cid] = (positions[entry.cid] ?? [:]).values.filter { $0 > 0 }.count
        }
        var frontier = FeeFrontier()
        for entry in ordinal where indegree[entry.cid] == 0 { frontier.push(entry) }
        var result: [Transaction] = []
        while result.count < maximum, let pick = frontier.pop() {
            result.append(pick.transaction)
            for signer in pick.conflictKey.signers {
                guard let chain = chains[signer], let index = positions[pick.cid]?[signer],
                      index + 1 < chain.count else { continue }
                let successor = chain[index + 1]
                indegree[successor.cid]? -= 1
                if indegree[successor.cid] == 0 { frontier.push(successor) }
            }
        }
        return result
    }

    /// A max-fee binary heap (CID ascending breaks ties).
    private struct FeeFrontier {
        private var items: [Entry] = []

        private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
            lhs.minerSurplus != rhs.minerSurplus ? lhs.minerSurplus > rhs.minerSurplus : lhs.cid < rhs.cid
        }

        mutating func push(_ entry: Entry) {
            items.append(entry)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(items[child], items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Entry? {
            guard let top = items.first else { return nil }
            items[0] = items[items.count - 1]
            items.removeLast()
            var parent = 0
            while true {
                var best = parent
                for child in [2 * parent + 1, 2 * parent + 2]
                where child < items.count && precedes(items[child], items[best]) {
                    best = child
                }
                guard best != parent else { break }
                items.swapAt(parent, best)
                parent = best
            }
            return top
        }
    }

    /// Eviction priority when the pool is full: ready over non-ready, then the
    /// higher `minerSurplus` (only when both are ready: a non-ready entry's
    /// debits are not funding-checked, so its fee could be forged), then the
    /// oldest, then the smaller CID. Positive keeps `lhs` over `rhs`.
    private static func retention(_ lhs: Entry, _ rhs: Entry) -> Int {
        let lhsReady = lhs.disposition == .ready
        let rhsReady = rhs.disposition == .ready
        if lhsReady != rhsReady { return lhsReady ? 1 : -1 }
        if lhsReady, lhs.minerSurplus != rhs.minerSurplus {
            return lhs.minerSurplus > rhs.minerSurplus ? 1 : -1
        }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt ? 1 : -1 }
        if lhs.cid != rhs.cid { return lhs.cid < rhs.cid ? 1 : -1 }
        return 0
    }

    /// Apply one preflight verdict to a pooled entry: invalid leaves the pool,
    /// anything else is its new classification.
    @discardableResult
    public mutating func reclassify(_ cid: String, as disposition: MempoolDisposition) -> MempoolMutation {
        var mutation = MempoolMutation()
        guard let entry = entries[cid] else { return mutation }
        if disposition == .invalid {
            if let removed = removeEntry(cid) { mutation.removed = [Self.item(removed)] }
        } else if entry.disposition != disposition {
            mutation.reclassified = [Self.item(entry)]
            entries[cid]?.disposition = disposition
            version &+= 1
        }
        return mutation
    }

    @discardableResult
    public mutating func remove(_ cids: some Sequence<String>) -> MempoolMutation {
        var mutation = MempoolMutation()
        mutation.removed = cids.compactMap { removeEntry($0).map(Self.item) }
        return mutation
    }

    @discardableResult
    public mutating func clear() -> MempoolMutation {
        remove(entries.keys.sorted())
    }

    private static func item(_ entry: Entry) -> MempoolItem {
        MempoolItem(
            cid: entry.cid,
            transaction: entry.transaction,
            disposition: entry.disposition,
            addedAt: entry.addedAt
        )
    }

    private mutating func insert(_ entry: Entry) {
        precondition(entries[entry.cid] == nil)
        entries[entry.cid] = entry
        for signer in entry.conflictKey.signers {
            signerNonces[SignerNonce(signer: signer, nonce: entry.conflictKey.nonce)] = entry.cid
        }
        byteCount += entry.size
        version &+= 1
    }

    private mutating func removeEntry(_ cid: String) -> Entry? {
        guard let removed = entries.removeValue(forKey: cid) else { return nil }
        for signer in removed.conflictKey.signers {
            let key = SignerNonce(signer: signer, nonce: removed.conflictKey.nonce)
            if signerNonces[key] == cid { signerNonces.removeValue(forKey: key) }
        }
        byteCount -= removed.size
        version &+= 1
        return removed
    }
}
