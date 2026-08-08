import Foundation
import Ivy
import Lattice
import UInt256
import cashew

private enum MiningCandidateValidationError: Error {
    case invalid
}

public struct DirectChildCandidate: Sendable {
    public let directory: String
    public let block: Block
    let searchWitness: ChildSchedulingWitness?
    let advertiserPeerKey: PeerKey?

    public init(
        directory: String,
        block: Block,
        searchWitness: ChildSchedulingWitness? = nil
    ) {
        self.directory = directory
        self.block = block
        self.searchWitness = searchWitness
        advertiserPeerKey = nil
    }

    init(
        directory: String,
        block: Block,
        searchWitness: ChildSchedulingWitness? = nil,
        advertiserPeerKey: PeerKey?
    ) {
        self.directory = directory
        self.block = block
        self.searchWitness = searchWitness
        self.advertiserPeerKey = advertiserPeerKey
    }
}

public struct ChildSchedulingWitness: Sendable {
    public let proof: ChildBlockProof
    public let terminal: Block

    public init(proof: ChildBlockProof, terminal: Block) {
        self.proof = proof
        self.terminal = terminal
    }
}

func schedulingTargets(
    for candidate: DirectChildCandidate
) async -> UInt256? {
    if let witness = candidate.searchWitness {
        guard let targets = await witness.proof.schedulingTargets(
            root: candidate.block,
            terminal: witness.terminal
        ) else { return nil }
        return targets.searchTarget
    }
    return candidate.block.target
}

public struct MiningTemplate: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let chainPath: [String]
    public let expiresAt: ContinuousClock.Instant
    let childCandidates: [DirectChildCandidate]
    let searchWitness: ChildSchedulingWitness?

    var remainingLifetimeMilliseconds: UInt64 {
        let components = ContinuousClock.now.duration(to: expiresAt).components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return 0
        }
        let seconds = UInt64(components.seconds)
        let milliseconds = UInt64(
            components.attoseconds / 1_000_000_000_000_000
        )
        let scaled = seconds.multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { return .max }
        let total = scaled.partialValue.addingReportingOverflow(milliseconds)
        return total.overflow ? .max : total.partialValue
    }
}

public enum MiningTemplateError: Error, Equatable {
    case invalidChildDirectory
    case duplicateChildDirectory
    case unknownWork
    case expired
    case missesSearchTarget
}

