import Lattice
import LatticeNodeRPCFuzzSupport
import Foundation
import Hummingbird
import HTTPTypes
import cashew
import VolumeBroker
import UInt256
import Synchronization

// Chain lifecycle RPC command services for RPCServer.
// Behavior-preserving extraction : /chain/info, /chain/map,
// /chain/register-rpc, /chain/genesis, /chain/spec, and /chain/deploy route bodies.
// Pure relocation; no logic change.

private final class RPCBufferedStorer: Storer, @unchecked Sendable {
    private let lock = Mutex<[String: Data]>([:])

    func store(rawCid: String, data: Data) throws {
        lock.withLock { $0[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        lock.withLock { $0[rawCid] != nil }
    }

    var entries: [String: Data] {
        lock.withLock { $0 }
    }
}

extension RPCRoutes {
    static func chainInfo(node: LatticeNode) async throws -> Response {
        let statuses = await node.chainStatus()
        let pubKey = await node.config.publicKey
        let listenPort = await node.config.listenPort
        // p2pAddress lets lattice-miner connect to this node's Ivy P2P port for gossip
        let p2pAddress = "\(pubKey)@127.0.0.1:\(listenPort)"
        struct R: Encodable { let chains: [C]; let genesisHash: String; let genesisTimestamp: Int64; let nexus: String; let p2pAddress: String }
        struct C: Encodable {
            let chainPath: [String]
            let directory: String
            let parentDirectory: String?
            let height: UInt64
            let tip: String
            let timestamp: Int64
            let mining: Bool
            let mempoolCount: Int
            let syncing: Bool
            let unhealthy: Bool
            let health: String
            let healthReason: String?
            let chainP2PAddress: String?  // per-chain P2P address for --subscribe-p2p in Phase 3
            let minFeeRate: UInt64        // Contract 6: per-byte fee floor this node admits at
        }
        var chains: [C] = []
        for s in statuses {
            let chainPort: UInt16?
            if let localPort = await node.network(forPath: s.chainPath)?.ivy.config.listenPort {
                chainPort = localPort
            } else if let parent = s.parentDirectory {
                chainPort = await node.network(for: parent)?.ivy.config.listenPort
            } else {
                chainPort = nil
            }
            let chainP2P = chainPort.map { "\(pubKey)@127.0.0.1:\($0)" }
            chains.append(C(chainPath: s.chainPath,
                            directory: s.directory, parentDirectory: s.parentDirectory,
                            height: s.height, tip: s.tip, timestamp: s.timestamp, mining: s.mining,
                            mempoolCount: s.mempoolCount, syncing: s.syncing,
                            unhealthy: s.unhealthy,
                            health: s.health,
                            healthReason: s.healthReason,
                            chainP2PAddress: chainP2P,
                            minFeeRate: s.minFeeRate))
        }
        return json(R(chains: chains, genesisHash: node.genesisResult.blockHash,
                      genesisTimestamp: node.genesisConfig.timestamp,
                      nexus: node.genesisConfig.directory, p2pAddress: p2pAddress))
    }

    // GET /api/chain/map — returns a map of full chain path → RPC endpoint for all
    // registered chains whose endpoint has been announced. Allows clients to discover
    // the direct HTTP endpoint for any chain in the subtree without multi-hop routing.

    static func chainMap(node: LatticeNode) async throws -> Response {
        var result: [String: String] = [:]
        for (path, endpoint) in await node.registeredRPCMap() {
            result[path] = endpoint
        }
        for (_, network) in await node.networks {
            if let endpoint = await network.rpcEndpoint {
                result[network.chainPath.joined(separator: "/")] = endpoint
            }
        }
        return json(result)
    }

    // GET /api/chain/children?chainPath=<path>&limit=&after= — discover the child chains
    // announced by a chain, read from its on-chain GenesisState (directory -> genesisCID).
    // Any node that synced the chain can enumerate its immediate children with no knowledge
    // of who deployed or runs them. Bounded page (cashew boundedKeysAndValues) — never walks
    // the whole genesisState trie. Deeper descendants become enumerable once a child is
    // followed and synced (the discover -> follow -> discover-deeper loop).
    static func chainChildren(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let limitStr = request.uri.queryParameters["limit"].map(String.init)
        let limit = min(limitStr.flatMap(Int.init) ?? 100, 1000)
        let after = request.uri.queryParameters["after"].map(String.init)
        do {
            let entries = try await node.listChildChains(chainPath: chain.path, limit: limit, after: after)
            struct ChildEntry: Encodable { let directory: String; let chainPath: [String]; let genesisHash: String }
            let children = entries.map { ChildEntry(directory: $0.directory, chainPath: chain.path + [$0.directory], genesisHash: $0.genesisHash) }
            struct R: Encodable { let children: [ChildEntry]; let count: Int; let chain: String }
            return json(R(children: children, count: children.count, chain: chain.key))
        } catch {
            return jsonError("Failed to list child chains", status: .internalServerError)
        }
    }

    // GET /api/chain/endpoints?chainPath=Nexus/toy — public HTTP RPC endpoints that this
    // node's directly-connected `toy` children have advertised through the child-peer
    // rendezvous. Lets a browser connect straight to a child chain's node (Nexus stays
    // Nexus-only, just relaying the directory). Self-declared + UNVERIFIED: the caller MUST
    // verify the served chain's genesis against the parent's anchor before trusting one.
    // Bounded, unauthenticated read. Only answers for a chain THIS node serves as parent.
    static func chainEndpoints(node: LatticeNode, request: Request) async throws -> Response {
        let basePath = await currentChainPath(node: node)
        guard let raw = request.uri.queryParameters["chainPath"].map(String.init),
              let resolved = resolveChainSelector(raw.split(separator: "/").map(String.init), from: basePath),
              resolved.count >= 2 else {
            return jsonError("Expected chainPath=<parent>/<child>, e.g. Nexus/toy", status: .badRequest)
        }
        let directory = resolved.last!
        let parentPath = Array(resolved.dropLast())
        // `pubkey` is the ADVERTISER's parent-link identity — it authenticates who relayed the
        // URL, NOT the RPC server. The URL is self-declared and untrusted: the browser MUST
        // verify the served genesis against the parent's anchor before using an endpoint.
        struct Ep: Encodable { let rpcUrl: String; let pubkey: String }
        struct R: Encodable { let chainPath: [String]; let endpoints: [Ep]; let count: Int }
        var eps: [Ep] = []
        // If THIS node serves the child chain in-process (multichain parent) and exposes a
        // public RPC, include itself — otherwise the explorer's level-by-level walk would find
        // no endpoint for an in-process level even though this very node can serve it.
        if await node.network(forPath: resolved) != nil,
           let ownRpc = await node.config.rpcPublicUrl, ChildPeerProvider.isBrowsableHTTPURL(ownRpc) {
            eps.append(Ep(rpcUrl: ownRpc, pubkey: await node.config.p2pPublicKey))
        }
        if let network = await node.network(forPath: parentPath) {
            let seen = Set(eps.map { $0.rpcUrl })
            for e in await node.advertisedChildRPCEndpoints(network: network, directory: directory)
            where !seen.contains(e.rpcUrl) {
                eps.append(Ep(rpcUrl: e.rpcUrl, pubkey: e.pubkey))
            }
        }
        return json(R(chainPath: resolved, endpoints: eps, count: eps.count))
    }

    // GET /api/chain/parent-height?chainPath=<path>
    // Contract 2 (parent-visibility): a child block carried by parent block H commits
    // `parentState = postState(H-1)` (BlockBuilder uses the carrier's prevState). So:
    //   parentHeight       = H        (the carrier block this child's tip is anchored to)
    //   visibleStateHeight = H - 1    (highest parent block whose post-state is visible
    //                                  through parentState — i.e. the receiptState a
    //                                  withdrawal validates against)
    // A receipt mined in parent block R is visible once visibleStateHeight >= R, i.e.
    // parentHeight >= R + 1. Both null for the root chain (no parent).

    static func parentChainHeight(node: LatticeNode, request: Request) async throws -> Response {
        let basePath = await currentChainPath(node: node)
        let rawPath = request.uri.queryParameters["chainPath"].map(String.init)
        let chainPath: [String]
        if let raw = rawPath {
            guard let resolved = resolveChainSelector(raw.split(separator: "/").map(String.init), from: basePath) else {
                return jsonError("Invalid chainPath", status: .badRequest)
            }
            chainPath = resolved
        } else {
            chainPath = basePath
        }
        // Proxy to the registered remote child for per-process topologies where the
        // parent has only an RPC pointer, not a local fork-choice view of the child.
        if await node.network(forPath: chainPath) == nil,
           let endpoint = await node.registeredRPCEndpoint(chainPath: chainPath) {
            let authToken = await node.registeredRPCAuthToken(chainPath: chainPath)
            return await proxyRegisteredRPC(endpoint: endpoint, request: request, authToken: authToken)
        }
        let height = await node.getParentChainHeight(chainPath: chainPath)
        // visibleStateHeight = carrier - 1; nil when carrier is nil or 0 (genesis carrier
        // commits no prior parent post-state).
        let visibleStateHeight: UInt64? = height.flatMap { $0 > 0 ? $0 - 1 : nil }
        struct R: Encodable { let parentHeight: UInt64?; let visibleStateHeight: UInt64? }
        return json(R(parentHeight: height, visibleStateHeight: visibleStateHeight))
    }

    // POST /api/chain/register-rpc { chainPath: [...], endpoint: "http://..." }
    // Called by a per-process child node on startup to announce its RPC endpoint.
    // The parent stores it and propagates up to any registered ancestor.

    static func registerChainRPC(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 4_096),
              let body = RPCRequestBodyCodecs.decodeRegisterChainRPC(Data(buffer: buffer)) else {
            return jsonError("Missing chainPath or endpoint", status: .badRequest)
        }
        guard validLoopbackHTTPBaseURL(body.endpoint) else {
            return jsonError("Invalid endpoint: expected loopback http(s) base URL", status: .badRequest)
        }
        // Normalize to API-base at ingress: callers may omit /api but all internal
        // paths (block delivery, proxy) expect the stored form to include it.
        let normalizedEndpoint = body.endpoint.hasSuffix("/api") ? body.endpoint : body.endpoint + "/api"
        let pathKey = body.chainPath.joined(separator: "/")
        await node.registerRPCEndpoint(chainPath: body.chainPath, endpoint: normalizedEndpoint, authToken: body.authToken)
        if let network = await node.networks[pathKey] {
            await network.setRPCEndpoint(normalizedEndpoint)
        }
        struct R: Encodable { let ok: Bool }
        return json(R(ok: true))
    }

    // POST /api/chain/unregister-rpc { chainPath: [...] }
    // Removes a previously-registered child RPC endpoint from the parent.

    static func unregisterChainRPC(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 4_096),
              let body = RPCRequestBodyCodecs.decodeUnregisterChainRPC(Data(buffer: buffer)) else {
            return jsonError("Expected {chainPath}", status: .badRequest)
        }
        let basePath = await currentChainPath(node: node)
        guard let resolved = resolveChainSelector(body.chainPath, from: basePath) else {
            return jsonError("Invalid chainPath", status: .badRequest)
        }
        // Contract 4: detach is durable. For a supervised child this marks the deployed
        // metadata detached (so restart/idempotent-deploy will NOT auto-respawn it),
        // stops the process, and drops the registration. For a non-supervised child it
        // is just an endpoint removal. detachSupervisedChild handles both.
        await node.detachSupervisedChild(chainPath: resolved)
        // If this node was the sole merged-mined block-delivery path for the child
        // (no other Ivy peer), the child will stall after this call. Any in-flight
        // swaps waiting for a withdrawal block on that child will be unable to mine.
        struct R: Encodable { let ok: Bool; let warning: String }
        return json(R(ok: true, warning: "Block delivery to this child may stall if this node was its only merged-mined relay. Ensure the child has an alternative peer before detaching."))
    }

