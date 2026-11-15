import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeCtlCore
import LatticeMinerCore
import LatticeNode
import XCTest
import cashew
import LatticeNodeAPI

/// Black-box E2Es for the `lattice` operator CLI: real shipped binaries,
/// public HTTP, nothing in-process. Proves the CLI can bring up a Nexus
/// node, mine it, and move value with `lattice tx`.
final class LatticeCtlE2ETests: XCTestCase {
    // MARK: harness

    private struct CtlHost {
        let root: URL
        let nexusRPC: UInt16
        let supervisor: NodeSupervisor
    }

    private var hosts: [CtlHost] = []
    /// Miners run under roots of their own, apart from any node's.
    private var minerRoots: [URL] = []

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
        for root in minerRoots {
            _ = try? await runCtl(["mine", "stop"], root: root)
            if !failed { try? FileManager.default.removeItem(at: root) }
        }
        minerRoots = []
        for host in hosts {
            _ = try? await runCtl(["mine", "stop"], root: host.root)
            _ = try? await runCtl(["down"], root: host.root)
            host.supervisor.stop()
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
    private func bringUpMiningHost(
        miner: TestKey?, minRelayFee: UInt64? = nil, olderMiningConfig: Bool = false,
        configure: (inout Topology) -> Void = { _ in }
    ) async throws -> CtlHost {
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
        topology.peers = ChainPeers(byChain: ["Nexus": []])
        topology.minRelayFee = minRelayFee
        configure(&topology)
        try topology.validated().save(root: root)
        try writeMinerConfig(root, recipients: miner.map { ["Nexus": $0.address] } ?? [:])
        if olderMiningConfig {
            // As a host upgraded from a release whose miner read lattice.json:
            // its `mine` object there and no miner.json.
            let file = root.appendingPathComponent(MinerConfig.fileName)
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: topologyURL)) as? [String: Any])
            var mine = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            mine["enabled"] = true
            object["mine"] = mine
            try JSONSerialization.data(withJSONObject: object).write(to: topologyURL)
            try FileManager.default.removeItem(at: file)
        }

        let host = CtlHost(
            root: root, nexusRPC: ports[1],
            supervisor: NodeSupervisor(lattice: try binary("E2E_CTL_BIN", "lattice"), root: root)
        )
        try host.supervisor.start()
        hosts.append(host)
        try await waitFor("Nexus active") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
        return host
    }

    /// The miner's own settings under `root` (its miner.json), which the
    /// loop reads again before each round.
    private func writeMinerConfig(_ root: URL, recipients: [String: String]) throws {
        try JSONEncoder().encode(MinerConfig(
            worker: "cpu", workers: 1, batchSize: 100_000, recipients: recipients
        )).write(to: root.appendingPathComponent(MinerConfig.fileName), options: .atomic)
    }

    /// Pays `chain`'s rewards to `address` from the next round, beside the
    /// recipients already set.
    private func setRecipient(_ root: URL, _ chain: String, _ address: String) throws {
        let file = root.appendingPathComponent(MinerConfig.fileName)
        var recipients = try MinerConfig.load(file: file).recipients ?? [:]
        recipients[chain] = address
        try writeMinerConfig(root, recipients: recipients)
    }

    /// The configuration in layers: a fragment applied, one written by hand
    /// and read on SIGHUP, a chain another fragment lists refused to `child
    /// unhost`, one a chain under it keeps said to stay; and an operator listener whose port is taken reported, not
    /// fatal.
    func testFragmentsAndAnOperatorListenerThatCannotOpen() async throws {
        #if canImport(Darwin)
        let held = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let held = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        defer { close(held) }
        let port = randomPorts(1)[0]
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(held, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(held, 1), 0)
        let host = try await bringUpMiningHost(miner: nil) {
            $0.operatorListen = "127.0.0.1:\(port)"
            $0.operatorTokens = "operator-tokens.json"
        }
        let status = try await runCtl(["status"], root: host.root)
        XCTAssertTrue(status.contains("Nexus: active") && status.contains("operatorListen"), status)

        // A fragment applied: its chain is hosted at once, its value waits.
        let file = host.root.appendingPathComponent("hostmarket.json")
        try Data(#"{"hostedChains":["Nexus/Beta"],"minRelayFee":4}"#.utf8).write(to: file)
        let applied = try await runCtl(["apply", "-f", file.path, "--fragment", "hostmarket"], root: host.root)
        XCTAssertTrue(applied.contains("minRelayFee"), applied)
        let fragment = try await runCtl(["config", "get", "--fragment", "hostmarket"], root: host.root)
        XCTAssertTrue(fragment.contains("Nexus/Beta"), fragment)
        let refused = try await runCtl(["child", "unhost", "Nexus/Beta"], root: host.root, expectFailure: true)
        XCTAssertTrue(refused.contains("listed by hostmarket"), refused)
        // A chain listed under it keeps it hosted: said, not refused.
        _ = try await runCtl(["child", "host", "Nexus/Delta/Eps"], root: host.root)
        _ = try await runCtl(["child", "host", "Nexus/Delta"], root: host.root)
        let kept = try await runCtl(["child", "unhost", "Nexus/Delta"], root: host.root)
        XCTAssertTrue(kept.contains("still hosted for Nexus/Delta/Eps"), kept)
        let implied = try await runCtl(["status"], root: host.root)
        XCTAssertTrue(implied.contains("Nexus/Delta: implied by Nexus/Delta/Eps"), implied)

        // A fragment written by hand is read on SIGHUP, and a later one wins.
        try Data(#"{"minRelayFee":9}"#.utf8).write(to: ConfigFragments.file(root: host.root, name: "zz-hand"))
        XCTAssertEqual(kill(try XCTUnwrap(host.supervisor.pid), SIGHUP), 0)
        try await waitFor("the hand-written fragment is read") {
            let fee = try? await self.runCtl(["config", "get", "minRelayFee"], root: host.root)
            return fee?.contains("9") == true
        }
        XCTAssertTrue(host.supervisor.isRunning, "SIGHUP does not stop the node")
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
        // Upgraded with no edits: the node starts from a lattice.json that
        // still holds `mine`, and the miner mines from it.
        let host = try await bringUpMiningHost(miner: miner, olderMiningConfig: true)
        // The operator port refuses a client without the cookie; the CLI and
        // its coordinator below carry it.
        var bare = URLRequest(url: URL(string: "http://127.0.0.1:\(host.nexusRPC)/status")!)
        bare.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, refused) = try await URLSession.shared.data(for: bare)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
        let started = try await runCtl(["mine", "start"], root: host.root)
        XCTAssertTrue(started.contains("copied"), "the miner copies the older settings to miner.json: \(started)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.root.appendingPathComponent(MinerConfig.fileName).path))
        try await waitFor("miner funded by Nexus rewards", seconds: 180) {
            await self.balance(host, miner.address) >= 10
        }
        try await submitUntilAccepted("Nexus accepts the transfer", host, [
            "send", "--chain", "Nexus", "--key", miner.file.path,
            "--to", recipient.address, "--amount", "10",
        ])
        try await waitFor("transfer mined", seconds: 240) {
            await self.balance(host, recipient.address) == 10
        }
    }

    /// A key with no balance transacts on a Nexus with a relay floor by
    /// paying a sponsor in work.
    func testAnUnfundedKeyTransactsUnderAFloorByPayingASponsorInWork() async throws {
        try requireSponsor()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sponsorKey = try await makeKey(scratch, "sponsor")
        let host = try await bringUpMiningHost(miner: sponsorKey, minRelayFee: 5)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("sponsor funded by Nexus rewards", seconds: 180) {
            await self.balance(host, sponsorKey.address) >= 50
        }
        try await transactThroughSponsor(host, chain: "Nexus", sponsorKey: sponsorKey)
    }

    /// The same on a merge-mined child, from the same sponsor: its shares are
    /// priced on the child's block in the merged template and its fee is paid
    /// in the child's coin.
    func testAnUnfundedKeyTransactsOnAChildUnderAFloorByPayingASponsorInWork() async throws {
        try requireSponsor()
        let alpha = "Nexus/Alpha"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sponsorKey = try await makeKey(scratch, "sponsor")
        let host = try await bringUpMiningHost(miner: nil, minRelayFee: 5)
        _ = try await runCtl(["child", "create", alpha, "--block-time", "1000", "--reward", "100"], root: host.root)
        try setRecipient(host.root, alpha, sponsorKey.address)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("sponsor funded by Alpha rewards", seconds: 180) {
            await self.balance(host, sponsorKey.address, chain: alpha) >= 50
        }
        try await transactThroughSponsor(host, chain: alpha, sponsorKey: sponsorKey)
    }

    /// lattice-sponsor, from its own repository (0xLattice/lattice-sponsor),
    /// whose CI runs these tests against this node with `E2E_SPONSOR_BIN`.
    /// Without it they skip.
    @discardableResult
    private func requireSponsor() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["E2E_SPONSOR_BIN"], !path.isEmpty else {
            throw XCTSkip("E2E_SPONSOR_BIN is not set; lattice-sponsor's CI runs this test")
        }
        return URL(fileURLWithPath: path)
    }

    /// A fresh key's first transaction on `chain`: the node's floor refuses
    /// it at zero fee, `lattice-sponsor` sells it the fee for shares of the
    /// sponsor's block template, and the co-signed transaction is mined.
    private func transactThroughSponsor(_ host: CtlHost, chain: String, sponsorKey: TestKey) async throws {
        let client = CryptoUtils.generateKeyPair()
        let draft = TransactionBody(
            accountActions: [],
            actions: [Action(key: "greeting", oldValue: nil, newValue: "hello")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: client.publicKey)],
            nonce: 0,
            chainPath: chain.components(separatedBy: "/")
        )
        func signed(_ body: TransactionBody, adding signatures: [String: String] = [:]) throws -> Transaction {
            let header = try HeaderImpl(node: body)
            var all = signatures
            all[client.publicKey] = TransactionSigning.sign(bodyHeader: header, privateKeyHex: client.privateKey)
            return Transaction(signatures: all, body: header)
        }
        let node = "http://127.0.0.1:\(host.nexusRPC)"
        let cookie = HostLayout(root: host.root.path).rpcCookie
        let (refusedStatus, refusal) = try await postJSON(
            "\(node)/transactions", SubmitTransactionRequest(transaction: try signed(draft)), cookie: cookie
        )
        XCTAssertFalse((200..<300).contains(refusedStatus), "the floor refuses a zero-fee transaction")
        XCTAssertTrue(String(decoding: refusal, as: UTF8.self).contains("belowMinRelayFee"))

        let port = randomPorts(1)[0]
        let sponsorProcess = Process()
        sponsorProcess.executableURL = try requireSponsor()
        sponsorProcess.arguments = [
            "--node", node, "--cookie-file", cookie.path, "--key", sponsorKey.file.path,
            "--share-work", "2^8", "--port", String(port),
        ]
        sponsorProcess.standardOutput = FileHandle.nullDevice
        sponsorProcess.standardError = FileHandle.nullDevice
        try sponsorProcess.run()
        defer { stop(sponsorProcess) }
        let sponsor = "http://127.0.0.1:\(port)"
        struct NewWork: Encodable { let chain: String }
        var work: [String: Any] = [:]
        try await waitFor("the sponsor hands out work") {
            guard let (status, data) = try? await self.postJSON("\(sponsor)/work", NewWork(chain: chain)),
                  status == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            work = object
            return true
        }
        let clientToken = try XCTUnwrap(work["client"] as? String)
        let assignment = try XCTUnwrap(work["assignment"] as? String)
        let prefix = try XCTUnwrap((work["prefixHex"] as? String).flatMap { Data(hex: $0) })
        let shareTarget = try XCTUnwrap((work["shareTarget"] as? String).flatMap(MinerLoopLogic.parseTarget))
        let start = try XCTUnwrap((work["startNonce"] as? String).flatMap { UInt64($0) })
        let needed = try XCTUnwrap((work["sharesForFee"] as? String).flatMap { UInt64($0) })
        XCTAssertGreaterThan(needed, 0)

        struct Share: Encodable {
            let assignment: String
            let nonce: String
        }
        let midstate = ProofOfWork.midstate(prefixBytes: ContiguousArray(prefix))
        var found: UInt64 = 0
        var nonce = start
        while found < needed {
            if ProofOfWork.hash(midstate: midstate, nonce: nonce) <= shareTarget {
                let (status, body) = try await postJSON(
                    "\(sponsor)/shares", Share(assignment: assignment, nonce: String(nonce))
                )
                XCTAssertEqual(status, 200, String(decoding: body, as: UTF8.self))
                found += 1
            }
            nonce += 1
        }

        struct SponsorRequest: Encodable {
            let client: String
            let transaction: ContentBoundTransaction
        }
        struct Sponsored: Decodable {
            let transaction: ContentBoundTransaction
        }
        let (sponsoredStatus, sponsoredData) = try await postJSON(
            "\(sponsor)/sponsor",
            SponsorRequest(client: clientToken, transaction: ContentBoundTransaction(signatures: [:], body: draft))
        )
        XCTAssertEqual(sponsoredStatus, 200, String(decoding: sponsoredData, as: UTF8.self))
        let sponsored = try JSONDecoder().decode(Sponsored.self, from: sponsoredData).transaction
        let (submitStatus, submitData) = try await postJSON(
            "\(node)/transactions",
            SubmitTransactionRequest(transaction: try signed(sponsored.body, adding: sponsored.signatures)),
            cookie: cookie
        )
        XCTAssertEqual(submitStatus, 200, String(decoding: submitData, as: UTF8.self))
        let cid = try JSONDecoder().decode(SubmitTransactionResponse.self, from: submitData).transactionCID
        try await waitFor("the sponsored transaction is mined", seconds: 240) {
            guard let url = URL(string: "\(node)/api/transaction/\(cid)" + Self.query(chain)),
                  let authorization = try? String(contentsOf: cookie, encoding: .utf8) else { return false }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Basic " + Data(authorization.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let transaction = try? JSONDecoder().decode(ExplorerTransaction.self, from: data) else {
                return false
            }
            return transaction.blockHeight != nil
        }
    }

    /// Stop and reap `process`, bounded. `waitUntilExit` on a child whose
    /// output nobody reads was seen to miss its exit and hang the teardown.
    private func stop(_ process: Process) {
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            // Reaped here, or already by Foundation (-1, ECHILD).
            if waitpid(process.processIdentifier, nil, WNOHANG) != 0 { return }
            usleep(50_000)
        }
        kill(process.processIdentifier, SIGKILL)
    }

    private func postJSON<Body: Encodable>(
        _ address: String, _ body: Body, cookie: URL? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie, let value = try? String(contentsOf: cookie, encoding: .utf8) {
            request.setValue("Basic " + Data(value.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func query(_ chain: String) -> String {
        chain == "Nexus" ? "" : "?chainPath=\(chain)"
    }

    /// The child directories `chain`'s executed blocks have committed, read
    /// with the node's loopback cookie.
    private func childDirectories(_ host: CtlHost, chain: String = "Nexus") async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:\(host.nexusRPC)/api/chain/children?chainPath=\(chain)"),
              let cookie = try? String(contentsOf: HostLayout(root: host.root.path).rpcCookie, encoding: .utf8) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["directories"] as? [String]
    }

    private func height(_ rpc: UInt16, chain: String) async -> Int {
        (await health(rpc, chain: chain)?["height"] as? String).flatMap { Int($0) } ?? -1
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
        try setRecipient(host.root, alpha, miner.address)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("Alpha mined by merged mining", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) >= 2
        }
        try await waitFor("Nexus lists Alpha as a child") {
            await self.childDirectories(host) == ["Alpha"]
        }
        try await waitFor("the Alpha miner is funded", seconds: 180) {
            await self.balance(host, miner.address, chain: alpha) >= 10
        }
        try await submitUntilAccepted("Alpha accepts the transfer", host, [
            "send", "--chain", alpha, "--key", miner.file.path,
            "--to", recipient.address, "--amount", "10",
        ])
        try await waitFor("the Alpha transfer is mined", seconds: 240) {
            await self.balance(host, recipient.address, chain: alpha) == 10
        }
        let before = await height(host.nexusRPC, chain: alpha)
        _ = try await runCtl(["mine", "stop"], root: host.root)
        // Asked to stop, the node exits 0 and its process manager leaves it.
        _ = try await runCtl(["down"], root: host.root)
        try await waitFor("the node exits") { !host.supervisor.isRunning }
        XCTAssertEqual(host.supervisor.exits.last, 0)
        try host.supervisor.start()
        try await waitFor("Alpha resumes where it was") {
            await self.height(host.nexusRPC, chain: alpha) >= before
        }
        let listed = await childDirectories(host)
        XCTAssertEqual(listed, ["Alpha"], "the list is rebuilt from the store on restart")
        let balance = await balance(host, recipient.address, chain: alpha)
        XCTAssertEqual(balance, 10)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("Alpha advances after the restart", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) > before
        }
    }

    /// A WASM policy module that accepts everything: the memory, allocator
    /// and transaction entrypoint the policy ABI requires, and nothing else.
    /// `heapPage` is where its allocator points, so two values give two modules.
    private static func acceptAllPolicyModule(heapPage: UInt8) -> Data {
        func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }
        func export(_ name: String, kind: UInt8, index: UInt8) -> [UInt8] {
            [UInt8(name.utf8.count)] + Array(name.utf8) + [kind, index]
        }
        var exports: [UInt8] = [0x03]
        exports += export("memory", kind: 2, index: 0)
        exports += export("lattice_alloc", kind: 0, index: 0)
        exports += export("lattice_validate_transaction", kind: 0, index: 1)
        var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        // (i32) -> i32 and (i32, i32) -> i32
        module += section(1, [0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f])
        module += section(3, [0x02, 0x00, 0x01])
        module += section(5, [0x01, 0x00, 0x01])
        module += section(7, exports)
        // lattice_alloc returns heapPage * 128; the entrypoint returns 1.
        module += section(10, [0x02, 0x05, 0x00, 0x41, 0x80, heapPage, 0x0b, 0x04, 0x00, 0x41, 0x01, 0x0b])
        return Data(module)
    }

    /// A child chain whose spec names two WASM policies and a premine, all
    /// through the CLI: created only with every module the spec names and an
    /// account for the premine, mined by merged mining with its genesis paying
    /// that account and carrying its creator's signed claim, and a transaction
    /// on it that both policies have to accept.
    func testAChildChainWithAPolicyIsCreatedMergeMinedAndTransactedThroughTheCLI() async throws {
        let alpha = "Nexus/Alpha"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-ctlpolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let miner = try await makeKey(scratch, "alpha-miner")
        let recipient = try await makeKey(scratch, "alpha-recipient")

        let modules = [Self.acceptAllPolicyModule(heapPage: 8), Self.acceptAllPolicyModule(heapPage: 16)]
        let moduleFiles = ["first.wasm", "second.wasm"].map { scratch.appendingPathComponent($0) }
        for (module, file) in zip(modules, moduleFiles) { try module.write(to: file) }
        let otherFile = scratch.appendingPathComponent("other.wasm")
        try Self.acceptAllPolicyModule(heapPage: 24).write(to: otherFile)
        let moduleCIDs = try modules.map { try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: $0)).rawCID }
        let specFile = scratch.appendingPathComponent("alpha-spec.json")
        try JSONEncoder().encode(ChainSpec(
            maxNumberOfTransactionsPerBlock: 1_000, maxStateGrowth: 1_000_000, premine: 3,
            targetBlockTime: 1_000, initialReward: 100, halvingInterval: 1_000_000, halfLife: 100,
            wasmPolicies: moduleCIDs.map { WasmPolicyRef(moduleCID: $0, scope: .transaction) }
        )).write(to: specFile)

        let host = try await bringUpMiningHost(miner: nil)
        let create = ["child", "create", alpha, "--spec", specFile.path]
        let partial = try await runCtl(
            create + ["--policy-module", moduleFiles[0].path], root: host.root, expectFailure: true
        )
        XCTAssertTrue(partial.contains(moduleCIDs[1]), "every module the spec names must be given: \(partial)")
        let wrong = try await runCtl(
            create + ["--policy-module", otherFile.path], root: host.root, expectFailure: true
        )
        XCTAssertTrue(wrong.contains("do not name"), "a module the spec does not name is refused: \(wrong)")
        let unpaid = try await runCtl(
            create + moduleFiles.flatMap { ["--policy-module", $0.path] }, root: host.root, expectFailure: true
        )
        XCTAssertTrue(unpaid.contains("--premine-to"), "a premine needs an account to go to: \(unpaid)")
        // The creator's own claim rides in the genesis; one whose signature
        // is not its signer's is refused before the chain is created.
        let creator = CryptoUtils.generateKeyPair()
        let claim = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [Action(key: "name/alpha", oldValue: nil, newValue: CryptoUtils.createAddress(from: creator.publicKey))],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: creator.publicKey)], nonce: 0, chainPath: ["Nexus", "Alpha"]
        ))
        func genesisFile(_ name: String, signedBy key: (privateKey: String, publicKey: String)) throws -> URL {
            let file = scratch.appendingPathComponent(name)
            let signature = try XCTUnwrap(TransactionSigning.sign(bodyHeader: claim, privateKeyHex: key.privateKey))
            try JSONEncoder().encode([SubmitTransactionRequest(
                transaction: Transaction(signatures: [key.publicKey: signature], body: claim)
            )]).write(to: file)
            return file
        }
        let forged = try await runCtl(
            create + moduleFiles.flatMap { ["--policy-module", $0.path] } + ["--premine-to", recipient.address]
                + ["--genesis-transactions", try genesisFile("forged.json", signedBy: CryptoUtils.generateKeyPair()).path],
            root: host.root, expectFailure: true
        )
        XCTAssertTrue(forged.contains("not signed by exactly its signers"), "a forged genesis transaction is refused: \(forged)")
        _ = try await runCtl(
            create + moduleFiles.flatMap { ["--policy-module", $0.path] } + ["--premine-to", recipient.address]
                + ["--genesis-transactions", try genesisFile("genesis.json", signedBy: creator).path],
            root: host.root
        )

        try setRecipient(host.root, alpha, miner.address)
        _ = try await runCtl(["mine", "start"], root: host.root)
        try await waitFor("Alpha mined by merged mining", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) >= 2
        }
        try await waitFor("the Alpha miner is funded", seconds: 180) {
            await self.balance(host, miner.address, chain: alpha) >= 10
        }
        // The genesis paid the premine, 3 blocks of 100, to the named account.
        try await waitFor("the premine is paid", seconds: 60) {
            await self.balance(host, recipient.address, chain: alpha) == 300
        }
        try await submitUntilAccepted("Alpha accepts the transfer", host, [
            "send", "--chain", alpha, "--key", miner.file.path,
            "--to", recipient.address, "--amount", "10",
        ])
        try await waitFor("the Alpha transfer is mined", seconds: 240) {
            await self.balance(host, recipient.address, chain: alpha) == 310
        }
    }

    /// Read with the node's loopback cookie, as every operator client must.
    private func balance(_ host: CtlHost, _ address: String, chain: String = "Nexus") async -> UInt64 {
        guard let url = URL(
            string: "http://127.0.0.1:\(host.nexusRPC)/api/state/account/\(address)" + Self.query(chain)
        ) else { return 0 }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let cookie = try? String(contentsOf: HostLayout(root: host.root.path).rpcCookie, encoding: .utf8) else {
            return 0
        }
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(
            for: request
        ), (response as? HTTPURLResponse)?.statusCode == 200,
           let object = try? JSONSerialization.jsonObject(with: data)
               as? [String: Any] else { return 0 }
        return (object["balance"] as? String).flatMap { UInt64($0) } ?? 0
    }
}