/// Bounded work cache for external miners. It never searches a nonce.
public actor MiningTemplateBook {
    private let chainPath: [String]
    private let lifetime: Duration
    private let capacity: Int
    private var templates: [String: MiningTemplate] = [:]
    private var order: [String] = []

    public init(
        chainPath: [String],
        lifetime: Duration = .seconds(30),
        capacity: Int = 16
    ) {
        precondition(capacity > 0 && lifetime > .zero)
        self.chainPath = chainPath
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public func build(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block? = nil,
        timestamp: Int64,
        transactionLimit: Int = .max,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        let template = try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            fetcher: fetcher
        )
        return issue(template)
    }

    func issue(_ template: MiningTemplate) -> MiningTemplate {
        issueTrackingInsertion(template).template
    }

    func issueTrackingInsertion(
        _ template: MiningTemplate
    ) -> (template: MiningTemplate, inserted: Bool) {
        precondition(template.chainPath == chainPath)
        if let existing = templates[template.workID],
           ContinuousClock.now < existing.expiresAt {
            order.removeAll { $0 == template.workID }
            order.append(template.workID)
            return (existing, false)
        }
        templates[template.workID] = template
        order.removeAll { $0 == template.workID }
        order.append(template.workID)
        while order.count > capacity {
            templates.removeValue(forKey: order.removeFirst())
        }
        return (template, true)
    }

    func discard(workID: String) {
        templates.removeValue(forKey: workID)
        order.removeAll { $0 == workID }
    }

    func activeChildCandidates() -> [DirectChildCandidate] {
        let now = ContinuousClock.now
        let expired = order.filter {
            templates[$0].map { now >= $0.expiresAt } ?? true
        }
        for workID in expired {
            templates.removeValue(forKey: workID)
        }
        if !expired.isEmpty {
            let expiredSet = Set(expired)
            order.removeAll { expiredSet.contains($0) }
        }
        return order.compactMap { templates[$0] }.flatMap(\.childCandidates)
    }

    /// Assembles candidate context without issuing miner work or consuming cache
    /// capacity. Used for contextual child requests before the final child set is
    /// known.
    func preview(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block? = nil,
        timestamp: Int64,
        transactionLimit: Int = .max,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            fetcher: fetcher
        )
    }

    private func assemble(
        previous: Block,
        transactions: [Transaction],
        children: [DirectChildCandidate],
        parentCarrier: Block?,
        timestamp: Int64,
        transactionLimit: Int,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        precondition(transactionLimit >= 0)
        var childBlocks: [String: Block] = [:]
        var childTargets: [String: UInt256] = [:]
        for child in children {
            guard _isBoundedDirectoryAtom(child.directory) else {
                throw MiningTemplateError.invalidChildDirectory
            }
            guard childBlocks[child.directory] == nil else {
                throw MiningTemplateError.duplicateChildDirectory
            }
            guard let searchTarget = await schedulingTargets(for: child) else {
                throw MiningCandidateValidationError.invalid
            }
            childBlocks[child.directory] = child.block
            childTargets[child.directory] = searchTarget
        }
        // A stale/conflicting pool entry must never suppress all external work.
        // Accept valid chunks greedily and bisect only the chunks that fail the
        // consensus state transform.
        var selected: [Transaction] = []
        var candidate = try await Self.makeCandidate(
            previous: previous,
            transactions: [],
            children: childBlocks,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            chainPath: chainPath,
            fetcher: fetcher
        )
        var chunks = transactions.isEmpty ? [] : [transactions[...]]
        while selected.count < transactionLimit, let chunk = chunks.popLast() {
            let remaining = transactionLimit - selected.count
            if chunk.count > remaining {
                let split = chunk.index(chunk.startIndex, offsetBy: remaining)
                chunks.append(chunk[split...])
                chunks.append(chunk[..<split])
                continue
            }
            do {
                candidate = try await Self.makeCandidate(
                    previous: previous,
                    transactions: selected + chunk,
                    children: childBlocks,
                    parentCarrier: parentCarrier,
                    timestamp: timestamp,
                    chainPath: chainPath,
                    fetcher: fetcher
                )
                selected.append(contentsOf: chunk)
            } catch let error
                where error is StateErrors
                    || error is ProofErrors
                    || error is MiningCandidateValidationError {
                guard chunk.count > 1 else { continue }
                let midpoint = chunk.index(
                    chunk.startIndex,
                    offsetBy: chunk.count / 2
                )
                chunks.append(chunk[midpoint...])
                chunks.append(chunk[..<midpoint])
            }
        }
        let workID = try BlockHeader(node: candidate).rawCID
        let scheduling = try await Self.scheduling(
            root: candidate,
            children: children,
            targets: childTargets,
            fetcher: fetcher
        )
        let template = MiningTemplate(
            workID: workID,
            block: candidate,
            searchTarget: scheduling.searchTarget,
            chainPath: chainPath,
            expiresAt: ContinuousClock.now + lifetime,
            childCandidates: children,
            searchWitness: scheduling.searchWitness
        )
        return template
    }

    private nonisolated static func scheduling(
        root: Block,
        children: [DirectChildCandidate],
        targets: [String: UInt256],
        fetcher: any Fetcher
    ) async throws -> (
        searchTarget: UInt256,
        searchWitness: ChildSchedulingWitness?
    ) {
        let rootHeader = try BlockHeader(node: root)
        var searchTarget = root.target
        var searchWitness: ChildSchedulingWitness?

        for child in children.sorted(by: { $0.directory < $1.directory }) {
            guard let childSearchTarget = targets[child.directory] else {
                throw MiningCandidateValidationError.invalid
            }
            let direct = try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: child.directory,
                fetcher: fetcher
            )
            if childSearchTarget > searchTarget {
                searchTarget = childSearchTarget
                if let descendant = child.searchWitness {
                    searchWitness = ChildSchedulingWitness(
                        proof: direct.composing(hop: descendant.proof),
                        terminal: descendant.terminal
                    )
                } else {
                    searchWitness = ChildSchedulingWitness(
                        proof: direct,
                        terminal: child.block
                    )
                }
            }
        }
        return (searchTarget, searchWitness)
    }

    private nonisolated static func makeCandidate(
        previous: Block,
        transactions: [Transaction],
        children: [String: Block],
        parentCarrier: Block?,
        timestamp: Int64,
        chainPath: [String],
        fetcher: any Fetcher
    ) async throws -> Block {
        let candidate = try await BlockBuilder.buildBlock(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentCarrier,
            timestamp: timestamp,
            nonce: 0,
            fetcher: fetcher
        )
        if transactions.contains(where: {
            $0.body.node?.withdrawalActions.isEmpty != true
        }) {
            let valid = try await candidate.validateWithdrawals(
                fetcher: fetcher,
                chainPath: chainPath
            )
            guard valid else { throw MiningCandidateValidationError.invalid }
        }
        return candidate
    }

    public func candidate(workID: String, nonce: UInt64) throws -> Block {
        try submission(workID: workID, nonce: nonce).block
    }

    func submission(
        workID: String,
        nonce: UInt64
    ) throws -> (block: Block, children: [DirectChildCandidate]) {
        guard let template = templates[workID] else {
            throw MiningTemplateError.unknownWork
        }
        guard ContinuousClock.now < template.expiresAt else {
            templates.removeValue(forKey: workID)
            order.removeAll { $0 == workID }
            throw MiningTemplateError.expired
        }
        let candidate = template.block.replacingNonce(nonce)
        let rootHash = candidate.proofOfWorkHash()
        guard rootHash <= template.searchTarget else {
            throw MiningTemplateError.missesSearchTarget
        }
        return (candidate, template.childCandidates)
    }

    public func invalidateAll() {
        templates.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

private extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}
