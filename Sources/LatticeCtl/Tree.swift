// Tree lifecycle: one lattice-node process hosts the whole topology. `up`
// runs `lattice-node --root` in the foreground (it becomes that process);
// whatever runs it (systemd, launchd, a container runtime) restarts it when
// it exits 75 (`lattice restart`). `down` asks the node to stop; `status`
// asks the node. `wipe` removes chain state, never identity.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeProcessWait
import LatticeCtlCore
import LatticeNode
import LatticeNodeAPI

func nodeBinary() throws -> URL {
    try siblingBinary("lattice-node")
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

/// Every chain path the one process hosts: Nexus and its listed children.
func hostedPaths(_ topology: Topology) -> [String] {
    [ChainAddress.nexus] + (topology.hostedChains ?? [])
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the one process hosting every chain in the tree, as lattice.json says, in the foreground.",
        discussion: """
        `lattice up` becomes `lattice-node --root <root>`: the node runs in the \
        foreground, logs to standard error, and stops on SIGTERM or SIGINT. It \
        exits 0 when asked to stop (`lattice down`), 75 when asked to restart \
        (`lattice restart`, `lattice wipe`) and 78 when its configuration is \
        invalid. Run it under a process manager that starts it again on a \
        failure exit: `lattice emit-systemd` (which also leaves 78 stopped), \
        `lattice emit-launchd`, or a container runtime's on-failure restart; \
        launchd and Docker retry 78 too, throttled. On Fly, restart on 75 in \
        the entrypoint, since Fly counts every failure exit toward its limit.
        """
    )

    @OptionGroup var rootOption: RootOption

    @Flag(name: .long, help: .hidden)
    var foreground = false

    func run() async throws {
        if foreground {
            FileHandle.standardError.write(Data(
                "warning: --foreground is deprecated: `lattice up` always runs in the foreground\n".utf8
            ))
        }
        let binary = try nodeBinary()
        let arguments = [binary.path, "--root", rootOption.layout.root.path]
        fflush(nil)
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(binary.path, argv)
        throw CtlError("could not run \(binary.path): \(String(cString: strerror(errno)))")
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask the node to stop (POST /stop): it stops cleanly and exits 0, which a process manager leaves stopped."
    )

    @OptionGroup var target: NodeTarget

    func run() async throws {
        guard let rpc = try await target.running() else { return print("not running") }
        try await stopNode(rpc)
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One line per hosted chain, and what waits for a restart."
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
        if let data = try? await send(rpc: rpc, "GET", "config"),
           let config = try? JSONDecoder().decode(ConfigResponse.self, from: data) {
            for chain in config.status.chains where chain.error != nil {
                print("\(chain.path): not hosted: \(chain.error!)")
            }
            if !config.status.pendingRestart.isEmpty {
                print("waiting for a restart: \(config.status.pendingRestart.joined(separator: ", "))")
            }
            for error in config.status.errors { print(error) }
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
            return try await restartNode(rpc, "wipe")
        }
        let layout = target.layout
        do {
            _ = try Topology.load(root: layout.root).validated()
            let directory = layout.chainDirectory(for: ChainAddress.nexus)
                .standardizedFileURL
            let container = layout.root.appendingPathComponent("chains")
                .standardizedFileURL
            guard directory.path.hasPrefix(container.path + "/") else {
                throw CtlError("refusing to remove unexpected path \(directory.path)")
            }
            // The node's own writer lock: held by any process still serving
            // this chain, and by this one until the storage is gone, so no
            // node starts on it meanwhile.
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

/// Asks the node behind `rpc` to restart (`POST /restart` or `/wipe`) and
/// waits until the new process answers: one whose start time
/// (`startedAt` in `GET /status`) is not the old one's, so the
/// old process answering on its way out is not taken for the new one.
func restartNode(_ rpc: NodeRPC, _ route: String) async throws {
    let before = await startTime(rpc)
    try await send(rpc: rpc, "POST", route, json: Data("{}".utf8))
    print(route == "wipe" ? "wiping: the node restarts on empty storage" : "restarting")
    let back = ContinuousClock.now + .seconds(180)
    var gone = false
    while ContinuousClock.now < back {
        if let before {
            if let now = await startTime(rpc), now != before { return print("the node is back") }
        } else {
            // No start time to compare (a token without GET /status, or an
            // older node): gone (no answer, or a 5xx), then any answer.
            let status = await healthStatus(rpc)
            if status == nil || status! >= 500 {
                gone = true
            } else if gone {
                return print("the node is back")
            }
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw CtlError("the node did not come back within 180s of its restart: it exits 75 to be started again, so run it under a process manager that does (`lattice emit-systemd`, `lattice emit-launchd`); see its log")
}

/// Asks the node behind `rpc` to stop (`POST /stop`) and waits until the
/// process that was asked is gone: nothing answers, or a process started
/// since (one whose process manager starts it again whatever its exit).
func stopNode(_ rpc: NodeRPC) async throws {
    let before = await startTime(rpc)
    try await send(rpc: rpc, "POST", "stop", json: Data("{}".utf8))
    let gone = ContinuousClock.now + .seconds(180)
    while ContinuousClock.now < gone {
        let status = await healthStatus(rpc)
        if status == nil { return print("stopped") }
        if let before, let now = await startTime(rpc), now != before {
            return print("stopped; whatever runs the node started it again")
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw CtlError("the node still answers 180s after it was asked to stop; see `lattice logs`")
}

/// The HTTP status `/health` answers with; nil when nothing answers.
private func healthStatus(_ rpc: NodeRPC) async -> Int? {
    guard var request = try? rpc.request("health") else { return nil }
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
    return (response as? HTTPURLResponse)?.statusCode
}

/// The node process's start time, from its status.
private func startTime(_ rpc: NodeRPC) async -> Double? {
    guard let data = try? await send(rpc: rpc, "GET", "status") else { return nil }
    return try? JSONDecoder().decode(NodeStatusResponse.self, from: data).startedAt
}
