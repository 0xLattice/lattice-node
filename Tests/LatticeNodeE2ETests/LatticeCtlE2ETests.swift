import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeMinerCore
import LatticeNode
import XCTest

/// Black-box E2Es for the `lattice` operator CLI: real shipped binaries,
/// public HTTP, nothing in-process. Proves the CLI can bring up multichain
/// hosts that sync, and carry a full child-chain token swap.
final class LatticeCtlE2ETests: XCTestCase {
    // MARK: harness

    private struct CtlHost {
        let root: URL
        let nexusRPC: UInt16
        var childRPC: UInt16?
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
    private func runRewards(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = try binary(
            "E2E_REWARDS_BIN", "lattice-rewards"
        )
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CtlE2EError("lattice-rewards failed: \(String(decoding: data, as: UTF8.self))")
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
    private func health(_ rpc: UInt16) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(rpc)/health") else {
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

    /// A `lattice-rewards` key file: the CLI signs with the file, the test
    /// only ever needs the address.
    private struct TestKey {
        let address: String
        let file: URL
    }

    private func makeKey(_ directory: URL, _ name: String) async throws -> TestKey {
        let path = directory.appendingPathComponent("\(name).json")
        _ = try await runRewards(["generate-key", "--out", path.path])
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

    /// Brings up one CLI-managed host mining Nexus with rewards to `miner`,
    /// then deploys a premined child.
    private func bringUpMiningHost(
        miner: TestKey
    ) async throws -> CtlHost {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        _ = try await runCtl(["init"], root: root)
        try copyKey(miner, into: root, name: "miner")
        _ = try await runRewards([
            "emit-batch", "--key",
            root.appendingPathComponent("miner.json").path,
            "--count", "60", "--out",
            root.appendingPathComponent("rewards.jsonl").path,
        ])
        let ports = randomPorts(3)
        let topologyURL = root.appendingPathComponent("lattice.json")
        var topology = try JSONSerialization.jsonObject(
            with: Data(contentsOf: topologyURL)
        ) as! [String: Any]
        var chains = topology["chains"] as! [String: Any]
        var nexus = chains["Nexus"] as! [String: Any]
        nexus["listen"] = Int(ports[0])
        nexus["fact"] = Int(ports[1])
        nexus["rpc"] = Int(ports[2])
        // Explicitly empty: this host seeds itself, so the shipped default
        // bootstrap peers must not send it at the public network.
        nexus["peers"] = [String]()
        chains["Nexus"] = nexus
        topology["chains"] = chains
        topology["mine"] = [
            "chain": "Nexus", "worker": "cpu", "workers": 1,
            "batchSize": 100_000, "rewards": "rewards.jsonl",
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: topology)
            .write(to: topologyURL)

        _ = try await runCtl(["up"], root: root)
        let host = CtlHost(root: root, nexusRPC: ports[2])
        hosts.append(host)
        try await waitFor("Nexus active") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
        return host
    }

    private func copyKey(
        _ key: TestKey, into root: URL, name: String
    ) throws {
        try FileManager.default.copyItem(
            at: key.file, to: root.appendingPathComponent("\(name).json")
        )
    }

    /// Deploys a child of `parent` through the CLI, premining it to
    /// `premineTo`, and returns the new chain's RPC port. Each deploy uses
    /// its own funding key nonce (fresh key per call keeps nonces at 0).
    @discardableResult
    private func deployChild(
        _ host: CtlHost,
        directory: String,
        parent: String = "Nexus",
        premineTo: String,
        fund: TestKey
    ) async throws -> UInt16 {
        _ = try await runCtl(try deployArguments(
            host, directory: directory, parent: parent,
            premineTo: premineTo, fund: fund
        ), root: host.root)
        return try childRPC(host, "\(parent)/\(directory)")
    }

    /// `child deploy` arguments for a premined child: writes its spec and
    /// copies the funding key into the host root.
    private func deployArguments(
        _ host: CtlHost,
        directory: String,
        parent: String = "Nexus",
        premineTo: String,
        fund: TestKey
    ) throws -> [String] {
        let spec: [String: Any] = [
            "maxNumberOfTransactionsPerBlock": 100,
            "maxStateGrowth": 100_000,
            "maxBlockSize": 1_000_000,
            "premine": 5_000,
            "targetBlockTime": 1_000,
            "initialReward": 10,
            "halvingInterval": 100_000,
            "retargetWindow": 120,
        ]
        let specURL = host.root.appendingPathComponent("spec-\(directory).json")
        try JSONSerialization.data(withJSONObject: spec).write(to: specURL)
        try copyKey(fund, into: host.root, name: "fund-\(directory)")
        return [
            "child", "deploy", directory,
            "--parent", parent,
            "--spec", specURL.path,
            "--fund", host.root
                .appendingPathComponent("fund-\(directory).json").path,
            "--premine-to", premineTo,
        ]
    }

    /// The RPC port the topology allocated to a deployed chain.
    private func childRPC(_ host: CtlHost, _ path: String) throws -> UInt16 {
        let topology = try JSONSerialization.jsonObject(with: Data(
            contentsOf: host.root.appendingPathComponent("lattice.json")
        )) as! [String: Any]
        let chains = topology["chains"] as! [String: Any]
        let deployed = try XCTUnwrap(
            chains[path] as? [String: Any], "\(path) is not in the tree"
        )
        return UInt16(deployed["rpc"] as! Int)
    }

    // MARK: scenarios

    func testMultichainHostsSyncAcrossTheCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let seller = try await makeKey(scratch, "seller")
        let fund = try await makeKey(scratch, "fund")

        let minerA = try await makeKey(scratch, "minerA")
        var hostA = try await bringUpMiningHost(miner: minerA)
        hostA.childRPC = try await deployChild(
            hostA, directory: "Market",
            premineTo: seller.address, fund: fund
        )
        _ = try await runCtl(["mine", "start"], root: hostA.root)
        try await waitFor("host A mines blocks", seconds: 120) {
            (await self.health(hostA.nexusRPC)?["height"] as? Int ?? 0) >= 3
        }

        // Host B: fresh CLI host peered at A's Nexus, adopting A's child.
        let identity = try await runCtl(["identity"], root: hostA.root)
        func peerString(_ path: String) throws -> String {
            for line in identity.split(separator: "\n")
            where line.hasPrefix("\(path): ") {
                return line.replacingOccurrences(of: "\(path): ", with: "")
            }
            throw CtlE2EError("no identity line for \(path)")
        }
        let nexusPeer = try peerString("Nexus").replacingOccurrences(
            of: "<this-host>:", with: "127.0.0.1:"
        )

        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootB, withIntermediateDirectories: true
        )
        _ = try await runCtl(["init", "--peer", nexusPeer], root: rootB)
        let portsB = randomPorts(3)
        let topologyBURL = rootB.appendingPathComponent("lattice.json")
        var topologyB = try JSONSerialization.jsonObject(
            with: Data(contentsOf: topologyBURL)
        ) as! [String: Any]
        var chainsB = topologyB["chains"] as! [String: Any]
        var nexusB = chainsB["Nexus"] as! [String: Any]
        nexusB["listen"] = Int(portsB[0])
        nexusB["fact"] = Int(portsB[1])
        nexusB["rpc"] = Int(portsB[2])
        chainsB["Nexus"] = nexusB
        topologyB["chains"] = chainsB
        try JSONSerialization.data(withJSONObject: topologyB)
            .write(to: topologyBURL)
        _ = try await runCtl(["up"], root: rootB)
        let hostB = CtlHost(root: rootB, nexusRPC: portsB[2])
        hosts.append(hostB)

        try await waitFor("host B syncs Nexus", seconds: 120) {
            (await self.health(hostB.nexusRPC)?["height"] as? Int ?? 0) >= 3
        }

        _ = try await runCtl(["child", "adopt", "Nexus/Market"], root: rootB)
        // Wire B's child at A's child overlay explicitly (deterministic on
        // loopback), then restart the tree so the peer takes effect.
        let childPeer = try peerString("Nexus/Market").replacingOccurrences(
            of: "<this-host>:", with: "127.0.0.1:"
        )
        var adopted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: topologyBURL)
        ) as! [String: Any]
        var adoptedChains = adopted["chains"] as! [String: Any]
        var market = adoptedChains["Nexus/Market"] as! [String: Any]
        market["peers"] = [childPeer]
        let childRPCB = UInt16(market["rpc"] as! Int)
        adoptedChains["Nexus/Market"] = market
        adopted["chains"] = adoptedChains
        try JSONSerialization.data(withJSONObject: adopted)
            .write(to: topologyBURL)
        _ = try await runCtl(["down"], root: rootB)
        _ = try await runCtl(["up"], root: rootB)

