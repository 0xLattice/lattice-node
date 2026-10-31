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

/// The submitted block's CID, and whether the node holds it now (weighed,
/// pending or waiting for a proof). `held` is false when it was dropped as
/// the same gossip would be: no weighed parent block commits it yet.
public struct SubmitChildBlockResponse: Codable, Sendable, Equatable {
    public let blockCID: String
    public let held: Bool

    public init(blockCID: String, held: Bool) {
        self.blockCID = blockCID
        self.held = held
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

    public init(
        recipients: [MiningRecipient] = [],
        minimumWork: [MiningMinimumWork] = []
    ) {
        self.recipients = recipients
        self.minimumWork = minimumWork
    }

    private enum CodingKeys: String, CodingKey {
        case recipients
        case minimumWork
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
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recipients, forKey: .recipients)
        if !minimumWork.isEmpty {
            try container.encode(minimumWork, forKey: .minimumWork)
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
    public let expiresInMilliseconds: UInt64
    /// A miner compares this with the status route's digest to learn its work
    /// is stale.
    public let templateDigest: String
    /// Every block a nonce for this work commits, the root first. Absent
    /// from older nodes.
    public let chains: [TemplateChainBlock]?

    public init(
        workID: String,
        block: Block,
        searchTarget: UInt256,
        targets: [UInt256],
        chainPath: [String],
        expiresInMilliseconds: UInt64,
        templateDigest: String,
        chains: [TemplateChainBlock]
    ) {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
        self.chainPath = chainPath
        self.expiresInMilliseconds = expiresInMilliseconds
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

public enum WorkDisposition: String, Codable, Sendable {
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
    public let durableChildProofs: [DirectChildProofSummary]

    public init(
        accepted: Bool,
        disposition: WorkDisposition,
        tipCID: String?,
        durableChildProofs: [DirectChildProofSummary]
    ) {
        self.accepted = accepted
        self.disposition = disposition
        self.tipCID = tipCID
        self.durableChildProofs = durableChildProofs
    }
}

/// Bounded miner-facing acknowledgement. Proof bytes stay in the node.
public struct DirectChildProofSummary: Codable, Sendable, Equatable {
    public let directory: String
    public let childCID: String

    public init(directory: String, childCID: String) {
        self.directory = directory
        self.childCID = childCID
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
    @OptionalDecimalString public var revision: UInt64?
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

    public init(
        phase: NodeAPIPhase,
        chainPath: [String],
        nexusGenesisCID: String,
        tipCID: String?,
        height: UInt64? = nil,
        revision: UInt64? = nil,
        mempoolCount: Int,
        mempoolBytes: Int,
        templateDigest: String?,
        bestHeaderHeight: UInt64? = nil,
        waiting: String? = nil
    ) {
        self.phase = phase
        self.chainPath = chainPath
        self.nexusGenesisCID = nexusGenesisCID
        self.tipCID = tipCID
        self.height = height
        self.revision = revision
        self.mempoolCount = mempoolCount
        self.mempoolBytes = mempoolBytes
        self.templateDigest = templateDigest
        self.bestHeaderHeight = bestHeaderHeight
        self.waiting = waiting
    }
}

public enum NodeAPIError: Error, Equatable, Sendable {
    case invalidRecipientPlan
    case invalidMinimumWork
    case minimumWorkPlanTooLarge
    case requestTooLarge
    case unresolvedTransactionContent
    case templateContextChanged
    case invalidWorkID
    case timestampOverflow
    case templateTooLarge
    case malformedBlock
}
