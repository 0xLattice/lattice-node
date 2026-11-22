import Foundation
import XCTest

/// Structural gate over the node runtime and the modules split out of it:
/// `LatticeNodeSupport/Timers.swift` is the only file that suspends on a sleep. Everything else arms a
/// `Timers` deadline, retry, poll or repeat, so no site can reach for
/// `Task.sleep(for:)` / `Clock.sleep(for:)` (which miscompile under Swift
/// 6.3 -O) or re-grow its own copy of the deadline pattern.
///
/// Comments are skipped: prose may name the primitive.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetSleepGateTests: XCTestCase {

    /// A direct sleep. `Timers.sleep(` is the sanctioned call, not a site.
    private static let sleepPattern = #"Task\.sleep|(?<!\bTimers)\.sleep\("#

    private static let modules = [
        "LatticeNode", "LatticeNodeConfig", "LatticeNodeCore",
        "LatticeNodeNet", "LatticeNodeStore", "LatticeNodeSupport",
    ]
    private static let timers = "LatticeNodeSupport/Timers.swift"

    private func sources() throws -> [SourceFile] {
        try SourceTree.swiftFiles(under: "Sources").filter { file in
            Self.modules.contains { file.path.hasPrefix($0 + "/") }
        }
    }

    private func matches(_ pattern: String, in files: [SourceFile]) throws -> [String] {
        try SwiftSource.matchingLines(pattern, in: files, view: SwiftSource.blankingComments)
    }

    func testGateSeesTheSleepPrimitive() throws {
        let files = try sources()
        XCTAssertTrue(files.map(\.path).contains(Self.timers), "gate walked \(files.count) files")
        let found = try matches(Self.sleepPattern, in: files.filter { $0.path == Self.timers })
        XCTAssertFalse(found.isEmpty, "the pattern no longer finds the primitive itself")
    }

    func testPatternCatchesEverySleepSpelling() throws {
        let caught = [
            "try await Task.sleep(nanoseconds: 1)",
            "try await Task.sleep(for: .seconds(1))",
            "try? await ContinuousClock.continuous",
            "    .sleep(until: ContinuousClock.now)",
            "try await clock.sleep(for: .seconds(1))",
        ]
        let allowed = ["_ = await Timers.sleep(nanoseconds: delay)"]
        let sample = [SourceFile(path: "sample", text: (caught + allowed).joined(separator: "\n"))]
        let found = try matches(Self.sleepPattern, in: sample)
        XCTAssertEqual(found, [
            "sample:1: try await Task.sleep(nanoseconds: 1)",
            "sample:2: try await Task.sleep(for: .seconds(1))",
            "sample:4: .sleep(until: ContinuousClock.now)",
            "sample:5: try await clock.sleep(for: .seconds(1))",
        ])
    }

    func testOnlyTimersSleeps() throws {
        let found = try matches(
            Self.sleepPattern,
            in: sources().filter { $0.path != Self.timers }
        )
        XCTAssertEqual(found, [], "sleep outside Timers.swift; use Timers")
    }
}
