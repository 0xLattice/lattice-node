import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon

/// The opt-in public submit: off unless the operator turns it on; on, the
/// operator route's body and answer, named refusals, a capped body, a
/// volatile (never journaled) admission relayed by ordinary gossip.
final class PublicSubmitTests: XCTestCase {
    private func node(keyByte: UInt8, peers: [PeerEndpoint] = []) async throws -> (NodeRuntime, NodeStorage, PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            publicSubmit: true
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage,
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                bootstrapPeers: peers,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
        )
        addTeardownBlock { await runtime.stop() }
        return (runtime, storage, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    private static func transaction(
        _ key: (privateKey: String, publicKey: String),
        actions: [AccountAction] = [],
        chainPath: [String] = ["Nexus"]
    ) throws -> Transaction {
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: actions, actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: chainPath
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    private static func post(_ client: some TestClientProtocol, _ transaction: Transaction) async throws -> TestResponse {
        try await client.execute(
            uri: "/transactions", method: .post, headers: [.contentType: "application/json"],
            body: ByteBuffer(bytes: try JSONEncoder().encode(SubmitTransactionRequest(transaction: transaction)))
        )
    }

    private static func text(_ response: TestResponse) -> String {
        String(decoding: response.body.readableBytesView, as: UTF8.self)
    }

    func testOffByDefaultTheListenerHasNoSubmitRouteAndSaysSo() async throws {
        let (runtime, _, _) = try await node(keyByte: 0x61)
        let app = makePublicReadApplication(service: runtime, host: "127.0.0.1", port: 8081)
        try await app.test(.router) { client in
            let response = try await Self.post(client, try Self.transaction(CryptoUtils.generateKeyPair()))
            XCTAssertEqual(response.status, .notFound)
            let info = try await client.execute(uri: "/api/chain/info", method: .get)
            XCTAssertEqual(try JSONDecoder().decode(ExplorerChainInfo.self, from: Data(buffer: info.body)).acceptsSubmit, false)
        }
        let status = await runtime.status()
        XCTAssertEqual(status.mempoolCount, 0)
        // The loopback operator API always accepts its own submits.
        try await makeApplication(service: runtime, host: "127.0.0.1", port: 8080).test(.router) { client in
            let info = try await client.execute(uri: "/api/chain/info", method: .get)
            XCTAssertEqual(try JSONDecoder().decode(ExplorerChainInfo.self, from: Data(buffer: info.body)).acceptsSubmit, true)
            // The operator's relay floor, read-only, as a decimal string (default 0).
            let object = try JSONSerialization.jsonObject(with: Data(buffer: info.body)) as? [String: Any]
            XCTAssertEqual(object?["minRelayFee"] as? String, "0")
        }
    }

    func testOnAValidSubmitIsAdmittedAnsweredNeverJournaledAndRelayedToAPeer() async throws {
        let (host, hostStorage, hostEndpoint) = try await node(keyByte: 0x62)
        let (peer, _, _) = try await node(keyByte: 0x63, peers: [hostEndpoint])
        try await eventually("the peer connects") { host.peerCount > 0 && peer.peerCount > 0 }
        let tx = try Self.transaction(CryptoUtils.generateKeyPair())
        let cid = try VolumeImpl<Transaction>(node: tx).rawCID
        let app = makePublicReadApplication(service: host, host: "127.0.0.1", port: 8081, submit: true)
        try await app.test(.router) { client in
            let response = try await Self.post(client, tx)
            XCTAssertEqual(response.status, .ok, Self.text(response))
            let answer = try JSONDecoder().decode(SubmitTransactionResponse.self, from: Data(buffer: response.body))
            XCTAssertEqual(answer.transactionCID, cid)
            XCTAssertEqual(answer.mempoolCount, 1)
            let info = try await client.execute(uri: "/api/chain/info", method: .get)
            XCTAssertEqual(try JSONDecoder().decode(ExplorerChainInfo.self, from: Data(buffer: info.body)).acceptsSubmit, true)
            // Reachable cross-origin: the preflight allows POST.
            let preflight = try await client.execute(
                uri: "/transactions", method: .options,
                headers: [.origin: "chrome-extension://wallet", .accessControlRequestMethod: "POST"]
            )
            XCTAssertTrue(preflight.headers[.accessControlAllowMethods]?.contains("POST") == true, "\(preflight.headers)")
        }
        let journal = try await hostStorage.localTransactions()
        XCTAssertTrue(journal.isEmpty, "a public submit is never journaled with local priority")
        try await eventually("the peer pools it by ordinary gossip") {
            peer.published.value?.mempoolCount == 1
        }
    }

    func testEveryRefusalIsNamedTheBodyIsCappedAndAnUnhostedChainIs404() async throws {
        let (runtime, _, _) = try await node(keyByte: 0x64)
        let key = CryptoUtils.generateKeyPair()
        let app = makePublicReadApplication(service: runtime, host: "127.0.0.1", port: 8081, submit: true)
        try await app.test(.router) { client in
            let first = try await Self.post(client, try Self.transaction(key))
            XCTAssertEqual(first.status, .ok, Self.text(first))
            // Same signer and nonce, no better fee: replace-by-fee refuses by name.
            let signer = CryptoUtils.createAddress(from: key.publicKey)
            let rival = try await Self.post(client, try Self.transaction(key, actions: [
                AccountAction(owner: signer, delta: -1), AccountAction(owner: signer, delta: 1),
            ]))
            XCTAssertEqual(rival.status, .badRequest)
            XCTAssertTrue(Self.text(rival).contains("feeTooLow"), Self.text(rival))
            // Value-creating: refused by name.
            let other = CryptoUtils.generateKeyPair()
            let minted = try await Self.post(client, try Self.transaction(other, actions: [
                AccountAction(owner: CryptoUtils.createAddress(from: other.publicKey), delta: 5),
            ]))
            XCTAssertEqual(minted.status, .badRequest)
            XCTAssertFalse(Self.text(minted).isEmpty, "the refusal names itself")
            // A chain this node does not host.
            let unhosted = try await Self.post(client, try Self.transaction(other, chainPath: ["Nexus", "NotHosted"]))
            XCTAssertEqual(unhosted.status, .notFound)
            XCTAssertTrue(Self.text(unhosted).contains("unknownChain"), Self.text(unhosted))
            // Malformed and oversized bodies never reach the node.
            let malformed = try await client.execute(
                uri: "/transactions", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            )
            XCTAssertEqual(malformed.status, .badRequest)
            let oversized = try await client.execute(
                uri: "/transactions", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(repeating: UInt8(ascii: " "), count: NodeAPILimits.maximumPayloadBytes + 1)
            )
            XCTAssertEqual(oversized.status, .contentTooLarge)
        }
        let status = await runtime.status()
        XCTAssertEqual(status.mempoolCount, 1)
    }
}
