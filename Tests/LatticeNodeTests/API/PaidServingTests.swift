import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon
import LatticeNodeAPI

/// Paid serving: the terms the public read port publishes, a prepay credited
/// once and only for a deep enough payment its signer claims, every refusal
/// named, the operator's own credit, and balances kept across restarts.
final class PaidServingTests: XCTestCase {
    private static let payTo = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
    private static let peer = String(repeating: "ab", count: 32)

    private func node(keyByte: UInt8) async throws -> NodeRuntime {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage,
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
        )
        addTeardownBlock { await runtime.stop() }
        return runtime
    }

    /// Unlimited, so one test can send every refusal.
    private func app(_ runtime: NodeRuntime, terms: PaidServing) throws -> Application<RouterResponder<PublicReadRequestContext>> {
        makePublicReadApplication(
            reads: runtime.reads, levelReads: { Array(runtime.levelReads.values) }, host: "127.0.0.1", port: 8081,
            limits: try PublicReadRateLimits.validated(generalRate: 0, expensiveRate: 0, listenerRate: 0, submitRate: 0),
            serving: ServingPayments(terms: terms, ledger: runtime.servingLedger)
        )
    }

    private static func transaction(
        _ key: (privateKey: String, publicKey: String), nonce: UInt64, actions: [AccountAction]
    ) throws -> Transaction {
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: actions, actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: nonce, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    private static func prepay(
        _ client: some TestClientProtocol, chain: String = "Nexus", txCID: String, peer: String? = nil,
        signer: String, key: String, signedPeer: String? = nil
    ) async throws -> TestResponse {
        let peer = peer ?? Self.peer
        let signature = try XCTUnwrap(CryptoUtils.sign(
            message: servingPrepayMessage(chain: chain, txCID: txCID, peer: signedPeer ?? peer), privateKeyHex: key
        ))
        let body = ServingPrepayRequest(chain: chain, txCID: txCID, peer: peer, signer: signer, signature: signature)
        return try await client.execute(
            uri: "/serving-prepay", method: .post, headers: [.contentType: "application/json"],
            body: ByteBuffer(bytes: try JSONEncoder().encode(body))
        )
    }

    private static func text(_ response: TestResponse) -> String {
        String(decoding: response.body.readableBytesView, as: UTF8.self)
    }

    func testTermsAreNullWhenUnsetAndNamedWhenSet() async throws {
        let runtime = try await node(keyByte: 0x71)
        try await try app(runtime, terms: try PaidServing()).test(.router) { client in
            let response = try await client.execute(uri: "/serving-terms", method: .get)
            XCTAssertEqual(response.status, .ok)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
            XCTAssertTrue(object["payTo"] is NSNull)
            XCTAssertTrue(object["workURL"] is NSNull)
            XCTAssertEqual((object["rates"] as? [String: Any])?.count, 0)
            XCTAssertEqual(object["depth"] as? Int, Int(PaidServing.defaultDepth))
        }
        let terms = try PaidServing(
            payTo: Self.payTo, rates: [["Nexus"]: 1024, ["Nexus", "Alpha"]: 8], depth: 3, workURL: "https://work.example.org"
        )
        try await try app(runtime, terms: terms).test(.router) { client in
            let response = try await client.execute(uri: "/serving-terms", method: .get)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any])
            XCTAssertEqual(object["payTo"] as? String, Self.payTo)
            XCTAssertEqual(object["workURL"] as? String, "https://work.example.org")
            XCTAssertEqual(object["depth"] as? Int, 3)
            let rates = try XCTUnwrap(object["rates"] as? [String: [String: Int]])
            XCTAssertEqual(rates, ["Nexus": ["bytesPerCoin": 1024], "Nexus/Alpha": ["bytesPerCoin": 8]])
        }
        XCTAssertThrowsError(try PaidServing(rates: [["Nexus"]: 1]))
        XCTAssertThrowsError(try PaidServing(payTo: "not-an-address"))
        XCTAssertThrowsError(try PaidServing(payTo: Self.payTo, rates: [["Nexus"]: 0]))
    }

    func testAPrepayIsCreditedOnceDeepEnoughAndEachRefusalIsNamed() async throws {
        let runtime = try await node(keyByte: 0x72)
        let key = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: key.publicKey)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: signer)])
        let funding = try BlockHeader(node: try await runtime.mineBlock(paid)).rawCID
        let funded = await runtime.reads.account(owner: signer, blockCID: funding)?.balance
        XCTAssertGreaterThan(try XCTUnwrap(funded), 10)
        // Pays 7 to payTo.
        let payment = try Self.transaction(key, nonce: 0, actions: [
            AccountAction(owner: signer, delta: -7), AccountAction(owner: Self.payTo, delta: 7),
        ])
        let paymentCID = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: payment)).transactionCID
        _ = try await runtime.mineBlock()
        let other = CryptoUtils.generateKeyPair()
        let pending = try VolumeImpl<Transaction>(node: try Self.transaction(other, nonce: 0, actions: [])).rawCID
        let terms = try PaidServing(payTo: Self.payTo, rates: [["Nexus"]: 1000, ["Nexus", "Alpha"]: 1], depth: 2)

        try await try app(runtime, terms: terms).test(.router) { client in
            func refused(_ response: TestResponse, _ status: HTTPResponse.Status, _ name: String) {
                XCTAssertEqual(response.status, status, Self.text(response))
                XCTAssertTrue(Self.text(response).contains(name), Self.text(response))
            }
            // In the chain, but not yet depth 2: retryable.
            refused(
                try await Self.prepay(client, txCID: paymentCID, signer: signer, key: key.privateKey),
                .tooEarly, "notDeepEnough"
            )
            // A transaction paying nothing, then enough blocks on both.
            let unpaying = try Self.transaction(key, nonce: 1, actions: [])
            let unpayingCID = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: unpaying)).transactionCID
            for _ in 0..<3 { _ = try await runtime.mineBlock() }
            refused(
                try await Self.prepay(client, chain: "Nexus/Beta", txCID: paymentCID, signer: signer, key: key.privateKey),
                .badRequest, "unpricedChain"
            )
            refused(
                try await Self.prepay(client, chain: "Nexus/Alpha", txCID: paymentCID, signer: signer, key: key.privateKey),
                .notFound, "unknownChain"
            )
            refused(
                try await Self.prepay(client, txCID: paymentCID, peer: Self.peer.uppercased(), signer: signer, key: key.privateKey),
                .badRequest, "invalidPeer"
            )
            refused(
                try await Self.prepay(client, txCID: "not a cid", signer: signer, key: key.privateKey),
                .badRequest, "invalidCID"
            )
            refused(
                try await Self.prepay(client, txCID: pending, signer: signer, key: key.privateKey),
                .notFound, "notIncluded"
            )
            refused(
                try await Self.prepay(
                    client, txCID: paymentCID, signer: CryptoUtils.createAddress(from: other.publicKey), key: other.privateKey
                ),
                .badRequest, "notSigner"
            )
            // Signed for another peer: the claim cannot be moved.
            refused(
                try await Self.prepay(
                    client, txCID: paymentCID, signer: signer, key: key.privateKey, signedPeer: String(repeating: "cd", count: 32)
                ),
                .badRequest, "invalidSignature"
            )
            refused(
                try await Self.prepay(client, txCID: unpayingCID, signer: signer, key: key.privateKey),
                .badRequest, "noPayment"
            )

            let credited = try await Self.prepay(client, txCID: paymentCID, signer: signer, key: key.privateKey)
            XCTAssertEqual(credited.status, .ok, Self.text(credited))
            let answer = try JSONDecoder().decode(ServingPrepayResponse.self, from: Data(buffer: credited.body))
            XCTAssertEqual(answer.peer, Self.peer)
            XCTAssertEqual(answer.credited, 7_000)
            XCTAssertEqual(answer.balance, 7_000)
            refused(
                try await Self.prepay(client, txCID: paymentCID, signer: signer, key: key.privateKey),
                .conflict, "alreadyCredited"
            )
            // Nor for another peer.
            refused(
                try await Self.prepay(
                    client, txCID: paymentCID, peer: String(repeating: "cd", count: 32), signer: signer, key: key.privateKey
                ),
                .conflict, "alreadyCredited"
            )
        }
        let balance = try await runtime.servingLedger.balance(peer: Self.peer)
        XCTAssertEqual(balance, 7_000)
    }

    /// A payment's net to payTo: its debits from payTo count against it.
    func testAPaymentCountsNetOfDebitsFromPayTo() async throws {
        let runtime = try await node(keyByte: 0x75)
        let key = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: key.publicKey)
        let paid = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: ["Nexus"], address: signer)])
        _ = try await runtime.mineBlock(paid)
        // The payer is payTo too: +9 and -9 to itself nets nothing.
        let wash = try Self.transaction(key, nonce: 0, actions: [
            AccountAction(owner: signer, delta: -9), AccountAction(owner: signer, delta: 9),
        ])
        let washCID = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: wash)).transactionCID
        _ = try await runtime.mineBlock()
        let terms = try PaidServing(payTo: signer, rates: [["Nexus"]: 1], depth: 0)
        try await try app(runtime, terms: terms).test(.router) { client in
            let response = try await Self.prepay(client, txCID: washCID, signer: signer, key: key.privateKey)
            XCTAssertEqual(response.status, .badRequest, Self.text(response))
            XCTAssertTrue(Self.text(response).contains("noPayment"), Self.text(response))
        }
    }

    func testTheOperatorCreditsAndReadsABalance() async throws {
        let runtime = try await node(keyByte: 0x73)
        try await makeApplication(service: runtime, host: "127.0.0.1", port: 8080).test(.router) { client in
            let headers: HTTPFields = [.authorization: testOperatorAuthorization, .contentType: "application/json"]
            func credit(_ peer: String, _ bytes: Int) async throws -> TestResponse {
                try await client.execute(
                    uri: "/serving-balance", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try JSONEncoder().encode(ServingBalanceRequest(peer: peer, bytes: bytes)))
                )
            }
            let first = try await credit(Self.peer, 500)
            XCTAssertEqual(first.status, .ok, Self.text(first))
            let second = try await credit(Self.peer, 250)
            XCTAssertEqual(try JSONDecoder().decode(ServingBalanceResponse.self, from: Data(buffer: second.body)).balance, 750)
            let read = try await client.execute(
                uri: "/serving-balance/\(Self.peer)", method: .get, headers: [.authorization: testOperatorAuthorization]
            )
            XCTAssertEqual(read.status, .ok)
            let answer = try JSONDecoder().decode(ServingBalanceResponse.self, from: Data(buffer: read.body))
            XCTAssertEqual(answer.peer, Self.peer)
            XCTAssertEqual(answer.balance, 750)

            let zero = try await credit(Self.peer, 0)
            XCTAssertEqual(zero.status, .badRequest)
            XCTAssertTrue(Self.text(zero).contains("invalidBytes"), Self.text(zero))
            let badPeer = try await credit("ed01" + Self.peer, 1)
            XCTAssertEqual(badPeer.status, .badRequest)
            XCTAssertTrue(Self.text(badPeer).contains("invalidPeer"), Self.text(badPeer))
            let badRead = try await client.execute(
                uri: "/serving-balance/nobody", method: .get, headers: [.authorization: testOperatorAuthorization]
            )
            XCTAssertEqual(badRead.status, .badRequest)
            // Operator surface: never without the cookie.
            let anonymous = try await client.execute(uri: "/serving-balance/\(Self.peer)", method: .get)
            XCTAssertEqual(anonymous.status, .unauthorized)
        }
        // Not on the public port.
        try await makePublicReadApplication(service: runtime, host: "127.0.0.1", port: 8081).test(.router) { client in
            let response = try await client.execute(uri: "/serving-balance/\(Self.peer)", method: .get)
            XCTAssertEqual(response.status, .notFound)
        }
    }

    func testBalancesAndCreditedPaymentsSurviveARestart() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tally = Tally()
        let ledger = try ServingLedger(directory: directory, tally: tally)
        _ = try await ledger.credit(peer: Self.peer, bytes: 1_000)
        _ = try await ledger.credit(peer: Self.peer, bytes: 500, payment: "payment")
        // Contended serving spends; the next save keeps what is left.
        tally.spendServingBalance(peer: PeerID(publicKey: Self.peer), bytes: 300)
        await ledger.save()

        let restarted = Tally()
        let restored = try ServingLedger(directory: directory, tally: restarted)
        XCTAssertEqual(restarted.servingBalance(for: PeerID(publicKey: Self.peer)), 1_200)
        do {
            _ = try await restored.credit(peer: Self.peer, bytes: 500, payment: "payment")
            XCTFail("a payment is credited once")
        } catch {
            XCTAssertEqual(error as? ServingLedgerError, .alreadyCredited)
        }
        let balance = try await restored.balance(peer: Self.peer)
        XCTAssertEqual(balance, 1_200)

        // A file that cannot be read fails the start: it holds what was credited.
        try Data("{".utf8).write(to: directory.appendingPathComponent(ServingLedger.fileName))
        XCTAssertThrowsError(try ServingLedger(directory: directory, tally: Tally()))
    }

    func testAPrepayIsBilledAsAnExpensiveRead() {
        XCTAssertEqual(PublicReadRouteClass(method: .post, path: "/serving-prepay"), .expensive)
        XCTAssertEqual(PublicReadRouteClass(method: .get, path: "/serving-terms"), .general)
    }
}
