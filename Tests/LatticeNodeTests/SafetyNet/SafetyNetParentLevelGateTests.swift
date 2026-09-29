import Foundation
import XCTest

/// Structural gate over `LocalParentLevel` (the lock-order rule): a child's
/// reads of its co-hosted parent are gate-free. The parent awaits its
/// children while holding its own `ChainService` lease, so a child read that
/// took the parent's `ChainProcess` operation gate or its service lease
/// could close a cycle. `LocalParentLevel` may therefore call only the
/// allowlisted process and store reads below, and each allowlisted
/// `ChainProcess` method must itself take no operation gate.
///
/// Comments and string contents are skipped.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetParentLevelGateTests: XCTestCase {

    /// Every parent read `LocalParentLevel` may make, as `process.<member>`.
    private static let allowlist: Set<String> = [
        "hasProducedParentState",
        "store.issuedParentGenesisLink",
        "anchoredChildGenesisCIDs",
        "runReport",
    ]

    /// A call through the parent process, optionally through its store.
    private static let parentCall =
        #"\bprocess\??\.(store\??\.)?([A-Za-z_][A-Za-z0-9_]*)"#

    private func code(_ file: String) throws -> String {
        let files = try SourceTree.swiftFiles(under: "Sources/LatticeNode/Architecture")
        let source = try XCTUnwrap(files.first { $0.path == file }, "\(file) moved")
        return SwiftSource.code(source.text)
    }

    /// The braced body that follows the first match of `header` in `text`.
    private func body(after header: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: header), "no \(header)")
        let open = try XCTUnwrap(
            text[start.upperBound...].firstIndex(of: "{"), "no body after \(header)"
        )
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        XCTFail("unbalanced body after \(header)")
        return ""
    }

    private func parentCalls(in text: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: Self.parentCall)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).map { match in
            let store = Range(match.range(at: 1), in: text) != nil
            let member = String(text[Range(match.range(at: 2), in: text)!])
            return store ? "store.\(member)" : member
        })
    }

    func testPatternSeesEveryCallShape() throws {
        let sample = """
        await process?.hasProducedParentState(x)
        try? await process.store.issuedParentGenesisLink(directory: d)
        await process?.store?.other()
        await process.importBlock(header)
        """
        XCTAssertEqual(try parentCalls(in: sample), [
            "hasProducedParentState",
            "store.issuedParentGenesisLink",
            "store.other",
            "importBlock",
        ])
    }

    func testLocalParentLevelCallsOnlyGateFreeReads() throws {
        let level = try body(
            after: "final class LocalParentLevel",
            in: try code("ParentLevel.swift")
        )
        let calls = try parentCalls(in: level)
        XCTAssertFalse(calls.isEmpty, "the gate no longer sees the parent reads")
        XCTAssertEqual(
            calls.subtracting(Self.allowlist), [],
            "LocalParentLevel reaches the parent outside the gate-free allowlist"
        )
        XCTAssertFalse(
            level.contains("ChainService"),
            "LocalParentLevel must not reach the parent's service lease"
        )
    }

    func testAllowlistedProcessReadsTakeNoOperationGate() throws {
        let process = try code("ChainProcess.swift")
        for member in Self.allowlist where !member.hasPrefix("store.") {
            let read = try body(after: "func \(member)(", in: process)
            XCTAssertFalse(
                read.contains("acquire"),
                "ChainProcess.\(member) takes the operation gate"
            )
        }
    }
}
