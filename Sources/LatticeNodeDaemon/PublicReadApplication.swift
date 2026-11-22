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

/// The public read application: exactly the bounded, non-mutating GET routes
/// the read-replica nginx allowlist exposes (/health,
/// /transactions/:cid, /accounts/:owner, /api/*), enforced in code.
/// Registered from the same function as the loopback application's read
/// surface so the two cannot drift apart.
func makePublicReadApplication(
    reads: ChainReads,
    levelReads: @escaping @Sendable () -> [ChainReads] = { [] },
    host: String,
    port: Int,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse = {
        ExplorerPeersResponse(count: 0, peers: [])
    },
    limits: PublicReadRateLimits = .default,
    healthClock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds,
    endpoints: @escaping ChainEndpointsLookup = { _ in nil },
    submit: PublicSubmit? = nil,
    fetches: PublicVolumeFetches? = nil
) -> Application<RouterResponder<BasicRequestContext>> {
    // This listener faces the public internet with nothing in front of it, so
    // it carries its own arrival-rate ceilings.
    let router = Router(context: BasicRequestContext.self)
    // CORS is scoped to READ methods only. The POST write routes stay off the
    // allow-list on purpose: they consume application/json, so a cross-origin
    // browser POST needs a preflight — denying .post here keeps those routes
    // reachable only by same-host (non-browser) clients. Cross-origin GETs to
    // the public read routes are "simple" requests and still succeed. An
    // operator who turned public submit on also allows POST: that route is
    // meant to be reached cross-origin. Installed OUTSIDE the limiter, so a
    // refusal still carries CORS (a page sees a 429, not a CORS failure) and
    // a preflight is answered without spending the budget.
    router.add(middleware: CORSMiddleware(
        allowOrigin: .all,
        allowHeaders: [.contentType],
        allowMethods: submit != nil ? [.get, .post, .options] : [.get, .options]
    ))
    // Middleware applies only to routes registered AFTER this call, so the
    // limiter must be installed before the routes it is meant to cover.
    if let limiter = PublicReadRateLimiter(limits: limits) {
        router.add(middleware: PublicReadRateLimitMiddleware<BasicRequestContext>(
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
        acceptsSubmit: submit != nil,
        fetches: fetches,
        healthSnapshot: { await health.value() }
    )
    if let submit {
        // Opt-in public submit: the operator route's body and answer, the
        // body capped BEFORE decoding, and none of the loopback route's
        // Host/Content-Type checks — those keep web pages off the operator's
        // own surface, while this route exists to be reached from anywhere.
        router.post("transactions") { request, context in
            let input: SubmitTransactionRequest = try await decode(
                request, upTo: NodeAPILimits.maximumPayloadBytes
            )
            return try await serviceCall(request: request, context: context) {
                try await submit(input)
            }
        }
    }
    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

/// The public submit route's body: capped before decoding, with none of the
/// operator decoder's Host and Content-Type checks.
private func decode<Value: Decodable>(
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

/// A complete Volume archive, immutable by its CID.
private func volumeArchiveResponse(_ archive: ByteBuffer) -> Response {
    Response(
        status: .ok,
        headers: [
            .contentType: "application/vnd.lattice.volume",
            .cacheControl: immutableCacheControl,
        ],
        body: ResponseBody(byteBuffer: archive)
    )
}

/// Generic over the context so the loopback application keeps
/// `BasicRequestContext` while the public listener carries a peer address —
/// one registration function, so the two surfaces cannot drift apart.
func addPublicReadRoutes<Context: RequestContext>(
    to router: Router<Context>,
    reads byPath: ChainReadsByPath,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse,
    endpoints: @escaping ChainEndpointsLookup,
    acceptsSubmit: Bool,
    fetches: PublicVolumeFetches? = nil,
    healthSnapshot: @Sendable @escaping () async -> NodeStatusResponse
) {
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
    router.get("volumes/:cid") { request, context in
        let service = try byPath(request)
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest)
        }
        if let archive = await service.completeVolumeArchive(rootCID: cid) {
            return volumeArchiveResponse(ByteBuffer(bytes: archive))
        }
        // One this node does not hold, read from peers when the operator
        // allows it (`--public-read-fetches`). A reader that goes away
        // while it waits for a place gives the place up. Watching for that
        // reads the connection past this request, so the connection is
        // closed after the answer, and the answer says so.
        guard let fetches else { throw HTTPError(.notFound) }
        let close: HTTPFields = [.connection: "close"]
        switch try await request.body.consumeWithCancellationOnInboundClose({ _ in await fetches.archive(cid) }) {
        case .archive(let read):
            var response = volumeArchiveResponse(read)
            response.headers[.connection] = "close"
            return response
        case .busy:
            throw HTTPError(.serviceUnavailable, headers: close + [.retryAfter: "1"], message: "busy")
        case .waited:
            let wait = String(fetches.maximumWait.components.seconds)
            throw HTTPError(.serviceUnavailable, headers: close + [.retryAfter: wait], message: "busy")
        case .notServed: throw HTTPError(.notFound, headers: close)
        }
    }
    // Many Volumes in one request, for a client walking content it already
    // knows the CIDs of. Only what this node holds: a CID left out is read
    // on its own, where a peer read may apply.
    router.get("volumes") { request, context in
        let service = try byPath(request)
        guard let list = request.uri.queryParameters["cids"] else {
            throw HTTPError(.badRequest)
        }
        let cids = list.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard cids.count <= maximumCompleteVolumeRecordsRoots,
              cids.allSatisfy(isPlausibleCID) else {
            throw HTTPError(.badRequest)
        }
        let records = await service.completeVolumeRecords(rootCIDs: cids)
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/vnd.lattice.volumes",
                // A CID left out may be held later.
                .cacheControl: records.complete ? immutableCacheControl : statusCacheControl,
            ],
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: records.body))
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
        let limit = try explorerParseLimit(
            request, defaultValue: 10, cap: ChainReads.maximumExplorerBlocksPage
        )
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
    // The child directories this chain's executed blocks have committed, in
    // order, from the level core's list.
    router.get("api/chain/children") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        let limit = try explorerParseLimit(request, defaultValue: 200, cap: 200)
        let after = request.uri.queryParameters["after"].map(String.init)
        return try jsonCached(
            await service.explorerChainChildren(after: after, limit: limit),
            cacheControl: statusCacheControl,
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
        // Inclusion changes as the chain grows and reorgs: not immutable.
        return try jsonCached(
            transaction,
            cacheControl: statusCacheControl,
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
    router.get("api/deposits") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        let limit = try explorerParseLimit(request, defaultValue: 100, cap: 100)
        let after = request.uri.queryParameters["after"].map(String.init)
        guard let page = try await service.explorerDeposits(limit: limit, after: after) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            page,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/deposit-state") { request, context in
        let service = try byPath(request)
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let key = request.uri.queryParameters["key"].map(String.init),
              DepositKey(key) != nil else {
            throw HTTPError(.badRequest)
        }
        guard let state = try await service.explorerDepositState(key: key) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            state,
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/receipt-state") { request, context in
        guard let demander = request.uri.queryParameters["demander"].map(String.init),
              isPlausibleCID(demander),
              let amountRaw = request.uri.queryParameters["amount"].map(String.init),
              let amount = UInt64(amountRaw),
              let nonceRaw = request.uri.queryParameters["nonce"].map(String.init),
              let nonce = UInt128(nonceRaw),
              let destinationRaw = request.uri.queryParameters["chainPath"].map(String.init),
              let destination = ChainAddress(string: destinationRaw),
              !destination.isNexus else {
            throw HTTPError(.badRequest)
        }
        let destinationPath = destination.components
        let parentPath = Array(destinationPath.dropLast())
        guard let service = byPath.service(for: parentPath),
              let receipt = try await service.explorerReceiptState(
                demander: demander,
                amountDemanded: amount,
                nonce: nonce,
                destinationPath: destinationPath
              ) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            receipt,
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
    router.get("api/fees") { request, context in
        let service = try byPath(request)
        return try jsonCached(
            await service.explorerFees(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    // A chain's own current peers; with no `chainPath`, Nexus's.
    router.get("api/peers") { request, context in
        let service = try byPath(request)
        return try jsonCached(
            service.chainPath == byPath.root.chainPath
                ? await peers() : ExplorerPeersResponse(count: service.peerCount(), peers: []),
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
        var info = await service.explorerChainInfo()
        info.acceptsSubmit = acceptsSubmit
        return try jsonCached(
            info,
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
    // A child chain's declared read URLs, UNVERIFIED (the reader checks what
    // each serves), found through the child's rendezvous. `chainPath` names
    // the child; its parent must be hosted here. Bounded: a few providers
    // asked, one deadline, cached, a few lookups at once.
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
    /// The hosted child levels as they are now: the operator changes them
    /// while the node runs.
    let hosted: @Sendable () -> [ChainReads]

    init(root: ChainReads, levels: @escaping @Sendable () -> [ChainReads]) {
        self.root = root
        self.hosted = levels
    }

    private var levels: [String: ChainReads] {
        Dictionary(hosted().map { ($0.chainPath.joined(separator: "/"), $0) }) { first, _ in first }
    }

    func callAsFunction(_ request: Request) throws -> ChainReads {
        guard let key = request.uri.queryParameters["chainPath"].map(String.init),
              key != root.chainPath.joined(separator: "/") else { return root }
        guard let level = levels[key] else { throw HTTPError(.notFound) }
        return level
    }

    func service(for chainPath: [String]) -> ChainReads? {
        let key = chainPath.joined(separator: "/")
        return key == root.chainPath.joined(separator: "/") ? root : levels[key]
    }
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
/// verify them without a sparse-Merkle proof, and account reads carry none
/// (only deposit/receipt state does: `StateDictionaryProof`). Trust rests on
/// the replica being a full verifier.
struct AccountResponse: Codable {
    let owner: String
    let block: String
    @DecimalString var balance: UInt64
    @DecimalString var nonce: UInt64
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
