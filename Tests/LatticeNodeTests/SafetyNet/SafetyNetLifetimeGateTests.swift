import Foundation
import XCTest

/// Structural gate over the network runtime (`NodeNetworkRuntime*.swift`,
/// `RangeSync.swift`, `ReadURLDiscovery.swift`): state written after a
/// suspension cannot outlive the session or generation that owned it.
///
/// - A task handle the runtime stores is a `TaskSlot` (`Lifetime.swift`),
///   whose clear compares the token the task was started with, so a task
///   that outlived a stop cannot empty the handle a restart stored. No type
///   there stores an optional `Task` except the allowlisted ones, none of
///   which is ever emptied by its own task: the lifecycle and run-report
///   tails (replaced, never cleared by a task), and a range sync's two
///   timeouts (owned by the sync state, cleared by the code that replaces
///   it, their fires matched by request ID / progress epoch).
/// - A per-peer record is created only where a session is established:
///   the creating `PeerSet.update(_:_:)` on `overlayRecords` /
///   `hierarchyRecords` appears only in the allowlisted members. Every
///   other write uses `update(session:_:)` or `updateExisting(_:_:)`,
///   which never create a record, so a write that resumes after its
///   session ended cannot bring the peer's key back.
///
/// Comment lines and string literal text are skipped. Plain `XCTAssert`
/// only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetLifetimeGateTests: XCTestCase {

    private static let architectureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SafetyNet
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/LatticeNode/Architecture")

    /// Stored optional task handles allowed outside a `TaskSlot`.
    private static let taskAllowlist: Set<String> = [
        "lifecycleTail",
        "runReportApplyTail",
        "responseTimeout",
        "progressTimeout",
    ]

    /// Members that establish a session and so may create its record.
    private static let creatingAllowlist: Set<String> = [
        // Overlay connect: the session starts awaiting its hello.
        "didConnect",
        // Hierarchy connect: the hello deadline is the record's first field.
        "scheduleHierarchyHelloDeadline",
        // Accepted hierarchy hello: role and session are bound here.
        "handleHierarchyHello",
    ]

    /// A stored `var` holding an optional `Task`, annotated or inferred.
    private static let taskPattern =
        #"^\s*(?:[\w()]+\s+)*var\s+(\w+)\s*(?::\s*Task<.*>\?|=\s*Task\b)"#

    /// A creating update on a plane's peer set (not `update(session:`).
    private static let creatingUpdatePattern =
        #"\b(?:overlayRecords|hierarchyRecords)\.update\((?!\s*session:)"#

    private static let functionPattern = #"\bfunc\s+(\w+)"#

    private func sources() throws -> [(path: String, text: String)] {
        let root = Self.architectureRoot.standardizedFileURL
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter {
                ($0.hasPrefix("NodeNetworkRuntime") && $0.hasSuffix(".swift"))
                    || $0 == "RangeSync.swift" || $0 == "ReadURLDiscovery.swift"
            }
            .sorted()
        XCTAssertGreaterThan(names.count, 3, "runtime sources not found under \(root.path)")
        return try names.map {
            ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// Every stored optional-task `var`, by name, as `file:line: name`.
    private func storedTaskHandles(
        in files: [(path: String, text: String)]
    ) throws -> [(name: String, site: String)] {
        let pattern = try NSRegularExpression(pattern: Self.taskPattern)
        var found: [(String, String)] = []
        for file in files {
            for (index, raw) in file.text.components(separatedBy: "\n").enumerated() {
                let line = Self.code(of: raw)
                let range = NSRange(line.startIndex..., in: line)
                guard let match = pattern.firstMatch(in: line, range: range),
                      let name = Range(match.range(at: 1), in: line) else { continue }
                found.append((String(line[name]), "\(file.path):\(index + 1)"))
            }
        }
        return found
    }

    /// Every creating peer-set update with the function it sits in.
    private func creatingUpdates(
        in files: [(path: String, text: String)]
    ) throws -> [(function: String, site: String)] {
        let update = try NSRegularExpression(pattern: Self.creatingUpdatePattern)
        let function = try NSRegularExpression(pattern: Self.functionPattern)
        var found: [(String, String)] = []
        for file in files {
            var current = "<file scope>"
            for (index, raw) in file.text.components(separatedBy: "\n").enumerated() {
                let line = Self.code(of: raw)
                let range = NSRange(line.startIndex..., in: line)
                if let match = function.firstMatch(in: line, range: range),
                   let name = Range(match.range(at: 1), in: line) {
                    current = String(line[name])
                }
                if update.firstMatch(in: line, range: range) != nil {
                    found.append((current, "\(file.path):\(index + 1)"))
                }
            }
        }
        return found
    }

    /// The line without its `//` comment and string literal text.
    private static func code(of line: String) -> String {
        var result = ""
        var inString = false
        var previous: Character?
        for character in line {
            if inString {
                if character == "\"" && previous != "\\" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "/" && previous == "/" {
                result.removeLast()
                break
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    func testScanFindsStoredTaskHandlesAndCreatingUpdates() throws {
        let sample = """
        struct Sample {
            var worker: Task<Void, Never>?
            private var tail = Task { }
            var slot = TaskSlot()
            // var commented: Task<Void, Never>?
            let fixed: Task<Void, Never>
            func connect() {
                overlayRecords.update(peer.key) { $0.session = nil }
            }
            func late() async {
                hierarchyRecords.update(session: peer) { $0.offer = nil }
                hierarchyRecords.updateExisting(key) { $0.offer = nil }
                hierarchyRecords.update(key) { $0.offer = nil }
            }
        }
        """
        XCTAssertEqual(
            try storedTaskHandles(in: [("sample", sample)]).map(\.name),
            ["worker", "tail"]
        )
        XCTAssertEqual(
            try creatingUpdates(in: [("sample", sample)]).map(\.function),
            ["connect", "late"]
        )
    }

    func testGateSeesTheAllowlistedSites() throws {
        let files = try sources()
        XCTAssertEqual(
            Set(try storedTaskHandles(in: files).map(\.name)),
            Self.taskAllowlist,
            "an allowlisted handle is gone: shrink the allowlist"
        )
        XCTAssertEqual(
            Set(try creatingUpdates(in: files).map(\.function)),
            Self.creatingAllowlist,
            "an allowlisted creating site is gone: shrink the allowlist"
        )
    }

    func testRuntimeTaskHandlesAreTaskSlots() throws {
        let found = try storedTaskHandles(in: sources())
            .filter { !Self.taskAllowlist.contains($0.name) }
        XCTAssertEqual(
            found.map { "\($0.site): \($0.name)" }, [],
            "store a runtime task handle in a TaskSlot (Lifetime.swift)"
        )
    }

    func testOnlySessionEstablishmentCreatesAPeerRecord() throws {
        let found = try creatingUpdates(in: sources())
            .filter { !Self.creatingAllowlist.contains($0.function) }
        XCTAssertEqual(
            found.map { "\($0.site): \($0.function)" }, [],
            "write per-peer state with update(session:) or updateExisting (PeerSet.swift)"
        )
    }
}
