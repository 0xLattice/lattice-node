import Foundation
import Lattice
import cashew

/// A child level's view of its co-hosted parent level: the parent facts a
/// child block's admission needs, read from the parent's own validated
/// state in this process.
///
/// Every method is a GATE-FREE read: it must not take the parent's
/// `ChainProcess` operation gate or its `ChainService` lease. A child reads
/// its parent while it holds its own lease (its candidate rebuild), so a
/// read that waited on either could close a cycle with a parent that holds
/// its lease. `LocalParentLevel` calls only the gate-free reads a SafetyNet
/// gate allows.
public protocol ParentLevel: AnyObject, Sendable {
    /// Whether the parent executed a block producing this state, from its
    /// genesis: the executed-from-genesis frontier, never a state it only
    /// weighed.
    func hasProducedState(_ stateCID: String) async -> Bool
    /// The parent's tree, which serves the child's directory, for the child
    /// to derive its attributed runs from (§9.10). Nil before the parent is
    /// active.
    func runTree() async -> ChainTree?
    /// The parent's validated tip and its CID: what a child's candidate
    /// binds (its provisional carrier's `prevState` is the tip's post-state).
    /// Nil before the parent's genesis activates.
    func validatedTip() async -> (cid: String, block: Block)?
    /// The parent's local content, for a candidate build against its
    /// provisional carrier: broker-local reads only, never the network.
    var contentSource: any ContentSource { get }
}

/// A parent level's view of a co-hosted child level. Notifications enqueue,
/// and `readyCandidate` reads the snapshot the child last published
/// (`ChainService.buildReadyCandidate`), built under the child's own lease
/// against the parent's validated tip. The parent's template path never
/// awaits a child (§2.4). The one awaited member, `admitMined`, is called
/// only by the parent's mined handoff with the parent's lease released: a
/// downward await never holds a parent lock.
public protocol ChildLevel: AnyObject, Sendable {
    var directory: String { get }
    /// Enqueues `change` for the child and returns.
    func parentChanged(_ change: ParentChange)
    /// The child's pre-built candidate, or nil when it has none: its
    /// execution walk is stepping or behind, or it has not built yet. The
    /// caller checks its binding.
    var readyCandidate: ReadyCandidate? { get }
    /// This host mined a grind carrying the child's `block` (the node from
    /// the mined block, in memory) under `proof`: the child admits it through
    /// its normal candidate path (and hands its own hosted children theirs)
    /// and reports whether it admitted.
    func admitMined(block: Block, proof: ChildBlockProof) async -> Bool
}

/// A hosted child's pre-built merged-mining candidate, the parent state it
/// binds (its provisional carrier's `prevState`, the parent's validated tip's
/// post-state when it was built), and the plan it was built on (the child's
/// part of the miner's plan, which pays that miner).
public struct ReadyCandidate: Sendable {
    public let candidate: DirectChildCandidate
    public let cid: String
    public let parentStateCID: String
    public let plan: DescendantPlan

    public init?(_ candidate: DirectChildCandidate, plan: DescendantPlan) {
        guard let cid = try? BlockHeader(node: candidate.block).rawCID else {
            return nil
        }
        self.candidate = candidate
        self.cid = cid
        parentStateCID = candidate.block.parentState.rawCID
        self.plan = plan
    }
}

/// The miner's plan for a level's subtree (recipients and minimum work), from
/// the last template request: what a hosted child builds its candidate
/// against. A parent sends each child its subtree's part when it changes,
/// and carries a child's snapshot only when it was built on that part.
public struct DescendantPlan: Sendable {
    public let recipients: [MiningRecipient]
    public let minimumWork: [MiningMinimumWork]

    public init(recipients: [MiningRecipient] = [], minimumWork: [MiningMinimumWork] = []) {
        self.recipients = recipients
        self.minimumWork = minimumWork
    }

    /// The part of this plan for chains at or below `subtree`.
    func narrowed(to subtree: [String]) -> DescendantPlan {
        func inSubtree(_ chainPath: [String]) -> Bool {
            chainPath.count >= subtree.count
                && Array(chainPath.prefix(subtree.count)) == subtree
        }
        return DescendantPlan(
            recipients: recipients.filter { inSubtree($0.chainPath) },
            minimumWork: minimumWork.filter { inSubtree($0.chainPath) }
        )
    }

    func same(as other: DescendantPlan) -> Bool {
        recipients == other.recipients && minimumWork == other.minimumWork
    }
}

