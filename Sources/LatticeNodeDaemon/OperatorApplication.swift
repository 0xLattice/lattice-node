import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import ServiceLifecycle
import Ivy
import Lattice
import LatticeNode
import LatticeNodeCore
import UInt256
import VolumeBroker
import LatticeNodeAPI

/// The loopback operator writes: the node runtime's RPC events.
protocol OperatorWrites: Sendable {
    func submitTransaction(_ request: SubmitTransactionRequest) async throws -> SubmitTransactionResponse
    func miningTemplate(_ request: MiningTemplateRequest) async throws -> MiningTemplateResponse
    func miningEvents() -> AsyncStream<String>
    func submitWork(_ request: SubmitWorkRequest) async throws -> SubmitWorkResponse
    func submitChildBlock(_ request: SubmitChildBlockRequest) async throws -> SubmitChildBlockResponse
    func buildChildBlock(_ request: BuildChildBlockRequest) async throws -> BuildChildBlockResponse
    func childCommitment(chainPath: [String]) async throws -> ChildCommitmentResponse
    func pinVolume(_ root: String, entries: [String: Data]?) async throws
    func fetchVolume(_ root: String) async throws -> SerializedVolume?
    func unpinVolume(_ root: String) async throws
    func pinnedVolumes() async -> [String]
    var hostedChildren: [[String]] { get }
    var servingLedger: ServingLedger { get }
}

/// `POST /pins`: the Volume an operator pins, by its root CID.
struct PinRequest: Codable, Sendable {
    let cid: String
    /// The Volume's entries, CID to bytes (base64), when the node does not
    /// hold it: a pin is stored only as the operator provides it.
    let entries: [String: Data]?

    init(cid: String, entries: [String: Data]? = nil) {
        self.cid = cid
        self.entries = entries
    }
}

/// The Volumes the operator pinned.
struct PinsResponse: Codable, Sendable {
    let pins: [String]
}

extension NodeRuntime: OperatorWrites {}

/// The public listener's `POST /transactions`, when its operator turned it on.
typealias PublicSubmit = @Sendable (SubmitTransactionRequest) async throws -> SubmitTransactionResponse

/// `GET /api/chain/endpoints`: a child chain's declared read URLs, or nil (404).
typealias ChainEndpointsLookup = @Sendable ([String]) async -> ExplorerChainEndpoints?

