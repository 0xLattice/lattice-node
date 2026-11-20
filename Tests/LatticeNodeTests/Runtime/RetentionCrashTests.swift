import Foundation
import Ivy
import Lattice
import LatticeNodeAPI
import LatticeNodeCore
import Synchronization
import cashew
import XCTest
@testable import LatticeNode

/// A node keeping recent state and no bodies beyond its working set,
/// stopped by a crash at each retention write the loop makes after a step,
/// starts again over the same store: it follows its peer to the tip, its
/// counts match the store, it answers a read of the tip's state, and the
/// transaction it acknowledged before the crash is pooled or on the chain.
final class RetentionCrashTests: XCTestCase {
    /// Stops every retention write from the first at `boundary` once armed,
    /// as a process that died there would.
    private final class Crash: Sendable {
        let boundary: StateBackend.Boundary
        let state = Mutex<(armed: Bool, fired: Bool)>((false, false))

        init(at boundary: StateBackend.Boundary, armed: Bool) {
            self.boundary = boundary
            state.withLock { $0.armed = armed }
        }

        func arm() { state.withLock { $0.armed = true } }
        var fired: Bool { state.withLock { $0.fired } }

        func stops(_ boundary: StateBackend.Boundary) -> Bool {
            state.withLock { state in
                if !state.fired, state.armed, boundary == self.boundary { state.fired = true }
                return state.fired
            }
        }
    }

    private typealias Key = (privateKey: String, publicKey: String)

    private func address(_ key: Key) -> String { CryptoUtils.createAddress(from: key.publicKey) }

    private func node(
        keyByte: UInt8, directory: URL, peers: [PeerEndpoint], state: StateRetention, bodies: BlockBodies
    ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(), webSocket: .off,
            peerSearchInterval: 600, blockBodies: bodies, state: state,
            stateWindows: FinalityWindows(all: 2)
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
            requestTimeout: .seconds(5), stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
        )
        return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-crash-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func transaction(_ signer: Key, nonce: UInt64, paying payee: String) throws -> Transaction {
        let header = try HeaderImpl(node: TransactionBody(
            accountActions: [AccountAction(owner: address(signer), delta: -2), AccountAction(owner: payee, delta: 1)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address(signer)], nonce: nonce, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [signer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: signer.privateKey
            ))],
            body: header
        )
    }

    func testACrashAtEachRetentionWriteRecoversOnTheNextStart() async throws {
        // The first three happen as the node first syncs its counts; the
        // rest as it follows blocks after that.
        let early: Set<StateBackend.Boundary> = [.syncCounts, .commitCounts, .releaseStaging]
        // A heal needs counts naming a root the store lacks, which a
        // follower never reaches by itself (`StateWindowTests`).
        for boundary in StateBackend.Boundary.allCases where boundary != .healCounts {
            try await crashAndRecover(at: boundary, armedAtStart: early.contains(boundary))
        }
    }

    private func crashAndRecover(at boundary: StateBackend.Boundary, armedAtStart: Bool) async throws {
        let (payer, payee): (Key, Key) = (CryptoUtils.generateKeyPair(), CryptoUtils.generateKeyPair())
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: address(payer))])
        let producer = try node(keyByte: 0xc1, directory: directory(), peers: [], state: .all, bodies: .all)
        let producerStorage = try await NodeStorage.open(configuration: producer.0)
        let producerRuntime = try await NodeRuntime.start(
            storage: producerStorage, configuration: producer.0, overlay: producer.1
        )
        var tip = ""
        func mine(_ count: Int) async throws {
            for _ in 0..<count { tip = try BlockHeader(node: try await producerRuntime.mineBlock(paid)).rawCID }
        }
        try await mine(3)

        let followerDirectory = directory()
        let follower = try node(
            keyByte: 0xc2, directory: followerDirectory, peers: [producer.2], state: .recent, bodies: .none
        )
        let crash = Crash(at: boundary, armed: armedAtStart)
        var acknowledged: String?
        do {
            let storage = try await NodeStorage.open(configuration: follower.0)
            let runtime = try await NodeRuntime.start(
                storage: storage, configuration: follower.0, overlay: follower.1,
                failStop: { XCTFail("fail-stop: \($0)") }, observeJob: nil,
                stopRetention: { crash.stops($0) }
            )
            if !armedAtStart {
                try await eventually("\(boundary): the follower reaches the tip") {
                    runtime.published.value?.actOnTip == tip
                }
                let submitted = try await runtime.submitTransaction(SubmitTransactionRequest(
                    transaction: try transaction(payer, nonce: 0, paying: address(payee))
                ))
                acknowledged = submitted.transactionCID
                crash.arm()
            }
            var polls = 0
            try await eventually("\(boundary): the crash comes", within: .seconds(60)) {
                if crash.fired { return true }
                polls += 1
                if polls % 20 == 0 {
                    if !armedAtStart { try await mine(1) }
                    runtime.inputs.yield(.maintenance)
                }
                return false
            }
            await runtime.stop()
        }

        try await mine(2)
        let storage = try await NodeStorage.open(configuration: follower.0)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: follower.0, overlay: follower.1)
        var polls = 0
        try await eventually("\(boundary): after the restart the follower reaches the tip and its counts it", within: .seconds(60)) {
            polls += 1
            if polls % 50 == 0 { runtime.inputs.yield(.maintenance) }
            guard runtime.published.value?.actOnTip == tip else { return false }
            let counted = try await storage.broker.countedState(scope: storage.scopes.counted(at: ["Nexus"]))
            guard let marker = counted.marker, CountedMarker(marker)?.tip.cid == tip else { return false }
            return await storage.auditCounted(at: ["Nexus"], marker: marker) != nil
        }
        let account = await runtime.reads.account(owner: address(payer), blockCID: tip)
        XCTAssertNotNil(account, "\(boundary): the tip's state answers a read")
        if let acknowledged {
            try await eventually("\(boundary): the acknowledged transaction is pooled or on the chain") {
                let pooled = try await storage.localTransactions().contains { item in
                    (try? Mempool.cid(of: item.transaction)) == acknowledged
                }
                let onChain = await runtime.reads.account(owner: address(payee), blockCID: tip)?.balance == 1
                return pooled || onChain
            }
        }
        await runtime.stop()
        await producerRuntime.stop()
    }
}
