import Lattice
import XCTest
@testable import LatticeNode

/// The two decisions candidate admission acts on once an outcome is back:
/// whom it blames (`candidateBlame`) and how the fetcher resolves the
/// candidate (`candidateResolution`). Every input combination is pinned.
final class CandidateAdmissionDecisionTests: XCTestCase {

    private static let childProof = CrossChainEvidenceRequirement.childProof(
        chainPath: ["Nexus", "Payments"], childCID: "child"
    )
    private static let parentGenesis = CrossChainEvidenceRequirement.parentGenesis(
        parentPath: ["Nexus"], directory: "Payments",
        childGenesisCID: "genesis", parentStateCID: "state"
    )
    private static let parentContinuity =
        CrossChainEvidenceRequirement.parentStateContinuity(
            parentPath: ["Nexus"], fromStateCID: "from", toStateCID: "to"
        )
    private static let commit = ChainCommit(tipHash: "a")

    private static let unavailable: [NodeImportDecision] = [
        .unavailable(nil),
        .unavailable(childProof),
        .unavailable(parentGenesis),
        .unavailable(parentContinuity),
    ]

    /// Every decision case, with each requirement `unavailable` can carry.
    private static let decisions: [NodeImportDecision] = unavailable + [
        .canonicalized(commit),
        .acceptedSide(commit),
        .duplicate,
        .temporarilyInvalid,
        .proofOfWorkInvalid,
        .invalid,
        .localFailure,
    ]

    private struct Inputs {
        let complete: Bool
        let soleSupplier: String?
        let ready: Bool
    }

    /// Every combination of the attribution inputs.
    private static let inputs: [Inputs] = {
        var result: [Inputs] = []
        for complete in [false, true] {
            for soleSupplier in [nil, "supplier"] as [String?] {
                for ready in [false, true] {
                    result.append(Inputs(
                        complete: complete,
                        soleSupplier: soleSupplier,
                        ready: ready
                    ))
                }
            }
        }
        return result
    }()

    private func blame(_ decision: NodeImportDecision, _ inputs: Inputs) -> String? {
        NodeNetworkRuntime.candidateBlame(
            decision,
            complete: inputs.complete,
            soleSupplier: inputs.soleSupplier,
            supplierHasReadySession: inputs.ready
        )
    }

    /// Establishes: NODE-SEMANTICS-003.b
    func testUnavailableNeverBlames() {
        for decision in Self.unavailable {
            for inputs in Self.inputs {
                XCTAssertNil(blame(decision, inputs), "\(decision) \(inputs)")
            }
        }
    }

    /// Establishes: NODE-SEMANTICS-004.b
    func testALocalFailureNeverBlames() {
        for inputs in Self.inputs {
            XCTAssertNil(blame(.localFailure, inputs), "\(inputs)")
        }
    }

    /// Only a header that proves no work blames its sender: a plain
    /// invalidity (a bad transition, malformed evidence, a rule the chain
    /// does not accept here) blames no one.
    ///
    /// Establishes: NODE-SEMANTICS-005.b
    func testInvalidDuplicateTemporarilyInvalidAndAcceptedNeverBlame() {
        let decisions: [NodeImportDecision] = [
            .invalid, .duplicate, .temporarilyInvalid,
            .canonicalized(Self.commit), .acceptedSide(Self.commit),
        ]
        for decision in decisions {
            for inputs in Self.inputs {
                XCTAssertNil(blame(decision, inputs), "\(decision) \(inputs)")
            }
        }
    }

    /// Every row of the table: blame exactly when the decision is
    /// `proofOfWorkInvalid`, the fetch was complete, one remote peer supplied
    /// it, and that peer's session is ready. The blamed peer is that
    /// supplier.
    ///
    /// Establishes: NODE-SEMANTICS-005.a
    func testOnlyACompleteProofOfWorkFailureFromItsSoleReadySupplierIsBlamed() {
        var blamedRows = 0
        for decision in Self.decisions {
            for inputs in Self.inputs {
                let attributable = decision == .proofOfWorkInvalid
                    && inputs.complete
                    && inputs.soleSupplier != nil
                    && inputs.ready
                XCTAssertEqual(
                    blame(decision, inputs),
                    attributable ? inputs.soleSupplier : nil,
                    "\(decision) \(inputs)"
                )
                if attributable { blamedRows += 1 }
            }
        }
        XCTAssertEqual(blamedRows, 1)
    }

    // MARK: - Resolution

    private func resolve(
        _ decision: NodeImportDecision,
        parkOn: String? = nil,
        contentShortfall: Bool = false
    ) -> String {
        switch NodeNetworkRuntime.candidateResolution(
            decision, parkOn: parkOn, contentShortfall: contentShortfall
        ) {
        case .terminal: "terminal"
        case .wait(.evidence): "wait evidence"
        case .wait(.content): "wait content"
        case .wait(.later): "wait later"
        case .wait(.parentFact): "wait parent fact"
        case .predecessor(let cid): "predecessor \(cid)"
        case .connected: "connected"
        }
    }

    /// `unavailable` always waits: for a new provider when the body was not
    /// served, for the parent's tip to move on a missing parent fact, and
    /// for new evidence otherwise.
    ///
    /// Establishes: NODE-SEMANTICS-003.a
    func testUnavailableWaitsByWhatIsMissing() {
        XCTAssertEqual(resolve(.unavailable(nil)), "wait evidence")
        XCTAssertEqual(
            resolve(.unavailable(nil), contentShortfall: true), "wait content"
        )
        XCTAssertEqual(resolve(.unavailable(Self.childProof)), "wait evidence")
        XCTAssertEqual(
            resolve(.unavailable(Self.childProof), contentShortfall: true),
            "wait evidence"
        )
        for shortfall in [false, true] {
            XCTAssertEqual(
                resolve(.unavailable(Self.parentGenesis), contentShortfall: shortfall),
                "wait parent fact"
            )
            XCTAssertEqual(
                resolve(.unavailable(Self.parentContinuity), contentShortfall: shortfall),
                "wait parent fact"
            )
        }
    }

    func testEveryOtherDecisionResolvesByItsMeaning() {
        let expected: [(NodeImportDecision, String)] = [
            (.canonicalized(Self.commit), "connected"),
            (.acceptedSide(Self.commit), "connected"),
            (.duplicate, "connected"),
            (.temporarilyInvalid, "wait later"),
            (.proofOfWorkInvalid, "terminal"),
            (.invalid, "terminal"),
            (.localFailure, "terminal"),
        ]
        for (decision, resolution) in expected {
            for shortfall in [false, true] {
                XCTAssertEqual(
                    resolve(decision, contentShortfall: shortfall),
                    resolution,
                    "\(decision)"
                )
            }
        }
    }

    func testAMissingAncestorParksWhateverTheDecision() {
        for decision in Self.decisions {
            for shortfall in [false, true] {
                XCTAssertEqual(
                    resolve(decision, parkOn: "p", contentShortfall: shortfall),
                    "predecessor p",
                    "\(decision)"
                )
            }
        }
    }
}
