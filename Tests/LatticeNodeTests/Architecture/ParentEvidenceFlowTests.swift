@testable import LatticeNode
import XCTest

final class ParentEvidenceFlowTests: XCTestCase {
    func testBackpressureBlocksReservationUntilCapacityReturns() async throws {
        let session = session(byte: 0x41)
        var flow = ParentEvidenceFlow()
        let append = try XCTUnwrap(flow.beginAppend(
            for: session,
            competingOperationCount: 0,
            capacity: 1
        ))
        let task = Task { ParentEvidenceFlow.Result.backpressured }
        flow.install(task, token: append.token, for: session)
        let reservation = try XCTUnwrap(flow.beginReservation(for: session))

        let result = await reservation.evidenceTail?.value
        XCTAssertEqual(result, .backpressured)
        XCTAssertFalse(flow.finish(
            token: append.token,
            result: .backpressured,
            for: session
        ))
        XCTAssertFalse(flow.allowsReservation(
            for: session,
            after: .handled
        ))

        flow.capacityBecameAvailable(for: session)
        XCTAssertTrue(flow.allowsReservation(
            for: session,
            after: .handled
        ))
        flow.finishReservation(for: session)
    }

    func testUnavailabilityStopsSequenceWithoutFailureOrBackpressure() throws {
        let session = session(byte: 0x61)
        var flow = ParentEvidenceFlow()
        let append = try XCTUnwrap(flow.beginAppend(
            for: session,
            competingOperationCount: 0,
            capacity: 1
        ))
        XCTAssertFalse(flow.finish(
            token: append.token,
            result: .unavailable,
            for: session
        ))
        XCTAssertFalse(flow.isFailed(session))
        XCTAssertFalse(flow.allowsReservation(
            for: session,
            after: .unavailable
        ))

        // Absence carries no blame: the next scan retries the same session,
        // and a handled tail restores reservations without any capacity
        // event.
        let retry = try XCTUnwrap(flow.beginAppend(
            for: session,
            competingOperationCount: 0,
            capacity: 1
        ))
        XCTAssertFalse(flow.finish(
            token: retry.token,
            result: .handled,
            for: session
        ))
        XCTAssertTrue(flow.allowsReservation(
            for: session,
            after: .handled
        ))
    }

    func testFailureIsSessionScopedAndResetClearsIt() throws {
        let failedSession = session(byte: 0x51)
        let healthySession = session(byte: 0x52)
        var flow = ParentEvidenceFlow()
        let append = try XCTUnwrap(flow.beginAppend(
            for: failedSession,
            competingOperationCount: 0,
            capacity: 1
        ))
        XCTAssertTrue(flow.finish(
            token: append.token,
            result: .failed,
            for: failedSession
        ))

        XCTAssertNil(flow.beginReservation(for: failedSession))
        XCTAssertNotNil(flow.beginReservation(for: healthySession))
        flow.reset()
        XCTAssertNotNil(flow.beginReservation(for: failedSession))
    }

    private func session(
        byte: UInt8
    ) -> ParentEvidenceFlow.Session {
        ParentEvidenceFlow.Session(
            peerID: String(byte),
            sessionID: Data(repeating: byte, count: 16)
        )
    }
}
