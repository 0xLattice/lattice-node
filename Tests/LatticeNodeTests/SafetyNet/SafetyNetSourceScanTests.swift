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
        let files = try SourceTree.swiftFiles(under: "Sources/LatticeNode/Architecture")
        let paths = files.map(\.path)
        XCTAssertEqual(paths, paths.sorted())
        XCTAssertTrue(paths.contains("Timers.swift"), "walked \(paths.count) files")
        XCTAssertTrue(paths.contains("Storage/NodeStoreRow.swift"), "subdirectories are walked")
    }

    func testWalkerRefusesAnEmptyOrMissingDirectory() {
        XCTAssertThrowsError(try SourceTree.swiftFiles(under: "Sources/NoSuchDirectory")) {
            XCTAssertTrue($0 is SourceTree.NoSources)
        }
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
