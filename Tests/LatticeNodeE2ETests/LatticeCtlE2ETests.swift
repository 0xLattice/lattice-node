import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeNode
import UInt256
import XCTest
import cashew

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

    private func health(_ rpc: UInt16) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(rpc)/health"),
              let (data, _) = try? await URLSession.shared.data(
                from: url
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

    private struct KeyFile: Decodable {
        let address: String
        let privateKey: String
        let publicKey: String
    }

    private func makeKey(_ directory: URL, _ name: String) async throws -> KeyFile {
        let path = directory.appendingPathComponent("\(name).json")
        _ = try await runRewards(["generate-key", "--out", path.path])
        return try JSONDecoder().decode(
            KeyFile.self, from: Data(contentsOf: path)
        )
    }

    private func signedTransaction(
        key: KeyFile,
        chainPath: [String],
        accountActions: [AccountAction] = [],
        depositActions: [DepositAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = [],
        fee: UInt64 = 0,
        nonce: UInt64
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: accountActions,
            actions: [],
            depositActions: depositActions,
            genesisActions: [],
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: [key.address],
            fee: fee,
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: header, privateKeyHex: key.privateKey
        ) else { throw CtlE2EError("signing failed") }
        return Transaction(
            signatures: [key.publicKey: signature], body: header
        )
    }

    private func submit(
        _ transaction: Transaction, rpc: UInt16, label: String = ""
    ) async throws {
        guard let url = URL(
            string: "http://127.0.0.1:\(rpc)/v1/transactions"
        ) else { throw CtlE2EError("bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SubmitTransactionRequest(transaction: transaction)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CtlE2EError("submit \(label) failed: HTTP \(status) \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// Brings up one CLI-managed host mining Nexus with rewards to `miner`,
    /// then deploys a premined child.
    private func bringUpMiningHost(
        miner: KeyFile
    ) async throws -> CtlHost {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        _ = try await runCtl(["init"], root: root)
        try writeMinerKey(miner, into: root, name: "miner")
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

    private func writeMinerKey(
        _ key: KeyFile, into root: URL, name: String
    ) throws {
        let encoder = JSONEncoder()
        try encoder.encode([
            "address": key.address,
            "privateKey": key.privateKey,
            "publicKey": key.publicKey,
        ]).write(to: root.appendingPathComponent("\(name).json"))
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
        fund: KeyFile
    ) async throws -> UInt16 {
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
        try writeMinerKey(fund, into: host.root, name: "fund-\(directory)")
        _ = try await runCtl([
            "child", "deploy", directory,
            "--parent", parent,
            "--spec", specURL.path,
            "--fund", host.root
                .appendingPathComponent("fund-\(directory).json").path,
            "--premine-to", premineTo,
        ], root: host.root)
        let topology = try JSONSerialization.jsonObject(with: Data(
            contentsOf: host.root.appendingPathComponent("lattice.json")
        )) as! [String: Any]
        let chains = topology["chains"] as! [String: Any]
        let deployed = chains["\(parent)/\(directory)"] as! [String: Any]
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
        let status = try await runCtl(["mine", "status"], root: host.root)
        guard let rewardsLine = status.split(separator: "\n").first(
            where: { $0.hasPrefix("rewards:") }
        ), let buyerNonce = rewardsLine.split(separator: " ")
            .dropFirst().first.flatMap({ UInt64($0) }) else {
            throw CtlE2EError("could not read reward cursor")
        }
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
        let deposit = try signedTransaction(
            key: seller,
            chainPath: ["Nexus", "Market"],
            accountActions: [AccountAction(owner: seller.address, delta: -100)],
            depositActions: [DepositAction(
                nonce: 7, demander: seller.address,
                amountDemanded: 60, amountDeposited: 100
            )],
            nonce: 0
        )
        let heightBeforeDeposit = await childHeight()
        try await submit(deposit, rpc: childRPC, label: "deposit")
        try await waitFor("deposit mined on the child", seconds: 180) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeDeposit && drained
        }

        // 2. Buyer pays the demanded 60 on the parent with a receipt.
        let receipt = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            receiptActions: [ReceiptAction(
                withdrawer: buyer.address, nonce: 7,
                demander: seller.address, amountDemanded: 60,
                directory: "Market"
            )],
            nonce: buyerNonce
        )
        try await submit(receipt, rpc: host.nexusRPC, label: "receipt")
        try await waitFor("receipt mined on the parent", seconds: 180) {
            await mempoolDrained(host.nexusRPC)
        }

        // 3. Buyer withdraws the locked 100 on the child.
        let withdrawal = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus", "Market"],
            accountActions: [AccountAction(owner: buyer.address, delta: 100)],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyer.address, nonce: 7,
                demander: seller.address, amountDemanded: 60,
                amountWithdrawn: 100
            )],
            nonce: 0
        )
        try await submit(withdrawal, rpc: childRPC, label: "withdrawal")
        try await waitFor("withdrawal mined on the child", seconds: 240) {
            await mempoolDrained(childRPC)
        }

        // 4. The withdrawn funds are real: spend them.
        let sink = try await makeKey(scratch, "sink")
        let spend = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus", "Market"],
            accountActions: [
                AccountAction(owner: buyer.address, delta: -40),
                AccountAction(owner: sink.address, delta: 40),
            ],
            nonce: 1
        )
        let heightBeforeSpend = await childHeight()
        try await submit(spend, rpc: childRPC, label: "spend")
        try await waitFor("dependent spend mined", seconds: 240) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeSpend && drained
        }

        // 5. The credit is real, not merely drained-from-the-mempool: the
        // sink can only spend if step 4 actually credited it. A spend chain
        // is the strongest state proof available over public RPC.
        let sinkSpend = try signedTransaction(
            key: sink,
            chainPath: ["Nexus", "Market"],
            accountActions: [
                AccountAction(owner: sink.address, delta: -35),
                AccountAction(owner: seller.address, delta: 35),
            ],
            nonce: 0
        )
        let heightBeforeSinkSpend = await childHeight()
        try await submit(sinkSpend, rpc: childRPC, label: "sink-spend")
        try await waitFor("sink spend proves the credited state", seconds: 240) {
            let height = await childHeight()
            let drained = await mempoolDrained(childRPC)
            return height > heightBeforeSinkSpend && drained
        }
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
        let deposit = try signedTransaction(
            key: seller,
            chainPath: ["Nexus", "Market", "Stalls"],
            accountActions: [AccountAction(owner: seller.address, delta: -100)],
            depositActions: [DepositAction(
                nonce: 9, demander: seller.address,
                amountDemanded: 60, amountDeposited: 100
            )],
            nonce: 0
        )
        let beforeDeposit = await height(stallsRPC)
        try await submit(deposit, rpc: stallsRPC, label: "grandchild-deposit")
        try await waitFor("deposit mined on the grandchild", seconds: 240) {
            let now = await height(stallsRPC)
            let empty = await drained(stallsRPC)
            return now > beforeDeposit && empty
        }

        // 2. Buyer pays the demanded 60 on the middle chain.
        let receipt = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus", "Market"],
            receiptActions: [ReceiptAction(
                withdrawer: buyer.address, nonce: 9,
                demander: seller.address, amountDemanded: 60,
                directory: "Stalls"
            )],
            nonce: 0
        )
        try await submit(receipt, rpc: marketRPC, label: "child-receipt")
        try await waitFor("receipt mined on the middle chain", seconds: 240) {
            await drained(marketRPC)
        }

        // 3. Buyer withdraws the locked 100 on the grandchild.
        let withdrawal = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus", "Market", "Stalls"],
            accountActions: [AccountAction(owner: buyer.address, delta: 100)],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyer.address, nonce: 9,
                demander: seller.address, amountDemanded: 60,
                amountWithdrawn: 100
            )],
            nonce: 0
        )
        // The grandchild validates the withdrawal against its PARENT-chain
        // receipt state, which lags the receipt's mining on the middle chain
        // until a subsequent carrier links it — the node correctly fail-closed
        // 400s a withdrawal it cannot yet prove. Retry the submit until the
        // grandchild's parent view includes the receipt (the recurring
        // 2-core-runner flake was this race).
        try await waitFor("grandchild accepts the withdrawal", seconds: 240) {
            do {
                try await self.submit(
                    withdrawal, rpc: stallsRPC, label: "grandchild-withdrawal"
                )
                return true
            } catch {
                return false
            }
        }
        try await waitFor("withdrawal mined on the grandchild", seconds: 300) {
            await drained(stallsRPC)
        }

        // 4. The credit is real: the buyer spends it onward to the sink.
        let spend = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus", "Market", "Stalls"],
            accountActions: [
                AccountAction(owner: buyer.address, delta: -40),
                AccountAction(owner: sink.address, delta: 40),
            ],
            nonce: 1
        )
        let beforeSpend = await height(stallsRPC)
        try await submit(spend, rpc: stallsRPC, label: "grandchild-spend")
        try await waitFor("dependent spend mined on the grandchild", seconds: 240) {
            let now = await height(stallsRPC)
            let empty = await drained(stallsRPC)
            return now > beforeSpend && empty
        }
    }
}

private struct CtlE2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
