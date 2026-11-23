import Foundation
import Lattice
import UInt256

public struct SubmitTransactionRequest: Codable, Sendable {
    public let transaction: Transaction

    public init(transaction: Transaction) {
        self.transaction = transaction
    }

    private enum CodingKeys: String, CodingKey {
        case transaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transaction = try container.decode(
            ContentBoundTransaction.self,
            forKey: .transaction
        ).transaction()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            ContentBoundTransaction(transaction: transaction),
            forKey: .transaction
        )
    }
}

public struct SubmitTransactionResponse: Codable, Sendable, Equatable {
    public let transactionCID: String
    public let mempoolCount: Int
    public let mempoolBytes: Int

    public init(transactionCID: String, mempoolCount: Int, mempoolBytes: Int) {
        self.transactionCID = transactionCID
        self.mempoolCount = mempoolCount
        self.mempoolBytes = mempoolBytes
    }
}

/// `POST /child-blocks`: a child block this node's operator holds (normally
/// its author), as a peer would gossip it without proofs: its block node's
/// bytes, its child index's, and a child genesis's spec.
public struct SubmitChildBlockRequest: Codable, Sendable {
    public let chainPath: [String]
    public let block: Data
    public let children: Data
    public let spec: Data?

    public init(chainPath: [String], block: Data, children: Data, spec: Data? = nil) {
        self.chainPath = chainPath
        self.block = block
        self.children = children
        self.spec = spec
    }
}

/// Where a submitted child block stands after the submit's step: weighed
/// in the block tree, pending its parent, awaiting a proof, or dropped as
/// the same gossip would be (no weighed parent block commits it yet).
public enum SubmitChildBlockStatus: String, Codable, Sendable, Equatable {
    case tree
    case pending
    case awaiting
    case dropped
}

/// The submitted block's CID and where it stands. The author resubmits
/// until `status` is `.tree`.
public struct SubmitChildBlockResponse: Codable, Sendable, Equatable {
    public let blockCID: String
    public let status: SubmitChildBlockStatus

    public init(blockCID: String, status: SubmitChildBlockStatus) {
        self.blockCID = blockCID
        self.status = status
    }
}

/// `POST /child-blocks/build`: a block for the hosted child chain
/// `chainPath`, built as this node's next template carries it, paying its
/// reward to `recipient`, for its author to have another chain's miners
/// commit (`child/X` = `C@P`) on the parent.
public struct BuildChildBlockRequest: Codable, Sendable {
    public let chainPath: [String]
    public let recipient: String?

    public init(chainPath: [String], recipient: String? = nil) {
        self.chainPath = chainPath
        self.recipient = recipient
    }
}

/// The built block, stored and retained here: its CID, the parent state it
/// was built on (P), the directory's current commitment value at P (the
/// commitment's `oldValue`; nil for the first), and the push that submits it
/// once a parent block commits it.
public struct BuildChildBlockResponse: Codable, Sendable {
    public let blockCID: String
    public let parentState: String
    public let previous: String?
    public let submit: SubmitChildBlockRequest

    public init(blockCID: String, parentState: String, previous: String?, submit: SubmitChildBlockRequest) {
        self.blockCID = blockCID
        self.parentState = parentState
        self.previous = previous
        self.submit = submit
    }
}

/// `GET /child-blocks/commitment?chainPath=X`: the state P the parent's
/// executed tip leaves (the one its next block enters) and `child/X` there.
public struct ChildCommitmentResponse: Codable, Sendable, Equatable {
    public let parentState: String
    public let value: String?

    public init(parentState: String, value: String?) {
        self.parentState = parentState
        self.value = value
    }
}

/// Where one chain's block reward and fees go: a wallet address for one
/// absolute chain path. The block commits it as `rewardRecipient`, which the
/// proof of work covers, so a relayer cannot swap it. Process identity is
/// never accepted as, or converted into, wallet identity.
public struct MiningRecipient: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let address: String

    public init(chainPath: [String], address: String) {
        self.chainPath = chainPath
        self.address = address
    }
}

