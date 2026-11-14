import Foundation
import LatticeCtlCore

/// Mining, as the node's configuration says (`mine.enabled`): the node runs
/// the mining loop `lattice mine run --root <root>` (the `lattice` beside
/// this binary) as its child while mining is on, starts it again when it
/// exits on its own, and stops it (SIGTERM, which lets the loop finish its
/// batch) when mining is turned off, the `mine` section changes (the loop
/// reads it at its start) or the node stops. The loop also exits when this
/// node does: it is told this process's pid and leaves once that is no
/// longer its parent, so a node killed outright leaves no miner behind.
///
/// The loop is the one `lattice mine start` ran before the node supervised
/// it, round deadlines, pacing and template probe included: one mining
/// implementation, now with one owner.
actor MinerSupervisor {
    let layout: HostLayout
    private var desired: TopologyMine?
    private var running: (process: Process, mine: TopologyMine)?
    private var reconciling = false
    private var dirty = false
    private var restarts = 0
    private var lastExit: String?

    init(layout: HostLayout) {
        self.layout = layout
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
        repeat {
            dirty = false
            if let current = running, !same(current.mine, desired) || !current.process.isRunning {
                running = nil
                await terminate(current.process)
            }
            if running == nil, let mine = desired {
                do {
                    running = (try start(), mine)
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
        guard let lattice = Self.lattice else {
            throw OperatorConfigError.invalid("no lattice binary beside lattice-node")
        }
        let log = layout.logFile(for: "mine")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = lattice
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
        guard running?.process === process else { return }
        running = nil
        lastExit = "exited with status \(process.terminationStatus)"
        print("mining: loop \(lastExit ?? "") on its own; starting it again in 5s")
        try? await Task.sleep(for: .seconds(5))
        guard desired != nil, running == nil else { return }
        restarts += 1
        await reconcile()
    }

    /// SIGTERM, then SIGKILL (and the round's coordinator with it) after 20s.
    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(20)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let coordinator = layout.pidFile(for: "mine-coordinator")
            if let text = try? String(contentsOf: coordinator, encoding: .utf8),
               let pid = text.split(separator: " ").first.flatMap({ Int32($0) }) {
                kill(pid, SIGKILL)
            }
            for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        }
        print("mining: loop stopped")
    }
}
