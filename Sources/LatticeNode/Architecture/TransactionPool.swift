import Foundation
import Lattice
import cashew

public enum TransactionPoolError: Error, Equatable {
    case unresolved
    case tooLarge
    case full
    case invalidState
    case conflictingNonce
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

    private let maxCount: Int
    private let maxBytes: Int
    private let maxSignatures: Int
    private let maxNonReadyPerSigner: Int
    private let entryLifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var signerNonces: [SignerNonce: String] = [:]
    private var totalBytes = 0

    public init(
        maxCount: Int = 10_000,
        maxBytes: Int = 64 * 1024 * 1024,
        maxSignatures: Int = 64,
        maxNonReadyPerSigner: Int = 64,
        entryLifetime: TimeInterval = 3 * 60 * 60
    ) {
        precondition(
            maxCount > 0 && maxBytes > 0 && maxSignatures > 0
                && maxNonReadyPerSigner > 0
                && entryLifetime > 0
        )
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.maxSignatures = maxSignatures
        self.maxNonReadyPerSigner = maxNonReadyPerSigner
        self.entryLifetime = entryLifetime
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
            disposition: disposition,
            addedAt: addedAt
        )

        // Last-writer-wins on an exact (signers, nonce) match: a signer may
        // replace their OWN pending transaction with a newer one — this supports
        // legitimate self-correction/finalization (only the signer can sign for
        // that nonce, so it is not a cross-user front-run). There is NO fee-bump
        // gate: external merged mining has no per-chain fee market to bid in, so
        // replacement is by recency, not fee. A partial signer overlap at the same
        // nonce is an unresolvable conflict.
        let overlappingCIDs = Set(conflictKey.signers.compactMap {
            signerNonces[SignerNonce(signer: $0, nonce: conflictKey.nonce)]
        })
        let replacedCID: String?
        if overlappingCIDs.isEmpty {
            replacedCID = nil
        } else if overlappingCIDs.count == 1,
                  let overlap = overlappingCIDs.first,
                  entries[overlap]?.conflictKey == conflictKey {
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
        // Serve candidates in ascending (nonce, CID) order and let the sequential
        // BlockBuilder own sequencing: it includes each signer's runnable nonce
        // prefix and skips gaps. No fee ordering — with external merged mining the
        // node is not a fee-maximizing miner, so ordering is deterministic, not
        // economic. Future entries stay eligible so a burst can still pack in one
        // block (the builder makes nonce N+1 runnable after including N).
        return entries.values
            .filter {
                $0.disposition == .ready
                    || (includesFuture && $0.disposition == .future)
                    || (includesUnavailable && $0.disposition == .unavailable)
            }
            .sorted {
                if $0.conflictKey.nonce != $1.conflictKey.nonce {
                    return $0.conflictKey.nonce < $1.conflictKey.nonce
                }
                return $0.cid < $1.cid
            }
            .prefix(maximum)
            .map(\.transaction)
    }

    /// Eviction priority when the pool is full: keep ready over non-ready, and
    /// among equal readiness keep the OLDEST (first-come-first-served, closest to
    /// being mined), evicting newest arrivals first; CID breaks exact ties. No fee
    /// tiebreak — spam is bounded by capacity, min-fee, and per-signer caps.
    private func retentionComparison(_ lhs: Entry, _ rhs: Entry) -> Int {
        let lhsReady = lhs.disposition == .ready
        let rhsReady = rhs.disposition == .ready
        if lhsReady != rhsReady { return lhsReady ? 1 : -1 }
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

    @discardableResult
    public func expire(at now: Date = Date()) -> TransactionPoolMutation {
        let cutoff = now.addingTimeInterval(-entryLifetime)
        let expired = entries.values
            .filter { $0.addedAt <= cutoff }
            .sorted { $0.cid < $1.cid }
            .compactMap { remove($0.cid).map(item) }
        return TransactionPoolMutation(
            transactionCID: nil,
            inserted: nil,
            replaced: [],
            evicted: [],
            expired: expired,
            removed: [],
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