    // POST /api/chain/follow { chainPath: [...] } — subscribe to an existing, announced child.
    // Records the follow intent durably; the supervised reconciler then resolves the child's
    // genesis from THIS node's synced parent GenesisState + CAS and spawns/syncs it — no
    // genesis-hex or peer address from the operator. Reuses the {chainPath} body codec.
    static func followChain(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 4_096),
              let body = RPCRequestBodyCodecs.decodeUnregisterChainRPC(Data(buffer: buffer)) else {
            return jsonError("Expected {chainPath}", status: .badRequest)
        }
        let basePath = await currentChainPath(node: node)
        guard let resolved = resolveChainSelector(body.chainPath, from: basePath), resolved.count >= 2 else {
            return jsonError("Invalid chainPath (must be a child path, e.g. Nexus/toy)", status: .badRequest)
        }
        await node.followChild(chainPath: resolved)
        // Kick a reconcile so resolution+spawn starts now rather than on the next 30s tick;
        // if the genesis isn't yet fetchable the child stays `resolving` and the loop retries.
        await node.reconcileSupervisedChildren()
        struct R: Encodable { let ok: Bool; let chainPath: [String] }
        return json(R(ok: true, chainPath: resolved))
    }

    // GET /api/chain/genesis?chainPath=<path> — returns genesis hex for a chain.
    // Enables bootstrapping a child chain process without manual genesis-hex passing.
    // The parent node fetches its own genesis block for the requested chain path.

    static func chainGenesis(node: LatticeNode, request: Request) async throws -> Response {
        // No bare-chain (?chain=) re-check here: RejectBareChainMiddleware is
        // installed before every route and already answers 400 for it.
        let basePath = await currentChainPath(node: node)
        let rawPath = request.uri.queryParameters["chainPath"].map(String.init)
            ?? request.uri.queryParameters["directory"].map(String.init)
        let chainPath: [String]
        if let rawPath {
            guard let resolved = resolveChainSelector(rawPath, from: basePath) else {
                return jsonError("Invalid chainPath", status: .badRequest)
            }
            chainPath = resolved
        } else {
            chainPath = basePath
        }
        if await node.network(forPath: chainPath) == nil,
           let endpoint = await node.registeredRPCEndpoint(chainPath: chainPath) {
            return await proxyRegisteredRPC(endpoint: endpoint, request: request)
        }
        guard let dir = chainPath.last else {
            return jsonError("Invalid empty chainPath", status: .badRequest)
        }
        if let deployed = await node.deployedChildChains[chainPath.joined(separator: "/")] {
            let pubKey = await node.config.publicKey
            let parentPort: UInt16
            if let port = await node.network(for: deployed.parentDirectory)?.ivy.config.listenPort {
                parentPort = port
            } else {
                parentPort = await node.config.listenPort
            }
            let chainP2PAddress = "\(pubKey)@127.0.0.1:\(parentPort)"
            struct R: Encodable {
                let directory: String; let chainPath: [String]; let genesisHash: String; let genesisHex: String
                let chainP2PAddress: String?
            }
            return json(R(
                directory: deployed.directory,
                chainPath: deployed.chainPath,
                genesisHash: deployed.genesisHash,
                genesisHex: deployed.genesisHex,
                chainP2PAddress: chainP2PAddress
            ))
        }
        guard await node.network(forPath: chainPath) != nil else {
            return jsonError("Unknown chain path: \(chainPath.joined(separator: "/"))", status: .notFound)
        }
        if let unavailable = await chainUnavailableResponse(node: node, chainPath: chainPath) {
            return unavailable
        }
        guard let chainState = await node.chain(forPath: chainPath) else {
            return jsonError("Chain path '\(chainPath.joined(separator: "/"))' not found", status: .notFound)
        }
        let genesisHash = await chainState.getMainChainBlockHash(atIndex: 0)
        guard let genesisHash else {
            return jsonError("Genesis block not found for '\(chainPath.joined(separator: "/"))'", status: .notFound)
        }
        guard let network = await node.network(forPath: chainPath) else {
            return jsonError("No network for '\(chainPath.joined(separator: "/"))'", status: .notFound)
        }
        guard let genesisData = try? await network.ivyFetcher.fetch(rawCid: genesisHash),
              let genesisBlock = Block(data: genesisData) else {
            return jsonError("Genesis block data unavailable for '\(chainPath.joined(separator: "/"))'", status: .serviceUnavailable)
        }
        // Build the same self-contained genesis payload shape returned by deploy:
        // block, spec, genesis tx bodies, and WASM policy modules.
        var genesisEntries: [(String, Data)] = [(genesisHash, genesisData)]
        let specCIDG = genesisBlock.spec.rawCID
        var resolvedSpec = genesisBlock.spec.node
        if resolvedSpec == nil {
            resolvedSpec = try? await genesisBlock.spec.resolve(fetcher: network.ivyFetcher).node
        }
        if let sd = resolvedSpec?.toData() {
            genesisEntries.append((specCIDG, sd))
        }
        if let spec = resolvedSpec {
            for policy in spec.wasmPolicies {
                let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
                guard let module = try? await moduleHeader.resolve(fetcher: network.ivyFetcher).node,
                      let moduleData = module.toData() else { continue }
                genesisEntries.append((policy.moduleCID, moduleData))
            }
        }
        // Genesis transaction bodies and policy modules are startup artifacts, not
        // guaranteed to be discoverable from a raw block fetch. Deploy records them
        // as height-0 stored roots so the endpoint can re-export them deterministically.
        if let store = await node.stateStore(forPath: chainPath) {
            for (root, _) in store.getStoredRoots(height: 0) {
                guard root != genesisHash, root != specCIDG,
                      let data = try? await network.ivyFetcher.fetch(rawCid: root) else { continue }
                if TransactionBody(data: data) != nil || WasmPolicyModule(data: data) != nil {
                    genesisEntries.append((root, data))
                }
            }
        }
        var seenGenesisEntryCIDs = Set<String>()
        genesisEntries = genesisEntries.filter { entry in
            seenGenesisEntryCIDs.insert(entry.0).inserted
        }
        var payload = Data()
        var count = UInt16(genesisEntries.count).littleEndian
        payload.append(Data(bytes: &count, count: 2))
        for (cid, data) in genesisEntries {
            let cidBytes = Data(cid.utf8)
            var cidLen = UInt16(cidBytes.count).littleEndian
            payload.append(Data(bytes: &cidLen, count: 2))
            payload.append(cidBytes)
            var dataLen = UInt32(data.count).littleEndian
            payload.append(Data(bytes: &dataLen, count: 4))
            payload.append(data)
        }
        let genesisHex = payload.map { String(format: "%02x", $0) }.joined()
        // Include the chain's P2P address so subscribers can use it as a bootstrap
        // peer — the deploying node is the initial peer for new chain participants.
        var chainP2PAddress: String? = nil
        let pubKey = await network.ivy.config.publicKey
        let port = await network.ivy.config.listenPort
        chainP2PAddress = "\(pubKey)@127.0.0.1:\(port)"
        struct R: Encodable {
            let directory: String; let chainPath: [String]; let genesisHash: String; let genesisHex: String
            let chainP2PAddress: String?   // bootstrap peer for new chain subscribers
        }
        return json(R(directory: dir, chainPath: chainPath, genesisHash: genesisHash, genesisHex: genesisHex, chainP2PAddress: chainP2PAddress))
    }

    static func chainSpec(node: LatticeNode, request: Request) async throws -> Response {
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let s: ChainSpec
        let currentPath = await currentChainPath(node: node)
        if chain.path == currentPath {
            s = node.genesisConfig.spec
        } else if let chainState = await node.chain(forPath: chain.path),
                  let network = await node.network(forPath: chain.path) {
            let tipHash = await chainState.getMainChainTip()
            let tipStub = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
            guard let tipBlock = try? await tipStub.resolve(fetcher: network.ivyFetcher).node,
                  let resolved = try? await tipBlock.spec.resolve(fetcher: network.ivyFetcher).node else {
                return jsonError("Chain not found: \(chain.key)", status: .notFound)
            }
            s = resolved
        } else {
            return jsonError("Chain not found: \(chain.key)", status: .notFound)
        }
        struct R: Encodable { let directory: String; let targetBlockTime: UInt64; let initialReward: UInt64; let halvingInterval: UInt64; let maxTransactionsPerBlock: UInt64; let maxStateGrowth: Int; let maxBlockSize: Int; let premine: UInt64; let premineAmount: UInt64; let wasmPolicies: [WasmPolicyRef] }
        return json(R(directory: chain.directory, targetBlockTime: s.targetBlockTime, initialReward: s.initialReward, halvingInterval: s.halvingInterval, maxTransactionsPerBlock: s.maxNumberOfTransactionsPerBlock, maxStateGrowth: s.maxStateGrowth, maxBlockSize: s.maxBlockSize, premine: s.premine, premineAmount: s.premineAmount(), wasmPolicies: s.wasmPolicies))
    }

    // MARK: - Mining Template
    // POST /api/chain/template { childNodes: [...] }
    // The node builds the complete block (postState, transactions, embedded child candidates).
    // The miner only needs to find a valid nonce — no state or topology knowledge required.

    static func deployChain(node: LatticeNode, request: Request) async throws -> Response {
        guard let buffer = try? await request.body.collect(upTo: 131_072) else {
            return jsonError("Invalid deploy request body")
        }
        let requestData = Data(buffer: buffer)
        guard let body = RPCRequestBodyCodecs.decodeDeployChain(requestData) else {
            return jsonError("Invalid deploy request body")
        }
        if body.transactionFilters != nil || body.actionFilters != nil {
            return jsonError("Legacy JavaScript filters are not supported; use wasmPolicies", status: .badRequest)
        }

        let dir = body.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir.isEmpty { return jsonError("Directory cannot be empty") }
        if dir.count > 64 { return jsonError("Directory must be 64 characters or fewer") }
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if dir.unicodeScalars.contains(where: { !allowedScalars.contains($0) }) {
            return jsonError("Directory must contain only letters, numbers, underscores, and hyphens")
        }
        // Block path traversal sequences and hidden-file names
        if dir.hasPrefix(".") {
            return jsonError("Directory cannot start with '.' (path traversal or hidden file)")
        }
        let storageDir = await node.config.storagePath.appendingPathComponent(dir)
        if FileManager.default.fileExists(atPath: storageDir.path) {
            return jsonError("Chain directory '\(dir)' already has data on disk from a prior deploy. Remove \(storageDir.path) before redeploying.", status: .conflict)
        }
        let basePath = await currentChainPath(node: node)
        let requestedChildPath: [String]
        if let bodyPath = body.chainPath {
            guard let resolved = resolveChainSelector(bodyPath, from: basePath),
                  resolved.last == dir else {
                return jsonError("Invalid chainPath for deploy", status: .badRequest)
            }
            requestedChildPath = resolved
        } else if body.parentDirectory == node.genesisConfig.directory {
            requestedChildPath = basePath + [dir]
        } else if let parentPath = await node.latticeChainPath(for: body.parentDirectory) {
            requestedChildPath = parentPath + [dir]
        } else {
            let matches = await node.deployedChildChains.values.filter { $0.directory == body.parentDirectory }
            guard matches.count == 1 else {
                return jsonError("Parent chain not found: \(body.parentDirectory)", status: .notFound)
            }
            requestedChildPath = matches[0].chainPath + [dir]
        }
        let parentChainPath = Array(requestedChildPath.dropLast())
        guard let parentDir = parentChainPath.last else {
            return jsonError("Invalid parent chain path", status: .badRequest)
        }
        guard parentDir == body.parentDirectory else {
            return jsonError("parentDirectory must match chainPath parent", status: .badRequest)
        }
        // Idempotent: if this chain is already staged return the existing genesis so the
        // caller can retry submitting the GenesisAction tx without re-deploying.
        let existingPathKey = requestedChildPath.joined(separator: "/")
        if let existing = await node.deployedChildChains[existingPathKey] {
            let pubKey2 = await node.config.publicKey
            let parentPort2: UInt16
            if let p = await node.network(for: body.parentDirectory)?.ivy.config.listenPort {
                parentPort2 = p
            } else {
                parentPort2 = await node.config.listenPort
            }
            // Contract 4: re-deploying a DETACHED child is the explicit reattach gesture —
            // clear the flag so reconcile/ensure will manage it again.
            var reattached = existing
            if existing.detached {
                reattached.detached = false
                await node.recordDeployedChildChain(reattached)
                log.info("deployChain (idempotent): reattaching previously-detached '\(dir)'")
            }
            // Single source of truth: probe → adopt-live-or-recover-dead, never spawn a
            // duplicate into a live child's ports, register only after auth succeeds.
            // Detached so the deploy HTTP response returns without waiting on the cookie.
            if await node.childSupervisor != nil {
                Task { await node.ensureSupervisedChild(reattached) }
            }
            let chainP2P2 = "\(pubKey2)@127.0.0.1:\(parentPort2)"
            struct R: Encodable {
                let directory: String; let parentDirectory: String
                let genesisHash: String; let genesisHex: String; let chainP2PAddress: String?
            }
            return json(R(directory: dir, parentDirectory: body.parentDirectory,
                          genesisHash: existing.genesisHash, genesisHex: existing.genesisHex,
                          chainP2PAddress: chainP2P2))
        }
        guard await node.network(forPath: requestedChildPath) == nil else {
            return jsonError("Chain '\(existingPathKey)' already exists", status: .conflict)
        }
        // Require the parent to be exactly local or have a registered proxy.
        // Falling through to a nearest-ancestor network would deploy the child under
        // a different parent than declared, producing an invalid parent-proof path.
        if await node.network(forPath: parentChainPath) == nil {
            if let endpoint = await node.registeredRPCEndpoint(chainPath: parentChainPath) {
                let authToken = await node.registeredRPCAuthToken(chainPath: parentChainPath)
                return await proxyRegisteredRPC(endpoint: endpoint, request: request, authToken: authToken, body: requestData)
            }
            return jsonError("Parent chain '\(parentChainPath.joined(separator: "/"))' is not local; run deploy on its owning node", status: .badRequest)
        }
        guard let parentNetwork = await node.nearestLocalNetwork(forPath: parentChainPath) else {
            return jsonError("No local storage network for parent chain: \(parentChainPath.joined(separator: "/"))", status: .notFound)
        }

        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: body.maxTransactionsPerBlock,
            maxStateGrowth: body.maxStateGrowth,
            maxBlockSize: body.maxBlockSize,
            premine: body.premine,
            targetBlockTime: body.targetBlockTime,
            initialReward: body.initialReward,
            halvingInterval: body.halvingInterval,
            retargetWindow: body.retargetWindow,
            wasmPolicies: body.wasmPolicies ?? []
        )
        guard spec.isValid else { return jsonError("Invalid chain spec (check premine < halvingInterval, non-zero fields)") }

        var policyModulesByCID: [String: Data] = [:]
        policyModulesByCID.reserveCapacity(spec.wasmPolicies.count)
        for policy in spec.wasmPolicies {
            let header = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
            guard let module = try? await header.resolve(fetcher: parentNetwork.ivyFetcher).node,
                  let data = module.toData() else {
                return jsonError("WASM policy module not found: \(policy.moduleCID)", status: .badRequest)
            }
            do {
                try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module.bytes)
            } catch {
                return jsonError("Invalid WASM policy \(policy.moduleCID): \(error)", status: .badRequest)
            }
            policyModulesByCID[policy.moduleCID] = data
        }
        let policyModules = policyModulesByCID.map { (cid: $0.key, data: $0.value) }

        var genesisTransactions: [Transaction] = []
        let premineAmt = spec.premineAmount()
        if premineAmt > 0 {
            guard premineAmt <= UInt64(Int64.max) else {
                return jsonError("Premine amount overflows Int64 — reduce initialReward or premine")
            }
            guard let recipient = body.premineRecipient, !recipient.isEmpty else {
                return jsonError("premineRecipient is required when premine > 0")
            }
            let premineBody = TransactionBody(
                accountActions: [AccountAction(owner: recipient, delta: Int64(premineAmt))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [recipient], fee: 0, nonce: 0
            )
            let bodyHeader = try HeaderImpl<TransactionBody>(node: premineBody)
            // Genesis TXs use empty signatures — they're never signature-validated (height=0).
            // This makes genesis TXs fully deterministic: reconstructible from body bytes alone.
            genesisTransactions.append(Transaction(signatures: [:], body: bodyHeader))
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let genesisBlock: Block
        do {
            genesisBlock = try await BlockBuilder.buildGenesis(
                spec: spec,
                transactions: genesisTransactions,
                timestamp: timestamp,
                target: UInt256.max,
                fetcher: parentNetwork.ivyFetcher
            )
        } catch {
            log.error("deployChain: buildGenesis failed: \(error)")
            return jsonError("Failed to build genesis block", status: .internalServerError)
        }
        let childChainPath = requestedChildPath
        do {
            let validationStorer = RPCBufferedStorer()
            try VolumeImpl<Block>(node: genesisBlock).storeRecursively(storer: validationStorer)
            var validationEntries = validationStorer.entries
            for module in policyModules {
                validationEntries[module.cid] = module.data
            }
            // Byte-identical mirror of the prior per-CID overlay (staged genesis/
            // policy entries over `parentNetwork.ivyFetcher`): entries first, then
            // the parent ivy. `batchVerifyPolicies` takes a `Fetcher`, so wrap the
            // native source in a CoalescingFetcher (transparent per-wave batching;
            // same per-CID resolution).
            let validationFetcher = CoalescingFetcher(OverlayContentSource(
                entries: validationEntries,
                fallback: IvyContentSource(parentNetwork.ivyFetcher)
            ))
            let genesisBodies = genesisTransactions.compactMap { $0.body.node }
            guard genesisBodies.count == genesisTransactions.count else {
                return jsonError("Genesis block validation failed", status: .badRequest)
            }
            // Genesis deploy validates only transaction-scope policies against the
            // deterministic genesis transaction bodies. Action-scope policies begin
            // applying to post-genesis user actions through normal tx/block validation.
            let acceptedByTransactionPolicies = await TransactionBody.batchVerifyPolicies(
                bodies: genesisBodies,
                spec: spec,
                chainPath: childChainPath,
                fetcher: validationFetcher,
                scopes: [.transaction]
            )
            guard acceptedByTransactionPolicies else {
                return jsonError("Genesis block rejected by WASM transaction policies", status: .badRequest)
            }
        } catch {
            log.error("deployChain: genesis validation failed: \(error)")
            return jsonError("Genesis block validation failed", status: .badRequest)
        }

        let genesisBootstrapEntries = genesisTransactions.compactMap { tx -> (String, Data)? in
            guard let bodyData = tx.body.node?.toData() else { return nil }
            return (tx.body.rawCID, bodyData)
        } + policyModules.map { ($0.cid, $0.data) }

        let genesisHeader = try VolumeImpl<Block>(node: genesisBlock)
        let genesisHash = genesisHeader.rawCID
        // Serialize ALL genesis sub-volumes so a child-chain process can self-bootstrap.
        // Genesis hex format: [numEntries:2LE][cidLen:2LE][cid][dataLen:4LE][data]...
        // Entry 0: genesis block bytes (first entry, NodeCommand.swift expects it here)
        // Entry 1: spec bytes (so child can initialize genesisConfig.spec)
        // Entry 2+: genesis TX body bytes and referenced WASM policy modules.
        // The child calls buildGenesis with reconstructed transactions to get a fully-inline
        // genesis block, which storeBlockRecursively then persists correctly.
        var genesisEntries: [(String, Data)] = []
        if let blockData = genesisBlock.toData() {
            genesisEntries.append((genesisHash, blockData))
        }
        if let specData = genesisBlock.spec.node?.toData() {
            genesisEntries.append((genesisBlock.spec.rawCID, specData))
        }
        genesisEntries.append(contentsOf: genesisBootstrapEntries)
        var genesisPayload = Data()
        var entryCount = UInt16(genesisEntries.count).littleEndian
        genesisPayload.append(Data(bytes: &entryCount, count: 2))
        for (cid, data) in genesisEntries {
            let cidBytes = Data(cid.utf8)
            var cidLen = UInt16(cidBytes.count).littleEndian
            genesisPayload.append(Data(bytes: &cidLen, count: 2))
            genesisPayload.append(cidBytes)
            var dataLen = UInt32(data.count).littleEndian
            genesisPayload.append(Data(bytes: &dataLen, count: 4))
            genesisPayload.append(data)
        }
        let genesisHex = genesisPayload.map { String(format: "%02x", $0) }.joined()

        do {
            try await node.deployChildChain(
                directory: dir,
                parentDirectory: body.parentDirectory,
                parentChainPath: parentChainPath,
                genesisBlock: genesisBlock,
                bootstrapEntries: genesisBootstrapEntries,
                genesisHex: genesisHex
            )
        } catch let error as NodeError {
            log.error("deployChain: deployChildChain failed: \(error)")
            return jsonError(error.description, status: .badRequest)
        } catch {
            log.error("deployChain: deployChildChain failed: \(error)")
            return jsonError("Failed to deploy chain", status: .internalServerError)
        }

        // chainP2PAddress for this directory lets the operator start the child chain process
        // with the correct parent P2P address (--subscribe-p2p). The parent
        // advertises child availability but does not run a child-chain network.
        let pubKey = await node.config.publicKey
        let parentPort: UInt16
        if let port = await node.network(for: body.parentDirectory)?.ivy.config.listenPort {
            parentPort = port
        } else {
            parentPort = await node.config.listenPort
        }
        let chainP2P = "\(pubKey)@127.0.0.1:\(parentPort)"

        // Contract 4: bring the freshly-staged child to RUNNING+REGISTERED via the same
        // probe→adopt-or-recover path used on restart and idempotent re-deploy. Detached
        // so the deploy HTTP response returns without waiting on the child's cookie. The
        // metadata was just recorded by deployChildChain above.
        if node.childSupervisor != nil,
           let metadata = await node.deployedChildChains[childChainPath.joined(separator: "/")] {
            Task { await node.ensureSupervisedChild(metadata) }
        }

        struct R: Encodable {
            let directory: String
            let parentDirectory: String
            let genesisHash: String
            let genesisHex: String   // hex bytes of the genesis block; pass to child process via --genesis-hex
            let chainP2PAddress: String?  // this chain's P2P address for child-of-child subscriptions
        }
        return json(R(
            directory: dir,
            parentDirectory: body.parentDirectory,
            genesisHash: genesisHash,
            genesisHex: genesisHex,
            chainP2PAddress: chainP2P
        ))
    }

    // MARK: - Mempool, Proof, Peers
}
