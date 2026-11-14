// Tree lifecycle: one lattice-node process hosts the whole topology. `up`
// spawns `lattice-node --root`, which reads lattice.json and owns it while it
// runs, and exits (its pidfile + loopback health are the record); `down`
// stops it by pidfile; `status` asks the node. `wipe` removes chain state,
// never identity.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
import LatticeProcessWait
import LatticeNode
import LatticeNodeAPI

func nodeBinary() throws -> URL {
    let own = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    for candidate in [
        own.appendingPathComponent("lattice-node"),
        URL(fileURLWithPath: "/usr/local/bin/lattice-node"),
    ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw CtlError("lattice-node not found beside lattice or in /usr/local/bin")
}

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
        // Closed here, not left to the pipe's deallocation: `up --foreground`
        // asks this every second for as long as the node runs, and a read
        // end left open each time uses up the process's descriptors in a
        // few hours.
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

/// Exclusive per-root lock so concurrent invocations cannot double-spawn.
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

func health(rpc: NodeRPC, chain: String = "Nexus") async -> [String: Any]? {
    guard var request = try? rpc.request("health", chain: chain) else {
        return nil
    }
    request.timeoutInterval = 5
    guard let (data, _) = try? await URLSession.shared.data(for: request) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The pidfile and log name of the one daemon hosting the whole tree.
let hostProcessName = "lattice-node"

/// Starts the one `lattice-node` for the hosted tree: `lattice-node --root`,
/// which reads lattice.json itself and owns it while it runs.
func spawnHost(layout: HostLayout) throws {
    let manager = FileManager.default
    for directory in [
        layout.pidFile(for: hostProcessName).deletingLastPathComponent(),
        layout.logFile(for: hostProcessName).deletingLastPathComponent(),
    ] {
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
    _ = try Topology.load(root: layout.root).validated()
    let process = Process()
    process.executableURL = try nodeBinary()
    process.arguments = ["--root", layout.root.path]
    let log = layout.logFile(for: hostProcessName)
    _ = manager.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    handle.seekToEndOfFile()
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    try writePidFile(
        layout, hostProcessName, pid: process.processIdentifier,
        name: "lattice-node"
    )
}

/// Every chain path the one process hosts: Nexus and its listed children.
func hostedPaths(_ topology: Topology) -> [String] {
    [ChainAddress.nexus] + (topology.hostedChains ?? [])
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

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the one process hosting every chain in the tree, as lattice.json says; the node owns that file while it runs."
    )

    @OptionGroup var rootOption: RootOption

    @Flag(name: .long, help: "Stay in the foreground and restart the process if it exits (container PID 1).")
    var foreground = false

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        guard foreground else {
            try await reconcileHost(layout, topology: topology)
            return
        }

        // As container PID 1 or a systemd foreground process, own the child
        // shutdown too. Otherwise terminating this supervisor makes the
        // runtime kill lattice-node instead of giving SQLite and Ivy a clean
        // stop.
        let stopRequested = InterruptFlag()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
        termination.setEventHandler { stopRequested.raise() }
        interrupt.setEventHandler { stopRequested.raise() }
        termination.resume()
        interrupt.resume()
        defer {
            termination.cancel()
            interrupt.cancel()
        }

        try await reconcileHost(layout, topology: topology)
        while !stopRequested.isRaised {
            try await Task.sleep(for: .seconds(1))
            guard !stopRequested.isRaised else { break }
            try await withSpawnLock(layout) {
                guard runningPid(layout, hostProcessName) == nil else { return }
                print("exited; restarting")
                try spawnHost(layout: layout)
            }
        }
        try await withSpawnLock(layout) {
            _ = try await stopProcess(layout, hostProcessName)
        }
        print("stopped")
    }

    private func reconcileHost(
        _ layout: HostLayout,
        topology: Topology
    ) async throws {
        try await withSpawnLock(layout) {
            // A running node owns lattice.json: changes go through it
            // (`lattice config set`, `child create`, ...), not a restart here.
            if let pid = runningPid(layout, hostProcessName) {
                print("already running (pid \(pid))")
                return
            }
            try spawnHost(layout: layout)
            print("started \(hostedPaths(topology).count) chain(s) (pid \(runningPid(layout, hostProcessName) ?? -1))")
        }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the one process hosting the tree."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        // Under the spawn lock, so no `up`, restart or deploy spawns while
        // this stops. A running `up --foreground` respawns once the lock is
        // released, as documented: it is the supervisor, so stop it first.
        try await withSpawnLock(layout) {
            guard runningPid(layout, hostProcessName) != nil else { return }
            try await stopProcess(layout, hostProcessName)
            print("stopped")
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One line per hosted chain, mining, and what waits for a restart."
    )

    @OptionGroup var target: NodeTarget

    func run() async throws {
        guard let rpc = try await target.running() else {
            let topology = try Topology.load(root: target.layout.root).validated()
            for path in hostedPaths(topology) { print("\(path): down") }
            return
        }
        let hosted = try JSONDecoder().decode(
            HostedChainsResponse.self, from: try await send(rpc: rpc, "GET", "hosted-chains")
        )
        for path in [ChainAddress.nexus] + hosted.chains {
            guard let health = await health(rpc: rpc, chain: path) else {
                print("\(path): running, rpc unreachable")
                continue
            }
            let phase = health["phase"] as? String ?? "?"
            let height = health["height"] as? String ?? "-"
            let tip = (health["tipCID"] as? String)?.prefix(20) ?? "-"
            let mempool = health["mempoolCount"] as? Int ?? 0
            print("\(path): \(phase) height=\(height) tip=\(tip)… mempool=\(mempool)")
        }
        for path in (hosted.configured ?? []) where !hosted.chains.contains(path) {
            print("\(path): configured, not running")
        }
        if let data = try? await send(rpc: rpc, "GET", "mining"),
           let mining = try? JSONDecoder().decode(MiningStatusResponse.self, from: data) {
            print("mining: \(mining.enabled ? (mining.running ? "on" : "on, loop not running") : "off")")
        }
        if let data = try? await send(rpc: rpc, "GET", "config"),
           let config = try? JSONDecoder().decode(ConfigResponse.self, from: data), !config.restartRequired.isEmpty {
            print("waiting for a restart: \(config.restartRequired.joined(separator: ", "))")
        }
    }
}

struct Wipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the hosted tree's complete storage; identity and configuration are preserved. A running node wipes it as it restarts."
    )

    @OptionGroup var target: NodeTarget

    func run() async throws {
        if let rpc = try await target.running() {
            try await send(rpc: rpc, "POST", "wipe", json: Data("{}".utf8))
            print("wiping: the node restarts on empty storage")
            try await waitForRestart(rpc)
            return
        }
        let layout = target.layout
        // Under the spawn lock, so no `up` or restart starts the tree while
        // its chain state is being removed.
        try await withSpawnLock(layout) {
            _ = try Topology.load(root: layout.root).validated()
            let directory = layout.chainDirectory(for: ChainAddress.nexus)
                .standardizedFileURL
            let container = layout.root.appendingPathComponent("chains")
                .standardizedFileURL
            guard directory.path.hasPrefix(container.path + "/") else {
                throw CtlError("refusing to remove unexpected path \(directory.path)")
            }
            // The node's own writer lock: held by any process still serving this
            // chain, whatever the pidfiles say.
            let lock: StorageDirectoryLock?
            do {
                lock = FileManager.default.fileExists(atPath: directory.path)
                    ? try StorageDirectoryLock(directory: directory) : nil
            } catch StorageDirectoryLockError.alreadyLocked {
                throw CtlError("tree storage is in use by a running node; `lattice down` first")
            }
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            _ = lock
            print("hosted tree storage wiped; identity and lattice.json preserved")
        }
    }
}

/// Waits until the node behind `rpc` went away and answers again: a
/// restart it was asked for.
func waitForRestart(_ rpc: NodeRPC) async throws {
    let gone = ContinuousClock.now + .seconds(60)
    while await health(rpc: rpc) != nil, ContinuousClock.now < gone {
        try await Task.sleep(for: .milliseconds(250))
    }
    let back = ContinuousClock.now + .seconds(180)
    while ContinuousClock.now < back {
        if await health(rpc: rpc) != nil {
            print("the node is back")
            return
        }
        try await Task.sleep(for: .milliseconds(500))
    }
    throw CtlError("the node did not answer within 180s of its restart; see `lattice logs`")
}
