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
    /// An account it debits cannot also pay what pooled transactions
    /// already debit it, and it does not outbid them. Retriable once those
    /// are mined.
    case insufficientFunds
    /// It shares its first signer's nonce, a state key, a deposit or a
    /// receipt with pooled transactions, and does not pay
    /// `MempoolLimits.replacementIncrement` more than all it would displace.
    case feeTooLow
    /// The fee is under this node's `MempoolLimits.minRelayFee`.
    case belowMinRelayFee
    /// Its nonce is ahead of the chain's: an earlier transaction from its
    /// first signer is not mined yet. Retriable once it is. The pool holds
    /// only transactions that can execute now.
    case nonceAhead
    /// This node cannot judge it now (state, a policy module, or a
    /// withdrawal's receipt it does not hold yet). Retriable.
    case unavailable
    /// Retriable: the executed tip moved more than `maxReissues` times while
    /// the submit waited for its verdict (the actor's
    /// `templateContextChanged`).
    case contextChanged
}

/// Lattice's classification of a transaction against one executed tip. Only
/// `.ready` is pooled.
public enum MempoolDisposition: Sendable, Equatable {
    case ready
    case future
    case unavailable
    case invalid
}

public struct MempoolItem: Sendable {
    public let cid: String
    public let transaction: Transaction
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

    /// Every entry that left the pool.
    public var departed: [MempoolItem] { replaced + evicted + removed }
}

public struct MempoolLimits: Sendable, Equatable {
    public var maxCount: Int
    public var maxBytes: Int
    public var maxSignatures: Int
    /// The smallest fee (`minerSurplus`) admitted. Node relay policy, never
    /// consensus. 0 admits any fee, and pool space is then free to hold.
    public var minRelayFee: UInt64

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        minRelayFee: UInt64 = 0
    ) {
        precondition(maxCount > 0 && maxBytes > 0 && maxSignatures > 0)
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.minRelayFee = minRelayFee
    }

    /// How much more a transaction pays than all it displaces: the relay
    /// floor, and at least 1 (BIP125 rules 3 and 4). Each displacement costs
    /// the sender at least this much in the fee that is finally mined, so
    /// churning the pool is bounded by the sender's balance.
    public var replacementIncrement: UInt64 { max(1, minRelayFee) }
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

    /// One more transaction of `size` bytes, from a package of rate `fee` over `packageSize`.
    func adding(_ size: Int, fee: WorkSum, packageSize: Int) -> ProjectedBlock {
        let lower = Mempool.lowerRate(fee, packageSize, than: lowestFee, lowestFeeBytes)
        return ProjectedBlock(
            transactionCount: transactionCount + 1, bytes: bytes + size,
            lowestFee: lower ? fee : lowestFee, lowestFeeBytes: lower ? packageSize : lowestFeeBytes, full: full
        )
    }

    func closed() -> ProjectedBlock {
        ProjectedBlock(transactionCount: transactionCount, bytes: bytes, lowestFee: lowestFee, lowestFeeBytes: lowestFeeBytes, full: true)
    }
}

/// The transaction pool of one level as a value: no IO, no awaits. It holds
/// only transactions Lattice's preflight found ready: each executes on the
/// tip as it stands, with its funds checked. None waits on another, so a
/// template takes them by fee rate alone.
///
/// Two rules keep every pooled transaction executable alongside every other:
/// - What only one transaction can ever use is claimed once: the first
///   signer's nonce, each state key written, each deposit and receipt.
/// - Money is budgeted: an account's debits across the pool never exceed
///   its balance on the tip, as preflight read it. An account backs as many
///   transactions as it can pay, and no more.
/// A conflict, over a claim or an account's balance, goes to the higher fee:
/// a newcomer displaces what it conflicts with by paying all of their fees
/// and `replacementIncrement` more. `version` moves on every change, so a
/// job built from the pool names the pool it read.
public struct Mempool: Sendable {
    /// Bound parse work by wire capacity (a 16-bit length), not an invented
    /// cap: the signature's crypto verification is the authoritative check.
    static let maximumSignatureFieldBytes = Int(UInt16.max)

    private struct Entry: Sendable {
        let cid: String
        let transaction: Transaction
        let size: Int
        let claims: Set<String>
        let debits: [String: UInt64]
        let fee: WorkSum
        let addedAt: Int64
    }

    public let limits: MempoolLimits
    private var entries: [String: Entry] = [:]
    /// Each claim's pooled transaction.
    private var claimants: [String: String] = [:]
    /// Each account's debits across the pool, for accounts pooled
    /// transactions debit.
    private var committed: [String: UInt64] = [:]
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

