import Lattice
@testable import LatticeImport
import XCTest
@testable import LatticeNode

final class ImportDecisionTests: XCTestCase {
    func testAvailabilityAndInvalidityStayDistinct() {
        let unavailable = NodeImportDecision(
            .rejected(.crossChainEvidenceRequired(.childProof(
                chainPath: ["Nexus", "Payments"],
                childCID: "child"
            )))
        )
        XCTAssertTrue(unavailable.shouldRetryWhenEvidenceChanges)

        let invalid = NodeImportDecision(.rejected(.protocolInvalid))
        XCTAssertFalse(invalid.shouldRetryWhenEvidenceChanges)
        XCTAssertFalse(invalid.shouldRetryLater)
    }

    func testTemporalAndTargetMissResultsStayNeutral() {
        let temporal = NodeImportDecision(.rejected(.notYetValid))
        XCTAssertTrue(temporal.shouldRetryLater)
        XCTAssertFalse(temporal.shouldRetryWhenEvidenceChanges)

        let targetMiss = NodeImportDecision(
            .rejected(.notAcceptedAtCurrentChain)
        )
        XCTAssertEqual(targetMiss, .carrier)
    }

    // MARK: - Exhaustive tables

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
    private static let added = ChainCommit(
        revision: 2, tipHash: "a", canonicalBlocksAdded: ["a": 1]
    )
    private static let removedOnly = ChainCommit(
        revision: 3, tipHash: "g", canonicalBlocksRemoved: ["a"]
    )
    private static let unchanged = ChainCommit(revision: 4, tipHash: "a")
    private static let predecessor = SameChainPredecessorRequirement(
        descendantCID: "b", predecessorCID: "a"
    )

    /// The node meaning of each Lattice import error. The switch has no
    /// default: a new `BlockImportError` case fails to compile here until it
    /// is given its meaning, and a sample in `errorSamples`.
    private static func expected(_ error: BlockImportError) -> NodeImportDecision {
        switch error {
        case .unavailableEvidence: .unavailable(nil)
        case .crossChainEvidenceRequired(let requirement): .unavailable(requirement)
        case .providerMalformedEvidence: .invalid
        case .protocolInvalid: .invalid
        case .localVerificationFailure: .localFailure
        case .revisionExhausted: .localFailure
        case .notYetValid: .temporarilyInvalid
        case .notAcceptedAtCurrentChain: .carrier
        }
    }

    /// One sample per case, each requirement for the case that carries one.
    private static let errorSamples: [BlockImportError] = [
        .unavailableEvidence,
        .crossChainEvidenceRequired(childProof),
        .crossChainEvidenceRequired(parentGenesis),
        .crossChainEvidenceRequired(parentContinuity),
        .providerMalformedEvidence,
        .protocolInvalid,
        .localVerificationFailure,
        .revisionExhausted,
        .notYetValid,
        .notAcceptedAtCurrentChain,
    ]

    private static func caseName(_ error: BlockImportError) -> String {
        switch error {
        case .unavailableEvidence: "unavailableEvidence"
        case .crossChainEvidenceRequired: "crossChainEvidenceRequired"
        case .providerMalformedEvidence: "providerMalformedEvidence"
        case .protocolInvalid: "protocolInvalid"
        case .localVerificationFailure: "localVerificationFailure"
        case .revisionExhausted: "revisionExhausted"
        case .notYetValid: "notYetValid"
        case .notAcceptedAtCurrentChain: "notAcceptedAtCurrentChain"
        }
    }

    private static func accepted(_ commit: ChainCommit) -> BlockImportResult {
        .accepted(ChainAcceptance(
            facts: .validation(blockHash: commit.tipHash),
            materializedPostState: nil,
            commit: commit,
            sameChainPredecessor: nil,
            parentCarrierLink: nil
        ))
    }

