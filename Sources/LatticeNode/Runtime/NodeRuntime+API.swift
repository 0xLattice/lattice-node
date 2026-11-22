import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew
import UInt256
import VolumeBroker
import LatticeNodeAPI

/// What RPC reads besides the core's snapshot, published by the loop with
/// it: the act-on chain by height, the pool listing and the template digest,
/// and the level's executed child directories.
struct NodeReadView: Sendable {
    var actOnTip: String?
    var heights = HeightIndex()
    var poolVersion: UInt64?
    var mempool = ChainReads.MempoolListing(count: 0, bytes: 0, cids: [])
    /// The pool version `mempool.projected` was computed from, and when
    /// (`NodeRuntime.uptime`).
    var projectedVersion: UInt64?
    var projectedAt: Int64 = 0
    var templateDigest: String?
    var peers = 0
    /// The first block of the body window, when it waits, and why.
    var waiting: Waiting?
    /// What the level's sync holds, for operator status.
    var sync = NodeSyncStatus()
    /// The level core's directories of committed children (shared, grow-only).
    var children: ExecutedChildren?

    struct Waiting: Sendable, Equatable {
        let cid: String
        let reason: BodyWait
    }
}

/// Why a block has no verdict yet. A closed set with a fixed rendering:
/// status is public, so it shows nothing an error says. The error itself
/// goes to the log.
enum BodyWait: Sendable, Equatable, CustomStringConvertible {
    /// Verified content of the body is past this node's byte budget.
    case exceedsLocalBudget
    /// No peer served the body's content.
    case unavailable
    /// The block's own content arrived; the receipt proofs its withdrawals
    /// need, which travel with it, did not.
    case receiptProofsUnavailable
    /// This node's own store failed.
    case storageFailed
    /// The body is held and its connect ended without a verdict.
    case notConnected(BlockImportError)

    init(fetchFailure error: any Error) {
        switch error {
        case NodeStorageError.bodyExceedsLocalBudget: self = .exceedsLocalBudget
        case NodeStorageError.receiptProofsUnavailable: self = .receiptProofsUnavailable
        case is NodeStorageError, is NodeStoreError, is BrokerError: self = .storageFailed
        default: self = .unavailable
        }
    }

    var description: String {
        switch self {
        case .exceedsLocalBudget: return "exceeds this node's byte budget"
        case .unavailable: return "not obtained from any peer"
        case .receiptProofsUnavailable: return "its receipt proofs not obtained from any peer"
        case .storageFailed: return "local storage failed"
        case .notConnected(let failure):
            let name = switch failure {
            case .unavailableEvidence: "unavailableEvidence"
            case .providerMalformedEvidence: "providerMalformedEvidence"
            case .crossChainEvidenceRequired: "crossChainEvidenceRequired"
            case .protocolInvalid: "protocolInvalid"
            case .localVerificationFailure: "localVerificationFailure"
            case .notYetValid: "notYetValid"
            case .notAcceptedAtCurrentChain: "notAcceptedAtCurrentChain"
            case .executedVerdictContradiction: "executedVerdictContradiction"
            case .proofOfWorkInvalid: "proofOfWorkInvalid"
            }
            return "not connected: \(name)"
        }
    }
}

/// The act-on chain's block CIDs by height, in fixed-size chunks: a copy
/// published to readers shares every chunk, so the loop's next append copies
/// one chunk and the chunk list, never the whole chain.
struct HeightIndex: Sendable {
    private static let chunkSize = 4_096
    private var chunks: [[String]] = []
    private(set) var count = 0

    subscript(height: Int) -> String? {
        guard height >= 0, height < count else { return nil }
        return chunks[height / Self.chunkSize][height % Self.chunkSize]
    }

    mutating func append(_ cid: String) {
        if count % Self.chunkSize == 0 { chunks.append([]) }
        chunks[chunks.count - 1].append(cid)
        count += 1
    }

    mutating func truncate(to newCount: Int) {
        while count > max(0, newCount) {
            chunks[chunks.count - 1].removeLast()
            if chunks[chunks.count - 1].isEmpty { chunks.removeLast() }
            count -= 1
        }
    }
}

/// One hosted child level as a template job reads it: its executed tip (nil
/// when it executed no root), its pool, its difficulty anchor, and the spec a
/// genesis is built from when it has no root yet, with the account that
/// genesis pays the spec's premine to.
/// Pooled transactions a template's policy check refused on `tipCID` of
/// `path`, for that level's pool to drop.
struct PolicyRefusal: Sendable, Equatable {
    let path: ChainPath
    let tipCID: String
    let cids: [String]
}

