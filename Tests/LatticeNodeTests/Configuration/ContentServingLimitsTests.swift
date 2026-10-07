import Foundation
import Ivy
import XCTest
@testable import LatticeNode

/// Operator content-serving limits reach the overlay unchanged, and an
/// impossible combination is refused when the overlay is configured.
final class ContentServingLimitsTests: XCTestCase {
    private func configuration(_ limits: ContentServingLimits) throws -> NodeConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serving-limits-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "5a", count: 32),
            contentServing: limits
        )
    }

    func testDefaultsAreTheOverlayDefaults() throws {
        let overlay = try OverlayConfiguration(configuration(.default)).overlay
        let defaults = IvyConfig(signingKey: .init(), listenPort: 0)
        XCTAssertEqual(overlay.maxConcurrentContentRequests, defaults.maxConcurrentContentRequests)
        XCTAssertEqual(overlay.maxInFlightVolumeBytes, defaults.maxInFlightVolumeBytes)
    }

    func testOperatorLimitsReachTheOverlay() throws {
        let overlay = try OverlayConfiguration(configuration(ContentServingLimits(
            maxConcurrent: 200,
            maxInFlightVolumeBytes: 512 * 1024 * 1024
        ))).overlay
        XCTAssertEqual(overlay.maxConcurrentContentRequests, 200)
        XCTAssertEqual(overlay.maxInFlightVolumeBytes, 512 * 1024 * 1024)
    }

    func testImpossibleLimitsAreRefused() throws {
        XCTAssertThrowsError(try OverlayConfiguration(configuration(
            ContentServingLimits(maxInFlightVolumeBytes: 0)
        )))
    }
}
