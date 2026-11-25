import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// Two releases on one network:
/// a node of an older release and a node of this build, peered on loopback,
/// each following the blocks the other mines to the same tip; and one root
/// upgraded in place, the older release's chain opened and extended by this
/// build.
///
/// Black box: each release's own shipped binaries, driven through its own
/// `lattice` CLI, read over `/health` and mined through its mining routes
/// (`TestMiner`), so nothing here depends on either release's Swift types.
/// Opt-in: `E2E_OLD_BIN_DIR` names the directory holding an older release's
/// `lattice` and `lattice-node` (the `bin` of its release archive).
final class TwoVersionE2ETests: XCTestCase {
    /// One release's host: its CLI, its root and the ports it listens on.
    private final class Host {
        let name: String
        let lattice: URL
        let root: URL
        let listen: UInt16
        let rpc: UInt16
        /// `lattice up`, when this release runs it in the foreground.
        var up: Process?
        /// Mines this host through its loopback API once started.
        let miner: TestMiner

        init(name: String, lattice: URL, root: URL, listen: UInt16, rpc: UInt16) {
            self.name = name
            self.lattice = lattice
            self.root = root
            self.listen = listen
            self.rpc = rpc
            self.miner = TestMiner(
                rpc: rpc,
                cookieFile: root.appendingPathComponent("chains/Nexus/.cookie")
            )
        }
    }

