import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeMiningCoordinator
import LatticeNode
import LatticeNodeAPI

/// A node's operator RPC: the local node's loopback port with the cookie the
/// node writes at every start, which every route but /health requires; or a
/// remote node's operator listener (`--operator-listen`) with a bearer token.
struct NodeRPC: Sendable {
    let cookieFile: URL?
    let token: String?
    private let remoteURL: String?
    private let addressFile: URL?
    private let configuredPort: UInt16

    /// The local node under `layout`, wherever it listens now.
    init(_ topology: Topology, _ layout: HostLayout) {
        self.remoteURL = nil
        self.addressFile = layout.rpcAddress
        self.configuredPort = topology.rpc
        self.cookieFile = layout.rpcCookie
        self.token = nil
    }

    /// A remote node's operator listener, e.g. http://10.0.0.5:8090.
    init(url: String, token: String) {
        self.remoteURL = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.addressFile = nil
        self.configuredPort = 0
        self.cookieFile = nil
        self.token = token
    }

    /// Where the node listens: the remote node's URL; the local node's
    /// own record of its listener, read again each time (a restart may move
    /// it); or, with no record (a node not yet started, or one older than
    /// it), the port lattice.json gives. A record a crashed node left names
    /// a port nothing answers on (refused at once, never waited on), and the
    /// next start replaces it as soon as it holds the storage.
    var baseURL: String {
        if let remoteURL { return remoteURL }
        if let addressFile, let text = try? String(contentsOf: addressFile, encoding: .utf8) {
            let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { return url }
        }
        return "http://127.0.0.1:\(configuredPort)"
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
    func running() async throws -> NodeRPC? {
        if let remote = try remote() { return remote }
        guard localNodeRunning(layout) else { return nil }
        return try await answering(NodeRPC(try Topology.load(root: layout.root), layout))
    }

    /// The running node to ask; an error when the local node is stopped.
    func runningNode() async throws -> NodeRPC {
        guard let rpc = try await running() else { throw CtlError("the node is not running; `lattice up` first") }
        return rpc
    }

    /// The configuration as the node has it, or (stopped) as its files
    /// make it.
    func config() async throws -> ConfigResponse {
        if let rpc = try await running() {
            return try JSONDecoder().decode(ConfigResponse.self, from: try await send(rpc: rpc, "GET", "config"))
        }
        return try stoppedResponse(MergedConfig.load(root: layout.root))
    }

    /// Fragment `name` changed by `edit` (`{}` when there is none yet),
    /// given the configuration as it is. On a running node the change is
    /// sent with the version it was made from (`If-Match`), and made again
    /// from the new one when another writer changed it meanwhile.
    @discardableResult
    func editFragment(
        _ name: String, _ edit: (inout [String: Any], ConfigResponse) throws -> Void
    ) async throws -> ConfigResponse {
        guard let rpc = try await running() else {
            // Read and written under the node's storage lock, so neither a
            // node nor another edit comes in between.
            guard case .stopped(let lock) = localNode(layout) else { throw CtlError("the storage lock is held: the node started meanwhile, or another lattice command holds it; try again") }
            defer { _ = lock }
            var object: [String: Any] = [:]
            let file = ConfigFragments.file(root: layout.root, name: name)
            if FileManager.default.fileExists(atPath: file.path) { object = try ConfigFragments.object(at: file) }
            try edit(&object, stoppedResponse(try MergedConfig.load(root: layout.root)))
            return try saveStopped(name, object)
        }
        let path = "config/fragments/\(name)"
        for _ in 0..<5 {
            let current = try JSONDecoder().decode(ConfigResponse.self, from: try await send(rpc: rpc, "GET", "config"))
            let (status, data, response) = try await exchange(rpc: rpc, "GET", path)
            var object: [String: Any] = [:]
            var version: String?
            switch status {
            case 200..<300:
                object = try ConfigFragments.object(data, named: name)
                version = response?.value(forHTTPHeaderField: "ETag")
            case 404 where !data.isEmpty:
                break // none yet
            default:
                throw failure("GET", path, status, data)
            }
            try edit(&object, current)
            let body = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // The version read, or (none read) that there is none yet.
            let (putStatus, answer, _) = try await exchange(
                rpc: rpc, "PUT", path, json: body, headers: version.map { ["If-Match": $0] } ?? ["If-None-Match": "*"]
            )
            if putStatus == 412 { continue }
            guard (200..<300).contains(putStatus) else { throw failure("PUT", path, putStatus, answer) }
            return try JSONDecoder().decode(ConfigResponse.self, from: answer)
        }
        throw CtlError("\(name) kept changing while it was edited; try again")
    }

    /// Creates the child chain `chain`, once: through a running (or remote)
    /// node's API; on a stopped local node, in its files.
    @discardableResult
    func createChain(_ chain: HostedChain) async throws -> Bool {
        if let rpc = try await running() {
            let body = try JSONEncoder().encode(chain)
            return try JSONDecoder().decode(
                CreatedChainResponse.self, from: try await send(rpc: rpc, "POST", "chains", json: body)
            ).created
        }
        // Under the node's storage lock, so no node starts meanwhile.
        guard case .stopped(let lock) = localNode(layout) else { throw CtlError("the storage lock is held: the node started meanwhile, or another lattice command holds it; try again") }
        defer { _ = lock }
        return try ChainCreation.create(chain, layout: layout)
    }

    /// Replaces fragment `name` with `object`: through a running (or
    /// remote) node's API, which applies it; on a stopped local node, in its
    /// file, once the configuration it makes checks (its next start reads it).
    @discardableResult
    func putFragment(_ name: String, _ object: [String: Any]) async throws -> ConfigResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let rpc = try await running() {
            return try JSONDecoder().decode(
                ConfigResponse.self, from: try await send(rpc: rpc, "PUT", "config/fragments/\(name)", json: data)
            )
        }
        // Under the node's storage lock, so no node starts meanwhile.
        guard case .stopped(let lock) = localNode(layout) else { throw CtlError("the storage lock is held: the node started meanwhile, or another lattice command holds it; try again") }
        defer { _ = lock }
        return try saveStopped(name, object)
    }

