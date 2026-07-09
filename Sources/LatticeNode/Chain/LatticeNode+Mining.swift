import Lattice
import LatticeMinerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Ivy
import Tally
import UInt256
import cashew
import VolumeBroker

public enum MiningWorkSubmissionStatus: String, Sendable, Codable, Equatable {
    case accepted
    case duplicate
    case malformed
    case rejected
    case stale
    case unavailable
    case wrongChain
    case hashMismatch
    case wrongTarget
}

public struct MiningWorkSubmissionResult: Sendable, Equatable {
    public let status: MiningWorkSubmissionStatus
    public let blockHash: String?
    public let height: UInt64?
    public let message: String?

    public var accepted: Bool { status == .accepted }

    public init(
        status: MiningWorkSubmissionStatus,
        blockHash: String? = nil,
        height: UInt64? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.blockHash = blockHash
        self.height = height
        self.message = message
    }
}

private struct ChildRPCForwarder: Sendable {
    let endpoint: String
    let authToken: String?
}

extension LatticeNode {


    /// Produce exactly one block on demand and submit it, using the same block
    /// assembly + proof-of-work the external miner relies on, but without the
    /// continuous mining loop or the `--mine`/RPC wiring. Returns `true` only
    /// if the produced block was accepted. This is a test/utility hook — the external
    /// `lattice-miner` is the only production miner.
    public func produceAndSubmitBlock(identity: MinerIdentity? = nil, timestampOverride: Int64? = nil) async -> Bool {
        let nexusDir = genesisConfig.directory
        guard !isChainUnavailable(directory: nexusDir) else { return false }
        guard let network = network(for: nexusDir),
              let chainState = await chain(for: nexusDir) else { return false }
        let key = chainKey(forDirectory: nexusDir)
        let minerIdentity = identity ?? coinbaseAuthority
        let producer = BlockProducer(
            chainState: chainState,
            mempool: network.nodeMempool,
            fetcher: network.ivyFetcher,
            spec: genesisConfig.spec,
            chainPath: [nexusDir],
            identity: minerIdentity,
            coinbaseRecipientAddress: identity?.address ?? config.coinbaseAddress ?? nodeAddress,
            batchSize: config.resources.miningBatchSize,
            tipCache: tipCaches[key],
            timestampOverride: timestampOverride
        )
        guard let produced = try? await producer.produceBlock() else { return false }
        guard produced.rootClearsTarget else { return false }
        let dir = nexusDir
        return await submitMinedBlock(directory: dir, block: produced.block, pendingRemovals: produced.pendingRemovals)
    }


    @discardableResult
    public func submitMinedBlock(directory: String, block: Block, pendingRemovals: MinedBlockPendingRemovals? = nil) async -> Bool {
        guard !isChainUnavailable(directory: directory) else { return false }
        guard let network = network(for: directory) else { return false }
        return await submitMinedBlock(directory: directory, chainPath: nil, network: network, block: block, pendingRemovals: pendingRemovals)
    }

    @discardableResult
    public func submitMinedBlock(chainPath: [String], block: Block, pendingRemovals: MinedBlockPendingRemovals? = nil) async -> Bool {
        guard let directory = chainPath.last, !isChainUnavailable(chainPath: chainPath) else { return false }
        guard let network = network(forPath: chainPath) else { return false }
        return await submitMinedBlock(directory: directory, chainPath: chainPath, network: network, block: block, pendingRemovals: pendingRemovals)
    }

