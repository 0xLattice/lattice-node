import Foundation
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

/// The loopback RPC port's cookie authentication and browser-origin policy.
final class LoopbackRPCAuthTests: XCTestCase {
    private static let extensionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

    private func loopback(allowedOrigins: [String] = []) async throws -> Application<RouterResponder<BasicRequestContext>> {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-rpc-auth-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        return makeApplication(
            service: service, host: "127.0.0.1", port: 8080,
            auth: LoopbackRPCAuth(token: "test-cookie", allowedOrigins: Set(allowedOrigins))
        )
    }

    private static let templateBody = ByteBuffer(bytes: try! JSONEncoder().encode(MiningTemplateRequest()))

    func testEveryRouteButHealthRequiresTheCookie() async throws {
        let app = try await loopback()
        try await app.test(.router) { client in
            for (uri, method) in [
                ("/status", HTTPRequest.Method.get), ("/metrics", .get), ("/api/mempool", .get),
                ("/api/chain/info", .get), ("/no-such-route", .get),
            ] {
                try await client.execute(uri: uri, method: method) { response in
                    XCTAssertEqual(response.status, .unauthorized, uri)
                    XCTAssertEqual(response.headers[.wwwAuthenticate], #"Basic realm="lattice-node""#)
                }
            }
            for uri in ["/mining/templates", "/mining/work", "/transactions"] {
                try await client.execute(
                    uri: uri, method: .post,
                    headers: [.contentType: "application/json"], body: Self.templateBody
                ) { response in
                    XCTAssertEqual(response.status, .unauthorized, uri)
                }
            }
            // Health probes need no secret.
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
            try await client.execute(uri: "/health", method: .head) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testBasicCookieAndBearerAreAcceptedAndAnythingElseRefused() async throws {
        let app = try await loopback()
        let basic = "Basic " + Data("__cookie__:test-cookie".utf8).base64EncodedString()
        try await app.test(.router) { client in
            for accepted in [basic, "Bearer test-cookie", "bearer test-cookie"] {
                try await client.execute(uri: "/status", method: .get, headers: [.authorization: accepted]) { response in
                    XCTAssertEqual(response.status, .ok, accepted)
                }
            }
            try await client.execute(
                uri: "/mining/templates", method: .post,
                headers: [.authorization: basic, .contentType: "application/json"], body: Self.templateBody
            ) { response in
                XCTAssertNotEqual(response.status, .unauthorized)
            }
            for refused in [
                "Bearer test-cookiE", "Bearer ", "Bearer test-cookie-and-more",
                "Basic " + Data("someone:test-cookie".utf8).base64EncodedString(),
                "Basic " + Data("__cookie__:wrong".utf8).base64EncodedString(),
                "Basic not-base64!", "test-cookie", "Digest test-cookie",
            ] {
                try await client.execute(uri: "/status", method: .get, headers: [.authorization: refused]) { response in
                    XCTAssertEqual(response.status, .unauthorized, refused)
                }
            }
        }
    }

    func testBrowserOriginsAreRefusedByDefault() async throws {
        let app = try await loopback()
        try await app.test(.router) { client in
            for uri in ["/status", "/health"] {
                try await client.execute(
                    uri: uri, method: .get,
                    headers: [.authorization: testOperatorAuthorization, .origin: "https://evil.example"]
                ) { response in
                    XCTAssertEqual(response.status, .forbidden, uri)
                    XCTAssertNil(response.headers[.accessControlAllowOrigin])
                }
            }
            try await client.execute(
                uri: "/transactions", method: .options,
                headers: [.origin: Self.extensionOrigin, .accessControlRequestMethod: "POST"]
            ) { response in
                XCTAssertEqual(response.status, .forbidden, "an unlisted extension is a browser origin like any other")
                XCTAssertNil(response.headers[.accessControlAllowOrigin])
            }
        }
    }

    func testAListedOriginGetsPreflightAndCORSButStillNeedsTheCookie() async throws {
        let app = try await loopback(allowedOrigins: [Self.extensionOrigin])
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/transactions", method: .options,
                headers: [
                    .origin: Self.extensionOrigin, .accessControlRequestMethod: "POST",
                    .accessControlRequestHeaders: "authorization, content-type",
                ]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], Self.extensionOrigin)
                XCTAssertTrue(response.headers[.accessControlAllowMethods]?.contains("POST") == true)
                XCTAssertTrue(response.headers[.accessControlAllowHeaders]?.contains("Authorization") == true)
            }
            try await client.execute(uri: "/status", method: .get, headers: [.origin: Self.extensionOrigin]) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], Self.extensionOrigin, "the refusal is readable")
            }
            try await client.execute(
                uri: "/status", method: .get,
                headers: [.origin: Self.extensionOrigin, .authorization: testOperatorAuthorization]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], Self.extensionOrigin)
                XCTAssertEqual(response.headers[.vary], "Origin")
            }
            try await client.execute(
                uri: "/mining/templates", method: .post,
                headers: [
                    .origin: Self.extensionOrigin, .authorization: testOperatorAuthorization,
                    .contentType: "application/json",
                ],
                body: Self.templateBody
            ) { response in
                XCTAssertNotEqual(response.status, .unauthorized)
                XCTAssertNotEqual(response.status, .forbidden)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], Self.extensionOrigin)
            }
            try await client.execute(
                uri: "/status", method: .get,
                headers: [.origin: "chrome-extension://someoneelse", .authorization: testOperatorAuthorization]
            ) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
        }
    }

    func testCookieIsPrivateAndRotatedAtEveryStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-cookie-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".cookie")
        let first = try LoopbackRPCAuth.createCookie(at: file, allowedOrigins: [])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, "__cookie__:\(first.token)")
        XCTAssertEqual(first.token.count, 64)
        XCTAssertTrue(first.accepts("Basic " + Data(content.utf8).base64EncodedString()))

        let second = try LoopbackRPCAuth.createCookie(at: file, allowedOrigins: [])
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "__cookie__:\(second.token)")
        XCTAssertFalse(second.accepts("Bearer \(first.token)"), "a rotated-out cookie never authenticates")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
    }
}
