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
        .carrier,
        .duplicate,
        .temporarilyInvalid,
        .invalid,
        .localFailure,
    ]

    private struct Inputs {
        let complete: Bool
        let soleSupplier: String?
        let ready: Bool
        let isNexus: Bool
        let hasCarrierLink: Bool
    }

    /// Every combination of the attribution and chain inputs.
    private static let inputs: [Inputs] = {
        var result: [Inputs] = []
        for complete in [false, true] {
            for soleSupplier in [nil, "supplier"] as [String?] {
                for ready in [false, true] {
                    for isNexus in [false, true] {
                        for hasCarrierLink in [false, true] {
                            result.append(Inputs(
                                complete: complete,
                                soleSupplier: soleSupplier,
                                ready: ready,
                                isNexus: isNexus,
                                hasCarrierLink: hasCarrierLink
                            ))
                        }
                    }
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
            supplierHasReadySession: inputs.ready,
            isNexus: inputs.isNexus,
            hasCarrierLink: inputs.hasCarrierLink
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

    func testCarrierDuplicateTemporarilyInvalidAndAcceptedNeverBlame() {
        let decisions: [NodeImportDecision] = [
            .carrier, .duplicate, .temporarilyInvalid,
            .canonicalized(Self.commit), .acceptedSide(Self.commit),
        ]
        for decision in decisions {
            for inputs in Self.inputs {
                XCTAssertNil(blame(decision, inputs), "\(decision) \(inputs)")
            }
        }
    }

    /// Every row of the table: blame exactly when the decision is `invalid`,
    /// the fetch was complete, one remote peer supplied it, that peer's
    /// session is ready, and the chain is Nexus or the outcome carries a
    /// parent carrier link. The blamed peer is that supplier.
    ///
    /// Establishes: NODE-SEMANTICS-005.a
    func testOnlyACompleteInvalidFromItsSoleReadySupplierIsBlamed() {
        var blamedRows = 0
        for decision in Self.decisions {
            for inputs in Self.inputs {
                let attributable = decision == .invalid
                    && inputs.complete
                    && inputs.soleSupplier != nil
                    && inputs.ready
                    && (inputs.isNexus || inputs.hasCarrierLink)
                XCTAssertEqual(
                    blame(decision, inputs),
                    attributable ? inputs.soleSupplier : nil,
                    "\(decision) \(inputs)"
                )
                if attributable { blamedRows += 1 }
            }
        }
        // Nexus with or without a link, or a child chain with one.
        XCTAssertEqual(blamedRows, 3)
    }

    /// Establishes: NODE-SEMANTICS-005.b
    func testAChildChainInvalidWithoutACarrierLinkBlamesNoOne() {
        for inputs in Self.inputs where !inputs.isNexus && !inputs.hasCarrierLink {
            XCTAssertNil(blame(.invalid, inputs), "\(inputs)")
        }
        XCTAssertEqual(
            blame(.invalid, Inputs(
                complete: true, soleSupplier: "supplier", ready: true,
                isNexus: false, hasCarrierLink: true
            )),
            "supplier"
        )
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
        case .predecessor(let cid): "predecessor \(cid)"
        case .connected: "connected"
        }
    }

    /// `unavailable` always waits: for a new provider when the body was not
    /// served, on a timer for a missing parent fact, and for new evidence
    /// otherwise.
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
                "wait later"
            )
            XCTAssertEqual(
                resolve(.unavailable(Self.parentContinuity), contentShortfall: shortfall),
                "wait later"
            )
        }
    }

    func testEveryOtherDecisionResolvesByItsMeaning() {
        let expected: [(NodeImportDecision, String)] = [
            (.canonicalized(Self.commit), "connected"),
            (.acceptedSide(Self.commit), "connected"),
            (.duplicate, "connected"),
            (.temporarilyInvalid, "wait later"),
            (.carrier, "terminal"),
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
