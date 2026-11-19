import BenchVFS
import Foundation
import Ivy
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import UInt256
import XCTest
@testable import LatticeNode

/// The sync benchmark: one recorded chain tree, synced from scratch by a
/// follower, measured per block and per level. Opt-in (CHILD_BENCH), driven
/// by Benchmarks/sync/*.sh; see "Sync benchmark" in README.md.
///
/// The tree has testnet's shape: Nexus, a depth-1 child Alpha whose blocks
/// are mostly child-only shares (their headers secured by peer grind
/// proofs; one Nexus block every CHILD_BENCH_RATIO shares commits the rest),
/// and CHILD_BENCH_LEAVES grandchildren under Alpha that every Alpha block
/// commits (lockstep, derivable from Alpha).
///
/// - CHILD_BENCH=record: mines until Alpha reaches CHILD_BENCH_BLOCKS into
///   CHILD_BENCH_DIR, then writes CHILD_BENCH_DIR/manifest.txt (each level's
///   height and tip) and stops.
/// - CHILD_BENCH=serve: starts a node on a recorded CHILD_BENCH_DIR and
///   serves it for CHILD_BENCH_SERVE seconds.
/// - CHILD_BENCH=follow: a follower (state BENCH_STATE, default recent;
///   bodies BENCH_BODIES, default all; state buffer BENCH_STATE_BUFFER
///   bytes, default the node's; the follower's alone) in CHILD_BENCH_DIR syncs
///   from CHILD_BENCH_PEER (key@host:port) until every level in
///   CHILD_BENCH_MANIFEST reaches its recorded height. With CHILD_BENCH_VFS
///   set it counts SQLite writes, commits and syncs and writes them there.
final class ChildSyncBench: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    /// Blocks always come later than a 1 ms schedule, so Alpha's and the
    /// leaves' targets stay the maximum: every share that misses Nexus is an
    /// Alpha block, and every Alpha block commits each leaf. Each level's
    /// reward differs (Alpha 1200, LeafN 1300 + N), so no two levels' blocks
    /// share content.
    static func spec(_ path: [String]) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 1, initialReward: 1_000 + UInt64(path.count * 100 + (Int(path.last!.dropFirst(4)) ?? 0)),
            halvingInterval: 10_000_000, halfLife: 10
        )
    }
    static let producerKey: UInt8 = 0xe1
    static let followerKey: UInt8 = 0xe2

    private static func leaves(_ count: Int) -> [[String]] {
        (0..<count).map { alpha + ["Leaf\($0)"] }
    }

    private static func usage() -> rusage {
        var usage = rusage()
        #if canImport(Glibc)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        #else
        getrusage(RUSAGE_SELF, &usage)
        #endif
        return usage
    }

    private static func cpuSeconds() -> Double {
        let usage = usage()
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Bytes this process asked the kernel to write to storage (Linux
    /// /proc/self/io write_bytes); nil elsewhere.
    private static func bytesWritten() -> UInt64? {
        guard let io = try? String(contentsOfFile: "/proc/self/io", encoding: .utf8) else { return nil }
        for line in io.split(separator: "\n") where line.hasPrefix("write_bytes:") {
            return UInt64(line.dropFirst("write_bytes:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A setting of the follower that is not one the benchmark has.
    private struct BenchSetting: Error, CustomStringConvertible {
        let (name, value): (String, String)
        var description: String { "\(name)=\(value) is not a setting of the sync benchmark" }
    }

    private func host(
        _ keyByte: UInt8, _ dir: URL, port: UInt16, levels: [[String]], specs: Bool,
        peers: [PeerEndpoint], state: StateRetention, bodies: BlockBodies = .all,
        buffer: Int = NodeResourcePolicy.defaultMaximumBufferedStateBytes
    ) throws -> (NodeConfiguration, IvyConfig) {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: dir,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), webSocket: .off,
            peerSearchInterval: 600,
            resourcePolicy: NodeResourcePolicy(maximumBufferedStateBytes: buffer),
            blockBodies: bodies, state: state,
            hostedChildren: levels,
            childSpecs: specs ? Dictionary(uniqueKeysWithValues: levels.map { ($0, Self.spec($0)) }) : [:]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
        )
        return (configuration, overlay)
    }

    private static func reads(_ runtime: NodeRuntime, _ path: [String]) -> ChainReads? {
        path == ["Nexus"] ? runtime.reads : runtime.levelReads[path]
    }

    private static func height(_ runtime: NodeRuntime, _ path: [String]) async -> UInt64 {
        await reads(runtime, path)?.tip().height ?? 0
    }

    private static func tip(_ runtime: NodeRuntime, _ path: [String]) async -> String? {
        await reads(runtime, path)?.tip().tipCID
    }

    func testRecord() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CHILD_BENCH"] == "record")
        let blocks = env["CHILD_BENCH_BLOCKS"].flatMap(UInt64.init) ?? 3_000
        let ratio = env["CHILD_BENCH_RATIO"].flatMap(Int.init) ?? 34
        let leaves = Self.leaves(env["CHILD_BENCH_LEAVES"].flatMap(Int.init) ?? 2)
        let dir = URL(fileURLWithPath: env["CHILD_BENCH_DIR"]!)
        let port = env["CHILD_BENCH_PORT"].flatMap(UInt16.init) ?? 24_611
        let (pc, po) = try host(Self.producerKey, dir, port: port, levels: [Self.alpha] + leaves, specs: true, peers: [], state: .all)
        let producer = try await NodeRuntime.start(storage: try await NodeStorage.open(configuration: pc), configuration: pc, overlay: po)
        let payee = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        // Every level pays, so Alpha's state changes and its leaves' geneses
        // can be committed.
        let request = MiningTemplateRequest(recipients: ([["Nexus"], Self.alpha] + leaves).map {
            MiningRecipient(chainPath: $0, address: payee)
        })
        func mineNexus() async throws {
            let nexus = producer.published.value?.actOnHeight ?? 0
            _ = try await producer.mineBlock(request)
            try await eventually("nexus advances") { (producer.published.value?.actOnHeight ?? 0) > nexus }
        }
        // Harden Nexus below the maximum so shares can miss it, and let
        // Nexus blocks commit the leaves' geneses.
        var mined = 0
        while mined < 64 {
            let template = try await producer.miningTemplate(request)
            let carried = template.block.children.node?.entries["Alpha"]?.node
            let leafCount = carried?.children.node?.entries.count ?? 0
            if template.block.target < UInt256.max, leafCount == leaves.count { break }
            try await mineNexus(); mined += 1
        }
        let start = try await producer.miningTemplate(request)
        guard start.block.target < UInt256.max,
              start.block.children.node?.entries["Alpha"]?.node?.children.node?.entries.count == leaves.count else {
            XCTFail("Nexus did not harden or the leaves have no genesis after \(mined) Nexus blocks"); return
        }
        let t0 = ContinuousClock.now
        var shares = 0, childOnly = 0
        var height = await Self.height(producer, Self.alpha)
        while height < blocks {
            let template = try await producer.miningTemplate(request)
            guard let carried = template.block.children.node?.entries["Alpha"]?.node else { continue }
            let carriedLeaves = carried.children.node?.entries ?? [:]
            let leafTargets = carriedLeaves.values.compactMap { $0.node?.target }
            // A carried leaf block may be its genesis (height 0): a leaf moves
            // when its tip does.
            var leafTips: [[String]: String?] = [:]
            for name in carriedLeaves.keys { leafTips[Self.alpha + [name]] = await Self.tip(producer, Self.alpha + [name]) }
            let bound = ([carried.target] + leafTargets).min()!
            if shares % ratio == ratio - 1 || bound <= template.block.target {
                try await mineNexus()
            } else {
                // A share that misses Nexus but meets Alpha and every leaf:
                // Alpha's header is secured by its grind proof alone, and
                // the Alpha block commits each leaf's block.
                var nonce: UInt64 = 0
                while true {
                    let hash = template.block.replacingNonce(nonce).proofOfWorkHash()
                    if hash > template.block.target, hash <= bound { break }
                    nonce += 1
                }
                let share = try await producer.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
                XCTAssertEqual(share.disposition, .childOnly)
                childOnly += 1
            }
            shares += 1
            // The next template builds on every level's new tip, so no level
            // forks.
            let before = height
            try await eventually("alpha and its leaves advance", within: .seconds(10), poll: .milliseconds(1)) {
                guard await Self.height(producer, Self.alpha) > before else { return false }
                for (leaf, was) in leafTips where await Self.tip(producer, leaf) == was { return false }
                return true
            }
            height = await Self.height(producer, Self.alpha)
            if shares % 500 == 0 {
                say("CHILD_BENCH recorded alpha \(height) nexus \(producer.published.value?.actOnHeight ?? 0) in \(t0.duration(to: .now))")
            }
        }
        var manifest = ""
        for path in [["Nexus"], Self.alpha] + leaves {
            let tip = await Self.reads(producer, path)!.tip()
            manifest += "level \(path.joined(separator: "/")) height \(tip.height ?? 0) tip \(tip.tipCID ?? "")\n"
        }
        // The shape, for a reader: Alpha blocks that were child-only shares
        // (secured by their grind proofs) against Nexus blocks.
        manifest += "shares \(shares) childOnly \(childOnly) nexusMined \(shares - childOnly)\n"
        await producer.stop()
        try manifest.write(to: dir.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        say(manifest)
    }

    /// The recorded levels: (path, height, tip).
    private static func manifest(_ path: String) throws -> [([String], UInt64, String)] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("level ") }.map { line in
            let fields = line.split(separator: " ")
            return (fields[1].split(separator: "/").map(String.init), UInt64(fields[3])!, String(fields[5]))
        }
    }

    func testServe() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CHILD_BENCH"] == "serve")
        let dir = URL(fileURLWithPath: env["CHILD_BENCH_DIR"]!)
        let levels = try Self.manifest(dir.appendingPathComponent("manifest.txt").path).map(\.0).filter { $0 != ["Nexus"] }
        let port = env["CHILD_BENCH_PORT"].flatMap(UInt16.init) ?? 24_611
        let (pc, po) = try host(Self.producerKey, dir, port: port, levels: levels, specs: true, peers: [], state: .all)
        let server = try await NodeRuntime.start(storage: try await NodeStorage.open(configuration: pc), configuration: pc, overlay: po)
        say("CHILD_BENCH serving \(pc.processPublicKey)@127.0.0.1:\(port)")
        try await Task.sleep(nanoseconds: UInt64((env["CHILD_BENCH_SERVE"].flatMap(Double.init) ?? 3_600) * 1e9))
        await server.stop()
    }

    func testFollow() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CHILD_BENCH"] == "follow")
        let targets = try Self.manifest(env["CHILD_BENCH_MANIFEST"]!)
        let peerSpec = env["CHILD_BENCH_PEER"]!.split(separator: "@")
        let hostPort = peerSpec[1].split(separator: ":")
        let peer = PeerEndpoint(publicKey: String(peerSpec[0]), host: String(hostPort[0]), port: UInt16(hostPort[1])!)
        let dir = URL(fileURLWithPath: env["CHILD_BENCH_DIR"]!)
        try? FileManager.default.removeItem(at: dir)
        if env["CHILD_BENCH_VFS"] != nil { XCTAssertEqual(bench_vfs_install(), 0) }
        // What the follower keeps, from the environment (the recorder and
        // the server keep everything, whatever it says): BENCH_STATE (all,
        // recent, none; default recent), BENCH_BODIES (all, none; default
        // all) and BENCH_STATE_BUFFER (the state buffer's limit in bytes,
        // 0 for none; default the node's). A value that is not one of
        // these stops the run: a run under a setting it did not use would
        // be compared as if it had.
        func setting<T>(_ name: String, default fallback: T, _ read: (String) -> T?) throws -> T {
            guard let value = env[name] else { return fallback }
            guard let read = read(value) else {
                throw BenchSetting(name: name, value: value)
            }
            return read
        }
        let state = try setting("BENCH_STATE", default: StateRetention.recent, StateRetention.init(rawValue:))
        let bodies = try setting("BENCH_BODIES", default: BlockBodies.all, BlockBodies.init(rawValue:))
        let buffer = try setting("BENCH_STATE_BUFFER", default: NodeResourcePolicy.defaultMaximumBufferedStateBytes) {
            Int($0).flatMap { $0 >= 0 ? $0 : nil }
        }
        let (fc, fo) = try host(
            Self.followerKey, dir, port: NetworkTransportTestPorts.allocate(),
            levels: targets.map(\.0).filter { $0 != ["Nexus"] }, specs: false, peers: [peer],
            state: state, bodies: bodies, buffer: buffer
        )
        // The node sizes its workers to the processors it sees; a container
        // limited to N CPUs still sees the host's, so run.sh passes what a
        // host with N CPUs would use.
        let workers = env["CHILD_BENCH_WORKERS"].flatMap(Int.init) ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        say("CHILD_BENCH follower workers \(workers) processors \(ProcessInfo.processInfo.activeProcessorCount) state \(state.rawValue) bodies \(bodies.rawValue) buffer \(buffer)")
        SyncTrace.log(chain: ["bench"], "follower start")
        let io0 = Self.bytesWritten()
        let cpu0 = Self.cpuSeconds()
        let wall0 = ContinuousClock.now
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        let follower = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: fc), configuration: fc, overlay: fo, workers: workers
        )
        var pending = targets
        try await eventually("synced", within: .seconds(7_200), poll: .milliseconds(50)) {
            var left: [([String], UInt64, String)] = []
            for (path, target, tip) in pending {
                if await Self.height(follower, path) >= target {
                    say("CHILD_BENCH level \(path.joined(separator: "/")) height \(target) wall \(String(format: "%.3f", seconds(wall0.duration(to: .now)))) cpu \(String(format: "%.3f", Self.cpuSeconds() - cpu0))")
                    // The same blocks the recording ends on.
                    let synced = await Self.tip(follower, path)
                    XCTAssertEqual(synced, tip, "\(path) tip")
                } else {
                    left.append((path, target, tip))
                }
            }
            pending = left
            return pending.isEmpty
        }
        let wall = seconds(wall0.duration(to: .now))
        let cpu = Self.cpuSeconds() - cpu0
        let written = (Self.bytesWritten() ?? 0) &- (io0 ?? 0)
        SyncTrace.log(chain: ["bench"], "follower done")
        if let out = env["CHILD_BENCH_VFS"] { bench_vfs_dump(out) }
        await follower.stop()
        let blocks = targets.reduce(0) { $0 + $1.1 }
        // Peak resident memory (KiB on Linux, bytes on Darwin) and what the
        // follower keeps on disk.
        #if canImport(Darwin)
        let rss = Self.usage().ru_maxrss / 1024
        #else
        let rss = Self.usage().ru_maxrss
        #endif
        let kept = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        say("CHILD_BENCH follow blocks \(blocks) wall \(String(format: "%.3f", wall)) cpu \(String(format: "%.3f", cpu)) written \(written / 1024) KiB rss \(rss / 1024) MiB disk \(kept >> 20) MiB")
    }
}

/// One unbuffered line on stdout, so a script watching the output sees it at once.
private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line.hasSuffix("\n") ? line : line + "\n").utf8))
}
