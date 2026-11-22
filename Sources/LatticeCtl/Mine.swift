// Mining role: coordinator + worker beside the hosted tree, one --once batch
// per round. Each block pays the configured recipient for its chain (the
// block's `rewardRecipient`); a chain with none burns its reward and fees.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeCtlCore
import LatticeNodeConfig
import LatticeMinerCore
import LatticeMiningCoordinator
import LatticeProcessWait

struct Mine: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Merged-mine a node's hosted tree, as a process of its own.",
        discussion: """
        The miner is a client of a node, not part of it: it asks the node for \
        templates and submits work (POST /mining/templates, POST /mining/work, \
        GET /status), and the node knows nothing of it. Its settings are its own \
        file, <root>/miner.json (or --config; while there is none, the mine \
        object an older <root>/lattice.json holds, with a warning): worker, workers, batchSize, \
        recipients (chain path -> address; a chain left out burns its reward and \
        fees), minWork, minBlockIntervalSeconds, templateTimeoutSeconds, \
        roundDeadlineMultiplier. The loop reads it again before every round. \
        It mines through the node under --root (its loopback API and cookie), \
        or with --node and --token-file through a node's operator listener, \
        with a token for those three routes.
        """,
        subcommands: [Start.self, Run.self, Stop.self, MineStatus.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the mining loop in the background."
        )

        @OptionGroup var options: MinerOptions

        func run() async throws {
            let layout = options.layout
            if let warning = try minerSettings(options).warning { print("warning: \(warning)") }
            try await withSpawnLock(layout) {
                try self.startLocked(layout)
            }
        }

        private func startLocked(_ layout: HostLayout) throws {
            if let pid = runningPid(layout, "mine") {
                throw CtlError("mining already running (pid \(pid))")
            }
            let process = Process()
            process.executableURL = currentExecutable
            process.arguments = ["mine", "run"] + options.runArguments
            let log = layout.logFile(for: "mine")
            try FileManager.default.createDirectory(
                at: log.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            try writePidFile(
                layout, "mine",
                pid: process.processIdentifier, name: "lattice"
            )
            print("mining started (pid \(process.processIdentifier)), log \(log.path)")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the mining loop."
        )

        @OptionGroup var rootOption: RootOption

        func run() async throws {
            let layout = rootOption.layout
            // Under the spawn lock, so a concurrent `mine start` cannot
            // lose its pidfile to this stop. Graceful: the loop finishes
            // its batch within the grace.
            let stopped = try await withSpawnLock(layout) {
                try await stopProcess(
                    layout, "mine", grace: .seconds(60),
                    onKill: {
                        if let coordinator = runningPid(layout, "mine-coordinator") {
                            kill(coordinator, SIGKILL)
                        }
                    }
                )
            }
            print(stopped ? "mining stopped" : "mining not running")
        }
    }

    struct MineStatus: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Whether mining runs, and who it pays."
        )

        @OptionGroup var options: MinerOptions

        func run() async throws {
            let layout = options.layout
            let (mine, warning) = try options.loadConfig()
            if let warning { print("warning: \(warning)") }
            let running = runningPid(layout, "mine").map { "running (pid \($0))" }
                ?? "stopped"
            print("mining: \(running)")
            print("node:   \(options.target.node ?? "the node under \(layout.root.path)")")
            let recipients = mine.recipientEntries
            if recipients.isEmpty {
                print("recipients: none configured (rewards and fees burn)")
            } else {
                for entry in recipients { print("recipient: \(entry)") }
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The mining loop in the foreground (what `mine start` runs in the background, and the systemd unit)."
        )

        @OptionGroup var options: MinerOptions

        func run() async throws {
            let layout = options.layout
            var settings = try minerSettings(options)
            // Finish the in-flight batch on SIGTERM: killing mid-iteration can
            // orphan a coordinator.
            //
            // The flag is only read at the top of the loop and inside
            // `holdFor`, so it does NOT cut short an in-flight HTTP call. A
            // SIGTERM landing mid-probe waits out the rest of
            // templateTimeoutSeconds before this notices. On a node
            // answering normally that is not visible, but on one slow enough
            // to need the timeout a stop can outlast `mine stop`'s own 60s
            // grace, ending in SIGKILL.
            let stopRequested = InterruptFlag()
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM)
            source.setEventHandler { stopRequested.raise() }
            source.resume()
            // Measured, not assumed: a wedged round never completes, so it
            // can never widen the bound that would have caught it.
            var longestCompletedRound = Duration.zero
            var nodeAnswered = false
            var unusableTemplateSince: ContinuousClock.Instant?
            if let warning = settings.warning { log("warning: \(warning)") }
            log("mining loop start, node \(settings.rpc.baseURL)"
                + (settings.mine.minBlockIntervalSeconds.map {
                    ", pacing parent blocks at least \($0)s apart"
                } ?? ""))
            while !stopRequested.isRaised {
                // Read again each round: a changed recipient applies to the
                // next round, with no restart.
                do {
                    settings = try minerSettings(options)
                } catch {
                    log("mining on with the settings read before: \(error)")
                }
                let multiplier = settings.mine.roundDeadlineMultiplier
                    ?? MiningRoundDeadline.defaultMultiplier
                let templateTimeout = settings.mine.resolvedTemplateTimeoutSeconds
                let outcome: CoordinatorOutcome
                let started = ContinuousClock.now
                do {
                    let templateRequestBody = try MiningTemplateRequestBody.make(
                        recipients: settings.mine.recipientEntries,
                        minimumWork: settings.mine.minimumWorkEntries
                    )
                    if !nodeAnswered {
                        // Marked BEFORE the attempt: an attempt can itself take
                        // the full timeout, so stamping it afterwards would
                        // report ~0 elapsed in the very line that says the node
                        // did not answer for that long.
                        unusableTemplateSince = unusableTemplateSince
                            ?? ContinuousClock.now
                        // The node adopts each request's plan for its
                        // descendants, so the probe sends the coordinator's
                        // own body: any other would churn their candidates.
                        nodeAnswered = await nodeAnswersTemplates(
                            settings.rpc,
                            body: templateRequestBody,
                            timeoutSeconds: templateTimeout
                        )
                    }
                    guard nodeAnswered else {
                        // Say so as the standstill it is: this retries
                        // forever, and a passing-hiccup wording would hide
                        // that the miner produced nothing for as long as it
                        // lasted.
                        //
                        // State the OBSERVATION, not a cause: no usable answer
                        // covers a timeout, a transport failure, a non-200
                        // (the node answers 409 while bootstrapping, 503
                        // "executing" while it syncs, holding the next
                        // blocks of its chain to execute first, and 503 when
                        // the mempool or parent is unavailable -- all fast).
                        // Naming any one
                        // of them would send an operator after the wrong thing.
                        // Elapsed, not an attempt count: an attempt here spans
                        // anywhere from milliseconds (a fast non-200) to the
                        // full timeout, so a count says nothing about how long
                        // this has been down, which is the actual question.
                        // Whole seconds, because `Duration` renders through a
                        // Double: an hour down prints as "3664.9999999999995
                        // seconds" otherwise, burying the one number the line
                        // exists to carry.
                        let downFor = (unusableTemplateSince ?? ContinuousClock.now)
                            .duration(to: ContinuousClock.now)
                        log("NOT MINING: no usable template answer from the node (no reply within \(templateTimeout)s, or a non-200). Stopped for \(downFor.components.seconds)s so far; check `POST /mining/templates` on this node.")
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    }
                    unusableTemplateSince = nil
                    let deadline = MiningRoundDeadline.deadline(
                        longestCompletedRound: longestCompletedRound,
                        multiplier: multiplier
                    )
                    outcome = try await runCoordinatorOnce(
                        settings, layout: layout, deadline: deadline
                    )
                } catch {
                    // A spawn/IO failure must never kill the loop: retry.
                    log("retrying after spawn error: \(error)")
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                // Only a round that actually produced a coordinator
                // result measures batch time. A round that burned its budget
                // failing -- worker/node trouble, or the deadline itself --
                // would inflate the very bound meant to catch it.
                switch outcome {
                case .accepted, .harmless, .childOnly, .refusal:
                    longestCompletedRound = max(
                        longestCompletedRound,
                        started.duration(to: ContinuousClock.now)
                    )
                case .workerTrouble, .roundDeadlineExceeded:
                    break
                }
                switch outcome {
                case .accepted(let tip):
                    log("accepted tip=\(tip.prefix(24))")
                    let hold = settings.mine.pacingHold(
                        afterRoundOf: started.duration(to: ContinuousClock.now)
                    )
                    if hold > .zero {
                        log("pacing: holding \(hold) so the next block is at least minBlockIntervalSeconds from this one")
                        await holdFor(hold, stopRequested: stopRequested)
                    }
                case .harmless:
                    break
                case .childOnly:
                    // A child chain advanced; no parent block was produced,
                    // so this starts no pacing hold. Note
                    // that is about the TRIGGER, not the effect: a hold
                    // withholds the next round, and a round is what co-mines
                    // the children, so pacing throttles the whole subtree.
                    break
                case .roundDeadlineExceeded(let deadline, let degraded):
                    // Loud by construction: a silent kill-and-continue is
                    // the original failure mode wearing a fix's clothes.
                    log("ROUND DEADLINE EXCEEDED after \(deadline): the coordinator process group was killed and the round abandoned. Raise roundDeadlineMultiplier in \(MinerConfig.fileName) if rounds here legitimately run this long.")
                    if degraded {
                        // State the fact; do not decide for the operator what
                        // it means. A teardown that could only signal the pid
                        // is not the clean one the line above implies.
                        log("ROUND TEARDOWN DEGRADED: only the coordinator pid could be signalled, not its process group, so processes it spawned may still be running and holding resources. Check for stray lattice-miner processes.")
                    }
                case .workerTrouble(let detail):
                    log("retrying after \(detail)")
                    try await Task.sleep(for: .seconds(5))
                case .refusal:
                    log("the node refused this round's work; retrying")
                    try await Task.sleep(for: .seconds(5))
                }
            }
        }

        /// Wait out a hold in slices, giving up the moment a stop is
        /// requested: `mine stop` must not have to sit through a long wait.
        /// Used for the block cadence.
        private func holdFor(
            _ hold: Duration, stopRequested: InterruptFlag
        ) async {
            let until = ContinuousClock.now.advanced(by: hold)
            while !stopRequested.isRaised {
                let remaining = ContinuousClock.now.duration(to: until)
                guard remaining > .zero else { return }
                try? await Task.sleep(for: min(remaining, .seconds(1)))
            }
        }

        private func log(_ message: String) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            // A direct write is a syscall per line: nothing buffers, so a
            // SIGKILL cannot erase the trail.
            FileHandle.standardOutput.write(
                Data("\(stamp) \(message)\n".utf8)
            )
        }
    }
}

