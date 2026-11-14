import ArgumentParser
import Crypto
import Foundation
import Hummingbird

/// The remote operator listener's credentials (`--operator-tokens`): bearer
/// tokens, each scoped to the routes its entry lists. The file holds only
/// each token's SHA-256, so reading it does not reveal a token:
///
/// ```json
/// [{ "name": "seller", "sha256": "<hex>", "routes": ["GET /hosted-chains", "POST /hosted-chains"] }]
/// ```
///
/// A route is the method and the path as the node registers it, a path
/// parameter in braces: `GET /fetch/{cid}`. A request names its chain with
/// `?chainPath=`, which a route does not restrict.
struct OperatorTokens: Sendable {
    struct Entry: Codable, Sendable {
        let name: String
        let sha256: String
        let routes: [String]
    }

    /// Each token's entry, by the lowercase hex of its SHA-256.
    let byHash: [String: Entry]

    init(_ entries: [Entry]) throws {
        var byHash: [String: Entry] = [:]
        for entry in entries {
            let hash = entry.sha256.lowercased()
            guard hash.count == 64, Data(hex: hash) != nil else {
                throw ValidationError("operator token \(entry.name): sha256 must be 64 hexadecimal characters")
            }
            guard byHash[hash] == nil else {
                throw ValidationError("operator token \(entry.name): its sha256 is listed twice")
            }
            for route in entry.routes {
                let parts = route.split(separator: " ")
                guard parts.count == 2, parts[1].hasPrefix("/") else {
                    throw ValidationError("operator token \(entry.name): route \"\(route)\" is not METHOD /path")
                }
            }
            byHash[hash] = entry
        }
        self.byHash = byHash
    }

    static func load(file: URL) throws -> OperatorTokens {
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
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return byHash[hash]
    }
}

/// The remote operator application's first middleware: a known bearer token
/// (401 otherwise), then the route in its list (403 otherwise). The loopback
/// cookie is not a token here. Hummingbird resolves the route before its
/// middleware runs, so `endpointPath` is the registered path; a path that
/// matches no route has none and is in no list.
struct OperatorTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let tokens: OperatorTokens

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let entry = tokens.entry(for: request.headers[.authorization]) else {
            throw HTTPError(.unauthorized, message: "the operator listener requires a bearer token")
        }
        let route = "\(request.method.rawValue) \(context.endpointPath ?? "")"
        guard context.endpointPath != nil,
              entry.routes.contains(where: { $0.uppercasedMethod == route }) else {
            throw HTTPError(.forbidden, message: "token \(entry.name) may not use \(route)")
        }
        return try await next(request, context)
    }
}

private extension String {
    /// `get /x` as `GET /x`: a method is matched without regard to case.
    var uppercasedMethod: String {
        guard let space = firstIndex(of: " ") else { return self }
        return self[..<space].uppercased() + self[space...]
    }
}
