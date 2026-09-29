import Foundation
import XCTest

/// Structural gate over the co-hosted levels (the lock-order rule, §2.4): a
/// child's reads of its co-hosted parent are gate-free. The parent's template
/// path awaits its children's candidate builds while holding its own
/// `ChainService` lease, so a child read that took the parent's `ChainProcess`
/// operation gate or its service lease could close a cycle.
/// `LocalParentLevel` may therefore call only the allowlisted process and
/// store reads below, and each allowlisted `ChainProcess` method must itself
/// take no operation gate; a child's candidate build reaches its parent only
/// through `ParentLevel`, and `LocalChildLevel` reaches only its own level.
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
        "fetch",
    ]

    /// Every member `LocalChildLevel` may call, as `<receiver>.<member>`:
    /// its own level's service, process and runtime, and its mailbox.
    private static let childLevelAllowlist: Set<String> = [
        "service.hostedMiningCandidate",
        "service.candidateCID",
        "process.store.pendingHandoffChildCIDs",
        "network.offerGate",
        "mailbox.send",
    ]

    /// Every `ParentLevel` member a `ChainService` may call on its parent.
    private static let parentLevelMembers: Set<String> = [
        "hasProducedState", "recordedGenesisLink", "anchoredGenesisCID",
        "runReport", "contentSource", "evidence", "holds",
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

    func testLocalChildLevelReachesOnlyItsOwnLevel() throws {
        let level = try body(
            after: "final class LocalChildLevel",
            in: try code("ParentLevel.swift")
        )
        let regex = try NSRegularExpression(
            pattern: #"\b(service|process|network|mailbox)\??\.(store\??\.)?([A-Za-z_][A-Za-z0-9_]*)\("#
        )
        let calls = Set(regex.matches(
            in: level, range: NSRange(level.startIndex..., in: level)
        ).map { match -> String in
            let receiver = String(level[Range(match.range(at: 1), in: level)!])
            let store = Range(match.range(at: 2), in: level) != nil ? "store." : ""
            let member = String(level[Range(match.range(at: 3), in: level)!])
            return "\(receiver).\(store)\(member)"
        })
        XCTAssertFalse(calls.isEmpty, "the gate no longer sees the child level's calls")
        XCTAssertEqual(
            calls.subtracting(Self.childLevelAllowlist), [],
            "LocalChildLevel reaches beyond its own level"
        )
        XCTAssertFalse(
            level.contains("ParentLevel") || level.contains("parentLevel"),
            "LocalChildLevel must not reach a parent level"
        )
    }

    /// A child's candidate build runs inside its own `ChainService`: the one
    /// handle it holds on its parent is `parentLevel`, used only through the
    /// `ParentLevel` protocol, whose one conformer is the allowlisted
    /// `LocalParentLevel` (no other type can smuggle in a gated call).
    func testAChildServiceReachesItsParentOnlyThroughParentLevel() throws {
        let service = try code("ChainService.swift")
        let regex = try NSRegularExpression(
            pattern: #"\bparentLevel\??\.([A-Za-z_][A-Za-z0-9_]*)"#
        )
        let members = Set(regex.matches(
            in: service, range: NSRange(service.startIndex..., in: service)
        ).map { String(service[Range($0.range(at: 1), in: service)!]) })
        XCTAssertFalse(members.isEmpty, "the gate no longer sees the parent reads")
        XCTAssertEqual(
            members.subtracting(Self.parentLevelMembers), [],
            "ChainService reaches its parent outside ParentLevel"
        )
        let conformer = try NSRegularExpression(
            pattern: #"(class|actor|struct|enum)\s+(\w+)[^{]*[:,]\s*ParentLevel\b"#
        )
        var conformers: Set<String> = []
        for file in try SourceTree.swiftFiles(under: "Sources") {
            let text = SwiftSource.code(file.text)
            for match in conformer.matches(
                in: text, range: NSRange(text.startIndex..., in: text)
            ) {
                conformers.insert(String(text[Range(match.range(at: 2), in: text)!]))
            }
        }
        XCTAssertEqual(conformers, ["LocalParentLevel"])
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