/// Where the miner keeps its state (pidfiles, log, settings), the node it
/// mines through, and its settings file.
struct MinerOptions: ParsableArguments {
    @OptionGroup var target: NodeTarget

    @Option(name: .long, help: "The miner's settings file (default: <root>/\(MinerConfig.fileName), or while there is none the mine object an older <root>/\(Topology.fileName) holds).")
    var config: String?

    var layout: HostLayout { target.layout }

    /// The miner's settings, and a warning when they came from an older
    /// lattice.json's `mine` object.
    func loadConfig() throws -> (config: MinerConfig, warning: String?) {
        if let config { return (try MinerConfig.load(file: URL(fileURLWithPath: config)), nil) }
        return try MinerConfig.load(root: layout.root)
    }

    /// These options as `mine run` takes them, every path absolute: the
    /// background loop runs from another directory.
    var runArguments: [String] {
        var arguments = ["--root", layout.root.path]
        if let config { arguments += ["--config", URL(fileURLWithPath: config).standardizedFileURL.path] }
        if let node = target.node, let tokenFile = target.tokenFile {
            arguments += [
                "--node", node,
                "--token-file", URL(fileURLWithPath: tokenFile).standardizedFileURL.path,
            ]
        }
        return arguments
    }
}

struct MinerSettings {
    let mine: MinerConfig
    let rpc: NodeRPC
    /// How the coordinator authenticates to the node: its bearer token file
    /// or the local node's cookie file.
    let coordinatorAuthentication: [String]
    let workerExecutable: URL
    /// Set when the settings came from an older lattice.json's `mine`.
    let warning: String?
}

