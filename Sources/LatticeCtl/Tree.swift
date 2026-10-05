// Tree lifecycle: one lattice-node process hosts the whole topology. `up`
// spawns it and exits (its pidfile + loopback health are the record), and
// restarts it when lattice.json lists other chains than it hosts; `down`
// stops it by pidfile; `status` reads only local loopback RPC —
// it never claims fleet truth. `wipe` removes chain state, never identity.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
import LatticeProcessWait
import LatticeNode

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

func health(rpc: UInt16, chain: String = "Nexus") async -> [String: Any]? {
    guard let url = readURL(rpc: rpc, "health", chain: chain) else {
        return nil
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    guard let (data, _) = try? await URLSession.shared.data(for: request) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The pidfile and log name of the one daemon hosting the whole tree.
let hostProcessName = "lattice-node"

/// Starts the one `lattice-node` for the configured hosted tree. The chain
/// set it starts with is recorded beside its pidfile.
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
    let topology = try Topology.load(root: layout.root).validated()
    let chains = hostedPaths(topology)
    try Data(chains.joined(separator: "\n").utf8).write(
        to: hostedChainsFile(layout), options: .atomic
    )
    let process = Process()
    process.executableURL = try nodeBinary()
    var arguments = [
        "--data-directory", layout.chainDirectory(for: "Nexus").path,
        "--identity-key", layout.identityKey(for: "Nexus").path,
        "--listen-port", String(topology.listen),
        "--rpc-port", String(topology.rpc),
    ]
    if let peers = topology.peers {
        arguments += peers.isEmpty ? ["--no-default-peers"] : ["--peer"] + peers
    }
    if let port = topology.publicRead { arguments += ["--public-read-port", String(port)] }
    if let host = topology.externalAddress { arguments += ["--external-address", host] }
    if let rate = topology.publicReadRate { arguments += ["--public-read-rate", String(rate)] }
    if let rate = topology.publicReadExpensiveRate { arguments += ["--public-read-expensive-rate", String(rate)] }
    if let rate = topology.publicReadMaxRate { arguments += ["--public-read-max-rate", String(rate)] }
    if let url = topology.publicReadURL { arguments += ["--public-read-url", url] }
    if topology.publicSubmit == true { arguments += ["--public-submit"] }
    if let fee = topology.minRelayFee { arguments += ["--min-relay-fee", String(fee)] }
    for child in topology.hostedChains ?? [] {
        let spec = layout.childSpec(for: child)
        arguments += ["--host-chain", FileManager.default.fileExists(atPath: spec.path) ? "\(child)=\(spec.path)" : child]
    }
    process.arguments = arguments
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

private func hostedChainsFile(_ layout: HostLayout) -> URL {
    layout.pidFile(for: hostProcessName).deletingPathExtension()
        .appendingPathExtension("chains")
}

/// The chains the running host was started with; nil when unrecorded.
private func hostedChains(_ layout: HostLayout) -> Set<String>? {
    guard let text = try? String(
        contentsOf: hostedChainsFile(layout), encoding: .utf8
    ) else { return nil }
    return Set(text.split(separator: "\n").map(String.init))
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

/// Restarts the running host so it serves the chains `lattice.json` lists
/// now: the host never adds a chain while it runs. The caller holds the
/// spawn lock; returns false, touching nothing, when no host is running.
func restartHostIfRunningLocked(_ layout: HostLayout) async throws -> Bool {
    guard runningPid(layout, hostProcessName) != nil else { return false }
    try await stopProcess(layout, hostProcessName)
    try spawnHost(layout: layout)
    return true
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the one process hosting every chain in the tree; restart it if lattice.json lists chains it does not host."
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
            if let pid = runningPid(layout, hostProcessName) {
                guard hostedChains(layout) != Set(hostedPaths(topology)) else {
                    print("already running (pid \(pid))")
                    return
                }
                print("lattice.json changed since the host started (pid \(pid)); restarting it")
                try await stopProcess(layout, hostProcessName)
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
        abstract: "One table across the tree, from local loopback RPC only."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        let running = runningPid(layout, hostProcessName) != nil
        for path in hostedPaths(topology) {
            guard running else {
                print("\(path): down")
                continue
            }
            guard let health = await health(rpc: topology.rpc, chain: path) else {
                print("\(path): running, rpc unreachable")
                continue
            }
            let phase = health["phase"] as? String ?? "?"
            let height = health["height"] as? String ?? "-"
            let tip = (health["tipCID"] as? String)?.prefix(20) ?? "-"
            let mempool = health["mempoolCount"] as? Int ?? 0
            print("\(path): \(phase) height=\(height) tip=\(tip)… mempool=\(mempool)")
        }
    }
}

struct Wipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove the hosted tree's complete storage; identity and configuration are preserved."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        // Under the spawn lock, so no `up` or restart starts the tree while
        // its chain state is being removed.
        try await withSpawnLock(layout) {
            _ = try Topology.load(root: layout.root).validated()
            guard runningPid(layout, hostProcessName) == nil else {
                throw CtlError("the tree is running; `lattice down` first")
            }
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
