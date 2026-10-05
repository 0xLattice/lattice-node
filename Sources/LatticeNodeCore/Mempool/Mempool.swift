import Lattice
import cashew
import UInt256

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
    /// The fee is under this node's `MempoolLimits.minRelayFee`.
    case belowMinRelayFee
    /// Retriable: the executed tip moved more than `maxReissues` times while
    /// the submit waited for its verdict (the actor's
    /// `templateContextChanged`).
    case contextChanged
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
    /// The smallest fee (`minerSurplus`) admitted. Node relay policy, never
    /// consensus; 0 admits any fee.
    public var minRelayFee: UInt64

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        maxNonReadyPerSigner: Int = 64,
        minRelayFee: UInt64 = 0
    ) {
        precondition(maxCount > 0 && maxBytes > 0 && maxSignatures > 0 && maxNonReadyPerSigner > 0)
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.maxNonReadyPerSigner = maxNonReadyPerSigner
        self.minRelayFee = minRelayFee
    }
}

/// The transaction pool of one level as a value: no IO, no awaits. The same
/// admission, replacement and eviction rules as the shell's `TransactionPool`
/// actor, over transactions whose content is already resolved; templates
/// select by ancestor-package fee rate. `version` moves on every change, so a job built from the pool
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
        guard surplus >= WorkSum(UInt256(limits.minRelayFee)) else {
            throw MempoolError.belowMinRelayFee
        }
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
        // Sorted only when full: admission stays linear in the pool.
        let full = prospectiveCount >= limits.maxCount || entry.size > limits.maxBytes - prospectiveBytes
        let candidates = !full ? [] : entries.values
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

    /// Ready entries, and the future entries that extend them, in template
    /// order, up to `limit` transactions and `maxBytes` of transaction size.
    public func transactions(limit: Int, maxBytes: Int = .max) -> [Transaction] {
        selected(limit: limit, maxBytes: maxBytes, includesUnavailable: false)
    }

    /// Candidate parent state can make a child withdrawal executable, so
    /// unavailable entries may root packages too; the builder preflights them
    /// against that context.
    public func contextualTransactions(limit: Int, maxBytes: Int = .max) -> [Transaction] {
        selected(limit: limit, maxBytes: maxBytes, includesUnavailable: true)
    }

    /// Packages that fail to fit, in a row, before selection gives up on a
    /// nearly full template (Bitcoin Core's `MAX_CONSECUTIVE_FAILURES`).
    static let maxConsecutiveMisses = 1_000

    /// Bitcoin Core's package limits (`-limitancestorcount`,
    /// `-limitdescendantcount`), each counting the entry itself. They bound
    /// every package walk, so selection stays linear in the pool.
    static let maxPackageAncestors = 25
    static let maxPackageDescendants = 25

    /// Greedy ancestor-package fee-rate selection, as Bitcoin Core's
    /// `addPackageTxs`.
    ///
    /// Ancestry is the nonce chain: Lattice applies each signer's
    /// transactions at consecutive nonces, so an entry's parents are the
    /// pooled entries at `nonce - 1` for each of its signers (a multi-signer
    /// entry joins chains). An entry is a candidate only if it can execute
    /// once its ancestors have: it is ready (or, contextually, unavailable),
    /// or EVERY one of its signers has its nonce predecessor pooled; and
    /// every ancestor is a candidate. So a nonce-gap entry, and everything
    /// behind it, stays out. An entry with more than `maxPackageAncestors`
    /// ancestors or `maxPackageDescendants` descendants is not a candidate.
    ///
    /// A package is an entry plus its unselected ancestors; its score is
    /// (sum of verified fees) / (sum of sizes). Only a `.ready` entry's
    /// surplus is funding-checked, so only it counts: an unverified entry can
    /// never raise its ancestors' score. The best-scoring package is
    /// taken whole, parents first; the packages of its descendants are then
    /// rescored without it. A package that does not fit is skipped. Equal
    /// rates break by the smaller CID, so the order is deterministic.
    private func selected(limit: Int, maxBytes: Int, includesUnavailable: Bool) -> [Transaction] {
        guard limit > 0, maxBytes > 0 else { return [] }

        func parents(_ entry: Entry) -> [String] {
            guard entry.conflictKey.nonce > 0 else { return [] }
            return Array(Set(entry.conflictKey.signers.compactMap {
                signerNonces[SignerNonce(signer: $0, nonce: entry.conflictKey.nonce - 1)]
            }))
        }
        var parentsOf: [String: [String]] = [:]
        var childrenOf: [String: [String]] = [:]
        for entry in entries.values {
            let found = parents(entry)
            parentsOf[entry.cid] = found
            for parent in found { childrenOf[parent, default: []].append(entry.cid) }
        }

        /// The entries reachable from `cid` (itself included) along `edges`
        /// inside `within`, counted up to `cap + 1`.
        func reach(_ cid: String, _ edges: [String: [String]], within: Set<String>, cap: Int) -> Int {
            var seen: Set<String> = [cid]
            var stack = [cid]
            while seen.count <= cap, let next = stack.popLast() {
                for other in edges[next] ?? [] where within.contains(other) && seen.insert(other).inserted {
                    stack.append(other)
                }
            }
            return seen.count
        }

        // Nonces strictly increase along every edge, so ascending nonce is a
        // topological order.
        let ordered = entries.values.sorted(by: Self.topological)
        var executable = Set<String>()
        for entry in ordered {
            let roots = entry.disposition == .ready
                || (includesUnavailable && entry.disposition == .unavailable)
            let extendsEverySigner = entry.conflictKey.nonce > 0 && entry.conflictKey.signers.allSatisfy {
                signerNonces[SignerNonce(signer: $0, nonce: entry.conflictKey.nonce - 1)] != nil
            }
            if (roots || extendsEverySigner),
               (parentsOf[entry.cid] ?? []).allSatisfy(executable.contains),
               reach(entry.cid, parentsOf, within: executable, cap: Self.maxPackageAncestors)
                   <= Self.maxPackageAncestors {
                executable.insert(entry.cid)
            }
        }
        let tooWide = executable.filter {
            reach($0, childrenOf, within: executable, cap: Self.maxPackageDescendants) > Self.maxPackageDescendants
        }
        var candidates = Set<String>()
        for entry in ordered where executable.contains(entry.cid) && !tooWide.contains(entry.cid)
            && (parentsOf[entry.cid] ?? []).allSatisfy(candidates.contains) {
            candidates.insert(entry.cid)
        }

        var picked = Set<String>()
        func package(_ cid: String) -> [Entry] {
            var seen: Set<String> = [cid]
            var stack = [cid]
            while let next = stack.popLast() {
                for parent in parentsOf[next] ?? [] where !picked.contains(parent) && seen.insert(parent).inserted {
                    stack.append(parent)
                }
            }
            return seen.compactMap { entries[$0] }.sorted(by: Self.topological)
        }

        var frontier = PackageFrontier()
        var generation: [String: Int] = [:]
        func score(_ cid: String) {
            let members = package(cid)
            let next = (generation[cid] ?? 0) + 1
            generation[cid] = next
            frontier.push(PackageScore(
                cid: cid,
                fee: members.reduce(.zero) { $1.disposition == .ready ? $0 + $1.minerSurplus : $0 },
                size: members.reduce(0) { $0 + $1.size },
                generation: next
            ))
        }
        for cid in candidates.sorted() { score(cid) }

        var result: [Transaction] = []
        var bytes = 0
        var skipped = Set<String>()
        var misses = 0
        while result.count < limit, let top = frontier.pop() {
            guard generation[top.cid] == top.generation,
                  !picked.contains(top.cid), !skipped.contains(top.cid) else { continue }
            let members = package(top.cid)
            guard members.count <= limit - result.count, top.size <= maxBytes - bytes else {
                skipped.insert(top.cid)
                misses += 1
                if misses >= Self.maxConsecutiveMisses { break }
                continue
            }
            misses = 0
            for member in members {
                picked.insert(member.cid)
                result.append(member.transaction)
            }
            bytes += top.size

            var affected = Set<String>()
            var stack = members.map(\.cid)
            while let next = stack.popLast() {
                for child in childrenOf[next] ?? [] where candidates.contains(child) && affected.insert(child).inserted {
                    stack.append(child)
                }
            }
            for cid in affected.sorted() where !picked.contains(cid) && !skipped.contains(cid) {
                score(cid)
            }
        }
        return result
    }

    private static func topological(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.conflictKey.nonce != rhs.conflictKey.nonce
            ? lhs.conflictKey.nonce < rhs.conflictKey.nonce
            : lhs.cid < rhs.cid
    }

    private struct PackageScore {
        let cid: String
        let fee: WorkSum
        let size: Int
        let generation: Int

        /// A higher fee rate first, compared exactly: `a.fee / a.size >
        /// b.fee / b.size` as `a.fee * b.size > b.fee * a.size`. Equal rates
        /// break by the smaller CID.
        func precedes(_ other: PackageScore) -> Bool {
            let lhs = Self.scaled(fee, by: other.size)
            let rhs = Self.scaled(other.fee, by: size)
            return lhs != rhs ? lhs > rhs : cid < other.cid
        }

        /// `value * factor` by doubling: WorkSum has no multiply.
        static func scaled(_ value: WorkSum, by factor: Int) -> WorkSum {
            var result = WorkSum.zero
            var addend = value
            var remaining = factor
            while remaining > 0 {
                if remaining & 1 == 1 { result = result + addend }
                remaining >>= 1
                if remaining > 0 { addend = addend + addend }
            }
            return result
        }
    }

    /// A max-score binary heap; stale scores are skipped at pop.
    private struct PackageFrontier {
        private var items: [PackageScore] = []

        mutating func push(_ score: PackageScore) {
            items.append(score)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].precedes(items[parent]) else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> PackageScore? {
            guard let top = items.first else { return nil }
            items[0] = items[items.count - 1]
            items.removeLast()
            var parent = 0
            while true {
                var best = parent
                for child in [2 * parent + 1, 2 * parent + 2]
                where child < items.count && items[child].precedes(items[best]) {
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
