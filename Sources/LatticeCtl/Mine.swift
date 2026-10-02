// Mining role: coordinator + worker beside a chain's node, one --once batch
// per round. Each block pays the configured recipient for its chain (the
// block's `rewardRecipient`); a chain with none burns its reward and fees.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeCtlCore
import LatticeMinerCore
import LatticeMiningCoordinator
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

        @OptionGroup var rootOption: RootOption

        func run() async throws {
            let layout = rootOption.layout
            let settings = try minerSettings(layout)
            let running = runningPid(layout, "mine").map { "running (pid \($0))" }
                ?? "stopped"
            print("mining: \(running)")
            print("chain:  \(settings.mine.chain)")
            let recipients = settings.mine.recipientEntries
            if recipients.isEmpty {
                print("recipients: none configured (rewards and fees burn)")
            } else {
                for entry in recipients { print("recipient: \(entry)") }
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
            // Finish the in-flight batch on SIGTERM: killing mid-iteration can
            // orphan a coordinator.
            //
            // The flag is only read at the top of the loop and inside
            // `holdFor`, so it does NOT cut short an in-flight HTTP call. A
            // SIGTERM landing mid-probe waits out the rest of
            // mine.templateTimeoutSeconds before this notices. On a node
            // answering normally that is not visible, but on one slow enough
            // to need the timeout a stop can outlast `mine stop`'s own 60s
            // grace, ending in SIGKILL.
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
            let templateRequestBody = try MiningTemplateRequestBody.make(
                recipients: settings.mine.recipientEntries,
                deployment: false,
                minimumWork: settings.mine.minimumWorkEntries
            )
            log("mining loop start"
                + (settings.mine.minBlockIntervalSeconds.map {
                    ", pacing parent blocks at least \($0)s apart"
                } ?? ""))
            while !stopRequested.isRaised {
                let outcome: CoordinatorOutcome
                let started = ContinuousClock.now
                do {
                    if templateExpiry == nil {
                        // Marked BEFORE the attempt: an attempt can itself take
                        // the full timeout, so stamping it afterwards would
                        // report ~0 elapsed in the very line that says the node
                        // did not answer for that long.
                        unusableTemplateSince = unusableTemplateSince
                            ?? ContinuousClock.now
                        // Template lifetime is node-wide, but the node
                        // adopts each request's plan for its descendants, so
                        // the probe sends the coordinator's own body: any
                        // other would churn their candidates.
                        templateExpiry = await observedTemplateExpiry(
                            settings.rpc,
                            body: templateRequestBody,
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
                        log("NOT MINING: no usable template answer from the node (no reply within \(templateTimeout)s, a non-200, or a reply with no expiry), so no round deadline can be derived. Stopped for \(downFor.components.seconds)s so far; check `POST /mining/templates` on this node.")
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
                        log("pacing: holding \(hold) so the next block is at least mine.minBlockIntervalSeconds from this one")
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
                    log("ROUND DEADLINE EXCEEDED after \(deadline): the coordinator process group was killed and the round abandoned. Raise mine.roundDeadlineMultiplier in lattice.json if rounds here legitimately run this long.")
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

struct MinerSettings {
    let mine: TopologyMine
    let rpc: UInt16
    let workerExecutable: URL
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
    if MinerLoopLogic.recipientField(mine.recipientEntries) == nil {
        throw CtlError("mine.recipients maps chain paths to addresses")
    }
    if MinerLoopLogic.minimumWorkField(mine.minimumWorkEntries) == nil {
        throw CtlError("mine.minWork maps chain paths to work per block, as 2^N or a positive decimal integer")
    }
    return MinerSettings(
        mine: mine, rpc: chain.rpc, workerExecutable: worker
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
    let executable = try nodeBinary().deletingLastPathComponent()
        .appendingPathComponent("lattice-mining-coordinator")
    var arguments = [
        "--node", "http://127.0.0.1:\(settings.rpc)",
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

/// The round bound the NODE itself advertises: `expiresInMilliseconds` from
/// a template request. Observed, never assumed -- the mining round deadline
/// is derived from this plus measured batch time, so no template lifetime is
/// hardcoded on this side of the RPC.
func observedTemplateExpiry(
    _ rpc: UInt16, body: Data, timeoutSeconds: UInt64
) async -> Duration? {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/mining/templates"
    ) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
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
