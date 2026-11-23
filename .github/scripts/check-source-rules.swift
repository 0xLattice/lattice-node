// Source rules the compiler cannot state, checked on the source text.
// Run from anywhere in the repository: `swift .github/scripts/check-source-rules.swift`.
//
// - sleep: only LatticeNodeSupport/Timers.swift suspends on a sleep. Every
//   other site in the runtime modules arms a `Timers` deadline, retry, poll
//   or repeat (`Task.sleep(for:)` / `Clock.sleep(for:)` miscompile under
//   Swift 6.3 -O).
// - raw-column: only LatticeNodeStore/NodeSQLite.swift and NodeStoreRow.swift
//   read a `NodeSQLiteValue` through textValue / intValue / blobValue; every
//   other reader goes through a per-table record. (LatticeNodeStore and
//   LatticeNode only: LatticeCtl and LatticeNodeDaemon read
//   `NSNumber.intValue`.)
// - tier-literal: no execution tier is spelled as an integer; every
//   `accepted_blocks.validated` read and write goes through `BlockStatus`.
// - hierarchy-topic: the hierarchy plane is gone (a child reads its parent
//   in-process); no source names a `lattice.hierarchy.` topic.
// - sync-canonicity: HeaderSync never reads canonicity. The sync sources name
//   no best-chain API; only ChainSelection.swift, execution and templates do.
// - lexer: the sources hold nothing the comment lexer below does not model
//   (regex literals, newline-like separators other than \n and \r, a lexed
//   character fused into a grapheme), so none of it can hide code from a rule.
//
// Comments are skipped by sleep, raw-column and tier-literal (prose may name
// what they forbid). String literals are not: the tier rule is mostly SQL.
// hierarchy-topic and sync-canonicity read the raw text, comments included.

import Foundation

struct SourceFile {
    /// Relative to the repository root.
    let path: String
    let text: String
}

let root: URL = {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["git", "rev-parse", "--show-toplevel"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    if (try? task.run()) != nil {
        task.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if task.terminationStatus == 0, !out.isEmpty { return URL(fileURLWithPath: out) }
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}()

var failed = false

func error(_ path: String, _ line: Int? = nil, _ message: String) {
    let location = line.map { "file=\(path),line=\($0)" } ?? "file=\(path)"
    print("::error \(location)::\(message)")
    failed = true
}

/// Every `.swift` file under `directory` (relative to the root), sorted. A
/// directory with none is an error: a rule over a moved or renamed directory
/// fails instead of passing over nothing.
func swiftFiles(under directory: String) -> [SourceFile] {
    let base = root.appendingPathComponent(directory)
    let paths = (FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? [])
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    if paths.isEmpty { error(directory, nil, "no Swift sources under \(directory): update check-source-rules.swift") }
    return paths.compactMap { relative in
        let path = directory + "/" + relative
        guard let text = try? String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8) else {
            error(path, nil, "unreadable as UTF-8")
            return nil
        }
        return SourceFile(path: path, text: text)
    }
}

func require(_ path: String, in files: [SourceFile]) {
    if !files.contains(where: { $0.path == path }) {
        error(path, nil, "missing: a source rule names this file; update check-source-rules.swift")
    }
}

/// (line number, source line) for every line of `file` whose `view` matches `pattern`.
func matches(_ pattern: String, in file: SourceFile, view: (String) -> String) -> [(Int, String)] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let viewed = view(file.text).components(separatedBy: "\n")
    let source = file.text.components(separatedBy: "\n")
    return viewed.enumerated().compactMap { index, line in
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
            ? nil : (index + 1, source[index].trimmingCharacters(in: .whitespaces))
    }
}

func forbid(_ pattern: String, in files: [SourceFile], view: (String) -> String, _ message: String) {
    for file in files {
        for (line, text) in matches(pattern, in: file, view: view) {
            error(file.path, line, "\(message): \(text)")
        }
    }
}

// MARK: - Views

/// Views of Swift source text. Both keep the text's length in characters and
/// every newline in place, so a line in a view is the same line in the source.
///
/// Not modelled: regex literals (`/…/`, `#/…/#`); a character the lexer
/// matches on (`"`, `#`, `/`, `*`, `\`, `(`, `)`) fused with another scalar
/// into one grapheme; and newline-like separators other than `\n` and `\r`.
/// The lexer walks `Character`s, so each of these can hide code. The `lexer`
/// rule fails if the sources ever contain one: teach the lexer first.
enum SwiftSource {