/// A miner's minimum work per block for one absolute chain path. It is a
/// template choice, never a validity rule: that chain's block still commits
/// its scheduled target, and the template's search thresholds become
/// `min(scheduled target, minimumWorkTarget(work))`, so the miner neither
/// searches for nor submits a hash that misses it.
///
/// It is a RATE control, and only that. Declining easier hashes makes this
/// miner's blocks take longer to find; the schedule reads that arrival rate
/// and moves difficulty accordingly. Difficulty remains something the chain
/// discovers from observed timing, never something a miner asserts.
public struct MiningMinimumWork: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let work: UInt256

    public init(chainPath: [String], work: UInt256) {
        self.chainPath = chainPath
        self.work = work
    }
}

public struct MiningTemplateRequest: Codable, Sendable {
    /// A chain with no entry mines to no one: its block reward and fees burn.
    public let recipients: [MiningRecipient]
    public let minimumWork: [MiningMinimumWork]
    /// Hosted chains, by absolute path below the template's own, whose next
    /// block this template leaves out: no nonce for it makes a block there,
    /// and its threshold is in neither `searchTarget` nor `targets`. A chain
    /// that carries a hosted chain left in cannot be excluded.
    public let exclude: [[String]]

    public init(
        recipients: [MiningRecipient] = [],
        minimumWork: [MiningMinimumWork] = [],
        exclude: [[String]] = []
    ) {
        self.recipients = recipients
        self.minimumWork = minimumWork
        self.exclude = exclude
    }

    private enum CodingKeys: String, CodingKey {
        case recipients
        case minimumWork
        case exclude
        case rewards
        case mode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The signed-reward request this replaced. Refused loudly, so an old
        // miner fails instead of silently mining to no one.
        guard !container.contains(.rewards) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rewards,
                in: container,
                debugDescription: "\"rewards\" was replaced by \"recipients\""
            )
        }
        guard !container.contains(.mode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "Mining template modes do not exist"
            )
        }
        recipients = try container.decodeIfPresent(
            [MiningRecipient].self,
            forKey: .recipients
        ) ?? []
        minimumWork = try container.decodeIfPresent(
            [MiningMinimumWork].self,
            forKey: .minimumWork
        ) ?? []
        exclude = try container.decodeIfPresent(
            [[String]].self,
            forKey: .exclude
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recipients, forKey: .recipients)
        if !minimumWork.isEmpty {
            try container.encode(minimumWork, forKey: .minimumWork)
        }
        if !exclude.isEmpty {
            try container.encode(exclude, forKey: .exclude)
        }
    }
}

public struct MiningTemplateResponse: Codable, Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    /// Every target this work can clear, easiest first (`searchTarget` leads).
    public let targets: [UInt256]
    public let chainPath: [String]
    /// Kept for clients that require the field: always
    /// `pullRefreshMilliseconds`. The node never refuses work on a clock;
    /// work is valid until the tip moves.
    public let expiresInMilliseconds: UInt64
    /// A miner compares this with the status route's digest to learn its work
    /// is stale.
    public let templateDigest: String
    /// Every block a nonce for this work commits, the root first. Absent
    /// from older nodes.
    public let chains: [TemplateChainBlock]?

    /// What `expiresInMilliseconds` carries, for decoders that still
    /// require the field. Not a validity bound.
    public static let pullRefreshMilliseconds: UInt64 = 30_000

    public init(
        workID: String,
        block: Block,
        searchTarget: UInt256,
        targets: [UInt256],
        chainPath: [String],
        templateDigest: String,
        chains: [TemplateChainBlock]
    ) {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
        self.chainPath = chainPath
        self.expiresInMilliseconds = Self.pullRefreshMilliseconds
        self.templateDigest = templateDigest
        self.chains = chains
    }
}