func makeApplication(
    reads: ChainReads,
    levelReads: @escaping @Sendable () -> [ChainReads] = { [] },
    writes: any OperatorWrites,
    status: @Sendable @escaping (_ chainPath: [String]?) async -> NodeStatusResponse?,
    metrics: @Sendable @escaping (_ peers: Int, _ processStartTime: Date) async -> String,
    host: String,
    port: Int,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse,
    processStartTime: Date,
    auth: OperatorAccess,
    endpoints: @escaping ChainEndpointsLookup = { _ in nil },
    control: OperatorControl = OperatorControl(),
    configure: (Router<BasicRequestContext>) -> Void = { _ in }
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    // First, so it covers every route below and the not-found responder: the
    // origin policy and the cookie check (LoopbackRPCAuth), or on the remote
    // listener the scoped bearer tokens (OperatorTokens).
    switch auth {
    case .loopback(let cookie):
        router.add(middleware: LoopbackRPCAuthMiddleware(auth: cookie))
    case .remote(let tokens, let origins):
        router.add(middleware: OperatorTokenMiddleware(tokens: tokens, allowedOrigins: origins))
    }
    addPublicReadRoutes(
        to: router,
        reads: ChainReadsByPath(root: reads, levels: levelReads),
        peers: peers,
        endpoints: endpoints,
        acceptsSubmit: true,
        // Loopback reads the live snapshot: `lattice status` and the E2E
        // suites poll this to watch height advance, and the public listener's
        // staleness window is a defence against public load that does not
        // apply here.
        healthSnapshot: { await reads.readSnapshot() }
    )
    // Operator surface below: registered ONLY on this loopback application.
    // /status reads the live runtime status and template digest. It is an
    // internal endpoint; the public status surface is /health.
    router.get("status") { request, context in
        let chainPath = request.uri.queryParameters["chainPath"].map { $0.split(separator: "/").map(String.init) }
        guard var answer = await status(chainPath) else { throw HTTPError(.notFound) }
        answer.startedAt = processStartTime.timeIntervalSince1970
        return try json(answer, request: request, context: context)
    }
    // Who the caller is, so a client can offer only what its credential may
    // do. Open to every credential the listener accepts; never the secret.
    router.get("whoami") { request, context in
        let me: TokensResponse.Token
        switch auth {
        case .loopback:
            me = .init(name: "cookie", role: "admin", routes: nil)
        case .remote(let tokens, _):
            guard let entry = tokens.entry(for: request.headers[.authorization]) else {
                throw HTTPError(.unauthorized, message: "the operator listener requires a bearer token")
            }
            me = .init(name: entry.name, role: entry.role, routes: entry.routes)
        }
        return try json(me, request: request, context: context)
    }
    // Prometheus exposition: operator surface only, never the public read app.
    router.get("metrics") { _, _ in
        let body = await metrics(await peers().count, processStartTime)
        return Response(
            status: .ok,
            headers: [.contentType: nodeMetricsContentType],
            body: ResponseBody(byteBuffer: ByteBuffer(string: body))
        )
    }
    addOperatorWriteRoutes(to: router, writes: writes, remote: auth.isRemote)
    addOperatorControlRoutes(to: router, control: control, writes: writes, remote: auth.isRemote)
    configure(router)
    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

/// Who may reach an operator application: the loopback API's cookie, or the
/// remote operator listener's scoped bearer tokens.
enum OperatorAccess: Sendable {
    case loopback(LoopbackRPCAuth)
    case remote(TokenStore, allowedOrigins: Set<String>)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// `--operator-listen`: where the remote operator listener binds, and its tokens.
struct OperatorListener: Sendable {
    let host: String
    let port: Int
    let tokens: TokenStore
    let allowedOrigins: Set<String>
}

/// Unauthenticated writes: registered only on the loopback application. The
/// public listener's opt-in `POST /transactions` is registered separately,
/// in `makePublicReadApplication`.
/// `remote`: the routes serve the remote operator listener, whose clients
/// are not on this host. Its bearer tokens are no credential a browser sends
/// on its own, so the loopback Host check (against DNS rebinding) does not
/// apply there, and nothing sent there may name a file on this node's disk.
private func addOperatorWriteRoutes(
    to router: Router<BasicRequestContext>,
    writes service: any OperatorWrites,
    remote: Bool
) {
    router.post("transactions") { request, context in
        let input: SubmitTransactionRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            try await service.submitTransaction(input)
        }
    }
    router.post("mining/templates") { request, context in
        let input: MiningTemplateRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            try await service.miningTemplate(input)
        }
    }
    // Server-sent events: the template digest now (`data: <digest>`), then
    // each time it changes. A client fetches a template when it does. A
    // comment line every `keepalive` only tells the client the connection
    // lives; a quiet chain sends nothing else.
    router.get("mining/events") { _, _ in
        let digests = service.miningEvents()
        return Response(
            status: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-store"],
            body: ResponseBody { writer in
                try await miningEvents(digests, to: &writer)
            }
        )
    }
    router.post("mining/work") { request, context in
        let input: SubmitWorkRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            try await service.submitWork(input)
        }
    }
    // A child block's author pushes it here until its status is "tree".
    router.post("child-blocks") { request, context in
        let input: SubmitChildBlockRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            try await service.submitChildBlock(input)
        }
    }
    // A child block built here for its author to commit on the parent; the
    // answer carries the push above.
    router.post("child-blocks/build") { request, context in
        let input: BuildChildBlockRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            try await service.buildChildBlock(input)
        }
    }
    // `child/X` on the parent's executed tip, read only: what the author's
    // loop decides each round from.
    router.get("child-blocks/commitment") { request, context in
        let path = request.uri.queryParameters["chainPath"].map { $0.split(separator: "/").map(String.init) } ?? []
        return try await serviceCall(request: request, context: context) {
            try await service.childCommitment(chainPath: path)
        }
    }
    // Operator pins: a Volume the node holds, serves and announces until
    // the operator unpins it.
    router.get("pins") { request, context in
        try json(PinsResponse(pins: await service.pinnedVolumes()), request: request, context: context)
    }
    // A Volume read from peers for the operator and not stored, in the shape
    // `POST /pins` takes.
    router.get("fetch/:cid") { request, context in
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest, message: "invalidCID")
        }
        return try await serviceCall(request: request, context: context) {
            guard let volume = try await service.fetchVolume(cid) else {
                throw HTTPError(.notFound, message: "notServed")
            }
            return PinRequest(cid: volume.root, entries: volume.entries)
        }
    }
    router.post("pins") { request, context in
        let input: PinRequest = try await decode(request, context: context, remote: remote)
        guard isPlausibleCID(input.cid) else { throw HTTPError(.badRequest, message: "invalidCID") }
        return try await serviceCall(request: request, context: context) {
            try await service.pinVolume(input.cid, entries: input.entries)
            return PinsResponse(pins: await service.pinnedVolumes())
        }
    }
    // Serving standing the operator credits by hand (its sponsor's work),
    // and any peer's standing.
    router.get("serving-credit/:peer") { request, context in
        let peer = context.parameters.get("peer") ?? ""
        return try await serviceCall(request: request, context: context) {
            ServingCreditResponse(peer: peer, standing: try await service.servingLedger.standing(peer: peer))
        }
    }
    router.post("serving-credit") { request, context in
        let input: ServingCreditRequest = try await decode(request, context: context, remote: remote)
        return try await serviceCall(request: request, context: context) {
            ServingCreditResponse(
                peer: input.peer,
                standing: try await service.servingLedger.credit(peer: input.peer, bytes: input.bytes)
            )
        }
    }
    router.delete("pins/:cid") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest, message: "invalidCID")
        }
        return try await serviceCall(request: request, context: context) {
            try await service.unpinVolume(cid)
            return PinsResponse(pins: await service.pinnedVolumes())
        }
    }
}