    /// `text` with every comment replaced by spaces. String literals are kept.
    static func blankingComments(_ text: String) -> String {
        var lexer = Lexer(text, blankStrings: false)
        return lexer.run()
    }

    /// `text` as code: comments and the contents of string literals replaced
    /// by spaces. Quote delimiters and interpolated expressions stay.
    static func code(_ text: String) -> String {
        var lexer = Lexer(text, blankStrings: true)
        return lexer.run()
    }

    /// A single pass over the characters, recursing into string literals and
    /// back out into the code of their interpolations.
    private struct Lexer {
        private let characters: [Character]
        private var output: [Character]
        private let blankStrings: Bool
        private var index = 0

        init(_ text: String, blankStrings: Bool) {
            characters = Array(text)
            output = characters
            self.blankStrings = blankStrings
        }

        mutating func run() -> String {
            code(inInterpolation: false)
            return String(output)
        }

        /// Code up to the end of the text, or, inside an interpolation, up
        /// to the `)` that closes it (left for the caller).
        private mutating func code(inInterpolation: Bool) {
            var parentheses = 0
            while index < characters.count {
                if starts("//") {
                    lineComment()
                } else if starts("/*") {
                    blockComment()
                } else if let opening = stringOpening() {
                    string(opening)
                } else if characters[index] == "(" {
                    parentheses += 1
                    index += 1
                } else if characters[index] == ")" {
                    if inInterpolation && parentheses == 0 { return }
                    parentheses -= 1
                    index += 1
                } else {
                    index += 1
                }
            }
        }

        private mutating func lineComment() {
            while index < characters.count, !characters[index].isNewline {
                blank(index, always: true)
                index += 1
            }
        }

        /// Swift block comments nest.
        private mutating func blockComment() {
            var depth = 0
            repeat {
                if starts("/*") {
                    depth += 1
                    blank(index, always: true)
                    blank(index + 1, always: true)
                    index += 2
                } else if starts("*/") {
                    depth -= 1
                    blank(index, always: true)
                    blank(index + 1, always: true)
                    index += 2
                } else {
                    blank(index, always: true)
                    index += 1
                }
            } while depth > 0 && index < characters.count
        }

        private struct Opening {
            /// The `#`s of a raw string: its escapes and its closing
            /// delimiter carry the same count.
            let hashes: Int
            let multiline: Bool
        }

