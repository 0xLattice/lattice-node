import Crypto
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

/// The committed target of the block a candidate schedules its search on,
/// and that block's directory path below the candidate (empty when it is the
/// candidate itself).
func schedulingTargets(
    for candidate: DirectChildCandidate
) async -> (target: UInt256, path: [String])? {
    if let witness = candidate.searchWitness {
        guard let targets = await witness.proof.schedulingTargets(
            root: candidate.block,
            terminal: witness.terminal
        ) else { return nil }
        return (targets.searchTarget, witness.proof.directoryPath)
    }
    return (candidate.block.target, [])
}

/// The most work any valid target can represent. Target 0 is met by no hash
/// and Lattice rejects it (`validateProofOfWork`), so target 1 is the hardest
/// and `workForTarget(1)` — 2^255 — is the ceiling. Work above it is refused
/// where it enters, never clamped: a clamped target would ask for less work
/// than the miner requested, and near the ceiling it would freeze the chain.
public let maximumRepresentableWork = workForTarget(UInt256(1))

/// The easiest target whose work (`workForTarget`, spec §9.1:
/// `floor(2^256 / (target + 1))`) is at least `work`, i.e.
/// `floor(2^256 / work) - 1`. Callers bound `work` by
/// `maximumRepresentableWork` first.
public func minimumWorkTarget(_ work: UInt256) -> UInt256 {
    precondition(work > .zero && work <= maximumRepresentableWork)
    let quotient = UInt256.max / work
    // floor(2^256 / work) exceeds floor((2^256 - 1) / work) by one exactly
    // when work divides 2^256. Within the ceiling a non-exact quotient is at
    // least 2, so the target below it is always a valid (positive) target.
    let exact = UInt256.max % work == work - UInt256(1)
    return exact ? quotient : quotient - UInt256(1)
}

/// What a miner searches one chain's block for: the block's committed target,
/// or the miner's minimum-work target where that is harder. The threshold is
/// `binding` when it is the harder one — a hash between the two still makes a
/// valid block, one the miner declined to produce.
struct SearchThreshold {
    let target: UInt256
    let binding: Bool

    init(committed: UInt256, minimumWork: UInt256?) {
        if let work = minimumWork, minimumWorkTarget(work) < committed {
            target = minimumWorkTarget(work)
            binding = true
        } else {
            target = committed
            binding = false
        }
    }
}