// MARK: serving standing

/// A peer's serving standing between real nodes: credited on the operator
/// route, kept across the holder being killed and restarted, and lowered by
/// the archive bytes of every Volume served to the peer, down to zero, where
/// the peer is still served. Only amounts are asserted, never order or
/// timing; Ivy's own tests cover the weighting.
extension LatticeCtlE2ETests {
    private static func operatorRequest(_ host: CtlHost, _ path: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(host.nexusRPC)/\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let cookie = try String(contentsOf: HostLayout(root: host.root.path).rpcCookie, encoding: .utf8)
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }

    /// The node's Ivy peer key, as it prints it on its `storage:` line.
    private func peerKey(_ host: CtlHost) throws -> String {
        let identity = HostLayout(root: host.root.path).identityKey(for: "Nexus")
        let privateKey = try String(contentsOf: identity, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: host.root, privateKeyHex: privateKey
        ).processPublicKey
    }

    private struct ServingCredit: Codable {
        var peer: String
        var standing: Int?
        var bytes: Int?
    }

    private func standing(_ host: CtlHost, _ peer: String) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(for: try Self.operatorRequest(host, "serving-credit/\(peer)"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(try JSONDecoder().decode(ServingCredit.self, from: data).standing)
    }

    /// `count` Volumes, distinct by `tag` and an index: one archive size for
    /// every tag of one length.
    private static func servedVolumes(_ count: Int, tag: String) async throws -> [SerializedVolume] {
        actor Captured: VolumeStorer {
            var volumes: [SerializedVolume] = []
            func store(volume: SerializedVolume) async throws { volumes.append(volume) }
        }
        var volumes: [SerializedVolume] = []
        for index in 0..<count {
            let body = TransactionBody(
                accountActions: [],
                actions: [Action(
                    key: "\(tag)-\(String(format: "%04d", index))", oldValue: nil,
                    newValue: String(repeating: "x", count: 512 * 1024)
                )],
                depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [], nonce: 0, chainPath: ["Nexus"]
            )
            let volume = try VolumeImpl<TransactionBody>(node: body)
            let captured = Captured()
            try await volume.store(storer: captured)
            let stored = await captured.volumes.first { $0.root == volume.rawCID }
            volumes.append(try XCTUnwrap(stored))
        }
        return volumes
    }

    /// Never timed out here: a retry sent while the reader still reads the
    /// first would be served, and charged, twice.
    private static let fetchSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 3_600
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration)
    }()

    /// `GET /fetch/:cid` on the reader, which reads it from its one peer.
    private static func fetch(_ reader: CtlHost, _ cid: String) async -> Int {
        guard let request = try? Self.operatorRequest(reader, "fetch/\(cid)"),
              let (_, response) = try? await fetchSession.data(for: request) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testAStandingSurvivesARestartAndIsLoweredByWhatIsServed() async throws {
        // Nothing is mined, so once the reader holds the holder's genesis it
        // fetches from the holder only what is asked of it here.
        let holder = try await bringUpMiningHost(miner: nil)
        let listen = try Topology.load(root: holder.root).listen
        let holderKey = try peerKey(holder)
        let reader = try await bringUpMiningHost(miner: nil) {
            $0.peers = ChainPeers(byChain: ["Nexus": ["\(holderKey)@127.0.0.1:\(listen)"]])
        }
        let peer = try peerKey(reader)

        let volumes = try await Self.servedVolumes(3, tag: "served")
        let sizes = Set(volumes.map { encodeCompleteVolumeArchive($0)?.count ?? 0 })
        XCTAssertEqual(sizes.count, 1, "every Volume archives to the same size")
        let archiveBytes = try XCTUnwrap(sizes.first)
        struct Pin: Encodable { let cid: String; let entries: [String: Data] }
        for volume in volumes {
            var pin = try Self.operatorRequest(holder, "pins")
            pin.httpMethod = "POST"
            pin.setValue("application/json", forHTTPHeaderField: "Content-Type")
            pin.httpBody = try JSONEncoder().encode(Pin(cid: volume.root, entries: volume.entries))
            let (data, response) = try await URLSession.shared.data(for: pin)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        }

        // MARK: credited on the operator route
        let funded = archiveBytes + archiveBytes / 2
        var credit = try Self.operatorRequest(holder, "serving-credit")
        credit.httpMethod = "POST"
        credit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        credit.httpBody = try JSONEncoder().encode(ServingCredit(peer: peer, bytes: funded))
        let (credited, creditResponse) = try await URLSession.shared.data(for: credit)
        XCTAssertEqual((creditResponse as? HTTPURLResponse)?.statusCode, 200, String(decoding: credited, as: UTF8.self))
        XCTAssertEqual(try JSONDecoder().decode(ServingCredit.self, from: credited).standing, funded)

        // MARK: killed and restarted on the same data directory
        let pid = try XCTUnwrap(holder.supervisor.pid)
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        try await waitFor("the holder is gone") {
            let answering = await self.health(holder.nexusRPC) != nil
            return !holder.supervisor.isRunning && !answering
        }
        try holder.supervisor.start()
        try await waitFor("the holder is active again") {
            await self.health(holder.nexusRPC)?["phase"] as? String == "active"
        }
        let restored = try await standing(holder, peer)
        XCTAssertEqual(restored, funded, "the credit survives a kill")

        // MARK: lowered by the archive bytes served
        // Connected again, asked without fetching: a fetch retried after a
        // failed one would be charged for whatever the failed one was sent.
        try await waitFor("the reader holds a session with the holder", seconds: 120) {
            guard let request = try? Self.operatorRequest(reader, "api/peers"),
                  let (data, _) = try? await URLSession.shared.data(for: request),
                  let peers = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return (peers["count"] as? Int ?? 0) > 0
        }
        let first = await Self.fetch(reader, volumes[0].root)
        XCTAssertEqual(first, 200)
        let afterFirst = try await standing(holder, peer)
        XCTAssertEqual(afterFirst, funded - archiveBytes, "one archive served")

        // Lowered to zero, never below.
        let second = await Self.fetch(reader, volumes[1].root)
        XCTAssertEqual(second, 200)
        let afterSecond = try await standing(holder, peer)
        XCTAssertEqual(afterSecond, 0, "standing stops at zero")

        // MARK: a peer with no standing is still served
        let third = await Self.fetch(reader, volumes[2].root)
        XCTAssertEqual(third, 200)
        let afterThird = try await standing(holder, peer)
        XCTAssertEqual(afterThird, 0)
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

/// A node operated from elsewhere: everything through `lattice --node
/// --token-file` against its operator listener, nothing on its disk.
extension LatticeCtlE2ETests {
    private func runRemote(
        _ arguments: [String], _ url: String, _ tokenFile: URL, expectFailure: Bool = false,
        lattice: URL? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = try lattice ?? binary("E2E_CTL_BIN", "lattice")
        process.arguments = arguments + ["--node", url, "--token-file", tokenFile.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if !expectFailure, process.terminationStatus != 0 {
            throw CtlE2EError("lattice \(arguments.joined(separator: " ")) (remote) failed: \(output)")
        }
        if expectFailure, process.terminationStatus == 0 {
            throw CtlE2EError("lattice \(arguments.joined(separator: " ")) (remote) succeeded: \(output)")
        }
        return output
    }

    /// SIGTERM is a stop (0); a configuration that does not check is 78,
    /// with the reason in what the process manager collects.
    func testTheExitStatusTellsTheProcessManagerWhatNext() async throws {
        let host = try await bringUpMiningHost(miner: nil)
        host.supervisor.stop()
        try await waitFor("the stop is recorded") { host.supervisor.exits.count == 1 }
        XCTAssertEqual(host.supervisor.exits.last, 0, "SIGTERM is a stop")
        try Data("{not json".utf8).write(to: host.root.appendingPathComponent(Topology.fileName))
        try host.supervisor.start()
        try await waitFor("the node exits") { host.supervisor.exits.count == 2 }
        XCTAssertEqual(host.supervisor.exits.last, 78, "a broken lattice.json is a configuration error")
        let collected = try String(contentsOf: host.root.appendingPathComponent("log/lattice-node.log"), encoding: .utf8)
        XCTAssertTrue(collected.contains(Topology.fileName), collected)
    }

    /// A changed `rpc` waits for a restart; until then the CLI reaches the
    /// node where it listens, and after it, where it moved.
    func testTheCLIFollowsTheNodeToANewRPCPort() async throws {
        let host = try await bringUpMiningHost(miner: nil)
        let moved = randomPorts(1)[0]
        let set = try await runCtl(["config", "set", "rpc=\(moved)"], root: host.root)
        XCTAssertTrue(set.contains("waiting for a restart"), set)
        let before = try await runCtl(["status"], root: host.root)
        XCTAssertTrue(before.contains("Nexus: active"), before)
        XCTAssertTrue(before.contains("waiting for a restart: rpc"), before)
        _ = try await runCtl(["restart"], root: host.root)
        XCTAssertEqual(host.supervisor.exits.last, 75, "a restart is an exit its process manager starts again")
        let after = try await runCtl(["status"], root: host.root)
        XCTAssertTrue(after.contains("Nexus: "), after)
        XCTAssertFalse(after.contains("waiting for a restart"), after)
        let onMoved = await health(moved)
        XCTAssertNotNil(onMoved, "the node listens on the new port")
        let onOld = await health(host.nexusRPC)
        XCTAssertNil(onOld, "and no longer on the old one")
    }

    /// A restart or stop asked through the API ends the node with its exit
    /// status, not a trap, while a response streams and connections keep
    /// arriving: its listeners shut down gracefully, serving and closing
    /// every connection they accepted.
    func testARestartOrStopUnderOpenConnectionsExitsCleanly() async throws {
        let host = try await bringUpMiningHost(miner: nil)
        let node = "http://127.0.0.1:\(host.nexusRPC)"
        let cookie = HostLayout(root: host.root.path).rpcCookie
        for (route, expected) in [("restart", Int32(75)), ("stop", 0)] {
            let before = host.supervisor.exits.count
            var stream = URLRequest(url: URL(string: "\(node)/mining/events")!)
            stream.setValue(
                "Basic " + Data(try String(contentsOf: cookie, encoding: .utf8).utf8).base64EncodedString(),
                forHTTPHeaderField: "Authorization"
            )
            let events = URLSession.shared.dataTask(with: stream)
            events.resume()
            // New connections throughout, each closed after its answer. Ended
            // by a flag, never by cancelling a task mid-request: on Linux,
            // cancelling an in-flight `URLSession.data(for:)` can deadlock
            // against the session completing it.
            let arrive = Arrivals()
            let arriving = (0..<8).map { _ in
                Task {
                    var probe = URLRequest(url: URL(string: "\(node)/health")!)
                    probe.setValue("close", forHTTPHeaderField: "Connection")
                    probe.cachePolicy = .reloadIgnoringLocalCacheData
                    probe.timeoutInterval = 5
                    while await arrive.going {
                        _ = try? await URLSession.shared.data(for: probe)
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            try await Task.sleep(for: .seconds(1))
            let (status, _) = try await postJSON("\(node)/\(route)", [String: String](), cookie: cookie)
            XCTAssertEqual(status, 202, route)
            try await waitFor("the node exits after /\(route)") { host.supervisor.exits.count > before }
            await arrive.stop()
            for probe in arriving { await probe.value }
            events.cancel()
            let log = try String(contentsOf: host.root.appendingPathComponent("log/lattice-node.log"), encoding: .utf8)
            XCTAssertEqual(host.supervisor.exits[before], expected, "/\(route): \(log.suffix(2_000))")
            XCTAssertFalse(log.contains("Fatal error"), log)
            if route == "restart" {
                try await waitFor("Nexus active after the restart") {
                    await self.health(host.nexusRPC)?["phase"] as? String == "active"
                }
            }
        }
    }

    /// A client that stalls mid-request holds a restart's drain only up to
    /// its cap: the node still exits 75, without a trap.
    func testARestartIsNotHeldOpenByAStalledClient() async throws {
        let host = try await bringUpMiningHost(miner: nil)
        let cookieFile = HostLayout(root: host.root.path).rpcCookie
        let authorization = "Basic " + Data(try String(contentsOf: cookieFile, encoding: .utf8).utf8).base64EncodedString()
        // A request whose body never finishes: read, so the drain waits on it.
        let stalled = try sendRaw(port: host.nexusRPC, """
            POST /transactions HTTP/1.1\r
            Host: 127.0.0.1\r
            Authorization: \(authorization)\r
            Content-Type: application/json\r
            Content-Length: 1000\r
            \r
            {"tra
            """)
        defer { close(stalled) }
        try await Task.sleep(for: .seconds(1))
        let before = host.supervisor.exits.count
        let asked = ContinuousClock.now
        let (status, _) = try await postJSON("http://127.0.0.1:\(host.nexusRPC)/restart", [String: String](), cookie: cookieFile)
        XCTAssertEqual(status, 202)
        try await waitFor("the node exits", seconds: 90) { host.supervisor.exits.count > before }
        let took = ContinuousClock.now - asked
        let log = try String(contentsOf: host.root.appendingPathComponent("log/lattice-node.log"), encoding: .utf8)
        XCTAssertEqual(host.supervisor.exits[before], 75, String(log.suffix(2_000)))
        XCTAssertFalse(log.contains("Fatal error"), log)
        XCTAssertGreaterThan(took, .seconds(25), "the stalled request held the drain until the cap")
        XCTAssertLessThan(took, .seconds(60), "and no longer")
        try await waitFor("Nexus active after the restart") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
    }

    /// A loopback connection to `port` that has sent `text` and is left open.
    private func sendRaw(port: UInt16, _ text: String) throws -> Int32 {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw CtlE2EError("socket: \(errno)") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let bytes = Array(text.utf8)
        guard connected == 0, write(descriptor, bytes, bytes.count) == bytes.count else {
            close(descriptor)
            throw CtlE2EError("could not send to port \(port): \(errno)")
        }
        return descriptor
    }

    func testANodeIsOperatedRemotelyThroughItsOperatorListener() async throws {
        let alpha = "Nexus/Alpha"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try await makeKey(scratch, "first")
        let second = try await makeKey(scratch, "second")
        let operatorPort = randomPorts(1)[0]
        let host = try await bringUpMiningHost(miner: nil) {
            $0.operatorListen = "127.0.0.1:\(operatorPort)"
            $0.operatorTokens = "operator-tokens.json"
        }
        let url = "http://127.0.0.1:\(operatorPort)"
        // The first admin token is made beside the node, with its cookie.
        let adminFile = scratch.appendingPathComponent("admin.token")
        _ = try await runCtl(["tokens", "create", "ops", "--role", "admin", "--out", adminFile.path], root: host.root)
        let remote = { (arguments: [String]) in try await self.runRemote(arguments, url, adminFile) }

        let status = try await remote(["status"])
        XCTAssertTrue(status.contains("Nexus: active"), status)

        // A chain created remotely, mined by a separate miner process with
        // its own settings and a token for the mining routes alone, its
        // recipient changed in the miner's own file.
        _ = try await remote(["child", "create", alpha, "--block-time", "1000", "--reward", "100"])
        let minerToken = scratch.appendingPathComponent("miner.token")
        _ = try await remote([
            "tokens", "create", "miner", "--out", minerToken.path,
            "--route", "GET /status", "--route", "POST /mining/templates", "--route", "POST /mining/work",
        ])
        let minerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-node-e2e-miner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: minerRoot, withIntermediateDirectories: true)
        minerRoots.append(minerRoot)
        try writeMinerConfig(minerRoot, recipients: [alpha: first.address])
        // A miner-only host: lattice and the mining binaries, no lattice-node.
        let minerBin = minerRoot.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: minerBin, withIntermediateDirectories: true)
        let lattice = try binary("E2E_CTL_BIN", "lattice")
        for name in ["lattice", "lattice-mining-coordinator", "lattice-miner"] {
            try FileManager.default.copyItem(
                at: lattice.deletingLastPathComponent().appendingPathComponent(name),
                to: minerBin.appendingPathComponent(name)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: minerBin.appendingPathComponent("lattice-node").path))
        _ = try await runRemote(
            ["mine", "start", "--root", minerRoot.path], url, minerToken,
            lattice: minerBin.appendingPathComponent("lattice")
        )
        try await waitFor("Alpha mined", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) >= 2
        }
        try await waitFor("the first recipient is paid", seconds: 180) {
            await self.balance(host, first.address, chain: alpha) > 0
        }
        try setRecipient(minerRoot, alpha, second.address)
        try await waitFor("the changed recipient is paid", seconds: 240) {
            await self.balance(host, second.address, chain: alpha) > 0
        }
        let mining = try await runRemote(["mine", "status", "--root", minerRoot.path], url, minerToken)
        XCTAssertTrue(mining.contains("mining: running"), mining)
        // The miner's token reaches nothing but mining.
        let unscoped = try await runRemote(["config", "get"], url, minerToken, expectFailure: true)
        XCTAssertTrue(unscoped.contains("403"), unscoped)

        // A key that takes a restart waits for one; the restart keeps all.
        let set = try await remote(["config", "set", "announceLifetime=900"])
        XCTAssertTrue(set.contains("announceLifetime"), set)
        let before = await height(host.nexusRPC, chain: alpha)
        _ = try await remote(["restart"])
        XCTAssertEqual(host.supervisor.exits.last, 75, "a restart is an exit its process manager starts again")
        let collected = try String(contentsOf: host.root.appendingPathComponent("log/lattice-node.log"), encoding: .utf8)
        XCTAssertTrue(collected.contains("stopped to restart (exit 75)"), "the last line reaches the process manager")
        let config = try await remote(["config", "get"])
        XCTAssertTrue(config.contains(alpha) && config.contains("900"), config)
        XCTAssertFalse(config.contains("\"mine\""), "the node keeps no mining settings: \(config)")
        let restarted = try await remote(["status"])
        XCTAssertFalse(restarted.contains("waiting for a restart"), restarted)
        try await waitFor("Alpha advances after the restart", seconds: 180) {
            await self.height(host.nexusRPC, chain: alpha) > before
        }
        // The log is the restarted process's output, from its memory.
        let logs = try await remote(["logs", "--tail", "50"])
        XCTAssertTrue(logs.contains("lattice-node (node runtime)"), logs)
        XCTAssertFalse(logs.contains("stopped to restart"), "the earlier process's output is not this one's: \(logs)")

        // Tokens: a read token reads and changes nothing; revoked, it is refused.
        let readFile = scratch.appendingPathComponent("read.token")
        _ = try await remote(["tokens", "create", "viewer", "--role", "read", "--out", readFile.path])
        _ = try await runRemote(["status"], url, readFile)
        let refused = try await runRemote(["config", "set", "minRelayFee=1"], url, readFile, expectFailure: true)
        XCTAssertTrue(refused.contains("403"), refused)
        _ = try await remote(["tokens", "revoke", "viewer"])
        let revoked = try await runRemote(["status"], url, readFile, expectFailure: true)
        XCTAssertTrue(revoked.contains("401"), revoked)

        // A wipe: storage goes, configuration and identity stay.
        _ = try await runCtl(["mine", "stop"], root: minerRoot)
        let height = await self.height(host.nexusRPC, chain: "Nexus")
        _ = try await remote(["wipe"])
        XCTAssertEqual(host.supervisor.exits.suffix(2), [75, 75], "a wipe restarts the node")
        let after = await self.height(host.nexusRPC, chain: "Nexus")
        XCTAssertLessThan(after, height, "Nexus starts again from genesis")
        let hosted = try await remote(["config", "get", "hostedChains"])
        XCTAssertTrue(hosted.contains(alpha), hosted)

        // Stopped remotely, it stays stopped.
        _ = try await remote(["down"])
        try await waitFor("the node exits") { !host.supervisor.isRunning }
        XCTAssertEqual(host.supervisor.exits.last, 0)
    }
}

/// What runs a node in these tests, as a process manager would: `lattice up`
/// in the foreground, started again when it exits 75 (a restart asked for),
/// left stopped on any other exit. Its output goes to <root>/log.
private final class NodeSupervisor: @unchecked Sendable {
    private let lattice: URL
    private let root: URL
    private let lock = NSLock()
    private var process: Process?
    private var stopping = false
    private var exitStatuses: [Int32] = []
    /// Cleared where the exit is recorded, so `exits` is current once it reads false
    /// (Process.isRunning turns false before the termination handler runs).
    private var live = false

    init(lattice: URL, root: URL) {
        self.lattice = lattice
        self.root = root
    }

    /// Every exit so far, in order.
    var exits: [Int32] { lock.withLock { exitStatuses } }
    var pid: Int32? { lock.withLock { process.map(\.processIdentifier) } }
    var isRunning: Bool { lock.withLock { live } }

    func start() throws {
        try lock.withLock {
            stopping = false
            try launch()
        }
    }

    /// Stops the node (SIGTERM) and waits for it; it is not started again.
    /// One still running past its shutdown cap (30 s) and a margin is
    /// killed, so a hung stop fails its test instead of the whole run.
    func stop() {
        let running = lock.withLock { () -> Process? in
            stopping = true
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
        let deadline = Date().addingTimeInterval(60)
        while running.isRunning, Date() < deadline { usleep(100_000) }
        if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        running.waitUntilExit()
    }

    /// Called with the lock held.
    private func launch() throws {
        let log = root.appendingPathComponent("log/lattice-node.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: log)
        output.seekToEndOfFile()
        let process = Process()
        process.executableURL = lattice
        process.arguments = ["up", "--root", root.path]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] ended in
            try? output.close()
            self?.exited(ended)
        }
        try process.run()
        self.process = process
        live = true
    }

    private func exited(_ ended: Process) {
        lock.withLock {
            exitStatuses.append(ended.terminationReason == .exit ? ended.terminationStatus : -ended.terminationStatus)
            if ended === process { live = false }
            guard ended === process, !stopping, ended.terminationReason == .exit, ended.terminationStatus == 75 else { return }
            try? launch()
        }
    }
}

/// Whether the test's arriving connections keep coming.
private actor Arrivals {
    private(set) var going = true
    func stop() { going = false }
}
