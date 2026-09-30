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

    func testTemporalAndTargetMissResultsStayDistinct() {
        let temporal = NodeImportDecision(.rejected(.notYetValid))
        XCTAssertTrue(temporal.shouldRetryLater)
        XCTAssertFalse(temporal.shouldRetryWhenEvidenceChanges)

        // A target miss is a terminal proof-of-work failure, the one refusal
        // that blames its sender; it is not a plain invalidity.
        let targetMiss = NodeImportDecision(.rejected(.proofOfWorkInvalid))
        XCTAssertEqual(targetMiss, .proofOfWorkInvalid)
        XCTAssertFalse(targetMiss.shouldRetryLater)
        XCTAssertFalse(targetMiss.shouldRetryWhenEvidenceChanges)
    }

    /// A bootstrap refusal blames no one: a genesis that misses its own
    /// target is the content's fault, not its server's.
    func testABootstrapProofOfWorkFailureIsBlameless() {
        XCTAssertEqual(ChainProcess.bootstrapDecision(.proofOfWorkInvalid), .invalid)
        for error in Self.errorSamples where error != .proofOfWorkInvalid {
            XCTAssertEqual(
                ChainProcess.bootstrapDecision(error),
                NodeImportDecision(error),
                "\(error)"
            )
        }
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
        case .notAcceptedAtCurrentChain: .invalid
        case .proofOfWorkInvalid: .proofOfWorkInvalid
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
        .proofOfWorkInvalid,
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
        case .proofOfWorkInvalid: "proofOfWorkInvalid"
        }
    }

    private static func accepted(_ commit: ChainCommit) -> BlockImportResult {
        .accepted(ChainAcceptance(
            facts: .validation(blockHash: commit.tipHash),
            materializedPostState: nil,
            commit: commit,
            sameChainPredecessor: nil
        ))
    }

    /// Every result shape the decision reads, with its exact decision. A new
    /// `BlockImportResult` case fails to compile in `resultCaseName`.
    private static let resultTable: [(String, BlockImportResult, NodeImportDecision)] = [
        ("accepted, added", accepted(added), .canonicalized(added)),
        ("accepted, removed only", accepted(removedOnly), .canonicalized(removedOnly)),
        ("accepted, unchanged", accepted(unchanged), .acceptedSide(unchanged)),
        ("duplicate", .duplicate(), .duplicate),
        ("duplicate behind a predecessor",
         .duplicate(sameChainPredecessor: predecessor), .duplicate),
        ("duplicate, promoted unchanged",
         .duplicate(promotedCommit: unchanged), .duplicate),
        ("duplicate, promoted canonical",
         .duplicate(promotedCommit: added), .canonicalized(added)),
    ] + errorSamples.map { error in
        ("rejected \(error)", .rejected(error), expected(error))
    }

    private static func resultCaseName(_ result: BlockImportResult) -> String {
        switch result {
        case .accepted: "accepted"
        case .duplicate: "duplicate"
        case .rejected: "rejected"
        }
    }

    /// Every decision case, with the payload each carries.
    private static let decisions: [NodeImportDecision] = [
        .canonicalized(added),
        .acceptedSide(unchanged),
        .duplicate,
        .unavailable(nil),
        .unavailable(childProof),
        .unavailable(parentGenesis),
        .unavailable(parentContinuity),
        .temporarilyInvalid,
        .proofOfWorkInvalid,
        .invalid,
        .localFailure,
    ]

    /// Establishes: NODE-SEMANTICS-001.a
    func testEveryImportResultAndErrorMapsToItsExactDecision() {
        XCTAssertEqual(
            Set(Self.errorSamples.map(Self.caseName)).count, 9,
            "every BlockImportError case needs a sample"
        )
        for error in Self.errorSamples {
            XCTAssertEqual(NodeImportDecision(error), Self.expected(error), "\(error)")
        }
        XCTAssertEqual(
            Set(Self.resultTable.map { Self.resultCaseName($0.1) }).count, 3,
            "every BlockImportResult case needs a row"
        )
        for (name, result, decision) in Self.resultTable {
            XCTAssertEqual(NodeImportDecision(result), decision, name)
        }
        // The eight meanings stay distinct: each row's decision equals only
        // decisions of its own case.
        let names = Set(Self.resultTable.map { Self.decisionCaseName($0.2) })
        XCTAssertEqual(names, [
            "canonicalized", "acceptedSide", "duplicate", "unavailable",
            "temporarilyInvalid", "proofOfWorkInvalid", "invalid",
            "localFailure",
        ])
    }

    private static func decisionCaseName(_ decision: NodeImportDecision) -> String {
        switch decision {
        case .canonicalized: "canonicalized"
        case .acceptedSide: "acceptedSide"
        case .duplicate: "duplicate"
        case .unavailable: "unavailable"
        case .temporarilyInvalid: "temporarilyInvalid"
        case .proofOfWorkInvalid: "proofOfWorkInvalid"
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
            "duplicate": "accepted",
            "unavailable": "evidence",
            "temporarilyInvalid": "later",
            "proofOfWorkInvalid": "",
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