func decode<Value: Decodable>(
    _ request: Request,
    upTo maximumBytes: Int
) async throws -> Value {
    let buffer: ByteBuffer
    do {
        buffer = try await request.body.collect(upTo: maximumBytes)
    } catch {
        throw HTTPError(.contentTooLarge)
    }
    do {
        return try JSONDecoder().decode(
            Value.self,
            from: Data(buffer.readableBytesView)
        )
    } catch {
        throw HTTPError(.badRequest)
    }
}

/// The one body decoder of the loopback operator POST routes. It first
/// refuses what a web page could send: a body that is not declared JSON (a
/// cross-origin form or text/plain POST is a "simple" request that needs no
/// CORS preflight; requiring application/json forces the preflight the
/// read-only CORS policy denies), and a Host naming anything but loopback (a
/// DNS-rebinding page reaching this listener under a hostname it controls) —
/// except on the remote operator listener, which no page reaches with a
/// credential it holds on its own.
func decode<Value: Decodable, Context: RequestContext>(
    _ request: Request,
    context: Context,
    remote: Bool
) async throws -> Value {
    if !remote { try requireLoopbackHost(request) }
    try requireJSON(request)
    do {
        return try await request.decode(as: Value.self, context: context)
    } catch {
        throw HTTPError(.badRequest)
    }
}

func requireJSON(_ request: Request) throws {
    let mediaType = request.headers[.contentType]?
        .split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased()
    guard mediaType == "application/json" else {
        throw HTTPError(.unsupportedMediaType, message: "Content-Type must be application/json")
    }
}

func requireLoopbackHost(_ request: Request) throws {
    let hosts = [request.head.authority].compactMap { $0 }
        + request.headers.filter { $0.name.canonicalName == "host" }.map(\.value)
    for host in hosts where !isLoopbackAuthority(host) {
        throw HTTPError(.forbidden, message: "operator routes answer only a loopback Host")
    }
}

private func isLoopbackAuthority(_ authority: String) -> Bool {
    var host = Substring(authority.lowercased())
    if host.hasPrefix("[") {
        guard let close = host.firstIndex(of: "]") else { return false }
        host = host[host.index(after: host.startIndex)..<close]
    } else if let colon = host.lastIndex(of: ":") {
        host = host[..<colon]
    }
    return ["127.0.0.1", "localhost", "::1"].contains(String(host))
}

