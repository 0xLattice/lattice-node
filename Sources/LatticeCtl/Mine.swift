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
            let stopRequested = InterruptFlag()
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM)
            source.setEventHandler { stopRequested.raise() }
            source.resume()
            log("mining loop start at reward cursor \(cursor)")
            while !stopRequested.isRaised {
                let outcome: CoordinatorOutcome
                do {
                    let rewardsFile = try prepareRewardsFile(
                        settings, cursor: cursor, layout: layout
                    )
                    outcome = try await runCoordinatorOnce(
                        settings, rewardsFile: rewardsFile, layout: layout
                    )
                } catch {
                    // A spawn/IO failure proves nothing about the reward and
                    // must never advance the cursor or kill the loop: retry.
                    log("reward \(cursor) retrying after spawn error: \(error)")
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                switch outcome {
                case .accepted(let tip):
                    log("reward \(cursor) accepted tip=\(tip.prefix(24))")
                    cursor += 1
                    writeCursor(layout, cursor)
                    refusedStreak = 0
                case .harmless:
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
                    if await templateProbe(rpc, batch[cursor]) == .refused,
                       cursor + 1 < batch.count,
                       await templateProbe(rpc, batch[cursor + 1]) == .accepted {
                        log("reward \(cursor) already spent on-chain; advancing")
                        cursor += 1
                        writeCursor(layout, cursor)
                        refusedStreak = 0
                    } else if await health(rpc: rpc) != nil,
                              await templateProbe(rpc, batch[cursor]) == .refused {
                        log("REWARD BATCH STALLED at \(cursor): this line and the next are both refused; re-emit the batch")
                        try await Task.sleep(for: .seconds(60))
                    } else {
                        try await Task.sleep(for: .seconds(5))
                    }
                }
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
    case refusal
    case workerTrouble(String)
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
    _ settings: MinerSettings, rewardsFile: URL?, layout: HostLayout
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
    // Delegate to the shared spawn path (fresh /dev/null per spawn +
    // terminationHandler reaping) that ProcessSpawnTests pins.
    let data = try await spawnCollectingOutput(
        executable: executable,
        arguments: arguments,
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
    let lines = String(decoding: data, as: UTF8.self)
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
    return .workerTrouble("coordinator produced no result line")
}

enum ProbeResult { case accepted, refused, unavailable }

func templateProbe(_ rpc: UInt16, _ rewardLine: String) async -> ProbeResult {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/v1/mining/templates"
    ) else { return .unavailable }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(rewardLine.utf8)
    request.timeoutInterval = 15
    guard let (_, response) = try? await URLSession.shared.data(
        for: request
    ), let http = response as? HTTPURLResponse else { return .unavailable }
    if http.statusCode == 200 { return .accepted }
    return http.statusCode == 400 ? .refused : .unavailable
}