public struct MiningTemplate: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    public let chainPath: [String]
    public let expiresAt: ContinuousClock.Instant
    let childCandidates: [DirectChildCandidate]
    let searchWitness: ChildSchedulingWitness?
    /// The search threshold of this block and of each direct child's block —
    /// never their committed targets. Where a minimum work binds, the
    /// committed target is easier, and advertising it would hand the miner
    /// back exactly the hits it declined.
    let thresholds: [UInt256]

    /// Every distinct threshold a nonce for this work can clear, easiest
    /// first, so the first is `searchTarget`. A carrier leaves the work open
    /// and the miner keeps searching toward the rest, skipping hits between
    /// them, so the list must be complete. It is only when every direct child
    /// is a leaf: a child carrying children of its own can clear descendant
    /// thresholds this node never sees, so such work advertises `searchTarget`
    /// alone and the miner stops at its first hit.
    var targets: [UInt256] {
        guard let emptyChildren = Self.emptyChildrenCID,
              childCandidates.allSatisfy({
                  $0.block.children.rawCID == emptyChildren
              }) else {
            return [searchTarget]
        }
        return Set(thresholds + [searchTarget])
            .filter { $0 <= searchTarget }
            .sorted(by: >)
    }

    private static let emptyChildrenCID = try? HeaderImpl<
        MerkleDictionaryImpl<VolumeImpl<Block>>
    >(node: MerkleDictionaryImpl<VolumeImpl<Block>>()).rawCID

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
        minimumWork: [[String]: UInt256] = [:],
        commitMinimumWorkTarget: Bool = false,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        let template = try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            minimumWork: minimumWork,
            commitMinimumWorkTarget: commitMinimumWorkTarget,
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
        minimumWork: [[String]: UInt256] = [:],
        commitMinimumWorkTarget: Bool = false,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        try await assemble(
            previous: previous,
            transactions: transactions,
            children: children,
            parentCarrier: parentCarrier,
            timestamp: timestamp,
            transactionLimit: transactionLimit,
            minimumWork: minimumWork,
            commitMinimumWorkTarget: commitMinimumWorkTarget,
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
        minimumWork: [[String]: UInt256],
        commitMinimumWorkTarget: Bool,
        fetcher: any Fetcher
    ) async throws -> MiningTemplate {
        precondition(transactionLimit >= 0)
        // The committed target is consensus data every descendant inherits
        // through the retarget, so by default the block commits the schedule
        // (nil: the builder takes `previous.nextTarget`) and a miner's minimum
        // work only narrows what it searches for. Committing the harder target
        // instead is an operator's explicit choice: validity permits it
        // (`target <= parent.nextTarget`), and Lattice derives `nextTarget`
        // from the target actually used.
        let target = commitMinimumWorkTarget
            ? minimumWork[chainPath].map {
                min(previous.nextTarget, minimumWorkTarget($0))
            }
            : nil
        var childBlocks: [String: Block] = [:]
        var childTargets: [String: (target: UInt256, path: [String])] = [:]
        for child in children {
            guard _isBoundedDirectoryAtom(child.directory) else {
                throw MiningTemplateError.invalidChildDirectory
            }
            guard childBlocks[child.directory] == nil else {
                throw MiningTemplateError.duplicateChildDirectory
            }
            guard let scheduled = await schedulingTargets(for: child) else {
                throw MiningCandidateValidationError.invalid
            }
            childBlocks[child.directory] = child.block
            childTargets[child.directory] = scheduled
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
            target: target,
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
                    target: target,
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
        let workID = Self.workID(
            blockCID: try BlockHeader(node: candidate).rawCID,
            minimumWork: minimumWork,
            commitMinimumWorkTarget: commitMinimumWorkTarget
        )
        let scheduling = try await Self.scheduling(
            root: candidate,
            children: children,
            targets: childTargets,
            chainPath: chainPath,
            minimumWork: minimumWork,
            fetcher: fetcher
        )
        let template = MiningTemplate(
            workID: workID,
            block: candidate,
            searchTarget: scheduling.searchTarget,
            chainPath: chainPath,
            expiresAt: ContinuousClock.now + lifetime,
            childCandidates: children,
            searchWitness: scheduling.searchWitness,
            thresholds: scheduling.thresholds
        )
        return template
    }

    /// Blocks no longer differ by the miner's filter, so the block CID alone
    /// would let two search policies share one cached work item, each judged
    /// against the other's search target. A request with a plan or the opt-in
    /// gets the CID plus a digest of both; one with neither keeps the CID.
    private nonisolated static func workID(
        blockCID: String,
        minimumWork: [[String]: UInt256],
        commitMinimumWorkTarget: Bool
    ) -> String {
        guard !minimumWork.isEmpty || commitMinimumWorkTarget else {
            return blockCID
        }
        let policy = minimumWork
            .map { ($0.key.joined(separator: "/"), $0.value.toHexString()) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\n")
            + "\ncommit=\(commitMinimumWorkTarget)"
        let digest = SHA256.hash(data: Data(policy.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(blockCID)-\(digest)"
    }

    /// The easiest threshold in the template, bounded by its hardest binding
    /// one. A nonce commits every chain in the template at once, so a hash
    /// that clears one chain's threshold can land between another chain's
    /// binding threshold and its easier committed target — a valid block the
    /// miner declined. Stopping the search at the hardest binding threshold
    /// means any hash that meets `searchTarget` clears every binding threshold
    /// here. A child candidate carries its own subtree's bound the same way:
    /// its witness names the block that sets its search target, which this
    /// level re-derives from the proof and the miner's minimum work.
    private nonisolated static func scheduling(
        root: Block,
        children: [DirectChildCandidate],
        targets: [String: (target: UInt256, path: [String])],
        chainPath: [String],
        minimumWork: [[String]: UInt256],
        fetcher: any Fetcher
    ) async throws -> (
        searchTarget: UInt256,
        searchWitness: ChildSchedulingWitness?,
        thresholds: [UInt256]
    ) {
        let rootHeader = try BlockHeader(node: root)
        let rootThreshold = SearchThreshold(
            committed: root.target,
            minimumWork: minimumWork[chainPath]
        )
        var thresholds = [rootThreshold.target]
        var easiest = rootThreshold.target
        var easiestWitness: ChildSchedulingWitness?
        var bound = rootThreshold.binding ? rootThreshold.target : nil
        var boundWitness: ChildSchedulingWitness?
        var unresolvedCap: UInt256?
        func bind(
            _ threshold: SearchThreshold,
            _ witness: ChildSchedulingWitness
        ) {
            guard threshold.binding,
                  bound.map({ threshold.target < $0 }) ?? true else { return }
            bound = threshold.target
            boundWitness = witness
        }

        for child in children.sorted(by: { $0.directory < $1.directory }) {
            guard let scheduled = targets[child.directory] else {
                throw MiningCandidateValidationError.invalid
            }
            let direct = try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: child.directory,
                fetcher: fetcher
            )
            let childPath = chainPath + [child.directory]
            let own = SearchThreshold(
                committed: child.block.target,
                minimumWork: minimumWork[childPath]
            )
            let ownWitness = ChildSchedulingWitness(
                proof: direct,
                terminal: child.block
            )
            thresholds.append(own.target)
            bind(own, ownWitness)
            var childThreshold = own
            var childWitness = ownWitness
            if let descendant = child.searchWitness {
                childThreshold = SearchThreshold(
                    committed: scheduled.target,
                    minimumWork: minimumWork[childPath + scheduled.path]
                )
                childWitness = ChildSchedulingWitness(
                    proof: direct.composing(hop: descendant.proof),
                    terminal: descendant.terminal
                )
                bind(childThreshold, childWitness)
            }
            if childThreshold.target > easiest {
                easiest = childThreshold.target
                easiestWitness = childWitness
            }
            // A witness is a valid proof, not a promise that it names the
            // chain setting the child's bound: a child node that predates or
            // ignores the plan names another block, or none. Every filter
            // below this child that its witness does not resolve caps the
            // search outright — over-strict when that chain's committed target
            // is already harder than its filter or the chain is absent, but
            // never hiding a declined block.
            for (path, work) in minimumWork
            where path.count > childPath.count
                && Array(path.prefix(childPath.count)) == childPath
                && path != childPath + scheduled.path {
                let cap = minimumWorkTarget(work)
                unresolvedCap = min(unresolvedCap ?? cap, cap)
            }
        }
        let searchTarget = [bound, unresolvedCap]
            .compactMap { $0 }
            .reduce(easiest, min)
        // Any binding bound names its witness, even when it ties the easiest
        // threshold: the level above re-derives the bound only from a witness
        // naming the binding block.
        return (searchTarget, bound == nil ? easiestWitness : boundWitness, thresholds)
    }

    private nonisolated static func makeCandidate(
        previous: Block,
        transactions: [Transaction],
        children: [String: Block],
        parentCarrier: Block?,
        timestamp: Int64,
        target: UInt256?,
        chainPath: [String],
        fetcher: any Fetcher
    ) async throws -> Block {
        let candidate = try await BlockBuilder.buildBlock(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentCarrier,
            timestamp: timestamp,
            target: target,
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