    private var hosts: [Host] = []
    private var scratch: URL?

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["E2E_OLD_BIN_DIR"]?.isEmpty == false,
            "set E2E_OLD_BIN_DIR to an older release's binaries to run the two-version E2Es"
        )
    }

    override func tearDown() async throws {
        let failed = (testRun?.totalFailureCount ?? 0) > 0
        for host in hosts { await stop(host) }
        hosts = []
        if let scratch {
            if failed {
                print("two-version E2E artifacts retained at \(scratch.path)")
            } else {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        scratch = nil
    }

    func testThisBuildFollowsAnOlderReleasesMiner() async throws {
        try await follow(minerIsOlder: true)
    }

    func testAnOlderReleaseFollowsThisBuildsMiner() async throws {
        try await follow(minerIsOlder: false)
    }

    /// The upgrade an operator runs on a network still mining the older
    /// release: this build refuses the older store as `wipe required`, and
    /// after `lattice wipe` the same root resyncs from an older-release peer
    /// to its tip. Identity and `lattice.json` survive the wipe.
    func testAnUpgradedRootIsWipedAndResyncsFromAnOlderPeer() async throws {
        let directory = try makeScratch()
        let ports = Self.freePorts(4)
        let miner = Host(
            name: "miner", lattice: try olderLattice(), root: directory.appendingPathComponent("miner"),
            listen: ports[0], rpc: ports[1]
        )
        let upgraded = Host(
            name: "older", lattice: try olderLattice(), root: directory.appendingPathComponent("upgraded"),
            listen: ports[2], rpc: ports[3]
        )
        hosts = [miner, upgraded]
        for host in hosts { try run(host, ["init"]) }
        let minerKey = try identity(miner)
        try write(miner, [
            "listen": Int(miner.listen), "rpc": Int(miner.rpc), "peers": [String](),
        ])
        try write(upgraded, [
            "listen": Int(upgraded.listen), "rpc": Int(upgraded.rpc),
            "peers": ["\(minerKey)@127.0.0.1:\(miner.listen)"],
        ])
        for host in hosts { try start(host) }
        for host in hosts {
            try await waitFor("\(host.name) active") { await self.health(host)?["phase"] as? String == "active" }
        }
        miner.miner.start()
        try await waitFor("the older miner mines \(Self.blocks) blocks", seconds: 240) {
            await self.height(miner) >= Self.blocks
        }
        await miner.miner.stop()
        let minerTip = await health(miner)?["tipCID"] as? String
        let mined = try XCTUnwrap(minerTip)
        try await waitFor("the older follower reaches the tip", seconds: 120) {
            await self.health(upgraded)?["tipCID"] as? String == mined
        }
        let identityBefore = try identity(upgraded)

        // The upgrade: the older node stopped, this build started on its root.
        await stop(upgraded)
        let current = Host(
            name: "current", lattice: try currentLattice(), root: upgraded.root,
            listen: upgraded.listen, rpc: upgraded.rpc
        )
        hosts = [miner, current]
        try? start(current)
        try await waitFor("this build refuses the older store") {
            self.log(of: current).contains("node store is incompatible")
        }
        XCTAssertTrue(self.log(of: current).contains("schema epoch"), self.log(of: current))
        let refusedHealth = await health(current)
        XCTAssertNotEqual(refusedHealth?["phase"] as? String, "active", "the older store was opened, not refused")
        await stop(current)

        try run(current, ["wipe"])
        XCTAssertEqual(try identity(current), identityBefore, "the wipe keeps the node's identity")
        try start(current)
        try await waitFor("the wiped root resyncs to the older miner's tip", seconds: 120) {
            await self.health(current)?["tipCID"] as? String == mined
        }
        let resyncedHeight = await height(current)
        let minedHeight = await height(miner)
        XCTAssertEqual(resyncedHeight, minedHeight)
    }

    // MARK: - The scenario

    /// One host mines Nexus; the other, of the other release, peers with it
    /// and reaches the same tip.
    private func follow(minerIsOlder: Bool) async throws {
        let directory = try makeScratch()
        let ports = Self.freePorts(4)
        let older = Host(
            name: "older", lattice: try olderLattice(), root: directory.appendingPathComponent("older"),
            listen: ports[0], rpc: ports[1]
        )
        let current = Host(
            name: "current", lattice: try currentLattice(), root: directory.appendingPathComponent("current"),
            listen: ports[2], rpc: ports[3]
        )
        hosts = [older, current]
        let (miner, follower) = minerIsOlder ? (older, current) : (current, older)

        for host in hosts { try run(host, ["init"]) }
        let minerKey = try identity(miner)
        // Peers are always spelled out, the miner's as none: neither host may
        // fall back to the shipped bootstrap peers and reach the public network.
        try write(miner, [
            "listen": Int(miner.listen), "rpc": Int(miner.rpc), "peers": [String](),
        ])
        try write(follower, [
            "listen": Int(follower.listen), "rpc": Int(follower.rpc),
            "peers": ["\(minerKey)@127.0.0.1:\(miner.listen)"],
        ])

        for host in hosts { try start(host) }
        for host in hosts {
            try await waitFor("\(host.name) active") { await self.health(host)?["phase"] as? String == "active" }
        }
        let minerGenesis = await health(miner)?["tipCID"] as? String
        let genesis = try XCTUnwrap(minerGenesis)
        let followerGenesis = await health(follower)?["tipCID"] as? String
        XCTAssertEqual(followerGenesis, genesis, "the two releases pin the same Nexus genesis")

        miner.miner.start()
        try await waitFor("\(miner.name) mines \(Self.blocks) Nexus blocks", seconds: 240) {
            await self.height(miner) >= Self.blocks
        }
        // A stopped miner's tip stands still, so the two can be compared.
        await miner.miner.stop()

        try await waitFor("\(follower.name) reaches \(miner.name)'s tip", seconds: 120) {
            guard let mined = await self.health(miner)?["tipCID"] as? String,
                  let followed = await self.health(follower)?["tipCID"] as? String else { return false }
            return mined == followed
        }
        let minedHeight = await height(miner)
        let followedHeight = await height(follower)
        XCTAssertGreaterThanOrEqual(minedHeight, Self.blocks)
        XCTAssertEqual(followedHeight, minedHeight)
        let tip = await health(follower)?["tipCID"] as? String
        XCTAssertNotEqual(tip, genesis, "the follower executed the miner's blocks")
    }

    private static let blocks = 6

    // MARK: - Harness

    private func makeScratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-twoversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratch = directory
        return directory
    }

    /// Mining stopped, `lattice down`, and a foreground `lattice up` ended.
    private func stop(_ host: Host) async {
        await host.miner.stop()
        _ = try? run(host, ["down"])
        if let up = host.up, up.isRunning {
            up.terminate()
            let deadline = Date().addingTimeInterval(60)
            while up.isRunning, Date() < deadline { usleep(100_000) }
            if up.isRunning { kill(up.processIdentifier, SIGKILL) }
        }
        host.up = nil
    }

    private func olderLattice() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["E2E_OLD_BIN_DIR"] ?? ""
        let lattice = URL(fileURLWithPath: directory).appendingPathComponent("lattice")
        guard FileManager.default.isExecutableFile(atPath: lattice.path) else {
            throw TwoVersionError("no lattice in E2E_OLD_BIN_DIR (looked at \(lattice.path))")
        }
        return lattice
    }

    /// This build's CLI, found as the operator-CLI E2Es find it.
    private func currentLattice() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["E2E_CTL_BIN"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        if let node = environment["E2E_NODE_BIN"], !node.isEmpty {
            let beside = URL(fileURLWithPath: node).deletingLastPathComponent().appendingPathComponent("lattice")
            if FileManager.default.isExecutableFile(atPath: beside.path) { return beside }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repository.appendingPathComponent(".build/debug/lattice")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw TwoVersionError("build lattice first (looked at \(candidate.path))")
        }
        return candidate
    }

    /// Never the built-in public peers, whatever a release's defaults are.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["LATTICE_FORBID_DEFAULT_PEERS"] = "1"
        return environment
    }()

    @discardableResult
    private func run(_ host: Host, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = host.lattice
        process.arguments = arguments + ["--root", host.root.path]
        process.environment = Self.environment
        // To a file, not a pipe: a release whose command leaves a daemon
        // behind would hold a pipe open past the command's own exit.
        let log = host.root.deletingLastPathComponent()
            .appendingPathComponent("\(host.name)-\(arguments.joined(separator: "-")).out")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil), "the log file could not be created")
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw TwoVersionError("\(host.name): lattice \(arguments.joined(separator: " ")) failed: \(output)")
        }
        return output
    }

    /// `lattice up`. An older release starts a daemon and returns; this build
    /// runs in the foreground until it is stopped. Either is taken: the
    /// process is left running, and an early failure is reported.
    private func start(_ host: Host) throws {
        let process = Process()
        process.executableURL = host.lattice
        process.arguments = ["up", "--root", host.root.path]
        process.environment = Self.environment
        let log = host.root.deletingLastPathComponent().appendingPathComponent("\(host.name)-up.out")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil), "the log file could not be created")
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        host.up = process
        usleep(500_000)
        if !process.isRunning, process.terminationStatus != 0 {
            let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw TwoVersionError("\(host.name): lattice up failed: \(output)")
        }
    }

    /// What `lattice up` has printed so far for `host`.
    private func log(of host: Host) -> String {
        let log = host.root.deletingLastPathComponent().appendingPathComponent("\(host.name)-up.out")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// The node's public key, as `lattice identity` prints it.
    private func identity(_ host: Host) throws -> String {
        let output = try run(host, ["identity"])
        let hex = Set("0123456789abcdef")
        guard let key = output.split(whereSeparator: { !hex.contains($0) }).first(where: { $0.count == 64 }) else {
            throw TwoVersionError("\(host.name): no public key in: \(output)")
        }
        return String(key)
    }

    private func write(_ host: Host, _ topology: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: topology, options: [.sortedKeys])
            .write(to: host.root.appendingPathComponent("lattice.json"), options: .atomic)
    }

    /// Never from the URL cache: `/health` is cacheable for a few seconds.
    private func health(_ host: Host) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(host.rpc)/health") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func height(_ host: Host) async -> Int {
        (await health(host)?["height"] as? String).flatMap { Int($0) } ?? -1
    }

    private func waitFor(_ label: String, seconds: Int = 60, condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds) * Self.timeScale
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw TwoVersionError("timed out waiting for: \(label)")
    }

    /// CI scales every poll deadline (`E2E_TIME_SCALE`) for slow shared runners.
    private static let timeScale: Int = ProcessInfo.processInfo
        .environment["E2E_TIME_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

    /// Probe-bound below the kernel's ephemeral range, so each is free when
    /// chosen.
    private static func freePorts(_ count: Int) -> [UInt16] {
        var chosen: [UInt16] = []
        while chosen.count < count {
            let candidate = UInt16.random(in: 21_000...28_999)
            guard !chosen.contains(candidate) else { continue }
            #if canImport(Darwin)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            #else
            let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            #endif
            guard descriptor >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Foundation.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            _ = close(descriptor)
            if bound == 0 { chosen.append(candidate) }
        }
        return chosen
    }
}

private struct TwoVersionError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
