import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew
import UInt256
import VolumeBroker
import LatticeNodeAPI
import LatticeNodeSupport
import LatticeNodeStore

// MARK: - Operator writes: events with reply IDs, answered from effects

extension NodeRuntime {
    /// Operator pins: the node holds the Volume `root` names, serves it, and
    /// announces that it has it (unless `announcePins` is off), until the
    /// operator unpins it. A Volume the node does not hold is stored only
    /// as the operator provides it (`entries`), never read from peers.
    /// Throws when it is neither held nor provided, or when what is
    /// provided does not match its CIDs.
    public func pinVolume(_ root: String, entries: [String: Data]? = nil) async throws {
        guard !maintenanceTimer.isCancelled else { throw NodeRuntimeError.stopped }
        try await storage.pin(root, entries: entries)
        guard configuration.announcePins else { return }
        await ivy.announceProvider(rootCID: root, expiresAt: configuration.announcementExpiry(at: NodeRuntime.now()))
    }

    /// A Volume read from peers for the operator, checked against its CIDs
    /// and not stored: an application validates it, then pins it if it
    /// keeps it. Nil when no peer serves it; throws `busy` when this node's
    /// own content budget had no room to read it.
    public func fetchVolume(_ root: String) async throws -> SerializedVolume? {
        try await fetchVolume(root, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    /// `fetchVolume(_:)`, refusing a Volume whose archive is larger than
    /// `maximumArchiveBytes` or has more than `maximumEntries` entries
    /// before reading it (nil).
    public func fetchVolume(
        _ root: String, maximumArchiveBytes: Int, maximumEntries: Int
    ) async throws -> SerializedVolume? {
        guard !maintenanceTimer.isCancelled else { throw NodeRuntimeError.stopped }
        let answer = await ivy.fetchVolume(
            rootCID: root, maximumArchiveBytes: maximumArchiveBytes, maximumEntries: maximumEntries
        )
        if answer.failure == .localCapacityUnavailable { throw NodeRuntimeError.busy }
        let volume = SerializedVolume(root: answer.rootCID, entries: answer.entries)
        return volume.root == root && (try? volume.validate()) != nil ? volume : nil
    }

    public func unpinVolume(_ root: String) async throws {
        guard !maintenanceTimer.isCancelled else { throw NodeRuntimeError.stopped }
        try await storage.unpin(root)
        await ivy.stopProviding(rootCID: root)
    }

    public func pinnedVolumes() async -> [String] {
        await storage.operatorPins()
    }

    /// Host these child chains, and only these, while running: they and
    /// their specs, premine recipients, genesis transactions, seeds and
    /// policy modules replace
    /// what the node was started or last told. A dropped level's chain has
    /// its data let go of; one listed that does not start keeps it. Throws `NodeConfigurationError` for a list that does not
    /// hold together, before anything changes.
    public func host(
        _ hostedChildren: [ChainPath],
        childSpecs: [ChainPath: ChainSpec] = [:],
        childPremineRecipients: [ChainPath: String] = [:],
        childGenesisTransactions: [ChainPath: [Transaction]] = [:],
        childSeedPeers: [ChainPath: [PeerEndpoint]] = [:],
        policyModules: [Data] = []
    ) async throws {
        var next = configuration
        try next.host(
            hostedChildren, childSpecs: childSpecs, childPremineRecipients: childPremineRecipients,
            childGenesisTransactions: childGenesisTransactions,
            childSeedPeers: childSeedPeers, policyModules: policyModules
        )
        try await withCheckedThrowingContinuation { continuation in
            if case .terminated = inputs.yield(.host(next, continuation)) {
                continuation.resume(throwing: NodeRuntimeError.stopped)
            }
        }
    }

    /// The directory this node stores in.
    public var storagePath: URL { configuration.storagePath }

    /// The child chains this node hosts now, parent first.
    public var hostedChildren: [ChainPath] {
        levelReads.keys.sorted { $0.count != $1.count ? $0.count < $1.count : $0.joined(separator: "/") < $1.joined(separator: "/") }
    }

    public func submitTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        try await submit(request) { .local(replyID: $0) }
    }

    /// A submit on the opt-in public listener: the same answer, but the
    /// transaction is volatile (never journaled) and, while it waits for a
    /// verdict, held to its own pending bound; once pooled it is held to the
    /// pool's ordinary capacity rules.
    public func submitPublicTransaction(
        _ request: SubmitTransactionRequest
    ) async throws -> SubmitTransactionResponse {
        try await submit(request) { .submitted(replyID: $0) }
    }

    private func submit(
        _ request: SubmitTransactionRequest,
        origin: @escaping @Sendable (UInt64) -> TransactionOrigin
    ) async throws -> SubmitTransactionResponse {
        guard let payload = try? JSONEncoder().encode(request),
              payload.count <= NodeAPILimits.maximumPayloadBytes else {
            throw NodeAPIError.requestTooLarge
        }
        let transaction = request.transaction
        // A transaction names its chain: it goes to that level's pool.
        let path = transaction.body.node?.chainPath ?? configuration.chainPath
        guard case .admitted(let cid, let count, let bytes) = try await ask(at: path, {
            .transactionReceived(transaction, origin: origin($0))
        }) else { throw NodeRuntimeError.stopped }
        return SubmitTransactionResponse(transactionCID: cid, mempoolCount: count, mempoolBytes: bytes)
    }

    /// A child block submitted on this node (its author's push): taken
    /// exactly as the same header, with the same proofs, synced from no
    /// peer. Without proofs it is held only when a weighed parent block
    /// commits it; with them it waits for their check as a synced header
    /// does. A proof that does not verify is refused, as the peer that sent
    /// it would be disconnected. Its content is stored as a received
    /// header's. Nothing records the submit: the author pushes again until
    /// the block is weighed (after a restart, an unhost or an eviction too).
    public func submitChildBlock(_ request: SubmitChildBlockRequest) async throws -> SubmitChildBlockResponse {
        let path = request.chainPath
        guard path.count > 1 else { throw NodeConfigurationError.invalidChainPath }
        let wire = WireHeaderEntry(block: request.block, children: request.children, proofs: request.proofs ?? [], spec: request.spec)
        guard let entry = wire.decoded, let cid = entry.cid else { throw NodeAPIError.malformedBlock }
        for proof in entry.proofs
        where ChildProofJob.credit(proof.verifySecuringWork(child: entry.block, chainPath: path), at: cid) == nil {
            throw NodeAPIError.invalidChildProof
        }
        guard await LiveLevels(inputs: inputs).read({ $0[path] != nil }) == true else {
            throw NodeRuntimeError.unknownChain
        }
        if case .terminated = inputs.yield(.event(.level(path, .submitted(entry)))) {
            throw NodeRuntimeError.stopped
        }
        // Read after the submit's step: the loop takes inputs in order.
        guard let status = await LiveLevels(inputs: inputs).read({ levels -> SubmitChildBlockStatus in
            guard let level = levels[path] else { return .dropped }
            if level.tree.contains(blockHash: cid) { return .tree }
            if level.sync.pending.entries[cid] != nil { return .pending }
            if level.sync.proofs.awaiting[cid] != nil { return .awaiting }
            return .dropped
        }) else { throw NodeRuntimeError.stopped }
        return SubmitChildBlockResponse(blockCID: cid, status: status)
    }

    /// A block for the hosted child chain `request.chainPath`, taken from the
    /// template this node would mine now (its executed tip extended, or its
    /// genesis), stored and retained as a mined block is: for its author to
    /// commit on the parent (`child/X` = `C@P`) and push once a parent block
    /// carries it. `previous` is `child/X` at P now, the commitment's
    /// `oldValue`.
    public func buildChildBlock(_ request: BuildChildBlockRequest) async throws -> BuildChildBlockResponse {
        let path = request.chainPath
        guard path.count > configuration.chainPath.count, path.starts(with: configuration.chainPath) else {
            throw NodeConfigurationError.invalidChainPath
        }
        if let recipient = request.recipient, !CryptoUtils.isValidAddress(recipient) {
            throw NodeAPIError.invalidRecipientPlan
        }
        guard await LiveLevels(inputs: inputs).read({ $0[path] != nil }) == true else {
            throw NodeRuntimeError.unknownChain
        }
        let plan = TemplateRequest(rewardRecipient: nil, childRecipients: request.recipient.map { [path: $0] } ?? [:])
        guard case .template(let template) = try await ask({
            .templateRequested(replyID: $0, plan)
        }) else { throw NodeRuntimeError.stopped }
        // Down the path to C, as `carriedGrinds` walks a mined root.
        var block = template.block
        for directory in path.dropFirst(configuration.chainPath.count) {
            guard let child = block.children.node?[directory]?.node else {
                // Left out: it, or a level above it, executes its backlog
                // first.
                let root = configuration.chainPath
                if await LiveLevels(inputs: inputs).read({ NodeRuntime.mined(path, root: root, levels: $0) }) == false {
                    throw TemplateError.executing
                }
                throw NodeAPIError.noChildCandidate
            }
            block = child
        }
        let fetcher = storage.workFetcher(.chain(path))
        let children = try await storage.storeMinedBlock(block, at: path)
        let spec = block.parent == nil ? try await block.spec.resolve(fetcher: fetcher).node?.toData() : nil
        guard let blockData = block.toData(), let childrenData = children.toData() else {
            throw NodeAPIError.malformedBlock
        }
        let parentState = block.parentState.rawCID
        return BuildChildBlockResponse(
            blockCID: try BlockHeader(node: block).rawCID,
            parentState: parentState,
            previous: try await commitment(into: path, at: parentState),
            submit: SubmitChildBlockRequest(chainPath: path, block: blockData, children: childrenData, spec: spec)
        )
    }

    /// `child/X` for the hosted child `chainPath` on its parent's executed
    /// tip: the state P the next carrier enters, and the value there. Read
    /// only: nothing is built or retained.
    public func childCommitment(chainPath path: ChainPath) async throws -> ChildCommitmentResponse {
        guard path.count > configuration.chainPath.count, path.starts(with: configuration.chainPath) else {
            throw NodeConfigurationError.invalidChainPath
        }
        let parent = Array(path.dropLast())
        guard levelReads[path] != nil,
              let reads = parent == configuration.chainPath ? self.reads : levelReads[parent] else {
            throw NodeRuntimeError.unknownChain
        }
        guard let tip = await reads.readSnapshot().tipCID, let block = await reads.blockNode(cid: tip) else {
            throw NodeStorageError.missingMaterializedVolume(path.joined(separator: "/"))
        }
        let parentState = block.postState.rawCID
        return ChildCommitmentResponse(parentState: parentState, value: try await commitment(into: path, at: parentState))
    }

    /// `child/X` in the parent state `parentState`, nil when unset. Read,
    /// never guessed: a wrong `oldValue` makes a commit invalid, so a state
    /// not held here is an error.
    private func commitment(into path: ChainPath, at parentState: String) async throws -> String? {
        let fetcher = storage.workFetcher(.chain(Array(path.dropLast())))
        let key = CHILD_COMMITMENT_KEY_PREFIX + path[path.count - 1]
        guard let state = try await LatticeStateHeader(rawCID: parentState).resolve(fetcher: fetcher).node,
              let general = try await state.generalState.resolve(paths: [[key]: .targeted], fetcher: fetcher).node else {
            throw NodeStorageError.missingMaterializedVolume(parentState)
        }
        return try general.get(key: key)
    }

    public func miningTemplate(
        _ request: MiningTemplateRequest
    ) async throws -> MiningTemplateResponse {
        let started = ContinuousClock.now
        let chainPath = configuration.chainPath
        // One plan for every level the template carries: each hosted
        // child's recipient and minimum work by path.
        let recipients = try MiningPlan.validatedRecipientPlan(request.recipients, chainPath: chainPath)
        let plan = TemplateRequest(
            rewardRecipient: recipients.current,
            minimumWork: try MiningPlan.validatedMinimumWorkPlan(
                request.minimumWork, chainPath: chainPath
            ).works,
            childRecipients: Dictionary(
                recipients.descendants.map { ($0.chainPath, $0.address) }, uniquingKeysWith: { first, _ in first }
            ),
            exclude: try MiningPlan.validatedExclusions(request.exclude, chainPath: chainPath, hosted: hostedChildren)
        )
        let answer: NodeRuntimeReply
        do {
            answer = try await ask { .templateRequested(replyID: $0, plan) }
        } catch let refusal as TemplateError {
            miningMetrics.templateAnswered(refusal, after: started.duration(to: .now))
            throw refusal
        }
        guard case .template(let template) = answer else { throw NodeRuntimeError.stopped }
        miningMetrics.templateAnswered(nil, after: started.duration(to: .now))
        return MiningTemplateResponse(
            workID: template.workID,
            block: template.block,
            searchTarget: template.searchTarget,
            targets: template.targets,
            chainPath: chainPath,
            templateDigest: template.digest,
            chains: template.chains.map(TemplateChainBlock.init)
        )
    }

    /// The root's template digest now, then each time it changes: a hosted
    /// level's act-on tip or next-block transactions, its first block being
    /// weighed, the hosted set, or a level holding, or no longer, a backlog
    /// to execute (it is left out while it does: `ChainCore.holdsBacklog`).
    /// Newest only, so a slow reader skips to the latest. Ends when the
    /// runtime stops.
    public func miningEvents() -> AsyncStream<String> {
        templateDigest.updates()
    }

    /// A miner's nonce for `request.workID`, answered and timed by outcome.
    public func submitWork(_ request: SubmitWorkRequest) async throws -> SubmitWorkResponse {
        let started = ContinuousClock.now
        do {
            let response = try await work(request)
            miningMetrics.submitted(response.disposition.rawValue, after: started.duration(to: .now))
            return response
        } catch {
            miningMetrics.submitted(MiningMetrics.outcome(of: error), after: started.duration(to: .now))
            throw error
        }
    }

    private func work(_ request: SubmitWorkRequest) async throws -> SubmitWorkResponse {
        guard !request.workID.isEmpty, request.workID.utf8.count <= _wireAtomCapacity else {
            throw NodeAPIError.invalidWorkID
        }
        guard case .work(let outcome) = try await ask({
            .submitWork(replyID: $0, workID: request.workID, nonce: request.nonce)
        }) else { throw NodeRuntimeError.stopped }
        let disposition: WorkDisposition = switch outcome {
        case .executed: .canonicalized
        case .side: .acceptedSide
        case .duplicate: .duplicate
        case .childOnly: .childOnly
        case .invalid, .refused: .invalid
        }
        let tipCID: String? = if case .executed(let tip) = outcome { tip } else { published.value?.actOnTip }
        return SubmitWorkResponse(
            accepted: disposition == .canonicalized || disposition == .acceptedSide,
            disposition: disposition,
            tipCID: tipCID
        )
    }

    /// Post a mining event under a fresh reply ID and wait for its answer.
    private func ask(
        at path: ChainPath? = nil, _ event: @escaping @Sendable (UInt64) -> MiningEvent
    ) async throws -> NodeRuntimeReply {
        let path = path ?? configuration.chainPath
        return try await withCheckedThrowingContinuation { continuation in
            if case .terminated = inputs.yield(.request(path, event, continuation)) {
                continuation.resume(throwing: NodeRuntimeError.stopped)
            }
        }
    }

    // MARK: - Reads: the published snapshot and view

    static func reads(
        storage: NodeStorage,
        remote: IvyRootContentSource? = nil,
        configuration: NodeConfiguration,
        published: PublishedValue<ChainSnapshot>,
        view: PublishedValue<NodeReadView>,
        chainPath: ChainPath? = nil,
        accepted: (@Sendable (String) async -> Bool)? = nil
    ) -> ChainReads {
        ChainReads(
            storage: storage,
            remote: remote,
            chainPath: chainPath,
            accepted: accepted,
            tip: {
                let snapshot = published.value
                return ChainStatus(
                    phase: snapshot == nil || snapshot?.actOnTip.isEmpty == true ? .awaitingGenesis : .active,
                    chainPath: chainPath ?? configuration.chainPath,
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    tipCID: snapshot?.actOnTip.isEmpty == false ? snapshot?.actOnTip : nil,
                    height: snapshot?.actOnTip.isEmpty == false ? snapshot?.actOnHeight : nil,
                    bestHeaderHeight: snapshot?.bestHeaderTip.isEmpty == false ? snapshot?.bestHeaderHeight : nil,
                    waiting: view.value?.waiting.map { "body of \($0.cid): \($0.reason)" },
                    sync: view.value?.sync
                )
            },
            canonicalCID: { height in
                view.value?.heights[Int(clamping: height)]
            },
            childDirectories: { view.value?.children },
            mempool: { _ in
                view.value?.mempool ?? ChainReads.MempoolListing(count: 0, bytes: 0, cids: [])
            },
            peerCount: { view.value?.peers ?? 0 },
            minRelayFee: configuration.minRelayFee,
            finality: configuration.finality
        )
    }

    /// The read URLs declared for `chainPath`, a child of a level this node
    /// hosts: this node's own when it hosts the child, then what the hosts
    /// found at the child's rendezvous answer. A child is found through its
    /// hosts, never through what the parent commits: a committed block can
    /// lose or be withheld. `committedBlock` is the child block the parent
    /// most recently committed, for information. Nil when the parent is not
    /// hosted, or nothing hosts, declares or commits the child.
    public func chainEndpoints(_ chainPath: [String]) async -> ExplorerChainEndpoints? {
        guard chainPath.count > 1, ChainAddress(chainPath) != nil else { return nil }
        let parent = Array(chainPath.dropLast())
        guard let parentReads = parent == reads.chainPath ? reads : levelReads[parent] else { return nil }
        let hostsChild = levelReads[chainPath] != nil
        let own = hostsChild
            ? configuration.publicReadURL.map {
                [DeclaredReadEndpoint(url: $0, acceptsSubmit: configuration.publicSubmit)]
            } ?? []
            : []
        let readEndpoints = readEndpoints
        return await Self.chainEndpoints(
            chainPath, hostsChild: hostsChild, own: own,
            committed: { await parentReads.committedChild(directory: chainPath[chainPath.count - 1]) },
            found: { await readEndpoints.lookup(chainPath) }
        )
    }

    /// The parent's commitment and the hosts' answers are independent
    /// reads: asked at once, a request waits for the slower, not both.
    static func chainEndpoints(
        _ chainPath: [String],
        hostsChild: Bool,
        own: [DeclaredReadEndpoint],
        committed: @escaping @Sendable () async -> String?,
        found: @escaping @Sendable () async -> [DeclaredReadEndpoint]
    ) async -> ExplorerChainEndpoints? {
        async let committedBlock = committed()
        var declared = own
        for endpoint in await found() where !declared.contains(where: { $0.url == endpoint.url }) {
            declared.append(endpoint)
        }
        let committed = await committedBlock
        guard committed != nil || hostsChild || !declared.isEmpty else { return nil }
        return ExplorerChainEndpoints(
            chainPath: chainPath,
            committedBlock: committed,
            endpoints: declared.map(\.url),
            submitEndpoints: declared.filter(\.acceptsSubmit).map(\.url)
        )
    }

    /// `/status` of the root: the read snapshot with the template digest,
    /// and what its sync holds.
    public func status() async -> NodeStatusResponse {
        await status(of: reads, root: true)
    }

    /// `/status?chainPath=`: a hosted chain's status (nil: the root); nil
    /// when this node does not host it. The template digest is the root's.
    public func status(chainPath: [String]?) async -> NodeStatusResponse? {
        guard let chainPath, chainPath != configuration.chainPath else { return await status() }
        guard let reads = levelReads[chainPath] else { return nil }
        return await status(of: reads, root: false)
    }

    private func status(of reads: ChainReads, root: Bool) async -> NodeStatusResponse {
        let read = await reads.readSnapshot()
        var status = NodeStatusResponse(
            phase: read.phase,
            chainPath: read.chainPath,
            nexusGenesisCID: read.nexusGenesisCID,
            tipCID: read.tipCID,
            height: read.height,
            mempoolCount: read.mempoolCount,
            mempoolBytes: read.mempoolBytes,
            templateDigest: !root || read.tipCID == nil ? nil : readView.value?.templateDigest,
            bestHeaderHeight: read.bestHeaderHeight,
            waiting: read.waiting,
            version: LatticeNodeVersion.current
        )
        status.sync = await reads.tip().sync
        if let advanced = status.sync?.tipAdvancedAt {
            status.sync?.secondsSinceTipAdvanced = max(0, Date().timeIntervalSince1970 - advanced)
        }
        return status
    }

    /// Ready overlay sessions: Nexus's current peers.
    public var peerCount: Int { readView.value?.peers ?? 0 }

    public func metricsExposition(peers: Int, processStartTime: Date) async -> String {
        let snapshot = published.value
        var chains: [NodeMetricsSample.Chain] = []
        // The root, then each hosted child level.
        let levels = [(configuration.chainPath, reads)] + levelReads.filter { $0.key != configuration.chainPath }
            .sorted { $0.key.joined(separator: "/") < $1.key.joined(separator: "/") }.map { ($0.key, $0.value) }
        for (path, reads) in levels {
            let tip = await reads.tip()
            chains.append(NodeMetricsSample.Chain(
                path: path, validatedTipHeight: tip.height, weighedTipHeight: tip.bestHeaderHeight,
                tipAdvancedAt: tip.sync?.tipAdvancedAt, blockedOn: tip.sync?.blockedOn, synced: tip.sync?.synced,
                headersSynced: tip.sync?.headersSynced, jobsQueued: tip.sync?.jobsQueued
            ))
        }
        return renderNodeMetrics(NodeMetricsSample(
            chainPath: configuration.chainPath,
            validatedTipHeight: snapshot?.actOnHeight,
            weighedTipHeight: snapshot?.bestHeaderHeight,
            overlayPeers: peers,
            mempoolTransactions: snapshot?.mempoolCount ?? 0,
            processStartTime: processStartTime,
            chains: chains,
            mining: miningMetrics.snapshot
        ))
    }
}
