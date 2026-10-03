import Foundation
import XCTest

/// Structural gates over `Sources/LatticeNode`: the storage
/// layer's two single-spelling rules, checked on the source text so a new
/// site cannot bypass them.
///
/// - (a) Only `Storage/NodeSQLite.swift` and `Storage/NodeStoreRow.swift` read a
///   `NodeSQLiteValue` through `textValue` / `intValue` / `blobValue`; every
///   other reader goes through a per-table record.
/// - (b) No execution tier is spelled as an integer: every
///   `accepted_blocks.validated` read and write goes through `BlockStatus`.
///
/// Comments are skipped; string literals are not, because the tier rule is
/// mostly spelled in SQL.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetStorageGateTests: XCTestCase {

    private func sources() throws -> [SourceFile] {
        try SourceTree.swiftFiles(under: "Sources/LatticeNode")
    }

    private func matches(_ pattern: String, in files: [SourceFile]) throws -> [String] {
        try SwiftSource.matchingLines(pattern, in: files, view: SwiftSource.blankingComments)
    }

    func testGateSeesTheSources() throws {
        let paths = try sources().map(\.path)
        XCTAssertTrue(paths.contains("Storage/NodeSQLite.swift"), "gate walked \(paths.count) files")
        XCTAssertTrue(paths.contains("Storage/NodeStoreRow.swift"))
        XCTAssertTrue(paths.contains("Storage/BlockStatus.swift"))
    }

    func testRawColumnValuesAreReadOnlyByTheRowLayer() throws {
        let allowed: Set<String> = ["Storage/NodeSQLite.swift", "Storage/NodeStoreRow.swift"]
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