/// What the parent level tells a hosted child (`ChainService.ParentMailbox`):
/// run, tip and plan changes, coalesced. Delivery never blocks the parent.
public enum ParentChange: Sendable {
    /// The parent's validated tip or executed frontier moved: a parent fact
    /// a child block waited on may hold now.
    case tipChanged
    /// The parent's weight moved, so a run into the child's directory may
    /// have (§9.10): the child derives its attributed runs again.
    case runs
    /// The miner's plan for the child's subtree changed: the child rebuilds
    /// its candidate against it.
    case plan(DescendantPlan)
}

/// A parent fact a child admission can read from its co-hosted parent
/// level: the key a `.wait(.parentFact)` park waits on.
enum ParentFact: Hashable, Sendable {
    /// The parent executed a block producing `toStateCID`, from genesis.
    case continuity(toStateCID: String)

    /// The fact `requirement` names, or nil when the requirement is not a
    /// fact `child`'s immediate parent level can answer.
    init?(_ requirement: CrossChainEvidenceRequirement, child: ChainAddress) {
        let parentPath = Array(child.components.dropLast())
        switch requirement {
        case .parentStateContinuity(let requiredPath, let fromStateCID, let toStateCID)
            where requiredPath == parentPath
            // Every child block anchors its `parentState` at the parent
            // chain's genesis, so the only continuity Lattice asks for runs
            // from the empty state: the executed-from-genesis frontier
            // answers it without walking the chain.
            && fromStateCID == LatticeState.emptyHeader.rawCID
            && fromStateCID != toStateCID:
            self = .continuity(toStateCID: toStateCID)
        default:
            return nil
        }
    }
}

extension ParentLevel {
    /// Whether the parent holds `fact` now: the one cheap local read a
    /// parked candidate's wake is gated on.
    func holds(_ fact: ParentFact) async -> Bool {
        switch fact {
        case .continuity(let toStateCID):
            await hasProducedState(toStateCID)
        }
    }

    /// `package` merged with the parent fact `requirement` names, when the
    /// parent holds it. Nil when it does not (yet), or when the requirement
    /// is not a fact of `child`'s immediate parent.
    func evidence(
        for requirement: CrossChainEvidenceRequirement,
        child: ChainAddress,
        package: AuthenticatedChildPackage
    ) async -> AuthenticatedChildPackage? {
        guard let parentFact = ParentFact(requirement, child: child) else {
            return nil
        }
        let fact: ChildValidationPackage
        switch parentFact {
        case .continuity(let toStateCID):
            guard await hasProducedState(toStateCID) else { return nil }
            fact = ChildValidationPackage(
                proof: package.package.proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: Array(child.components.dropLast()),
                    fromStateCID: LatticeState.emptyHeader.rawCID,
                    toStateCID: toStateCID
                )
            )
        }
        return BlockFetcher.mergePackages(
            package, AuthenticatedChildPackage(package: fact)
        )
    }
}

/// `ParentLevel` over the co-hosted parent's process. Weak: the host owns
/// the parent level, and a stopped parent answers nothing.
final class LocalParentLevel: @unchecked Sendable, ParentLevel, ContentSource {
    private weak var process: ChainProcess?

    init(_ process: ChainProcess) {
        self.process = process
    }

    func hasProducedState(_ stateCID: String) async -> Bool {
        await process?.hasProducedParentState(stateCID) ?? false
    }

    func runTree() async -> ChainTree? {
        await process?.runTree()
    }

    func validatedTip() async -> (cid: String, block: Block)? {
        await process?.ungatedValidatedTip()
    }

    var contentSource: any ContentSource { self }

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        await process?.fetch(cids) ?? [:]
    }
}

/// `ChildLevel` over the co-hosted child's service. Weak: the host owns the
/// child level, and a stopped child is not carried.
final class LocalChildLevel: @unchecked Sendable, ChildLevel {
    let directory: String
    private let mailbox: ChainService.ParentMailbox
    private weak var service: ChainService?

    init(
        directory: String,
        mailbox: ChainService.ParentMailbox,
        service: ChainService
    ) {
        self.directory = directory
        self.mailbox = mailbox
        self.service = service
    }

    func parentChanged(_ change: ParentChange) {
        mailbox.send(change)
    }

    var readyCandidate: ReadyCandidate? {
        service?.readyCandidate()
    }

    func admitMined(block: Block, proof: ChildBlockProof) async -> Bool {
        await service?.admitMinedCarriage(block: block, proof: proof) ?? false
    }
}
