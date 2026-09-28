import Foundation
import XCTest

/// Structural gate over `Sources/LatticeNode/Architecture/NodeNetworkRuntime*.swift`:
/// no type there stores a `[PeerKey: …]` dictionary or a `Set<PeerKey>`.
/// Per-peer state lives in a `PeerSet` record (`PeerSet.swift`), which a
/// disconnect removes in one step and a restart empties in one step, so a
/// new per-peer field cannot be added somewhere the disconnect forgets.
///
/// Only stored members of a type are checked (locals inside functions may
/// build such collections). `ParentStateQueryGuard.peers` is allowlisted: it
/// is one global capacity shared by both planes, released by the hold its
/// acquire returned, not per-peer state of either plane.
///
/// Scanned as code (`SwiftSource.code`). Plain `XCTAssert` only
/// (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetPeerKeyStateGateTests: XCTestCase {

    /// `Type.property` names allowed to store peer keys.
    private static let allowlist: Set<String> = ["ParentStateQueryGuard.peers"]

    /// A `var`/`let` declaration whose annotated type or initializer is a
    /// peer-keyed dictionary or a set of peer keys.
    private static let declarationPattern =
        #"^\s*(?:[\w()]+\s+)*(?:var|let)\s+(\w+)\s*(?::\s*(?:\[\s*PeerKey\s*:|Set<\s*PeerKey\s*>|Dictionary<\s*PeerKey\s*,)|=\s*(?:Set<\s*PeerKey\s*>|\[\s*PeerKey\s*:|Dictionary<\s*PeerKey\s*,))"#

    /// A line opening a type body.
    private static let typePattern =
        #"\b(?:struct|class|actor|enum|extension)\s+(\w+)[^{]*\{"#

    private func runtimeSources() throws -> [SourceFile] {
        let files = try SourceTree.swiftFiles(under: "Sources/LatticeNode/Architecture")
            .filter { $0.path.hasPrefix("NodeNetworkRuntime") }
        XCTAssertFalse(files.isEmpty, "no NodeNetworkRuntime*.swift in Architecture")
        return files
    }

    /// `Type.property` for every peer-keyed collection stored directly in a
    /// type body. Scopes are tracked by brace depth; a scope is a type body
    /// when the line that opened it declared a type.
    private func storedPeerKeyCollections(
        in files: [SourceFile]
    ) throws -> [String] {
        let declaration = try NSRegularExpression(pattern: Self.declarationPattern)
        let typeOpener = try NSRegularExpression(pattern: Self.typePattern)
        var found: [String] = []
        for file in files {
            // One entry per open brace: the type name if it opened a type body.
            var scopes: [String?] = []
            for line in Self.codeLines(of: file.text) {
                let range = NSRange(line.startIndex..., in: line)
                if let enclosing = scopes.last, let typeName = enclosing,
                   let match = declaration.firstMatch(in: line, range: range),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    found.append("\(typeName).\(line[nameRange])")
                }
                var openedType: String?
                if let match = typeOpener.firstMatch(in: line, range: range),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    openedType = String(line[nameRange])
                }
                for character in line {
                    if character == "{" {
                        scopes.append(openedType)
                        openedType = nil
                    } else if character == "}" {
                        _ = scopes.popLast()
                    }
                }
            }
        }
        return found
    }

    /// The text's lines as code (`SwiftSource.code`), a declaration whose
    /// type annotation continues on the next line (`var x:` then
    /// `[PeerKey: …]`) joined into one.
    private static func codeLines(of text: String) -> [String] {
        var lines: [String] = []
        var pending: String?
        for line in SwiftSource.code(text).components(separatedBy: "\n") {
            let joined = pending.map { $0 + " " + line.trimmingCharacters(in: .whitespaces) } ?? line
            if joined.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                pending = joined
            } else {
                pending = nil
                lines.append(joined)
            }
        }
        if let pending { lines.append(pending) }
        return lines
    }

    func testGateSeesTheAllowlistedGuard() throws {
        let found = try storedPeerKeyCollections(in: runtimeSources())
        XCTAssertTrue(
            Set(found).isSuperset(of: Self.allowlist),
            "the scan no longer finds the allowlisted guard: \(found)"
        )
    }

    func testScanFindsStoredMembersOnly() throws {
        let sample = """
        actor Sample {
            private var byKey: [PeerKey: Int] = [:]
            private(set) var keys = Set<PeerKey>()
            let named: Set<PeerKey>
            private var fine: [UInt64: Int] = [:]
            private var wrapped:
                [PeerKey: [Int]] = [:]
            // private var commented: [PeerKey: Int] = [:]
            private struct Nested {
                var inner: [PeerKey: String]
            }
            func work() {
                var local = Set<PeerKey>()
                let other: [PeerKey: Int] = [:]
            }
        }
        """
        let found = try storedPeerKeyCollections(in: [SourceFile(path: "sample", text: sample)])
        XCTAssertEqual(found, [
            "Sample.byKey",
            "Sample.keys",
            "Sample.named",
            "Sample.wrapped",
            "Nested.inner",
        ])
    }

    func testNoStoredPeerKeyCollectionOutsidePeerSet() throws {
        let found = try storedPeerKeyCollections(in: runtimeSources())
            .filter { !Self.allowlist.contains($0) }
        XCTAssertEqual(
            found, [],
            "per-peer state belongs in a PeerSet record (PeerSet.swift)"
        )
    }
}
