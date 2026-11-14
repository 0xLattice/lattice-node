import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import Lattice
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon
import LatticeNodeAPI

/// The remote operator listener (`--operator-listen`): scoped bearer tokens,
/// no cookie, no file paths; and the inline `POST /hosted-chains` form its
/// clients send.
final class OperatorListenerTests: XCTestCase {
    private static let token = "seller-token"
    private static let alpha = ["Nexus", "Alpha"]

    private func remote() async throws -> Application<RouterResponder<BasicRequestContext>> {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-operator-listener-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "02", count: 32)
        ))
        let service = try await startRuntime(storage)
        let hash = SHA256.hash(data: Data(Self.token.utf8)).map { String(format: "%02x", $0) }.joined()
        let tokens = try OperatorTokens([
            .init(name: "seller", sha256: hash, routes: ["GET /hosted-chains", "post /hosted-chains", "GET /api/state/account/{addr}"]),
        ])
        return makeApplication(service: service, host: "10.0.0.5", port: 8090, auth: .remote(tokens))
    }

    private static func hostedChains(_ request: HostedChainsRequest) throws -> ByteBuffer {
        ByteBuffer(bytes: try JSONEncoder().encode(request))
    }

    func testAListedRouteAnswersItsToken() async throws {
        let app = try await remote()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/hosted-chains", method: .get, headers: [.authorization: "Bearer \(Self.token)"]
            ) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
            // A route with a parameter is listed as registered.
            try await client.execute(
                uri: "/api/state/account/\(String(repeating: "a", count: 40))", method: .get,
                headers: [.authorization: "Bearer \(Self.token)"]
            ) { XCTAssertNotEqual($0.status, .forbidden) }
            // A write from another host: no loopback Host is required here.
            var headers: HTTPFields = [.authorization: "Bearer \(Self.token)", .contentType: "application/json"]
            headers.append(.init(name: .init("Host")!, value: "10.0.0.5:8090"))
            try await client.execute(
                uri: "/hosted-chains", method: .post,
                headers: headers,
                body: try Self.hostedChains(HostedChainsRequest(
                    hostChain: nil, premineTo: nil, genesisTransactions: nil, chainPeer: nil, policyModule: nil, chains: []
                ))
            ) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
        }
    }

    func testNoOrUnknownTokenIsUnauthorized() async throws {
        let app = try await remote()
        try await app.test(.router) { client in
            for headers: HTTPFields in [[:], [.authorization: "Bearer not-a-token"], [.authorization: "Token \(Self.token)"]] {
                try await client.execute(uri: "/hosted-chains", method: .get, headers: headers) {
                    XCTAssertEqual($0.status, .unauthorized)
                }
            }
            // Nothing is open without one, /health included.
            try await client.execute(uri: "/health", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testARouteOutsideTheTokensListIsForbidden() async throws {
        let app = try await remote()
        try await app.test(.router) { client in
            for (uri, method) in [
                ("/status", HTTPRequest.Method.get), ("/pins", .get), ("/health", .get), ("/no-such-route", .get),
            ] {
                try await client.execute(uri: uri, method: method, headers: [.authorization: "Bearer \(Self.token)"]) {
                    XCTAssertEqual($0.status, .forbidden, uri)
                }
            }
        }
    }

    func testTheCookieIsRefused() async throws {
        let app = try await remote()
        let basic = "Basic " + Data("__cookie__:test-cookie".utf8).base64EncodedString()
        try await app.test(.router) { client in
            for authorization in [testOperatorAuthorization, basic] {
                try await client.execute(uri: "/hosted-chains", method: .get, headers: [.authorization: authorization]) {
                    XCTAssertEqual($0.status, .unauthorized, authorization)
                }
            }
        }
    }

    func testFilePathsAreRefused() async throws {
        let app = try await remote()
        let requests = [
            HostedChainsRequest(hostChain: ["Nexus/Alpha=/etc/spec.json"], premineTo: nil, genesisTransactions: nil, chainPeer: nil, policyModule: nil),
            HostedChainsRequest(hostChain: ["Nexus/Alpha"], premineTo: nil, genesisTransactions: ["Nexus/Alpha=/tmp/g.json"], chainPeer: nil, policyModule: nil),
            HostedChainsRequest(hostChain: [], premineTo: nil, genesisTransactions: nil, chainPeer: nil, policyModule: ["/tmp/p.wasm"]),
        ]
        try await app.test(.router) { client in
            for request in requests {
                try await client.execute(
                    uri: "/hosted-chains", method: .post,
                    headers: [.authorization: "Bearer \(Self.token)", .contentType: "application/json"],
                    body: try Self.hostedChains(request)
                ) { response in
                    XCTAssertEqual(response.status, .badRequest)
                    XCTAssertTrue(String(buffer: response.body).contains("no file paths"), String(buffer: response.body))
                }
            }
        }
    }

    func testTokenFileEntriesAreChecked() throws {
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: "abc", routes: [])]))
        let hash = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: hash, routes: ["hosted-chains"])]))
        XCTAssertThrowsError(try OperatorTokens([
            .init(name: "a", sha256: hash, routes: []), .init(name: "b", sha256: hash.uppercased(), routes: []),
        ]))
    }

    /// Inline chains go through the same checks as the file form: the same
    /// spec and recipient are accepted or refused alike.
    func testInlineChainsAreCheckedAsTheFileFormIs() throws {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 5,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-inline-hosted-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let specFile = directory.appendingPathComponent("spec.json")
        try JSONEncoder().encode(spec).write(to: specFile)
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)

        func fromFiles(_ to: String) throws -> HostedChildren {
            try HostedChildren(
                hostChain: ["Nexus/Alpha=\(specFile.path)"], premineTo: ["Nexus/Alpha=\(to)"],
                chainPeer: [], policyModule: []
            )
        }
        func inline(_ to: String?, spec: ChainSpec? = spec) throws -> HostedChildren {
            try HostedChildren(
                hostChain: [], premineTo: [], chainPeer: [], policyModule: [],
                chains: [HostedChain(path: "Nexus/Alpha", spec: spec, premineTo: to)]
            )
        }

        let files = try fromFiles(recipient)
        let sent = try inline(recipient)
        XCTAssertEqual(sent.children, files.children)
        XCTAssertEqual(try JSONEncoder().encode(sent.specs[Self.alpha]), try JSONEncoder().encode(files.specs[Self.alpha]))
        XCTAssertEqual(sent.premineRecipients, [Self.alpha: recipient])
        XCTAssertEqual(sent.premineRecipients, files.premineRecipients)

        XCTAssertThrowsError(try fromFiles("not-an-address"))
        XCTAssertThrowsError(try inline("not-an-address"))
        // A recipient needs a spec to pay it from.
        XCTAssertThrowsError(try inline(recipient, spec: nil))
        // One chain is named once.
        XCTAssertThrowsError(try HostedChildren(
            hostChain: ["Nexus/Alpha"], premineTo: [], chainPeer: [], policyModule: [],
            chains: [HostedChain(path: "Nexus/Alpha")]
        ))
        // The inline form round-trips as JSON, specs and all.
        let decoded = try JSONDecoder().decode(
            HostedChainsRequest.self,
            from: JSONEncoder().encode(HostedChainsRequest(
                hostChain: nil, premineTo: nil, genesisTransactions: nil, chainPeer: nil, policyModule: nil,
                chains: [HostedChain(path: "Nexus/Alpha", spec: spec, premineTo: recipient, policyModules: [Data([1, 2])])]
            ))
        )
        XCTAssertEqual(try JSONEncoder().encode(decoded.chains?.first?.spec), try JSONEncoder().encode(spec))
        XCTAssertFalse(decoded.namesFiles)
    }
}
