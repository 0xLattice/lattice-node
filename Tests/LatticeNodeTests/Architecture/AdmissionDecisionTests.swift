import Lattice
import XCTest
@testable import LatticeNode

final class AdmissionDecisionTests: XCTestCase {
    func testAvailabilityAndInvalidityStayDistinct() {
        let unavailable = NodeAdmissionDecision(
            .rejected(.crossChainEvidenceRequired(.childProof(
                chainPath: ["Nexus", "Payments"],
                childCID: "child"
            )))
        )
        XCTAssertTrue(unavailable.shouldRetryWhenEvidenceChanges)

        let invalid = NodeAdmissionDecision(.rejected(.protocolInvalid))
        XCTAssertFalse(invalid.shouldRetryWhenEvidenceChanges)
        XCTAssertFalse(invalid.shouldRetryLater)
    }

    func testTemporalAndTargetMissResultsStayNeutral() {
        let temporal = NodeAdmissionDecision(.rejected(.notYetAdmissible))
        XCTAssertTrue(temporal.shouldRetryLater)
        XCTAssertFalse(temporal.shouldRetryWhenEvidenceChanges)

        let targetMiss = NodeAdmissionDecision(
            .rejected(.notAcceptedAtCurrentChain)
        )
        XCTAssertEqual(targetMiss, .carrier)
    }
}
