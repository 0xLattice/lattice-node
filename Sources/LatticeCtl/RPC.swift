import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeCtlCore
import LatticeMiningCoordinator
import LatticeNode

/// A node's operator RPC: the local node's loopback port with the cookie the
/// node writes at every start, which every route but /health requires; or a
/// remote node's operator listener (`--operator-listen`) with a bearer token.
struct NodeRPC: Sendable {
    let baseURL: String
    let cookieFile: URL?
    let token: String?

    init(port: UInt16, cookieFile: URL) {
        self.baseURL = "http://127.0.0.1:\(port)"
        self.cookieFile = cookieFile
        self.token = nil
    }

    init(_ topology: Topology, _ layout: HostLayout) {
        self.init(port: topology.rpc, cookieFile: layout.rpcCookie)
    }

    /// A remote node's operator listener, e.g. http://10.0.0.5:8090.
    init(url: String, token: String) {
        self.baseURL = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.cookieFile = nil
        self.token = token
    }

    /// A request to `path`, naming a child chain with `?chainPath=`, carrying
    /// the cookie as it is now (re-read: a restarted node rotated it).
    func request(_ path: String, chain: String = "Nexus") throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/\(path)" + (chain == "Nexus" ? "" : "?chainPath=\(chain)")) else {
            throw CtlError("bad RPC URL")
        }
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let cookieFile, let authorization = rpcCookieAuthorization(file: cookieFile) {
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


/// GET the local node's JSON answer for `path`, on `chain`.
func get<Response: Decodable>(rpc: NodeRPC, path: String, chain: String) async throws -> Response {
    var request = try rpc.request(path, chain: chain)
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        throw CtlError("\(path) failed: HTTP \(status) \(String(decoding: data.prefix(512), as: UTF8.self))")
    }
    return try JSONDecoder().decode(Response.self, from: data)
}

/// Which node a command operates: the local one under `--root` (its loopback
/// API and cookie), or with `--node` and `--token-file` a remote one's
/// operator listener.
struct NodeTarget: ParsableArguments {
    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "A node's operator listener (its operatorListen), e.g. http://10.0.0.5:8090, instead of the local node under --root. Requires --token-file.")
    var node: String?

    @Option(name: .long, help: "A file holding the bearer token for --node.")
    var tokenFile: String?

    var layout: HostLayout { rootOption.layout }

    func validate() throws {
        guard (node == nil) == (tokenFile == nil) else {
            throw ValidationError("--node and --token-file go together")
        }
    }

    /// The remote node, or nil for the local one.
    func remote() throws -> NodeRPC? {
        guard let node, let tokenFile else { return nil }
        let token = try String(contentsOf: URL(fileURLWithPath: tokenFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CtlError("--token-file \(tokenFile) is empty") }
        return NodeRPC(url: node, token: token)
    }

    /// The node to ask: the remote one, or the local one while it runs.
    func running() throws -> NodeRPC? {
        if let remote = try remote() { return remote }
        guard localNodeRunning(layout) else { return nil }
        return NodeRPC(try Topology.load(root: layout.root), layout)
    }

    /// The running node to ask; an error when the local node is stopped.
    func runningNode() throws -> NodeRPC {
        guard let rpc = try running() else { throw CtlError("the node is not running; `lattice up` first") }
        return rpc
    }

    /// A change to the node's configuration: sent to a running (or remote)
    /// node, which applies it and writes lattice.json; made to the file
    /// itself while the local node is stopped (its next start reads it).
    func changeConfig(
        api: (NodeRPC) async throws -> Void,
        stopped: (inout Topology) throws -> Void
    ) async throws {
        if let remote = try remote() { return try await api(remote) }
        let layout = layout
        let local: NodeRPC? = try await withSpawnLock(layout) {
            guard case .stopped(let lock) = localNode(layout) else {
                return NodeRPC(try Topology.load(root: layout.root), layout)
            }
            var topology = try Topology.load(root: layout.root)
            try stopped(&topology)
            try topology.validated().save(root: layout.root)
            _ = lock
            return nil
        }
        if let local { try await api(local) }
    }
}

/// Whether a node holds the local tree's storage.
func localNodeRunning(_ layout: HostLayout) -> Bool {
    if case .running = localNode(layout) { return true }
    return false
}

enum LocalNode {
    case running
    /// Stopped: its storage lock, held for the caller while it edits what a
    /// running node would own (nil when no node ever made the storage).
    case stopped(StorageDirectoryLock?)
}

/// The local node, by its storage lock. Callers that edit hold the spawn
/// lock too, so no `up` starts a node meanwhile.
func localNode(_ layout: HostLayout) -> LocalNode {
    let directory = layout.chainDirectory(for: ChainAddress.nexus)
    guard FileManager.default.fileExists(atPath: directory.path) else { return .stopped(nil) }
    do {
        return .stopped(try StorageDirectoryLock(directory: directory))
    } catch {
        return .running
    }
}

/// Sends `body` (JSON) to `path` with `method` and returns the answer's
/// bytes, failing on anything but 2xx with the node's message. A
/// configuration change's answer is returned on 500 too: its body says what
/// failed.
@discardableResult
func send(
    rpc: NodeRPC, _ method: String, _ path: String, json body: Data? = nil,
    contentType: String = "application/json", acceptFailedChange: Bool = false
) async throws -> Data {
    var request = try rpc.request(path)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    if let body {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if (200..<300).contains(status) || (acceptFailedChange && status == 500
        && (try? JSONDecoder().decode(ConfigChangeResponse.self, from: data)) != nil) {
        return data
    }
    if status == 404, (String(data: data, encoding: .utf8) ?? "").isEmpty {
        throw CtlError("\(method) /\(path): this node does not have that route; it predates this lattice (upgrade lattice-node)")
    }
    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        ?? String(decoding: data.prefix(512), as: UTF8.self)
    throw CtlError("\(method) /\(path) failed: HTTP \(status) \(message)")
}

/// A configuration change sent to `rpc`, its outcome printed; throws when a
/// part of it failed.
func sendChange(rpc: NodeRPC, _ method: String, _ path: String, json body: Data? = nil, contentType: String = "application/json") async throws {
    let data = try await send(rpc: rpc, method, path, json: body, contentType: contentType, acceptFailedChange: true)
    let change = try JSONDecoder().decode(ConfigChangeResponse.self, from: data)
    if !change.applied.isEmpty { print("applied: \(change.applied.joined(separator: ", "))") }
    if !change.restartRequired.isEmpty {
        print("waiting for a restart (`lattice restart`): \(change.restartRequired.joined(separator: ", "))")
    }
    guard change.failed.isEmpty else {
        throw CtlError(change.failed.map { "failed: \($0.key)\($0.chain.map { " " + $0 } ?? ""): \($0.error)" }
            .joined(separator: "\n"))
    }
}
