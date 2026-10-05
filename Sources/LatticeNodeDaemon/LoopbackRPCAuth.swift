import Foundation
import Hummingbird

/// Loopback RPC authentication, bitcoind-style: at every start the node writes
/// a fresh random cookie file (mode 0600) and every route on the loopback
/// port requires it, except `GET`/`HEAD /health` (public chain status, also
/// served by the public read listener; left open so container and process
/// health probes need no secret).
///
/// A client proves it can read the cookie file in either of two conventional
/// forms:
/// - `Authorization: Basic base64("__cookie__:<token>")` — the file's whole
///   content as user:password, exactly what bitcoind's cookie is;
/// - `Authorization: Bearer <token>` — the part after `__cookie__:`.
///
/// Browsers are refused by default: any request carrying an `Origin` header is
/// answered 403 unless the operator listed that exact origin
/// (`--rpc-allowed-origin`, e.g. `chrome-extension://<id>`). A listed origin
/// gets CORS preflight answers and `Access-Control-Allow-Origin` on its
/// responses, and still needs the cookie.
struct LoopbackRPCAuth: Sendable {
    static let cookieUser = "__cookie__"

    /// The secret after `__cookie__:`.
    let token: String
    let allowedOrigins: Set<String>

    /// Writes a fresh cookie to `file` (replacing any earlier one) and returns
    /// the auth that accepts it.
    static func createCookie(at file: URL, allowedOrigins: [String]) throws -> LoopbackRPCAuth {
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Written under a temporary name created 0600 and renamed into place:
        // the secret is never readable by anyone else, not even briefly, and a
        // reader never sees a half-written file.
        let temporary = file.appendingPathExtension("tmp")
        unlink(temporary.path)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let content = Array("\(cookieUser):\(token)".utf8)
        let written = content.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == content.count, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return LoopbackRPCAuth(token: token, allowedOrigins: Set(allowedOrigins))
    }

    /// Whether an `Authorization` header value carries this cookie.
    func accepts(_ authorization: String?) -> Bool {
        guard let authorization else { return false }
        let parts = authorization.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let presented: String
        switch parts[0].lowercased() {
        case "bearer":
            presented = "\(Self.cookieUser):\(parts[1].trimmingCharacters(in: .whitespaces))"
        case "basic":
            guard let data = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            presented = String(decoding: data, as: UTF8.self)
        default:
            return false
        }
        return constantTimeEqual(Array(presented.utf8), Array("\(Self.cookieUser):\(token)".utf8))
    }

    private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

/// The loopback application's first middleware: origin policy, CORS for the
/// operator-listed origins, then the cookie check.
struct LoopbackRPCAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let auth: LoopbackRPCAuth

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let origin = request.headers[.origin] else {
            try authorize(request)
            return try await next(request, context)
        }
        guard auth.allowedOrigins.contains(origin) else {
            throw HTTPError(.forbidden, message: "origin not allowed on the operator RPC port")
        }
        let cors: HTTPFields = [.accessControlAllowOrigin: origin, .vary: "Origin"]
        if request.method == .options {
            // A preflight carries no credentials; it only learns what the real
            // request may send.
            var headers = cors
            headers[.accessControlAllowMethods] = "GET, HEAD, POST"
            headers[.accessControlAllowHeaders] = "Authorization, Content-Type"
            headers[.accessControlMaxAge] = "600"
            return Response(status: .noContent, headers: headers)
        }
        do {
            try authorize(request)
            var response = try await next(request, context)
            response.headers.append(contentsOf: cors)
            return response
        } catch let error as any HTTPResponseError {
            // The listed origin must be able to read a refusal, too.
            var response = try error.response(from: request, context: context)
            response.headers.append(contentsOf: cors)
            return response
        } catch {
            return Response(status: .internalServerError, headers: cors)
        }
    }

    private func authorize(_ request: Request) throws {
        if request.method == .get || request.method == .head, request.uri.path == "/health" { return }
        guard auth.accepts(request.headers[.authorization]) else {
            throw HTTPError(
                .unauthorized,
                headers: [.wwwAuthenticate: #"Basic realm="lattice-node""#],
                message: "operator RPC requires the node's cookie"
            )
        }
    }
}
