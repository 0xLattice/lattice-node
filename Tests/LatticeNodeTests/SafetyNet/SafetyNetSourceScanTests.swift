import Foundation
import XCTest

/// The lexer and walker every structural gate stands on
/// (`Support/SourceScan.swift`). A lexer that hides code from a gate turns
/// a violation into a pass, so each case below is one a naive strip gets
/// wrong. Expectations compare the view's tokens (whitespace-separated), so
/// a case reads as the code a gate would see.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetSourceScanTests: XCTestCase {

    private func tokens(_ view: String) -> String {
        view.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Every view keeps the text's length and newlines, and only ever
    /// replaces characters with spaces.
    private func assertOnlyBlanks(
        _ view: String,
        of text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = Array(text)
        let viewed = Array(view)
        XCTAssertEqual(viewed.count, source.count, "length changed", file: file, line: line)
        for (offset, pair) in zip(source, viewed).enumerated() where pair.0 != pair.1 {
            XCTAssertEqual(pair.1, " ", "offset \(offset) became \(pair.1)", file: file, line: line)
            XCTAssertFalse(pair.0.isNewline, "offset \(offset) lost a newline", file: file, line: line)
        }
    }

    private func code(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let view = SwiftSource.code(text)
        assertOnlyBlanks(view, of: text, file: file, line: line)
        return tokens(view)
    }

    private func commentless(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let view = SwiftSource.blankingComments(text)
        assertOnlyBlanks(view, of: text, file: file, line: line)
        return tokens(view)
    }

    func testCommentsAreBlankedInBothViews() {
        let text = """
        let a = 1 // Task.sleep
        /// doc Task.sleep
        x /* a /* nested */ still comment */ y
        b /*
          spans lines
        */ c
        """
        XCTAssertEqual(code(text), "let a = 1 x y b c")
        XCTAssertEqual(commentless(text), "let a = 1 x y b c")
        XCTAssertEqual(SwiftSource.code(text).components(separatedBy: "\n").count, 6)
    }

    func testCommentMarkersInsideAStringAreText() {
        let text = #"let u = "http://x /* y"; call()"#
        XCTAssertEqual(code(text), #"let u = " "; call()"#)
        XCTAssertEqual(commentless(text), text)
    }

    func testAQuoteInsideACommentOpensNothing() {
        let text = "// say \"hi\nlet live = 1"
        XCTAssertEqual(code(text), "let live = 1")
    }

    func testEscapesNeverEndTheString() {
        // `"\\"` ends at its second quote: a lexer that reads `\"` as an
        // escaped quote hides everything after it on the line.
        XCTAssertEqual(SwiftSource.code(#"f("\\", x)"#), #"f("  ", x)"#)
        XCTAssertEqual(code(#"let s = "\\"; hidden()"#), #"let s = " "; hidden()"#)
        XCTAssertEqual(code(#"let q = "a\"b"; hidden()"#), #"let q = " "; hidden()"#)
        XCTAssertEqual(code(#"let t = "\\\""; hidden()"#), #"let t = " "; hidden()"#)
    }

    func testInterpolationsAreCode() {
        XCTAssertEqual(
            code(#"log("tip \(hierarchyState.tip + f(1, 2)) done")"#),
            #"log(" hierarchyState.tip + f(1, 2) ")"#
        )
    }

    func testAStringInsideAnInterpolationIsAString() {
        // The inner `"k//"` is a string (its `//` is text); the outer
        // literal's `// c` is string content, not a comment.
        let text = #"let a = "\(d["k//"]) // c"; w()"#
        XCTAssertEqual(code(text), #"let a = " d[" "] "; w()"#)
        XCTAssertEqual(commentless(text), tokens(text))
    }

    func testMultilineStrings() {
        let text = #"""
        let m = """
            a "quoted" "" line \(value)
            // not a comment
            """; after()
        """#
        XCTAssertEqual(code(text), #"let m = """ value """; after()"#)
        XCTAssertEqual(commentless(text), tokens(text))
    }

    func testRawStrings() {
        XCTAssertEqual(
            code(##"let r = #"a "b" \(notCode) \#(isCode)"#; t()"##),
            ##"let r = #" isCode "#; t()"##
        )
        XCTAssertEqual(
            code(###"let r = ##"x"#y \#(no) \##(yes)"##; t()"###),
            ###"let r = ##" yes "##; t()"###
        )
    }

    func testRawMultilineStrings() {
        // `#"""` opens a multiline raw string: its closing line is `"""#`,
        // and a `"""` or `\(x)` inside is text.
        let text = ##"""
        let s = #"""
            a """ "q" \(notCode) \#(isCode)
            """#
        Task.sleep(1)
        """##
        XCTAssertEqual(code(text), ##"let s = #""" isCode """# Task.sleep(1)"##)
    }

    func testDirectivesAreNotStrings() {
        XCTAssertEqual(code("#if DEBUG\nlet s = #selector(run)\n#endif"), "#if DEBUG let s = #selector(run) #endif")
    }

    func testAnUnterminatedStringStopsAtItsLine() {
        XCTAssertEqual(code("let bad = \"oops\nlet good = 1"), "let bad = \" let good = 1")
    }

    func testMatchingLinesReadsTheViewAndPrintsTheSource() throws {
        let file = SourceFile(path: "f.swift", text: """
            Task.sleep(1) // comment
            // Task.sleep in a comment
            let s = "Task.sleep in a string"
            """)
        XCTAssertEqual(
            try SwiftSource.matchingLines(#"Task\.sleep"#, in: [file], view: SwiftSource.code),
            ["f.swift:1: Task.sleep(1) // comment"]
        )
        XCTAssertEqual(
            try SwiftSource.matchingLines(#"Task\.sleep"#, in: [file], view: SwiftSource.blankingComments),
            [
                "f.swift:1: Task.sleep(1) // comment",
                "f.swift:3: let s = \"Task.sleep in a string\"",
            ]
        )
    }

    func testWalkerReadsNestedFilesSortedAndRelative() throws {
        let files = try SourceTree.swiftFiles(under: "Sources/LatticeNode")
        let paths = files.map(\.path)
        XCTAssertEqual(paths, paths.sorted())
        XCTAssertTrue(paths.contains("Runtime/Timers.swift"), "walked \(paths.count) files")
        XCTAssertTrue(paths.contains("Storage/NodeStoreRow.swift"), "subdirectories are walked")
    }

    func testWalkerRefusesAnEmptyOrMissingDirectory() {
        XCTAssertThrowsError(try SourceTree.swiftFiles(under: "Sources/NoSuchDirectory")) {
            XCTAssertTrue($0 is SourceTree.NoSources)
        }
    }

    /// Where a regex literal can start. Swift reads a `/` as binary after an
    /// operand (a word character, `)`, `]` or `}`), so the rule excludes that
    /// rather than listing where a regex may start:
    /// - a `/` not after an operand, and not followed by whitespace, `/`,
    ///   `*`, `)`, the end of the line, or `=` and a space (compound `/=`);
    /// - a spaced `/=` whose nearest non-space on the left is not an operand
    ///   (`= /= "a"/` is a regex, `x /= 2` is not);
    /// - `#/` anywhere.
    /// Force-unwrap division (`x!/2`, `x! /= 2`) and an operator declared
    /// with no space before its parameters (`func /(`) match, which fails
    /// loudly. Missed, as unlikely and harmless beyond one line: a regex
    /// glued to a keyword (`in/x/`, `return/x/`, `try/x/`), and `#//…/#`,
    /// whose `//` the lexer already blanks as a comment.
    private static let regexLiteralStart =
        #"(?:^|[^\w)\]}])#*/(?![\s/*)]|=\s|=$|$)|(?:^|[^\w)\]}\s])\s*#*/=(?:\s|$)|#/"#

    /// Characters the lexer matches on. Fused into one grapheme with another
    /// scalar, one of them is invisible to a lexer that walks `Character`s.
    private static let lexedScalars: Set<Unicode.Scalar> = ["\"", "#", "/", "*", "\\", "(", ")"]

    /// Newline-like scalars other than `\n` and `\r`: `Character.isNewline`
    /// accepts them, so one inside a string would end it early.
    private static let otherSeparators: Set<Unicode.Scalar> = [
        "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    func testRegexLiteralPatternFindsEveryStartAndNoDivision() throws {
        let starts = [
            ".contains(/x/)", "a ?? /x/", "s.map { /x/ }", "case /x/:", "if /x/ ~= s {",
            "try /x/.wholeMatch(in: s)", "await /x/", "!/x/", "a&&/x/", "return /x/",
            "[/a/, /b/]", "c ? /a/ : /b/", "let r = #/a b/#", "/x/.firstMatch(in: s)",
            "let r = /=+/", "x == /=/", "-/x/", "a + /x/", "</x/", "%/x/", "~/x/",
            "let r = /= \"a\"/", "x ?? /= b/",
            // Reachable only through `#/`: its `/` is followed by a space.
            "x.firstMatch(of: #/ a/#)",
        ]
        for start in starts {
            XCTAssertEqual(
                try SwiftSource.matchingLines(
                    Self.regexLiteralStart,
                    in: [SourceFile(path: "s", text: start)],
                    view: SwiftSource.code
                ).count,
                1,
                start
            )
        }
        let division = [
            "let q = b/c", "let q = b / c", "x /= 2", "x/=2", "let t = (a +\n    b) / 2",
            "f(a /* c */, b)", "(a)/2", "a[0]/2", "s.count/2", "reduce(1, /)",
            "let r = x /\n    2", "x.map { $0 }/2",
        ]
        for text in division {
            XCTAssertEqual(
                try SwiftSource.matchingLines(
                    Self.regexLiteralStart,
                    in: [SourceFile(path: "d", text: text)],
                    view: SwiftSource.code
                ),
                [],
                text
            )
        }
    }

    /// What the lexer does not model (see `SwiftSource`) is absent from what
    /// the gates read, so none of it can hide code from a gate.
    func testSourcesHoldNothingTheLexerDoesNotModel() throws {
        let files = try SourceTree.swiftFiles(under: "Sources")
        XCTAssertEqual(
            try SwiftSource.matchingLines(Self.regexLiteralStart, in: files, view: SwiftSource.code),
            [],
            "regex literal: teach SourceScan to lex it before a gate reads it"
        )
        var unmodelled: [String] = []
        for file in files {
            if file.text.unicodeScalars.contains(where: Self.otherSeparators.contains) {
                unmodelled.append("\(file.path): a newline-like separator other than \\n or \\r")
            }
            if file.text.contains(where: {
                $0.unicodeScalars.count > 1 && $0.unicodeScalars.contains(where: Self.lexedScalars.contains)
            }) {
                unmodelled.append("\(file.path): a lexed character fused into a grapheme")
            }
        }
        XCTAssertEqual(unmodelled, [], "teach SourceScan to lex these before a gate reads them")
    }

    /// A view that blanks too much passes every law below, so real code is
    /// checked to survive: in the package sources, a line that declares a
    /// function (after any attributes and modifiers) or an import is code,
    /// and the code view keeps it up to its first string literal or comment.
    func testCodeViewKeepsDeclarationsOfThePackageSources() throws {
        let declaration = try NSRegularExpression(
            pattern: #"^(?:@?\w+(?:\([^)]*\))?\s+)*(?:func|import)\s"#
        )
        var checked = 0
        for file in try SourceTree.swiftFiles(under: "Sources") {
            let viewed = SwiftSource.code(file.text).components(separatedBy: "\n")
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                guard declaration.firstMatch(in: trimmed, range: range) != nil else { continue }
                let code = trimmed.prefix { $0 != "\"" }.components(separatedBy: " //")[0]
                XCTAssertTrue(
                    viewed[index].contains(code),
                    "\(file.path):\(index + 1): code view lost \(code)"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1_000, "checked \(checked) declaration lines")
    }

    /// Laws over every Swift file the gates could read: both views only
    /// blank; blanking comments twice changes nothing; and the code view of
    /// the comment-free view is the code view.
    func testViewLawsHoldOverTheWholePackage() throws {
        let files = try SourceTree.swiftFiles(under: "Sources")
            + SourceTree.swiftFiles(under: "Tests")
        XCTAssertGreaterThan(files.count, 50, "walked \(files.count) files")
        for file in files {
            let commentless = SwiftSource.blankingComments(file.text)
            let code = SwiftSource.code(file.text)
            assertOnlyBlanks(commentless, of: file.text)
            assertOnlyBlanks(code, of: file.text)
            XCTAssertEqual(SwiftSource.blankingComments(commentless), commentless, file.path)
            XCTAssertEqual(SwiftSource.code(commentless), code, file.path)
        }
    }
}

/// The hierarchy plane is gone: a child reads its parent in-process and
/// takes child-block proofs from the overlay. No source names a topic on it.
final class SafetyNetNoHierarchyPlaneTests: XCTestCase {
    func testNoSourceNamesAHierarchyTopic() throws {
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Sources") {
            for (number, line) in file.text.components(separatedBy: "\n")
                .enumerated() where line.contains("lattice.hierarchy.") {
                offenders.append("\(file.path):\(number + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "a hierarchy topic reappeared")
    }
}
