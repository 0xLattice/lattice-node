import Foundation

/// A Swift source file as a structural gate reads it.
struct SourceFile: Sendable {
    /// Relative to the directory the gate scanned.
    let path: String
    let text: String
}

/// The package's Swift sources, read for the SafetyNet structural gates.
enum SourceTree {

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    struct NoSources: Error, CustomStringConvertible {
        let directory: String
        var description: String { "no Swift sources under \(directory)" }
    }

    /// Every `.swift` file under `directory` (relative to the package root,
    /// searched recursively), paths relative to `directory`, sorted. A
    /// directory with none throws: a gate over a moved or renamed directory
    /// fails instead of passing over nothing.
    static func swiftFiles(under directory: String) throws -> [SourceFile] {
        let root = packageRoot.appendingPathComponent(directory).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw NoSources(directory: root.path)
        }
        let paths = enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        guard !paths.isEmpty else { throw NoSources(directory: root.path) }
        return try paths.map {
            SourceFile(
                path: $0,
                text: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
            )
        }
    }
}

/// Views of Swift source text for pattern-based gates. Both views keep the
/// text's length in characters and every newline in place, so a line or a
/// character offset in a view is the same line or offset in the source.
///
/// Not modelled: regex literals (`/…/`, `#/…/#`), a quote carrying a
/// combining mark, and line separators other than newlines inside a
/// single-line string. `SafetyNetSourceScanTests` fails if the package
/// sources ever contain one, so teach the lexer before that lands.
enum SwiftSource {

    /// `text` with every comment replaced by spaces. String literals are
    /// kept whole: a gate may be matching inside them (SQL, for one).
    static func blankingComments(_ text: String) -> String {
        var lexer = Lexer(text, blankStrings: false)
        return lexer.run()
    }

    /// `text` as code: comments and the contents of string literals
    /// replaced by spaces. Quote delimiters stay, and so does every
    /// interpolated expression, which is code.
    static func code(_ text: String) -> String {
        var lexer = Lexer(text, blankStrings: true)
        return lexer.run()
    }

    /// `path:line: text` for every line of `files` whose `view` matches
    /// `pattern`, printing the source line trimmed of surrounding spaces.
    static func matchingLines(
        _ pattern: String,
        in files: [SourceFile],
        view: (String) -> String
    ) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for file in files {
            let viewed = view(file.text).components(separatedBy: "\n")
            let source = file.text.components(separatedBy: "\n")
            for (index, line) in viewed.enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                let shown = source[index].trimmingCharacters(in: .whitespaces)
                found.append("\(file.path):\(index + 1): \(shown)")
            }
        }
        return found
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
            return Opening(
                hashes: cursor - index,
                multiline: starts("\"\"\"", at: cursor)
            )
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
            let start = position ?? index
            var cursor = start
            for character in text {
                guard cursor < characters.count, characters[cursor] == character else {
                    return false
                }
                cursor += 1
            }
            return true
        }

        /// Replaces one character with a space, keeping newlines. String
        /// contents are blanked only in the `code` view; comments always.
        private mutating func blank(_ position: Int, always: Bool = false) {
            guard position < output.count,
                  always || blankStrings,
                  !output[position].isNewline else { return }
            output[position] = " "
        }
    }
}
