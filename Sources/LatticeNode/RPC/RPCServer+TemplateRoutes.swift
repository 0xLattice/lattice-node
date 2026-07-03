import Lattice
import LatticeNodeRPCFuzzSupport
import Foundation
import Ivy
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HTTPTypes
import cashew
import VolumeBroker
import UInt256

private final class MiningChildFanoutSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// Mining-template & candidate RPC command services for RPCServer.
// Behavior-preserving extraction : /chain/template, /chain/submit-work,
// /chain/candidate route bodies plus serialized-volume collection/storage helpers.
// Pure relocation; no logic change.

extension RPCRoutes {
    /// Cap on the miner-supplied `childNodes` fan-out list. Each entry triggers
    /// one (recursive) outbound HTTP candidate fetch; without a cap a single
    /// template/candidate request could spawn an unbounded fan-out. A real
    /// hierarchy of locally-managed child chains is small.
    static let maxChildNodesFanout = 256
    static let childFanoutRequestTimeout: TimeInterval = 5
    static let childFanoutResourceTimeout: TimeInterval = 10

    static func childFanoutSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = childFanoutRequestTimeout
        configuration.timeoutIntervalForResource = childFanoutResourceTimeout
        // ponytail: bounded loopback fanout; MiningJobManager can own this later.
        return URLSession(
            configuration: configuration,
            delegate: MiningChildFanoutSessionDelegate(),
            delegateQueue: nil
        )
    }

    struct WireSerializedVolumeHex: Codable {
        let root: String
        let entries: [String: String]

        init(root: String, entries: [String: String]) {
            self.root = root
            self.entries = entries
        }

        init(_ volume: SerializedVolume) {
            self.root = volume.root
            self.entries = volume.entries.mapValues { data in
                data.map { String(format: "%02x", $0) }.joined()
            }
        }

        init(_ body: ChainCandidateVolumeBody) {
            self.init(root: body.root, entries: body.entries)
        }

        var jsonObject: [String: Any] {
            ["root": root, "entries": entries]
        }

        var serializedVolume: SerializedVolume? {
            var decoded: [String: Data] = [:]
            decoded.reserveCapacity(entries.count)
            for (cid, hex) in entries {
                guard let data = Data(hex: hex) else { return nil }
                decoded[cid] = data
            }
            return SerializedVolume(root: root, entries: decoded)
        }
    }

    struct CandidateResp: Decodable {
        let directory: String
        let blockHex: String
        let subVolumes: [WireSerializedVolumeHex]?
        let childBlocks: [String: String]?
        let pendingTargets: [String: String]?
    }

    struct ChildChainInfoResp: Decodable {
        struct C: Decodable {
            let chainPath: [String]?
            let directory: String
            let parentDirectory: String?
            let timestamp: Int64?
        }
        let chains: [C]
    }

    struct RewardMaterial {
        let identity: MinerIdentity
        let recipientAddress: String
    }

    struct ChainTemplateResponse: Encodable {
        let workId: String
        let blockHex: String
        let childBlocks: [String: String]
        let effectiveTarget: String
        // Stable across timestamp-only template rebuilds: a coordinator uses
        // this to detect genuine staleness (the tip advanced) instead of the
        // volatile workId, which changes whenever the template timestamp changes.
        // Matches submitWork's authoritative staleness check (template.parent ==
        // current tip).
        let staleToken: String
    }

    static func hasPathPrefix(_ path: [String], _ prefix: [String]) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }

    static func isDirectChildURL(
        _ childURL: String,
        of currentPath: [String],
        currentDirectory: String,
        childPaths: [String: [String]],
        childParentDir: [String: String]
    ) -> Bool {
        if let path = childPaths[childURL] {
            return path.count == currentPath.count + 1 && hasPathPrefix(path, currentPath)
        }
        return (childParentDir[childURL] ?? currentDirectory) == currentDirectory
    }

    static func verifiedVolume(
        from body: ChainCandidateVolumeBody,
        expectedRoot: String
    ) -> SerializedVolume? {
        guard !expectedRoot.isEmpty else { return nil }
        let wire = WireSerializedVolumeHex(body)
        guard let volume = wire.serializedVolume,
              volume.root == expectedRoot,
              volume.entries[expectedRoot] != nil,
              volume.entries.allSatisfy({ ContentAddressVerifier.data($0.value, matches: $0.key) }) else {
            return nil
        }
        return volume
    }

    static func verifiedLocalParentHomesteadVolume(
        for parentCarrier: Block,
        network: ChainNetwork
    ) async -> SerializedVolume? {
        await network.verifiedLocalVolume(root: parentCarrier.prevState.rawCID)
    }

    static func descendantChildURLs(
        of directChildURL: String,
        allChildURLs: [String],
        childPaths: [String: [String]],
        childDirectory: [String: String],
        childParentDir: [String: String]
    ) -> [String] {
        if let directPath = childPaths[directChildURL] {
            return allChildURLs.filter { candidate in
                guard candidate != directChildURL,
                      let candidatePath = childPaths[candidate],
                      candidatePath.count > directPath.count else { return false }
                return hasPathPrefix(candidatePath, directPath)
            }
        }

        guard let directChildDir = childDirectory[directChildURL] else { return [] }
        func descendsFromDirectChild(_ url: String) -> Bool {
            guard url != directChildURL else { return false }
            var seen = Set<String>()
            var parent = childParentDir[url]
            while let current = parent, seen.insert(current).inserted {
                if current == directChildDir { return true }
                let parentURLs = childDirectory.compactMap { $0.value == current ? $0.key : nil }
                guard parentURLs.count == 1, let parentURL = parentURLs.first else { return false }
                parent = childParentDir[parentURL]
            }
            return false
        }
        return allChildURLs.filter(descendsFromDirectChild)
    }

    struct ChildChainTopology {
        var childPaths: [String: [String]] = [:]     // URL -> full chainPath
        var childDirectory: [String: String] = [:]   // URL -> directory
        var childParentDir: [String: String] = [:]   // URL -> parentDirectory
        var maxChildTimestampMs: Int64?              // newest child tip timestamp seen
    }

    /// Fetch /chain/info for each child URL to determine hierarchy.
    /// `maxChildTimestampMs` is the newest child tip timestamp reported: the
    /// TEMPLATE route folds it into the shared template timestamp (a parent
    /// carrier must be newer than every embedded child tip), while the
    /// CANDIDATE route ignores it because its timestamp is fixed by the
    /// coordinator's request.
    static func fetchChildChainTopology(
        childURLs: [String],
        fallbackParentDirectory: String,
        session: URLSession
    ) async -> ChildChainTopology {
        var topology = ChildChainTopology()
        await withTaskGroup(of: (String, [String]?, String, String, Int64?)?.self) { group in
            for childURL in childURLs {
                group.addTask {
                    guard let url = URL(string: "\(childURL)/chain/info"),
                          let (data, resp) = try? await session.data(from: url),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          let info = try? JSONDecoder().decode(ChildChainInfoResp.self, from: data),
                          let chain = info.chains.first else { return nil }
                    return (childURL, chain.chainPath, chain.directory, chain.parentDirectory ?? fallbackParentDirectory, chain.timestamp)
                }
            }
            for await result in group {
                if let (url, path, directory, parentDir, timestamp) = result {
                    if let path { topology.childPaths[url] = path }
                    topology.childDirectory[url] = directory
                    topology.childParentDir[url] = parentDir
                    if let timestamp {
                        topology.maxChildTimestampMs = max(topology.maxChildTimestampMs ?? timestamp, timestamp)
                    }
                }
            }
        }
        return topology
    }

    struct ChildCandidateFanout {
        var children: [String: Block] = [:]          // directory -> embedded child block
        var childBlocksHex: [String: String] = [:]   // directory (and dir/descendant) -> block hex
        var pendingTargets: [String: UInt256] = [:]  // tx-bearing descendant targets
        var subVolumes: [SerializedVolume] = []      // accumulated descendant sub-volumes
    }

    /// POST /chain/candidate to every DIRECT child of the current chain (each
    /// direct child receives its own descendant subtree and repeats the same
    /// partitioning, so a root miner can include children at arbitrary depth)
    /// and merge the responses.
    ///
    /// Sub-volumes are stored durably here: for an IN-PROCESS child into its own
    /// network; for a PER-PROCESS child (no local network) into `network` (the
    /// current chain's durable broker) instead — otherwise the embedded child
    /// block's `transactions` root reads as missing and the whole composite
    /// block is rejected by processBlockHeader. The accumulated `subVolumes`
    /// are additionally RETURNED for the candidate route, which must forward
    /// them upward in its own response; the template route is the top of the
    /// recursion and has no caller to forward them to.
    static func fetchChildCandidates(
        node: LatticeNode,
        network: ChainNetwork,
        currentPath: [String],
        currentDirectory: String,
        allChildURLs: [String],
        topology: ChildChainTopology,
        parentCarrierHex: String,
        parentHomesteadVolume: SerializedVolume?,
        timestampMs: Int64,
        childNodeAuth: [String: String]?,
        session: URLSession
    ) async -> ChildCandidateFanout {
        // Separate direct children from the full descendant set each direct
        // child should recursively consider while building its candidate.
        let directChildURLs = allChildURLs.filter {
            isDirectChildURL(
                $0,
                of: currentPath,
                currentDirectory: currentDirectory,
                childPaths: topology.childPaths,
                childParentDir: topology.childParentDir
            )
        }
        var fanout = ChildCandidateFanout()
        await withTaskGroup(of: (String, Block, [SerializedVolume], String, [String: String], [String: String])?.self) { group in
            for childURL in directChildURLs {
                let subChildURLs = descendantChildURLs(
                    of: childURL,
                    allChildURLs: allChildURLs,
                    childPaths: topology.childPaths,
                    childDirectory: topology.childDirectory,
                    childParentDir: topology.childParentDir
                )
                group.addTask {
                    guard let url = URL(string: "\(childURL)/chain/candidate") else { return nil }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let token = bearerToken(for: childURL, in: childNodeAuth) {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    var bodyDict: [String: Any] = [
                        "parentBlockHex": parentCarrierHex,
                        "timestampMs": timestampMs,
                    ]
                    if let parentHomesteadVolume {
                        bodyDict["parentHomesteadVolume"] = WireSerializedVolumeHex(parentHomesteadVolume).jsonObject
                    }
                    if !subChildURLs.isEmpty { bodyDict["childNodes"] = subChildURLs }
                    let subChildAuth = authMap(for: subChildURLs, in: childNodeAuth)
                    if !subChildAuth.isEmpty { bodyDict["childNodeAuth"] = subChildAuth }
                    // Do NOT forward this node's rewardAddress to a per-process
                    // child: each child node credits its OWN --coinbase-address.
                    // Forwarding overrode the child's configured coinbase, leaking
                    // the child's reward to the coordinator's payout (child identity
                    // got the nonce, parent address got the balance).
                    req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
                    guard let (data, resp) = try? await session.data(for: req),
                          let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                    guard let cr = try? JSONDecoder().decode(CandidateResp.self, from: data),
                          let blockData = Data(hex: cr.blockHex),
                          let block = Block(data: blockData) else { return nil }
                    let subVols = (cr.subVolumes ?? []).compactMap(\.serializedVolume)
                    return (cr.directory, block, subVols, cr.blockHex, cr.childBlocks ?? [:], cr.pendingTargets ?? [:])
                }
            }
            for await result in group {
                guard let (childDir, block, subVols, blockHex, descendantBlocks, childPendingTargets) = result else { continue }
                fanout.children[childDir] = block
                fanout.childBlocksHex[childDir] = blockHex
                // Collect descendant block hexes for miner gossip.
                for (descDir, descHex) in descendantBlocks {
                    fanout.childBlocksHex["\(childDir)/\(descDir)"] = descHex
                }
                fanout.subVolumes.append(contentsOf: subVols)
                for (pendingDir, pendingTargetHex) in childPendingTargets {
                    if let pendingTarget = UInt256(pendingTargetHex, radix: 16) {
                        let pendingKey = pendingDir == childDir ? childDir : "\(childDir)/\(pendingDir)"
                        fanout.pendingTargets[pendingKey] = pendingTarget
                    }
                }
                if !subVols.isEmpty {
                    if let childNetwork = await node.network(for: childDir) {
                        try? await childNetwork.storeVolumesDurably(subVols)
                    } else {
                        try? await network.storeVolumesDurably(subVols)
                    }
                }
            }
        }
        return fanout
    }

    static func collectSerializedVolumes(for block: Block) throws -> [SerializedVolume] {
        // Object-grain: one `storeRecursively` pass produces the block's whole owned
        // closure as per-boundary volumes joined by owned-child edges — matching
        // LatticeNode.collectBlockVolumes. transactions/children are in-package in
        // the block volume (and resolvable by CID); tx bodies, the postState trie,
        // and child blocks are sub-volumes. References (prevState/parentState/parent)
        // are not children and are fetched by CID on demand. No singleton promotion.
        let storer = BrokerStorer(broker: MemoryBroker())
        let header = try VolumeImpl<Block>(node: block)
        try header.storeRecursively(storer: storer)
        return storer.collectVolumes(root: header.rawCID)
    }

    static func storeCandidateVolumes(
        for block: Block,
        network: ChainNetwork,
        owner: String? = nil
    ) async throws -> [SerializedVolume] {
        let volumes = try collectSerializedVolumes(for: block)
        if !volumes.isEmpty {
            try await network.storeVolumesDurably(volumes)
        }
        if let owner {
            try await network.pinBatchDurably(roots: volumes.map(\.root), owner: owner)
        }
        return volumes
    }

    static func chainTemplate(node: LatticeNode, request: Request) async throws -> Response {
        // Legacy minerPrivateKey/minerPublicKey fields remain ignored. Reward
        // signing always uses node-owned key material; request bodies may select a
        // recipient address, but must never provide private key material.
        let templateData = (try? await request.body.collect(upTo: 65_536)).map { Data(buffer: $0) } ?? Data()
        var body = RPCRequestBodyCodecs.decodeChainTemplate(templateData)
            ?? ChainTemplateRequestBody(chain: nil, chainPath: nil, childNodes: nil, childNodeAuth: nil)
        if body.chain != nil {
            return jsonError("Use chainPath=Nexus/...; bare chain is no longer supported", status: .badRequest)
        }
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: body.chainPath) {
        case .success(let resolvedPath):
            if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: resolvedPath, body: templateData) {
                return proxied
            }
        case .failure(let response):
            return response
        }
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request, chainPath: body.chainPath) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        // Auto-include the children this node is ALREADY serving (supervised / followed —
        // their loopback RPC is in the registered-RPC map) into the merged template, so a
        // coordinator mines "this node + whatever it follows" without passing any --child-node.
        // Union with the caller-supplied childNodes; the loopback/count/SSRF checks below still
        // run on the combined set. Chain membership stays a NODE concern, not the miner's.
        let autoChildren = await node.registeredDirectChildEndpoints(parentPath: chain.path)
        if !autoChildren.isEmpty {
            // Append auto-children only up to the fan-out cap and dedup by normalized (/api)
            // URL, so they can NEVER push the set over maxChildNodesFanout and 400 the node's
            // OWN template (a node serving >cap children would otherwise halt even Nexus work)
            // — graceful degradation over total outage. Caller URLs are left as-is; the
            // loopback/count checks below still run on the combined set.
            func normAPI(_ s: String) -> String { s.hasSuffix("/api") ? s : s + "/api" }
            var merged = body.childNodes ?? []
            var seen = Set(merged.map(normAPI))
            var authMap = body.childNodeAuth ?? [:]
            for c in autoChildren {
                let key = normAPI(c.url)
                guard !seen.contains(key), merged.count < maxChildNodesFanout else { continue }
                seen.insert(key)
                merged.append(c.url)
                if let a = c.auth { authMap[c.url] = a }
            }
            body = ChainTemplateRequestBody(chain: body.chain, chainPath: body.chainPath,
                                            childNodes: merged, childNodeAuth: authMap.isEmpty ? nil : authMap,
                                            rewardAddress: body.rewardAddress)
        }
        let dir = chain.directory
        guard let chainState = await node.chain(forPath: chain.path),
              let network = await node.network(forPath: chain.path) else {
            return jsonError("Unknown chain path: \(chain.key)", status: .notFound)
        }
        let tipHash = await chainState.getMainChainTip()
        guard !tipHash.isEmpty else {
            return jsonError("No tip available", status: .serviceUnavailable)
        }
        let tipStub = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await tipStub.resolve(fetcher: network.ivyFetcher).node else {
            return jsonError("Tip block unavailable", status: .serviceUnavailable)
        }
        guard let specNode = try? await tipBlock.spec.resolve(fetcher: network.ivyFetcher).node else {
            return jsonError("Chain spec unavailable", status: .serviceUnavailable)
        }
        let maxTxCount = Int(specNode.maxNumberOfTransactionsPerBlock) - 1
        let mempool = network.nodeMempool
        await node.refreshMempoolNonceFloorsFromTip(directory: dir, chainPath: chain.path)
        let mempoolGeneration = await mempool.currentGeneration
        let hasRecursiveFanout = body.childNodes?.isEmpty == false
        // SSRF/DoS input validation MUST run before the template-cache hit path:
        // a cached template must never be returned for a request carrying a
        // malicious (non-loopback / oversized) childNodes fan-out list. (The
        // I5 template cache below would otherwise short-circuit past the
        // fan-out validation at the build path.)
        if let childURLs = body.childNodes, !childURLs.isEmpty {
            guard childURLs.count <= maxChildNodesFanout else {
                return jsonError("Too many childNodes: max \(maxChildNodesFanout)", status: .badRequest)
            }
            guard childURLs.allSatisfy(validLoopbackHTTPBaseURL) else {
                return jsonError("Invalid childNodes: expected loopback http(s) base URLs", status: .badRequest)
            }
        }
        if !hasRecursiveFanout,
           let cached = await node.cachedTemplate(forKey: chain.key),
           cached.tipCID == tipHash,
           cached.mempoolGeneration == mempoolGeneration {
            let workId = try VolumeImpl<Block>(node: cached.builtBlock).rawCID
            return json(ChainTemplateResponse(
                workId: workId,
                blockHex: cached.builtData.map { String(format: "%02x", $0) }.joined(),
                childBlocks: cached.childBlocksHex,
                effectiveTarget: cached.effectiveTarget.toHexString(),
                staleToken: tipHash
            ))
        }
        var selectedTxs = await mempool.selectTransactions(maxCount: max(0, maxTxCount))
        var appendedCoinbase = false
        let target = max(tipBlock.nextTarget, ChainSpec.minimumTarget)

        let nodeConfig = await node.config
        let coinbaseAuthority = node.coinbaseAuthority
        let nodeFallbackReward = nodeConfig.coinbaseAddress.map {
            RewardMaterial(
                identity: coinbaseAuthority,
                recipientAddress: body.rewardAddress ?? $0
            )
        }
        let rewardMaterial = nodeFallbackReward
        if let rewardMaterial {
            let mempoolFetcherForCoinbase = CoalescingFetcher(await node.buildMempoolAwareSource(directory: dir, baseFetcher: network.ivyFetcher))
            if let coinbase = try? await BlockProducer.buildCoinbaseTransaction(
                spec: specNode,
                identity: rewardMaterial.identity,
                chainPath: chain.path,
                previousBlock: tipBlock, mempoolTransactions: selectedTxs,
                fetcher: mempoolFetcherForCoinbase,
                recipientAddress: rewardMaterial.recipientAddress
            ) {
                selectedTxs.append(coinbase)
                appendedCoinbase = true
            } else {
                // A coinbase address IS configured but the coinbase couldn't be built — the
                // block would silently forfeit its reward. Surface it rather than re-hiding it.
                log.warning("coinbase address configured but coinbase build returned nil for '\(dir)' — this block forfeits its reward")
            }
        }

        var children: [String: Block] = [:]
        var allChildBlocksHex: [String: String] = [:]
        var childTransactionTargets: [String: UInt256] = [:]
        var templateTimestampMs = max(Int64(Date().timeIntervalSince1970 * 1000), tipBlock.timestamp + 1)

        if let childURLs = body.childNodes, !childURLs.isEmpty {
            guard childURLs.count <= maxChildNodesFanout else {
                return jsonError("Too many childNodes: max \(maxChildNodesFanout)", status: .badRequest)
            }
            guard childURLs.allSatisfy(validLoopbackHTTPBaseURL) else {
                return jsonError("Invalid childNodes: expected loopback http(s) base URLs", status: .badRequest)
            }
            // Normalize to API-base so topology/candidate calls reach /api/chain/...
            let childURLs = childURLs.map { $0.hasSuffix("/api") ? $0 : $0 + "/api" }
            // Auth map keys must match the normalized URLs (bearerToken uses exact/path-aware match).
            // Use a loop to avoid crashing when a caller sends both bare and /api forms of the same key.
            let childNodeAuth: [String: String]? = body.childNodeAuth.map { dict in
                var result: [String: String] = [:]
                for (k, v) in dict {
                    let bare = k.hasSuffix("/") ? String(k.dropLast()) : k
                    result[bare.hasSuffix("/api") ? bare : bare + "/api"] = v
                }
                return result
            }
            let session = childFanoutSession()
            defer { session.invalidateAndCancel() }

            let topology = await fetchChildChainTopology(
                childURLs: childURLs, fallbackParentDirectory: dir, session: session
            )
            // The parent template must be newer than every embedded child tip.
            if let maxChildTs = topology.maxChildTimestampMs {
                templateTimestampMs = max(templateTimestampMs, maxChildTs + 1)
            }
            let provisionalParentCarrier: Block
            let provisionalFetcher = CoalescingFetcher(await node.buildMempoolAwareSource(directory: dir, baseFetcher: network.ivyFetcher))
            // Compute nextTarget from the in-memory main-chain timestamp index —
            // the SAME source the validator reads — so the served template and the
            // block validated on submit agree even after a content prune. Letting
            // BlockBuilder fall back to its CAS ancestor walk breaks once mining
            // outruns the retention window (pruned bodies → short window → target
            // hardened past the validator's expectation → block rejected).
            let provisionalNextTarget = await BlockProducer.canonicalNextTarget(
                chainState: chainState, spec: specNode, parentHash: tipHash,
                parentBlock: tipBlock, timestamp: templateTimestampMs,
                blockTarget: target, fetcher: provisionalFetcher
            )
            do {
                let assembled = try await TemplateAssembly.buildWithFallback(
                    directory: dir,
                    context: "provisional template",
                    transactions: selectedTxs,
                    hasCoinbase: appendedCoinbase,
                    build: { txs in
                        try await BlockBuilder.buildBlock(
                            previous: tipBlock,
                            transactions: txs,
                            timestamp: templateTimestampMs,
                            target: target,
                            nextTarget: provisionalNextTarget,
                            nonce: 0,
                            fetcher: provisionalFetcher
                        )
                    },
                    removeFromMempool: { await mempool.remove(txCID: $0) }
                )
                provisionalParentCarrier = assembled.block
                selectedTxs = assembled.transactions
                appendedCoinbase = appendedCoinbase && !selectedTxs.isEmpty
            } catch {
                return jsonError("Failed to build provisional template block", status: .serviceUnavailable)
            }
            guard let thisParentCarrierHex = provisionalParentCarrier.toData()?.map({ String(format: "%02x", $0) }).joined() else {
                return jsonError("Failed to serialize provisional parent template", status: .serviceUnavailable)
            }
            let parentHomesteadVolume = await verifiedLocalParentHomesteadVolume(
                for: provisionalParentCarrier,
                network: network
            )
            if !provisionalParentCarrier.prevState.rawCID.isEmpty && parentHomesteadVolume == nil {
                return jsonError("Parent homestead unavailable", status: .serviceUnavailable)
            }

            let fanout = await fetchChildCandidates(
                node: node,
                network: network,
                currentPath: chain.path,
                currentDirectory: dir,
                allChildURLs: childURLs,
                topology: topology,
                parentCarrierHex: thisParentCarrierHex,
                parentHomesteadVolume: parentHomesteadVolume,
                timestampMs: templateTimestampMs,
                childNodeAuth: childNodeAuth,
                session: session
            )
            children = fanout.children
            allChildBlocksHex = fanout.childBlocksHex
            childTransactionTargets = fanout.pendingTargets
            // fanout.subVolumes intentionally unused: /chain/template is the top
            // of the recursion — there is no caller to forward them to (they are
            // already stored durably inside fetchChildCandidates).
        }

        let mempoolFetcher = CoalescingFetcher(await node.buildMempoolAwareSource(directory: dir, baseFetcher: network.ivyFetcher))
        // See provisional build above: nextTarget MUST come from the in-memory
        // index so production and validation agree across a content prune.
        let templateNextTarget = await BlockProducer.canonicalNextTarget(
            chainState: chainState, spec: specNode, parentHash: tipHash,
            parentBlock: tipBlock, timestamp: templateTimestampMs,
            blockTarget: target, fetcher: mempoolFetcher
        )
        let built: Block
        do {
            let assembled = try await TemplateAssembly.buildWithFallback(
                directory: dir,
                context: "template",
                transactions: selectedTxs,
                hasCoinbase: appendedCoinbase,
                build: { txs in
                    try await BlockBuilder.buildBlock(
                        previous: tipBlock,
                        transactions: txs,
                        children: children,
                        timestamp: templateTimestampMs,
                        target: target,
                        nextTarget: templateNextTarget,
                        nonce: 0,
                        fetcher: mempoolFetcher
                    )
                },
                removeFromMempool: { await mempool.remove(txCID: $0) }
            )
            built = assembled.block
            selectedTxs = assembled.transactions
            appendedCoinbase = appendedCoinbase && !selectedTxs.isEmpty
        } catch {
            return jsonError("Failed to build template block", status: .serviceUnavailable)
        }
        guard let builtData = built.toData() else {
            return jsonError("Failed to build template block", status: .serviceUnavailable)
        }
        // Store sub-volumes through the chain's durable broker so validation
        // can resolve them locally. PIN them
        // under the candidate owner: an unpinned candidate can be reclaimed by the
        // eviction sweep in the window between serving this template and the miner
        // submitting a solution for it (store-then-GC race), after which
        // submit-work fails to resolve the workId. `releaseStaleCandidatePins`
        // drops these once the tip advances, so they never leak.
        let builtHash = try VolumeImpl<Block>(node: built).rawCID
        let candidateOwner = LatticeNode.candidateStorageOwner(
            ownerNamespace: network.ownerNamespace, height: built.height, blockHash: builtHash)
        let storedCandidateVolumes: [SerializedVolume]
        do {
            storedCandidateVolumes = try await storeCandidateVolumes(for: built, network: network, owner: candidateOwner)
        } catch {
            log.error("failed to store template volumes for \(dir): \(String(describing: error))")
            return jsonError("Failed to store template block data", status: .serviceUnavailable)
        }
        let childTargets = allChildBlocksHex.values
            .compactMap { Data(hex: $0) }
            .compactMap { Block(data: $0)?.target }
        var transactionTargets = Array(childTransactionTargets.values)
        let rootUserTxCount = appendedCoinbase ? max(0, selectedTxs.count - 1) : selectedTxs.count
        if rootUserTxCount > 0 {
            transactionTargets.append(target)
        }
        let effectiveTarget: UInt256
        if transactionTargets.isEmpty {
            // Reward-only work can settle at any level. Mine against the easiest
            // target in the assembled tree so child-only wins are surfaced.
            effectiveTarget = childTargets.reduce(target) { max($0, max($1, ChainSpec.minimumTarget)) }
        } else {
            // When user transactions are pending, avoid starving them behind
            // easier reward-only wins. Mine against the easiest tx-bearing
            // candidate; submit-work still validates which levels actually clear.
            effectiveTarget = transactionTargets.reduce(ChainSpec.minimumTarget) { max($0, max($1, ChainSpec.minimumTarget)) }
        }
        if !hasRecursiveFanout {
            await node.storeTemplate(
                LatticeNode.CachedTemplate(
                    tipCID: tipHash,
                    mempoolGeneration: mempoolGeneration,
                    builtBlock: built,
                    builtData: builtData,
                    storedCandidateVolumeRoots: storedCandidateVolumes.map(\.root),
                    effectiveTarget: effectiveTarget,
                    childBlocksHex: allChildBlocksHex,
                    timestamp: templateTimestampMs
                ),
                forKey: chain.key
            )
        }
        let workId = try VolumeImpl<Block>(node: built).rawCID
        return json(ChainTemplateResponse(
            workId: workId,
            blockHex: builtData.map { String(format: "%02x", $0) }.joined(),
            childBlocks: allChildBlocksHex,
            effectiveTarget: effectiveTarget.toHexString(),
            staleToken: tipHash
        ))
    }

    // POST /api/chain/parent-continuity { parentDirectory, blockHex }
    // A parent process pushes every block it mints to its children — whether or
    // not that block embeds a child — so each child records the parent's
    // prevState→postState continuity edge synchronously, instead of relying on
    // best-effort gossip (which the child can drop under a fast parent) plus an
    // on-demand fetch race. The pushed block is verified independently here (CID
    // re-derivation + PoW) before its transition is recorded; it never advances a
    // child tip or grants child fork-choice weight.
    static func parentContinuity(node: LatticeNode, request: Request) async -> Response {
        let data = (try? await request.body.collect(upTo: 4_194_304)).map { Data(buffer: $0) } ?? Data()
        struct Body: Decodable { let parentDirectory: String?; let blockHex: String? }
        guard let body = try? jsonDecoder.decode(Body.self, from: data),
              let parentDirectory = body.parentDirectory, !parentDirectory.isEmpty,
              let blockHex = body.blockHex,
              let blockData = Data(hex: blockHex),
              let parentBlock = Block(data: blockData),
              let parentCID = try? VolumeImpl<Block>(node: parentBlock).rawCID else {
            return jsonError("Missing parentDirectory or blockHex", status: .badRequest)
        }
        let rootHash = parentBlock.proofOfWorkHash()
        guard parentBlock.validateProofOfWork(nexusHash: rootHash) else {
            return jsonError("Parent block PoW invalid", status: .badRequest)
        }
        await node.recordPushedParentContinuity(
            parentDirectory: parentDirectory,
            parentBlock: parentBlock,
            parentCID: parentCID
        )
        return json(["accepted": true])
    }

    // POST /api/chain/submit-work { workId, nonce, hash?, chainPath? }
    // The coordinator submits nonce results; the node resolves the nonce-0
    // candidate, seals it, validates the target, accepts/persists, and publishes.

    static func submitWork(node: LatticeNode, request: Request) async throws -> Response {
        struct Body: Decodable {
            let chain: String?
            let chainPath: [String]?
            let workId: String
            let nonce: UInt64
            let hash: String?
            let childNodes: [String]?
            let childNodeAuth: [String: String]?
        }
        guard let buffer = try? await request.body.collect(upTo: 65_536) else {
            return jsonError("Missing workId or nonce", status: .badRequest)
        }
        let submitData = Data(buffer: buffer)
        guard let body = try? jsonDecoder.decode(Body.self, from: submitData) else {
            return jsonError("Missing workId or nonce", status: .badRequest)
        }
        if body.chain != nil {
            return jsonError("Use chainPath=Nexus/...; bare chain is no longer supported", status: .badRequest)
        }
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: body.chainPath) {
        case .success(let resolvedPath):
            if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: resolvedPath, body: submitData) {
                return proxied
            }
        case .failure(let response):
            return response
        }
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request, chainPath: body.chainPath) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        if let childURLs = body.childNodes, !childURLs.isEmpty {
            guard childURLs.count <= maxChildNodesFanout else {
                return jsonError("Too many childNodes: max \(maxChildNodesFanout)", status: .badRequest)
            }
            guard childURLs.allSatisfy(validLoopbackHTTPBaseURL) else {
                return jsonError("Invalid childNodes: expected loopback http(s) base URLs", status: .badRequest)
            }
        }
        let result = await node.submitWork(
            chainPath: chain.path,
            workId: body.workId,
            nonce: body.nonce,
            resultHash: body.hash,
            childNodes: body.childNodes ?? [],
            childNodeAuth: body.childNodeAuth ?? [:]
        )
        if !result.accepted {
            await node.removeCachedTemplate(forKey: chain.key)
        }
        struct R: Encodable {
            let accepted: Bool
            let status: String
            let blockHash: String?
            let height: UInt64?
            let message: String?
        }
        let status: HTTPResponse.Status
        switch result.status {
        case .accepted:
            status = .ok
        case .duplicate, .stale:
            status = .conflict
        case .unavailable:
            status = .serviceUnavailable
        case .wrongChain:
            status = .notFound
        case .malformed, .hashMismatch, .wrongTarget, .rejected:
            status = .badRequest
        }
        return json(
            R(
                accepted: result.accepted,
                status: result.status.rawValue,
                blockHash: result.blockHash,
                height: result.height,
                message: result.message
            ),
            status: status
        )
    }

    // POST /api/chain/submit-child-block { chainPath, blockHex, proofHex }
    // Private node-to-node handoff for per-process merged mining: a parent process
    // that does not own a child ChainNetwork can still deliver child-only work to
    // the registered child process. The child verifies the sparse proof and applies
    // the block locally; the parent never acquires a child fork-choice view.
    static func submitChildBlock(node: LatticeNode, request: Request) async throws -> Response {
        struct Body: Decodable {
            let chainPath: [String]?
            let blockHex: String
            let proofHex: String
        }
        guard let buffer = try? await request.body.collect(upTo: 4_194_304),
              let body = try? jsonDecoder.decode(Body.self, from: Data(buffer: buffer)),
              let bodyPath = body.chainPath,
              let blockData = Data(hex: body.blockHex),
              let block = Block(data: blockData),
              let proofData = Data(hex: body.proofHex),
              let proof = ChildBlockProof.deserialize(proofData) else {
            return jsonError("Missing or invalid child block submission", status: .badRequest)
        }
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: bodyPath) {
        case .success(let resolvedPath):
            if await node.network(forPath: resolvedPath) == nil {
                if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: resolvedPath, body: Data(buffer: buffer)) {
                    return proxied
                }
                return jsonError("Unknown chain path: \(resolvedPath.joined(separator: "/"))", status: .notFound)
            }
            let result = await node.submitProvenChildBlock(
                chainPath: resolvedPath,
                block: block,
                proof: proof
            )
            struct R: Encodable {
                let accepted: Bool
                let status: String
                let blockHash: String?
                let height: UInt64?
                let message: String?
            }
            let status: HTTPResponse.Status
            switch result.status {
            case .accepted:
                status = .ok
            case .duplicate, .stale:
                status = .conflict
            case .unavailable:
                status = .serviceUnavailable
            case .wrongChain:
                status = .notFound
            case .malformed, .hashMismatch, .wrongTarget, .rejected:
                status = .badRequest
            }
            return json(
                R(
                    accepted: result.accepted,
                    status: result.status.rawValue,
                    blockHash: result.blockHash,
                    height: result.height,
                    message: result.message
                ),
                status: status
            )
        case .failure(let response):
            return response
        }
    }

    // GET /api/chain/candidate — returns this chain's pending block for embedding
    // by a parent chain miner. The miner assembles a composite Nexus block with
    // child candidates in the `children` field. Differs from /template (which
    // returns a pre-built candidate block (nonce=0). The node builds it using its own
    // DiskBroker so all sub-CIDs (transactions dict, state nodes) are stored and
    // fetchable during validation when the miner gossips the block back.

    static func chainCandidate(node: LatticeNode, request: Request) async throws -> Response {
        let candidateData = (try? await request.body.collect(upTo: 4_194_304)).map { Data(buffer: $0) } ?? Data()
        let candidateBody = RPCRequestBodyCodecs.decodeChainCandidate(candidateData)
        if candidateBody?.chain != nil {
            return jsonError("Use chainPath=Nexus/...; bare chain is no longer supported", status: .badRequest)
        }
        switch await resolveRequestedChainPath(node: node, request: request, chainPath: candidateBody?.chainPath) {
        case .success(let resolvedPath):
            if let proxied = await proxyRegisteredRPCIfRemote(node: node, request: request, chainPath: resolvedPath, body: candidateData) {
                return proxied
            }
        case .failure(let response):
            return response
        }
        let chain: ResolvedChain
        switch await resolveChainResult(node: node, request: request, chainPath: candidateBody?.chainPath) {
        case .success(let resolved): chain = resolved
        case .failure(let response): return response
        }
        let dir = chain.directory
        guard let chainState = await node.chain(forPath: chain.path),
              let network = await node.network(forPath: chain.path) else {
            return jsonError("Unknown chain path: \(chain.key)", status: .notFound)
        }
        let tipHash = await chainState.getMainChainTip()
        guard !tipHash.isEmpty else {
            return jsonError("No candidate available", status: .serviceUnavailable)
        }
        let tipStub = VolumeImpl<Block>(rawCID: tipHash, node: nil, encryptionInfo: nil)
        guard let tipBlock = try? await tipStub.resolve(fetcher: network.ivyFetcher).node else {
            return jsonError("Tip block unavailable", status: .serviceUnavailable)
        }
        guard let specNode = try? await tipBlock.spec.resolve(fetcher: network.ivyFetcher).node else {
            return jsonError("Chain spec unavailable", status: .serviceUnavailable)
        }
        // parentBlockHex is the parent carrier block; its real prevState is the
        // parent blocktree homestead this candidate anchors to.
        // childNodes (optional): grandchild chain URLs to embed using this
        // chain's candidate prevState as their parentState.
        let decodedParentChainBlock: Block? = candidateBody?.parentBlockHex
            .flatMap { Data(hex: $0) }
            .flatMap { Block(data: $0) }
        let suppliedParentHomesteadVolume: SerializedVolume?
        if let parentHomesteadBody = candidateBody?.parentHomesteadVolume {
            guard let decodedParentChainBlock else {
                return jsonError("parentHomesteadVolume requires parentBlockHex", status: .badRequest)
            }
            guard let volume = verifiedVolume(
                from: parentHomesteadBody,
                expectedRoot: decodedParentChainBlock.prevState.rawCID
            ) else {
                return jsonError("Invalid parentHomesteadVolume", status: .badRequest)
            }
            do {
                try await network.storeVolumeDurably(volume)
            } catch {
                log.error("failed to store parent homestead volume for \(dir): \(String(describing: error))")
                return jsonError("Failed to store parent homestead volume", status: .serviceUnavailable)
            }
            suppliedParentHomesteadVolume = volume
        } else {
            suppliedParentHomesteadVolume = nil
        }
        let parentChainBlock: Block?
        if let decodedParentChainBlock {
            parentChainBlock = await node.materializeParentHomesteadForCandidate(
                directory: dir,
                parentBlock: decodedParentChainBlock
            )
        } else {
            parentChainBlock = nil
        }
        let mempoolFetcher = CoalescingFetcher(await node.buildMempoolAwareSource(directory: dir, baseFetcher: network.ivyFetcher))
        // A child chain's own fork choice is independent of parent canonicity,
        // but mining still has to extend from a child block whose parent-state
        // root is continuous with the parent carrier's prevState. Same-root
        // cases need no proof; skipped roots require already-verified parent
        // transition edges.
        guard let baseTipBlock = await node.parentCompatibleCandidateBase(
            directory: dir,
            tipBlock: tipBlock,
            parentChainBlock: parentChainBlock,
            fetcher: network.ivyFetcher
        ) else {
            return jsonError("No parent-state-continuous child candidate", status: .serviceUnavailable)
        }
        let maxTxCount = Int(specNode.maxNumberOfTransactionsPerBlock) - 1
        let mempool = network.nodeMempool
        await node.refreshMempoolNonceFloorsFromTip(directory: dir, chainPath: chain.path)
        var selectedTxs = await mempool.selectTransactions(maxCount: max(0, maxTxCount))
        var appendedCoinbase = false
        let target = max(baseTipBlock.nextTarget, ChainSpec.minimumTarget)
        let nodeConfig = await node.config
        let coinbaseAuthority = node.coinbaseAuthority
        let nodeReward = nodeConfig.coinbaseAddress.map {
            RewardMaterial(
                identity: coinbaseAuthority,
                recipientAddress: candidateBody?.rewardAddress ?? $0
            )
        }
        if let nodeReward {
            if let coinbase = try? await BlockProducer.buildCoinbaseTransaction(
                   spec: specNode,
                   identity: nodeReward.identity,
                   chainPath: chain.path,
                   previousBlock: baseTipBlock,
                   mempoolTransactions: selectedTxs,
                   fetcher: mempoolFetcher,
                   recipientAddress: nodeReward.recipientAddress
               ) {
                selectedTxs.append(coinbase)
                appendedCoinbase = true
            } else {
                // Configured coinbase that couldn't be built — surface the silent forfeit.
                log.warning("coinbase address configured but coinbase build returned nil for '\(dir)' — this block forfeits its reward")
            }
        }
        let candidateTimestampMs = candidateBody?.timestampMs ?? max(
            Int64(Date().timeIntervalSince1970 * 1000),
            baseTipBlock.timestamp + 1
        )
        // Self-similar with the parent template path: a child IS the nexus of its
        // own subtree, so its candidate's nextTarget must come from the same
        // in-memory timestamp index the validator reads — never BlockBuilder's CAS
        // ancestor walk, which breaks after a content prune and (because it also
        // re-reads up to retargetWindow ancestor bodies per template) throttles
        // candidate production so the chain can't keep pace with its parent.
        let candidateNextTarget = await BlockProducer.canonicalNextTarget(
            chainState: chainState, spec: specNode, parentHash: tipHash,
            parentBlock: baseTipBlock, timestamp: candidateTimestampMs,
            blockTarget: target, fetcher: mempoolFetcher
        )

        // Fetch child candidates if childNodes provided, using this chain's
        // candidate prevState as parentState.
        var grandchildren: [String: Block] = [:]
        var grandchildBlocksHex: [String: String] = [:]
        var pendingTargets: [String: UInt256] = [:]
        var descendantSubVolumes: [SerializedVolume] = []
        if let gcURLs = candidateBody?.childNodes, !gcURLs.isEmpty {
            guard gcURLs.count <= maxChildNodesFanout else {
                return jsonError("Too many childNodes: max \(maxChildNodesFanout)", status: .badRequest)
            }
            guard gcURLs.allSatisfy(validLoopbackHTTPBaseURL) else {
                return jsonError("Invalid childNodes: expected loopback http(s) base URLs", status: .badRequest)
            }
            // Normalize to API-base so topology/candidate calls reach /api/chain/...
            let gcURLs = gcURLs.map { $0.hasSuffix("/api") ? $0 : $0 + "/api" }
            // Auth map keys must match the normalized URLs (bearerToken uses exact/path-aware match).
            // Use a loop to avoid crashing when a caller sends both bare and /api forms of the same key.
            let gcAuth: [String: String]? = candidateBody?.childNodeAuth.map { dict in
                var result: [String: String] = [:]
                for (k, v) in dict {
                    let bare = k.hasSuffix("/") ? String(k.dropLast()) : k
                    result[bare.hasSuffix("/api") ? bare : bare + "/api"] = v
                }
                return result
            }
            let provisionalParentCarrier: Block
            do {
                let assembled = try await TemplateAssembly.buildWithFallback(
                    directory: dir,
                    context: "provisional candidate",
                    transactions: selectedTxs,
                    hasCoinbase: appendedCoinbase,
                    build: { txs in
                        try await BlockBuilder.buildBlock(
                            previous: baseTipBlock,
                            transactions: txs,
                            parentChainBlock: parentChainBlock,
                            timestamp: candidateTimestampMs,
                            target: target,
                            nextTarget: candidateNextTarget,
                            nonce: 0,
                            fetcher: mempoolFetcher
                        )
                    },
                    removeFromMempool: { await mempool.remove(txCID: $0) }
                )
                provisionalParentCarrier = assembled.block
                selectedTxs = assembled.transactions
                appendedCoinbase = appendedCoinbase && !selectedTxs.isEmpty
            } catch {
                return jsonError("Failed to build provisional candidate block", status: .serviceUnavailable)
            }
            guard let thisParentCarrierHex = provisionalParentCarrier.toData()?.map({ String(format: "%02x", $0) }).joined() else {
                return jsonError("Failed to serialize provisional parent candidate", status: .serviceUnavailable)
            }
            let parentHomesteadVolume = await verifiedLocalParentHomesteadVolume(
                for: provisionalParentCarrier,
                network: network
            )
            if !provisionalParentCarrier.prevState.rawCID.isEmpty && parentHomesteadVolume == nil {
                return jsonError("Parent homestead unavailable", status: .serviceUnavailable)
            }
            let session = childFanoutSession()
            defer { session.invalidateAndCancel() }
            let topology = await fetchChildChainTopology(
                childURLs: gcURLs, fallbackParentDirectory: dir, session: session
            )
            // topology.maxChildTimestampMs is deliberately ignored here: the
            // candidate timestamp is fixed by the coordinator's request (the
            // template route is where child tips raise the shared timestamp).
            let fanout = await fetchChildCandidates(
                node: node,
                network: network,
                currentPath: chain.path,
                currentDirectory: dir,
                allChildURLs: gcURLs,
                topology: topology,
                parentCarrierHex: thisParentCarrierHex,
                parentHomesteadVolume: parentHomesteadVolume,
                timestampMs: candidateTimestampMs,
                childNodeAuth: gcAuth,
                session: session
            )
            grandchildren = fanout.children
            grandchildBlocksHex = fanout.childBlocksHex
            pendingTargets = fanout.pendingTargets
            descendantSubVolumes = fanout.subVolumes
        }

        let built: Block
        do {
            let assembled = try await TemplateAssembly.buildWithFallback(
                directory: dir,
                context: "candidate",
                transactions: selectedTxs,
                hasCoinbase: appendedCoinbase,
                build: { txs in
                    try await BlockBuilder.buildBlock(
                        previous: baseTipBlock,
                        transactions: txs,
                        children: grandchildren,
                        parentChainBlock: parentChainBlock,
                        timestamp: candidateTimestampMs,
                        target: target,
                        nextTarget: candidateNextTarget,
                        nonce: 0,
                        fetcher: mempoolFetcher
                    )
                },
                removeFromMempool: { await mempool.remove(txCID: $0) }
            )
            built = assembled.block
            selectedTxs = assembled.transactions
            appendedCoinbase = appendedCoinbase && !selectedTxs.isEmpty
        } catch {
            return jsonError("Failed to build candidate block", status: .serviceUnavailable)
        }
        // Store all sub-volumes (transactions dict, state nodes) durably so
        // validation can resolve them when the miner gossips the block back.
        // Announce CIDs to Ivy so peer chains (e.g. grandchildren) can fetch state
        // via P2P — mirrors storeBlockRecursively which also announces stored CIDs.
        let builtHash = try VolumeImpl<Block>(node: built).rawCID
        let owner = LatticeNode.candidateStorageOwner(
            ownerNamespace: network.ownerNamespace, height: tipBlock.height + 1, blockHash: builtHash)
        let volumes: [SerializedVolume]
        do {
            volumes = try await storeCandidateVolumes(for: built, network: network, owner: owner)
            if let suppliedParentHomesteadVolume {
                try await network.pinDurably(root: suppliedParentHomesteadVolume.root, owner: owner)
            }
            let fee = await network.ivy.config.relayFee * 2
            let expiry = UInt64(Date().timeIntervalSince1970) + (await node.config.pinAnnounceExpiry)
            for volume in volumes { Task { await network.announce(cid: volume.root, expiry: expiry, fee: fee) } }
        } catch {
            log.error("failed to store candidate volumes for \(dir): \(String(describing: error))")
            return jsonError("Failed to store candidate block data", status: .serviceUnavailable)
        }
        guard let builtData = built.toData() else {
            return jsonError("Failed to serialize candidate block", status: .serviceUnavailable)
        }
        // Collect sub-volumes for the template endpoint to store in the parent's DiskBroker.
        let subVolumes = (volumes + descendantSubVolumes).map(WireSerializedVolumeHex.init)
        let userTxCount = appendedCoinbase ? max(0, selectedTxs.count - 1) : selectedTxs.count
        if userTxCount > 0 {
            pendingTargets[dir] = target
        }
        let pendingTargetHex = pendingTargets.mapValues { $0.toHexString() }
        struct R: Encodable {
            let chain: String; let directory: String; let blockHex: String
            let target: String; let subVolumes: [WireSerializedVolumeHex]; let childBlocks: [String: String]
            let pendingTargets: [String: String]
        }
        return json(R(
            chain: dir,
            directory: dir,
            blockHex: builtData.map { String(format: "%02x", $0) }.joined(),
            target: target.toHexString(),
            subVolumes: subVolumes,
            childBlocks: grandchildBlocksHex,
            pendingTargets: pendingTargetHex
        ))
    }

    // MARK: - Balance & Blocks
}
