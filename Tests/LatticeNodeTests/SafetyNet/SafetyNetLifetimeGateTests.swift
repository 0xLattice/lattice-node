import Foundation
import XCTest

/// Structural gate: state written after a suspension cannot outlive the
/// session or generation that owned it.
///
/// - Every task handle a type in `Sources/LatticeNode` stores is a
///   `TaskSlot` (`Lifetime.swift`), whose clear compares the token the task
///   was started with, so a task that outlived a stop cannot empty the
///   handle a restart stored. The scan finds stored properties whose
///   declared type or initializer names a task in any spelling it knows
///   (`Task<…>`, `Optional<Task<…>>`, a collection or tuple of tasks, a
///   typealias of one, `= Task {…}`, `= Task.detached`, a
///   `Timers.deadline(…)` initializer), across lines. The allowlist names
///   each other stored task and why no stale task can clobber it.
/// - In the network runtime (`NodeNetworkRuntime*.swift`) a per-peer record
///   is created only where a session is established, and removed by key
///   only where a connect replaces the key's session or teardown empties
///   the set. Every other write uses `update(session:_:)` or
///   `updateExisting(_:_:)`, and every other removal `remove(_:ifBoundTo:)`:
///   work that resumes after its session ended can neither bring the key
///   back nor remove a newer session's record.
///
/// Scanned as code (`SwiftSource.code`): comments and string literal text
/// are skipped. Plain `XCTAssert` only (`XCTContext` is unavailable on
/// corelibs XCTest).
final class SafetyNetLifetimeGateTests: XCTestCase {

    /// `Type.property` stored tasks allowed outside a `TaskSlot`.
    private static let taskAllowlist: [String: String] = [
        "TaskSlot.current": "the primitive itself",
        "NodeNetworkRuntime.lifecycleTail":
            "a tail each lifecycle operation replaces; never cleared by a task",
        "HelloDeadline.task": "held with its lifetime token; fires compare the token",
        "PendingTransactionInventory.timeout":
            "an entry keyed by a process-unique request ID, removed by its owner",
        "PendingReadEndpoint.timeout":
            "an entry keyed by a process-unique request ID, removed by its owner",
        "ReadURLDiscovery.tasks": "each entry holds its lifetime token; removal compares it",
        "State.responseTimeout":
            "owned by the range-sync state; fires are matched by request ID",
        "State.progressTimeout":
            "owned by the range-sync state; fires are matched by progress epoch",
        "Append.predecessor": "a value handed to the appending task, not a stored handle",
        "Reservation.evidenceTail": "a value handed to the reserving task, not a stored handle",
        "Tail.task": "held with its lifetime token; finish compares the token",
        "EvidenceSlotWaiter.timeout":
            "cancelled when its waiter wakes; a fire only wakes the waiter with its own id",
        "ChainService.canonicalCommitWorker":
            "the service never restarts; shutdown joins the worker",
        "ChainService.executionWalkWorker":
            "the service never restarts; shutdown joins the worker",
        "ChainService.executionWalkRetryTask":
            "the service never restarts; shutdown cancels it before joining the workers",
        "ChainService.transactionPublicationWorker":
            "the service never restarts; shutdown joins the worker",
        "ChainService.parentMailboxDrain":
            "the service never restarts; shutdown finishes the mailbox and joins the drain",
        "ChainService.carrierProofDeliveries":
            "entries keyed by a service-unique ID, each removed by its own task; shutdown joins them",
    ]

    /// Members that establish a session and so may create its record.
    private static let creatingAllowlist: Set<String> = [
        // Overlay connect: the session starts awaiting its hello.
        "didConnect",
        // Hierarchy connect: the hello deadline is the record's first field.
        "scheduleHierarchyHelloDeadline",
        // Accepted hierarchy hello: role and session are bound here.
        "handleHierarchyHello",
    ]

    /// Members that may remove a record by key: a connect replacing the
    /// key's session, and teardown.
    private static let keyedRemovalAllowlist: Set<String> = [
        "didConnect",
        "clearRuntimeState",
    ]

    // MARK: - Source

    private func runtimeFiles() throws -> [SourceFile] {
        try SourceTree.swiftFiles(under: "Sources/LatticeNode").filter {
            ($0.path as NSString).lastPathComponent.hasPrefix("NodeNetworkRuntime")
        }
    }

    // MARK: - Stored tasks

