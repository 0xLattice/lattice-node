import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import Lattice
import LatticeCtlCore
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon
import LatticeNodeAPI

/// The remote operator listener (`--operator-listen`): bearer tokens with a
/// role or a route list, no cookie, no file paths, an origin allowlist; and
/// tokens made and revoked through the API.
final class OperatorListenerTests: XCTestCase {
    private static let token = "seller-token"
    private static let admin = "admin-token"
    private static let reader = "read-token"

    private struct Node {
        let app: Application<RouterResponder<BasicRequestContext>>
        let tokens: TokenStore
    }

    private func node(remote: Bool = true, origins: Set<String> = []) async throws -> Node {
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
        let tokens = TokenStore(try OperatorTokens([
            .init(name: "seller", sha256: OperatorTokens.hash(Self.token), routes: [
                "GET /hosted-chains", "post /hosted-chains", "GET /api/state/account/{addr}", "POST /tokens",
            ]),
            .init(name: "ops", sha256: OperatorTokens.hash(Self.admin), role: "admin"),
            .init(name: "viewer", sha256: OperatorTokens.hash(Self.reader), role: "read"),
        ]), file: directory.appendingPathComponent("tokens.json"))
        let control = OperatorControl(tokens: tokens, storagePath: directory)
        let app = remote
            ? makeApplication(
                service: service, host: "10.0.0.5", port: 8090,
                auth: .remote(tokens, allowedOrigins: origins), control: control
            )
            : makeApplication(service: service, host: "127.0.0.1", port: 8080, control: control)
        return Node(app: app, tokens: tokens)
    }

    private static func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    func testAListedRouteAnswersItsToken() async throws {
        let app = try await node().app
        try await app.test(.router) { client in
            try await client.execute(uri: "/hosted-chains", method: .get, headers: Self.bearer(Self.token)) {
                XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
            }
            // A route with a parameter is listed as registered.
            try await client.execute(
                uri: "/api/state/account/\(String(repeating: "a", count: 40))", method: .get,
                headers: Self.bearer(Self.token)
            ) { XCTAssertNotEqual($0.status, .forbidden) }
        }
    }

    func testNoOrUnknownTokenIsUnauthorized() async throws {
        let app = try await node().app
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
        let app = try await node().app
        try await app.test(.router) { client in
            for (uri, method) in [
                ("/status", HTTPRequest.Method.get), ("/pins", .get), ("/health", .get), ("/no-such-route", .get),
                // Only admin manages tokens, whatever a list names.
                ("/tokens", .post),
            ] {
                try await client.execute(uri: uri, method: method, headers: Self.bearer(Self.token)) {
                    XCTAssertEqual($0.status, .forbidden, uri)
                }
            }
        }
    }

    /// `read` reaches every GET and nothing else; `admin` reaches all.
    func testRolesScopeTheirTokens() async throws {
        let app = try await node().app
        try await app.test(.router) { client in
            for uri in ["/status", "/pins", "/hosted-chains", "/disk", "/mining"] {
                try await client.execute(uri: uri, method: .get, headers: Self.bearer(Self.reader)) {
                    XCTAssertEqual($0.status, .ok, "\(uri): \(String(buffer: $0.body))")
                }
            }
            for (uri, method) in [("/restart", HTTPRequest.Method.post), ("/config", .patch), ("/tokens", .get)] {
                try await client.execute(uri: uri, method: method, headers: Self.bearer(Self.reader)) {
                    XCTAssertEqual($0.status, .forbidden, uri)
                }
            }
            try await client.execute(uri: "/tokens", method: .get, headers: Self.bearer(Self.admin)) {
                XCTAssertEqual($0.status, .ok)
            }
            // Admin passes the token check to a route's own answer: 409, not
            // 403, for a configuration this node does not own.
            try await client.execute(uri: "/config", method: .get, headers: Self.bearer(Self.admin)) {
                XCTAssertEqual($0.status, .conflict)
            }
        }
    }

    func testTheCookieIsRefused() async throws {
        let app = try await node().app
        let basic = "Basic " + Data("__cookie__:test-cookie".utf8).base64EncodedString()
        try await app.test(.router) { client in
            for authorization in [testOperatorAuthorization, basic] {
                try await client.execute(uri: "/hosted-chains", method: .get, headers: [.authorization: authorization]) {
                    XCTAssertEqual($0.status, .unauthorized, authorization)
                }
            }
        }
    }

