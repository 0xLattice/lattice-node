// Mining role: coordinator + worker beside a chain's node, one --once batch
// per block, one pre-signed reward per block in nonce order. The cursor
// advances only on an accepted block or the paired-probe spent-nonce
// signature (line i refused at template build while line i+1 builds); both
// refused stalls loudly. Same discipline as deploy/mine-supervisor.py.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeCtlCore
import LatticeMinerCore
import LatticeProcessWait

struct Mine: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mine beside a chain in the tree.",
        subcommands: [Start.self, Run.self, Stop.self, MineStatus.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the mining loop in the background."
        )

        @OptionGroup var rootOption: RootOption

        func run() async throws {
            let layout = rootOption.layout
            _ = try minerSettings(layout)
            try await withSpawnLock(layout) {
                try self.startLocked(layout)
            }
        }

        private func startLocked(_ layout: HostLayout) throws {
            if let pid = runningPid(layout, "mine") {
                throw CtlError("mining already running (pid \(pid))")
            }
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: CommandLine.arguments[0]
            ).resolvingSymlinksInPath()
            process.arguments = ["mine", "run", "--root", layout.root.path]
            let log = layout.logFile(for: "mine")
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
            guard let pid = runningPid(layout, "mine") else {
                print("mining not running")
                return
            }
            // Graceful: the loop finishes its batch and persists the cursor.
            kill(pid, SIGTERM)
            for _ in 0..<600 where runningPid(layout, "mine") != nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            if runningPid(layout, "mine") != nil {
                kill(pid, SIGKILL)
                if let coordinator = runningPid(layout, "mine-coordinator") {
                    kill(coordinator, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(
                at: layout.pidFile(for: "mine")
            )
            print("mining stopped")
        }
    }

    struct MineStatus: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Cursor position and batch runway."
        )

        @OptionGroup var rootOption: RootOption

        func run() async throws {
            let layout = rootOption.layout
            let settings = try minerSettings(layout)
            let running = runningPid(layout, "mine").map { "running (pid \($0))" }
                ?? "stopped"
            let cursor = readCursor(layout)
            print("mining: \(running)")
            print("chain:  \(settings.mine.chain)")
            if let total = settings.batch?.count {
                print("rewards: \(cursor) of \(total) consumed, \(total - min(cursor, total)) remaining")
            } else {
                print("rewards: none configured (blocks pay nobody)")
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Foreground mining loop (used by `mine start`).",
            shouldDisplay: false
        )

        @OptionGroup var rootOption: RootOption

        func run() async throws {
            let layout = rootOption.layout
            let settings = try minerSettings(layout)
            var cursor = readCursor(layout)
            var refusedStreak = 0
            // Finish the in-flight batch and persist the cursor on SIGTERM:
            // killing mid-iteration can orphan a coordinator whose accepted
            // block would leave the cursor behind the chain.
            //
            // The flag is only read at the top of the loop and inside
            // `holdFor`, so it does NOT cut short an in-flight HTTP call. A
            // SIGTERM landing mid-probe waits out the rest of
            // mine.templateTimeoutSeconds before this notices, and the
            // refusal-heal branch is worse: up to three `templateProbe` calls
            // plus a `health` call back to back. On a node answering normally
            // none of that is visible, but on one slow enough to need these
            // timeouts a stop can outlast `mine stop`'s own 60s grace, and on
            // the refusal path `TimeoutStopSec` too, ending in SIGKILL.
            // Nothing is lost when it does -- the cursor only advances after
            // an accepted block and is written atomically -- but the stop is
            // then not the graceful one this comment otherwise describes.
            let stopRequested = InterruptFlag()
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM)
            source.setEventHandler { stopRequested.raise() }
            source.resume()
            let multiplier = settings.mine.roundDeadlineMultiplier
                ?? MiningRoundDeadline.defaultMultiplier
            let templateTimeout = settings.mine.resolvedTemplateTimeoutSeconds
            // Measured, not assumed: a wedged round never completes, so it
            // can never widen the bound that would have caught it.
            var longestCompletedRound = Duration.zero
            var templateExpiry: Duration?
            var unusableTemplateSince: ContinuousClock.Instant?
            log("mining loop start at reward cursor \(cursor)"
                + (settings.mine.minBlockIntervalSeconds.map {
                    ", pacing parent blocks at least \($0)s apart"
                } ?? ""))
            while !stopRequested.isRaised {
                let outcome: CoordinatorOutcome
                let started = ContinuousClock.now
                do {
                    let rewardsFile = try prepareRewardsFile(
                        settings, cursor: cursor, layout: layout
                    )
                    if templateExpiry == nil {
                        // Marked BEFORE the attempt: an attempt can itself take
                        // the full timeout, so stamping it afterwards would
                        // report ~0 elapsed in the very line that says the node
                        // did not answer for that long.
                        unusableTemplateSince = unusableTemplateSince
                            ?? ContinuousClock.now
                        // NEVER the cursor's reward line. The node answers
                        // 400 once that line is no longer mineable -- the
                        // same "already spent on-chain" condition the
                        // refusal branch below heals -- and a nil expiry
                        // would then wedge this loop forever WITHOUT ever
                        // reaching that branch. Template lifetime is
                        // node-wide, so an empty rewards body observes it
                        // without entangling it with reward validity.
                        templateExpiry = await observedTemplateExpiry(
                            settings.rpc, rewardsFile: nil,
                            timeoutSeconds: templateTimeout
                        )
                    }
                    guard let expiry = templateExpiry else {
                        // No observation, no derived bound -- and an
                        // unbounded round is the defect itself. But say so as
                        // the standstill it is: this retries forever, and the
                        // old wording read like a passing hiccup while the
                        // miner produced nothing for as long as it lasted.
                        //
                        // State the OBSERVATION, not a cause: no usable answer
                        // covers a timeout, a transport failure, a non-200
                        // (the node answers 409 while bootstrapping and 503
                        // when the mempool or parent is unavailable -- both
                        // fast), and a reply carrying no expiry. Naming any one
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
                        log("reward \(cursor) NOT MINING: no usable template answer from the node (no reply within \(templateTimeout)s, a non-200, or a reply with no expiry), so no round deadline can be derived. Stopped for \(downFor.components.seconds)s so far; check `POST /v1/mining/templates` on this node.")
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    }
                    unusableTemplateSince = nil
                    let deadline = MiningRoundDeadline.deadline(
                        templateExpiry: expiry,
                        longestCompletedRound: longestCompletedRound,
                        multiplier: multiplier
                    )
                    outcome = try await runCoordinatorOnce(
                        settings, rewardsFile: rewardsFile, layout: layout,
                        deadline: deadline
                    )
                } catch {
                    // A spawn/IO failure proves nothing about the reward and
                    // must never advance the cursor or kill the loop: retry.
                    log("reward \(cursor) retrying after spawn error: \(error)")
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                // Only a round that actually produced a coordinator
                // result measures batch time. A round that burned its budget
                // failing -- worker/node trouble, or the deadline itself --
                // would inflate the very bound meant to catch it.
                switch outcome {
                case .accepted, .harmless, .carrier, .refusal:
                    longestCompletedRound = max(
                        longestCompletedRound,
                        started.duration(to: ContinuousClock.now)
                    )
                case .workerTrouble, .roundDeadlineExceeded:
                    break
                }
                switch outcome {
                case .accepted(let tip):
                    log("reward \(cursor) accepted tip=\(tip.prefix(24))")
                    cursor += 1
                    writeCursor(layout, cursor)
                    refusedStreak = 0
                    let hold = settings.mine.pacingHold(
                        afterRoundOf: started.duration(to: ContinuousClock.now)
                    )
                    if hold > .zero {
                        log("pacing: holding \(hold) so the next block is at least mine.minBlockIntervalSeconds from this one")
                        await holdFor(hold, stopRequested: stopRequested)
                    }
                case .harmless:
                    refusedStreak = 0
                case .carrier:
                    // A child chain advanced; no reward consumed and no parent
                    // block was produced, so this starts no pacing hold. Note
                    // that is about the TRIGGER, not the effect: a hold
                    // withholds the next round, and a round is what co-mines
                    // the children, so pacing throttles the whole subtree.
                    refusedStreak = 0
                case .roundDeadlineExceeded(let deadline, let degraded):
                    // Loud by construction: a silent kill-and-continue is
                    // the original failure mode wearing a fix's clothes.
                    log("ROUND DEADLINE EXCEEDED after \(deadline): the coordinator process group was killed and the round abandoned. Reward cursor stays at \(cursor). Raise mine.roundDeadlineMultiplier in lattice.json if rounds here legitimately run this long.")
                    if degraded {
                        // State the fact; do not decide for the operator what
                        // it means. A teardown that could only signal the pid
                        // is not the clean one the line above implies.
                        log("ROUND TEARDOWN DEGRADED: only the coordinator pid could be signalled, not its process group, so processes it spawned may still be running and holding resources. Check for stray lattice-miner processes.")
                    }
                    refusedStreak = 0
                case .workerTrouble(let detail):
                    log("reward \(cursor) retrying after \(detail)")
                    try await Task.sleep(for: .seconds(5))
                case .refusal:
                    refusedStreak += 1
                    guard refusedStreak >= 3,
                          let batch = settings.batch,
                          cursor < batch.count else {
                        try await Task.sleep(for: .seconds(5))
                        continue
                    }
                    let rpc = settings.rpc
                    if await templateProbe(rpc, batch[cursor], timeoutSeconds: templateTimeout) == .refused,
                       cursor + 1 < batch.count,
                       await templateProbe(rpc, batch[cursor + 1], timeoutSeconds: templateTimeout) == .accepted {
                        log("reward \(cursor) already spent on-chain; advancing")
                        cursor += 1
                        writeCursor(layout, cursor)
                        refusedStreak = 0
                    } else if await health(rpc: rpc) != nil,
                              await templateProbe(rpc, batch[cursor], timeoutSeconds: templateTimeout) == .refused {
                        log("REWARD BATCH STALLED at \(cursor): this line and the next are both refused; re-emit the batch")
                        // Stop-aware: this is the longest wait in the loop, and
                        // it sits on the path whose probes already delay a stop
                        // the most. A bare sleep here made `mine stop` wait out
                        // a full minute of a wait that exists only to avoid
                        // spinning.
                        await holdFor(.seconds(60), stopRequested: stopRequested)
                    } else {
                        try await Task.sleep(for: .seconds(5))
                    }
                }
            }
        }

        /// Wait out a hold in slices, giving up the moment a stop is
        /// requested: `mine stop` must not have to sit through a long wait.
        /// Used for the block cadence and for the stalled-batch backoff.
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

struct MinerSettings {
    let mine: TopologyMine
    let rpc: UInt16
    let workerExecutable: URL
    let batch: [String]?
}

func minerSettings(_ layout: HostLayout) throws -> MinerSettings {
    let topology = try Topology.load(root: layout.root).validated()
    guard let mine = topology.mine else {
        throw CtlError("no [mine] section in \(Topology.fileName)")
    }
    let chain = topology.chains[mine.chain]!
    let worker: URL
    if let path = mine.worker, path != "cpu" {
        worker = URL(fileURLWithPath: path)
    } else {
        worker = try nodeBinary().deletingLastPathComponent()
            .appendingPathComponent("lattice-miner")
    }
    guard FileManager.default.isExecutableFile(atPath: worker.path) else {
        throw CtlError("worker is not executable: \(worker.path)")
    }
    var batch: [String]?
    if let rewards = mine.rewards {
        let url = URL(
            fileURLWithPath: rewards,
            relativeTo: layout.root
        )
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CtlError("rewards batch not readable: \(url.path)")
        }
        batch = text.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
    }
    if MinerLoopLogic.minimumWorkField(mine.minimumWorkEntries) == nil {
        throw CtlError("mine.minWork maps chain paths to work per block, as 2^N or a positive decimal integer")
    }
    return MinerSettings(
        mine: mine, rpc: chain.rpc, workerExecutable: worker, batch: batch
    )
}

