import Foundation
import XCTest

/// Structural gate over the `NodeNetworkRuntime` plane extensions: overlay
/// code (`+Overlay`, `+RangeSync`, `+ReadURL`) never touches
/// `hierarchyState`, hierarchy code (`+Hierarchy`) never touches
/// `overlayState`, neither touches the fetcher (`blockFetcher`,
/// `candidateOfferDeferredByAdmission`), and the fetcher side
/// (`+Candidates`) touches neither plane's state. The fetcher side reaches a
/// plane through that plane's seam functions; overlay and hierarchy reach
/// each other only by calling one of the named seams below, so every
/// cross-plane dependency is listed here and nowhere else.
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
        case fetcher

        /// State this plane's code never names.
        var foreignState: [String] {
            switch self {
            case .overlay:
                return ["hierarchyState", "blockFetcher", "candidateOfferDeferredByAdmission"]
            case .hierarchy:
                return ["overlayState", "blockFetcher", "candidateOfferDeferredByAdmission"]
            case .fetcher:
                return ["overlayState", "hierarchyState"]
            }
        }
    }

    /// The plane each file belongs to.
    private static let files: [String: Plane] = [
        "NodeNetworkRuntime+Overlay.swift": .overlay,
        "NodeNetworkRuntime+RangeSync.swift": .overlay,
        "NodeNetworkRuntime+ReadURL.swift": .overlay,
        "NodeNetworkRuntime+Hierarchy.swift": .hierarchy,
        "NodeNetworkRuntime+Candidates.swift": .fetcher,
    ]

    /// Hierarchy members overlay code may call.
    private static let overlayToHierarchySeams: Set<String> = [
        // An overlay hello or an admission makes child proofs worth another pass.
        "scheduleChildProofRecovery",
        // Serving and discovering read URLs includes the wired children's.
        "anyChildDeclaredReadURL",
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
        /// A function is named by a call (`name(`); a local of the same
        /// name elsewhere is not a use of it.
        let isFunction: Bool
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
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|nonisolated|static|override|final|mutating)\s+)*(func|var|let)\s+(\w+)"#

    /// Every member of each file's type bodies with its code lines. A line
    /// at the extension's own depth that declares a member starts it; its
    /// body is every line until the depth returns.
    private func members(
        in files: [(path: String, text: String)],
        plane: (String) -> Plane
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
                   let kindRange = Range(match.range(at: 1), in: line),
                   let nameRange = Range(match.range(at: 2), in: line) {
                    if let current { found.append(current) }
                    current = Member(
                        plane: plane(file.path),
                        file: file.path,
                        name: String(line[nameRange]),
                        isStatic: line.range(of: #"\bstatic\b"#, options: .regularExpression) != nil,
                        isFunction: line[kindRange] == "func"
                    )
                }
                if depth >= 1 {
                    current?.lines.append((index + 1, line))
                }
                for character in line {
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                }
                // A brace the line filter mis-read (an unhandled string
                // form) would drift the depth and silently stop the scan.
                XCTAssertGreaterThanOrEqual(
                    depth, 0, "\(file.path):\(index + 1): brace depth went negative"
                )
                if depth == 0, let finished = current {
                    found.append(finished)
                    current = nil
                }
            }
            XCTAssertEqual(depth, 0, "\(file.path): braces do not balance; the scan drifted")
            if let current { found.append(current) }
        }
        return found
    }

    private func runtimeMembers() throws -> [Member] {
        try members(in: sources()) { Self.files[$0] ?? .fetcher }
    }

    /// `file:line: member` for every line of `plane`'s members that names
    /// state foreign to it, or (between overlay and hierarchy) a member of
    /// the other plane that is not one of the seams it may call.
    private func crossings(in members: [Member], from plane: Plane) throws -> [String] {
        var otherPlane: Plane?
        var seams: Set<String> = []
        switch plane {
        case .overlay:
            otherPlane = .hierarchy
            seams = Self.overlayToHierarchySeams
        case .hierarchy:
            otherPlane = .overlay
            seams = Self.hierarchyToOverlaySeams
        case .fetcher:
            otherPlane = nil
        }
        let otherMembers = members.filter {
            $0.plane == otherPlane && !$0.isStatic && !seams.contains($0.name)
        }
        let ownNames = Set(members.filter { $0.plane == plane }.map(\.name))
        var calls: [(name: String, plane: Plane, pattern: NSRegularExpression)] = []
        for member in otherMembers where !ownNames.contains(member.name)
            && !calls.contains(where: { $0.name == member.name }) {
            let use = member.isFunction ? #"\s*\("# : #"\b"#
            calls.append((
                member.name,
                member.plane,
                try NSRegularExpression(
                    pattern: #"(?<![\w.])(?:self\.|Self\.)?\#(member.name)"# + use
                )
            ))
        }
        let state = try plane.foreignState.map {
            ($0, try NSRegularExpression(pattern: #"\b\#($0)\b"#))
        }
        var found: [String] = []
        for member in members where member.plane == plane {
            for line in member.lines {
                let range = NSRange(line.code.startIndex..., in: line.code)
                for (name, pattern) in state
                where pattern.firstMatch(in: line.code, range: range) != nil {
                    found.append("\(member.file):\(line.number): \(member.name) touches \(name)")
                }
                for call in calls.sorted(by: { $0.name < $1.name })
                where call.pattern.firstMatch(in: line.code, range: range) != nil {
                    found.append("\(member.file):\(line.number): \(member.name) calls \(call.plane.rawValue) \(call.name)")
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
                let hierarchyOnly = blockFetcher.tracks(cid)
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
        let fetcher = """
        extension NodeNetworkRuntime {
            func admit() {
                blockFetcher.next()
                hierarchyState.releasedCarriedChildCID = cid
                hierarchyOnly()
            }
        }
        """
        let members = try members(
            in: [("o", overlay), ("h", hierarchy), ("f", fetcher)]
        ) { ["o": .overlay, "h": .hierarchy][$0] ?? .fetcher }
        XCTAssertEqual(
            members.map { "\($0.file).\($0.name)" },
            ["o.overlayWork", "o.overlayView", "o.pure", "h.seam", "h.hierarchyOnly", "f.admit"]
        )
        XCTAssertEqual(try crossings(in: members, from: .overlay), [
            "o:5: overlayWork touches hierarchyState",
            "o:6: overlayWork calls hierarchy seam",
            "o:7: overlayWork calls hierarchy hierarchyOnly",
            "o:8: overlayWork touches blockFetcher",
        ])
        XCTAssertEqual(try crossings(in: members, from: .hierarchy), [
            "h:5: hierarchyOnly calls overlay overlayView",
        ])
        XCTAssertEqual(try crossings(in: members, from: .fetcher), [
            "f:4: admit touches hierarchyState",
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
    }

    func testOverlayReachesTheHierarchyOnlyThroughItsSeams() throws {
        XCTAssertEqual(
            try crossings(in: runtimeMembers(), from: .overlay), [],
            "overlay code reaches hierarchy or fetcher state; add a named seam"
        )
    }

    func testHierarchyReachesTheOverlayOnlyThroughItsSeams() throws {
        XCTAssertEqual(
            try crossings(in: runtimeMembers(), from: .hierarchy), [],
            "hierarchy code reaches overlay or fetcher state; add a named seam"
        )
    }

    func testFetcherReachesThePlanesOnlyThroughTheirSeams() throws {
        XCTAssertEqual(
            try crossings(in: runtimeMembers(), from: .fetcher), [],
            "+Candidates reaches plane state; add a seam on the owning plane"
        )
    }
}
