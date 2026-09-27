import Foundation
import XCTest

/// Structural gates over `Sources/LatticeNode/Architecture`: the storage
/// layer's two single-spelling rules, checked on the source text so a new
/// site cannot bypass them.
///
/// - (a) Only `NodeSQLite.swift` and `Storage/NodeStoreRow.swift` read a
///   `NodeSQLiteValue` through `textValue` / `intValue` / `blobValue`; every
///   other reader goes through a per-table record.
/// - (b) No execution tier is spelled as an integer: every
///   `accepted_blocks.validated` read and write goes through `BlockStatus`.
///
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetStorageGateTests: XCTestCase {

    private static let architectureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SafetyNet
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/LatticeNode/Architecture")

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

    /// `file:line: text` for every line of `files` matching `pattern`.
    private func matches(
        _ pattern: String,
        in files: [(path: String, text: String)]
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    found.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return found
    }

    func testGateSeesTheSources() throws {
        let paths = try sources().map(\.path)
        XCTAssertTrue(paths.contains("NodeSQLite.swift"), "gate walked \(paths.count) files")
        XCTAssertTrue(paths.contains("Storage/NodeStoreRow.swift"))
        XCTAssertTrue(paths.contains("Storage/BlockStatus.swift"))
    }

    func testRawColumnValuesAreReadOnlyByTheRowLayer() throws {
        let allowed: Set<String> = ["NodeSQLite.swift", "Storage/NodeStoreRow.swift"]
        let found = try matches(
            #"\.(textValue|intValue|blobValue)\b"#,
            in: sources().filter { !allowed.contains($0.path) }
        )
        XCTAssertEqual(found, [], "raw NodeSQLiteValue reads outside the row layer")
    }

    func testNoExecutionTierIsSpelledAsAnInteger() throws {
        let files = try sources()
        for pattern in [
            #"\bvalidated\s*(==|!=|>=|<=|=|<|>|IN)\s*\(?\s*-?[0-9]"#,
            #"validated\s*\?\s*1\s*:\s*0"#,
            #"validated INTEGER NOT NULL DEFAULT [0-9]"#,
        ] {
            let found = try matches(pattern, in: files)
            XCTAssertEqual(found, [], "tier literal matching \(pattern); use BlockStatus")
        }
    }
}