    private func submitMinedBlock(
        directory: String,
        chainPath: [String]?,
        network: ChainNetwork,
        block: Block,
        pendingRemovals: MinedBlockPendingRemovals? = nil
    ) async -> Bool {
        // known-valid local node; CID cannot fail
        let header = try! VolumeImpl<Block>(node: block)
        guard let blockData = block.toData() else { return false }

        let log = NodeLogger("miner")
        log.info("\(directory): mined block \(String(header.rawCID.prefix(16)))… at index \(block.height) (txs=\(block.transactions.node?.count ?? 0))")

        // Store the candidate's data locally so it can be validated, but do NOT
        // pin or announce it yet — a mined block that turns out to be rejected
        // must never be retained or advertised as chain storage. If candidate
        // storage fails, abort before validation/publish: validation would still
        // pass against the in-memory block, but the block would then advance
        // without its data ever being durably stored or pinned.
        guard let storedRoots = await storeBlockData(block, network: network) else {
            log.error("\(directory): failed to store mined block \(String(header.rawCID.prefix(16)))… locally — aborting submit")
            return false
        }
        do {
            try await network.pinBatchDurably(roots: storedRoots, owner: candidateStorageOwner(block: block, network: network))
        } catch {
            log.error("\(directory): failed to pin mined candidate \(String(header.rawCID.prefix(16)))… locally — aborting submit: \(error)")
            return false
        }
        await preWarmValidationCache(block, network: network)

        let outcome = await processBlockAndRecoverReorg(
            header: header,
            directory: directory,
            chainPath: chainPath,
            fetcher: network.ivyFetcher,
            resolvedBlock: block,
            requireDurableResolvedBlock: true,
            preStoredCIDs: storedRoots
        )
        let accepted = outcome == .accepted
        if !accepted && outcome != .storageFailed {
            await unpinBlockStorageForRejectedCandidate(block, storedRoots: storedRoots, network: network)
        }
        if outcome == .rejected {
            log.warn("\(directory): mined block at index \(block.height) was NOT accepted")
        } else if outcome == .storageFailed {
            log.error("\(directory): mined block at index \(block.height) was accepted but not durably stored")
        }
        if accepted {
            await network.publishBlock(cid: header.rawCID, data: blockData)

            // Settlement: submit mining work to Ivy creditors. The block hash serves
            // as proof of work — creditors verify it meets target.
            let blockHash = Data(header.rawCID.utf8)
            await settleWithCreditors(network: network, nonce: block.nonce, blockHash: blockHash)

            // `accepted` means the block was valid and may have moved fork choice;
            // it does not promise this exact candidate became canonical. A local
            // side block must not consume mempool transactions from the canonical
            // miner queue.
            let submittedChain: ChainState?
            if let chainPath {
                submittedChain = await chain(forPath: chainPath)
            } else {
                submittedChain = await chain(for: directory)
            }
            let promoted = await submittedChain?.isOnMainChain(hash: header.rawCID) ?? false
            if promoted, let removals = pendingRemovals {
                await network.pruneConfirmedTransactions(txCIDs: removals.nexusTxCIDs)
            }
        }
        if outcome != .storageFailed {
            await maybePersist(directory: directory)
        }
        return accepted
    }