/// The node to mine through (a remote one with its token, or the one under
/// --root with its cookie) and the miner's own settings.
func minerSettings(_ options: MinerOptions) throws -> MinerSettings {
    let (mine, warning) = try options.loadConfig()
    let rpc: NodeRPC
    let authentication: [String]
    if let remote = try options.target.remote(), let tokenFile = options.target.tokenFile {
        rpc = remote
        authentication = ["--token-file", URL(fileURLWithPath: tokenFile).standardizedFileURL.path]
    } else {
        let layout = options.layout
        rpc = NodeRPC(try Topology.load(root: layout.root), layout)
        authentication = ["--rpc-cookie-file", layout.rpcCookie.path]
    }
    let worker: URL
    if let path = mine.worker, path != "cpu" {
        worker = URL(fileURLWithPath: path)
    } else {
        worker = try siblingBinary("lattice-miner")
    }
    guard FileManager.default.isExecutableFile(atPath: worker.path) else {
        throw CtlError("worker is not executable: \(worker.path)")
    }
    return MinerSettings(
        mine: mine, rpc: rpc, coordinatorAuthentication: authentication, workerExecutable: worker,
        warning: warning
    )
}

enum CoordinatorOutcome {
    case accepted(tip: String)
    case harmless
    case childOnly
    case refusal
    case workerTrouble(String)
    /// The round outlived its derived bound; its process group was killed.
    /// Carries whether that teardown was DEGRADED -- only the pid could be
    /// signalled -- separately from the deadline itself, because the two vary
    /// independently.
    case roundDeadlineExceeded(Duration, teardownDegraded: Bool)
}

