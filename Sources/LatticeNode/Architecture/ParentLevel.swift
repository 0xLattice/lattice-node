import Foundation
import Lattice

/// A child level's view of its co-hosted parent level: the parent facts a
/// child block's admission needs, read from the parent's own validated
/// state in this process.
///
/// Every method is a GATE-FREE read: it must not take the parent's
/// `ChainProcess` operation gate or its `ChainService` lease. The parent
/// awaits its children while it holds its own lease, so a child read that
/// waited on either could close a cycle. `LocalParentLevel` calls only the
/// gate-free reads a SafetyNet gate allows.
public protocol ParentLevel: AnyObject, Sendable {
    /// Whether the parent executed a block producing this state, from its
    /// genesis: the executed-from-genesis frontier, never a state it only
    /// weighed.
    func hasProducedState(_ stateCID: String) async -> Bool
    /// The genesis link the parent recorded for this child genesis in
    /// `directory`, bound to the empty parent state a self-contained genesis
    /// commits to. Nil when the parent recorded no such genesis.
    func recordedGenesisLink(
        directory: String, childGenesisCID: String
    ) async -> ParentGenesisLink?
    /// The genesis CID the parent committed for `directory` in its
    /// validated tip's state. Nil while no anchor is committed there.
    func anchoredGenesisCID(directory: String) async -> String?
    /// The run the parent credits to `carrier`, one of its blocks committing
    /// into `directory` (§9.10). Nil while the parent does not serve runs for
    /// `directory` or `carrier` commits nothing there.
    func runReport(carrier: String, directory: String) async -> ParentRunReport?
}

/// What the parent level tells a hosted child (`ChainService.ParentMailbox`):
/// runs in the order sent, tip changes coalesced. Delivery never blocks the
/// parent.
public enum ParentChange: Sendable {
    /// The parent's validated tip or executed frontier moved: a parent fact
    /// a child block waited on may hold now.
    case tipChanged
    /// Runs the parent credits to its blocks committing into the child's
    /// directory changed (§9.10): the child credits each at the child block
    /// the committer carried.
    case runs([ParentRunReport])
}

/// A parent fact a child admission can read from its co-hosted parent
/// level: the key a `.wait(.parentFact)` park waits on.
enum ParentFact: Hashable, Sendable {
    /// The parent executed a block producing `toStateCID`, from genesis.
    case continuity(toStateCID: String)
    /// The parent recorded `childGenesisCID` for `directory`.
    case genesis(directory: String, childGenesisCID: String)

    /// The fact `requirement` names, or nil when the requirement is not a
    /// fact `child`'s immediate parent level can answer.
    init?(_ requirement: CrossChainEvidenceRequirement, child: ChainAddress) {
        let parentPath = Array(child.components.dropLast())
        switch requirement {
        case .parentGenesis(
            let requiredPath, let directory, let childGenesisCID, let parentStateCID
        ) where requiredPath == parentPath && directory == child.directory
            // A self-contained genesis commits to the empty parent state.
            && parentStateCID == LatticeState.emptyHeader.rawCID:
            self = .genesis(directory: directory, childGenesisCID: childGenesisCID)
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
        case .genesis(let directory, let childGenesisCID):
            await recordedGenesisLink(
                directory: directory, childGenesisCID: childGenesisCID
            )?.parentStateCID == LatticeState.emptyHeader.rawCID
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
        case .genesis(let directory, let childGenesisCID):
            guard let link = await recordedGenesisLink(
                directory: directory, childGenesisCID: childGenesisCID
            ), link.parentStateCID == LatticeState.emptyHeader.rawCID
            else { return nil }
            fact = ChildValidationPackage(
                proof: package.package.proof, parentGenesisLink: link
            )
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
final class LocalParentLevel: @unchecked Sendable, ParentLevel {
    private weak var process: ChainProcess?

    init(_ process: ChainProcess) {
        self.process = process
    }

    func hasProducedState(_ stateCID: String) async -> Bool {
        await process?.hasProducedParentState(stateCID) ?? false
    }

    func recordedGenesisLink(
        directory: String, childGenesisCID: String
    ) async -> ParentGenesisLink? {
        guard let process else { return nil }
        return try? await process.store.issuedParentGenesisLink(
            directory: directory,
            childGenesisCID: childGenesisCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
    }

    func anchoredGenesisCID(directory: String) async -> String? {
        await process?.anchoredChildGenesisCIDs(
            directories: [directory]
        )[directory]
    }

    func runReport(carrier: String, directory: String) async -> ParentRunReport? {
        await process?.runReport(carrier: carrier, directory: directory)
    }
}
