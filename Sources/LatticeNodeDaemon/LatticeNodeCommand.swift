import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import Ivy
import Lattice
import LatticeNode
import LatticeNodeCore
import UInt256

@main
struct LatticeNodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "Run one Nexus-rooted hosted tree"
    )

    @Option(help: "Hosted-tree storage directory; defaults to ~/.lattice/chains/Nexus")
    var dataDirectory: String?

    @Option(help: "Process identity key file; created with mode 0600 when absent")
    var identityKey: String?

    @Option(name: .customLong("host-chain"), help: "A child chain to host as a level of this storage, e.g. Nexus/Alpha, optionally =<spec.json> to mine its genesis (repeatable; a parent before its children)")
    var hostChain: [String] = []

    /// `--host-chain` entries: each path, and the spec file it names.
    private func hostedChains() throws -> [(path: [String], spec: ChainSpec?)] {
        try hostChain.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let path = parts[0].split(separator: "/").map(String.init)
            guard parts.count == 2 else { return (path, nil) }
            let data = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
            return (path, try JSONDecoder().decode(ChainSpec.self, from: data))
        }
    }

    @Option(help: "Hosted-tree overlay listen port")
    var listenPort: UInt16 = 4001

    @Option(help: "Loopback HTTP API port")
    var rpcPort: UInt16 = 8080

    @Option(help: "HTTP bind address; only loopback addresses are accepted")
    var rpcBind = "127.0.0.1"

    @Option(parsing: .upToNextOption, help: "Overlay peer as public-key@host:port. Any peer given here REPLACES the built-in default bootstrap peers; the two are never merged.")
    var peer: [String] = []

    @Flag(help: "Start with no built-in default bootstrap peers. Without --peer this means no bootstrap peers at all; the node then finds peers only through discovery or inbound connections.")
    var noDefaultPeers = false

    @Option(help: "Minimum overlay peer-key work bits")
    var minimumPeerKeyBits = 0

    @Option(help: "Per-netgroup overlay connection cap (both directions). Defaults to the total connection cap (no effective throttle): a low value breaks proxy-fronted nodes where every connection shares one address, and buys little since bad data is rejected on verification and outbound sync slots are separately reserved. For a real per-source admission cost on a public direct-IP node, set --minimum-peer-key-bits (a grinding price) instead of lowering this.")
    var overlayMaxConnectionsPerNetgroup = IvyConfig.defaultMaxConnections

    @Option(help: "Seconds with no newly accepted Nexus block after which the node widens its peer search: re-dial configured peers without a session and look up providers of Nexus genesis. The node also announces each hosted chain by genesis. Staleness is measured from the verified local tip. Discovery never affects validation or fork choice. 0 disables search.")
    var peerSearchInterval: Double = 600

    @Option(help: "Public read-only HTTP port; binds all interfaces and serves ONLY the bounded GET read routes (the read-replica allowlist, enforced in code). Chain data is public; this exposes no operator or write surface.")
    var publicReadPort: UInt16?

    @Option(help: "Per-client arrival-rate ceiling for the general public read routes, in requests per second. The client is the PEER SOCKET ADDRESS (no forwarded-for header is trusted), so behind a proxy that presents one address for every client this throttles the whole internet as one user — set it to 0 there. 0 disables this ceiling.")
    var publicReadRate = PublicReadRateLimits.defaultGeneralRate

    @Option(help: "Per-client arrival-rate ceiling, in requests per second, for the expensive public reads: a block's detail, /transactions or /children (hundreds of content fetches). Keyed like --public-read-rate; 0 disables it.")
    var publicReadExpensiveRate = PublicReadRateLimits.defaultExpensiveRate

    @Option(help: "Listener-wide arrival-rate ceiling for the public read port, in requests per second. Address-agnostic, so it remains correct behind a proxy that collapses every client onto one address. 0 disables it; all three rates 0 is no rate limiting at all.")
    var publicReadMaxRate = PublicReadRateLimits.defaultListenerRate

    @Option(help: "This host's public read URL (absolute https:// or http://, e.g. https://reads.example.org), declared for EVERY level it hosts: peers asking for a hosted level's read endpoint get it, and each hosted child chain is announced so a node hosting its parent can list it at /api/chain/endpoints. Unset: nothing is declared or announced.")
    var publicReadUrl: String?

    @Option(help: "Self-described publicly reachable host for overlay announcements (NAT/proxy-fronted nodes announce an unreachable observed address otherwise). Host only; the overlay listen port applies.")
    var externalAddress: String?

    mutating func run() async throws {
        let processStartTime = Date()
        let address = ChainAddress([ChainAddress.nexus])!
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }
        if let publicReadPort {
            guard publicReadPort != rpcPort else {
                throw ValidationError("--public-read-port must differ from --rpc-port")
            }
        }
        let publicReadLimits = try PublicReadRateLimits.validated(
            generalRate: publicReadRate,
            expensiveRate: publicReadExpensiveRate,
            listenerRate: publicReadMaxRate
        )

        let storage = try storageURL(for: address)
        let keyURL = identityKey.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent("storage.key")
        let privateKeyHex = try loadOrCreateIdentity(at: keyURL)
        let explicitPeers = try peer.map(parsePeerEndpoint)
        // An operator peer source is authoritative: a supplied list replaces
        // the built-in defaults, and --no-default-peers expresses the empty
        // one. Only "nothing configured at all" falls back to the defaults.
        let configuredPeers = explicitPeers.isEmpty && !noDefaultPeers ? nil : explicitPeers
        if DefaultBootstrapPeers.forbidden(
            configured: configuredPeers,
            environment: ProcessInfo.processInfo.environment
        ) {
            throw ValidationError(
                "\(DefaultBootstrapPeers.forbidEnvironmentKey)=1: pass --peer or --no-default-peers"
            )
        }
        let overlayPeers = DefaultBootstrapPeers.resolved(
            chainPath: address.components,
            configured: configuredPeers
        )

        // Each spec file read once: the paths and specs agree.
        let hosted = try hostedChains()
        let configuration = try NodeConfiguration(
            chainPath: address.components,
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            listenPort: listenPort,
            rpcPort: rpcPort,
            bootstrapPeers: overlayPeers,
            minPeerKeyBits: minimumPeerKeyBits,
            overlayMaxConnectionsPerNetgroup: overlayMaxConnectionsPerNetgroup,
            externalAddress: externalAddress,
            peerSearchInterval: peerSearchInterval,
            hostedChildren: hosted.map(\.path),
            childSpecs: Dictionary(hosted.compactMap { entry in entry.spec.map { (entry.path, $0) } }) { first, _ in first },
            publicReadURL: publicReadUrl
        )
        try await runNodeRuntime(
            configuration: configuration,
            publicReadLimits: publicReadLimits,
            processStartTime: processStartTime
        )
    }

    private func storageURL(for address: ChainAddress) throws -> URL {
        var url: URL
        if let dataDirectory {
            url = URL(fileURLWithPath: dataDirectory)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lattice/chains", isDirectory: true)
            for component in address.components {
                url = url.appendingPathComponent(
                    storageComponent(component),
                    isDirectory: true
                )
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func storageComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
}

func loadOrCreateIdentity(at url: URL) throws -> String {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw ValidationError("identity key permissions must not grant group or other access")
        }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64,
              Data(hex: value) != nil else {
            throw ValidationError("identity key must contain exactly 32 hexadecimal bytes")
        }
        return value.lowercased()
    }

    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    let value = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    try Data((value + "\n").utf8).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return value
}