final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

func runCoordinatorOnce(
    _ settings: MinerSettings, layout: HostLayout, deadline: Duration
) async throws -> CoordinatorOutcome {
    let executable = try siblingBinary("lattice-mining-coordinator")
    var arguments = [
        "--node", settings.rpc.baseURL,
    ] + settings.coordinatorAuthentication + [
        "--worker-executable", settings.workerExecutable.path,
        "--workers", String(settings.mine.workers ?? 1),
        "--batch-size", String(settings.mine.batchSize ?? 2_000_000_000),
        "--once",
    ]
    arguments += settings.mine.coordinatorRecipientArguments
    arguments += settings.mine.coordinatorMinimumWorkArguments
    // Delegate to the shared spawn path (fresh /dev/null per spawn +
    // terminationHandler reaping) that ProcessSpawnTests pins.
    let result = try await spawnCollectingOutput(
        executable: executable,
        arguments: arguments,
        deadline: deadline,
        onSpawn: { pid in
            try? writePidFile(
                layout, "mine-coordinator",
                pid: pid, name: "lattice-mining-coordinator"
            )
        }
    )
    try? FileManager.default.removeItem(
        at: layout.pidFile(for: "mine-coordinator")
    )
    if result.outcome == .deadlineExceeded {
        return .roundDeadlineExceeded(
            deadline, teardownDegraded: result.teardownDegraded
        )
    }
    let lines = String(decoding: result.output, as: UTF8.self)
        .split(separator: "\n").reversed()
    for line in lines {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(line.utf8)
        ) as? [String: Any], let kind = object["result"] as? String else {
            continue
        }
        switch kind {
        case "submitted" where object["accepted"] as? Bool == true:
            return .accepted(tip: object["tipCID"] as? String ?? "")
        case "noSolution", "stale":
            return .harmless
        case "submitted" where object["disposition"] as? String == "childOnly":
            // The solution cleared only a child chain's target: the child
            // advances and no parent block was mined. Routine on a merged-mining chain whose child target
            // is easier than the parent's — never a refusal signal.
            return .childOnly
        case "submitted":
            // Accepted was handled above: a rejected submission is a refusal.
            return .refusal
        case "workerFailed", "nodeFailed":
            return .workerTrouble(kind)
        default:
            return .refusal
        }
    }
    return .workerTrouble(
        result.outputComplete
            ? "coordinator produced no result line"
            : "coordinator output was truncated at the round deadline"
    )
}

