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
    private func bringUpMiningHost(
        miner: TestKey?, minRelayFee: UInt64? = nil, configure: (inout Topology) -> Void = { _ in }
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
        topology.mine = TopologyMine(
            worker: "cpu", workers: 1, batchSize: 100_000,
            recipients: miner.map { ["Nexus": $0.address] }
        )
        topology.minRelayFee = minRelayFee
        configure(&topology)
        try topology.validated().save(root: root)

        _ = try await runCtl(["up"], root: root)
        let host = CtlHost(root: root, nexusRPC: ports[1])
        hosts.append(host)
        try await waitFor("Nexus active") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
        return host
    }

    /// The descriptors `pid` holds open, or nil where this cannot be read.
    private func openDescriptors(_ pid: Int32) -> Int? {
        try? FileManager.default
            .contentsOfDirectory(atPath: "/proc/\(pid)/fd").count
    }

    /// `up --foreground` is a container's PID 1: it checks on the node every
    /// second for as long as the node runs. A descriptor kept from each check
    /// reaches the process's limit within hours, after which the supervisor
    /// can read nothing, takes the node for dead and exits.
    func testTheForegroundSupervisorHoldsNoMoreDescriptorsAsItWatches() async throws {
        let host = try await bringUpMiningHost(miner: nil)
        let supervisor = Process()
        supervisor.executableURL = try binary("E2E_CTL_BIN", "lattice")
        supervisor.arguments = ["up", "--foreground", "--root", host.root.path]
        supervisor.standardOutput = FileHandle.nullDevice
        supervisor.standardError = FileHandle.nullDevice
        try supervisor.run()
        defer {
            supervisor.terminate()
            supervisor.waitUntilExit()
        }
        try XCTSkipIf(
            openDescriptors(ProcessInfo.processInfo.processIdentifier) == nil,
            "no /proc here to count another process's descriptors"
        )
        // Past start-up, where descriptors are still being opened.
        try await Task.sleep(for: .seconds(5))
        let before = try XCTUnwrap(openDescriptors(supervisor.processIdentifier))
        try await Task.sleep(for: .seconds(15))
        XCTAssertTrue(supervisor.isRunning, "the supervisor is still watching")
        let after = try XCTUnwrap(openDescriptors(supervisor.processIdentifier))
        XCTAssertLessThanOrEqual(
            after, before + 3,
            "fifteen checks on the node left \(after - before) more descriptors open"
        )
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
        // The operator port refuses a client without the cookie; the CLI and
        // its coordinator below carry it.
        var bare = URLRequest(url: URL(string: "http://127.0.0.1:\(host.nexusRPC)/status")!)
        bare.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, refused) = try await URLSession.shared.data(for: bare)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
        _ = try await runCtl(["mine", "start"], root: host.root)
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
        var topology = try Topology.load(root: host.root)
        topology.mine?.recipients = [alpha: sponsorKey.address]
        try topology.validated().save(root: host.root)
        try await waitFor("Nexus active after the restart") {
            await self.health(host.nexusRPC)?["phase"] as? String == "active"
        }
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
        _ = try await runCtl(["down"], root: host.root)
        _ = try await runCtl(["up"], root: host.root)
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

// MARK: paid serving