    /// Writes fragment `name` of a stopped node, once the configuration it
    /// makes checks; the caller holds the storage lock.
    private func saveStopped(_ name: String, _ object: [String: Any]) throws -> ConfigResponse {
        guard ConfigFragments.isValidName(name) else { throw CtlError("\(name) is not a fragment's name") }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let merged = try MergedConfig.merge(ConfigFragments.layers(root: layout.root, replacing: name, with: object))
        try FileManager.default.createDirectory(at: ConfigFragments.directory(root: layout.root), withIntermediateDirectories: true)
        try writeDurably(data, to: ConfigFragments.file(root: layout.root, name: name))
        print("saved \(ConfigFragments.directoryName)/\(name).json; the node reads it at its next start")
        return stoppedResponse(merged)
    }

    private func stoppedResponse(_ merged: MergedConfig) -> ConfigResponse {
        ConfigResponse(
            spec: merged.topology, fragments: merged.layers,
            status: ConfigStatus(
                chains: merged.tree.status(running: [], errors: [:]),
                pendingRestart: [], errors: [], inert: merged.inert
            )
        )
    }
}

/// The fragment `lattice config set`, `lattice child ...` and the dashboard
/// edit: people's. Layers merge in name order alone, so it comes after
/// `deploy` and `hostmarket` and before any name sorting after it.
let operatorFragment = "operator"

/// Prints what a change left to do, and fails when `chain` (if given) did
/// not start.
func report(_ response: ConfigResponse, chain: String? = nil) throws {
    for note in response.status.inert { print("inert: \(note)") }
    if !response.status.pendingRestart.isEmpty {
        print("waiting for a restart (`lattice restart`): \(response.status.pendingRestart.joined(separator: ", "))")
    }
    if let chain, let error = response.status.chains.first(where: { $0.path == chain })?.error {
        throw CtlError("\(chain): \(error)")
    }
}

/// The local node once it answers: a node just started opens its storage
/// and listener only after a while.
private func answering(_ rpc: NodeRPC) async throws -> NodeRPC {
    let deadline = ContinuousClock.now + .seconds(180)
    var said = false
    while await health(rpc: rpc) == nil {
        guard ContinuousClock.now < deadline else {
            throw CtlError("the node runs but does not answer on its RPC port; see `lattice logs`")
        }
        if !said {
            FileHandle.standardError.write(Data("waiting for the node to answer\n".utf8))
            said = true
        }
        try await Task.sleep(for: .milliseconds(250))
    }
    return rpc
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

/// The local node, by its storage lock: held while a node runs on it.
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
/// bytes, failing on anything but 2xx with the node's message.
@discardableResult
func send(
    rpc: NodeRPC, _ method: String, _ path: String, json body: Data? = nil,
    contentType: String = "application/json"
) async throws -> Data {
    let (status, data, _) = try await exchange(rpc: rpc, method, path, json: body, contentType: contentType)
    if (200..<300).contains(status) { return data }
    throw failure(method, path, status, data)
}

/// One request and its answer as it came: status, body and headers.
func exchange(
    rpc: NodeRPC, _ method: String, _ path: String, json body: Data? = nil,
    contentType: String = "application/json", headers: [String: String] = [:]
) async throws -> (status: Int, data: Data, response: HTTPURLResponse?) {
    var request = try rpc.request(path)
    request.httpMethod = method
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    if let body {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as? HTTPURLResponse
    return (http?.statusCode ?? 0, data, http)
}

/// The error a refused request reads as.
func failure(_ method: String, _ path: String, _ status: Int, _ data: Data) -> CtlError {
    if status == 404, (String(data: data, encoding: .utf8) ?? "").isEmpty {
        return CtlError("\(method) /\(path): this node does not have that route; it predates this lattice (upgrade lattice-node)")
    }
    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        ?? String(decoding: data.prefix(512), as: UTF8.self)
    return CtlError("\(method) /\(path) failed: HTTP \(status) \(message)")
}
