import Lattice
import LatticeNodeRPCFuzzSupport
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession/URLRequest live here on Linux
#endif
import Hummingbird
import HTTPTypes
import LatticeNodeAuth
import cashew
import VolumeBroker
import UInt256
import Logging
import Synchronization
import ServiceLifecycle

private enum RPCProxyError: Error {
    case responseTooLarge
    case missingResponse
}

private final class RPCProxyResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func start(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maxBytes) {
            finish(.failure(RPCProxyError.responseTooLarge))
            completionHandler(.cancel)
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        var shouldCancel = false
        lock.lock()
        data.append(chunk)
        if data.count > maxBytes {
            shouldCancel = true
        }
        lock.unlock()

        if shouldCancel {
            finish(.failure(RPCProxyError.responseTooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()

        guard let response else {
            finish(.failure(RPCProxyError.missingResponse))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public final class RPCServer: Sendable {
    private let app: Application<RouterResponder<RPCRequestContext>>
    private let _serviceGroup: Mutex<ServiceGroup?>

    public init(node: LatticeNode, port: UInt16 = 8080, bindAddress: String = "127.0.0.1", allowedOrigin: String = "http://127.0.0.1", auth: CookieAuth? = nil, trustProxyHeaders: Bool = false) {
        let router = RPCRoutes.build(node: node, trustProxyHeaders: trustProxyHeaders, allowedOrigin: allowedOrigin, auth: auth)
        self.app = Application(router: router, configuration: .init(address: .hostname(bindAddress, port: Int(port))))
        self._serviceGroup = Mutex(nil)
    }

    public func run() async throws {
        let group = ServiceGroup(
            configuration: .init(services: [app], logger: .init(label: "lattice.rpc"))
        )
        _serviceGroup.withLock { $0 = group }
        try await group.run()
    }

    public func shutdown() async {
        let group = _serviceGroup.withLock { $0 }
        await group?.triggerGracefulShutdown()
    }
}

// MARK: - Routes

enum RPCRoutes {
    static let log = Logger(label: "lattice.rpc")
    static let sseStreamBufferLimit = 256

    static func build(node: LatticeNode, trustProxyHeaders: Bool = false, allowedOrigin: String = "http://127.0.0.1", auth: CookieAuth? = nil) -> Router<RPCRequestContext> {
        let router = Router(context: RPCRequestContext.self)
        // All middleware MUST be added before routes — Hummingbird only applies
        // middleware to routes registered after the middleware.add() call.
        // SECURITY: never reflect an arbitrary caller Origin. A wildcard "*" is
        // treated as "no allowlist configured": emit no Access-Control-Allow-Origin
        // (instead of Hummingbird's reflecting `.originBased` or the cross-site-read
        // wildcard `.all`). Only an explicit origin gets a fixed `.custom` allow value.
        let corsOrigin: CORSMiddleware<RPCRequestContext>.AllowOriginExtended = allowedOrigin == "*" ? .none : .custom(allowedOrigin)
        router.middlewares.add(CORSMiddleware(allowOrigin: corsOrigin, allowHeaders: [.contentType, .authorization], allowMethods: [.get, .post, .options]))
        router.middlewares.add(RateLimitMiddleware(limiter: node.rateLimiter, trustProxyHeaders: trustProxyHeaders))
        router.middlewares.add(RejectBareChainMiddleware())
        let api = router.group("api")

        api.get("chain/info") { _, _ in try await chainInfo(node: node) }
        api.get("chain/map") { _, _ in try await chainMap(node: node) }
        api.get("chain/children") { req, _ in try await chainChildren(node: node, request: req) }
        api.get("chain/endpoints") { req, _ in try await chainEndpoints(node: node, request: req) }
        api.post("chain/register-rpc") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/register-rpc") {
                return denied
            }
            return try await registerChainRPC(node: node, request: req)
        }
        api.post("chain/unregister-rpc") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/unregister-rpc") {
                return denied
            }
            return try await unregisterChainRPC(node: node, request: req)
        }
        api.post("chain/follow") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/follow") {
                return denied
            }
            return try await followChain(node: node, request: req)
        }
        api.get("chain/genesis") { req, _ in try await chainGenesis(node: node, request: req) }
        // Contract 3 (RPC liveness): an authenticated GET that returns 200 iff the
        // presented cookie is the one this process accepts. A supervising parent probes
        // this on restart to tell "child alive, auth valid" (adopt) from "child alive,
        // stale auth" (re-read cookie) from "child dead" (connection error → recover).
        api.get("chain/auth-check") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/auth-check") {
                return denied
            }
            return json(["ok": true])
        }
        api.get("chain/parent-height") { req, _ in try await parentChainHeight(node: node, request: req) }
        api.get("chain/spec") { req, _ in try await chainSpec(node: node, request: req) }
        api.post("chain/template") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/template") {
                return denied
            }
            return try await chainTemplate(node: node, request: req)
        }
        api.post("chain/submit-work") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/submit-work") {
                return denied
            }
            return try await submitWork(node: node, request: req)
        }
        api.post("chain/submit-child-block") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/submit-child-block") {
                return denied
            }
            return try await submitChildBlock(node: node, request: req)
        }
        api.post("chain/parent-continuity") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/parent-continuity") {
                return denied
            }
            return await parentContinuity(node: node, request: req)
        }
        api.post("chain/candidate") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/candidate") {
                return denied
            }
            return try await chainCandidate(node: node, request: req)
        }
        api.get("chain/candidate") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/candidate") {
                return denied
            }
            return try await chainCandidate(node: node, request: req)
        }
        api.get("balance/{address}") { req, ctx in try await getBalance(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("block/latest") { req, _ in try await latestBlock(node: node, request: req) }
        api.get("block/{id}") { req, ctx in try await getBlock(node: node, id: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/transactions") { req, ctx in try await getBlockTransactions(node: node, id: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/children") { req, ctx in try await getBlockChildren(node: node, id: ctx.parameters.require("id"), request: req) }
        api.post("transaction") { req, _ in try await submitTransaction(node: node, request: req) }
        api.post("transaction/prepare") { req, _ in try await prepareTransaction(node: node, request: req) }
        api.get("mempool") { req, _ in try await mempool(node: node, request: req) }
        api.get("proof/{address}") { req, ctx in try await balanceProof(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("peers") { req, _ in try await getPeers(node: node, request: req) }

        api.get("fee/estimate") { req, _ in try await feeEstimate(node: node, request: req) }
        api.get("fee/histogram") { req, _ in try await feeHistogram(node: node, request: req) }
        api.get("nonce/{address}") { req, ctx in try await getNonce(node: node, address: ctx.parameters.require("address"), request: req) }

        api.get("receipt/{txCID}") { req, ctx in try await getReceipt(node: node, txCID: ctx.parameters.require("txCID"), request: req) }
        api.get("transaction/{txCID}") { req, ctx in try await getTransaction(node: node, txCID: ctx.parameters.require("txCID"), request: req) }
        api.get("transactions/{address}") { req, ctx in try await getTransactionHistory(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("finality/{height}") { req, ctx in try await getFinality(node: node, height: ctx.parameters.require("height"), request: req) }
        api.get("finality/config") { _, _ in try await getFinalityConfig(node: node) }
        api.get("block/{id}/state") { req, ctx in try await getBlockState(node: node, blockId: ctx.parameters.require("id"), request: req) }
        api.get("block/{id}/state/account/{address}") { req, ctx in try await getBlockAccountState(node: node, blockId: ctx.parameters.require("id"), address: ctx.parameters.require("address"), request: req) }
        let light = api.group("light")
        light.get("headers") { req, _ in try await lightHeaders(node: node, request: req) }
        light.get("proof/{address}") { req, ctx in try await lightProof(node: node, address: ctx.parameters.require("address"), request: req) }

        // deployChain is a destructive admin operation. It requires a valid RPC
        // cookie credential regardless of bind address; loopback is not auth.
        api.post("chain/deploy") { req, _ in
            if let denied = requireAdminAccess(request: req, auth: auth, endpoint: "chain/deploy") {
                return denied
            }
            return try await deployChain(node: node, request: req)
        }

        // State explorer
        api.get("state/account/{address}") { req, ctx in try await getAccountState(node: node, address: ctx.parameters.require("address"), request: req) }
        api.get("state/summary") { req, _ in try await getStateSummary(node: node, request: req) }

        // Swap state queries
        api.get("deposit") { req, _ in try await getDepositState(node: node, request: req) }
        api.get("deposits") { req, _ in try await listDeposits(node: node, request: req) }
        api.get("receipt-state") { req, _ in try await getReceiptState(node: node, request: req) }

        // Health check
        router.get("health") { _, _ in try await healthCheck(node: node) }

        // Serve static files for the web UI (if dist/ exists next to the binary)
        router.get("") { _, _ in
            return Response(status: .temporaryRedirect, headers: HTTPFields([HTTPField(name: .location, value: "/app/")]))
        }

        router.get("metrics") { _, _ in try await metricsEndpoint(node: node) }

        router.get("ws") { req, ctx in
            // Derive the per-client SSE key the same way the rate limiter does, so
            // behind a trusted reverse proxy each forwarded client gets its own
            // per-client subscription bucket instead of all collapsing onto the
            // single proxy connection IP. Without a trusted proxy this falls back
            // to the per-connection source IP.
            let clientKey = RPCClientIP.extract(
                from: req.headers,
                trustProxyHeaders: trustProxyHeaders,
                connectionIP: ctx.sourceIP
            )
            return try await wsUpgrade(node: node, request: req, clientKey: clientKey)
        }

        return router
    }

    // MARK: - JSON Helpers

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let jsonDecoder = JSONDecoder()
    static let maxProxiedRPCResponseBytes = 4_194_304
    static let proxiedRPCRequestTimeout: TimeInterval = 15

    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? jsonEncoder.encode(value)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
    }

    static func jsonError(_ message: String, status: HTTPResponse.Status = .badRequest) -> Response {
        struct E: Encodable { let error: String }
        log.warning("RPC error: \(message)")
        return json(E(error: message), status: status)
    }

    static func status(from code: Int) -> HTTPResponse.Status {
        switch code {
        case 200: return .ok
        case 201: return .created
        case 202: return .accepted
        case 204: return .noContent
        case 301: return .movedPermanently
        case 302: return .found
        case 303: return .seeOther
        case 304: return .notModified
        case 307: return .temporaryRedirect
        case 308: return .permanentRedirect
        case 400: return .badRequest
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 429: return .tooManyRequests
        case 500: return .internalServerError
        case 503: return .serviceUnavailable
        default: return code >= 200 && code < 300 ? .ok : .internalServerError
        }
    }

    static func proxyRegisteredRPC(
        endpoint: String,
        request: Request,
        authToken: String? = nil,
        body: Data? = nil
    ) async -> Response {
        // endpoint is an API-base URL (e.g. http://child/api); request.uri begins /api/...
        // Strip the leading /api so concatenation yields http://child/api/chain/... not /api/api/chain/...
        let rawURI = String(describing: request.uri)
        let proxiedPath = rawURI.hasPrefix("/api") ? String(rawURI.dropFirst(4)) : rawURI
        guard let url = URL(string: endpoint + proxiedPath) else {
            return jsonError("Invalid registered RPC endpoint", status: .serviceUnavailable)
        }
        var out = URLRequest(url: url)
        out.httpMethod = String(describing: request.method)
        if let body {
            out.httpBody = body
            out.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authToken {
            out.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        out.timeoutInterval = proxiedRPCRequestTimeout
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = proxiedRPCRequestTimeout
            configuration.timeoutIntervalForResource = proxiedRPCRequestTimeout
            let collector = RPCProxyResponseCollector(maxBytes: maxProxiedRPCResponseBytes)
            let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await withCheckedThrowingContinuation { continuation in
                collector.start(continuation)
                session.dataTask(with: out).resume()
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 502
            var headers = HTTPFields()
            if let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") {
                headers.append(HTTPField(name: .contentType, value: mime))
            }
            return Response(status: status(from: code), headers: headers, body: .init(byteBuffer: .init(data: data)))
        } catch RPCProxyError.responseTooLarge {
            return jsonError("Registered RPC endpoint response too large", status: .serviceUnavailable)
        } catch {
            return jsonError("Registered RPC endpoint unavailable: \(error)", status: .serviceUnavailable)
        }
    }

    static func proxyRegisteredRPCIfRemote(
        node: LatticeNode,
        request: Request,
        chainPath: [String],
        body: Data? = nil
    ) async -> Response? {
        guard await node.network(forPath: chainPath) == nil,
              let endpoint = await node.registeredRPCEndpoint(chainPath: chainPath) else {
            return nil
        }
        let authToken = await node.registeredRPCAuthToken(chainPath: chainPath)
        return await proxyRegisteredRPC(endpoint: endpoint, request: request, authToken: authToken, body: body)
    }

    static func resolveRequestedChainPath(
        node: LatticeNode,
        request: Request,
        chainPath explicitChainPath: [String]? = nil
    ) async -> ChainResolution<[String]> {
        // No bare-chain (?chain=) re-check here: RejectBareChainMiddleware is
        // installed before every route and already answers 400 for it.
        let basePath = await currentChainPath(node: node)
        if let explicitChainPath {
            guard let resolved = resolveChainSelector(explicitChainPath, from: basePath) else {
                return .failure(jsonError("Invalid chainPath", status: .badRequest))
            }
            return .success(resolved)
        }
        if let rawPath = request.uri.queryParameters["chainPath"].map(String.init) {
            guard let resolved = resolveChainSelector(rawPath, from: basePath) else {
                return .failure(jsonError("Invalid chainPath", status: .badRequest))
            }
            return .success(resolved)
        }
        return .success(basePath)
    }

    private static func requireAdminAccess(request: Request, auth: CookieAuth?, endpoint: String) -> Response? {
        // Admin/state-changing methods require a presented-and-validated credential
        // regardless of bind address. Loopback is NOT treated as authentication
        // : a default-launched loopback node still exposes these endpoints
        // to any local process / CSRF-driven browser.
        guard let auth, auth.validate(authHeader: request.headers[.authorization]) else {
            return jsonError("\(endpoint) requires a valid RPC cookie credential.", status: .unauthorized)
        }
        return nil
    }

    static func validLoopbackHTTPBaseURL(_ raw: String) -> Bool {
        RPCRequestBodyCodecs.validLoopbackHTTPBaseURL(raw)
    }

    static func bearerToken(for baseURL: String, in authMap: [String: String]?) -> String? {
        guard let authMap else { return nil }
        let raw: String?
        if let exact = authMap[baseURL] {
            raw = exact
        } else if let normalizedBaseURL = normalizedHTTPBaseURL(baseURL) {
            raw = authMap.first { key, _ in normalizedHTTPBaseURL(key) == normalizedBaseURL }?.value
        } else {
            raw = nil
        }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func authMap(for baseURLs: [String], in authMap: [String: String]?) -> [String: String] {
        guard let authMap else { return [:] }
        var result: [String: String] = [:]
        for baseURL in baseURLs {
            if let token = bearerToken(for: baseURL, in: authMap) {
                result[baseURL] = token
            }
        }
        return result
    }

    private static func normalizedHTTPBaseURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = scheme
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        } else if components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }

    static func chainUnavailableResponse(node: LatticeNode, directory: String) async -> Response? {
        if await node.isChainUnavailable(directory: directory) {
            return jsonError("Chain \(directory) is unavailable", status: .serviceUnavailable)
        }
        return nil
    }

    static func chainUnavailableResponse(node: LatticeNode, chainPath: [String]) async -> Response? {
        if await node.isChainUnavailable(chainPath: chainPath) {
            return jsonError("Chain \(chainPath.joined(separator: "/")) is unavailable", status: .serviceUnavailable)
        }
        return nil
    }

    // MARK: - Query Parameter Helpers

    struct ResolvedChain {
        let path: [String]
        let key: String
        let directory: String
    }

    enum ChainResolution<T> {
        case success(T)
        case failure(Response)
    }

    static func currentChainPath(node: LatticeNode) async -> [String] {
        await node.config.fullChainPath ?? [node.genesisConfig.directory]
    }

    static func resolveChainSelector(_ raw: String, from basePath: [String]) -> [String]? {
        let parts = raw.split(separator: "/").map(String.init)
        return resolveChainSelector(parts, from: basePath)
    }

    static func resolveChainSelector(_ parts: [String], from basePath: [String]) -> [String]? {
        guard !parts.isEmpty, !basePath.isEmpty else { return nil }
        // Absolute selector (starts at the root): use verbatim.
        if parts.first == basePath.first { return parts }
        // Relative selector that names this node's own chain by a trailing
        // suffix of its full path (e.g. selector ["FastTest"] on a per-process
        // node whose path is ["Nexus","FastTest"]). Resolve to the full path
        // rather than prepending it, which would double the leaf directory.
        if parts.count <= basePath.count && Array(basePath.suffix(parts.count)) == parts {
            return basePath
        }
        // Relative selector naming a descendant: prepend this node's path.
        return basePath + parts
    }

    static func resolveChainResult(node: LatticeNode, request: Request, chainPath explicitChainPath: [String]? = nil) async -> ChainResolution<ResolvedChain> {
        let path: [String]
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: explicitChainPath) {
        case .success(let resolved): path = resolved
        case .failure(let response): return .failure(response)
        }
        guard let directory = path.last else {
            return .failure(jsonError("Invalid empty chainPath", status: .badRequest))
        }
        guard await node.network(forPath: path) != nil else {
            if String(describing: request.method).uppercased() == "GET",
               let endpoint = await node.registeredRPCEndpoint(chainPath: path) {
                let authToken = await node.registeredRPCAuthToken(chainPath: path)
                return .failure(await proxyRegisteredRPC(endpoint: endpoint, request: request, authToken: authToken))
            }
            return .failure(jsonError("Unknown chain path: \(path.joined(separator: "/"))", status: .notFound))
        }
        if let unavailable = await chainUnavailableResponse(node: node, chainPath: path) {
            return .failure(unavailable)
        }
        return .success(ResolvedChain(path: path, key: path.joined(separator: "/"), directory: directory))
    }

    // MARK: - Chain

    static func healthCheck(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        let nexus = statuses.first { $0.directory == node.genesisConfig.directory }
        let peerCount = await node.connectedPeerEndpoints().count
        let uptime = ProcessInfo.processInfo.systemUptime

        struct R: Encodable {
            let status: String
            let chainHeight: UInt64
            let genesisHash: String
            let genesisTimestamp: Int64
            let peerCount: Int
            let syncing: Bool
            let unhealthy: Bool
            let chains: Int
            let uptimeSeconds: Int
            let chainPath: [String]?      // full ancestral path for per-process nodes
            let singleChain: Bool         // whether this node runs in single-chain mode
        }
        let syncing = statuses.contains { $0.syncing }
        let unhealthy = statuses.contains { $0.unhealthy }
        let status = unhealthy ? "unhealthy" : (peerCount > 0 ? "ok" : "degraded")
        let nodeConfig = await node.config
        return json(R(
            status: status,
            chainHeight: nexus?.height ?? 0,
            genesisHash: node.genesisResult.blockHash,
            genesisTimestamp: node.genesisConfig.timestamp,
            peerCount: peerCount,
            syncing: syncing,
            unhealthy: unhealthy,
            chains: statuses.count,
            uptimeSeconds: Int(uptime),
            chainPath: nodeConfig.fullChainPath,
            singleChain: statuses.count == 1
        ))
    }

    // MARK: - Prometheus Metrics

    private static func sanitizeMetricLabel(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(s.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
    }

    static func metricsEndpoint(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        let metrics = node.metrics
        for s in statuses {
            let chain = sanitizeMetricLabel(s.directory)
            metrics.set("lattice_chain_height{chain=\"\(chain)\"}", value: Double(s.height))
            metrics.set("lattice_mempool_size{chain=\"\(chain)\"}", value: Double(s.mempoolCount))
            metrics.set("lattice_mining_active{chain=\"\(chain)\"}", value: s.mining ? 1 : 0)
        }
        let peerCount = await node.connectedPeerEndpoints().count
        metrics.set("lattice_peer_count", value: Double(peerCount))
        metrics.set("lattice_chain_count", value: Double(statuses.count))
        metrics.set("lattice_uptime_seconds", value: ProcessInfo.processInfo.systemUptime)
        let text = metrics.prometheus()
        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "text/plain; version=0.0.4; charset=utf-8"))
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(string: text)))
    }

    // MARK: - WebSocket (SSE fallback)

    static func makeEventStreamSubscription(
        subscriptions: SubscriptionManager,
        eventTypes: Set<SubscriptionEventType>,
        clientKey: String? = nil,
        bufferLimit: Int = RPCRoutes.sseStreamBufferLimit
    ) async -> (stream: AsyncStream<String>, subId: UUID)? {
        let boundedLimit = max(1, bufferLimit)
        let (stream, continuation) = AsyncStream<String>.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(boundedLimit)
        )

        guard let subId = await subscriptions.subscribeWithID(
            events: eventTypes,
            clientKey: clientKey,
            send: { subId, json in
                let result = continuation.yield("data: \(json)\n\n")
                switch result {
                case .enqueued(_):
                    break
                case .dropped(_), .terminated:
                    continuation.finish()
                    await subscriptions.unsubscribe(id: subId)
                @unknown default:
                    continuation.finish()
                    await subscriptions.unsubscribe(id: subId)
                }
            }
        ) else {
            continuation.finish()
            return nil
        }

        continuation.onTermination = { _ in
            Task { await subscriptions.unsubscribe(id: subId) }
        }
        return (stream, subId)
    }

    static func wsUpgrade(node: LatticeNode, request: Request, clientKey: String? = nil) async throws -> Response {
        // SSE (Server-Sent Events) endpoint since Hummingbird WebSocket requires a separate module.
        // Clients connect via EventSource and receive JSON event frames.
        let eventsParam = request.uri.queryParameters["events"].map(String.init) ?? "newBlock,newTransaction"
        let eventTypes = Set(eventsParam.split(separator: ",").compactMap { SubscriptionEventType(rawValue: String($0)) })
        if eventTypes.isEmpty {
            return jsonError("No valid event types. Available: newBlock, newTransaction, chainReorg, syncStatus")
        }

        var headers = HTTPFields()
        headers.append(HTTPField(name: .contentType, value: "text/event-stream"))
        headers.append(HTTPField(name: .init("Cache-Control")!, value: "no-cache"))
        headers.append(HTTPField(name: .init("Connection")!, value: "keep-alive"))

        let subscriptions = node.subscriptions
        guard let subscription = await makeEventStreamSubscription(
            subscriptions: subscriptions,
            eventTypes: eventTypes,
            clientKey: clientKey
        ) else {
            return jsonError("Too many event stream subscribers", status: .serviceUnavailable)
        }

        let body = ResponseBody(asyncSequence: subscription.stream.map { ByteBuffer(string: $0) })

        return Response(status: .ok, headers: headers, body: body)
    }
}