    /// Every result shape the decision reads, with its exact decision. A new
    /// `BlockImportResult` case fails to compile in `resultCaseName`.
    private static let resultTable: [(String, BlockImportResult, NodeImportDecision)] = [
        ("accepted, added", accepted(added), .canonicalized(added)),
        ("accepted, removed only", accepted(removedOnly), .canonicalized(removedOnly)),
        ("accepted, unchanged", accepted(unchanged), .acceptedSide(unchanged)),
        ("carrier", .carrier(nil), .carrier),
        ("carrier behind a predecessor",
         .carrier(nil, sameChainPredecessor: predecessor), .carrier),
        ("duplicate", .duplicate(nil), .duplicate),
        ("duplicate, promoted unchanged",
         .duplicate(nil, promotedCommit: unchanged), .duplicate),
        ("duplicate, promoted canonical",
         .duplicate(nil, promotedCommit: added), .canonicalized(added)),
    ] + errorSamples.map { error in
        ("rejected \(error)", .rejected(error), expected(error))
    }

    private static func resultCaseName(_ result: BlockImportResult) -> String {
        switch result {
        case .accepted: "accepted"
        case .carrier: "carrier"
        case .duplicate: "duplicate"
        case .rejected: "rejected"
        }
    }

    /// Every decision case, with the payload each carries.
    private static let decisions: [NodeImportDecision] = [
        .canonicalized(added),
        .acceptedSide(unchanged),
        .carrier,
        .duplicate,
        .unavailable(nil),
        .unavailable(childProof),
        .unavailable(parentGenesis),
        .unavailable(parentContinuity),
        .temporarilyInvalid,
        .invalid,
        .localFailure,
    ]

    /// Establishes: NODE-SEMANTICS-001.a
    func testEveryImportResultAndErrorMapsToItsExactDecision() {
        XCTAssertEqual(
            Set(Self.errorSamples.map(Self.caseName)).count, 8,
            "every BlockImportError case needs a sample"
        )
        for error in Self.errorSamples {
            XCTAssertEqual(NodeImportDecision(error), Self.expected(error), "\(error)")
        }
        XCTAssertEqual(
            Set(Self.resultTable.map { Self.resultCaseName($0.1) }).count, 4,
            "every BlockImportResult case needs a row"
        )
        for (name, result, decision) in Self.resultTable {
            XCTAssertEqual(NodeImportDecision(result), decision, name)
        }
        // The eight meanings stay distinct: each row's decision equals only
        // decisions of its own case.
        let names = Set(Self.resultTable.map { Self.decisionCaseName($0.2) })
        XCTAssertEqual(names, [
            "canonicalized", "acceptedSide", "carrier", "duplicate",
            "unavailable", "temporarilyInvalid", "invalid", "localFailure",
        ])
    }

    private static func decisionCaseName(_ decision: NodeImportDecision) -> String {
        switch decision {
        case .canonicalized: "canonicalized"
        case .acceptedSide: "acceptedSide"
        case .carrier: "carrier"
        case .duplicate: "duplicate"
        case .unavailable: "unavailable"
        case .temporarilyInvalid: "temporarilyInvalid"
        case .invalid: "invalid"
        case .localFailure: "localFailure"
        }
    }

    /// The flags every consumer reads, per decision: accepted, retried when
    /// the evidence changes, retried later, publishes a canonical tip.
    private static func flags(_ decision: NodeImportDecision) -> String {
        [
            decision.isAccepted ? "accepted" : nil,
            decision.shouldRetryWhenEvidenceChanges ? "evidence" : nil,
            decision.shouldRetryLater ? "later" : nil,
            decision.shouldPublishCanonicalTip ? "publish" : nil,
        ].compactMap { $0 }.joined(separator: ",")
    }

    /// Establishes: NODE-SEMANTICS-002.c
    func testEveryDecisionCarriesExactlyItsFlags() {
        let expected: [String: String] = [
            "canonicalized": "accepted,publish",
            "acceptedSide": "accepted",
            "carrier": "",
            "duplicate": "accepted",
            "unavailable": "evidence",
            "temporarilyInvalid": "later",
            "invalid": "",
            "localFailure": "",
        ]
        for decision in Self.decisions {
            XCTAssertEqual(
                Self.flags(decision),
                expected[Self.decisionCaseName(decision)],
                "\(decision)"
            )
        }
    }

    /// Establishes: NODE-SEMANTICS-002.d
    func testTheServiceMapsEveryDecisionCaseForCase() {
        for decision in Self.decisions {
            XCTAssertEqual(
                WorkDisposition(decision).rawValue,
                Self.decisionCaseName(decision),
                "\(decision)"
            )
        }
    }
}
