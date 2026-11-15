import Foundation
import XCTest
@testable import LatticeNodeDaemon

/// A SIGHUP caught before the node can reload is kept, and acted on once it
/// can. (The signal's delivery to a running node is the E2E's.)
final class HangupsTests: XCTestCase {
    func testAnEarlySIGHUPIsActedOnOnceTheNodeCanReload() {
        let hangups = Hangups()
        hangups.hangUp()
        let reloaded = expectation(description: "the early SIGHUP is acted on")
        hangups.onHangup { reloaded.fulfill() }
        wait(for: [reloaded], timeout: 1)
        // Acted on once; a later one goes straight to the action.
        let again = expectation(description: "a later SIGHUP")
        hangups.onHangup { again.fulfill() }
        hangups.hangUp()
        wait(for: [again], timeout: 1)
    }
}
