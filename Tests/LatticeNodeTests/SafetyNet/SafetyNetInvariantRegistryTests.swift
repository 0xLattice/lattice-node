import Foundation
import XCTest

/// Structural gate: every claim in `docs/correctness-invariants.md` is
/// established by a test or names the issue that will establish it.
///
/// A claim is a bullet `- **NODE-AREA-NNN.x** — …` under its invariant's
/// heading. A test establishes it with `/// Establishes: NODE-AREA-NNN.x`
/// (several claims comma-separated) in the doc comment of a zero-argument
/// `test` method declared directly in an XCTest class. A claim no test
/// establishes carries an indented `Gap: #N` line.
///
/// The gate fails on: a claim with neither or with both (the gap closed:
/// remove the marker); a claim outside its heading or declared twice; a gap
/// naming no issue, outside any claim, or not indented under one (a claim's
/// own lines are indented; a heading, a list item or a line at column 0
/// ends it); a claim-shaped ID anywhere but a well-formed claim bullet, so a
/// malformed bullet cannot silently drop out;
/// an annotation naming no claim or not on a test method; two `Establishes`
/// lines in one doc comment (how an inserted test steals its neighbour's
/// annotation); and an `Established by` line, which would restate the
/// annotations in prose.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetInvariantRegistryTests: XCTestCase {

    struct Claim: Equatable {
        let id: String
        let gaps: [Int]
    }

    struct Annotation: Equatable {
        let claim: String
        /// `path:line` of the annotation.
        let site: String
        /// The test method it documents; nil when it documents anything else.
        let test: String?
    }

    /// Every pattern, compiled once per parse.
    private struct Patterns {
        let heading: NSRegularExpression
        let bullet: NSRegularExpression
        let claimID: NSRegularExpression
        let gap: NSRegularExpression
        let issue: NSRegularExpression
        let establishedBy: NSRegularExpression
        let establishes: NSRegularExpression
        let testMethod: NSRegularExpression
        let typeOpener: NSRegularExpression
        let testClass: NSRegularExpression

        init() throws {
            heading = try NSRegularExpression(pattern: #"^## (NODE-[A-Z0-9]+-\d{3}) "#)
            bullet = try NSRegularExpression(pattern: #"^- \*\*(NODE-[A-Z0-9]+-\d{3})\.([a-z])\*\* "#)
            claimID = try NSRegularExpression(pattern: #"NODE-\w+-\d+\.\w+"#)
            gap = try NSRegularExpression(pattern: #"^\s+Gap:"#)
            issue = try NSRegularExpression(pattern: #"#(\d+)\b"#)
            establishedBy = try NSRegularExpression(
                pattern: #"^[\W_]*established[\s_-]*by(?![a-z])"#,
                options: [.caseInsensitive]
            )
            establishes = try NSRegularExpression(pattern: #"^\s*/// Establishes: (.+)$"#)
            testMethod = try NSRegularExpression(
                pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:override\s+)?func (test\w+)\s*\(\s*\)"#
            )
            typeOpener = try NSRegularExpression(
                pattern: #"\b(?:class|struct|enum|actor|extension)\s+\w+[^{]*\{"#
            )
            testClass = try NSRegularExpression(pattern: #"\bclass\s+\w+\s*:\s*\w*TestCase\b"#)
        }

        func first(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }

        func all(_ regex: NSRegularExpression, _ line: String) -> [NSTextCheckingResult] {
            regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        }
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }

    // MARK: - Parsing

    /// The claims in `doc`, with the problems found while reading them.
    static func claims(in doc: String) throws -> (claims: [Claim], problems: [String]) {
        let patterns = try Patterns()
        var claims: [Claim] = []
        var problems: [String] = []
        var heading: String?
        var current: Claim?
        func finish() {
            if let current { claims.append(current) }
            current = nil
        }
        for (index, line) in doc.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            if patterns.first(patterns.establishedBy, line) != nil {
                problems.append("line \(lineNumber): an Established-by line restates the annotations")
            }
            if let match = patterns.first(patterns.heading, line) {
                finish()
                heading = group(match, 1, in: line)
            } else if let match = patterns.first(patterns.bullet, line) {
                finish()
                let invariant = group(match, 1, in: line)
                let id = invariant + "." + group(match, 2, in: line)
                if invariant != heading {
                    problems.append("\(id): not under its heading ## \(invariant)")
                }
                current = Claim(id: id, gaps: [])
                continue
            } else if patterns.first(patterns.gap, line) != nil {
                guard let open = current else {
                    problems.append("line \(lineNumber): a Gap line outside any claim")
                    continue
                }
                let numbers = patterns.all(patterns.issue, line)
                    .compactMap { Int(group($0, 1, in: line)) }
                if numbers.isEmpty {
                    problems.append("\(open.id): its Gap names no issue")
                }
                current = Claim(id: open.id, gaps: open.gaps + numbers)
            } else if line.hasPrefix("Gap:") {
                finish()
                problems.append("line \(lineNumber): a Gap line not indented under its claim")
            } else if let first = line.first, !first.isWhitespace {
                // A claim's own lines are indented. Anything at column 0 (a
                // heading, a list item, prose) ends it.
                finish()
            }
            // Only a well-formed bullet may carry a claim ID: a malformed one
            // would otherwise drop its claim out of the registry silently.
            if let match = patterns.first(patterns.claimID, line) {
                let id = Range(match.range, in: line).map { String(line[$0]) } ?? ""
                problems.append("line \(lineNumber): \(id) outside a well-formed claim bullet")
            }
        }
        finish()
        var seen = Set<String>()
        for claim in claims where !seen.insert(claim.id).inserted {
            problems.append("\(claim.id): declared twice")
        }
        return (claims, problems)
    }

    /// Every `/// Establishes:` doc comment in `files`, with the test method
    /// it documents: a zero-argument `test…` method whose innermost
    /// enclosing scope is an XCTest class. An annotation-shaped line inside
    /// a string literal is text; one inside a block comment documents
    /// nothing, since its declaration is read from the comment-free view.
    static func annotations(in files: [SourceFile]) throws -> [Annotation] {
        let patterns = try Patterns()
        var found: [Annotation] = []
        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            let commentless = SwiftSource.blankingComments(file.text).components(separatedBy: "\n")
            let code = SwiftSource.code(file.text).components(separatedBy: "\n")
            // The innermost scope at the start of each line: true when it is
            // the body of an XCTest class.
            var scopes: [Bool] = []
            var inTestClassBody: [Bool] = []
            for line in code {
                inTestClassBody.append(scopes.last ?? false)
                var opensTestClass: Bool?
                if patterns.first(patterns.typeOpener, line) != nil {
                    opensTestClass = patterns.first(patterns.testClass, line) != nil
                }
                for character in line {
                    if character == "{" {
                        scopes.append(opensTestClass ?? false)
                        opensTestClass = nil
                    } else if character == "}" {
                        _ = scopes.popLast()
                    }
                }
            }
            for (index, line) in lines.enumerated() {
                guard let match = patterns.first(patterns.establishes, line),
                      commentless[index].allSatisfy(\.isWhitespace) else { continue }
                // The documented declaration: the next line that is neither a
                // doc comment nor an attribute on a line of its own.
                var next = index + 1
                while next < lines.count {
                    let trimmed = lines[next].trimmingCharacters(in: .whitespaces)
                    let attributeOnly = trimmed.hasPrefix("@") && !trimmed.contains("func ")
                    guard trimmed.hasPrefix("///") || attributeOnly else { break }
                    next += 1
                }
                var test: String?
                if next < lines.count, inTestClassBody[next],
                   let method = patterns.first(patterns.testMethod, commentless[next]) {
                    test = group(method, 1, in: commentless[next])
                }
                for claim in group(match, 1, in: line).split(separator: ",") {
                    found.append(Annotation(
                        claim: claim.trimmingCharacters(in: .whitespaces),
                        site: "\(file.path):\(index + 1)",
                        test: test
                    ))
                }
            }
        }
        return found
    }

    /// `path:line` of every `/// Establishes:` line followed, within the same
    /// doc comment, by another. That is how a test inserted between an
    /// existing annotation and its method steals the annotation: the gate
    /// cannot otherwise tell, since the claim stays established.
    static func stackedAnnotations(in files: [SourceFile]) throws -> [String] {
        let patterns = try Patterns()
        var found: [String] = []
        for file in files {
            let lines = file.text.components(separatedBy: "\n")
            let commentless = SwiftSource.blankingComments(file.text).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where patterns.first(patterns.establishes, line) != nil
                && commentless[index].allSatisfy(\.isWhitespace) {
                var next = index + 1
                while next < lines.count,
                      lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                    if patterns.first(patterns.establishes, lines[next]) != nil {
                        found.append("\(file.path):\(index + 1)")
                        break
                    }
                    next += 1
                }
            }
        }
        return found
    }

    /// What the registry rejects, given the parsed claims and annotations.
    static func problems(claims: [Claim], annotations: [Annotation]) -> [String] {
        let known = Set(claims.map(\.id))
        var problems: [String] = []
        for annotation in annotations {
            if !known.contains(annotation.claim) {
                problems.append("\(annotation.site): establishes unknown claim \(annotation.claim)")
            }
            if annotation.test == nil {
                problems.append("\(annotation.site): Establishes is not on a test method")
            }
        }
        let establishing = Dictionary(grouping: annotations.filter { $0.test != nil }, by: \.claim)
        for claim in claims {
            let tests = establishing[claim.id] ?? []
            if tests.isEmpty && claim.gaps.isEmpty {
                problems.append("\(claim.id): no test establishes it and it names no gap")
            }
            if !tests.isEmpty && !claim.gaps.isEmpty {
                let names = tests.compactMap(\.test).joined(separator: ", ")
                problems.append("\(claim.id): established by \(names) but still marks a gap; remove the Gap line")
            }
        }
        return problems
    }

    // MARK: - Self-tests

    private static let fixtureDoc = """
        # Correctness invariants

          Gap: #1

        ## NODE-SAMPLE-001 — a sample

        - **NODE-SAMPLE-001.a** — established.
        - **NODE-SAMPLE-001.b** — a gap,
          wrapped over two lines.
          Gap: #12, #34
        - **NODE-SAMPLE-001.c** — neither.
        * **NODE-SAMPLE-001.e** — a malformed bullet ends the claim above.
          Gap: #99
        -  **NODE-SAMPLE-001.f** — two spaces: also malformed.

        ## NODE-SAMPLE-002 — another

        - **NODE-SAMPLE-001.d** — under the wrong heading.
          Gap: #5
        - **NODE-SAMPLE-002.a** — both.
          Gap: #7
        - **NODE-SAMPLE-002.a** — twice.
          Gap: soon

        ## NODE-P2P-003 — an area with a digit

        - **NODE-P2P-003.a** — well formed.
          Gap: #8
        **Established by:** SomeTests
        - **NODE-P2P-003.b** — prose ends a claim.
        Prose at column 0 ends the claim above.
          Gap: #21
        - **NODE-P2P-003.c** — a subheading ends a claim.
        ### Notes
          Gap: #22
        - **NODE-P2P-003.d** — a numbered item ends a claim.
        1. an item
          Gap: #23
        - **NODE-P2P-003.e** — an unindented gap is not its gap.
        Gap: #24
        _Established-by_ SomeTests
        """

    private static let fixtureTests = """
        final class SampleTests: XCTestCase {
            /// Establishes: NODE-SAMPLE-001.a, NODE-SAMPLE-002.a
            @MainActor
            func testEstablishes() {}

            /// Establishes: NODE-SAMPLE-009.z
            func testUnknownClaim() {}

            /// Establishes: NODE-SAMPLE-001.a
            func helper() {}

            /// Establishes: NODE-SAMPLE-001.a
            @MainActor func testInlineAttribute() async throws {}

            /// Establishes: NODE-SAMPLE-001.a
            func testWithAnArgument(_ value: Int) {}

            struct Nested {
                /// Establishes: NODE-SAMPLE-001.a
                func testInANestedType() {}
            }

            /*
            /// Establishes: NODE-SAMPLE-001.a
            func testCommentedOut() {}
            */

            /// Establishes: NODE-SAMPLE-001.a
            override func testOverridden() {}
        }

        /// Establishes: NODE-SAMPLE-001.a
        func testFreeFunction() {}

        class SubclassTests: SampleTestCase {
            /// Establishes: NODE-SAMPLE-001.b
            func testInASubclass() {}

            /// Establishes: NODE-SAMPLE-001.b

            func testAfterABlankLine() {}
        }
        """

    func testClaimParserReadsBulletsGapsAndRejectsMalformedOnes() throws {
        let parsed = try Self.claims(in: Self.fixtureDoc)
        XCTAssertEqual(parsed.claims, [
            Claim(id: "NODE-SAMPLE-001.a", gaps: []),
            Claim(id: "NODE-SAMPLE-001.b", gaps: [12, 34]),
            Claim(id: "NODE-SAMPLE-001.c", gaps: []),
            Claim(id: "NODE-SAMPLE-001.d", gaps: [5]),
            Claim(id: "NODE-SAMPLE-002.a", gaps: [7]),
            Claim(id: "NODE-SAMPLE-002.a", gaps: []),
            Claim(id: "NODE-P2P-003.a", gaps: [8]),
            Claim(id: "NODE-P2P-003.b", gaps: []),
            Claim(id: "NODE-P2P-003.c", gaps: []),
            Claim(id: "NODE-P2P-003.d", gaps: []),
            Claim(id: "NODE-P2P-003.e", gaps: []),
        ])
        XCTAssertEqual(parsed.problems, [
            "line 3: a Gap line outside any claim",
            "line 12: NODE-SAMPLE-001.e outside a well-formed claim bullet",
            "line 13: a Gap line outside any claim",
            "line 14: NODE-SAMPLE-001.f outside a well-formed claim bullet",
            "NODE-SAMPLE-001.d: not under its heading ## NODE-SAMPLE-001",
            "NODE-SAMPLE-002.a: its Gap names no issue",
            "line 29: an Established-by line restates the annotations",
            "line 32: a Gap line outside any claim",
            "line 35: a Gap line outside any claim",
            "line 38: a Gap line outside any claim",
            "line 40: a Gap line not indented under its claim",
            "line 41: an Established-by line restates the annotations",
            "NODE-SAMPLE-002.a: declared twice",
        ])
    }

    func testAnnotationScanFindsDocCommentsOnZeroArgumentTestMethodsOnly() throws {
        let found = try Self.annotations(in: [SourceFile(path: "t", text: Self.fixtureTests)])
        XCTAssertEqual(found, [
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:2", test: "testEstablishes"),
            Annotation(claim: "NODE-SAMPLE-002.a", site: "t:2", test: "testEstablishes"),
            Annotation(claim: "NODE-SAMPLE-009.z", site: "t:6", test: "testUnknownClaim"),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:9", test: nil),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:12", test: "testInlineAttribute"),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:15", test: nil),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:19", test: nil),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:24", test: nil),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:28", test: "testOverridden"),
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:32", test: nil),
            Annotation(claim: "NODE-SAMPLE-001.b", site: "t:36", test: "testInASubclass"),
            // A blank line ends the declaration search: it documents nothing.
            Annotation(claim: "NODE-SAMPLE-001.b", site: "t:39", test: nil),
        ])
    }

    func testTwoEstablishesLinesInOneDocCommentAreFlagged() throws {
        let stacked = SourceFile(path: "s", text: """
            final class StackedTests: XCTestCase {
                /// Establishes: NODE-SAMPLE-001.a
                /// A sentence between them.
                /// Establishes: NODE-SAMPLE-001.a
                func testNew() {}

                /// Establishes: NODE-SAMPLE-001.b, NODE-SAMPLE-001.c
                func testOld() {}
            }
            """)
        XCTAssertEqual(try Self.stackedAnnotations(in: [stacked]), ["s:2"])
    }

    /// An annotation-shaped line inside a string literal (a fixture like the
    /// ones above) is text, not a doc comment.
    func testAnnotationInsideAStringLiteralIsText() throws {
        let embedded = SourceFile(path: "e", text: """
            final class EmbeddingTests: XCTestCase {
                let fixture = \"\"\"
                    /// Establishes: NODE-SAMPLE-001.c
                    func testInsideTheString() {}
                    \"\"\"
            }
            """)
        XCTAssertEqual(try Self.annotations(in: [embedded]), [])
    }

    func testRegistryRejectsEveryBrokenLink() throws {
        let claims = [
            Claim(id: "NODE-SAMPLE-001.a", gaps: []),
            Claim(id: "NODE-SAMPLE-001.b", gaps: [12]),
            Claim(id: "NODE-SAMPLE-001.c", gaps: []),
            Claim(id: "NODE-SAMPLE-002.a", gaps: [7]),
        ]
        let annotations = [
            Annotation(claim: "NODE-SAMPLE-001.a", site: "t:1", test: "testA"),
            Annotation(claim: "NODE-SAMPLE-002.a", site: "t:1", test: "testA"),
            Annotation(claim: "NODE-SAMPLE-009.z", site: "t:2", test: "testB"),
            // Not on a test method: it neither establishes 001.c nor counts.
            Annotation(claim: "NODE-SAMPLE-001.c", site: "t:3", test: nil),
        ]
        XCTAssertEqual(Self.problems(claims: claims, annotations: annotations), [
            "t:2: establishes unknown claim NODE-SAMPLE-009.z",
            "t:3: Establishes is not on a test method",
            "NODE-SAMPLE-001.c: no test establishes it and it names no gap",
            "NODE-SAMPLE-002.a: established by testA but still marks a gap; remove the Gap line",
        ])
    }

    // MARK: - Gate

    private func liveClaims() throws -> (claims: [Claim], problems: [String]) {
        let url = SourceTree.packageRoot.appendingPathComponent("docs/correctness-invariants.md")
        return try Self.claims(in: try String(contentsOf: url, encoding: .utf8))
    }

    func testGateSeesTheClaimsAndTheAnnotations() throws {
        let claims = try liveClaims().claims
        let annotations = try Self.annotations(in: SourceTree.swiftFiles(under: "Tests"))
        XCTAssertGreaterThan(claims.count, 40, "read \(claims.count) claims")
        XCTAssertGreaterThan(
            Set(annotations.map(\.claim)).count, 15,
            "found annotations for \(Set(annotations.map(\.claim)).count) claims"
        )
    }

    func testEveryClaimIsEstablishedOrNamesItsGap() throws {
        let parsed = try liveClaims()
        XCTAssertEqual(parsed.problems, [], "docs/correctness-invariants.md")
        XCTAssertEqual(
            try Self.stackedAnnotations(in: SourceTree.swiftFiles(under: "Tests")),
            [],
            "one doc comment carries two Establishes lines: put its claims on one line"
        )
        XCTAssertEqual(
            Self.problems(
                claims: parsed.claims,
                annotations: try Self.annotations(in: SourceTree.swiftFiles(under: "Tests"))
            ),
            []
        )
    }
}
