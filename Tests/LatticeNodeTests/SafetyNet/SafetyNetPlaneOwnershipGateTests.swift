import Foundation
import XCTest

/// Structural gate over the `NodeNetworkRuntime` plane extensions: overlay
/// code (`+Overlay`, `+RangeSync`, the overlay part of `+ReadURL`) never
/// touches `hierarchyState`, and hierarchy code (`+Hierarchy`, the hierarchy
/// part of `+ReadURL`) never touches `overlayState`. One plane reaches the
/// other only by calling one of the named seams below, so every cross-plane
/// dependency is listed here and nowhere else.
///
/// Members are attributed by brace depth inside the file's
/// `extension NodeNetworkRuntime`. Comments and string literal text are
/// skipped; string interpolations are code. Plain `XCTAssert` only
/// (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetPlaneOwnershipGateTests: XCTestCase {

    private static let architectureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SafetyNet
        .deletingLastPathComponent()  // LatticeNodeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/LatticeNode/Architecture")

    private enum Plane: String {
        case overlay
        case hierarchy

        var ownState: String {
            switch self {
            case .overlay: return "overlayState"
            case .hierarchy: return "hierarchyState"
            }
        }
    }

    /// The plane each file belongs to; `+ReadURL` members default to the
    /// overlay unless named in `readURLHierarchyMembers`.
    private static let files: [String: Plane] = [
        "NodeNetworkRuntime+Overlay.swift": .overlay,
        "NodeNetworkRuntime+RangeSync.swift": .overlay,
        "NodeNetworkRuntime+ReadURL.swift": .overlay,
        "NodeNetworkRuntime+Hierarchy.swift": .hierarchy,
    ]

    /// `+ReadURL` members that are the hierarchy's: they read the wired
    /// children's declared URLs.
    private static let readURLHierarchyMembers: Set<String> = ["declaredReadURLs"]

    /// Hierarchy members overlay code may call.
    private static let overlayToHierarchySeams: Set<String> = [
        // An overlay hello or an admission makes child proofs worth another pass.
        "scheduleChildProofRecovery",
        // Serving and discovering read URLs includes the wired children's.
        "declaredReadURLs",
    ]

    /// Overlay members hierarchy code may call.
    private static let hierarchyToOverlaySeams: Set<String> = []

    private struct Member {
        let plane: Plane
        let file: String
        let name: String
        /// A static member holds no plane state; calling one is not a crossing.
        let isStatic: Bool
        var lines: [(number: Int, code: String)] = []
    }

    private func sources() throws -> [(path: String, text: String)] {
        let root = Self.architectureRoot.standardizedFileURL
        return try Self.files.keys.sorted().map {
            ($0, try String(
                contentsOf: root.appendingPathComponent($0),
                encoding: .utf8
            ))
        }
    }

    private static let memberPattern =
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|nonisolated|static|override|final|mutating)\s+)*(?:func|var|let)\s+(\w+)"#

    /// Every member of each file's type bodies with its code lines. A line
    /// at the extension's own depth that declares a member starts it; its
    /// body is every line until the depth returns.
    private func members(
        in files: [(path: String, text: String)],
        plane: (String, String) -> Plane
    ) throws -> [Member] {
        let declaration = try NSRegularExpression(pattern: Self.memberPattern)
        var found: [Member] = []
        for file in files {
            var depth = 0
            var current: Member?
            for (index, raw) in file.text.components(separatedBy: "\n").enumerated() {
                let line = Self.code(of: raw)
                let range = NSRange(line.startIndex..., in: line)
                if depth == 1,
                   let match = declaration.firstMatch(in: line, range: range),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    if let current { found.append(current) }
                    let name = String(line[nameRange])
                    current = Member(
                        plane: plane(file.path, name),
                        file: file.path,
                        name: name,
                        isStatic: line.range(of: #"\bstatic\b"#, options: .regularExpression) != nil
                    )
                }
                if depth >= 1 {
                    current?.lines.append((index + 1, line))
                }
                for character in line {
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                }
                if depth == 0, let finished = current {
                    found.append(finished)
                    current = nil
                }
            }
            if let current { found.append(current) }
        }
        return found
    }

    private func runtimeMembers() throws -> [Member] {
        try members(in: sources()) { file, name in
            if file == "NodeNetworkRuntime+ReadURL.swift",
               Self.readURLHierarchyMembers.contains(name) {
                return .hierarchy
            }
            return Self.files[file] ?? .overlay
        }
    }

    /// `file:line: member` for every line of `plane`'s members that names
    /// the other plane's state, or a member of the other plane that is not
    /// one of the seams it may call.
    private func crossings(in members: [Member], from plane: Plane) throws -> [String] {
        let other: Plane = plane == .overlay ? .hierarchy : .overlay
        let seams = plane == .overlay
            ? Self.overlayToHierarchySeams
            : Self.hierarchyToOverlaySeams
        let otherNames = Set(members.filter { $0.plane == other && !$0.isStatic }.map(\.name))
            .subtracting(members.filter { $0.plane == plane }.map(\.name))
            .subtracting(seams)
        let state = try NSRegularExpression(pattern: #"\b\#(other.ownState)\b"#)
        let calls = try otherNames.sorted().map {
            ($0, try NSRegularExpression(pattern: #"(?<![\w.])(?:self\.|Self\.)?\#($0)\b"#))
        }
        var found: [String] = []
        for member in members where member.plane == plane {
            for line in member.lines {
                let range = NSRange(line.code.startIndex..., in: line.code)
                if state.firstMatch(in: line.code, range: range) != nil {
                    found.append("\(member.file):\(line.number): \(member.name) touches \(other.ownState)")
                }
                for (name, call) in calls
                where call.firstMatch(in: line.code, range: range) != nil {
                    found.append("\(member.file):\(line.number): \(member.name) calls \(other.rawValue) \(name)")
                }
            }
        }
        return found
    }

    /// The line without its `//` comment and string literal text; an
    /// interpolation inside a string is kept as code.
    private static func code(of line: String) -> String {
        var result = ""
        var inString = false
        var interpolationDepth = 0
        var previous: Character?
        for character in line {
            if inString && interpolationDepth == 0 {
                if character == "\"" && previous != "\\" {
                    inString = false
                } else if character == "(" && previous == "\\" {
                    interpolationDepth = 1
                    result.append(" ")
                }
                previous = character
                continue
            }
            if inString {
                if character == "(" { interpolationDepth += 1 }
                if character == ")" {
                    interpolationDepth -= 1
                    if interpolationDepth == 0 {
                        result.append(" ")
                        previous = character
                        continue
                    }
                }
                result.append(character)
            } else if character == "\"" {
                inString = true
            } else if character == "/" && previous == "/" {
                result.removeLast()
                break
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    func testScanAttributesMembersAndFindsCrossings() throws {
        let overlay = """
        extension NodeNetworkRuntime {
            func overlayWork() {
                overlayState.rangeSync.clear()
                // hierarchyState.receivedParentTip = nil
                log("tip \\(hierarchyState.receivedParentTip)")
                seam()
                hierarchyOnly()
            }
            var overlayView: Int { 1 }
            nonisolated static func pure() -> Int { 1 }
        }
        """
        let hierarchy = """
        extension NodeNetworkRuntime {
            func seam() {}
            private func hierarchyOnly() {
                if true {
                    overlayView
                    Self.pure()
                }
            }
        }
        """
        let members = try members(
            in: [("o", overlay), ("h", hierarchy)]
        ) { file, _ in file == "o" ? .overlay : .hierarchy }
        XCTAssertEqual(
            members.map { "\($0.file).\($0.name)" },
            ["o.overlayWork", "o.overlayView", "o.pure", "h.seam", "h.hierarchyOnly"]
        )
        let fromOverlay = try crossings(in: members, from: .overlay)
        XCTAssertEqual(fromOverlay, [
            "o:5: overlayWork touches hierarchyState",
            "o:6: overlayWork calls hierarchy seam",
            "o:7: overlayWork calls hierarchy hierarchyOnly",
        ])
        XCTAssertEqual(try crossings(in: members, from: .hierarchy), [
            "h:5: hierarchyOnly calls overlay overlayView",
        ])
    }

    func testGateSeesEveryPlaneAndEverySeam() throws {
        let members = try runtimeMembers()
        for file in Self.files.keys {
            XCTAssertFalse(
                members.filter { $0.file == file }.isEmpty,
                "no members found in \(file)"
            )
        }
        let hierarchyNames = Set(members.filter { $0.plane == .hierarchy }.map(\.name))
        let overlayNames = Set(members.filter { $0.plane == .overlay }.map(\.name))
        XCTAssertEqual(
            Self.overlayToHierarchySeams.subtracting(hierarchyNames), [],
            "an overlay-to-hierarchy seam is no longer a hierarchy member"
        )
        XCTAssertEqual(
            Self.hierarchyToOverlaySeams.subtracting(overlayNames), [],
            "a hierarchy-to-overlay seam is no longer an overlay member"
        )
        XCTAssertEqual(
            Self.readURLHierarchyMembers.subtracting(hierarchyNames), [],
            "a +ReadURL hierarchy member is gone"
        )
    }

    func testOverlayReachesTheHierarchyOnlyThroughItsSeams() throws {
        XCTAssertEqual(
            try crossings(in: runtimeMembers(), from: .overlay), [],
            "overlay code reaches hierarchy state; add a named hierarchy seam"
        )
    }

    func testHierarchyReachesTheOverlayOnlyThroughItsSeams() throws {
        XCTAssertEqual(
            try crossings(in: runtimeMembers(), from: .hierarchy), [],
            "hierarchy code reaches overlay state; add a named overlay seam"
        )
    }
}
