// Tree lifecycle: reconcile running lattice-node processes against the
// topology. `up` spawns and exits (pidfiles + loopback health are the
// record); `down` stops by pidfile; `status` reads only local loopback RPC —
// it never claims fleet truth. `wipe` removes chain state, never identity.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
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
        let name = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
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

func spawnChain(
    _ path: String,
    topology: Topology,
    layout: HostLayout
) throws {
    let chain = topology.chains[path]!
    let manager = FileManager.default
    for directory in [
        layout.chainDirectory(for: path),
        layout.pidFile(for: path).deletingLastPathComponent(),
        layout.logFile(for: path).deletingLastPathComponent(),
    ] {
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }
    var arguments = [
        "--chain-path", path,
        "--data-directory", layout.chainDirectory(for: path).path,
        "--identity-key", layout.identityKey(for: path).path,
        "--listen-port", String(chain.listen),
        "--fact-listen-port", String(chain.fact),
        "--rpc-port", String(chain.rpc),
    ]
    let components = path.components(separatedBy: "/")
    if components.count > 1 {
        let parentPath = components.dropLast().joined(separator: "/")
        let parent = topology.chains[parentPath]!
        let parentKey = try publicKey(
            ofIdentity: layout.identityKey(for: parentPath)
        )
        arguments += ["--parent", "\(parentKey)@127.0.0.1:\(parent.fact)"]
    }
    for peer in chain.peers ?? [] {
        arguments += ["--peer", peer]
    }
    if let publicRead = chain.publicRead {
        arguments += ["--public-read-port", String(publicRead)]
    }
    if let externalAddress = chain.externalAddress {
        arguments += ["--external-address", externalAddress]
    }
    let process = Process()
    process.executableURL = try nodeBinary()
    process.arguments = arguments
    let log = layout.logFile(for: path)
    _ = manager.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    handle.seekToEndOfFile()
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    try writePidFile(
        layout, path, pid: process.processIdentifier, name: "lattice-node"
    )
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start every chain process in the tree that is not already running."
    )

    @OptionGroup var rootOption: RootOption

    @Flag(name: .long, help: "Stay in the foreground and restart processes that exit (container PID 1).")
    var foreground = false

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        try await withSpawnLock(layout) {
            for path in topology.orderedPaths() {
                if let pid = runningPid(layout, path) {
                    print("\(path): already running (pid \(pid))")
                    continue
                }
                try spawnChain(path, topology: topology, layout: layout)
                print("\(path): started (pid \(runningPid(layout, path) ?? -1))")
            }
        }
        guard foreground else { return }
        while true {
            try await Task.sleep(for: .seconds(10))
            for path in topology.orderedPaths()
            where runningPid(layout, path) == nil {
                print("\(path): exited; restarting")
                try spawnChain(path, topology: topology, layout: layout)
            }
        }
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop every running chain process in the tree, children first."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        for path in topology.orderedPaths().reversed() {
            guard let pid = runningPid(layout, path) else { continue }
            kill(pid, SIGTERM)
            for _ in 0..<50 where runningPid(layout, path) != nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            if runningPid(layout, path) != nil { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: layout.pidFile(for: path))
            print("\(path): stopped")
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
        for path in topology.orderedPaths() {
            let chain = topology.chains[path]!
            guard runningPid(layout, path) != nil else {
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
        guard runningPid(layout, chain) == nil else {
            throw CtlError("\(chain) is running; `lattice down` first")
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