        /// The string literal that opens at `index`, if one does: optional
        /// `#`s, then `"` or `"""`.
        private func stringOpening() -> Opening? {
            var cursor = index
            while cursor < characters.count, characters[cursor] == "#" { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
            return Opening(hashes: cursor - index, multiline: starts("\"\"\"", at: cursor))
        }

        private mutating func string(_ opening: Opening) {
            let hashes = String(repeating: "#", count: opening.hashes)
            let quotes = opening.multiline ? "\"\"\"" : "\""
            let escape = "\\" + hashes
            index += hashes.count + quotes.count
            while index < characters.count {
                if starts(quotes + hashes) {
                    index += quotes.count + hashes.count
                    return
                }
                if !opening.multiline, characters[index].isNewline {
                    // Unterminated on its line: not valid Swift. Stop here so
                    // one bad literal cannot swallow the rest of the file.
                    return
                }
                if starts(escape) {
                    let escaped = index + escape.count
                    if escaped < characters.count, characters[escaped] == "(" {
                        for offset in 0...escape.count { blank(index + offset) }
                        index = escaped + 1
                        code(inInterpolation: true)
                        if index < characters.count {
                            blank(index)
                            index += 1
                        }
                    } else {
                        // The escape and the character it escapes, so an
                        // escaped quote or backslash never ends the string.
                        for offset in 0...escape.count { blank(index + offset) }
                        index = escaped + 1
                    }
                    continue
                }
                blank(index)
                index += 1
            }
        }

        private func starts(_ text: String, at position: Int? = nil) -> Bool {
            var cursor = position ?? index
            for character in text {
                guard cursor < characters.count, characters[cursor] == character else { return false }
                cursor += 1
            }
            return true
        }

        /// Replaces one character with a space, keeping newlines. String
        /// contents are blanked only in the `code` view; comments always.
        private mutating func blank(_ position: Int, always: Bool = false) {
            guard position < output.count, always || blankStrings, !output[position].isNewline else { return }
            output[position] = " "
        }
    }
}

// MARK: - Rules

let sources = swiftFiles(under: "Sources")

// sleep
do {
    let modules = [
        "LatticeNode", "LatticeNodeConfig", "LatticeNodeCore", "LatticeNodeMining",
        "LatticeNodeNet", "LatticeNodeStore", "LatticeNodeSupport",
    ]
    let timers = "Sources/LatticeNodeSupport/Timers.swift"
    // A direct sleep. `Timers.sleep(` is the sanctioned call, not a site.
    let sleep = #"Task\.sleep|(?<!\bTimers)\.sleep\("#
    let files = sources.filter { file in modules.contains { file.path.hasPrefix("Sources/\($0)/") } }
    require(timers, in: files)
    if let primitive = files.first(where: { $0.path == timers }),
       matches(sleep, in: primitive, view: SwiftSource.blankingComments).isEmpty {
        error(timers, nil, "the sleep rule no longer finds the primitive itself: update its pattern")
    }
    forbid(sleep, in: files.filter { $0.path != timers }, view: SwiftSource.blankingComments,
           "sleep outside \(timers); use Timers")
}

// raw-column, tier-literal
do {
    let files = sources.filter {
        $0.path.hasPrefix("Sources/LatticeNodeStore/") || $0.path.hasPrefix("Sources/LatticeNode/")
    }
    let rowLayer = ["Sources/LatticeNodeStore/NodeSQLite.swift", "Sources/LatticeNodeStore/NodeStoreRow.swift"]
    for path in rowLayer + ["Sources/LatticeNodeStore/BlockStatus.swift"] { require(path, in: files) }
    forbid(#"\.(textValue|intValue|blobValue)\b"#, in: files.filter { !rowLayer.contains($0.path) },
           view: SwiftSource.blankingComments,
           "raw NodeSQLiteValue read outside the row layer; read it through a per-table record")
    for pattern in [
        #"\bvalidated\s*(==|!=|>=|<=|=|<|>|IN)\s*\(?\s*-?[0-9]"#,
        #"validated\s*\?\s*1\s*:\s*0"#,
        #"validated INTEGER NOT NULL DEFAULT [0-9]"#,
    ] {
        forbid(pattern, in: files, view: SwiftSource.blankingComments,
               "execution tier spelled as an integer; use BlockStatus")
    }
}

// hierarchy-topic
forbid(#"lattice\.hierarchy\."#, in: sources, view: { $0 },
       "a hierarchy topic reappeared; a child reads its parent in-process")

// sync-canonicity
do {
    let syncSources = [
        "Sources/LatticeNodeCore/Chain/ChainCore.swift",
        "Sources/LatticeNodeCore/Sync/HeaderSync.swift",
        "Sources/LatticeNodeCore/Sync/SyncProtocol.swift",
    ]
    for path in syncSources { require(path, in: sources) }
    forbid("isCanonical|canonicalTip|canonicalBlockHash|canonicalChain|actOnTip|bestChain",
           in: sources.filter { syncSources.contains($0.path) }, view: { $0 },
           "sync reads canonicity; only ChainSelection.swift, execution and templates may")
}

// lexer
do {
    // Where a regex literal can start. Swift reads a `/` as binary after an
    // operand (a word character, `)`, `]` or `}`), so the rule excludes that:
    // - a `/` not after an operand, and not followed by whitespace, `/`, `*`,
    //   `)`, the end of the line, or `=` and a space (compound `/=`);
    // - a spaced `/=` whose nearest non-space on the left is not an operand;
    // - `#/` anywhere.
    let regexLiteralStart =
        #"(?:^|[^\w)\]}])#*/(?![\s/*)]|=\s|=$|$)|(?:^|[^\w)\]}\s])\s*#*/=(?:\s|$)|#/"#
    forbid(regexLiteralStart, in: sources, view: SwiftSource.code,
           "regex literal: teach check-source-rules.swift to lex it first")
    let lexedScalars: Set<Unicode.Scalar> = ["\"", "#", "/", "*", "\\", "(", ")"]
    let otherSeparators: Set<Unicode.Scalar> = ["\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]
    for file in sources {
        if file.text.unicodeScalars.contains(where: otherSeparators.contains) {
            error(file.path, nil, "a newline-like separator other than \\n or \\r: teach check-source-rules.swift to lex it first")
        }
        if file.text.contains(where: { $0.unicodeScalars.count > 1 && $0.unicodeScalars.contains(where: lexedScalars.contains) }) {
            error(file.path, nil, "a lexed character fused into a grapheme: teach check-source-rules.swift to lex it first")
        }
    }
}

if failed { exit(1) }
print("source rules: \(sources.count) files under Sources pass")
