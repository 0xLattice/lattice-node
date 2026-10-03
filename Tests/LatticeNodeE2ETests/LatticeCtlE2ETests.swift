import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeCtlCore
import LatticeMinerCore
import LatticeNode
import XCTest

/// Black-box E2Es for the `lattice` operator CLI: real shipped binaries,
/// public HTTP, nothing in-process. Proves the CLI can bring up a Nexus
/// node, mine it, and move value with `lattice tx`.
final class LatticeCtlE2ETests: XCTestCase {
    // MARK: harness

    private struct CtlHost {
        let root: URL
        let nexusRPC: UInt16
    }

    private var hosts: [CtlHost] = []

    /// These drive real multi-chain CPU mining and starve when co-run with
    /// the rest of the E2E suite on a small shared runner, so they gate on
    /// an explicit opt-in and run in their own CI lane.
    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["E2E_CTL"] == "1",
            "set E2E_CTL=1 to run the operator-CLI E2Es"
        )
    }

    override func tearDown() async throws {
        let failed = (testRun?.totalFailureCount ?? 0) > 0
        for host in hosts {
            _ = try? await runCtl(["mine", "stop"], root: host.root)
            _ = try? await runCtl(["down"], root: host.root)
            if failed {
                print("lattice-ctl E2E artifacts retained at \(host.root.path)")
            } else {
                try? FileManager.default.removeItem(at: host.root)
            }
        }
        hosts = []
    }

    private func binary(
        _ variable: String, _ product: String
    ) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[variable], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        if let node = environment["E2E_NODE_BIN"], !node.isEmpty {
            let beside = URL(fileURLWithPath: node)
                .deletingLastPathComponent().appendingPathComponent(product)
            if FileManager.default.isExecutableFile(atPath: beside.path) {
                return beside
            }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = repository
            .appendingPathComponent(".build/debug/\(product)")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw CtlE2EError("build \(product) first (looked at \(candidate.path))")
        }
        return candidate
    }

    @discardableResult
    private func runCtl(
        _ arguments: [String], root: URL, expectFailure: Bool = false
    ) async throws -> String {
        let process = Process()
        process.executableURL = try binary("E2E_CTL_BIN", "lattice")
        process.arguments = arguments + ["--root", root.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if !expectFailure, process.terminationStatus != 0 {
            throw CtlE2EError("lattice \(arguments.joined(separator: " ")) failed: \(output)")
        }
        return output
    }

    @discardableResult
    private func runKeyTool(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = try binary("E2E_CTL_BIN", "lattice")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CtlE2EError("lattice key failed: \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Probe-bind below the kernel ephemeral range so a chosen port is
    /// actually free at selection time (mirrors the main harness's
    /// allocator discipline).
    private func randomPorts(_ count: Int) -> [UInt16] {
        var chosen: Set<UInt16> = []
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
                    Foundation.bind(descriptor, $0,
                         socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            _ = close(descriptor)
            if bound == 0 { chosen.insert(candidate) }
        }
        return Array(chosen)
    }

    /// Never from the URL cache: `/health` is `max-age=3`, so a cached answer
    /// can report a stopped-and-restarting node as active before it listens.
    private func health(_ rpc: UInt16, chain: String = "Nexus") async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(rpc)/health" + Self.query(chain)) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(
            for: request
        ) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data))
            as? [String: Any]
    }

    private func waitFor(
        _ label: String,
        seconds: Int = 60,
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + e2eScaled(.seconds(seconds))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CtlE2EError("timed out waiting for \(label)")
    }

    /// A `lattice key generate` key file: the CLI signs with the file, the test
    /// only ever needs the address.
    private struct TestKey {
        let address: String
        let file: URL
    }

    private func makeKey(_ directory: URL, _ name: String) async throws -> TestKey {
        let path = directory.appendingPathComponent("\(name).json")
        _ = try await runKeyTool(["key", "generate", "--out", path.path])
        struct KeyFile: Decodable { let address: String }
        let decoded = try JSONDecoder().decode(
            KeyFile.self, from: Data(contentsOf: path)
        )
        return TestKey(address: decoded.address, file: path)
    }

    /// `lattice tx …` against the host; false when the node refused the
    /// transaction — a stale nonce, an unfunded credit, or the tip moving
    /// under the preflight. Swap legs retry on that.
    ///
    /// The reason is kept, because every other failure looks identical here:
    /// a wrong key path or a chain missing from the topology would otherwise
    /// surface only as a timeout four minutes later, with nothing saying why.
    private func tx(_ host: CtlHost, _ arguments: [String]) async -> Bool {
        do {
            _ = try await runCtl(["tx"] + arguments, root: host.root)
            return true
        } catch {
            lastTxFailure = "\(arguments.first ?? "tx"): \(error)"
            return false
        }
    }

    /// Why the most recent `tx` invocation was refused, for timeout messages.
    private var lastTxFailure: String?

    /// Retry a `tx` submit until the node accepts it, reporting the last
    /// refusal if it never does.
    private func submitUntilAccepted(
        _ label: String,
        _ host: CtlHost,
        _ arguments: [String],
        seconds: Int = 240
    ) async throws {
        lastTxFailure = nil
        do {
            try await waitFor(label, seconds: seconds) {
                await self.tx(host, arguments)
            }
        } catch {
            throw CtlE2EError(
                "\(label); last refusal: \(lastTxFailure ?? "none recorded")"
            )
        }
    }

    /// Brings up one CLI-managed host mining Nexus with rewards to `miner`
    /// (none when nil: they burn).
    ///
    /// Pass a Nexus `miner` only when the test spends Nexus rewards. A
    /// credited recipient changes Nexus's post-state on every block, and at
    /// this host's near-maximum Nexus target nearly every hash is a full
    /// Nexus block, so each one stales every hosted child's prebuilt
    /// candidate (it binds the tip's post-state) before the coordinator's
    /// next template can carry it. A child is then carried only when its
    /// rebuild wins that race, and a grandchild topology, or a child with a
    /// transaction pooled, can lose it on every block. At Nexus's real
    /// target a child rides child-only carriers, which leave Nexus's
    /// post-state alone.
    private func bringUpMiningHost(miner: TestKey?) async throws -> CtlHost {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        _ = try await runCtl(["init"], root: root)
        let ports = randomPorts(2)
        let topologyURL = root.appendingPathComponent("lattice.json")
        var topology = try JSONDecoder().decode(
            Topology.self, from: Data(contentsOf: topologyURL)
        )
        topology.listen = ports[0]
        topology.rpc = ports[1]
        // Explicitly empty: this host seeds itself, so the shipped default
        // bootstrap peers must not send it at the public network.
        topology.peers = []
        topology.mine = TopologyMine(
            worker: "cpu", workers: 1, batchSize: 100_000,
            recipients: miner.map { ["Nexus": $0.address] }
        )
        try topology.validated().save(root: root)

        _ = try await runCtl(["up"], root: root)
        let host = CtlHost(root: root, nexusRPC: ports[1])
        hosts.append(host)
        try await waitFor("Nexus active") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
        return host
    }

    func testNexusMiningAndTransferThroughTheCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "miner")
        let recipient = try await makeKey(scratch, "recipient")
        let host = try await bringUpMiningHost(miner: miner)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("miner funded by Nexus rewards", seconds: 180) {
            await self.balance(host.nexusRPC, miner.address) >= 10
        }
        try await submitUntilAccepted("Nexus accepts the transfer", host, [
            "send", "--chain", "Nexus", "--key", miner.file.path,
            "--to", recipient.address, "--amount", "10",
        ])
        try await waitFor("transfer mined", seconds: 240) {
            await self.balance(host.nexusRPC, recipient.address) == 10
        }
    }

    private static func query(_ chain: String) -> String {
        chain == "Nexus" ? "" : "?chainPath=\(chain)"
    }

    private func height(_ rpc: UInt16, chain: String) async -> Int {
        await health(rpc, chain: chain)?["height"] as? Int ?? -1
    }

    /// Nexus plus one hosted child, all through the CLI: the child created
    /// from a spec, both mined by merged mining, a transaction on the child,
    /// and a restart that resumes both.
    func testAChildChainIsCreatedMergeMinedTransactedAndResumedThroughTheCLI() async throws {
        let alpha = "Nexus/Alpha"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "alpha-miner")
        let recipient = try await makeKey(scratch, "alpha-recipient")
        let host = try await bringUpMiningHost(miner: nil)
        _ = try await runCtl(["child", "create", alpha, "--block-time", "1000", "--reward", "100"], root: host.root)
        let again = try await runCtl(["child", "create", alpha], root: host.root, expectFailure: true)
        XCTAssertTrue(again.contains("already exists"), "a second create is refused: \(again)")
        var topology = try Topology.load(root: host.root)
        topology.mine?.recipients = [alpha: miner.address]
        try topology.validated().save(root: host.root)
        try await waitFor("Nexus active after the restart") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("Alpha mined by merged mining", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) >= 2
        }
        try await waitFor("the Alpha miner is funded", seconds: 180) {
            await self.balance(host.nexusRPC, miner.address, chain: alpha) >= 10
        }
        try await submitUntilAccepted("Alpha accepts the transfer", host, [
            "send", "--chain", alpha, "--key", miner.file.path,
            "--to", recipient.address, "--amount", "10",
        ])
        try await waitFor("the Alpha transfer is mined", seconds: 240) {
            await self.balance(host.nexusRPC, recipient.address, chain: alpha) == 10
        }
        let before = await height(host.nexusRPC, chain: alpha)
        _ = try await runCtl(["mine", "stop"], root: host.root)
        _ = try await runCtl(["down"], root: host.root)
        _ = try await runCtl(["up"], root: host.root)
        try await waitFor("Alpha resumes where it was") {
            await self.height(host.nexusRPC, chain: alpha) >= before
        }
        let balance = await balance(host.nexusRPC, recipient.address, chain: alpha)
        XCTAssertEqual(balance, 10)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("Alpha advances after the restart", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) > before
        }
    }

    private func balance(_ rpc: UInt16, _ address: String, chain: String = "Nexus") async -> UInt64 {
        guard let url = URL(
            string: "http://127.0.0.1:\(rpc)/api/state/account/\(address)" + Self.query(chain)
        ) else { return 0 }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(
            for: request
        ), (response as? HTTPURLResponse)?.statusCode == 200,
           let object = try? JSONSerialization.jsonObject(with: data)
               as? [String: Any] else { return 0 }
        return (object["balance"] as? NSNumber)?.uint64Value ?? 0
    }
}

private struct CtlE2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// CI scales every poll deadline (`E2E_TIME_SCALE`) for slow shared runners.
private let e2eTimeScale: Int = ProcessInfo.processInfo
    .environment["E2E_TIME_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

private func e2eScaled(_ timeout: Duration) -> Duration {
    timeout * e2eTimeScale
}
