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

/// Paid serving: the operator's credit of a peer's balance, and balances kept
/// across restarts.
final class PaidServingTests: XCTestCase {
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

    private static func text(_ response: TestResponse) -> String {
        String(decoding: response.body.readableBytesView, as: UTF8.self)
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

    func testBalancesSurviveARestart() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tally = Tally()
        let ledger = try ServingLedger(directory: directory, tally: tally)
        _ = try await ledger.credit(peer: Self.peer, bytes: 1_500)
        // Contended serving spends; the next save keeps what is left.
        tally.spendServingBalance(peer: PeerID(publicKey: Self.peer), bytes: 300)
        await ledger.save()

        let restarted = Tally()
        let restored = try ServingLedger(directory: directory, tally: restarted)
        let balance = try await restored.balance(peer: Self.peer)
        XCTAssertEqual(balance, 1_200)

        // A file that cannot be read fails the start: it holds the balances.
        try Data("{".utf8).write(to: directory.appendingPathComponent(ServingLedger.fileName))
        XCTAssertThrowsError(try ServingLedger(directory: directory, tally: Tally()))
    }

    /// A file an earlier node wrote, with the payments it credited, still
    /// loads: those are ignored, the balances kept.
    func testAFileWithCreditedPaymentsStillLoads() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"balances":{"\#(Self.peer)":700},"credited":["payment"]}"#.utf8)
            .write(to: directory.appendingPathComponent(ServingLedger.fileName))
        let tally = Tally()
        _ = try ServingLedger(directory: directory, tally: tally)
        XCTAssertEqual(tally.servingBalance(for: PeerID(publicKey: Self.peer)), 700)
    }

    /// Past Tally's bound a new peer's credit takes the smallest balance's
    /// place, as Tally does; one no larger is refused before anything is
    /// written.
    func testPastTallysBoundANewCreditDisplacesOnlyASmallerBalance() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = TallyConfig(maxPeers: 1)
        let tally = Tally(config: config)
        let ledger = try ServingLedger(directory: directory, tally: tally, config: config)
        let peers = (1...5).map { String(repeating: String(format: "%02x", $0), count: 32) }
        for (index, peer) in peers.prefix(4).enumerated() { _ = try await ledger.credit(peer: peer, bytes: 10 + index) }
        do {
            _ = try await ledger.credit(peer: peers[4], bytes: 10)
            XCTFail("no larger than the smallest balance")
        } catch {
            XCTAssertEqual(error as? ServingLedgerError, .balancesFull)
        }
        // Not burned: a larger credit for it takes the smallest's place.
        _ = try await ledger.credit(peer: peers[4], bytes: 11)
        XCTAssertEqual(tally.servingBalances().count, 4)
        XCTAssertEqual(tally.servingBalance(for: PeerID(publicKey: peers[0])), 0)
        XCTAssertEqual(tally.servingBalance(for: PeerID(publicKey: peers[4])), 11)
        // And the file agrees.
        let restored = Tally(config: config)
        _ = try ServingLedger(directory: directory, tally: restored, config: config)
        XCTAssertEqual(restored.servingBalances(), tally.servingBalances())
    }

    func testACreditThatCannotBeWrittenIsNotApplied() async throws {
        let tally = Tally()
        let ledger = try ServingLedger(directory: temporaryDirectory(), tally: tally)
        do {
            _ = try await ledger.credit(peer: Self.peer, bytes: 10)
            XCTFail("the directory does not exist")
        } catch {
            XCTAssertEqual(error as? ServingLedgerError, .notSaved)
        }
        XCTAssertEqual(tally.servingBalance(for: PeerID(publicKey: Self.peer)), 0)
    }

}