    /// Names typealiased to a task type, through chains of aliases.
    private static func taskAliases(in codes: [String]) throws -> Set<String> {
        let alias = try NSRegularExpression(
            pattern: #"\btypealias\s+(\w+)\s*(?:<[^=]*>)?\s*=\s*([^\n]+)"#
        )
        var definitions: [(String, String)] = []
        for code in codes {
            for match in alias.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let name = Range(match.range(at: 1), in: code),
                      let body = Range(match.range(at: 2), in: code) else { continue }
                definitions.append((String(code[name]), String(code[body])))
            }
        }
        var aliases = Set<String>()
        var changed = true
        while changed {
            changed = false
            for (name, body) in definitions where !aliases.contains(name) {
                if try mentionsTask(body, aliases: aliases) {
                    aliases.insert(name)
                    changed = true
                }
            }
        }
        return aliases
    }

    private static func mentionsTask(_ text: String, aliases: Set<String>) throws -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let task = try NSRegularExpression(
            pattern: #"(?<![\w.])Task\s*(?:<|\{|\(|\.detached\b|\.immediate\b|\?|\]|,|\)|$)|\bTimers\.deadline\s*\("#,
            options: [.anchorsMatchLines]
        )
        if task.firstMatch(in: text, range: range) != nil { return true }
        guard !aliases.isEmpty else { return false }
        let alias = try NSRegularExpression(
            pattern: #"(?<![\w.])(?:\#(aliases.sorted().joined(separator: "|")))\b"#
        )
        return alias.firstMatch(in: text, range: range) != nil
    }

    private static let typeOpener = #"\b(?:struct|class|actor|enum|extension)\s+(\w+)[^{]*\{"#
    private static let declaration =
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:[\w()]+\s+)*(?:var|let)\s+(\w+)"#

    /// `Type.property` for every stored property directly in a type body
    /// whose declared type or initializer names a task. A declaration runs
    /// across lines while its brackets are open or its line ends in `:`,
    /// `=` or `,`; one whose annotation is followed by a body without `=`
    /// is computed, not stored.
    private func storedTasks(
        in files: [SourceFile]
    ) throws -> [(name: String, site: String)] {
        let codes = files.map { SwiftSource.code($0.text) }
        let aliases = try Self.taskAliases(in: codes)
        let opener = try NSRegularExpression(pattern: Self.typeOpener)
        let declaration = try NSRegularExpression(pattern: Self.declaration)
        var found: [(String, String)] = []
        for (file, code) in zip(files, codes) {
            let lines = code.components(separatedBy: "\n")
            var scopes: [String?] = []
            var index = 0
            while index < lines.count {
                let line = lines[index]
                let range = NSRange(line.startIndex..., in: line)
                var consumed = 1
                if let enclosing = scopes.last, let typeName = enclosing,
                   let match = declaration.firstMatch(in: line, range: range),
                   let nameRange = Range(match.range(at: 1), in: line) {
                    var text = line
                    while index + consumed < lines.count, Self.continues(text) {
                        text += "\n" + lines[index + consumed]
                        consumed += 1
                    }
                    if !Self.isComputed(text), try Self.mentionsTask(text, aliases: aliases) {
                        found.append(("\(typeName).\(line[nameRange])", "\(file.path):\(index + 1)"))
                    }
                }
                for offset in 0..<consumed {
                    let scanned = lines[index + offset]
                    let scannedRange = NSRange(scanned.startIndex..., in: scanned)
                    var openedType: String?
                    if let match = opener.firstMatch(in: scanned, range: scannedRange),
                       let nameRange = Range(match.range(at: 1), in: scanned) {
                        openedType = String(scanned[nameRange])
                    }
                    for character in scanned {
                        if character == "{" {
                            scopes.append(openedType)
                            openedType = nil
                        } else if character == "}" {
                            _ = scopes.popLast()
                        }
                    }
                }
                index += consumed
            }
            XCTAssertTrue(scopes.isEmpty, "\(file.path): braces do not balance; the scan drifted")
        }
        return found
    }

    private static func continues(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if "([<".contains(character) { depth += 1 }
            if ")]>".contains(character) { depth -= 1 }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return depth > 0 || trimmed.hasSuffix(":") || trimmed.hasSuffix("=")
            || trimmed.hasSuffix(",")
    }

    private static func isComputed(_ text: String) -> Bool {
        guard let brace = text.firstIndex(of: "{") else { return false }
        return !text[..<brace].contains("=") && text[..<brace].contains(":")
    }

    // MARK: - Peer-set creation and removal

    /// Every match of `pattern` in the files, with the function it sits in.
    private func calls(
        matching pattern: String,
        in files: [SourceFile]
    ) throws -> [(function: String, site: String)] {
        let call = try NSRegularExpression(pattern: pattern)
        let function = try NSRegularExpression(pattern: #"\bfunc\s+(\w+)"#)
        var found: [(String, String)] = []
        for file in files {
            let code = SwiftSource.code(file.text)
            let whole = NSRange(code.startIndex..., in: code)
            let functions = function.matches(in: code, range: whole)
            for match in call.matches(in: code, range: whole) {
                let enclosing = functions.last { $0.range.location < match.range.location }
                let name = enclosing
                    .flatMap { Range($0.range(at: 1), in: code) }
                    .map { String(code[$0]) } ?? "<file scope>"
                let line = code[..<(Range(match.range, in: code)!.lowerBound)]
                    .filter { $0 == "\n" }.count + 1
                found.append((name, "\(file.path):\(line)"))
            }
        }
        return found
    }

    private static let creatingUpdate =
        #"\b(?:overlayRecords|hierarchyRecords)\s*\.\s*update\s*\((?!\s*session\s*:)"#
    /// A removal by key: `remove(key)` without `ifBoundTo:`, or `removeAll`.
    private static let keyedRemoval =
        #"\b(?:overlayRecords|hierarchyRecords)\s*\.\s*(?:remove\s*\((?![^()]*ifBoundTo\s*:)|removeAll\s*\()"#

    // MARK: - Self-tests

    func testTaskScanFindsEverySpelling() throws {
        let sample = """
        typealias Handle = Task<Void, Never>
        typealias Handles = [Handle]
        struct Sample {
            var plain: Task<Void, Never>?
            let fixed: Task<Void, Never>
            var wrapped: Optional<Task<Void, Never>>
            var byKey: [String: Task<Int, Never>] = [:]
            var list: [Task<Void, Never>] = []
            var pair: (token: Int, task: Task<Void, Never>)?
            var aliased: Handle?
            var aliasedList: Handles = []
            var split:
                Task<Void, Never>?
            var spread: [
                String: Task<Void, Never>
            ] = [:]
            private var inferred = Task { }
            var detached = Task.detached { }
            var prioritized = Task(priority: .low) { }
            var immediate = Task.immediate { }
            var timer = Timers.deadline(after: .seconds(1), generation: 0) { _ in }
            var slot = TaskSlot()
            var group: TaskGroup<Int>?
            var computed: Task<Void, Never>? { nil }
            // var commented: Task<Void, Never>?
            var text = "Task<Void, Never>"
            func work() {
                var local: Task<Void, Never>?
                let other = Task { }
            }
        }
        """
        XCTAssertEqual(
            try storedTasks(in: [SourceFile(path: "sample", text: sample)]).map(\.name),
            [
                "Sample.plain", "Sample.fixed", "Sample.wrapped", "Sample.byKey",
                "Sample.list", "Sample.pair", "Sample.aliased", "Sample.aliasedList",
                "Sample.split", "Sample.spread", "Sample.inferred", "Sample.detached",
                "Sample.prioritized", "Sample.immediate", "Sample.timer",
            ]
        )
    }

    func testPeerSetScanFindsCreatingUpdatesAndKeyedRemovals() throws {
        let sample = """
        func connect() {
            overlayRecords.update(peer.key) { $0.session = nil }
            hierarchyRecords.remove(peer.key)
        }
        func late() async {
            hierarchyRecords.update(session: peer) { $0.offer = nil }
            hierarchyRecords.updateExisting(key) { $0.offer = nil }
            hierarchyRecords.update(key) { $0.offer = nil }
            hierarchyRecords.remove(
                key, ifBoundTo: ended
            )
            hierarchyRecords.remove(
                key
            )
            // hierarchyRecords.remove(key)
            overlayRecords.removeAll()
        }
        """
        XCTAssertEqual(
            try calls(matching: Self.creatingUpdate, in: [SourceFile(path: "sample", text: sample)]).map(\.function),
            ["connect", "late"]
        )
        XCTAssertEqual(
            try calls(matching: Self.keyedRemoval, in: [SourceFile(path: "sample", text: sample)]).map(\.site),
            ["sample:3", "sample:12", "sample:16"]
        )
    }

    // MARK: - Gates

    func testGateSeesTheAllowlistedSites() throws {
        let sources = try SourceTree.swiftFiles(under: "Sources/LatticeNode")
        XCTAssertEqual(
            Set(try storedTasks(in: sources).map(\.name)),
            Set(Self.taskAllowlist.keys),
            "an allowlisted task is gone: shrink the allowlist"
        )
        let runtime = try runtimeFiles()
        XCTAssertEqual(
            Set(try calls(matching: Self.creatingUpdate, in: runtime).map(\.function)),
            Self.creatingAllowlist,
            "an allowlisted creating site is gone: shrink the allowlist"
        )
        XCTAssertEqual(
            Set(try calls(matching: Self.keyedRemoval, in: runtime).map(\.function)),
            Self.keyedRemovalAllowlist,
            "an allowlisted keyed removal is gone: shrink the allowlist"
        )
    }

    func testStoredTaskHandlesAreTaskSlots() throws {
        let found = try storedTasks(in: SourceTree.swiftFiles(under: "Sources/LatticeNode"))
            .filter { Self.taskAllowlist[$0.name] == nil }
        XCTAssertEqual(
            found.map { "\($0.site): \($0.name)" }, [],
            "store a task handle in a TaskSlot (Lifetime.swift)"
        )
    }

    func testOnlySessionEstablishmentCreatesAPeerRecord() throws {
        let found = try calls(matching: Self.creatingUpdate, in: runtimeFiles())
            .filter { !Self.creatingAllowlist.contains($0.function) }
        XCTAssertEqual(
            found.map { "\($0.site): \($0.function)" }, [],
            "write per-peer state with update(session:) or updateExisting (PeerSet.swift)"
        )
    }

    func testOnlyAConnectOrTeardownRemovesAPeerRecordByKey() throws {
        let found = try calls(matching: Self.keyedRemoval, in: runtimeFiles())
            .filter { !Self.keyedRemovalAllowlist.contains($0.function) }
        XCTAssertEqual(
            found.map { "\($0.site): \($0.function)" }, [],
            "end a session with remove(_:ifBoundTo:) (PeerSet.swift)"
        )
    }
}