    /// What a transaction claims: its first signer's nonce, each state key
    /// it writes, and each deposit and receipt it creates or spends. Other
    /// signers' funds are budgeted, not claimed (`debits(of:)`).
    static func claims(of body: TransactionBody) -> Set<String> {
        var claims = Set(body.signers.prefix(1).map { "signer:" + $0 })
        for action in body.actions { claims.insert("action:" + action.key) }
        for deposit in body.depositActions { claims.insert("deposit:" + DepositKey(depositAction: deposit).description) }
        for withdrawal in body.withdrawalActions {
            claims.insert("deposit:" + DepositKey(withdrawalAction: withdrawal).description)
        }
        for receipt in body.receiptActions { claims.insert("receipt:" + ReceiptKey(receiptAction: receipt).description) }
        return claims
    }

    /// What a transaction takes from each account, as consensus nets it:
    /// its account actions and the receipts it pays (`netOutflows`). Nil
    /// when consensus would refuse the sums.
    public static func debits(of body: TransactionBody) -> [String: UInt64]? {
        try? body.netOutflows()
    }

    /// The size checks that need no state, run before a transaction costs a
    /// preflight job. `submit` runs them again.
    public func check(_ transaction: Transaction, spec: ChainSpec) throws -> String {
        try measure(transaction, spec: spec).cid
    }