func parsePeerEndpoint(_ value: String) throws -> PeerEndpoint {
    let parsed = try parseEndpoint(value)
    return PeerEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseEndpoint(_ value: String) throws -> (key: String, host: String, port: UInt16) {
    guard let separator = value.firstIndex(of: "@"),
          separator != value.startIndex else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    let key = String(value[..<separator])
    let address = String(value[value.index(after: separator)...])
    guard let colon = address.lastIndex(of: ":"),
          let port = UInt16(address[address.index(after: colon)...]),
          port != 0 else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    var host = String(address[..<colon])
    if host.first == "[", host.last == "]" {
        host.removeFirst()
        host.removeLast()
    }
    guard !host.isEmpty else {
        throw ValidationError("endpoint host must be nonempty")
    }
    return (key, host, port)
}

/// The loopback operator writes: the node runtime's RPC events.
protocol OperatorWrites: Sendable {
    func submitTransaction(_ request: SubmitTransactionRequest) async throws -> SubmitTransactionResponse
    func miningTemplate(_ request: MiningTemplateRequest) async throws -> MiningTemplateResponse
    func submitWork(_ request: SubmitWorkRequest) async throws -> SubmitWorkResponse
}

extension NodeRuntime: OperatorWrites {}

/// `GET /api/chain/endpoints`: a child chain's declared read URLs, or nil (404).
typealias ChainEndpointsLookup = @Sendable ([String]) async -> ExplorerChainEndpoints?

func makeApplication(
    reads: ChainReads,
    levelReads: [ChainReads] = [],
    writes: any OperatorWrites,
    status: @Sendable @escaping () async -> NodeStatusResponse,
    metrics: @Sendable @escaping (_ peers: Int, _ processStartTime: Date) async -> String,
    host: String,
    port: Int,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse,
    processStartTime: Date,
    endpoints: @escaping ChainEndpointsLookup = { _ in nil },
    configure: (Router<BasicRequestContext>) -> Void = { _ in }
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    addPublicReadRoutes(
        to: router,
        reads: ChainReadsByPath(root: reads, levels: levelReads),
        peers: peers,
        endpoints: endpoints,
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
        try json(await status(), request: request, context: context)
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
    addOperatorWriteRoutes(to: router, writes: writes)
    configure(router)
    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

/// The public read application: exactly the bounded, non-mutating GET routes
/// the read-replica nginx allowlist exposes (/health,
/// /transactions/:cid, /accounts/:owner, /api/*), enforced in code.
/// Registered from the same function as the loopback application's read
/// surface so the two cannot drift apart.
func makePublicReadApplication(
    reads: ChainReads,
    levelReads: [ChainReads] = [],
    host: String,
    port: Int,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse = {
        ExplorerPeersResponse(count: 0, peers: [])
    },
    limits: PublicReadRateLimits = .default,
    healthClock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds,
    endpoints: @escaping ChainEndpointsLookup = { _ in nil }
) -> Application<RouterResponder<PublicReadRequestContext>> {
    // This listener faces the public internet with nothing in front of it, so
    // it carries its own arrival-rate ceilings. Its context is NOT
    // BasicRequestContext: the peer socket address is the only client identity
    // available here, and BasicRequestContext does not carry one.
    let router = Router(context: PublicReadRequestContext.self)
    // Middleware applies only to routes registered AFTER this call, so the
    // limiter must be installed before the routes it is meant to cover.
    if let limiter = PublicReadRateLimiter(limits: limits) {
        router.add(middleware: PublicReadRateLimitMiddleware<PublicReadRequestContext>(
            limiter: limiter
        ))
    }
    // /health is exempt from every bucket, so that a health check can never be
    // refused by public load — a refused check depools the machine, and on the
    // testnet follower that machine carries every chain in the path. The cost
    // is bounded by collapsing the work instead: readSnapshot() is isolated on
    // the same NodeStorage actor that serves sync and block admission, and
    // this makes a flood cost one call per TTL however fast it arrives.
    let health = ShortTTLSnapshotCache(
        ttl: statusCacheMaxAgeSeconds, clock: healthClock
    ) {
        await reads.readSnapshot()
    }
    addPublicReadRoutes(
        to: router,
        reads: ChainReadsByPath(root: reads, levels: levelReads),
        peers: peers,
        endpoints: endpoints,
        healthSnapshot: { await health.value() }
    )
    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

/// Generic over the context so the loopback application keeps
/// `BasicRequestContext` while the public listener carries a peer address —
/// one registration function, so the two surfaces cannot drift apart.
private func addPublicReadRoutes<Context: RequestContext>(
    to router: Router<Context>,
    reads byPath: ChainReadsByPath,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse,
    endpoints: @escaping ChainEndpointsLookup,
    healthSnapshot: @Sendable @escaping () async -> NodeStatusResponse
) {
    // CORS is scoped to READ methods only. The POST write routes stay off the
    // allow-list on purpose: they consume application/json, so a cross-origin
    // browser POST needs a preflight — denying .post here keeps those routes
    // reachable only by same-host (non-browser) clients, preserving the
    // daemon's loopback-only write posture. Cross-origin GETs to the public
    // read routes are "simple" requests and still succeed.
    router.add(middleware: CORSMiddleware(
        allowOrigin: .all,
        allowHeaders: [.contentType],
        allowMethods: [.get, .options]
    ))

    // /health is the public, non-mutating status: readSnapshot() never enters
    // the runtime loop, so a health-check/explorer poll cannot mutate or
    // head-of-line-block consensus/mempool work.
    let health: @Sendable (Request, Context) async throws -> Response = {
        request, context in
        let service = try byPath(request)
        return try jsonCached(
            service.chainPath == byPath.root.chainPath ? await healthSnapshot() : await service.readSnapshot(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("health", use: health)
    // HEAD is registered explicitly, not via `.autoGenerateHeadEndpoints`: that
    // option would synthesise a HEAD for EVERY GET on both applications, which
    // is far broader than this needs. Without it `HEAD /health` falls through
    // to the not-found responder and answers 404 — and the read-replica
    // allowlist permits HEAD (`limit_except GET HEAD`), so an operator pointing
    // a HEAD health check here would depool a perfectly live machine. Same
    // response, minus the body, exactly as Hummingbird's own auto-generated
    // HEAD endpoint does it.
    router.head("health") { request, context in
        try await health(request, context).createHeadResponse()
    }
    router.get("transactions/:cid") { request, context in
        let service = try byPath(request)
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest)
        }
        guard let transaction = await service.transaction(cid: cid) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            TransactionResponse(cid: cid, transaction: transaction),
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("accounts/:owner") { request, context in
        let service = try byPath(request)
        guard let owner = context.parameters.get("owner"), isPlausibleCID(owner) else {
            throw HTTPError(.badRequest)
        }
        guard let block = request.uri.queryParameters["block"].map(String.init),
              isPlausibleCID(block) else {
            throw HTTPError(.badRequest)
        }
        guard let account = await service.account(owner: owner, blockCID: block) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            AccountResponse(
                owner: owner,
                block: block,
                balance: account.balance,
                nonce: account.nonce
            ),
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    // MARK: - Explorer read API (/api/*)
    //
    // Ungated, read-only surface for the static browser explorer. Every handler
    // mirrors the public CID read routes: content-verified, size-bounded, and
    // outside the runtime loop. Served to the public internet via a
    // read-replica.

    router.get("api/block/latest") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let latest = await service.explorerLatestBlock() else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            latest,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/blocks") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        let limit = try explorerParseLimit(request, defaultValue: 10, cap: 100)
        var before: UInt64?
        if let raw = request.uri.queryParameters["before"] {
            guard let parsed = UInt64(raw) else { throw HTTPError(.badRequest) }
            before = parsed
        }
        return try jsonCached(
            await service.explorerBlocks(before: before, limit: limit),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/block/:id") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let id = context.parameters.get("id") else {
            throw HTTPError(.badRequest)
        }
        let cid: String
        let byCID: Bool
        switch explorerBlockID(id) {
        case .height(let height):
            guard let resolved = await service.explorerCanonicalBlockCID(
                atHeight: height
            ) else {
                throw HTTPError(.notFound)
            }
            cid = resolved
            byCID = false
        case .cid(let value):
            cid = value
            byCID = true
        case .invalid:
            throw HTTPError(.badRequest)
        }
        guard let block = await service.explorerBlock(cid: cid) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            block,
            cacheControl: byCID ? immutableCacheControl : statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/block/:id/transactions") { request, context in
        let service = try byPath(request)
        guard let id = context.parameters.get("id"), isPlausibleCID(id) else {
            throw HTTPError(.badRequest)
        }
        let limit = try explorerParseLimit(request, defaultValue: 20, cap: 100)
        let offset = try explorerParseOffset(request)
        guard let page = await service.explorerBlockTransactions(
            cid: id,
            offset: offset,
            limit: limit
        ) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            page,
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/block/:id/children") { request, context in
        let service = try byPath(request)
        guard let id = context.parameters.get("id"), isPlausibleCID(id) else {
            throw HTTPError(.badRequest)
        }
        let limit = try explorerParseLimit(request, defaultValue: 100, cap: 100)
        guard let children = await service.explorerBlockChildren(
            cid: id,
            limit: limit
        ) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            children,
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/transaction/:cid") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest)
        }
        guard let transaction = await service.explorerTransaction(cid: cid) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            transaction,
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/state/account/:addr") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let addr = context.parameters.get("addr"), isPlausibleCID(addr) else {
            throw HTTPError(.badRequest)
        }
        guard let account = await service.explorerAccount(owner: addr) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            account,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/mempool") { request, context in
        let service = try byPath(request)
        return try jsonCached(
            await service.explorerMempool(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/peers") { request, context in
        try jsonCached(
            await peers(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/chain/info") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            await service.explorerChainInfo(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/chain/spec") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let spec = await service.explorerChainSpec() else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            spec,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    // A child chain's declared read URLs, UNVERIFIED (the reader checks each
    // serves `committedBlock`). `chainPath` names the child; its parent must
    // be hosted here. Bounded: a few providers asked, one deadline, cached.
    router.get("api/chain/endpoints") { request, context in
        guard let raw = request.uri.queryParameters["chainPath"].map(String.init),
              let address = ChainAddress(string: raw), !address.isNexus else {
            throw HTTPError(.badRequest)
        }
        guard let found = await endpoints(address.components) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            found,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/chain/genesis") { request, context in
        let service = try byPath(request)
        return try jsonCached(
            await service.explorerChainGenesis(),
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
}

/// The read surface a request names with `?chainPath=Nexus/Alpha`: the
/// root's when it names none, a hosted child level's, or 404.
struct ChainReadsByPath: Sendable {
    let root: ChainReads
    let levels: [String: ChainReads]

    init(root: ChainReads, levels: [ChainReads]) {
        self.root = root
        self.levels = Dictionary(uniqueKeysWithValues: levels.map { ($0.chainPath.joined(separator: "/"), $0) })
    }

    func callAsFunction(_ request: Request) throws -> ChainReads {
        guard let key = request.uri.queryParameters["chainPath"].map(String.init),
              key != root.chainPath.joined(separator: "/") else { return root }
        guard let level = levels[key] else { throw HTTPError(.notFound) }
        return level
    }
}

/// Unauthenticated writes: registered only on the loopback application, never
/// on the public read application.
private func addOperatorWriteRoutes(
    to router: Router<BasicRequestContext>,
    writes service: any OperatorWrites
) {
    router.post("transactions") { request, context in
        let input: SubmitTransactionRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitTransaction(input)
        }
    }
    router.post("mining/templates") { request, context in
        let input: MiningTemplateRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.miningTemplate(input)
        }
    }
    router.post("mining/work") { request, context in
        let input: SubmitWorkRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitWork(input)
        }
    }
}

private func decode<Value: Decodable>(
    _ request: Request,
    upTo maximumBytes: Int
) async throws -> Value {
    do {
        let buffer = try await request.body.collect(upTo: maximumBytes)
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
/// DNS-rebinding page reaching this listener under a hostname it controls).
private func decode<Value: Decodable, Context: RequestContext>(
    _ request: Request,
    context: Context
) async throws -> Value {
    try requireLoopbackJSON(request)
    do {
        return try await request.decode(as: Value.self, context: context)
    } catch {
        throw HTTPError(.badRequest)
    }
}

private func requireLoopbackJSON(_ request: Request) throws {
    let hosts = [request.head.authority].compactMap { $0 }
        + request.headers.filter { $0.name.canonicalName == "host" }.map(\.value)
    for host in hosts where !isLoopbackAuthority(host) {
        throw HTTPError(.forbidden, message: "operator routes answer only a loopback Host")
    }
    let mediaType = request.headers[.contentType]?
        .split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased()
    guard mediaType == "application/json" else {
        throw HTTPError(.unsupportedMediaType, message: "Content-Type must be application/json")
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

private func serviceCall<Value: Encodable, Context: RequestContext>(
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
    } catch let error as MempoolError where error == .contextChanged {
        throw HTTPError(.serviceUnavailable, message: reason(error))
    } catch let error as MempoolError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch let error as TemplateError where error == .busy || error == .contextChanged {
        throw HTTPError(.serviceUnavailable, message: reason(error))
    } catch let error as TemplateError {
        throw HTTPError(.badRequest, message: reason(error))
    } catch NodeRuntimeError.stopped {
        throw HTTPError(.serviceUnavailable, message: "shuttingDown")
    } catch NodeRuntimeError.unknownChain {
        throw HTTPError(.notFound, message: "unknownChain")
    }
}

/// The refusal's own case name. These routes are the loopback-only operator
/// surface, and an unexplained `400` makes every refusal — an unfunded
/// credit, a stale nonce, an unproven withdrawal — look alike to the operator
/// holding the key. The case name is the node's existing vocabulary; it adds
/// no state the caller could not already read back over the same loopback.
private func reason(_ error: some Error) -> String {
    String(describing: error)
}

private func json<Value: Encodable, Context: RequestContext>(
    _ value: Value,
    request: Request,
    context: Context
) throws -> Response {
    try context.responseEncoder.encode(value, from: request, context: context)
}

/// The explorer's optional `?chainPath=` filter: this node serves exactly one
/// chain, so a request naming a different path gets a 404. Absent = serve.
private func explorerChainPathAllows(_ request: Request, own: [String]) -> Bool {
    guard let requested = request.uri.queryParameters["chainPath"] else { return true }
    return String(requested) == own.joined(separator: "/")
}

/// Parse and bound a `?limit=` query: reject non-positive/non-numeric with 400,
/// then clamp to the server cap.
private func explorerParseLimit(
    _ request: Request,
    defaultValue: Int,
    cap: Int
) throws -> Int {
    guard let raw = request.uri.queryParameters["limit"] else { return defaultValue }
    guard let parsed = Int(raw), parsed > 0 else { throw HTTPError(.badRequest) }
    return min(parsed, cap)
}

/// Parse a `?offset=` query: reject negative/non-numeric with 400.
private func explorerParseOffset(_ request: Request) throws -> Int {
    guard let raw = request.uri.queryParameters["offset"] else { return 0 }
    guard let parsed = Int(raw), parsed >= 0 else { throw HTTPError(.badRequest) }
    return parsed
}

/// A block or transaction served by CID never changes once accepted.
let immutableCacheControl = "public, max-age=31536000, immutable"
/// Chain status/health is a live snapshot; cache it only briefly. The public
/// listener also serves /health from a server-side snapshot cache of exactly
/// this age — /health is exempt from every rate limit, so its cost is bounded
/// by collapsing the work rather than by refusing requests, and reusing the
/// max-age already advertised keeps that within the contract clients are told.
/// Declared as the integer the header carries, with the cache's TTL derived
/// from it — never the other way round. A `Double` source truncated into
/// `max-age` could advertise 3 while caching 3.9, i.e. serve staler than
/// promised with nothing to show for it; deriving this direction cannot.
let statusCacheMaxAge = 3
let statusCacheControl = "public, max-age=\(statusCacheMaxAge)"
let statusCacheMaxAgeSeconds = Double(statusCacheMaxAge)

private func jsonCached<Value: Encodable, Context: RequestContext>(
    _ value: Value,
    cacheControl: String,
    request: Request,
    context: Context
) throws -> Response {
    var response = try json(value, request: request, context: context)
    response.headers[.cacheControl] = cacheControl
    return response
}

/// GET /transactions/:cid response: the decoded, content-verified
/// transaction, echoing the requested CID.
struct TransactionResponse: Codable {
    let cid: String
    let transaction: Transaction
}

/// GET /accounts/:owner?block=:cid response: the balance and next-expected
/// nonce as of `block`'s post-state, echoing the requested owner/block CIDs.
///
/// NODE-ATTESTED, not proof-backed: unlike by-CID block/tx bytes (which a
/// client can re-hash), these values are read from the node's content-verified
/// post-state and returned as plain fields — a client cannot independently
/// verify them without a sparse-Merkle proof (LatticeLightClient is kept out of
/// the daemon). Trust rests on the replica being a full verifier.
struct AccountResponse: Codable {
    let owner: String
    let block: String
    let balance: UInt64
    let nonce: UInt64
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
