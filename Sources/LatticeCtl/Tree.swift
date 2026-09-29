// Tree lifecycle: one lattice-node process hosts the whole topology. `up`
// spawns it and exits (its pidfile + loopback health are the record); `down`
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
    guard let text = try? String(
        contentsOf: layout.pidFile(for: path), encoding: .utf8
    ) else { return nil }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ", maxSplits: 1)
    guard let pid = parts.first.flatMap({ Int32($0) }),
          kill(pid, 0) == 0 else {
        return nil
    }
    if parts.count == 2 {
        let expected = String(parts[1])
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["ps", "-o", "comm=", "-p", String(pid)]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return pid }
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
            return pid
        }
        let name = String(decoding: read.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasSuffix(expected) else { return nil }
    }
    return pid
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

func health(rpc: UInt16) async -> [String: Any]? {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/health") else {
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

/// Starts the one `lattice-node` hosting every chain in the tree. It wires
/// each child to its co-hosted parent itself.
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
    let process = Process()
    process.executableURL = try nodeBinary()
    process.arguments = [
        "--config", layout.root.appendingPathComponent(Topology.fileName).path,
        "--data-root", layout.root.path,
    ]
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

/// Adds a chain already written to `lattice.json` to the running daemon,
/// through the root chain's loopback host-control route.
func attachLevel(_ path: String, topology: Topology) async throws {
    guard let root = topology.chains[ChainAddress.nexus] else {
        throw CtlError("the tree has no \(ChainAddress.nexus) root")
    }
    let _: HostLevelRequest = try await post(
        rpc: root.rpc, path: "v1/host/levels",
        body: HostLevelRequest(path: path)
    )
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the one process hosting every chain in the tree, unless it is already running."
    )

    @OptionGroup var rootOption: RootOption

    @Flag(name: .long, help: "Stay in the foreground and restart the process if it exits (container PID 1).")
    var foreground = false

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        try await withSpawnLock(layout) {
            if let pid = runningPid(layout, hostProcessName) {
                print("already running (pid \(pid))")
                return
            }
            try spawnHost(layout: layout)
            print("started \(topology.chains.count) chain(s) (pid \(runningPid(layout, hostProcessName) ?? -1))")
        }
        guard foreground else { return }
        while true {
            try await Task.sleep(for: .seconds(10))
            try await withSpawnLock(layout) {
                guard runningPid(layout, hostProcessName) == nil else { return }
                print("exited; restarting")
                try spawnHost(layout: layout)
            }
        }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the process hosting the tree; it stops the chains children first."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        guard let pid = runningPid(layout, hostProcessName) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<300 where runningPid(layout, hostProcessName) != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        if runningPid(layout, hostProcessName) != nil { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(
            at: layout.pidFile(for: hostProcessName)
        )
        print("stopped")
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
        for path in topology.chains.keys.sorted() {
            let chain = topology.chains[path]!
            guard running else {
                print("\(path): down")
                continue
            }
            guard let health = await health(rpc: chain.rpc) else {
                print("\(path): running, rpc unreachable")
                continue
            }
            let phase = health["phase"] as? String ?? "?"
            let height = (health["height"] as? Int).map(String.init) ?? "-"
            let tip = (health["tipCID"] as? String)?.prefix(20) ?? "-"
            let mempool = health["mempoolCount"] as? Int ?? 0
            print("\(path): \(phase) height=\(height) tip=\(tip)… mempool=\(mempool)")
        }
    }
}

struct Wipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove one chain's state (state.db + volumes.db as a unit); identity is preserved."
    )

    @OptionGroup var rootOption: RootOption

    @Argument(help: "Chain path to wipe (e.g. Nexus).")
    var chain: String

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        guard topology.chains[chain] != nil else {
            throw CtlError("\(chain) is not in the tree")
        }
        guard runningPid(layout, hostProcessName) == nil else {
            throw CtlError("the tree is running; `lattice down` first")
        }
        let directory = layout.chainDirectory(for: chain)
            .standardizedFileURL
        let container = layout.root.appendingPathComponent("chains")
            .standardizedFileURL
        guard directory.path.hasPrefix(container.path + "/") else {
            throw CtlError("refusing to remove unexpected path \(directory.path)")
        }
        try? FileManager.default.removeItem(at: directory)
        print("\(chain): chain state wiped; identity preserved")
    }
}