func readCursor(_ layout: HostLayout) -> Int {
    (try? String(
        contentsOf: layout.pidFile(for: "mine-cursor"), encoding: .utf8
    )).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
}

func writeCursor(_ layout: HostLayout, _ cursor: Int) {
    try? Data(String(cursor).utf8).write(
        to: layout.pidFile(for: "mine-cursor"), options: .atomic
    )
}

func prepareRewardsFile(
    _ settings: MinerSettings, cursor: Int, layout: HostLayout
) throws -> URL? {
    guard let batch = settings.batch, cursor < batch.count else { return nil }
    let url = layout.pidFile(for: "mine-rewards")
    try Data(batch[cursor].utf8).write(to: url, options: .atomic)
    return url
}

enum CoordinatorOutcome {
    case accepted(tip: String)
    case harmless
    case carrier
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
    _ settings: MinerSettings, rewardsFile: URL?, layout: HostLayout,
    deadline: Duration
) async throws -> CoordinatorOutcome {
    let executable = try nodeBinary().deletingLastPathComponent()
        .appendingPathComponent("lattice-mining-coordinator")
    var arguments = [
        "--node", "http://127.0.0.1:\(settings.rpc)",
        "--worker-executable", settings.workerExecutable.path,
        "--workers", String(settings.mine.workers ?? 1),
        "--batch-size", String(settings.mine.batchSize ?? 2_000_000_000),
        "--once",
    ]
    if let rewardsFile {
        arguments += ["--rewards-file", rewardsFile.path]
    }
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
        case "submitted" where object["disposition"] as? String == "carrier":
            // The solution cleared only a child chain's target: the child
            // advances, no parent block was mined, and the reward line is
            // untouched. Routine on a merged-mining chain whose child target
            // is easier than the parent's — never a refusal signal.
            return .carrier
        case "submitted":
            // Accepted was handled above: a rejected submission behaves like
            // a refusal so the paired probe can heal an accept-then-crash.
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

/// The round bound the NODE itself advertises: `expiresInMilliseconds` from
/// a template request. Observed, never assumed -- the mining round deadline
/// is derived from this plus measured batch time, so no template lifetime is
/// hardcoded on this side of the RPC.
func observedTemplateExpiry(
    _ rpc: UInt16, rewardsFile: URL?, timeoutSeconds: UInt64
) async -> Duration? {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/v1/mining/templates"
    ) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = rewardsFile.flatMap { try? Data(contentsOf: $0) }
        ?? Data(#"{"rewards":[]}"#.utf8)
    request.timeoutInterval = TimeInterval(timeoutSeconds)
    guard let (data, response) = try? await URLSession.shared.data(
        for: request
    ), let http = response as? HTTPURLResponse, http.statusCode == 200,
       let object = try? JSONSerialization.jsonObject(
           with: data
       ) as? [String: Any],
       let milliseconds = (object["expiresInMilliseconds"] as? NSNumber)?
           .int64Value, milliseconds > 0 else {
        return nil
    }
    return .milliseconds(milliseconds)
}

enum ProbeResult { case accepted, refused, unavailable }

func templateProbe(
    _ rpc: UInt16, _ rewardLine: String, timeoutSeconds: UInt64
) async -> ProbeResult {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/v1/mining/templates"
    ) else { return .unavailable }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(rewardLine.utf8)
    request.timeoutInterval = TimeInterval(timeoutSeconds)
    guard let (_, response) = try? await URLSession.shared.data(
        for: request
    ), let http = response as? HTTPURLResponse else { return .unavailable }
    if http.statusCode == 200 { return .accepted }
    return http.statusCode == 400 ? .refused : .unavailable
}
