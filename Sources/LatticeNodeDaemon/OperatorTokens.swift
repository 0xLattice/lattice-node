import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import LatticeCtlCore

/// The remote operator listener's credentials (`--operator-tokens`): bearer
/// tokens, each with a role or a list of the routes it may use. The file
/// holds only each token's SHA-256, so reading it does not reveal a token:
///
/// ```json
/// [{ "name": "ops", "sha256": "<hex>", "role": "admin" },
///  { "name": "seller", "sha256": "<hex>", "routes": ["GET /hosted-chains", "POST /hosted-chains"] }]
/// ```
///
/// `admin` may use every route, `read` every GET; a route is the method and
/// the path as the node registers it, a path parameter in braces: `GET
/// /fetch/{cid}`. A request names its chain with `?chainPath=`, which a
/// route does not restrict. Only `admin` manages tokens (`/tokens`), whatever
/// a list names.
struct OperatorTokens: Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let sha256: String
        var role: String?
        var routes: [String]?

        init(name: String, sha256: String, role: String? = nil, routes: [String]? = nil) {
            self.name = name
            self.sha256 = sha256
            self.role = role
            self.routes = routes
        }

        /// Whether this token may use `METHOD path`.
        func allows(method: String, path: String) -> Bool {
            switch role {
            case "admin": return true
            case "read": return (method == "GET" || method == "HEAD") && !path.hasPrefix("/tokens")
            default:
                guard !path.hasPrefix("/tokens") else { return false }
                return (routes ?? []).contains { $0.uppercasedMethod == "\(method) \(path)" }
            }
        }
    }

    static let roles = ["admin", "read"]

    let entries: [Entry]
    /// Each token's entry, by the lowercase hex of its SHA-256.
    let byHash: [String: Entry]

    init(_ entries: [Entry]) throws {
        var byHash: [String: Entry] = [:]
        var names: Set<String> = []
        for entry in entries {
            try Self.check(entry)
            let hash = entry.sha256.lowercased()
            guard byHash[hash] == nil else {
                throw ValidationError("operator token \(entry.name): its sha256 is listed twice")
            }
            guard names.insert(entry.name).inserted else {
                throw ValidationError("operator token \(entry.name) is listed twice")
            }
            byHash[hash] = entry
        }
        self.entries = entries
        self.byHash = byHash
    }

    static func check(_ entry: Entry) throws {
        guard !entry.name.isEmpty, !entry.name.contains("/") else {
            throw ValidationError("operator token name \"\(entry.name)\" must be nonempty and have no /")
        }
        let hash = entry.sha256.lowercased()
        guard hash.count == 64, Data(hex: hash) != nil else {
            throw ValidationError("operator token \(entry.name): sha256 must be 64 hexadecimal characters")
        }
        guard (entry.role == nil) != (entry.routes == nil) else {
            throw ValidationError("operator token \(entry.name): give a role (\(roles.joined(separator: " or "))) or routes, not both")
        }
        if let role = entry.role, !roles.contains(role) {
            throw ValidationError("operator token \(entry.name): role is \(roles.joined(separator: " or ")), not \(role)")
        }
        for route in entry.routes ?? [] {
            let parts = route.split(separator: " ")
            guard parts.count == 2, parts[1].hasPrefix("/") else {
                throw ValidationError("operator token \(entry.name): route \"\(route)\" is not METHOD /path")
            }
        }
    }

    /// The tokens `file` lists; none when it does not exist yet (the first
    /// `POST /tokens` creates it).
    static func load(file: URL) throws -> OperatorTokens {
        guard FileManager.default.fileExists(atPath: file.path) else { return try OperatorTokens([]) }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } catch {
            throw ValidationError("--operator-tokens \(file.path): \(error)")
        }
        return try OperatorTokens(entries)
    }

    /// The entry an `Authorization: Bearer <token>` value names, or nil.
    func entry(for authorization: String?) -> Entry? {
        guard let authorization else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return byHash[Self.hash(parts[1].trimmingCharacters(in: .whitespaces))]
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The token file the remote operator listener reads, changed through the
/// API (`POST` / `DELETE /tokens`): each change is written to the file
/// (atomically, mode 0600) and applies from the next request.
final class TokenStore: @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    private var tokens: OperatorTokens

    init(file: URL) throws {
        self.file = file
        self.tokens = try OperatorTokens.load(file: file)
    }

    /// Over tokens given directly, for tests.
    init(_ tokens: OperatorTokens, file: URL) {
        self.file = file
        self.tokens = tokens
    }

    var count: Int { lock.withLock { tokens.entries.count } }

    func entry(for authorization: String?) -> OperatorTokens.Entry? {
        lock.withLock { tokens.entry(for: authorization) }
    }

    func list() -> TokensResponse {
        lock.withLock {
            TokensResponse(tokens: tokens.entries.map { .init(name: $0.name, role: $0.role, routes: $0.routes) })
        }
    }

    /// A new token named `request.name`; its secret is returned this once.
    func create(_ request: CreateTokenRequest) throws -> CreateTokenResponse {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let entry = OperatorTokens.Entry(
            name: request.name, sha256: OperatorTokens.hash(token), role: request.role, routes: request.routes
        )
        try OperatorTokens.check(entry)
        try lock.withLock {
            guard !tokens.entries.contains(where: { $0.name == request.name }) else {
                throw HTTPError(.conflict, message: "a token named \(request.name) exists; revoke it first")
            }
            try save(OperatorTokens(tokens.entries + [entry]))
        }
        return CreateTokenResponse(name: request.name, token: token)
    }

    /// Revokes the token named `name`; false when there is none.
    func revoke(_ name: String) throws -> Bool {
        try lock.withLock {
            guard tokens.entries.contains(where: { $0.name == name }) else { return false }
            try save(OperatorTokens(tokens.entries.filter { $0.name != name }))
            return true
        }
    }

    /// Writes `next` and only then uses it: a token the file does not hold
    /// is never accepted.
    private func save(_ next: OperatorTokens) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporary)
        guard (try? writePrivateFile(try encoder.encode(next.entries), to: temporary.path)) != nil,
              rename(temporary.path, file.path) == 0 else {
            throw HTTPError(.internalServerError, message: "could not write \(file.path)")
        }
        tokens = next
    }
}

