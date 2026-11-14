import Foundation
import LatticeCtlCore
import LatticeProcessWait

/// Mining, as the node's configuration says (`mine.enabled`): the node runs
/// the mining loop `lattice mine run --root <root>` (the `lattice` beside
/// this binary) as its child while mining is on, starts it again when it
/// exits on its own (after a pause that grows while it keeps failing), and
/// stops it when mining is turned off, the `mine` section changes (the loop
/// reads it at its start) or the node stops. The loop also exits when this
/// node does: it is told this process's pid and leaves once that is no
/// longer its parent, so a node killed outright leaves no miner behind.
///
/// A stop cuts the round in flight: the loop is asked to stop (SIGTERM) and
/// its coordinator's process group is ended, so a stop takes seconds, not a
/// batch (which can run for minutes).
///
/// The loop is the one `lattice mine start` ran before the node supervised
/// it, round deadlines, pacing and template probe included: one mining
/// implementation, now with one owner.
actor MinerSupervisor {
    let layout: HostLayout
    private let executable: URL?
    private var desired: TopologyMine?
    private var running: (process: Process, mine: TopologyMine, since: ContinuousClock.Instant)?
    private var reconciling = false
    private var dirty = false
    private var restarts = 0
    /// Exits in a row of loops that ran less than a minute: the pause before
    /// the next start doubles with each, to five minutes.
    private var failures = 0
    private var lastExit: String?
    private var checkedLegacy = false

    /// `executable` runs the loop (`mine run ...`); the `lattice` beside this
    /// binary unless given.
    init(layout: HostLayout, executable: URL? = nil) {
        self.layout = layout
        self.executable = executable ?? Self.lattice
    }

    /// The `lattice` binary beside this one, which runs the loop.
    static var lattice: URL? {
        let own = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        return [own.appendingPathComponent("lattice"), URL(fileURLWithPath: "/usr/local/bin/lattice")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Refuses a `mine` section this node cannot mine with, before it is
    /// kept: the loop's binary and the worker must be executables here.
    static func check(_ mine: TopologyMine?) throws {
        guard let mine, mine.enabled == true else { return }
        guard let lattice else {
            throw OperatorConfigError.invalid("mining needs the lattice binary beside lattice-node or in /usr/local/bin")
        }
        let worker = mine.worker.flatMap { $0 == "cpu" ? nil : URL(fileURLWithPath: $0) }
            ?? lattice.deletingLastPathComponent().appendingPathComponent("lattice-miner")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw OperatorConfigError.invalid("mine.worker is not executable here: \(worker.path)")
        }
    }

    /// Mine as `mine` says from now on. Returns at once; the loop is stopped
    /// and started in the background.
    func apply(_ mine: TopologyMine?) {
        desired = mine?.enabled == true ? mine : nil
        Task { await reconcile() }
    }

    func status() -> MiningStatusResponse {
        MiningStatusResponse(
            enabled: desired != nil,
            running: running?.process.isRunning == true,
            pid: running.map { $0.process.processIdentifier },
            restarts: restarts,
            lastExit: lastExit,
            recipients: (running?.mine ?? desired)?.recipients ?? [:]
        )
    }

    /// Stops the loop for good: the node is stopping or restarting.
    func stop() async {
        desired = nil
        if let current = running {
            running = nil
            await terminate(current.process)
        }
    }

    private func reconcile() async {
        guard !reconciling else {
            dirty = true
            return
        }
        reconciling = true
        defer { reconciling = false }
        if !checkedLegacy {
            checkedLegacy = true
            await stopLegacyLoop()
        }
        repeat {
            dirty = false
            if let current = running, !same(current.mine, desired) || !current.process.isRunning {
                running = nil
                await terminate(current.process)
            }
            if running == nil, let mine = desired {
                do {
                    running = (try start(), mine, .now)
                } catch {
                    lastExit = "could not start: \(error)"
                    print("mining: could not start the loop: \(error)")
                }
            }
        } while dirty
    }

    private func same(_ lhs: TopologyMine?, _ rhs: TopologyMine?) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    private func start() throws -> Process {
        guard let executable else {
            throw OperatorConfigError.invalid("no lattice binary beside lattice-node")
        }
        // Appended to, never truncated: a crashed loop's last words stay.
        let log = layout.logFile(for: "mine")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "mine", "run", "--root", layout.root.path, "--parent-pid", String(getpid()),
        ]
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in
            Task { await self?.exited(exited) }
        }
        try process.run()
        try? handle.close()
        print("mining: loop started (pid \(process.processIdentifier)), log \(log.path)")
        return process
    }

    /// The loop exited. One the node did not stop is started again after a
    /// pause, for as long as mining stays on.
    private func exited(_ process: Process) async {
        guard let current = running, current.process === process else { return }
        running = nil
        failures = current.since.duration(to: .now) < .seconds(60) ? failures + 1 : 0
        let pause = Duration.seconds(min(5 << min(failures, 6), 300))
        lastExit = "exited with status \(process.terminationStatus); starting again in \(pause.components.seconds)s (see log/mine.log)"
        print("mining: loop \(lastExit ?? "")")
        try? await Task.sleep(for: pause)
        guard desired != nil, running == nil else { return }
        restarts += 1
        await reconcile()
    }

    /// Asks the loop to stop and ends its round's coordinator at once, then
    /// kills the loop if it has not left within 10s.
    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        let loop = ProcessTeardownTarget.capture(pid: process.processIdentifier)
        process.terminate()
        await endCoordinator(of: process.processIdentifier)
        let deadline = ContinuousClock.now + .seconds(10)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            terminateProcessGroup(loop)
            kill(process.processIdentifier, SIGKILL)
            for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        }
        print("mining: loop stopped")
    }

    /// The coordinator the loop `parent` runs now, by its pidfile, ended with
    /// its process group: only a live `lattice-mining-coordinator` whose
    /// parent is that loop, never whatever a stale pidfile names.
    private func endCoordinator(of parent: Int32) async {
        guard let pid = recordedPid("mine-coordinator"),
              let process = await processInfo(pid),
              process.parent == parent, process.command.contains("lattice-mining-coordinator") else { return }
        terminateProcessGroup(ProcessTeardownTarget.capture(pid: pid))
    }

    /// A loop an earlier `lattice mine start` ran on its own (its pidfile
    /// `run/mine.pid`): stopped, as the node mines now.
    private func stopLegacyLoop() async {
        guard let pid = recordedPid("mine"), let process = await processInfo(pid),
              process.command.contains("lattice"), process.command.contains("mine run") else { return }
        print("mining: stopping the loop an earlier `lattice mine start` ran (pid \(pid)); the node runs mining now")
        kill(pid, SIGTERM)
        await endCoordinator(of: pid)
        for _ in 0..<100 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: layout.pidFile(for: "mine"))
    }

    private func recordedPid(_ name: String) -> Int32? {
        (try? String(contentsOf: layout.pidFile(for: name), encoding: .utf8))
            .flatMap { $0.split(separator: " ").first }
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// A live process's parent and command line: from /proc where there is
    /// one (a container may have no `ps`), else from `ps`.
    private func processInfo(_ pid: Int32) async -> (parent: Int32, command: String)? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let cmdline = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")) {
            // pid (comm) state ppid ...: comm may hold spaces, so after its ")".
            let fields = stat[(stat.lastIndex(of: ")") ?? stat.startIndex)...].split(separator: " ")
            guard fields.count > 2, fields[1] != "Z", let parent = Int32(fields[2]) else { return nil }
            let command = String(decoding: cmdline, as: UTF8.self).replacingOccurrences(of: "\0", with: " ")
            return (parent, command.trimmingCharacters(in: .whitespaces))
        }
        guard let result = try? await spawnCollectingOutput(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "ppid=", "-o", "args=", "-p", String(pid)],
            deadline: .seconds(5)
        ) else { return nil }
        let line = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = line.firstIndex(of: " "), let parent = Int32(line[..<space]) else { return nil }
        return (parent, String(line[space...]).trimmingCharacters(in: .whitespaces))
    }
}
