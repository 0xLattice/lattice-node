import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LatticeCtlCore
import LatticeMiningCoordinator

/// The local node's loopback RPC: its port, and the cookie the node writes
/// at every start, which every route but /health requires.
struct NodeRPC: Sendable {
    let port: UInt16
    let cookieFile: URL

    init(port: UInt16, cookieFile: URL) {
        self.port = port
        self.cookieFile = cookieFile
    }

    init(_ topology: Topology, _ layout: HostLayout) {
        self.init(port: topology.rpc, cookieFile: layout.rpcCookie)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// A request to `path`, naming a child chain with `?chainPath=`, carrying
    /// the cookie as it is now (re-read: a restarted node rotated it).
    func request(_ path: String, chain: String = "Nexus") throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/\(path)" + (chain == "Nexus" ? "" : "?chainPath=\(chain)")) else {
            throw CtlError("bad RPC URL")
        }
        var request = URLRequest(url: url)
        if let authorization = rpcCookieAuthorization(file: cookieFile) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// POST a JSON body to the local node and decode its answer.
func post<Body: Encodable, Response: Decodable>(
    rpc: NodeRPC, path: String, body: Body
) async throws -> Response {
    var request = try rpc.request(path)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = String(decoding: data.prefix(512), as: UTF8.self)
        throw CtlError("\(path) failed: HTTP \(status) \(detail)")
    }
    return try JSONDecoder().decode(Response.self, from: data)
}