    /// A node started with flags takes no chains from the remote listener:
    /// their flag form names files on its disk.
    func testFlagFormHostedChainsAreRefusedRemotely() async throws {
        let app = try await node().app
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/hosted-chains", method: .post,
                headers: [.authorization: "Bearer \(Self.token)", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"hostChain":["Nexus/Alpha=/etc/spec.json"]}"#)
            ) { XCTAssertEqual($0.status, .conflict, String(buffer: $0.body)) }
        }
    }

    /// Tokens made through the API work from the next request, the secret
    /// shown once and only its hash kept; a revoked one is refused.
    func testTokensAreMadeAndRevokedLive() async throws {
        let node = try await node()
        try await node.app.test(.router) { client in
            var made: CreateTokenResponse?
            try await client.execute(
                uri: "/tokens", method: .post,
                headers: [.authorization: "Bearer \(Self.admin)", .contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(CreateTokenRequest(name: "dash", role: "read")))
            ) { response in
                XCTAssertEqual(response.status, .ok, String(buffer: response.body))
                made = try JSONDecoder().decode(CreateTokenResponse.self, from: Data(buffer: response.body))
            }
            let secret = try XCTUnwrap(made?.token)
            let file = try String(contentsOf: node.tokens.file, encoding: .utf8)
            XCTAssertFalse(file.contains(secret), "the file keeps only the hash")
            XCTAssertTrue(file.contains(OperatorTokens.hash(secret)))
            let mode = try FileManager.default.attributesOfItem(atPath: node.tokens.file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
            try await client.execute(uri: "/status", method: .get, headers: Self.bearer(secret)) {
                XCTAssertEqual($0.status, .ok)
            }
            // The same name twice, an unknown role, both role and routes: refused.
            for body in [
                CreateTokenRequest(name: "dash", role: "read"), CreateTokenRequest(name: "x", role: "root"),
                CreateTokenRequest(name: "y", role: "read", routes: ["GET /status"]),
            ] {
                try await client.execute(
                    uri: "/tokens", method: .post,
                    headers: [.authorization: "Bearer \(Self.admin)", .contentType: "application/json"],
                    body: ByteBuffer(bytes: try JSONEncoder().encode(body))
                ) { XCTAssertTrue([.conflict, .badRequest].contains($0.status), "\(body.name): \($0.status)") }
            }
            try await client.execute(uri: "/tokens/dash", method: .delete, headers: Self.bearer(Self.admin)) {
                XCTAssertEqual($0.status, .ok)
            }
            try await client.execute(uri: "/status", method: .get, headers: Self.bearer(secret)) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/tokens/dash", method: .delete, headers: Self.bearer(Self.admin)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
        // What the file says is what a restart reads.
        let reloaded = try TokenStore(file: node.tokens.file)
        XCTAssertEqual(reloaded.list().tokens.map(\.name), ["seller", "ops", "viewer"])
    }

    /// The loopback cookie manages tokens too.
    func testTheCookieManagesTokensOnLoopback() async throws {
        let app = try await node(remote: false).app
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/tokens", method: .post,
                headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(CreateTokenRequest(name: "ops2", role: "admin")))
            ) { XCTAssertEqual($0.status, .ok, String(buffer: $0.body)) }
        }
    }

    /// Browsers: an unlisted origin is refused, a listed one gets CORS and
    /// still needs a token.
    func testBrowserOriginsAreAllowlisted() async throws {
        let app = try await node(origins: ["https://dash.example"]).app
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/status", method: .get, headers: [.authorization: "Bearer \(Self.reader)", .origin: "https://evil.example"]
            ) { XCTAssertEqual($0.status, .forbidden) }
            // A preflight from an unlisted origin gets no CORS answer.
            try await client.execute(uri: "/status", method: .options, headers: [.origin: "https://evil.example"]) {
                XCTAssertEqual($0.status, .forbidden)
                XCTAssertNil($0.headers[.accessControlAllowOrigin])
            }
            try await client.execute(uri: "/status", method: .options, headers: [.origin: "https://dash.example"]) {
                XCTAssertEqual($0.status, .noContent)
                XCTAssertEqual($0.headers[.accessControlAllowOrigin], "https://dash.example")
            }
            try await client.execute(uri: "/status", method: .get, headers: [.origin: "https://dash.example"]) {
                XCTAssertEqual($0.status, .unauthorized)
                XCTAssertEqual($0.headers[.accessControlAllowOrigin], "https://dash.example")
            }
            try await client.execute(
                uri: "/status", method: .get, headers: [.authorization: "Bearer \(Self.reader)", .origin: "https://dash.example"]
            ) { XCTAssertEqual($0.status, .ok) }
        }
    }

    /// The dashboard's files are open on both operator listeners; every
    /// route that reads or changes the node still needs its credential.
    func testTheDashboardIsServedWithoutACredential() async throws {
        for remote in [true, false] {
            let app = try await node(remote: remote).app
            try await app.test(.router) { client in
                try await client.execute(uri: "/", method: .get) {
                    XCTAssertEqual($0.status, .ok)
                    XCTAssertEqual($0.headers[.contentType], "text/html; charset=utf-8")
                    XCTAssertTrue(String(buffer: $0.body).contains("dashboard.js"))
                    XCTAssertNotNil($0.headers[.contentSecurityPolicy])
                }
                for asset in ["/dashboard.js", "/dashboard.css"] {
                    try await client.execute(uri: asset, method: .get) { XCTAssertEqual($0.status, .ok, asset) }
                }
                // Only GET of exactly those paths is open.
                for (uri, method) in [
                    ("/status", HTTPRequest.Method.get), ("/config", .get), ("/tokens", .get), ("/restart", .post),
                    ("/", .head), ("/", .post), ("/dashboard.js/", .get), ("/Dashboard.js", .get),
                ] {
                    try await client.execute(uri: uri, method: method) {
                        XCTAssertEqual($0.status, .unauthorized, "\(remote ? "remote" : "loopback") \(uri)")
                    }
                }
            }
        }
    }

    /// The page a listener served calls back with its own origin, which
    /// needs no listing; any other origin is still refused.
    func testTheDashboardsOwnOriginIsNotCrossOrigin() async throws {
        for remote in [true, false] {
            let app = try await node(remote: remote).app
            let credential = remote ? "Bearer \(Self.reader)" : testOperatorAuthorization
            let mode = remote ? "remote" : "loopback"
            try await app.test(.router) { client in
                // The test client names the listener "localhost".
                let own: HTTPFields = [.authorization: credential, .origin: "http://localhost"]
                try await client.execute(uri: "/status", method: .get, headers: own) { XCTAssertEqual($0.status, .ok, mode) }
                let other: HTTPFields = [.authorization: credential, .origin: "http://elsewhere.example"]
                try await client.execute(uri: "/status", method: .get, headers: other) { XCTAssertEqual($0.status, .forbidden, mode) }
                // A Host that disagrees with the origin is not the same origin,
                // nor is a second Host beside one that agrees.
                var rebound = own
                rebound.append(.init(name: .init("Host")!, value: "10.0.0.5:8090"))
                try await client.execute(uri: "/status", method: .get, headers: rebound) { XCTAssertEqual($0.status, .forbidden, mode) }
                var doubled = own
                doubled.append(.init(name: .init("Host")!, value: "localhost"))
                doubled.append(.init(name: .init("Host")!, value: "evil.example"))
                try await client.execute(uri: "/status", method: .get, headers: doubled) { XCTAssertEqual($0.status, .forbidden, mode) }
            }
        }
    }

    func testTokenFileEntriesAreChecked() throws {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: "abc", routes: [])]))
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: hash, routes: ["hosted-chains"])]))
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: hash)]), "a role or routes")
        XCTAssertThrowsError(try OperatorTokens([.init(name: "a", sha256: hash, role: "owner")]))
        XCTAssertThrowsError(try OperatorTokens([
            .init(name: "a", sha256: hash, routes: []), .init(name: "b", sha256: hash.uppercased(), routes: []),
        ]))
        // The earlier file form, routes only, still reads.
        let entries = try JSONDecoder().decode(
            [OperatorTokens.Entry].self, from: Data(#"[{"name":"s","sha256":"\#(hash)","routes":["GET /status"]}]"#.utf8)
        )
        XCTAssertNoThrow(try OperatorTokens(entries))
    }
}