struct ChildTemplateInput: Sendable {
    let path: ChainPath
    let tipCID: String?
    /// Whether a block of it is weighed: until one is, a creator mines its
    /// genesis (`genesisSpec`).
    let weighed: Bool
    let transactions: [Transaction]
    let anchor: DifficultyAnchor?
    let genesisSpec: ChainSpec?
    let genesisPremineRecipient: String?
    let genesisTransactions: [Transaction]
    let genesisTarget: UInt256
}

/// What a mining job reads of its level, taken on the loop when the job is
/// spawned: the snapshot of the tip it builds on as preflight reads it
/// (`ChainTree.transactionPreflightTip`, nil unless executed from genesis),
/// and, for a template, the tip's difficulty anchor. A job holds no tree:
/// anything else it reads, it reads live through `LiveLevels`.
struct MiningBasis: Sendable {
    let snapshot: TipBlockSnapshot?
    let anchor: DifficultyAnchor?
    /// For a child level's preflight: the hosted parent's executed post-state,
    /// which a withdrawal's receipt is proven in. Nil at the root, or when
    /// the parent is not hosted or has not executed.
    var parentState: LatticeStateHeader? = nil
}

/// What a child block's connect reads of its parent level: whether the
/// parent's executed set carried its state along the link Lattice asks
/// (Lattice spec §5.3 step 6), answered in one read of the live levels
/// (`LiveLevels`), so the job holds no copy of the parent's tree, which the
/// parent keeps mutating. The answer is the parent's executed set at the step
/// the read runs; a block that waits is asked again when the parent advances
/// (`wakeAnswered`). A parent the loop does not hold, or a stopped loop,
/// answers false: the block then awaits that fact
/// (`BodyPipeline.awaitingParent`), never valid on it.
struct ParentContinuity: ParentChainFacts {
    let levels: LiveLevels

    func hasContinuity(_ link: ParentStateContinuityLink) async -> Bool {
        await levels.read {
            $0[link.parentPath]?.tree.executedSetAdvanced(from: link.fromStateCID, to: link.toStateCID) ?? false
        } ?? false
    }
}

/// The hosted levels as the loop holds them, read from a job: `read` runs
/// on the loop between steps, as Bitcoin reads its live block index under
/// `cs_main`, and is nil once the loop has stopped. A recheck's tip still
/// decides whether it runs; what it reads live is the answer at the step the
/// read runs, and an anchor depends only on a block's ancestry.
struct LiveLevels: Sendable {
    /// Runs its argument on the loop, with the levels, or with nil when the
    /// loop has stopped.
    let run: @Sendable (_ read: @escaping @Sendable ([ChainPath: ChainCore]?) -> Void) -> Void

    /// Levels no loop holds: every read is nil.
    static let none = LiveLevels { $0(nil) }

    /// The levels the loop that `inputs` feeds holds.
    init(inputs: NodeRuntime.Inputs) {
        self.init { read in
            // A read the stopped loop will never see is answered here.
            if case .terminated = inputs.yield(.read(read)) { read(nil) }
        }
    }

    init(run: @escaping @Sendable (_ read: @escaping @Sendable ([ChainPath: ChainCore]?) -> Void) -> Void) {
        self.run = run
    }

    func read<T: Sendable>(_ body: @escaping @Sendable ([ChainPath: ChainCore]) -> T) async -> T? {
        await withCheckedContinuation { continuation in
            run { levels in continuation.resume(returning: levels.map(body)) }
        }
    }
}

/// An RPC's answer, from the effect that names its reply ID.
enum NodeRuntimeReply: Sendable {
    case admitted(cid: String, count: Int, bytes: Int)
    case template(WorkTemplate)
    case work(MinedOutcome)
}

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
    /// exactly as the same header gossiped from no peer, so it is held only
    /// when a weighed parent block commits it, and its content is stored as
    /// a received header's. Nothing records the submit: the author pushes
    /// again until the block is weighed (after a restart, an unhost or an
    /// eviction too).
    public func submitChildBlock(_ request: SubmitChildBlockRequest) async throws -> SubmitChildBlockResponse {
        let path = request.chainPath
        guard path.count > 1 else { throw NodeConfigurationError.invalidChainPath }
        guard let entry = WireHeaderEntry(block: request.block, children: request.children, proofs: [], spec: request.spec).decoded,
              let cid = entry.cid else { throw NodeAPIError.malformedBlock }
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
            )
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
            tipCID: tipCID,
            durableChildProofs: []
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
                    revision: nil,
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
            peerCount: { view.value?.peers ?? 0 }
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
            revision: read.revision,
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