/// One block a template commits: its chain, its committed target, its
/// height, and the address it pays (nil burns its reward). The work is
/// searched to the template's `searchTarget`, which no taken hash exceeds,
/// so a hash makes this block only when it clears both.
public struct TemplateChainBlock: Codable, Sendable, Equatable {
    public let chainPath: [String]
    public let target: UInt256
    @DecimalString public var height: UInt64
    public let rewardRecipient: String?

    public init(chainPath: [String], target: UInt256, height: UInt64, rewardRecipient: String?) {
        self.chainPath = chainPath
        self.target = target
        self.height = height
        self.rewardRecipient = rewardRecipient
    }
}

public struct SubmitWorkRequest: Codable, Sendable, Equatable {
    public let workID: String
    public let nonce: UInt64

    public init(workID: String, nonce: UInt64) {
        self.workID = workID
        self.nonce = nonce
    }
}

public enum WorkDisposition: String, Codable, Sendable, CaseIterable {
    case canonicalized
    case acceptedSide
    /// The grind cleared only child targets, not Nexus's own: the children
    /// it carries advanced and no Nexus block was mined. The work stays open.
    case childOnly
    case duplicate
    case invalid
}

public struct SubmitWorkResponse: Codable, Sendable {
    public let accepted: Bool
    public let disposition: WorkDisposition
    public let tipCID: String?

    public init(
        accepted: Bool,
        disposition: WorkDisposition,
        tipCID: String?
    ) {
        self.accepted = accepted
        self.disposition = disposition
        self.tipCID = tipCID
    }
}

public enum NodeAPIPhase: String, Codable, Sendable {
    case awaitingGenesis
    case active
}

public struct NodeStatusResponse: Codable, Sendable, Equatable {
    public let phase: NodeAPIPhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    @OptionalDecimalString public var height: UInt64?
    public let mempoolCount: Int
    public let mempoolBytes: Int
    /// Nil before the node can serve templates (no executed tip).
    public let templateDigest: String?
    /// The height of the best header chain this node knows, ahead of
    /// `height` (the tip this node acts on) while it syncs: local
    /// progress is `height` of `bestHeaderHeight`. Nil before any header.
    @OptionalDecimalString public var bestHeaderHeight: UInt64? = nil
    /// The next block this chain cannot execute yet and why — its body not
    /// fetched, or its connect ended without a verdict — while that holds.
    /// The reason is one of a fixed set; no error text is shown here. The
    /// node keeps retrying; nil when it waits on nothing.
    public var waiting: String? = nil
    /// The node's version (`LatticeNodeVersion.current`); operator status
    /// only, never the public `/health`. Nil from a node predating it.
    public var version: String? = nil
    /// When this node process started, in unix seconds; a restart in place
    /// (`POST /restart`) changes it. Operator status only.
    public var startedAt: Double? = nil
    /// What this chain's sync holds right now. Operator status only.
    public var sync: NodeSyncStatus? = nil

    public init(
        phase: NodeAPIPhase,
        chainPath: [String],
        nexusGenesisCID: String,
        tipCID: String?,
        height: UInt64? = nil,
        mempoolCount: Int,
        mempoolBytes: Int,
        templateDigest: String?,
        bestHeaderHeight: UInt64? = nil,
        waiting: String? = nil,
        version: String? = nil
    ) {
        self.phase = phase
        self.chainPath = chainPath
        self.nexusGenesisCID = nexusGenesisCID
        self.tipCID = tipCID
        self.height = height
        self.mempoolCount = mempoolCount
        self.mempoolBytes = mempoolBytes
        self.templateDigest = templateDigest
        self.bestHeaderHeight = bestHeaderHeight
        self.waiting = waiting
        self.version = version
    }
}

