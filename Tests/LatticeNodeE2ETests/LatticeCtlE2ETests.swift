import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
