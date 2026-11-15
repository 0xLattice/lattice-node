import Foundation
import XCTest
@testable import LatticeNodeDaemon

/// SIGHUP is caught from the process's start: one that comes before the
/// node can reload is kept, and acted on once it can.
final class HangupsTests: XCTestCase {
    func testAnEarlySIGHUPIsActedOnOnceTheNodeCanReload() async throws {
        let hangups = Hangups()
        hangups.install()
        XCTAssertEqual(kill(getpid(), SIGHUP), 0, "the process survives it: caught, not its default")
        // The signal source hands it over on its own queue.
        try await Task.sleep(for: .milliseconds(300))
        let reloaded = expectation(description: "the early SIGHUP is acted on")
        hangups.onHangup { reloaded.fulfill() }
        await fulfillment(of: [reloaded], timeout: 5)
        // A later one goes straight to the action.
        let again = expectation(description: "a later SIGHUP")
        hangups.onHangup { again.fulfill() }
        XCTAssertEqual(kill(getpid(), SIGHUP), 0)
        await fulfillment(of: [again], timeout: 5)
    }
}