    @discardableResult
    private func submitMinedChildBlock(
        chainPath: [String],
        block: Block,
        rootHash: UInt256,
        proof: ChildBlockProof,
        rpcForwarder: ChildRPCForwarder? = nil
    ) async -> Bool {
        guard let directory = chainPath.last,
              !isChainUnavailable(chainPath: chainPath) else { return false }
        guard let network = network(forPath: chainPath) else {
            if await forwardMinedChildBlockIfRegistered(
                chainPath: chainPath,
                block: block,
                proof: proof
            ) {
                return true
            }
            if let rpcForwarder {
                return await forwardMinedChildBlock(
                    chainPath: chainPath,
                    block: block,
                    proof: proof,
                    forwarder: rpcForwarder
                )
            }
            return false
        }

        let header = try! VolumeImpl<Block>(node: block)
        guard let blockData = block.toData() else { return false }
        guard let parentAnchor = await verifiedCommittingParentAnchor(
            directory: directory,
            chainPath: chainPath,
            childBlock: block,
            childCID: header.rawCID,
            proof: proof
        ) else { return false }
        guard let storedRoots = await storeBlockData(block, network: network) else {
            NodeLogger("miner").error("\(directory): failed to store mined child block \(String(header.rawCID.prefix(16)))… locally — aborting submit")
            return false
        }
        do {
            try await network.pinBatchDurably(roots: storedRoots, owner: candidateStorageOwner(block: block, network: network))
        } catch {
            NodeLogger("miner").error("\(directory): failed to pin mined child candidate \(String(header.rawCID.prefix(16)))… locally — aborting submit: \(error)")
            return false
        }
        await preWarmValidationCache(block, network: network)

        await preloadInheritedWeight(directory: directory, blockHash: header.rawCID, proof: proof)
        // Native wave-batched validation base source (#287): proof-entry overlay
        // over the network ivy. `OverlayContentSource` batches a wave; the
        // `IvyContentSource` fallback fetches misses as whole bundles. The
        // block-processing entry takes a `Fetcher`, so wrap the source in a
        // `CoalescingFetcher` — byte-identical to the retired per-CID proof-entry
        // overlay over `network.ivyFetcher`.
        let validationBaseSource = OverlayContentSource(
            entries: proof.entryMap,
            fallback: IvyContentSource(network.ivyFetcher)
        )
        let validationFetcher: Fetcher = CoalescingFetcher(validationBaseSource)
        let outcome = await processBlockAndRecoverReorg(
            header: header,
            directory: directory,
            chainPath: chainPath,
            fetcher: validationFetcher,
            resolvedBlock: block,
            rootHash: rootHash,
            parentAnchor: parentAnchor,
            requireDurableResolvedBlock: true,
            preStoredCIDs: storedRoots,
            baseValidationSourceOverride: validationBaseSource
        )
        let accepted = outcome == .accepted
        if !accepted && outcome != .storageFailed {
            await unpinBlockStorageForRejectedCandidate(block, storedRoots: storedRoots, network: network)
        }
        if accepted || outcome == .duplicate {
            await persistAcceptedBlockProof(directory: directory, height: block.height, blockHash: header.rawCID, proof: proof)
            guard await applyInheritedWeight(directory: directory, blockHash: header.rawCID, proof: proof, source: IvyContentSource(network.ivyFetcher)) else {
                return false
            }
        }
        // Held-heavier rescue: a proof-verified child block that did NOT enter
        // the chain (e.g. a below-tip connector dropped by the push height
        // guard) is cached so the connector rescue can replay it once the chain
        // declares its CID a missing ancestor; a non-promoted add may have just
        // declared such an ancestor — schedule a drain either way.
        if outcome == .rejected {
            cacheDetachedChildEvidence(
                directory: directory,
                chainPath: chainPath,
                cid: header.rawCID,
                blockData: blockData,
                selectedAnchor: parentAnchor,
                processingRootHash: rootHash,
                verified: [VerifiedChildProofEvidence(proof: proof, anchor: parentAnchor, rootHash: rootHash)]
            )
        }
        if outcome != .storageFailed {
            scheduleChildConnectorRescue(directory: directory, chainPath: chainPath)
        }
        if accepted {
            // Route through the canonical publish choke point so the tip announce
            // is gated on the promoted-to-tip contract: a mined child that lands
            // as a SIDE FORK (lost fork choice) must not be announced as the tip.
            // announceCurrentTipWhenNotPromoted mirrors the child-chain gossip
            // ingestion path (keeps peers' headers-first sync primed).
            await publishAcceptedBlock(
                block: block,
                cid: header.rawCID,
                data: blockData,
                network: network,
                childRelayRootHash: rootHash,
                childRelayProofs: [proof],
                announceCurrentTipWhenNotPromoted: true
            )
            await forwardParentContinuityToRegisteredDirectChildren(
                parentPath: chainPath,
                parentDirectory: directory,
                blockData: blockData
            )
        }
        if outcome != .storageFailed {
            await maybePersist(directory: directory)
        }
        return accepted
    }

    @discardableResult
    public func submitProvenChildBlock(
        chainPath: [String],
        block: Block,
        proof: ChildBlockProof
    ) async -> MiningWorkSubmissionResult {
        guard let root = await proof.anchorRoot() else {
            return MiningWorkSubmissionResult(status: .malformed, message: "Invalid child proof")
        }
        guard await submitMinedChildBlock(
            chainPath: chainPath,
            block: block,
            rootHash: root.hash,
            proof: proof
        ) else {
            let cid = try! VolumeImpl<Block>(node: block).rawCID
            return MiningWorkSubmissionResult(status: .rejected, blockHash: cid, height: block.height)
        }
        return MiningWorkSubmissionResult(
            status: .accepted,
            blockHash: try! VolumeImpl<Block>(node: block).rawCID,
            height: block.height
        )
    }