        var targetChildHeight = 0
        try await waitFor("host A child height observable", seconds: 60) {
            targetChildHeight = await self.health(
                hostA.childRPC!
            )?["height"] as? Int ?? 0
            return targetChildHeight >= 1
        }
        try await waitFor("host B syncs the child chain", seconds: 180) {
            guard let health = await self.health(childRPCB),
                  health["phase"] as? String == "active" else { return false }
            return (health["height"] as? Int ?? -1) >= targetChildHeight
        }
    }

    func testFullChildTokenSwapThroughTheCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let seller = try await makeKey(scratch, "seller")
        let fund = try await makeKey(scratch, "fund")
        let buyer = try await makeKey(scratch, "minerSwap")

        var host = try await bringUpMiningHost(miner: buyer)
        host.childRPC = try await deployChild(
            host, directory: "Market",
            premineTo: seller.address, fund: fund
        )
        _ = try await runCtl(["mine", "start"], root: host.root)

        // Fund the buyer parent-side through mining rewards, then switch to
        // rewardless mining so the buyer's nonce sequence is ours to spend.
        try await waitFor("buyer funded by rewards", seconds: 120) {
            let status = try? await self.runCtl(
                ["mine", "status"], root: host.root
            )
            guard let line = status?.split(separator: "\n").first(
                where: { $0.hasPrefix("rewards:") }
            ), let consumed = line.split(separator: " ").dropFirst().first
                .flatMap({ Int($0) }) else { return false }
            return consumed >= 3
        }
        _ = try await runCtl(["mine", "stop"], root: host.root)
        let topologyURL = host.root.appendingPathComponent("lattice.json")
        var topology = try JSONSerialization.jsonObject(
            with: Data(contentsOf: topologyURL)
        ) as! [String: Any]
        var mine = topology["mine"] as! [String: Any]
        mine.removeValue(forKey: "rewards")
        topology["mine"] = mine
        try JSONSerialization.data(withJSONObject: topology)
            .write(to: topologyURL)
        _ = try await runCtl(["mine", "start"], root: host.root)

        let childRPC = host.childRPC!
        func childHeight() async -> Int {
            await health(childRPC)?["height"] as? Int ?? -1
        }
        func mempoolDrained(_ rpc: UInt16) async -> Bool {
            await health(rpc)?["mempoolCount"] as? Int == 0
        }

        // 1. Seller locks 100 on the child, demanding 60 on the parent.
        let heightBeforeDeposit = await childHeight()
        try await runCtl([
            "tx", "deposit", "--chain", "Nexus/Market",
            "--key", seller.file.path,
            "--swap-nonce", "7", "--demand", "60", "--lock", "100",
        ], root: host.root)
        try await waitFor("deposit mined on the child", seconds: 180) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeDeposit && drained
        }

        // 2. Buyer pays the demanded 60 on the parent with a receipt. The
        // buyer's nonce follows its mined rewards; `tx` reads it from state.
        try await runCtl([
            "tx", "receipt", "--chain", "Nexus", "--key", buyer.file.path,
            "--swap-nonce", "7", "--demand", "60",
            "--demander", seller.address, "--directory", "Market",
        ], root: host.root)
        try await waitFor("receipt mined on the parent", seconds: 180) {
            await mempoolDrained(host.nexusRPC)
        }

        // 3. Buyer withdraws the locked 100 on the child.
        let withdrawal = [
            "withdraw", "--chain", "Nexus/Market", "--key", buyer.file.path,
            "--swap-nonce", "7", "--demand", "60",
            "--demander", seller.address, "--amount", "100",
        ]
        // The child validates the withdrawal against its parent-receipt state,
        // which lags the receipt's mining on the parent until a carrier links
        // it. Submitting early is NOT refused: submission preflights with no
        // parent state to check against, so the pool holds the withdrawal as
        // temporarily unavailable and the template decides later. This retries
        // to stay robust against the submits that ARE refused — a stale nonce,
        // or the tip moving under the preflight.
        try await submitUntilAccepted(
            "child accepts the withdrawal", host, withdrawal
        )
        try await waitFor("withdrawal mined on the child", seconds: 240) {
            await mempoolDrained(childRPC)
        }

        // 4. The withdrawn funds are real: spend them.
        let sink = try await makeKey(scratch, "sink")
        let spend = [
            "send", "--chain", "Nexus/Market", "--key", buyer.file.path,
            "--to", sink.address, "--amount", "40",
        ]
        let heightBeforeSpend = await childHeight()
        // Each dependent submit validates against the PRIOR tx's applied,
        // queryable state; mempool-drained only proves the prior tx left the
        // mempool, not that its credit is visible, so a submit can fail-closed
        // 400 until the credit lands. Retry until accepted (same race as the
        // withdrawal submit).
        try await submitUntilAccepted("child accepts the spend", host, spend)
        try await waitFor("dependent spend mined", seconds: 240) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeSpend && drained
        }

        // 5. The credit is real, not merely drained-from-the-mempool: the
        // sink can only spend if step 4 actually credited it. A spend chain
        // is the strongest state proof available over public RPC.
        let sinkSpend = [
            "send", "--chain", "Nexus/Market", "--key", sink.file.path,
            "--to", seller.address, "--amount", "35",
        ]
        let heightBeforeSinkSpend = await childHeight()
        try await submitUntilAccepted(
            "child accepts the sink spend", host, sinkSpend
        )
        try await waitFor("sink spend proves the credited state", seconds: 240) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeSinkSpend && drained
        }

        // 6. Two transfers submitted back to back, before either is mined,
        // must both happen. The signer's next nonce is read from committed
        // state, so without also accounting for what that signer already has
        // pooled, both would be signed at the same nonce — and the pool keeps
        // whichever bids the higher real fee, dropping the other while both
        // commands print `submitted` and exit 0. Paying nobody must never look
        // like success, so assert on the recipient's balance, not on exit
        // codes: only two surviving transfers reach 300.
        let queueTarget = try await makeKey(scratch, "queued")
        let before = await balance(childRPC, queueTarget.address)
        XCTAssertEqual(before, 0, "a fresh key starts unfunded")
        try await submitUntilAccepted("first queued transfer", host, [
            "send", "--chain", "Nexus/Market", "--key", seller.file.path,
            "--to", queueTarget.address, "--amount", "100", "--fee", "1",
        ])
        // Deliberately a HIGHER fee: this is the transaction that would win
        // the replace-by-fee race and silently erase the one above.
        try await submitUntilAccepted("second queued transfer", host, [
            "send", "--chain", "Nexus/Market", "--key", seller.file.path,
            "--to", queueTarget.address, "--amount", "200", "--fee", "9",
        ])
        try await waitFor("both queued transfers mined", seconds: 120) {
            await self.balance(childRPC, queueTarget.address) == 300
        }
    }

    /// One account's balance as the chain currently sees it; 0 when the
    /// account has never been credited.
    private func balance(_ rpc: UInt16, _ address: String) async -> UInt64 {
        guard let url = URL(
            string: "http://127.0.0.1:\(rpc)/api/state/account/\(address)"
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

    /// A swap one level deeper: the seller lives on a GRANDCHILD, the buyer
    /// pays on the middle child chain, and the whole flow rides three-level
    /// merged mining driven from Nexus. Four transactions total: deposit on
    /// the grandchild, receipt on its parent, withdrawal on the grandchild,
    /// and a dependent spend proving the credited state.
    func testGrandchildSwapThroughTheCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerG")
        let seller = try await makeKey(scratch, "sellerG")
        let buyer = try await makeKey(scratch, "buyerG")
        let sink = try await makeKey(scratch, "sinkG")

        let host = try await bringUpMiningHost(miner: miner)
        // Middle chain premined to the BUYER (their receipt funding);
        // grandchild premined to the SELLER (the locked goods).
        let marketRPC = try await deployChild(
            host, directory: "Market",
            premineTo: buyer.address,
            fund: try await makeKey(scratch, "fundMarket")
        )
        let stallsRPC = try await deployChild(
            host, directory: "Stalls", parent: "Nexus/Market",
            premineTo: seller.address,
            fund: try await makeKey(scratch, "fundStalls")
        )
        _ = try await runCtl(["mine", "start"], root: host.root)

        func height(_ rpc: UInt16) async -> Int {
            await health(rpc)?["height"] as? Int ?? -1
        }
        func drained(_ rpc: UInt16) async -> Bool {
            await health(rpc)?["mempoolCount"] as? Int == 0
        }

        // 1. Seller locks 100 on the grandchild, demanding 60 on Market.
        let beforeDeposit = await height(stallsRPC)
        try await runCtl([
            "tx", "deposit", "--chain", "Nexus/Market/Stalls",
            "--key", seller.file.path,
            "--swap-nonce", "9", "--demand", "60", "--lock", "100",
        ], root: host.root)
        try await waitFor("deposit mined on the grandchild", seconds: 240) {
            let now = await height(stallsRPC)
            let empty = await drained(stallsRPC)
            return now > beforeDeposit && empty
        }

        // 2. Buyer pays the demanded 60 on the middle chain.
        let receipt = [
            "receipt", "--chain", "Nexus/Market", "--key", buyer.file.path,
            "--swap-nonce", "9", "--demand", "60",
            "--demander", seller.address, "--directory", "Stalls",
        ]
        // The receipt is an ordinary parent-chain payment, so it is refused
        // outright until the buyer's premined balance is queryable on the
        // middle chain — retry until it funds.
        try await submitUntilAccepted(
            "middle chain accepts the receipt", host, receipt
        )
        try await waitFor("receipt mined on the middle chain", seconds: 240) {
            await drained(marketRPC)
        }

        // 3. Buyer withdraws the locked 100 on the grandchild.
        let withdrawal = [
            "withdraw", "--chain", "Nexus/Market/Stalls",
            "--key", buyer.file.path,
            "--swap-nonce", "9", "--demand", "60",
            "--demander", seller.address, "--amount", "100",
        ]
        // The grandchild validates the withdrawal against its PARENT-chain
        // receipt state, which lags the receipt's mining on the middle chain
        // until a subsequent carrier links it. As on the child above, an early
        // submit is held rather than refused; this retries for the submits
        // that ARE refused.
        try await submitUntilAccepted(
            "grandchild accepts the withdrawal", host, withdrawal
        )
        try await waitFor("withdrawal mined on the grandchild", seconds: 300) {
            await drained(stallsRPC)
        }

        // 4. The credit is real: the buyer spends it onward to the sink.
        let beforeSpend = await height(stallsRPC)
        try await runCtl([
            "tx", "send", "--chain", "Nexus/Market/Stalls",
            "--key", buyer.file.path, "--to", sink.address, "--amount", "40",
        ], root: host.root)
        try await waitFor("dependent spend mined on the grandchild", seconds: 240) {
            let now = await height(stallsRPC)
            let empty = await drained(stallsRPC)
            return now > beforeSpend && empty
        }
    }

    /// Lattice §9.10 through three real nodes and the real wire: Nexus's
    /// work reaches the grandchild through the middle chain, each level
    /// talking only to its immediate parent — across an outage of the middle
    /// chain's node, the case where the parent mines blocks that commit
    /// nothing into the child and only the run report carries them.
    ///
    /// Shape: a CLI host brings up Nexus, Market and its grandchild Stalls
    /// and the coordinator co-mines them. The coordinator then stops, and
    /// full Nexus blocks are mined by hand through the RPC it uses — to
    /// Nexus's own target, so each is a chain block carrying Market's
    /// candidate (which carries Stalls's) — until both descendants' tips sit
    /// on chain committers. Market's node goes down; three more full Nexus
    /// blocks are mined alone, so the run of the last block that carried
    /// Market grows and nothing else mints. Market returns and is credited
    /// on its re-ask; Stalls — which never went away and mined nothing — is
    /// credited through Market (Market's push of the run the credit changed,
    /// or Stalls's own ask; the wire cannot order those two, so the push
    /// itself is pinned by the multichain unit test). Then Stalls restarts
    /// twice, the second time by SIGKILL: each hello re-serves its
    /// committers' runs and every one is refused as not stronger, and after
    /// the crash nothing new is credited — only a credit replayed from its
    /// own fact log explains that. The counters are the ones an operator
    /// watches on /metrics.
    func testNexusWorkReachesTheGrandchildAcrossAMiddleChainOutage() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerRun")
        let holder = try await makeKey(scratch, "holderRun")

        let host = try await bringUpMiningHost(miner: miner)
        let marketRPC = try await deployChild(
            host, directory: "Market",
            premineTo: holder.address,
            fund: try await makeKey(scratch, "fundMarketRun")
        )
        let stallsRPC = try await deployChild(
            host, directory: "Stalls", parent: "Nexus/Market",
            premineTo: holder.address,
            fund: try await makeKey(scratch, "fundStallsRun")
        )
        _ = try await runCtl(["mine", "start"], root: host.root)

        func height(_ rpc: UInt16) async -> Int? {
            await health(rpc)?["height"] as? Int
        }
        func active(_ rpc: UInt16) async -> Bool {
            await health(rpc)?["phase"] as? String == "active"
        }
        let applied = "lattice_parent_run_reports_applied_total"
        let refused = "lattice_parent_run_reports_refused_total"
        // The weighed tip: /health reports the validated height, which lags
        // admission while the validate walk catches up and would count
        // blocks mined before the outage as mined during it.
        func nexusWeighedHeight() async -> Int? {
            await metric(host.nexusRPC, "lattice_chain_tip_height", label: "tier=\"weighed\"")
        }

        // One miner advances all three chains: the grandchild moves without
        // mining of its own.
        try await waitFor("both descendants co-mined", seconds: 120) {
            let market = await height(marketRPC) ?? 0
            let stalls = await height(stallsRPC) ?? 0
            return market >= 1 && stalls >= 1
        }
        // From here the blocks are mined by hand through the RPC the
        // coordinator itself uses, searching to Nexus's OWN target so every
        // block is a chain block. The coordinator hunts the easiest target
        // and so also produces child-only carriers — Nexus-shaped blocks that
        // meet a child's target but not Nexus's, which Nexus never admits;
        // a child whose tip sits on one has no chain committer to be credited
        // through. Stopping it also means nothing pushes from here on, so the
        // outage blocks are the only work a credit can be.
        _ = try await runCtl(["mine", "stop"], root: host.root)
        try await waitForStableHeight(host.nexusRPC)
        // Each descendant's tip is carried by a chain block: a full Nexus
        // block collects Market's candidate, which carries Stalls's.
        let marketBeforeCarryValue = await height(marketRPC)
        let stallsBeforeCarryValue = await height(stallsRPC)
        let marketBeforeCarry = try XCTUnwrap(marketBeforeCarryValue)
        let stallsBeforeCarry = try XCTUnwrap(stallsBeforeCarryValue)
        try await waitFor("descendants carried by full Nexus blocks", seconds: 180) {
            _ = try? await self.mineFullBlock(host.nexusRPC)
            let market = await height(marketRPC) ?? 0
            let stalls = await height(stallsRPC) ?? 0
            return market > marketBeforeCarry && stalls > stallsBeforeCarry
        }

        // Outage: Market's node goes down. Nexus mines on alone, and with no
        // Market candidate to carry, its blocks commit nothing into Market —
        // work only a run report can deliver.
        try await stopChain(host, "Nexus/Market")
        for _ in 0..<3 { _ = try await mineFullBlock(host.nexusRPC) }
        let stallsAppliedBeforeValue = await metric(stallsRPC, applied)
        let stallsAppliedBefore = try XCTUnwrap(stallsAppliedBeforeValue)

        // Market returns: on its hello Nexus re-serves the runs of Market's
        // committers, and the last carrier's run now holds the outage blocks.
        // Counters restart with the process, so any credit here is new.
        _ = try await runCtl(["up"], root: host.root)
        try await waitFor("Market back", seconds: 60) { await active(marketRPC) }
        try await waitFor("Market credited Nexus's run", seconds: 60) {
            (await metric(marketRPC, applied) ?? 0) >= 1
        }
        // Two levels down: Stalls, which never went away and mined nothing,
        // is credited the same work through Market.
        try await waitFor("Stalls credited Market's run", seconds: 60) {
            (await metric(stallsRPC, applied) ?? 0) > stallsAppliedBefore
        }
        let marketConflictsValue = await metric(marketRPC, refused, label: "reason=\"locationConflict\"")
        let stallsConflictsValue = await metric(stallsRPC, refused, label: "reason=\"locationConflict\"")
        let marketConflicts = try XCTUnwrap(marketConflictsValue)
        let stallsConflicts = try XCTUnwrap(stallsConflictsValue)
        XCTAssertEqual(marketConflicts, 0, "a location conflict is a parent naming the wrong block")
        XCTAssertEqual(stallsConflicts, 0)

        // Durable: a restarted Stalls is re-served its committers' runs on
        // its hello and refuses every one as not stronger — which only a
        // credit replayed from its own fact log explains. Twice: the first
        // restart also absorbs any push Stalls missed while reconnecting
        // during Market's outage, so by the second nothing served can be new
        // — and the second is a crash, not a graceful stop.
        for (restart, signal) in [(1, SIGTERM), (2, SIGKILL)] {
            try await stopChain(host, "Nexus/Market/Stalls", signal: signal)
            _ = try await runCtl(["up"], root: host.root)
            try await waitFor("Stalls back (restart \(restart))", seconds: 60) {
                await active(stallsRPC)
            }
            try await waitFor("re-served runs refused as not stronger (restart \(restart))", seconds: 60) {
                (await metric(stallsRPC, refused, label: "reason=\"notStronger\"") ?? 0) >= 1
            }
        }
        // Counters restart with the process: what this one shows is only
        // what the re-serve after the crash did — read once the answers have
        // had time to land, not at the first refusal.
        try await Task.sleep(for: e2eScaled(.seconds(2)))
        let appliedAfterCrashValue = await metric(stallsRPC, applied)
        let appliedAfterCrash = try XCTUnwrap(appliedAfterCrashValue)
        XCTAssertEqual(appliedAfterCrash, 0, "nothing new to credit: every credit was already durable")
    }

    /// Mine one FULL block through the RPC the coordinator uses — the
    /// template collects the children's candidates — searching to the chain's
    /// own target rather than the easiest one, so the block is a chain block
    /// and never a child-only carrier. Returns the accepted block's CID.
    private func mineFullBlock(_ rpc: UInt16) async throws -> String {
        let template: MiningTemplateResponse = try await postJSON(
            rpc, "/v1/mining/templates", MiningTemplateRequest(rewards: []), timeout: 40
        )
        let midstate = ProofOfWork.midstate(for: template.block)
        var nonce: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: nonce) > template.block.target {
            nonce += 1
        }
        let response: SubmitWorkResponse = try await postJSON(
            rpc, "/v1/mining/work",
            SubmitWorkRequest(workID: template.workID, nonce: nonce), timeout: 60
        )
        guard response.accepted else { throw CtlE2EError("full block refused") }
        return try BlockHeader(node: ProofOfWork.withNonce(template.block, nonce: nonce)).rawCID
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        _ rpc: UInt16, _ path: String, _ body: Request, timeout: TimeInterval
    ) async throws -> Response {
        guard let url = URL(string: "http://127.0.0.1:\(rpc)\(path)") else {
            throw CtlE2EError("bad url \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CtlE2EError("\(path): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// A block in flight when the miner stops can still land; settled is two
    /// equal weighed-tip samples a beat apart.
    private func waitForStableHeight(_ rpc: UInt16) async throws {
        var previous: Int?
        try await waitFor("height settled after mining stopped", seconds: 60) {
            guard let now = await self.metric(
                rpc, "lattice_chain_tip_height", label: "tier=\"weighed\""
            ) else { return false }
            defer { previous = now }
            if previous == now { return true }
            try? await Task.sleep(for: e2eScaled(.seconds(2)))
            return false
        }
    }

    /// The shape merged mining produces, with a stop in it: the coordinator
    /// mines all three chains; Market's node is stopped mid-round (SIGTERM,
    /// the deploy case — its shutdown grace is where a parent-carried block
    /// it had just deferred gets cut off with no retry in memory), while
    /// the coordinator's next solves keep carrying that block's sibling on
    /// Nexus's chain. Mining then stops; Market restarts. It must admit the
    /// owed block from its durable edge and be credited the Nexus work above
    /// that block's committer — the run its own tip could never be credited
    /// through, sitting on a carrier Nexus never admitted. The losing
    /// interleaving is the coordinator's to produce, so this is the realistic
    /// scenario, not the deterministic guard: that is the process and
    /// network unit tests, which fail if a deferral consumes the inbox or the
    /// inbox is seeded eagerly.
    func testChildStoppedDuringCoMiningIsCreditedAfterRestart() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerCrash")
        let holder = try await makeKey(scratch, "holderCrash")
        let host = try await bringUpMiningHost(miner: miner)
        let marketRPC = try await deployChild(
            host, directory: "Market", premineTo: holder.address,
            fund: try await makeKey(scratch, "fundMarketCrash")
        )
        let stallsRPC = try await deployChild(
            host, directory: "Stalls", parent: "Nexus/Market", premineTo: holder.address,
            fund: try await makeKey(scratch, "fundStallsCrash")
        )
        _ = try await runCtl(["mine", "start"], root: host.root)
        func height(_ rpc: UInt16) async -> Int? { await health(rpc)?["height"] as? Int }
        func active(_ rpc: UInt16) async -> Bool { await health(rpc)?["phase"] as? String == "active" }
        let applied = "lattice_parent_run_reports_applied_total"
        func nexusWeighedHeight() async -> Int? {
            await metric(host.nexusRPC, "lattice_chain_tip_height", label: "tier=\"weighed\"")
        }
        try await waitFor("both descendants co-mined", seconds: 120) {
            let market = await height(marketRPC) ?? 0
            let stalls = await height(stallsRPC) ?? 0
            return market >= 1 && stalls >= 1
        }
        // Stop Market mid-round, while the coordinator keeps mining.
        try await stopChain(host, "Nexus/Market")
        let nexusAtCrashValue = await nexusWeighedHeight()
        let nexusAtCrash = try XCTUnwrap(nexusAtCrashValue, "Nexus metrics")
        try await waitFor("Nexus mined on through the crash", seconds: 120) {
            (await nexusWeighedHeight() ?? 0) >= nexusAtCrash + 3
        }
        _ = try await runCtl(["mine", "stop"], root: host.root)
        try await waitForStableHeight(host.nexusRPC)

        // Market returns with nothing but its own store: the owed block is
        // admitted from the durable edge, its committer's run is asked for,
        // and the outage work is credited. Counters restart with the process.
        _ = try await runCtl(["up"], root: host.root)
        try await waitFor("Market back", seconds: 60) { await active(marketRPC) }
        try await waitFor("Market credited the outage work after the restart", seconds: 90) {
            (await metric(marketRPC, applied) ?? 0) >= 1
        }
        let conflictsValue = await metric(marketRPC, "lattice_parent_run_reports_refused_total", label: "reason=\"locationConflict\"")
        let conflicts = try XCTUnwrap(conflictsValue)
        XCTAssertEqual(conflicts, 0)
    }

    /// Stop one chain's node the way `lattice down` would (SIGTERM, then
    /// SIGKILL if it lingers), or crash it outright with SIGKILL, leaving the
    /// rest of the tree running; `lattice up` brings it back.
    private func stopChain(
        _ host: CtlHost, _ path: String, signal: Int32 = SIGTERM
    ) async throws {
        let pidFile = host.root.appendingPathComponent("run")
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "-") + ".pid")
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        guard let pid = text.split(separator: " ").first.flatMap({ Int32($0) }) else {
            throw CtlE2EError("no pid recorded for \(path)")
        }
        kill(pid, signal)
        if signal != SIGKILL {
            let grace = ContinuousClock.now + e2eScaled(.seconds(10))
            while ContinuousClock.now < grace, isAlive(pid) {
                try await Task.sleep(for: .milliseconds(200))
            }
            if isAlive(pid) { kill(pid, SIGKILL) }
        }
        try await waitFor("\(path) stopped", seconds: 30) { !self.isAlive(pid) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Alive and not a zombie: a container's PID 1 may never reap, so a
    /// bare `kill(pid, 0)` can keep answering for a process that exited.
    private func isAlive(_ pid: Int32) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["ps", "-o", "stat=", "-p", String(pid)]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return kill(pid, 0) == 0 }
        let state = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        probe.waitUntilExit()
        return !state.isEmpty && !state.contains("Z")
    }

    /// A sample from the node's loopback `/metrics`, summed over the samples
    /// of `name` — narrowed to those carrying `label` (e.g. `tier="weighed"`)
    /// when given. Nil when the scrape itself failed, so an assertion of zero
    /// cannot pass against a node that is not answering.
    private func metric(_ rpc: UInt16, _ name: String, label: String? = nil) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(rpc)/metrics") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        var total = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
        where line.hasPrefix(name + "{") {
            if let label, !line.contains(label) { continue }
            if let value = line.split(separator: " ").last.flatMap({ Int($0) }) {
                total += value
            }
        }
        return total
    }

    /// The deploy that lost a testnet child: its anchor reached the parent,
    /// the process died before the parent recorded it, and the anchor landed
    /// anyway — recording a genesis CID whose bytes had existed only in the
    /// dead process. Every interruption here must leave that genesis
    /// activatable: a re-run resumes the SAME genesis and the SAME signed
    /// anchor, and the child it finally brings up is the one the parent
    /// recorded. The `genesis` line must also survive the kill, since a
    /// killed process never flushes buffered output.
    func testInterruptedChildDeployResumesTheSameGenesis() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerResume")
        let seller = try await makeKey(scratch, "sellerResume")
        let fund = try await makeKey(scratch, "fundResume")
        let host = try await bringUpMiningHost(miner: miner)
        // Nothing mines until step 4: each attempt parks in the poll-only
        // wait, exactly like a deploy against a network of external miners.
        let deploy = try deployArguments(
            host, directory: "Market",
            premineTo: seller.address, fund: fund
        ) + ["--external-mining-wait-seconds", "600"]

        // 1. The parent is unreachable, so submission fails outright. The
        // seed must already be durable: the next attempt is this genesis.
        _ = try await runCtl(["down"], root: host.root)
        let unreachable = try await runCtl(
            deploy, root: host.root, expectFailure: true
        )
        guard let genesis = line("genesis", in: unreachable) else {
            throw CtlE2EError("a deploy names its genesis before submitting: \(unreachable)")
        }
        _ = try await runCtl(["up"], root: host.root)
        try await waitFor("Nexus active again") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }

        // 2. Killed once the anchor is in the parent's mempool: submitted,
        // not recorded.
        let first = try startCtl(deploy, root: host.root, log: "deploy-1")
        try await waitFor("anchor pooled on the parent") {
            (await self.health(host.nexusRPC)?["mempoolCount"] as? Int ?? 0) >= 1
        }
        let firstOutput = try sigkill(first)
        try check(
            line("genesis", in: firstOutput) == genesis,
            "the resumed deploy is genesis \(genesis), flushed before the kill: \(firstOutput)"
        )

        // 3. Resumed while that anchor is still pooled: it must resubmit the
        // identical transaction (which the pool already holds), not a fresh
        // signature at the same nonce that the pool refuses as a replacement.
        let second = try startCtl(deploy, root: host.root, log: "deploy-2")
        try await waitFor("resumed deploy resubmits its anchor") {
            (try? self.output(of: second)).flatMap {
                self.line("anchor", in: $0)
            } != nil || !second.process.isRunning
        }
        try check(
            second.process.isRunning,
            "resubmitting a still-pooled anchor is not a refusal: \((try? output(of: second)) ?? "")"
        )
        let secondOutput = try sigkill(second)
        try check(
            line("genesis", in: secondOutput) == genesis,
            "the second resume is genesis \(genesis) too: \(secondOutput)"
        )

        // 4. The anchor lands while no deploy is running.
        try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("parent records the anchored genesis", seconds: 120) {
            await self.recordedGenesis(host.nexusRPC, "Market") == genesis
        }

        // 5. A re-run finds its genesis already recorded and brings the child
        // up on it. The consequence, not the exit code: an active child whose
        // state carries the seeded premine, on the genesis the parent holds.
        let finished = try await runCtl(deploy, root: host.root)
        try check(
            line("genesis", in: finished) == genesis,
            "the finishing run is genesis \(genesis): \(finished)"
        )
        let childRPC = try childRPC(host, "Nexus/Market")
        try await waitFor("the recorded child is active") {
            await self.health(childRPC)?["phase"] as? String == "active"
        }
        try await waitFor("the child genesis carries the seeded premine") {
            await self.balance(childRPC, seller.address) == 50_000
        }
        let recorded = await recordedGenesis(host.nexusRPC, "Market")
        try check(
            recorded == genesis,
            "the parent still records \(genesis), not \(recorded ?? "nothing")"
        )
    }

    /// A pending deploy must stay correctable. An anchor signed with a nonce
    /// the key has not reached is admitted as `future` and never mined; the
    /// re-run with the right `--nonce` has to re-sign the anchor for the SAME
    /// genesis, not resubmit the stuck transaction forever.
    func testPendingDeployReSignsForACorrectedNonce() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerNonce")
        let seller = try await makeKey(scratch, "sellerNonce")
        let fund = try await makeKey(scratch, "fundNonce")
        let host = try await bringUpMiningHost(miner: miner)
        // External miners are running throughout, so an anchor that never
        // lands is unmineable rather than merely unmined.
        _ = try await runCtl(["mine", "start"], root: host.root)
        let deploy = try deployArguments(
            host, directory: "Market",
            premineTo: seller.address, fund: fund
        )

        // 1. A fresh key expects nonce 0; nonce 5 is pooled as future.
        let stuck = try await runCtl(
            deploy + ["--nonce", "5", "--external-mining-wait-seconds", "1"],
            root: host.root, expectFailure: true
        )
        guard let genesis = line("genesis", in: stuck),
              line("anchor", in: stuck) != nil else {
            throw CtlE2EError("the future-nonce anchor is submitted and pooled: \(stuck)")
        }
        try check(
            await recordedGenesis(host.nexusRPC, "Market") == nil,
            "a future-nonce anchor cannot be recorded: \(stuck)"
        )

        // 2. The corrected re-run brings up the child on that same genesis.
        let corrected = try await runCtl(
            deploy + ["--nonce", "0", "--external-mining-wait-seconds", "120"],
            root: host.root
        )
        try check(
            line("genesis", in: corrected) == genesis,
            "the corrected run resumes genesis \(genesis): \(corrected)"
        )
        let childRPC = try childRPC(host, "Nexus/Market")
        try await waitFor("the corrected child is active") {
            await self.health(childRPC)?["phase"] as? String == "active"
        }
        try await waitFor("the child genesis carries the seeded premine") {
            await self.balance(childRPC, seller.address) == 50_000
        }
        let recorded = await recordedGenesis(host.nexusRPC, "Market")
        try check(
            recorded == genesis,
            "the parent records \(genesis), not \(recorded ?? "nothing")"
        )
    }

    /// Correcting a nonce must not strand the anchor it replaced. The first
    /// anchor stays pooled, so a re-run with the ORIGINAL arguments has to
    /// resubmit that exact transaction: a re-signed copy carries the same
    /// (signers, nonce) at the same fee, which the pool refuses as
    /// `feeTooLow`. Only on macOS is that visible — Linux signatures are
    /// deterministic, so a re-signed copy is byte-identical and already known.
    func testReRunWithOriginalArgumentsResubmitsTheEarlierAnchor() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "minerBack")
        let seller = try await makeKey(scratch, "sellerBack")
        let fund = try await makeKey(scratch, "fundBack")
        // Nothing mines until step 4, so both anchors stay pooled.
        let host = try await bringUpMiningHost(miner: miner)
        let deploy = try deployArguments(
            host, directory: "Market",
            premineTo: seller.address, fund: fund
        )

        // 1. The original anchor, at the nonce the key actually expects.
        let original = try await runCtl(
            deploy + ["--nonce", "0", "--external-mining-wait-seconds", "1"],
            root: host.root, expectFailure: true
        )
        guard let genesis = line("genesis", in: original),
              let anchor = line("anchor", in: original) else {
            throw CtlE2EError("the first deploy submits an anchor: \(original)")
        }
        try await waitFor("the original anchor is pooled") {
            (await self.health(host.nexusRPC)?["mempoolCount"] as? Int ?? 0) >= 1
        }

        // 2. A correction at another nonce: a second anchor, same genesis.
        let corrected = try await runCtl(
            deploy + ["--nonce", "5", "--external-mining-wait-seconds", "1"],
            root: host.root, expectFailure: true
        )
        try check(
            line("genesis", in: corrected) == genesis,
            "the correction keeps genesis \(genesis): \(corrected)"
        )
        try await waitFor("both anchors are pooled") {
            (await self.health(host.nexusRPC)?["mempoolCount"] as? Int ?? 0) >= 2
        }

        // 3. Back to the original arguments while anchor 1 is still pooled.
        let again = try startCtl(
            deploy + ["--nonce", "0", "--external-mining-wait-seconds", "600"],
            root: host.root, log: "deploy-again"
        )
        defer { _ = try? sigkill(again) }
        try await waitFor("the re-run resubmits rather than re-signing") {
            (try? self.output(of: again)).flatMap {
                self.line("anchor", in: $0)
            } != nil || !again.process.isRunning
        }
        let resubmitted = try output(of: again)
        try check(
            again.process.isRunning,
            "resubmitting the still-pooled original anchor is not a refusal: \(resubmitted)"
        )
        try check(
            line("anchor", in: resubmitted) == anchor,
            "it resubmits the original anchor \(anchor): \(resubmitted)"
        )

        // 4. It is a real anchor: let miners record it and bring the child up.
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("the deploy finishes", seconds: 240) {
            !again.process.isRunning
        }
        let finished = try awaitExit(again)
        try check(
            again.process.terminationStatus == 0,
            "the resumed deploy completed: \(finished)"
        )
        let childRPC = try childRPC(host, "Nexus/Market")
        try await waitFor("the child is active") {
            await self.health(childRPC)?["phase"] as? String == "active"
        }
        try await waitFor("the child genesis carries the seeded premine") {
            await self.balance(childRPC, seller.address) == 50_000
        }
        let recorded = await recordedGenesis(host.nexusRPC, "Market")
        try check(
            recorded == genesis,
            "the parent records \(genesis), not \(recorded ?? "nothing")"
        )
    }

    /// Throws rather than recording an XCTAssert failure: on macOS, assertion
    /// failures recorded after a spawned process exits intermittently vanish
    /// from the run's failure count, which would make these checks vacuous.
    private func check(
        _ condition: Bool, _ message: @autoclosure () -> String
    ) throws {
        guard condition else { throw CtlE2EError(message()) }
    }

    /// A `lattice` invocation left running, its combined output going to a
    /// FILE so exactly what it flushed survives a SIGKILL.
    private struct RunningCtl {
        let process: Process
        let log: URL
        let handle: FileHandle
    }

    private func startCtl(
        _ arguments: [String], root: URL, log name: String
    ) throws -> RunningCtl {
        let log = root.appendingPathComponent("\(name).log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = try binary("E2E_CTL_BIN", "lattice")
        process.arguments = arguments + ["--root", root.path]
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return RunningCtl(process: process, log: log, handle: handle)
    }

    private func output(of running: RunningCtl) throws -> String {
        String(decoding: try Data(contentsOf: running.log), as: UTF8.self)
    }

    /// Waits for a run that is expected to finish on its own.
    private func awaitExit(_ running: RunningCtl) throws -> String {
        running.process.waitUntilExit()
        try? running.handle.close()
        return try output(of: running)
    }

    /// SIGKILL: no exit handlers and no stdio flush, only what already
    /// reached the file.
    private func sigkill(_ running: RunningCtl) throws -> String {
        if running.process.isRunning {
            _ = kill(running.process.processIdentifier, SIGKILL)
        }
        running.process.waitUntilExit()
        try? running.handle.close()
        return try output(of: running)
    }

    /// The value of the first `<key> <value>` line in CLI output.
    private func line(_ key: String, in output: String) -> String? {
        output.split(separator: "\n")
            .first { $0.hasPrefix("\(key) ") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    /// The genesis CID the parent has committed for `directory`, if any.
    private func recordedGenesis(
        _ rpc: UInt16, _ directory: String
    ) async -> String? {
        guard let url = URL(
            string: "http://127.0.0.1:\(rpc)/api/chain/children?limit=100"
        ) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
           let object = try? JSONSerialization.jsonObject(with: data)
               as? [String: Any],
           let children = object["children"] as? [[String: Any]] else {
            return nil
        }
        return children.first {
            ($0["chainPath"] as? [String])?.last == directory
        }?["genesisHash"] as? String
    }
}

private struct CtlE2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
