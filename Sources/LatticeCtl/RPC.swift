import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LatticeCtlCore

/// POST a JSON body to the local node and decode its answer.
func post<Body: Encodable, Response: Decodable>(
    rpc: UInt16, path: String, body: Body
) async throws -> Response {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/\(path)") else {
        throw CtlError("bad RPC URL")
    }
    var request = URLRequest(url: url)
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