/// A peer's serving balance between real nodes: credited on the operator
/// route, kept across the holder being killed and restarted, and spent only
/// by fetches that waited for the holder's one serving slot. Only spending is
/// asserted, never completion order or timing; Ivy's own tests cover the
/// weighting.
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

    private struct ServingBalance: Codable {
        var peer: String
        var balance: Int?
        var bytes: Int?
    }

    private func servingBalance(_ host: CtlHost, _ peer: String) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(for: try Self.operatorRequest(host, "serving-balance/\(peer)"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(try JSONDecoder().decode(ServingBalance.self, from: data).balance)
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

    /// Enough connections for a whole burst at once: `URLSession.shared`
    /// holds a host to a few, which would queue the burst here instead of
    /// at the holder. Never timed out here: a retry sent while the reader
    /// still reads the first would contend with it.
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

    /// Gone, or a zombie nobody reaps: a CI container's PID 1 never reaps an
    /// adopted orphan, and a zombie still answers kill(pid, 0).
    private static func isGone(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return true }
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return false }
        return stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
    }

    func testAServingBalanceSurvivesARestartAndIsSpentOnlyByFetchesThatWaited() async throws {
        // One serving slot: any two requests at once contend. Nothing is
        // mined, so once the reader holds the holder's genesis no sync
        // request takes the slot.
        let holder = try await bringUpMiningHost(miner: nil) { $0.servingMaxConcurrent = 1 }
        let listen = try Topology.load(root: holder.root).listen
        let holderKey = try peerKey(holder)
        let reader = try await bringUpMiningHost(miner: nil) {
            $0.peers = ChainPeers(byChain: ["Nexus": ["\(holderKey)@127.0.0.1:\(listen)"]])
        }
        let peer = try peerKey(reader)

        // MARK: credited on the operator route
        let funded = 1 << 30
        var credit = try Self.operatorRequest(holder, "serving-balance")
        credit.httpMethod = "POST"
        credit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        credit.httpBody = try JSONEncoder().encode(ServingBalance(peer: peer, bytes: funded))
        let (credited, creditResponse) = try await URLSession.shared.data(for: credit)
        XCTAssertEqual((creditResponse as? HTTPURLResponse)?.statusCode, 200, String(decoding: credited, as: UTF8.self))
        XCTAssertEqual(try JSONDecoder().decode(ServingBalance.self, from: credited).balance, funded)

        // MARK: killed and restarted on the same data directory
        let layout = HostLayout(root: holder.root.path)
        let pidText = try String(contentsOf: layout.pidFile(for: "lattice-node"), encoding: .utf8)
        let pid = try XCTUnwrap(pidText.split(separator: " ").first.flatMap { Int32($0) })
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        try await waitFor("the holder is gone") {
            let answering = await self.health(holder.nexusRPC) != nil
            return Self.isGone(pid) && !answering
        }
        // What a crash leaves: a pidfile naming a dead process.
        layout.removePidFile(for: "lattice-node", ifNaming: pid)
        _ = try await runCtl(["up"], root: holder.root)
        try await waitFor("the holder is active again") {
            await self.health(holder.nexusRPC)?["phase"] as? String == "active"
        }
        let restored = try await servingBalance(holder, peer)
        XCTAssertEqual(restored, funded, "the credit survives a kill")

        // MARK: spent only by fetches that waited
        let lone = try await Self.servedVolumes(1, tag: "alone")
        let bursts = try await Self.servedVolumes(36, tag: "burst")
        let sizes = Set((lone + bursts).map { encodeCompleteVolumeArchive($0)?.count ?? 0 })
        XCTAssertEqual(sizes.count, 1, "every Volume archives to the same size")
        let archiveBytes = try XCTUnwrap(sizes.first)
        struct Pin: Encodable { let cid: String; let entries: [String: Data] }
        for volume in lone + bursts {
            var pin = try Self.operatorRequest(holder, "pins")
            pin.httpMethod = "POST"
            pin.setValue("application/json", forHTTPHeaderField: "Content-Type")
            pin.httpBody = try JSONEncoder().encode(Pin(cid: volume.root, entries: volume.entries))
            let (data, response) = try await URLSession.shared.data(for: pin)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        }

        // Alone, a fetch gets the free slot at once and is never charged.
        try await waitFor("the reader reads from the holder", seconds: 120) {
            await Self.fetch(reader, lone[0].root) == 200
        }
        let afterLone = try await servingBalance(holder, peer)
        XCTAssertEqual(afterLone, funded, "a fetch served at once is free")

        // A burst at once: with one slot, every request but those that found
        // it free waits, and what is served to those is spent. Whether a
        // given burst overlaps at the holder is the runner's timing, so
        // bursts of fresh Volumes repeat until one does.
        var balance = afterLone
        for burst in stride(from: 0, to: bursts.count, by: 12) {
            let roots = bursts[burst..<(burst + 12)].map(\.root)
            let statuses = await withTaskGroup(of: Int.self) { group in
                for root in roots { group.addTask { await Self.fetch(reader, root) } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            XCTAssertEqual(statuses, Array(repeating: 200, count: roots.count))
            let after = try await servingBalance(holder, peer)
            let spent = balance - after
            XCTAssertGreaterThanOrEqual(spent, 0)
            XCTAssertEqual(spent % archiveBytes, 0, "spent by whole archives served: \(spent) of \(archiveBytes)")
            XCTAssertLessThanOrEqual(spent, roots.count * archiveBytes, "never more than was served")
            balance = after
            if spent > 0 { break }
        }
        XCTAssertLessThan(balance, afterLone, "fetches that waited spend the balance")
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