    private func forwardMinedChildBlockIfRegistered(
        chainPath: [String],
        block: Block,
        proof: ChildBlockProof
    ) async -> Bool {
        guard let endpoint = registeredRPCEndpoint(chainPath: chainPath),
              let blockData = block.toData() else {
            return false
        }
        return await forwardMinedChildBlock(
            chainPath: chainPath,
            blockData: blockData,
            proof: proof,
            forwarder: ChildRPCForwarder(
                endpoint: endpoint,
                authToken: registeredRPCAuthToken(chainPath: chainPath)
            )
        )
    }

    private func forwardMinedChildBlock(
        chainPath: [String],
        block: Block,
        proof: ChildBlockProof,
        forwarder: ChildRPCForwarder
    ) async -> Bool {
        guard let blockData = block.toData() else { return false }
        return await forwardMinedChildBlock(
            chainPath: chainPath,
            blockData: blockData,
            proof: proof,
            forwarder: forwarder
        )
    }

    /// Push a freshly-minted parent block to one child node for state continuity
    /// (see RPCRoutes.parentContinuity). Fire-and-forget best effort: the child
    /// also learns the same transition via gossip and can fetch it on demand, so
    /// a dropped push only forgoes the synchronous fast path, never correctness.
    private nonisolated static func forwardParentContinuity(
        parentDirectory: String,
        blockHex: String,
        forwarder: ChildRPCForwarder
    ) async {
        guard let url = URL(string: forwarder.endpoint + "/chain/parent-continuity") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken = forwarder.authToken,
           !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "parentDirectory": parentDirectory,
            "blockHex": blockHex
        ])
        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(for: request)
    }

    private func forwardMinedChildBlock(
        chainPath: [String],
        blockData: Data,
        proof: ChildBlockProof,
        forwarder: ChildRPCForwarder
    ) async -> Bool {
        guard let url = URL(string: forwarder.endpoint + "/chain/submit-child-block") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken = forwarder.authToken,
           !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        let proofHex = proof.serialize().map { String(format: "%02x", $0) }.joined()
        let blockHex = blockData.map { String(format: "%02x", $0) }.joined()
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chainPath": chainPath,
            "blockHex": blockHex,
            "proofHex": proofHex
        ])
        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 409 else { return false }
            struct R: Decodable {
                let accepted: Bool
                let status: String?
            }
            guard let decoded = try? JSONDecoder().decode(R.self, from: data) else { return false }
            return decoded.accepted || decoded.status == MiningWorkSubmissionStatus.duplicate.rawValue
        } catch {
            NodeLogger("miner").warn("\(chainPath.joined(separator: "/")): failed to forward child-only work: \(error)")
            return false
        }
    }

    /// Submit a proof-of-work result for a node-built candidate. `workId` is the
    /// CID of the nonce-0 candidate returned by the template/work endpoint. The
    /// node resolves that exact candidate from local storage, verifies it is still
    /// the current work for `chainPath`, applies the nonce, checks PoW, then reuses
    /// the normal mined-block acceptance/persistence/gossip path.
    public func submitWork(
        chainPath: [String],
        workId: String,
        nonce: UInt64,
        resultHash: String? = nil,
        childNodes: [String] = [],
        childNodeAuth: [String: String] = [:]
    ) async -> MiningWorkSubmissionResult {
        guard !chainPath.isEmpty, !workId.isEmpty else {
            return MiningWorkSubmissionResult(status: .malformed, message: "Missing chainPath or workId")
        }
        guard !isChainUnavailable(chainPath: chainPath) else {
            return MiningWorkSubmissionResult(status: .unavailable, message: "Chain is unavailable")
        }
        guard let network = network(forPath: chainPath),
              let chainState = await chain(forPath: chainPath) else {
            return MiningWorkSubmissionResult(status: .wrongChain, message: "Unknown chain path")
        }

        // Resolve the just-stored template from canonical content storage.
        let localFetcher = network.canonicalContentFetcher()
        let workHeader = VolumeImpl<Block>(rawCID: workId, node: nil, encryptionInfo: nil)
        // Migrate the template resolution onto the source API (resolve(paths:source:))
        // to complete the fetcher→ContentSource cutover. This is a LOCAL-BROKER site
        // (canonicalContentFetcher, not network ivy), so there is no network
        // wave-batching to gain: bridging the EXACT localFetcher via
        // FetcherContentSource is byte-identical to the prior resolution
        // (sequential per-CID over the local broker). API-consistency bridge, not a
        // perf win — that win lives only on the network tier (#287). localFetcher is
        // retained below (spec.resolve, collectValidChildBlocksFromMinedRoot).
        let templateSource = FetcherContentSource(localFetcher)
        guard let template = try? await workHeader.resolve(paths: Block.contentResolutionPaths, source: templateSource).node else {
            return MiningWorkSubmissionResult(status: .malformed, message: "Unknown or unavailable workId")
        }
        guard try! VolumeImpl<Block>(node: template).rawCID == workId,
              template.nonce == 0,
              template.parent != nil else {
            return MiningWorkSubmissionResult(status: .malformed, message: "workId does not name a nonce-0 candidate")
        }
        // Bind the work to THIS chain. Directory is positional, and spec CID can no
        // longer distinguish chains (chains may share economics — e.g. testnet and
        // mainnet share a spec), so the old `templateSpec.directory == directory`
        // guard is replaced by a stronger binding: a template belongs to this chain
        // iff it extends a block this chain knows. Cross-chain work replay is also
        // caught downstream by chainPath validation in block acceptance.
        guard let templateParentCID = template.parent?.rawCID,
              await chainState.contains(blockHash: templateParentCID) else {
            return MiningWorkSubmissionResult(status: .wrongChain, message: "workId does not extend this chain")
        }

        let sealed = ProofOfWork.withNonce(template, nonce: nonce)
        let sealedHeader = try! VolumeImpl<Block>(node: sealed)
        let sealedCID = sealedHeader.rawCID
        if await chainState.contains(blockHash: sealedCID) {
            return MiningWorkSubmissionResult(
                status: .duplicate,
                blockHash: sealedCID,
                height: sealed.height,
                message: "Block already accepted"
            )
        }

        let currentTip = await chainState.getMainChainTip()
        guard template.parent?.rawCID == currentTip else {
            return MiningWorkSubmissionResult(status: .stale, message: "workId is not based on the current tip")
        }

        let computedHash = sealed.proofOfWorkHash()
        if let resultHash, !resultHash.isEmpty,
           normalizeHex(resultHash) != normalizeHex(computedHash.toHexString()) {
            return MiningWorkSubmissionResult(status: .hashMismatch, message: "Submitted hash does not match workId + nonce")
        }
        let sealedClearsTarget = sealed.validateProofOfWork(nexusHash: computedHash)
        let validChildren = await collectValidChildBlocksFromMinedRoot(
            rootBlock: sealed,
            rootPath: chainPath,
            rootHash: computedHash,
            fetcher: localFetcher
        )
        guard sealedClearsTarget || !validChildren.isEmpty else {
            return MiningWorkSubmissionResult(status: .wrongTarget, message: "Nonce does not satisfy target")
        }

        var acceptedHash: String?
        var acceptedHeight: UInt64?
        var acceptedAny = false
        let childRPCForwarders = await childRPCForwarders(
            rootPath: chainPath,
            childNodes: childNodes,
            childNodeAuth: childNodeAuth
        )
        if sealedClearsTarget {
            if await submitMinedBlock(chainPath: chainPath, block: sealed) {
                acceptedAny = true
                acceptedHash = sealedCID
                acceptedHeight = sealed.height
                // Push this parent transition to EVERY child, embedded or not, so
                // each child's continuity index stays current as the parent
                // advances (user directive: a block minted on the parent but not on
                // a child must still reach the child for state continuity). The
                // child verifies the block itself; this is best-effort and never
                // gates parent acceptance.
                if let parentDirectory = chainPath.last,
                   let blockData = sealed.toData() {
                    await forwardParentContinuityToDirectChildren(
                        parentDirectory: parentDirectory,
                        blockData: blockData,
                        forwarders: directChildForwarders(
                            parentPath: chainPath,
                            from: childRPCForwarders
                        )
                    )
                }
            }
        }
        for child in validChildren {
            if await submitMinedChildBlock(
                chainPath: child.chainPath,
                block: child.block,
                rootHash: computedHash,
                proof: child.proof,
                rpcForwarder: childRPCForwarders[chainKey(forPath: child.chainPath)]
            ) {
                acceptedAny = true
                if acceptedHash == nil {
                    acceptedHash = try! VolumeImpl<Block>(node: child.block).rawCID
                    acceptedHeight = child.block.height
                }
            }
        }
        guard acceptedAny else {
            return MiningWorkSubmissionResult(status: .rejected, blockHash: sealedCID, height: sealed.height)
        }
        return MiningWorkSubmissionResult(status: .accepted, blockHash: acceptedHash, height: acceptedHeight)
    }

    private func childRPCForwarders(
        rootPath: [String],
        childNodes: [String],
        childNodeAuth: [String: String]
    ) async -> [String: ChildRPCForwarder] {
        guard !childNodes.isEmpty else { return [:] }
        // Normalize to API-base: block delivery and candidate calls append /chain/...,
        // so the stored endpoint must always include /api.
        let validChildNodes = childNodes
            .filter(RPCRoutes.validLoopbackHTTPBaseURL)
            .map { $0.hasSuffix("/api") ? $0 : $0 + "/api" }
        guard !validChildNodes.isEmpty else { return [:] }
        // Normalize auth-map keys to match normalized endpoints (bearerToken uses exact/path-aware
        // lookup). Use a loop instead of uniqueKeysWithValues to avoid crashing when a caller sends
        // both the bare origin and the /api form (last writer wins, deterministic).
        var normalizedAuth: [String: String] = [:]
        for (k, v) in childNodeAuth {
            let bare = k.hasSuffix("/") ? String(k.dropLast()) : k
            let normalized = bare.hasSuffix("/api") ? bare : bare + "/api"
            normalizedAuth[normalized] = v
        }

        struct ChainInfo: Decodable {
            struct Chain: Decodable {
                let directory: String
                let chainPath: [String]?
            }
            let chains: [Chain]
        }
        struct NodeInfo: Sendable {
            let endpoint: String
            let chainPath: [String]
        }

        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        let infos: [NodeInfo] = await withTaskGroup(of: NodeInfo?.self) { group in
            for endpoint in validChildNodes {
                group.addTask {
                    guard let url = URL(string: endpoint + "/chain/info"),
                          let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let info = try? JSONDecoder().decode(ChainInfo.self, from: data),
                          let chain = info.chains.first else { return nil }
                    // Use the canonical chainPath served by the child; fall back to
                    // appending the leaf directory to our root path when the field is absent.
                    let path = chain.chainPath ?? (rootPath + [chain.directory])
                    return NodeInfo(endpoint: endpoint, chainPath: path)
                }
            }
            var results: [NodeInfo] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
        guard !infos.isEmpty else { return [:] }

        var forwarders: [String: ChildRPCForwarder] = [:]
        for info in infos {
            forwarders[chainKey(forPath: info.chainPath)] = ChildRPCForwarder(
                endpoint: info.endpoint,
                authToken: RPCRoutes.bearerToken(for: info.endpoint, in: normalizedAuth)
            )
        }
        return forwarders
    }

    private func directChildForwarders(
        parentPath: [String],
        from forwarders: [String: ChildRPCForwarder]
    ) -> [ChildRPCForwarder] {
        forwarders.compactMap { key, forwarder in
            let path = key.split(separator: "/").map(String.init)
            guard path.count == parentPath.count + 1,
                  Array(path.dropLast()) == parentPath else {
                return nil
            }
            return forwarder
        }
    }

    private func registeredDirectChildForwarders(parentPath: [String]) -> [ChildRPCForwarder] {
        directChildForwarders(
            parentPath: parentPath,
            from: Dictionary(uniqueKeysWithValues: registeredRPCEndpoints.map { key, endpoint in
                (
                    key,
                    ChildRPCForwarder(
                        endpoint: endpoint,
                        authToken: registeredRPCAuthTokens[key]
                    )
                )
            })
        )
    }

    private func forwardParentContinuityToRegisteredDirectChildren(
        parentPath: [String],
        parentDirectory: String,
        blockData: Data
    ) async {
        await forwardParentContinuityToDirectChildren(
            parentDirectory: parentDirectory,
            blockData: blockData,
            forwarders: registeredDirectChildForwarders(parentPath: parentPath)
        )
    }

    private func forwardParentContinuityToDirectChildren(
        parentDirectory: String,
        blockData: Data,
        forwarders: [ChildRPCForwarder]
    ) async {
        guard !forwarders.isEmpty else { return }
        let blockHex = blockData.map { String(format: "%02x", $0) }.joined()
        await withTaskGroup(of: Void.self) { group in
            for forwarder in forwarders {
                group.addTask { [parentDirectory, blockHex, forwarder] in
                    await Self.forwardParentContinuity(
                        parentDirectory: parentDirectory,
                        blockHex: blockHex,
                        forwarder: forwarder
                    )
                }
            }
            await group.waitForAll()
        }
    }

    private nonisolated func normalizeHex(_ value: String) -> String {
        var hex = value.lowercased()
        if hex.hasPrefix("0x") {
            hex.removeFirst(2)
        }
        while hex.first == "0", hex.count > 1 {
            hex.removeFirst()
        }
        return hex
    }

    private func collectValidChildBlocksFromMinedRoot(
        rootBlock: Block,
        rootPath: [String],
        rootHash: UInt256,
        fetcher: Fetcher
    ) async -> [MinedChildBlock] {
        let rootHeader = try! VolumeImpl<Block>(node: rootBlock)
        return await collectValidChildBlocksFromMinedParent(
            parentBlock: rootBlock,
            parentHeader: rootHeader,
            parentPath: rootPath,
            rootHash: rootHash,
            upstreamProof: nil,
            fetcher: fetcher
        )
    }

    private func collectValidChildBlocksFromMinedParent(
        parentBlock: Block,
        parentHeader: VolumeImpl<Block>,
        parentPath: [String],
        rootHash: UInt256,
        upstreamProof: ChildBlockProof?,
        fetcher: Fetcher
    ) async -> [MinedChildBlock] {
        guard let childDict = try? await parentBlock.children.resolve(
            paths: [[""]: .list],
            fetcher: fetcher
        ).node,
        let childDirs = try? childDict.allKeys(),
        !childDirs.isEmpty else { return [] }

        var mined: [MinedChildBlock] = []
        for childDir in childDirs {
            guard let childHeader: VolumeImpl<Block> = try? childDict.get(key: childDir),
                  let childBlock = try? await childHeader.resolve(fetcher: fetcher).node,
                  let localHop = try? await ChildBlockProof.generate(
                      rootHeader: parentHeader,
                      childDirectory: childDir,
                      fetcher: fetcher
                  ) else { continue }
            let childPath = parentPath + [childDir]
            let proof = upstreamProof?.composing(hop: localHop) ?? localHop
            let childCID = try! VolumeImpl<Block>(node: childBlock).rawCID
            if await MinedChildBlockSelection.accepts(
                chainPath: childPath,
                block: childBlock,
                childCID: childCID,
                rootHash: rootHash,
                proof: proof
            ) {
                mined.append(MinedChildBlock(chainPath: childPath, block: childBlock, proof: proof))
            }
            mined.append(contentsOf: await collectValidChildBlocksFromMinedParent(
                parentBlock: childBlock,
                parentHeader: childHeader,
                parentPath: childPath,
                rootHash: rootHash,
                upstreamProof: proof,
                fetcher: fetcher
            ))
        }
        return mined
    }

    /// Submit mining proof to Ivy creditors to settle outstanding debt.
    /// Each mined block is simultaneously a settlement proof — the work was real.
    /// We settle whenever we have any debt, not just past threshold, because
    /// graduated debt pressure means even small debt reduces our service quality.
    private func settleWithCreditors(network: ChainNetwork, nonce: UInt64, blockHash: Data) async {
        // Settlement disabled — Ivy ledger API not available in current Ivy version.
    }
}
