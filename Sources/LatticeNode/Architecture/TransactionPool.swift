import Foundation
import Lattice
import UInt256
import cashew

public enum TransactionPoolError: Error, Equatable {
    case unresolved
    case tooLarge
    case full
    case invalidState
    case conflictingNonce
    case feeTooLow
}

public enum TransactionPoolDisposition: Sendable, Equatable {
    case ready
    case future
    case unavailable
    case invalid
}

public struct TransactionPoolItem: Sendable {
    public let cid: String
    public let transaction: Transaction
    public let disposition: TransactionPoolDisposition
    public let addedAt: Date
}

public struct TransactionPoolMutation: Sendable {
    public let transactionCID: String?
    public let inserted: TransactionPoolItem?
    public let replaced: [TransactionPoolItem]
    public let evicted: [TransactionPoolItem]
    public let expired: [TransactionPoolItem]
    public let removed: [TransactionPoolItem]
    public let reclassified: [TransactionPoolItem]

    fileprivate var allRemoved: [TransactionPoolItem] {
        replaced + evicted + expired + removed
    }
}

public actor TransactionPool {
    // Bound parse work by wire capacity, not an invented cap — the signature's
    // crypto verification is the authoritative check.
    private static let maximumSignatureFieldBytes = _wireAtomCapacity

    private struct Entry: Sendable {
        let cid: String
        let transaction: Transaction
        let size: Int
        let conflictKey: ConflictKey
        let minerFee: WorkSum
        var disposition: TransactionPoolDisposition
        let addedAt: Date
    }

    private struct ConflictKey: Hashable, Sendable {
        let signers: [String]
        let nonce: UInt64
    }

    private struct SignerNonce: Hashable, Sendable {
        let signer: String
        let nonce: UInt64
    }

    /// A max-fee binary heap over pool entries (CID ascending breaks ties), used
    /// to select the highest-paying emittable transaction during fee-priority
    /// template ordering.
    private struct FeeFrontier {
        private var items: [Entry] = []

        private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
            if lhs.minerFee != rhs.minerFee { return lhs.minerFee > rhs.minerFee }
            return lhs.cid < rhs.cid
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
                let left = 2 * parent + 1
                let right = 2 * parent + 2
                var best = parent
                if left < items.count, precedes(items[left], items[best]) {
                    best = left
                }
                if right < items.count, precedes(items[right], items[best]) {
                    best = right
                }
                guard best != parent else { break }
                items.swapAt(parent, best)
                parent = best
            }
            return top
        }
    }

    private let maxCount: Int
    private let maxBytes: Int
    private let maxSignatures: Int
    private let maxNonReadyPerSigner: Int
    private var entries: [String: Entry] = [:]
    private var signerNonces: [SignerNonce: String] = [:]
    private var totalBytes = 0

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        maxNonReadyPerSigner: Int = 64
    ) {
        precondition(
            maxCount > 0 && maxBytes > 0 && maxSignatures > 0
                && maxNonReadyPerSigner > 0
        )
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.maxNonReadyPerSigner = maxNonReadyPerSigner
    }

    @discardableResult
    public func submit(
        _ transaction: Transaction,
        spec: ChainSpec,
        fetcher: any Fetcher,
        disposition: TransactionPoolDisposition = .ready,
        addedAt: Date = Date()
    ) async throws -> TransactionPoolMutation {
        guard disposition != .invalid else {
            throw TransactionPoolError.invalidState
        }
        guard transaction.signatures.count <= maxSignatures,
              transaction.signatures.allSatisfy({ key, signature in
                  key.utf8.count <= Self.maximumSignatureFieldBytes
                      && signature.utf8.count <= Self.maximumSignatureFieldBytes
              }) else {
            throw TransactionPoolError.tooLarge
        }
        if let body = transaction.body.node {
            guard let bodyData = body.toData(),
                  bodyData.count <= spec.maxBlockSize else {
                throw TransactionPoolError.tooLarge
            }
        } else {
            let bodyData = try await fetcher.fetch(rawCid: transaction.body.rawCID)
            guard bodyData.count <= spec.maxBlockSize else {
                throw TransactionPoolError.tooLarge
            }
        }
        guard let envelopeData = transaction.toData(),
              envelopeData.count <= spec.maxBlockSize else {
            throw TransactionPoolError.tooLarge
        }
        let bodyHeader = try await transaction.body.resolve(fetcher: fetcher)
        guard let body = bodyHeader.node else { throw TransactionPoolError.unresolved }
        let resolved = Transaction(signatures: transaction.signatures, body: bodyHeader)
        // Lattice preflight owns state and consensus validity. The pool only
        // enforces bounded local-resource policy and indexes replacement keys.
        guard body.signers.count <= maxSignatures else {
            throw TransactionPoolError.tooLarge
        }

        guard let bodyData = body.toData() else {
            throw TransactionPoolError.unresolved
        }
        let (storedSize, sizeOverflow) = envelopeData.count.addingReportingOverflow(
            bodyData.count
        )
        guard !sizeOverflow, storedSize <= spec.maxBlockSize else {
            throw TransactionPoolError.tooLarge
        }
        let header = try VolumeImpl<Transaction>(node: resolved)
        let cid = header.rawCID
        if entries[cid] != nil {
            return TransactionPoolMutation(
                transactionCID: cid,
                inserted: nil,
                replaced: [],
                evicted: [],
                expired: [],
                removed: [],
                reclassified: []
            )
        }
        guard storedSize <= maxBytes else {
            throw TransactionPoolError.tooLarge
        }
        let conflictKey = ConflictKey(
            signers: Array(Set(body.signers)).sorted(),
            nonce: body.nonce
        )
        let entry = Entry(
            cid: cid,
            transaction: resolved,
            size: storedSize,
            conflictKey: conflictKey,
            minerFee: Self.minerFee(of: body),
            disposition: disposition,
            addedAt: addedAt
        )

        // Replace-by-fee on an exact (signers, nonce) match: a signer may replace
        // their OWN pending transaction at that nonce only by strictly paying more
        // to the miner (`minerFee` — the real debit-over-credit excess, not the
        // free-form `body.fee` consensus ignores). Because that excess is funds the
        // signer actually gives up, the bid cannot be raised for free; last-writer-
        // wins would let a signer cancel or downgrade for free and churn relay/
        // eviction. Only the signer can sign for that nonce, so this is self-
        // replacement, not a front-run. A partial signer overlap at the same nonce
        // is an unresolvable conflict.
        let overlappingCIDs = Set(conflictKey.signers.compactMap {
            signerNonces[SignerNonce(signer: $0, nonce: conflictKey.nonce)]
        })
        let replacedCID: String?
        if overlappingCIDs.isEmpty {
            replacedCID = nil
        } else if overlappingCIDs.count == 1,
                  let overlap = overlappingCIDs.first,
                  let existing = entries[overlap],
                  existing.conflictKey == conflictKey {
            // Compare the real excess regardless of disposition: a signer may
            // legitimately replace their OWN not-yet-executable claim (e.g. a
            // withdrawal queued before its parent receipt commits) with a
            // higher-value one. A non-ready entry's declared excess is not yet
            // funding-checked, so this permits monotonic self-churn on that one
            // slot — but bounded (`maxNonReadyPerSigner`), never mineable, and no
            // worse than the recency rule this replaced.
            guard entry.minerFee > existing.minerFee else {
                throw TransactionPoolError.feeTooLow
            }
            replacedCID = overlap
        } else {
            throw TransactionPoolError.conflictingNonce
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
                queuedBySigner[$0, default: 0] < maxNonReadyPerSigner
            }) else {
                throw TransactionPoolError.full
            }
        }

        var prospectiveCount = entries.count - (replacedCID == nil ? 0 : 1)
        var prospectiveBytes = totalBytes
            - (replacedCID.flatMap { entries[$0]?.size } ?? 0)
        var evictions: [String] = []
        let candidates = entries.values
            .filter { $0.cid != replacedCID }
            .sorted { retentionComparison($0, $1) < 0 }
        for candidate in candidates
        where prospectiveCount >= maxCount
            || storedSize > maxBytes - prospectiveBytes {
            guard retentionComparison(entry, candidate) > 0 else {
                throw TransactionPoolError.full
            }
            evictions.append(candidate.cid)
            prospectiveCount -= 1
            prospectiveBytes -= candidate.size
        }
        guard prospectiveCount < maxCount,
              storedSize <= maxBytes - prospectiveBytes else {
            throw TransactionPoolError.full
        }

        let replaced = replacedCID.flatMap { entries[$0].map(item) }
        let evicted = evictions.compactMap { entries[$0].map(item) }
        if let replacedCID { _ = remove(replacedCID) }
        for cid in evictions { _ = remove(cid) }
        insert(entry)
        return TransactionPoolMutation(
            transactionCID: cid,
            inserted: item(entry),
            replaced: replaced.map { [$0] } ?? [],
            evicted: evicted,
            expired: [],
            removed: [],
            reclassified: []
        )
    }

    public func transactions(limit: Int) -> [Transaction] {
        orderedTransactions(
            limit: limit,
            includesUnavailable: false,
            includesFuture: true
        )
    }

    /// Candidate parent state can make a child withdrawal executable. Future
    /// nonces stay excluded; unavailable entries get authoritative contextual
    /// preflight before template selection.
    public func contextualTransactions(
        limit: Int
    ) -> [Transaction] {
        orderedTransactions(
            limit: limit,
            includesUnavailable: true,
            includesFuture: true
        )
    }

    private func orderedTransactions(
        limit: Int,
        includesUnavailable: Bool,
        includesFuture: Bool
    ) -> [Transaction] {
        let maximum = max(0, limit)
        guard maximum > 0 else { return [] }
        // Fee-priority selection. The block's fees accrue to whoever mines it, so
        // the template fills with the most valuable transactions first. But the
        // greedy assembler applies candidates in order and permanently drops any
        // that fail the state transform at their position, so a signer's nonce N
        // must precede its nonce N+1, and a multi-signer transaction must follow
        // every signer's lower-nonce transaction. We honor those dependencies with
        // a topological (Kahn) emission: an entry is emittable once every signer's
        // lower-nonce entry has been emitted, and among emittable entries the
        // highest fee wins (CID breaks ties, keeping the order deterministic).
        // Future entries stay eligible so a burst still packs in one block.
        let eligible = entries.values.filter {
            $0.disposition == .ready
                || (includesFuture && $0.disposition == .future)
                || (includesUnavailable && $0.disposition == .unavailable)
        }
        guard !eligible.isEmpty else { return [] }
        // Each signer's entries, ascending by nonce; a multi-signer entry appears
        // in every one of its signers' chains. An entry depends on the entry
        // before it in each chain it belongs to.
        let ordinal = eligible.sorted {
            if $0.conflictKey.nonce != $1.conflictKey.nonce {
                return $0.conflictKey.nonce < $1.conflictKey.nonce
            }
            return $0.cid < $1.cid
        }
        var chains: [String: [Entry]] = [:]
        var positions: [String: [String: Int]] = [:]
        for entry in ordinal {
            for signer in entry.conflictKey.signers {
                let index = chains[signer]?.count ?? 0
                chains[signer, default: []].append(entry)
                positions[entry.cid, default: [:]][signer] = index
            }
        }
        // indegree = how many of an entry's signers still have an un-emitted
        // lower-nonce predecessor (initially: signers where it is not the head).
        var indegree: [String: Int] = [:]
        for entry in ordinal {
            indegree[entry.cid] = (positions[entry.cid] ?? [:])
                .reduce(0) { $0 + ($1.value > 0 ? 1 : 0) }
        }
        var frontier = FeeFrontier()
        for entry in ordinal where indegree[entry.cid] == 0 {
            frontier.push(entry)
        }
        var ordered: [Transaction] = []
        ordered.reserveCapacity(min(ordinal.count, maximum))
        while ordered.count < maximum, let pick = frontier.pop() {
            ordered.append(pick.transaction)
            for signer in pick.conflictKey.signers {
                guard let chain = chains[signer],
                      let index = positions[pick.cid]?[signer],
                      index + 1 < chain.count else { continue }
                let successor = chain[index + 1]
                indegree[successor.cid]? -= 1
                if indegree[successor.cid] == 0 { frontier.push(successor) }
            }
        }
        return ordered
    }

    /// The real miner-claimable value of a transaction: the excess that block
    /// validation lets the coinbase mint — funds it destroys (account debits plus
    /// withdrawals) minus funds it creates (account credits plus deposits). This
    /// mirrors `validateBalanceChanges` per transaction, excluding the block
    /// reward. Unlike `body.fee` — a declared field consensus never reads — this
    /// cannot be inflated without actually giving up funds, so it is a
    /// forge-resistant key for eviction and template ranking. A net-negative
    /// (reward-subsidized) transaction ranks as zero.
    private static func minerFee(of body: TransactionBody) -> WorkSum {
        var claimable = WorkSum.zero
        var owed = WorkSum.zero
        for action in body.accountActions where action.verify() {
            if action.isDebit {
                claimable = claimable + UInt256(action.absoluteAmount)
            } else if action.isCredit {
                owed = owed + UInt256(action.absoluteAmount)
            }
        }
        for withdrawal in body.withdrawalActions {
            claimable = claimable + UInt256(withdrawal.amountWithdrawn)
        }
        for deposit in body.depositActions {
            owed = owed + UInt256(deposit.amountDeposited)
        }
        return claimable.subtracting(owed) ?? .zero
    }

    /// Eviction priority when the pool is full: keep ready over non-ready, then
    /// keep the HIGHER `minerFee` (the block's revenue, so the pool retains what a
    /// miner would prefer and sheds free/low-value spam first); among equal fee
    /// keep the OLDEST (first-come-first-served, closest to being mined), evicting
    /// newest arrivals first; CID breaks exact ties. A positive result keeps `lhs`
    /// over `rhs`.
    private func retentionComparison(_ lhs: Entry, _ rhs: Entry) -> Int {
        let lhsReady = lhs.disposition == .ready
        let rhsReady = rhs.disposition == .ready
        if lhsReady != rhsReady { return lhsReady ? 1 : -1 }
        // Only a validated (.ready) excess is trustworthy: a future/unavailable
        // entry's declared debits are not yet funding-checked, so its `minerFee`
        // could be forged. Rank on fee only when both are ready; otherwise fall
        // back to first-come-first-served so forged non-ready fees cannot
        // preferentially evict honest non-ready entries.
        if lhsReady, lhs.minerFee != rhs.minerFee {
            return lhs.minerFee > rhs.minerFee ? 1 : -1
        }
        if lhs.addedAt != rhs.addedAt {
            return lhs.addedAt < rhs.addedAt ? 1 : -1
        }
        if lhs.cid != rhs.cid { return lhs.cid < rhs.cid ? 1 : -1 }
        return 0
    }

    public func snapshot() -> [TransactionPoolItem] {
        entries.values.sorted { $0.cid < $1.cid }.map(item)
    }

    /// Reclassifies the pool against a canonical tip. The classifier is supplied
    /// by the Lattice-owning layer so the pool never copies consensus rules.
    @discardableResult
    public func revalidate(
        _ classify: @Sendable (Transaction) async throws
            -> TransactionPoolDisposition
    ) async rethrows -> TransactionPoolMutation {
        let snapshot = entries.values.sorted { $0.cid < $1.cid }
        var dispositions: [String: TransactionPoolDisposition] = [:]
        for entry in snapshot {
            dispositions[entry.cid] = try await classify(entry.transaction)
        }

        var removed: [TransactionPoolItem] = []
        var reclassified: [TransactionPoolItem] = []
        for (cid, disposition) in dispositions {
            guard entries[cid] != nil else { continue }
            if disposition == .invalid {
                if let entry = remove(cid) { removed.append(item(entry)) }
            } else {
                if entries[cid]!.disposition != disposition {
                    reclassified.append(item(entries[cid]!))
                }
                entries[cid]!.disposition = disposition
            }
        }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed.sorted { $0.cid < $1.cid },
            reclassified: reclassified.sorted { $0.cid < $1.cid }
        )
    }

    @discardableResult
    public func remove(_ cids: some Sequence<String>) -> TransactionPoolMutation {
        let removed = cids.compactMap { remove($0).map(item) }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed,
            reclassified: []
        )
    }

    @discardableResult
    public func clear() -> TransactionPoolMutation {
        let removed = entries.values.map(item)
        entries.removeAll()
        signerNonces.removeAll()
        totalBytes = 0
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: [],
            removed: removed,
            reclassified: []
        )
    }

    public func rollback(_ mutation: TransactionPoolMutation) {
        if let inserted = mutation.inserted { _ = remove(inserted.cid) }
        for removed in mutation.allRemoved {
            guard let body = removed.transaction.body.node,
                  let envelope = removed.transaction.toData(),
                  let bodyData = body.toData() else {
                preconditionFailure("pooled transaction lost resolved content")
            }
            insert(Entry(
                cid: removed.cid,
                transaction: removed.transaction,
                size: envelope.count + bodyData.count,
                conflictKey: ConflictKey(
                    signers: Array(Set(body.signers)).sorted(),
                    nonce: body.nonce
                ),
                minerFee: Self.minerFee(of: body),
                disposition: removed.disposition,
                addedAt: removed.addedAt
            ))
        }
        for previous in mutation.reclassified where entries[previous.cid] != nil {
            entries[previous.cid]!.disposition = previous.disposition
        }
    }

    public var count: Int {
        entries.count
    }

    public var byteCount: Int {
        return totalBytes
    }

    private func item(_ entry: Entry) -> TransactionPoolItem {
        TransactionPoolItem(
            cid: entry.cid,
            transaction: entry.transaction,
            disposition: entry.disposition,
            addedAt: entry.addedAt
        )
    }

    private func insert(_ entry: Entry) {
        precondition(entries[entry.cid] == nil)
        entries[entry.cid] = entry
        for signer in entry.conflictKey.signers {
            signerNonces[SignerNonce(
                signer: signer,
                nonce: entry.conflictKey.nonce
            )] = entry.cid
        }
        totalBytes += entry.size
    }

    @discardableResult
    private func remove(_ cid: String) -> Entry? {
        guard let removed = entries.removeValue(forKey: cid) else { return nil }
        for signer in removed.conflictKey.signers {
            let key = SignerNonce(signer: signer, nonce: removed.conflictKey.nonce)
            if signerNonces[key] == cid { signerNonces.removeValue(forKey: key) }
        }
        totalBytes -= removed.size
        return removed
    }
}