/// Counts of what one chain's sync holds, as its last step left them: what
/// an operator reads to see where a chain waits. Operator status only.
public struct NodeSyncStatus: Codable, Sendable, Equatable {
    /// Headers received and not yet weighed, most waiting for their parent
    /// header.
    public var pendingHeaders = 0
    /// Child-chain headers waiting for a proof that weighs them.
    public var headersAwaitingProof = 0
    /// Peers' proofs in a check (one job per page of headers).
    public var proofChecksRunning = 0
    /// The blocks the body window asks to execute next: every fork child on
    /// the act-on path and the best chain's look-ahead.
    public var bodyWindow = 0
    /// Bodies asked of peers that have not arrived.
    public var bodiesRequested = 0
    /// Window blocks whose last fetch failed: no peer served the body, or
    /// this node's byte budget or store declined it.
    public var bodiesUnavailable = 0
    /// Window blocks whose body fetch failed at least once.
    public var bodiesParked = 0
    /// Blocks whose connect needs a fact of the parent chain this node has
    /// not executed yet.
    public var awaitingParentFacts = 0
    /// When the tip this chain acts on last moved, in unix seconds, as this
    /// process saw it (its first tip at a start counts as a move). Nil before
    /// it has a tip.
    public var tipAdvancedAt: Double? = nil
    /// Seconds since `tipAdvancedAt`, when the answer was made. With the
    /// status's `height` and `bestHeaderHeight`: a chain whose best header
    /// is above its tip and whose tip has not moved for long is stalled; one
    /// at its best header is only waiting for the network's next block. (A
    /// best chain that is heavier but no longer reads as at the best
    /// header, as Bitcoin Core's blocks against headers does.)
    public var secondsSinceTipAdvanced: Double? = nil
    /// What the tip waits on, as the chain's last step left it: `atTip`,
    /// `headers`, `proofs`, `parent` (a child chain waiting on its parent
    /// chain), `bodies`, `bodiesUnavailable`, `execution`, or `stalled`
    /// (behind its best header with nothing under way for the next block,
    /// which should never last). New values may be added; nil from a node
    /// that does not send it.
    public var blockedOn: String? = nil
    /// Whether this chain has weighed a peer's whole log since the node
    /// started (it opens child chains' sync), and whether it has caught up
    /// (it admits peer transactions). Nil from a node that does not send it.
    public var headersSynced: Bool? = nil
    public var synced: Bool? = nil
    /// This chain's jobs waiting for a worker.
    public var jobsQueued = 0

    public init() {}

    /// A count a node does not send reads as zero: counts come and go
    /// without breaking a client.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int { try values.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        pendingHeaders = try count(.pendingHeaders)
        headersAwaitingProof = try count(.headersAwaitingProof)
        proofChecksRunning = try count(.proofChecksRunning)
        bodyWindow = try count(.bodyWindow)
        bodiesRequested = try count(.bodiesRequested)
        bodiesUnavailable = try count(.bodiesUnavailable)
        bodiesParked = try count(.bodiesParked)
        awaitingParentFacts = try count(.awaitingParentFacts)
        tipAdvancedAt = try values.decodeIfPresent(Double.self, forKey: .tipAdvancedAt)
        secondsSinceTipAdvanced = try values.decodeIfPresent(Double.self, forKey: .secondsSinceTipAdvanced)
        blockedOn = try values.decodeIfPresent(String.self, forKey: .blockedOn)
        headersSynced = try values.decodeIfPresent(Bool.self, forKey: .headersSynced)
        synced = try values.decodeIfPresent(Bool.self, forKey: .synced)
        jobsQueued = try count(.jobsQueued)
    }
}

public enum NodeAPIError: Error, Equatable, Sendable {
    case invalidRecipientPlan
    case invalidMinimumWork
    case minimumWorkPlanTooLarge
    /// An `exclude` entry that is not a chain below the template's, or
    /// names one twice.
    case invalidExclusion
    /// An `exclude` entry carries a hosted chain the request leaves in: a
    /// block on it is needed to carry that chain's.
    case excludedAncestor
    case requestTooLarge
    case unresolvedTransactionContent
    case templateContextChanged
    case invalidWorkID
    case timestampOverflow
    case templateTooLarge
    case malformedBlock
    /// The node's template carries no block for the child chain now (its
    /// root is weighed but not executed, or it has no spec to start from).
    case noChildCandidate
}