/// The remote operator application's first middleware: the browser origin
/// policy (an `Origin` the operator did not list is refused; a listed one
/// gets CORS answers), then a known bearer token (401 otherwise), then the
/// route among what the token may use (403 otherwise). The loopback cookie
/// is not a token here. Hummingbird resolves the route before its
/// middleware runs, so `endpointPath` is the registered path; a path that
/// matches no route has none, and only `admin` gets past to its 404.
struct OperatorTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let tokens: TokenStore
    let allowedOrigins: Set<String>

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // No Origin, or the dashboard this listener served calling back.
        guard let origin = request.headers[.origin], !isSameOrigin(origin, as: request) else {
            try authorize(request, context: context)
            return try await next(request, context)
        }
        guard allowedOrigins.contains(origin) else {
            throw HTTPError(.forbidden, message: "origin not allowed on the operator listener")
        }
        let cors: HTTPFields = [.accessControlAllowOrigin: origin, .vary: "Origin"]
        if request.method == .options {
            // A preflight carries no credentials; it only learns what the
            // real request may send.
            var headers = cors
            headers[.accessControlAllowMethods] = "GET, HEAD, POST, PATCH, DELETE"
            headers[.accessControlAllowHeaders] = "Authorization, Content-Type"
            headers[.accessControlMaxAge] = "600"
            return Response(status: .noContent, headers: headers)
        }
        do {
            try authorize(request, context: context)
            var response = try await next(request, context)
            response.headers.append(contentsOf: cors)
            return response
        } catch let error as any HTTPResponseError {
            // The listed origin must be able to read a refusal, too.
            var response = try error.response(from: request, context: context)
            response.headers.append(contentsOf: cors)
            return response
        }
    }

    private func authorize(_ request: Request, context: Context) throws {
        // The dashboard's own files hold no data; what the page then asks
        // for carries a token.
        if Dashboard.isAsset(request) { return }
        guard let entry = tokens.entry(for: request.headers[.authorization]) else {
            throw HTTPError(.unauthorized, message: "the operator listener requires a bearer token")
        }
        let path = context.endpointPath ?? ""
        guard context.endpointPath != nil || entry.role == "admin",
              entry.allows(method: request.method.rawValue, path: path) else {
            throw HTTPError(.forbidden, message: "token \(entry.name) may not use \(request.method.rawValue) \(path)")
        }
    }
}

private extension String {
    /// `get /x` as `GET /x`: a method is matched without regard to case.
    var uppercasedMethod: String {
        guard let space = firstIndex(of: " ") else { return self }
        return self[..<space].uppercased() + self[space...]
    }
}