/// Whether the node answers a template request at all: mining starts only
/// once it does. Nothing in the answer is read.
func nodeAnswersTemplates(
    _ rpc: NodeRPC, body: Data, timeoutSeconds: UInt64
) async -> Bool {
    guard var request = try? rpc.request("mining/templates") else { return false }
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = TimeInterval(timeoutSeconds)
    guard let (_, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse else { return false }
    return http.statusCode == 200
}

// MARK: - The mining loop's background process (`mine start`, `mine stop`)
//
// Recorded by a pidfile under <root>/run, with its output in <root>/log.

/// A live pid is only "ours" if the command name still matches what the
/// pidfile recorded: pids recycle, and killing a stranger is worse than a
/// stale file.
func runningPid(_ layout: HostLayout, _ path: String) -> Int32? {
    guard let recorded = recordedPid(layout, path),
          isAlive(recorded.pid, named: recorded.name) else {
        return nil
    }
    return recorded.pid
}

/// The pid and command name a pidfile records.
private func recordedPid(
    _ layout: HostLayout, _ path: String
) -> (pid: Int32, name: String?)? {
    guard let text = try? String(
        contentsOf: layout.pidFile(for: path), encoding: .utf8
    ) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ", maxSplits: 1)
    guard let pid = parts.first.flatMap({ Int32($0) }) else { return nil }
    return (pid, parts.count == 2 ? String(parts[1]) : nil)
}

/// Whether `pid` is alive and, when a name was recorded, still runs that
/// command.
private func isAlive(_ pid: Int32, named expected: String?) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    if let expected {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["ps", "-o", "comm=", "-p", String(pid)]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return true }
        // Closed here, not left to the pipe's deallocation: a read end left
        // open each time uses up the process's descriptors.
        try? out.fileHandleForWriting.close()
        defer { try? out.fileHandleForReading.close() }
        // Captured while the probe is alive, for the same reason the bounded
        // wait does it: a group derived after the child is reaped is gone.
        let teardown = ProcessTeardownTarget.capture(
            pid: probe.processIdentifier
        )
        // Bounded, and never `waitUntilExit()`: a pid-name probe must not
        // outlive the question it answers (#62). This bound is a local
        // liveness allowance, not a round parameter -- `ps` has none.
        let read = readToEndBounded(
            fileDescriptor: out.fileHandleForReading.fileDescriptor,
            deadline: ContinuousClock.now + .seconds(5)
        )
        if !read.complete {
            terminateProcessGroup(teardown)
            if teardown.isDegraded {
                // Do not report a clean teardown we did not perform: only the
                // pid could be signalled, so anything the probe spawned is
                // still running.
                FileHandle.standardError.write(Data(
                    "warning: pid probe \(probe.processIdentifier) could not be torn down as a group; its descendants may still be running\n".utf8
                ))
            }
            // A probe that timed out says NOTHING about the pid, and a
            // truncated name would fail the suffix check below and report a
            // live node as stopped -- which invites a double spawn. Same
            // convention as the run() failure above: assume running.
            return true
        }
        let name = String(decoding: read.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasSuffix(expected) else { return false }
    }
    return true
}

func writePidFile(
    _ layout: HostLayout, _ path: String, pid: Int32, name: String
) throws {
    try Data("\(pid) \(name)".utf8).write(
        to: layout.pidFile(for: path), options: .atomic
    )
}

/// Exclusive per-root lock so concurrent `mine start`s cannot double-spawn.
func withSpawnLock<T>(
    _ layout: HostLayout, _ body: () async throws -> T
) async throws -> T {
    let lockURL = layout.pidFile(for: "spawn-lock")
    try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    let descriptor = open(lockURL.path, O_RDWR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
        if descriptor >= 0 { close(descriptor) }
        throw CtlError("could not take the spawn lock at \(lockURL.path)")
    }
    defer {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    return try await body()
}

/// Stops a process by pidfile: SIGTERM, then SIGKILL if it lingers, then
/// waits until it is gone, so a spawn after this finds its locks and ports
/// free. Watches the pid it signalled, never a re-read pidfile, and
/// removes the pidfile only while it still names that pid. `grace` is how
/// long SIGTERM gets; `onKill` runs right after the SIGKILL, for anything
/// else the killed process leaves behind. Callers hold the spawn lock.
/// Returns false when the process was not running.
@discardableResult
func stopProcess(
    _ layout: HostLayout, _ name: String,
    grace: Duration = .seconds(30),
    onKill: () -> Void = {}
) async throws -> Bool {
    guard let recorded = recordedPid(layout, name),
          isAlive(recorded.pid, named: recorded.name) else { return false }
    let pid = recorded.pid
    let alive = { isAlive(pid, named: recorded.name) }
    kill(pid, SIGTERM)
    let deadline = ContinuousClock.now + grace
    while alive(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }
    if alive() {
        kill(pid, SIGKILL)
        onKill()
        for _ in 0..<100 where alive() {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !alive() else {
            throw CtlError("\(name) (pid \(pid)) survived SIGKILL for 10s")
        }
    }
    layout.removePidFile(for: name, ifNaming: pid)
    return true
}
