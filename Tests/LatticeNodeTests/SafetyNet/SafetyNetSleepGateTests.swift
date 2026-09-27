import Foundation
import XCTest

/// Structural gate over `Sources/LatticeNode/Architecture`: `Timers.swift`
/// is the only file that suspends on a sleep. Everything else arms a
/// `Timers` deadline, retry, poll or repeat, so no site can reach for
/// `Task.sleep(for:)` / `Clock.sleep(for:)` (which miscompile under Swift
/// 6.3 -O) or re-grow its own copy of the deadline pattern.
///
/// Comment lines are skipped: prose may name the primitive.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetSleepGateTests: XCTestCase {

    private static let architectureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SafetyNet
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/LatticeNode/Architecture")

    /// A direct sleep. `Timers.sleep(` is the sanctioned call, not a site.
    private static let sleepPattern = #"Task\.sleep|(?<!\bTimers)\.sleep\("#

    /// Every Swift source under `Architecture`, keyed by path relative to it.
    private func sources() throws -> [(path: String, text: String)] {
        let root = Self.architectureRoot.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(root.path)")
            return []
        }
        var files: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(root.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(files.isEmpty, "no Swift sources under \(root.path)")
        return files.sorted { $0.path < $1.path }
    }

    /// `file:line: text` for every non-comment line of `files` matching `pattern`.
    private func matches(
        _ pattern: String,
        in files: [(path: String, text: String)]
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    found.append("\(file.path):\(index + 1): \(trimmed)")
                }
            }
        }
        return found
    }

    func testGateSeesTheSleepPrimitive() throws {
        let files = try sources()
        XCTAssertTrue(files.map(\.path).contains("Timers.swift"), "gate walked \(files.count) files")
        let found = try matches(Self.sleepPattern, in: files.filter { $0.path == "Timers.swift" })
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
        let sample = [(path: "sample", text: (caught + allowed).joined(separator: "\n"))]
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
            in: sources().filter { $0.path != "Timers.swift" }
        )
        XCTAssertEqual(found, [], "sleep outside Timers.swift; use Timers")
    }
}
