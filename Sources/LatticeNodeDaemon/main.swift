import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import Ivy
import Lattice
import LatticeNode
import UInt256

/// Match DiskBroker's default storage-age grace: a newly stored orphan that
/// misses one sweep is old enough to reclaim at the next.
let volumeMaintenanceIntervalNanoseconds: UInt64 = 600 * 1_000_000_000

func runVolumeMaintenance(
    everyNanoseconds interval: UInt64 = volumeMaintenanceIntervalNanoseconds,
    evict: @escaping @Sendable () async throws -> Void
) async {
    precondition(interval > 0)
    while !Task.isCancelled {
        do {
            try await Task.sleep(nanoseconds: interval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        do {
            try await evict()
        } catch {
            FileHandle.standardError.write(Data(
                "lattice-node volume maintenance failed: \(error)\n".utf8
            ))
        }
    }
}

@main
struct LatticeNodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "Run one Lattice chain process"
    )

    @Option(help: "Absolute slash-separated path, always beginning with Nexus")
    var chainPath = "Nexus"

    @Option(help: "Storage directory; defaults to ~/.lattice/chains/<chain-path>")
    var dataDirectory: String?

    @Option(help: "Process identity key file; created with mode 0600 when absent")
    var identityKey: String?

    @Option(help: "Same-chain overlay listen port")
    var listenPort: UInt16 = 4001

    @Option(help: "Private parent/child fact-plane listen port")
    var factListenPort: UInt16 = 4002

    @Option(help: "Loopback HTTP API port")
    var rpcPort: UInt16 = 8080

    @Option(help: "HTTP bind address; only loopback addresses are accepted")
    var rpcBind = "127.0.0.1"

    @Option(parsing: .upToNextOption, help: "Overlay peer as public-key@host:port")
    var peer: [String] = []

    @Option(help: "Immediate parent fact endpoint as public-key@host:port")
    var parent: String?

    @Option(help: "Minimum overlay peer-key work bits")
    var minimumPeerKeyBits = 0

    @Option(help: "Per-netgroup overlay connection cap; raise on proxy-fronted nodes where all inbound share one source address")
    var overlayMaxConnectionsPerNetgroup = 2

    mutating func run() async throws {
        guard let address = ChainAddress(string: chainPath) else {
            throw ValidationError("--chain-path must be absolute and begin with Nexus")
        }
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }

        let storage = try storageURL(for: address)
        let keyURL = identityKey.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent("process.key")
        let privateKeyHex = try loadOrCreateIdentity(at: keyURL)
        let parentEndpoint = try parent.map(parseParentEndpoint)
        let overlayPeers = try peer.map(parsePeerEndpoint)

        let configuration = try NodeConfiguration(
            chainPath: address.components,
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            listenPort: listenPort,
            factListenPort: factListenPort,
            rpcPort: rpcPort,
            bootstrapPeers: overlayPeers,
            parentEndpoint: parentEndpoint,
            minPeerKeyBits: minimumPeerKeyBits,
            overlayMaxConnectionsPerNetgroup: overlayMaxConnectionsPerNetgroup
        )

        let network = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { [weak network] context in
                guard let network else { return [] }
                return await network.directChildCandidates(context)
            },
            childCandidateReservationReconciler: { [weak network] update in
                guard let network else {
                    return update.reservations.isEmpty
                        && update.handoffs.isEmpty
                }
                return await network.reconcileChildCandidateReservations(
                    update
                )
            },
            childProofPublisher: { [weak network] publication in
                guard let network else { throw CancellationError() }
                _ = try await network.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    childCID: publication.childCID
                )
            },
            acceptedBlockPublisher: { [weak network] blockCID in
                guard let network else { throw CancellationError() }
                try await network.publishAcceptedBlock(blockCID)
            },
            acceptedTransactionPublisher: { [weak network] rootCID in
                guard let network else { throw CancellationError() }
                try await network.publishTransaction(rootCID)
            }
        )
        try await service.restoreLocalTransactions()
        let handlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak service] context, parentContentSource in
                guard let service else { return nil }
                return try await service.miningCandidate(
                    parentCarrier: context.parentCarrier,
                    parentContentSource: parentContentSource,
                    rewards: context.rewards,
                    mode: context.mode
                )
            },
            candidateReservations: { [weak service] update in
                guard let service else { return false }
                return await service.replaceIssuedCandidateReservations(
                    update
                )
            },
            admission: { [weak service] admission in
                guard let service else { throw CancellationError() }
                return try await service.admitNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource
                )
            },
            transaction: { [weak service] transaction in
                guard let service else { throw CancellationError() }
                return try await service.submitNetworkTransaction(transaction)
            },
            transactionInventory: { [weak service] in
                guard let service else { return [] }
                return await service.transactionInventoryRoots()
            }
        )
        try await network.start(process: process, handlers: handlers)
        let app = makeApplication(
            service: service,
            host: rpcBind,
            port: Int(rpcPort),
            peers: { [weak network] in
                guard let network else {
                    return ExplorerPeersResponse(count: 0, peers: [])
                }
                return await network.peerSummaries(limit: 200)
            },
            discoverProviders: { [weak network] genesisCID in
                guard let network else { return [] }
                return await network.discoverProviderReadURLs(
                    genesisCID: genesisCID
                )
            }
        )

        print("lattice-node \(address.key)")
        print("  process: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort)")

        let volumeMaintenance = Task {
            await runVolumeMaintenance {
                _ = try await process.evictUnretainedVolumes()
            }
        }
        do {
            try await app.runService()
        } catch {
            volumeMaintenance.cancel()
            await volumeMaintenance.value
            await network.stop()
            throw error
        }
        volumeMaintenance.cancel()
        await volumeMaintenance.value
        await network.stop()
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

