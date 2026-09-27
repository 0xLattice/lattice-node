import Foundation
import XCTest

/// Structural gate over `Sources/LatticeNode/Architecture`: no actor
/// initializer takes an `@escaping` closure. An actor reaches its
/// collaborators through an interface (`NetworkInterface`, `ChainInterface`)
/// whose weak adapter owns the nil fallback, instead of through a bag of
/// closures that each re-state it.
///
/// `StaleTipPeerSearch` predates the gate: its closures are the test seam
/// for a clock and the runtime's peer sets, and it is listed as the one
/// known exception until it takes an interface too.
///
/// Comments and string literals are blanked before scanning. Initializers of
/// types nested in an actor are not the actor's and are not scanned.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetActorInitGateTests: XCTestCase {

    private static let architectureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SafetyNet
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/LatticeNode/Architecture")

    /// Files whose actor initializers may still take closures.
    private static let knownExceptions: Set<String> = ["StaleTipPeerSearch.swift"]

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

    /// `text` with comments and string-literal contents replaced by spaces
    /// (newlines kept), so braces and parentheses left are code.
    private static func blanked(_ text: String) -> [Character] {
        let chars = Array(text)
        var out = chars
        var index = 0
        func blank(_ i: Int) { if out[i] != "\n" { out[i] = " " } }
        func at(_ i: Int, _ s: String) -> Bool {
            let needle = Array(s)
            guard i + needle.count <= chars.count else { return false }
            return Array(chars[i..<(i + needle.count)]) == needle
        }
        while index < chars.count {
            if at(index, "//") {
                while index < chars.count, chars[index] != "\n" { blank(index); index += 1 }
            } else if at(index, "/*") {
                var depth = 0
                repeat {
                    if at(index, "/*") { depth += 1; blank(index); blank(index + 1); index += 2 }
                    else if at(index, "*/") { depth -= 1; blank(index); blank(index + 1); index += 2 }
                    else { blank(index); index += 1 }
                } while depth > 0 && index < chars.count
            } else if chars[index] == "\"" {
                let delimiter = at(index, "\"\"\"") ? "\"\"\"" : "\""
                index += delimiter.count
                var interpolation = 0
                while index < chars.count {
                    if interpolation == 0 {
                        if chars[index] == "\\", at(index + 1, "(") {
                            blank(index); interpolation = 1; index += 2
                        } else if chars[index] == "\\" {
                            blank(index)
                            if index + 1 < chars.count { blank(index + 1) }
                            index += 2
                        } else if at(index, delimiter) {
                            index += delimiter.count
                            break
                        } else {
                            blank(index); index += 1
                        }
                    } else {
                        if chars[index] == "(" { interpolation += 1 }
                        if chars[index] == ")" { interpolation -= 1 }
                        blank(index); index += 1
                    }
                }
            } else {
                index += 1
            }
        }
        return out
    }

    private static func matchingClose(
        _ code: [Character],
        from open: Int,
        _ opening: Character,
        _ closing: Character
    ) -> Int? {
        var depth = 0
        var index = open
        while index < code.count {
            if code[index] == opening { depth += 1 }
            if code[index] == closing {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// `file:line: init` for every initializer, declared directly in an
    /// actor or in an extension of one, whose parameters include `@escaping`.
    private static func escapingActorInits(
        in files: [(path: String, text: String)]
    ) throws -> [String] {
        let blankedFiles = files.map { (path: $0.path, code: blanked($0.text)) }
        let actorName = try NSRegularExpression(pattern: #"\bactor\s+(\w+)"#)
        var actors = Set<String>()
        for file in blankedFiles {
            let code = String(file.code)
            for match in actorName.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                if let range = Range(match.range(at: 1), in: code) {
                    actors.insert(String(code[range]))
                }
            }
        }
        guard !actors.isEmpty else { return [] }
        let names = actors.sorted().joined(separator: "|")
        let declaration = try NSRegularExpression(
            pattern: #"\b(?:actor|extension)\s+(?:"# + names + #")(?![\w.])[^{]*\{"#
        )
        let initializer = try NSRegularExpression(pattern: #"\binit\s*[?!]?\s*(?:<[^>]*>)?\s*\("#)
        var found: [String] = []
        for file in blankedFiles {
            let code = String(file.code)
            let characters = file.code
            for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range, in: code) else { continue }
                let open = code.distance(from: code.startIndex, to: range.upperBound) - 1
                guard let close = matchingClose(characters, from: open, "{", "}") else { continue }
                // Only the actor body's own depth: skip nested type bodies
                // and function bodies.
                var depth = 0
                var index = open + 1
                while index < close {
                    let character = characters[index]
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                    if depth == 0, character == "i" {
                        let rest = String(characters[index..<min(close, index + 64)])
                        let isWordStart = index == 0
                            || !(characters[index - 1].isLetter || characters[index - 1].isNumber
                                 || characters[index - 1] == "_" || characters[index - 1] == ".")
                        if isWordStart,
                           let hit = initializer.firstMatch(
                               in: rest, range: NSRange(rest.startIndex..., in: rest)
                           ), hit.range.location == 0 {
                            let paren = index + hit.range.length - 1
                            if let end = matchingClose(characters, from: paren, "(", ")"),
                               String(characters[paren...end]).contains("@escaping") {
                                let line = characters[..<index].filter { $0 == "\n" }.count + 1
                                found.append("\(file.path):\(line): init")
                            }
                        }
                    }
                    index += 1
                }
            }
        }
        return found.sorted()
    }

    func testGateSeesTheArchitectureActors() throws {
        let files = try sources()
        let joined = files.map(\.text).joined(separator: "\n")
        XCTAssertTrue(joined.contains("public actor ChainService"), "gate walked \(files.count) files")
        XCTAssertTrue(joined.contains("public actor NodeNetworkRuntime"), "gate walked \(files.count) files")
    }

    func testGateCatchesAnEscapingActorInit() throws {
        let sample = """
        public actor Caught {
            // init(ignored: @escaping () -> Void) in a comment
            let name = "init(alsoIgnored: @escaping () -> Void)"
            struct Nested {
                init(nested: @escaping () -> Void) {}
            }
            public init(
                value: Int,
                callback: @escaping @Sendable () async -> Void = {}
            ) {}
            init(plain: Int, closure: (Int) -> Void) {}
        }
        extension Caught {
            init?(fromExtension: @escaping () -> Void) { return nil }
        }
        final class NotAnActor {
            init(callback: @escaping () -> Void) {}
        }
        """
        let found = try Self.escapingActorInits(in: [(path: "sample", text: sample)])
        XCTAssertEqual(found, ["sample:14: init", "sample:7: init"])
    }

    func testNoActorInitTakesAnEscapingClosure() throws {
        let files = try sources()
        XCTAssertEqual(
            try Self.escapingActorInits(
                in: files.filter { Self.knownExceptions.contains($0.path) }
            ).count,
            Self.knownExceptions.count,
            "a known exception no longer takes a closure; remove it from the list"
        )
        let found = try Self.escapingActorInits(
            in: files.filter { !Self.knownExceptions.contains($0.path) }
        )
        XCTAssertEqual(
            found, [],
            "actor initializer takes an @escaping closure; pass an interface instead"
        )
    }
}
