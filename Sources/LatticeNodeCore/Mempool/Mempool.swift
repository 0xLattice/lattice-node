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

/// One block of `Mempool.projectedBlocks`.
public struct ProjectedBlock: Sendable, Equatable {
    public let transactionCount: Int
    /// Transaction size it carries (envelope plus body, as the pool measures).
    public let bytes: Int
    /// Its lowest-rate package: the verified fee over its size in bytes. A
    /// transaction paying a higher rate would have been taken before it.
    public let lowestFee: WorkSum
    public let lowestFeeBytes: Int
    /// Whether ready transactions were left for a later block.
    public let full: Bool

    func adding(count: Int, fee: WorkSum, size: Int) -> ProjectedBlock {
        let lower = Mempool.lowerRate(fee, size, than: lowestFee, lowestFeeBytes)
        return ProjectedBlock(
            transactionCount: transactionCount + count, bytes: bytes + size,
            lowestFee: lower ? fee : lowestFee, lowestFeeBytes: lower ? size : lowestFeeBytes, full: full
        )
    }

    func closed() -> ProjectedBlock {
        ProjectedBlock(transactionCount: transactionCount, bytes: bytes, lowestFee: lowestFee, lowestFeeBytes: lowestFeeBytes, full: true)
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

    /// The nonce slot a transaction occupies: its first signer's, the only
    /// nonce consensus checks and advances (empty for a signer-less body).
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
    /// Each chain's entries by nonce, under `chainKey`.
    private var chainEntries: [String: [UInt64: String]] = [:]
    /// Each chain's selectable runs, kept as the pool changes.
    private var chains: [String: Chain] = [:]
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
            signers: measured.body.signers.first.map { [$0] } ?? [],
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
        // signer gives up, so the bid cannot be raised for free.
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

    /// The next `count` blocks this pool would fill if nothing else arrived:
    /// the ready packages in template order, each block taking them until
    /// one does not fit in `transactionLimit` transactions or `maxBytes` of
    /// transaction size. An estimate for fee pricing, not a template: a
    /// miner also fills a block's gaps with smaller packages, and the block's
    /// own overhead shares `maxBytes`. Empty when nothing is ready.
    public func projectedBlocks(count: Int, transactionLimit: Int, maxBytes: Int) -> [ProjectedBlock] {
        guard count > 0, transactionLimit > 0, maxBytes > 0 else { return [] }
        var blocks: [ProjectedBlock] = []
        var current: ProjectedBlock?
        _ = selected(limit: .max, maxBytes: .max, includesUnavailable: false) { members, fee, size in
            if let block = current,
               members.count <= transactionLimit - block.transactionCount, size <= maxBytes - block.bytes {
                current = block.adding(count: members.count, fee: fee, size: size)
                return true
            }
            if let block = current {
                blocks.append(block.closed())
                if blocks.count == count { return false }
            }
            current = ProjectedBlock(transactionCount: members.count, bytes: size, lowestFee: fee, lowestFeeBytes: size, full: false)
            return true
        }
        if let current, blocks.count < count { blocks.append(current) }
        return blocks
    }

    /// Packages that fail to fit, in a row, before selection gives up on a
    /// nearly full template (Bitcoin Core's `MAX_CONSECUTIVE_FAILURES`).
    static let maxConsecutiveMisses = 1_000

    /// Bitcoin Core's package limits (`-limitancestorcount`,
    /// `-limitdescendantcount`, both 25), each counting the entry itself. A
    /// run is a chain, so both cap it at its first 25 entries.
    static let maxPackageAncestors = 25

    /// Greedy package fee-rate selection, as Bitcoin Core's `addPackageTxs`,
    /// over chains.
    ///
    /// Ancestry is the nonce chain: Lattice applies each first signer's
    /// transactions at consecutive nonces, so an entry's parent is the
    /// pooled entry at `nonce - 1` for its first signer (co-signers' nonces
    /// are not consensus). Every package is therefore a prefix of what is
    /// left of a run (see `rerun`); its score is (sum of verified fees) /
    /// (sum of sizes). Only a `.ready` entry's surplus is funding-checked, so
    /// only it counts: an unverified entry can never raise its ancestors'
    /// score.
    ///
    /// Each run offers its best package (`bestPrefix`) to a heap. The best
    /// offer is taken whole if it fits, and its run offers the best of what
    /// is left. One that does not fit is skipped, no package ends at its last
    /// entry again, and its run offers its next best. Equal rates break by
    /// the smaller CID of the package's last entry, so the order is
    /// deterministic. Runs keep their first offer as the pool changes, so the
    /// work is in the packages taken, not the pool. `visit`, when given,
    /// sees each package as it is taken (its members, fee and size) and ends
    /// selection by returning false.
    private func selected(
        limit: Int,
        maxBytes: Int,
        includesUnavailable: Bool,
        visit: ((_ members: [Entry], _ fee: WorkSum, _ size: Int) -> Bool)? = nil
    ) -> [Transaction] {
        guard limit > 0, maxBytes > 0 else { return [] }

        // Each run's counted entries and where what is left of it starts.
        var runs: [(members: [String], start: Int)] = []
        var offers: [PackageScore] = []
        for chain in chains.values {
            for run in chain.runs.values where includesUnavailable ? run.contextual : run.ready {
                offers.append(PackageScore(run: runs.count, package: run.first))
                runs.append((run.members, 0))
            }
        }
        var frontier = PackageFrontier(offers)

        var result: [Transaction] = []
        var bytes = 0
        var skipped = Set<String>()
        var misses = 0
        while result.count < limit, let top = frontier.pop() {
            let package = top.package
            if package.members.count <= limit - result.count, package.size <= maxBytes - bytes {
                misses = 0
                let members = package.members.compactMap { entries[$0] }
                result.append(contentsOf: members.map(\.transaction))
                bytes += package.size
                if let visit, !visit(members, package.fee, package.size) { break }
                runs[top.run].start += members.count
            } else {
                skipped.insert(package.tip)
                misses += 1
                if misses >= Self.maxConsecutiveMisses { break }
            }
            let rest = runs[top.run].members[runs[top.run].start...].compactMap { entries[$0] }
            if let next = Self.bestPrefix(rest, skipping: skipped) {
                frontier.push(PackageScore(run: top.run, package: next))
            }
        }
        return result
    }

    /// Consecutive verified fees and sizes taken together: one entry, or a
    /// prefix of a run.
    private struct Chunk: Sendable {
        var members: [String]
        var fee: WorkSum
        var size: Int
        /// `fee` when it fits 64 bits, as a funded fee always does: rates
        /// then compare in 128-bit integers, not by `WorkSum` doubling.
        let fee64: UInt64?

        init(members: [String], fee: WorkSum, size: Int) {
            self.members = members
            self.fee = fee
            self.size = size
            fee64 = fee.uint64Value
        }

        /// Whether this pays a higher rate than `other` (positive), the same
        /// (zero) or a lower one, compared exactly.
        func rate(comparedTo other: Chunk) -> Int {
            if let lhsFee = fee64, let rhsFee = other.fee64 {
                let lhs = lhsFee.multipliedFullWidth(by: UInt64(other.size))
                let rhs = rhsFee.multipliedFullWidth(by: UInt64(size))
                return lhs == rhs ? 0 : (lhs.high, lhs.low) > (rhs.high, rhs.low) ? 1 : -1
            }
            let lhs = PackageScore.scaled(fee, by: other.size)
            let rhs = PackageScore.scaled(other.fee, by: size)
            return lhs == rhs ? 0 : lhs > rhs ? 1 : -1
        }

        /// One entry; only a `.ready` entry's surplus is funding-checked.
        init(_ entry: Entry) {
            self.init(members: [entry.cid], fee: entry.disposition == .ready ? entry.minerSurplus : .zero, size: entry.size)
        }

        var tip: String { members.last ?? "" }

        func merged(with later: Chunk) -> Chunk {
            Chunk(members: members + later.members, fee: fee + later.fee, size: size + later.size)
        }
    }

    /// A selectable run: its counted entries, its best package, and which
    /// selections take it (`transactions` when its head is ready,
    /// `contextualTransactions` also when it is unavailable).
    private struct Run: Sendable {
        /// Its first `maxPackageAncestors` entries, in nonce order.
        let members: [String]
        /// Its best package, before anything is taken or skipped.
        let first: Chunk
        let ready: Bool
        let contextual: Bool
    }

    /// A chain's selectable runs, by head nonce.
    private struct Chain: Sendable {
        var runs: [UInt64: Run] = [:]
    }

    /// The chain an entry belongs to: its first signer's, or its own when it
    /// has no signer (then it extends nothing).
    private static func chainKey(_ entry: Entry) -> String {
        entry.conflictKey.signers.first ?? "\u{0}" + entry.cid
    }

    /// The best package of what is left of a run (`rest`, in nonce order):
    /// the prefix with the highest rate, at equal rates the one whose last
    /// entry has the smaller CID, among prefixes not ending at a skipped
    /// entry. Nil when every prefix ends at one.
    private static func bestPrefix(_ rest: [Entry], skipping skipped: Set<String> = []) -> Chunk? {
        var prefix = Chunk(members: [], fee: .zero, size: 0)
        var best: Chunk?
        for entry in rest {
            prefix = prefix.merged(with: Chunk(entry))
            guard !skipped.contains(entry.cid) else { continue }
            if let current = best {
                let order = prefix.rate(comparedTo: current)
                guard order > 0 || (order == 0 && entry.cid < current.tip) else { continue }
            }
            best = prefix
        }
        return best
    }

    /// Bring a chain's runs up to date after the entry at `nonce` arrived,
    /// left or changed class. Only a run's first `maxPackageAncestors`
    /// entries count, so the change reaches at most the run whose head is
    /// that close behind it, and the run that starts (or no longer starts)
    /// right after it: the work is bounded however long the chain.
    private mutating func touch(_ key: String, at nonce: UInt64) {
        let present = chainEntries[key] ?? [:]
        var head: UInt64? = present[nonce] != nil ? nonce
            : nonce > 0 && present[nonce - 1] != nil ? nonce - 1 : nil
        var steps = 0
        while let current = head, current > 0, present[current - 1] != nil, steps < Self.maxPackageAncestors {
            head = current - 1
            steps += 1
        }
        if let head { rerun(key, head: head) }
        // A head that left takes its run with it.
        if head != nonce { rerun(key, head: nonce) }
        if nonce < .max { rerun(key, head: nonce + 1) }
        if chains[key]?.runs.isEmpty == true { chains[key] = nil }
    }

    /// Recompute the run headed at `head`, or drop it when no run starts
    /// there. A run is consecutive pooled nonces; it is selectable when its
    /// head can execute without a pooled predecessor: ready (or,
    /// contextually, unavailable), or signer-less at a nonce past 0.
    /// Everything behind a nonce gap waits for its own head.
    private mutating func rerun(_ key: String, head: UInt64) {
        let present = chainEntries[key] ?? [:]
        guard let headCID = present[head], let first = entries[headCID],
              head == 0 || present[head - 1] == nil else {
            chains[key]?.runs[head] = nil
            return
        }
        var run = [first]
        while run.count < Self.maxPackageAncestors, let last = run.last, last.conflictKey.nonce < .max,
              let cid = present[last.conflictKey.nonce + 1], let next = entries[cid] {
            run.append(next)
        }
        let extendsNothing = first.conflictKey.signers.isEmpty && first.conflictKey.nonce > 0
        let ready = first.disposition == .ready || extendsNothing
        let contextual = ready || first.disposition == .unavailable
        guard ready || contextual else {
            chains[key]?.runs[head] = nil
            return
        }
        guard let first = Self.bestPrefix(run) else {
            chains[key]?.runs[head] = nil
            return
        }
        chains[key, default: Chain()].runs[head] = Run(
            members: run.map(\.cid), first: first, ready: ready, contextual: contextual
        )
    }

    /// Whether `fee` over `size` is a lower rate than `otherFee` over `otherSize`, exactly.
    static func lowerRate(_ fee: WorkSum, _ size: Int, than otherFee: WorkSum, _ otherSize: Int) -> Bool {
        Chunk(members: [], fee: fee, size: size).rate(comparedTo: Chunk(members: [], fee: otherFee, size: otherSize)) < 0
    }

    /// A package on offer: the best prefix of what is left of run `run`.
    private struct PackageScore {
        let run: Int
        let package: Chunk

        /// A higher fee rate first, compared exactly: `a.fee / a.size >
        /// b.fee / b.size` as `a.fee * b.size > b.fee * a.size`. Equal rates
        /// break by the smaller CID of the package's last entry.
        func precedes(_ other: PackageScore) -> Bool {
            let order = package.rate(comparedTo: other.package)
            return order != 0 ? order > 0 : package.tip < other.package.tip
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
        private var items: [PackageScore]

        /// A heap of `offers`, built in one pass.
        init(_ offers: [PackageScore] = []) {
            items = offers
            for index in stride(from: items.count / 2 - 1, through: 0, by: -1) { siftDown(index) }
        }

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
            siftDown(0)
            return top
        }

        private mutating func siftDown(_ start: Int) {
            var parent = start
            while true {
                var best = parent
                let left = 2 * parent + 1, right = left + 1
                if left < items.count, items[left].precedes(items[best]) { best = left }
                if right < items.count, items[right].precedes(items[best]) { best = right }
                guard best != parent else { return }
                items.swapAt(parent, best)
                parent = best
            }
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
            touch(Self.chainKey(entry), at: entry.conflictKey.nonce)
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
        let key = Self.chainKey(entry)
        chainEntries[key, default: [:]][entry.conflictKey.nonce] = entry.cid
        touch(key, at: entry.conflictKey.nonce)
        version &+= 1
    }

    private mutating func removeEntry(_ cid: String) -> Entry? {
        guard let removed = entries.removeValue(forKey: cid) else { return nil }
        for signer in removed.conflictKey.signers {
            let key = SignerNonce(signer: signer, nonce: removed.conflictKey.nonce)
            if signerNonces[key] == cid { signerNonces.removeValue(forKey: key) }
        }
        byteCount -= removed.size
        let key = Self.chainKey(removed)
        if chainEntries[key]?[removed.conflictKey.nonce] == cid {
            chainEntries[key]?[removed.conflictKey.nonce] = nil
            if chainEntries[key]?.isEmpty == true { chainEntries[key] = nil }
        }
        touch(key, at: removed.conflictKey.nonce)
        version &+= 1
        return removed
    }
}