func serviceCall<Value: Encodable, Context: RequestContext>(
    request: Request,
    context: Context,
    operation: () async throws -> Value
) async throws -> Response {
    do {
        return try json(
            try await operation(),
            request: request,
            context: context
        )
    } catch let error as NodeAPIError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch let error as MiningTemplateError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch MempoolError.full {
        throw HTTPError(.tooManyRequests, message: "full")
    } catch let error as MempoolError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch let error as TemplateError where error == .busy || error == .executing {
        throw HTTPError(.serviceUnavailable, message: reason(error))
    } catch let error as TemplateError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch NodeRuntimeError.stopped {
        throw HTTPError(.serviceUnavailable, message: "shuttingDown")
    } catch NodeRuntimeError.unknownChain {
        throw HTTPError(.notFound, message: "unknownChain")
    } catch NodeRuntimeError.busy {
        throw HTTPError(.serviceUnavailable, headers: [.retryAfter: "1"], message: "busy")
    } catch NodeStorageError.missingMaterializedVolume, BrokerError.missingRetainedRoot {
        throw HTTPError(.notFound, message: "notHeld")
    } catch let error as ValidationError {
        throw HTTPError(.badRequest, message: error.message)
    } catch NodeConfigurationError.invalidChainPath {
        throw HTTPError(.badRequest, message: "invalidChainPath")
    } catch NodeStorageError.invalidVolume {
        throw HTTPError(.badRequest, message: "invalidVolume")
    } catch BrokerError.conflictingVolume {
        throw HTTPError(.conflict, message: "conflictingVolume")
    } catch let error as ServingLedgerError where error == .notSaved {
        throw HTTPError(.serviceUnavailable, message: reason(error))
    } catch let error as ServingLedgerError {
        throw HTTPError(.badRequest, message: reason(error))
    }
}

/// Write each digest as a server-sent event, with a comment line whenever
/// `keepalive` passes without one, until the stream ends.
private enum MiningStreamEvent: Sendable { case digest(String), keepalive, ended }

func miningEvents(
    _ digests: AsyncStream<String>,
    to writer: inout any ResponseBodyWriter,
    keepalive: Duration = .seconds(15)
) async throws {
    let (events, sink) = AsyncStream<MiningStreamEvent>.makeStream()
    let (written, ack) = AsyncStream<Void>.makeStream()
    let reader = Task {
        // One digest in flight at a time: the source keeps only the newest,
        // so a client that stops reading skips to the latest instead of
        // queueing every one here.
        var acks = written.makeAsyncIterator()
        for await digest in digests {
            sink.yield(.digest(digest))
            guard await acks.next() != nil else { break }
        }
        sink.yield(.ended)
    }
    let ticker = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: keepalive)
            sink.yield(.keepalive)
        }
    }
    defer {
        reader.cancel()
        ticker.cancel()
    }
    // The server waits for open responses when it shuts down, and this one
    // would run until the runtime stops after it: end it with the server.
    try await withGracefulShutdownHandler {
        try await writeMiningEvents(events, to: &writer, written: ack)
    } onGracefulShutdown: {
        sink.yield(.ended)
    }
}

private func writeMiningEvents(
    _ events: AsyncStream<MiningStreamEvent>,
    to writer: inout any ResponseBodyWriter,
    written: AsyncStream<Void>.Continuation
) async throws {
    for await next in events {
        switch next {
        case .digest(let digest):
            try await writer.write(ByteBuffer(string: "data: \(digest)\n\n"))
            written.yield()
        case .keepalive:
            try await writer.write(ByteBuffer(string: ": keepalive\n\n"))
        case .ended:
            try await writer.finish(nil)
            return
        }
    }
}

/// The refusal's own case name. An unexplained `400` makes every refusal —
/// an unfunded credit, a stale nonce, an unproven withdrawal — look alike to
/// the key holder. The case name is the node's existing vocabulary; it adds
/// no state the caller could not already read back (on the public submit
/// route too: account state and the pool are public reads).
private func reason(_ error: some Error) -> String {
    String(describing: error)
}

func json<Value: Encodable, Context: RequestContext>(
    _ value: Value,
    request: Request,
    context: Context
) throws -> Response {
    try context.responseEncoder.encode(value, from: request, context: context)
}
