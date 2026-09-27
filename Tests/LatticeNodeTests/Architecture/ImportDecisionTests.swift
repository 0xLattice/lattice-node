import Lattice
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
}
