import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
@testable import LatticeNodeCore
import LatticeNodeAPI
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon
import cashew

/// Submits and peer transactions while a node executes another node's blocks,
/// through the real worker pool (`NodeRuntime.start`): a submit's verdict is
/// applied whatever tip it was read on, and a level not yet synced ignores
/// peers' transactions.
final class AdmissionWhileSyncingTests: XCTestCase {
    /// What the worker pool ran, seen by `NodeRuntime.start`'s `observeJob`.
    private actor Probe {
        var runtime: NodeRuntime?
        private var counts: [String: Int] = [:]

        func attach(_ runtime: NodeRuntime) { self.runtime = runtime }
        func count(_ name: String) { counts[name, default: 0] += 1 }
        func value(_ name: String) -> Int { counts[name, default: 0] }

        /// The node's root level, read on its loop.
        func level<T: Sendable>(_ read: @escaping @Sendable (ChainCore) -> T) async -> T? {
            guard let runtime else { return nil }
            return await LiveLevels(inputs: runtime.inputs).read { $0[["Nexus"]].map(read) }.flatMap { $0 }
        }
    }

    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
    }

    private func node(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        workers: Int = 2,
        bodyWindow: Int = 64,
        observe: NodeRuntime.JobObserver? = nil
    ) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let runtime = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                bootstrapPeers: peers,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ),
            coreConfig: ChainCoreConfig(bodyWindow: bodyWindow),
            workers: workers,
            observeJob: observe
        )
        addTeardownBlock { await runtime.stop() }
        return Node(runtime: runtime, endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    private static func transaction() throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    /// Waits, polling, until `condition` holds or about a minute passes.
    private static func until(_ condition: () async -> Bool) async {
        for _ in 0..<(6_000 * testTimeScale) {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A submit while the node executes a peer's blocks, its check slowed
    /// until the tip has moved past the tip it reads: answered once,
    /// admitted (never a 503), with at most two preflights (its admission
    /// and one recheck), and pooled on the final tip. With one worker the
    /// last connect is held until the submit waits, so its verdict is one
    /// move stale; with two, every move lands while its check runs.
    func testASubmitWhileConnectsMoveTheTipIsAdmittedOnce() async throws {
        let blocks: UInt64 = 5
        let miner = try await node(keyByte: 0x71)
        for _ in 0..<blocks { _ = try await miner.runtime.mineBlock() }
        let tx = try Self.transaction()
        let cid = try Mempool.cid(of: tx)

        for workers in [1, 2] {
            // The connect into the held height waits until the submit does.
            let held: UInt64 = workers == 1 ? blocks - 1 : 0
            let probe = Probe()
            let syncing = try await node(keyByte: 0x72 + UInt8(workers), peers: [miner.endpoint], workers: workers) { kind, effect in
                switch (kind, effect) {
                case (.connect, _):
                    await probe.count("connect")
                    if await probe.runtime?.published.value?.actOnHeight == held {
                        await Self.until { await probe.level { $0.mining.isPending(cid) } == true }
                    }
                case (_, .preflight(let preflight)?) where preflight.cid == cid:
                    await probe.count(preflight.checksPolicies ? "admission" : "recheck")
                    // With a second worker, the check outlasts every move.
                    if preflight.checksPolicies, workers > 1 {
                        await Self.until { await probe.runtime?.published.value?.actOnHeight == blocks }
                    }
                default:
                    break
                }
            }
            await probe.attach(syncing.runtime)
            try await eventually("connects reach height \(held)", within: .seconds(60)) {
                (syncing.runtime.published.value?.actOnHeight ?? 0) >= held
                    && (syncing.runtime.published.value?.bestHeaderHeight ?? 0) == blocks
            }
            let spawnHeight = syncing.runtime.published.value?.actOnHeight
            let app = makeApplication(service: syncing.runtime, host: "127.0.0.1", port: 8080)
            try await app.test(.router) { client in
                let response = try await client.execute(
                    uri: "/transactions", method: .post,
                    headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
                    body: ByteBuffer(bytes: try JSONEncoder().encode(SubmitTransactionRequest(transaction: tx)))
                )
                XCTAssertEqual(response.status, .ok, "workers \(workers): \(String(buffer: response.body))")
                let answer = try JSONDecoder().decode(SubmitTransactionResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(answer.transactionCID, cid)
            }
            try await eventually("pooled on the final tip, its recheck done", within: .seconds(60)) {
                await probe.level {
                    $0.snapshot.actOnHeight == blocks && $0.mining.tipCID == $0.snapshot.actOnTip
                        && $0.mining.mempool.contains(cid) && $0.mining.outstandingPreflights == 0
                } == true
            }
            XCTAssertEqual(spawnHeight, held, "workers \(workers): submitted on height \(held)")
            let (admissions, rechecks) = (await probe.value("admission"), await probe.value("recheck"))
            XCTAssertEqual(admissions, 1, "workers \(workers)")
            XCTAssertEqual(rechecks, 1, "workers \(workers): the stale verdict's one recheck")
            XCTAssertLessThanOrEqual(admissions + rechecks, 2)
            await syncing.runtime.stop()
        }
    }

    /// One worker, catching up from a peer that keeps announcing
    /// transactions: no peer admission runs before the level's sync latch is
    /// set (`ChainCore.synced`), which it is once caught up; its connects are those of a quiet sync, and once
    /// caught up it pools a peer's transaction. A miner polling for
    /// templates meanwhile is served on the old tip (Bitcoin Core refuses
    /// `getblocktemplate` during initial block download); the builds it
    /// costs are printed.
    func testACatchingUpNodeIgnoresPeerTransactionsWithoutSlowingItsConnects() async throws {
        let window = 4
        let blocks = UInt64(3 * window + 4)
        let source = try await node(keyByte: 0x81, bodyWindow: window)
        for _ in 0..<blocks { _ = try await source.runtime.mineBlock() }

        func resync(keyByte: UInt8, flood: Bool) async throws -> Probe {
            let probe = Probe()
            let synced = try await node(
                keyByte: keyByte, peers: [source.endpoint], workers: 1, bodyWindow: window
            ) { kind, effect in
                // Nil, the level unreadable (a job still running once the
                // loop has stopped), is not catching up.
                let catchingUp = await probe.level(\.synced) == false
                switch (kind, effect) {
                case (.connect, _):
                    await probe.count("connect")
                case (_, .buildTemplate?) where catchingUp:
                    await probe.count("template while catching up")
                case (_, .preflight(let preflight)?) where preflight.checksPolicies && !preflight.awaited:
                    await probe.count(catchingUp ? "peer admission while catching up" : "peer admission")
                default:
                    break
                }
            }
            await probe.attach(synced.runtime)
            let announcing = Task {
                while flood, !Task.isCancelled {
                    _ = try? await source.runtime.submitTransaction(SubmitTransactionRequest(transaction: try Self.transaction()))
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            let polling = Task {
                while flood, !Task.isCancelled {
                    _ = try? await synced.runtime.miningTemplate(MiningTemplateRequest())
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer {
                announcing.cancel()
                polling.cancel()
            }
            try await eventually("caught up to the source's tip", within: .seconds(120)) {
                synced.runtime.published.value?.actOnHeight == blocks
            }
            try await eventually("the sync latch is set", within: .seconds(60)) {
                await probe.level(\.synced) == true
            }
            if flood {
                try await eventually("a peer's transaction pooled once caught up", within: .seconds(60)) {
                    (synced.runtime.published.value?.mempoolCount ?? 0) > 0
                }
            }
            announcing.cancel()
            polling.cancel()
            await synced.runtime.stop()
            return probe
        }

        let quiet = try await resync(keyByte: 0x82, flood: false)
        let flooded = try await resync(keyByte: 0x83, flood: true)
        let quietConnects = await quiet.value("connect")
        let connects = await flooded.value("connect")
        let builds = await flooded.value("template while catching up")
        let early = await flooded.value("peer admission while catching up")
        let admitted = await flooded.value("peer admission")
        print(
            "catch-up: connects quiet \(quietConnects), flooded \(connects); "
                + "template builds while catching up \(builds); peer admissions after \(admitted)"
        )
        XCTAssertEqual(early, 0)
        XCTAssertGreaterThan(admitted, 0, "peer transactions are admitted once caught up")
        XCTAssertEqual(quietConnects, Int(blocks))
        XCTAssertEqual(connects, quietConnects, "the flood costs the sync no connect")
    }
}