private func loadOrCreateIdentity(at url: URL) throws -> String {
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

private func parsePeerEndpoint(_ value: String) throws -> PeerEndpoint {
    let parsed = try parseEndpoint(value)
    return PeerEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseParentEndpoint(_ value: String) throws -> ParentEndpoint {
    let parsed = try parseEndpoint(value)
    return ParentEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
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

func makeApplication(
    service: ChainService,
    host: String,
    port: Int,
    peers: @Sendable @escaping () async -> ExplorerPeersResponse = {
        ExplorerPeersResponse(count: 0, peers: [])
    },
    discoverProviders: @Sendable @escaping (String) async -> [String] = { _ in [] }
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
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

    // /health is the public, non-mutating status: readSnapshot() takes no
    // operation gate and reconciles nothing, so a health-check/explorer poll
    // can never head-of-line-block or mutate consensus/mempool state.
    router.get("health") { request, context in
        try jsonCached(
            await service.readSnapshot(),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    // /v1/status stays on the reconciling status() (expires the mempool, prunes
    // stale child-intents) — existing operational clients poll it to observe
    // mempool drain, and depend on that reconciliation. It is an internal
    // endpoint; the public status surface is /health above.
    router.get("v1/status") { request, context in
        try json(await service.status(), request: request, context: context)
    }
    router.get("v1/blocks/:cid") { request, context in
        guard let cid = context.parameters.get("cid"), isPlausibleCID(cid) else {
            throw HTTPError(.badRequest)
        }
        guard let block = await service.block(cid: cid) else {
            throw HTTPError(.notFound)
        }
        return try jsonCached(
            BlockResponse(cid: cid, block: block),
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("v1/transactions/:cid") { request, context in
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
    router.get("v1/accounts/:owner") { request, context in
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
    router.get("v1/blocks") { request, context in
        let query = request.uri.queryParameters
        var before: String?
        if let cid = query["before"] {
            let value = String(cid)
            guard isPlausibleCID(value) else { throw HTTPError(.badRequest) }
            before = value
        }
        let limit: Int
        if let requested = query["limit"] {
            guard let parsed = Int(requested), parsed > 0 else {
                throw HTTPError(.badRequest)
            }
            limit = parsed
        } else {
            limit = 20
        }
        guard let blocks = await service.recentBlocks(before: before, limit: limit) else {
            throw HTTPError(.notFound)
        }
        // A `before` walk is immutable ONLY when it is complete — it returned
        // the full (capped) limit or reached genesis. If it truncated early
        // because a parent body was pruned/temporarily unavailable, the list
        // can grow later, so it must not be cached as immutable for a year.
        let cappedLimit = min(limit, ChainService.maximumRecentBlocksLimit)
        let complete = blocks.count >= cappedLimit || blocks.last?.parentCID == nil
        return try jsonCached(
            blocks,
            cacheControl: (before != nil && complete)
                ? immutableCacheControl : statusCacheControl,
            request: request,
            context: context
        )
    }
    // MARK: - Explorer read API (/api/*)
    //
    // Ungated, read-only surface for the static browser explorer. Every handler
    // mirrors a `/v1/*` read: content-verified, size-bounded, never touching the
    // operation gate (no status()/transactionInventoryRoots()). Served to the
    // public internet via a read-replica.

    router.get("api/block/latest") { request, context in
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
    router.get("api/block/:id") { request, context in
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        guard let id = context.parameters.get("id") else {
            throw HTTPError(.badRequest)
        }
        let cid: String
        let byCID: Bool
        if isPlausibleCID(id) {
            cid = id
            byCID = true
        } else if let height = UInt64(id) {
            guard let resolved = await service.explorerMainChainBlockCID(
                atHeight: height
            ) else {
                throw HTTPError(.notFound)
            }
            cid = resolved
            byCID = false
        } else {
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
        try jsonCached(
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
    router.get("api/chain/genesis") { request, context in
        try jsonCached(
            await service.explorerChainGenesis(),
            cacheControl: immutableCacheControl,
            request: request,
            context: context
        )
    }
    router.get("api/chain/children") { request, context in
        guard explorerChainPathAllows(request, own: service.explorerChainPath()) else {
            throw HTTPError(.notFound)
        }
        let limit = try explorerParseLimit(request, defaultValue: 100, cap: 100)
        return try jsonCached(
            await service.explorerChainChildren(limit: limit),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }
    // Permissionless child discovery: `?chainPath=<parent>/<dir>` names a DIRECT
    // child of this node's chain. We resolve that child's anchored genesisCID
    // from our own genesisState, then DHT-discover nodes providing that CID and
    // return them as read URLs (convention A). No registry: a child node becomes
    // discoverable purely by announcing itself as a provider of its genesis.
    router.get("api/chain/endpoints") { request, context in
        guard let requested = request.uri.queryParameters["chainPath"]
            .map(String.init) else {
            throw HTTPError(.badRequest)
        }
        let own = service.explorerChainPath()
        let parts = requested.split(separator: "/").map(String.init)
        guard parts.count == own.count + 1,
              Array(parts.prefix(own.count)) == own else {
            // Only direct children of THIS node's chain are resolvable here.
            throw HTTPError(.notFound)
        }
        let directory = parts[own.count]
        guard let genesisCID = await service.explorerChildGenesisCID(
            directory: directory
        ) else {
            // Not anchored (yet): no error — the explorer treats empty as offline.
            return try jsonCached(
                ExplorerEndpoints(endpoints: []),
                cacheControl: statusCacheControl,
                request: request,
                context: context
            )
        }
        let urls = await discoverProviders(genesisCID)
        return try jsonCached(
            ExplorerEndpoints(endpoints: urls.map { ExplorerEndpoint(rpcUrl: $0) }),
            cacheControl: statusCacheControl,
            request: request,
            context: context
        )
    }

    router.post("v1/transactions") { request, context in
        let input: SubmitTransactionRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitTransaction(input)
        }
    }
    router.post("v1/mining/templates") { request, context in
        let input: MiningTemplateRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.miningTemplate(input)
        }
    }
    router.post("v1/mining/work") { request, context in
        let input: SubmitWorkRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitWork(input)
        }
    }
    router.post("v1/children/intents") { request, context in
        let input: ChildDeployIntentRequest = try await decode(
            request,
            upTo: ChainServiceLimits.maximumChildIntentPayloadBytes
        )
        return try await serviceCall(request: request, context: context) {
            try await service.createChildDeployIntent(input)
        }
    }

    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
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

private func decode<Value: Decodable, Context: RequestContext>(
    _ request: Request,
    context: Context
) async throws -> Value {
    do {
        return try await request.decode(as: Value.self, context: context)
    } catch {
        throw HTTPError(.badRequest)
    }
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
    } catch ChainServiceError.childIntentLimitReached {
        throw HTTPError(.tooManyRequests)
    } catch ChainServiceError.noDeploymentAvailable {
        throw HTTPError(.conflict)
    } catch ChainServiceError.mempoolUnavailable,
            ChainServiceError.parentUnavailable {
        throw HTTPError(.serviceUnavailable)
    } catch is ChainServiceError {
        throw HTTPError(.badRequest)
    } catch TransactionPoolError.full {
        throw HTTPError(.tooManyRequests)
    } catch is TransactionPoolError {
        throw HTTPError(.badRequest)
    } catch is MiningTemplateError {
        throw HTTPError(.badRequest)
    } catch ChainProcessError.chainNotBootstrapped {
        throw HTTPError(.conflict)
    }
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
/// Chain status/health is a live snapshot; cache it only briefly.
let statusCacheControl = "public, max-age=3"

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

/// GET /v1/blocks/:cid response: the decoded, content-verified block, echoing
/// the requested CID (Codable, never raw CBOR).
struct BlockResponse: Codable {
    let cid: String
    let block: Block
}

/// GET /v1/transactions/:cid response: the decoded, content-verified
/// transaction, echoing the requested CID.
struct TransactionResponse: Codable {
    let cid: String
    let transaction: Transaction
}

/// GET /v1/accounts/:owner?block=:cid response: the balance and next-expected
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