    private func measure(
        _ transaction: Transaction,
        spec: ChainSpec
    ) throws -> (cid: String, body: TransactionBody, size: Int, surplus: WorkSum, debits: [String: UInt64]) {
        guard transaction.signatures.count <= limits.maxSignatures,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }) else {
            throw MempoolError.tooLarge
        }
        guard let body = transaction.body.node else { throw MempoolError.unresolved }
        guard let bodyData = body.toData() else { throw MempoolError.unresolved }
        let room = Self.transactionRoom(spec)
        guard bodyData.count <= room,
              let envelopeData = transaction.toData(),
              envelopeData.count <= room,
              body.signers.count <= limits.maxSignatures else {
            throw MempoolError.tooLarge
        }
        // A transaction that creates value (credits and deposits over debits
        // and withdrawals) breaks the fee rule in any block, so it is never
        // pooled: a template carrying it would be invalid.
        guard let surplus = body.minerSurplus(), let debits = Self.debits(of: body) else { throw MempoolError.invalidState }
        guard surplus >= WorkSum(UInt256(limits.minRelayFee)) else {
            throw MempoolError.belowMinRelayFee
        }
        let (size, overflow) = envelopeData.count.addingReportingOverflow(bodyData.count)
        guard !overflow, size <= room else { throw MempoolError.tooLarge }
        return (try Self.cid(of: transaction), body, size, surplus, debits)
    }

    /// The most bytes a transaction may have: what is left of `maxBlockSize`
    /// in a block carrying only it. The block's own fields and transaction
    /// trie count toward the limit, so a transaction of `maxBlockSize` bytes
    /// could never be mined, and the builder, which takes the template's
    /// longest prefix that fits, would stop at it.
    public static func transactionRoom(_ spec: ChainSpec) -> Int {
        spec.maxBlockSize - blockAllowance
    }

    /// A block's content besides its transactions, with room to spare: an
    /// empty Nexus block measures 766 bytes (about 1,000 with its height,
    /// timestamp and nonce at their largest), and a transaction adds about
    /// 180 to the trie.
    static let blockAllowance = 2_048

    /// Pool a transaction preflight found ready. `balances` holds, for each
    /// account it debits, the balance preflight read on the tip; one
    /// missing counts as empty.
    @discardableResult
    public mutating func submit(
        _ transaction: Transaction,
        spec: ChainSpec,
        addedAt: Int64,
        balances: [String: UInt64]
    ) throws -> MempoolMutation {
        let measured = try measure(transaction, spec: spec)
        let cid = measured.cid
        if entries[cid] != nil {
            return MempoolMutation(transactionCID: cid)
        }
        guard measured.size <= limits.maxBytes else { throw MempoolError.tooLarge }
        let entry = Entry(
            cid: cid,
            transaction: transaction,
            size: measured.size,
            claims: Self.claims(of: measured.body),
            debits: measured.debits,
            fee: measured.surplus,
            addedAt: addedAt
        )

        // Conflicts go to the higher fee. It displaces every pooled
        // transaction sharing a claim with it, and, for each account it
        // debits, that account's lowest-paying transactions until its own
        // debit fits the balance. It must pay what they all pay plus the
        // increment: every displacement costs the sender in the fee that is
        // finally mined, so bids cannot be raised for free.
        var displaced: [String: Entry] = [:]
        for claim in entry.claims {
            if let holder = claimants[claim], let existing = entries[holder] { displaced[holder] = existing }
        }
        let claimsConflict = !displaced.isEmpty
        for (account, debit) in entry.debits.sorted(by: { $0.key < $1.key }) {
            let balance = balances[account, default: 0]
            guard debit <= balance else { throw MempoolError.insufficientFunds }
            var held = committed[account, default: 0] - displaced.values.reduce(0) { $0 + ($1.debits[account] ?? 0) }
            guard held > balance || debit > balance - held else { continue }
            let debiting = entries.values
                .filter { $0.debits[account] != nil && displaced[$0.cid] == nil }
                .sorted { Self.retention($0, $1) < 0 }
            for existing in debiting where held > balance || debit > balance - held {
                displaced[existing.cid] = existing
                held -= existing.debits[account] ?? 0
            }
        }
        if !displaced.isEmpty {
            let owed = displaced.values.reduce(WorkSum(UInt256(limits.replacementIncrement))) { $0 + $1.fee }
            guard entry.fee >= owed else {
                throw claimsConflict ? MempoolError.feeTooLow : MempoolError.insufficientFunds
            }
        }

        var prospectiveCount = entries.count - displaced.count
        var prospectiveBytes = byteCount - displaced.values.reduce(0) { $0 + $1.size }
        var evictions: [String] = []
        // Sorted only when full: admission stays linear in the pool.
        let full = prospectiveCount >= limits.maxCount || entry.size > limits.maxBytes - prospectiveBytes
        let candidates = !full ? [] : entries.values
            .filter { displaced[$0.cid] == nil }
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
        mutation.replaced = displaced.keys.sorted().compactMap { removeEntry($0).map(Self.item) }
        mutation.evicted = evictions.compactMap { removeEntry($0).map(Self.item) }
        insert(entry)
        mutation.inserted = Self.item(entry)
        return mutation
    }

    /// Pooled transactions in template order (the higher fee rate first,
    /// then the smaller CID), up to `limit` transactions and `maxBytes` of
    /// transaction size. One that does not fit is skipped for a smaller one
    /// behind it.
    public func transactions(limit: Int, maxBytes: Int = .max) -> [Transaction] {
        var result: [Transaction] = []
        _ = selected(limit: limit, maxBytes: maxBytes) { entry in
            result.append(entry.transaction)
            return true
        }
        return result
    }

    /// What the next block can carry: pooled transactions in template order,
    /// skipping one that does not fit for a smaller one behind it, up to the
    /// spec's transaction count and `transactionRoom`. A template judges
    /// these by its policies, never the whole pool.
    public func nextBlock(_ spec: ChainSpec) -> [Transaction] {
        transactions(limit: Int(clamping: spec.maxNumberOfTransactionsPerBlock), maxBytes: Self.transactionRoom(spec))
    }

    /// The next `count` blocks this pool would fill if nothing else arrived,
    /// as this node's builder fills them: transactions in template order,
    /// each block taking them until one does not fit in `transactionLimit`
    /// transactions or `maxBytes` of transaction size. A block's rate is the
    /// lowest it carries. An estimate for fee pricing, not a template: the
    /// block's own structure, which grows with its transaction count, shares
    /// `maxBytes`, and other miners may fill gaps with smaller transactions.
    /// Empty when the pool is.
    public func projectedBlocks(count: Int, transactionLimit: Int, maxBytes: Int) -> [ProjectedBlock] {
        guard count > 0, transactionLimit > 0, maxBytes > 0 else { return [] }
        var blocks: [ProjectedBlock] = []
        var current: ProjectedBlock?
        for entry in ordered {
            if let block = current, block.transactionCount < transactionLimit, entry.size <= maxBytes - block.bytes {
                current = block.adding(entry.size, fee: entry.fee, packageSize: entry.size)
                continue
            }
            if let block = current {
                blocks.append(block.closed())
                if blocks.count == count { return blocks }
            }
            // Admission caps a transaction at the block size, so one always
            // fits an empty block.
            current = ProjectedBlock(
                transactionCount: 1, bytes: entry.size, lowestFee: entry.fee, lowestFeeBytes: entry.size, full: false
            )
        }
        if let current, blocks.count < count { blocks.append(current) }
        return blocks
    }

    /// Transactions that fail to fit, in a row, before selection gives up on
    /// a nearly full template (Bitcoin Core's `MAX_CONSECUTIVE_FAILURES`).
    static let maxConsecutiveMisses = 1_000

    /// Every entry, the higher fee rate first, then the smaller CID.
    private var ordered: [Entry] {
        entries.values.sorted { lhs, rhs in
            let order = Self.rate(lhs, comparedTo: rhs)
            return order != 0 ? order > 0 : lhs.cid < rhs.cid
        }
    }

    private func selected(limit: Int, maxBytes: Int, _ take: (Entry) -> Bool) -> Int {
        guard limit > 0, maxBytes > 0 else { return 0 }
        var taken = 0
        var bytes = 0
        var misses = 0
        for entry in ordered {
            guard taken < limit else { break }
            guard entry.size <= maxBytes - bytes else {
                misses += 1
                if misses >= Self.maxConsecutiveMisses { break }
                continue
            }
            misses = 0
            taken += 1
            bytes += entry.size
            if !take(entry) { break }
        }
        return taken
    }

    /// Whether `lhs` pays a higher fee rate than `rhs` (positive), the same
    /// (zero) or a lower one, compared exactly: `lhs.fee * rhs.size` against
    /// `rhs.fee * lhs.size`.
    private static func rate(_ lhs: Entry, comparedTo rhs: Entry) -> Int {
        Self.rate(lhs.fee, lhs.size, comparedTo: rhs.fee, rhs.size)
    }

    private static func rate(_ fee: WorkSum, _ size: Int, comparedTo otherFee: WorkSum, _ otherSize: Int) -> Int {
        if let lhsFee = fee.uint64Value, let rhsFee = otherFee.uint64Value {
            let lhs = lhsFee.multipliedFullWidth(by: UInt64(otherSize))
            let rhs = rhsFee.multipliedFullWidth(by: UInt64(size))
            return lhs == rhs ? 0 : (lhs.high, lhs.low) > (rhs.high, rhs.low) ? 1 : -1
        }
        let lhs = scaled(fee, by: otherSize)
        let rhs = scaled(otherFee, by: size)
        return lhs == rhs ? 0 : lhs > rhs ? 1 : -1
    }

    /// `value * factor` by doubling: WorkSum has no multiply.
    private static func scaled(_ value: WorkSum, by factor: Int) -> WorkSum {
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

    /// Whether `fee` over `size` is a lower rate than `otherFee` over `otherSize`, exactly.
    static func lowerRate(_ fee: WorkSum, _ size: Int, than otherFee: WorkSum, _ otherSize: Int) -> Bool {
        rate(fee, size, comparedTo: otherFee, otherSize) < 0
    }

    /// Eviction priority when the pool is full: the higher fee rate, then
    /// the oldest, then the smaller CID. Positive keeps `lhs` over `rhs`.
    private static func retention(_ lhs: Entry, _ rhs: Entry) -> Int {
        let order = rate(lhs, comparedTo: rhs)
        if order != 0 { return order }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt ? 1 : -1 }
        if lhs.cid != rhs.cid { return lhs.cid < rhs.cid ? 1 : -1 }
        return 0
    }

    @discardableResult
    public mutating func remove(_ cids: some Sequence<String>) -> MempoolMutation {
        var mutation = MempoolMutation()
        mutation.removed = cids.compactMap { removeEntry($0).map(Self.item) }
        return mutation
    }

    /// A verdict on the tip read these balances: an account whose pooled
    /// debits no longer fit sheds its lowest-paying transactions until the
    /// rest do.
    @discardableResult
    public mutating func rebalance(_ balances: [String: UInt64]) -> MempoolMutation {
        var mutation = MempoolMutation()
        for (account, balance) in balances.sorted(by: { $0.key < $1.key }) where committed[account, default: 0] > balance {
            let debiting = entries.values.filter { $0.debits[account] != nil }.sorted { Self.retention($0, $1) < 0 }
            for entry in debiting where committed[account, default: 0] > balance {
                if let removed = removeEntry(entry.cid) { mutation.evicted.append(Self.item(removed)) }
            }
        }
        return mutation
    }

    @discardableResult
    public mutating func clear() -> MempoolMutation {
        remove(entries.keys.sorted())
    }

    private static func item(_ entry: Entry) -> MempoolItem {
        MempoolItem(cid: entry.cid, transaction: entry.transaction, addedAt: entry.addedAt)
    }

    private mutating func insert(_ entry: Entry) {
        precondition(entries[entry.cid] == nil)
        entries[entry.cid] = entry
        for claim in entry.claims { claimants[claim] = entry.cid }
        for (account, debit) in entry.debits { committed[account, default: 0] += debit }
        byteCount += entry.size
        version &+= 1
    }

    private mutating func removeEntry(_ cid: String) -> Entry? {
        guard let removed = entries.removeValue(forKey: cid) else { return nil }
        for claim in removed.claims where claimants[claim] == cid { claimants.removeValue(forKey: claim) }
        for (account, debit) in removed.debits {
            let left = committed[account, default: 0] - debit
            committed[account] = left == 0 ? nil : left
        }
        byteCount -= removed.size
        version &+= 1
        return removed
    }
}
