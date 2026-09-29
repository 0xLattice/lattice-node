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
    /// See `ChainService.templateDigestLocked`. A miner compares it with the
    /// status route's to learn its work is stale.
    public let templateDigest: String

    init(
        template: MiningTemplate,
        maximumLifetimeMilliseconds: UInt64,
        templateDigest: String
    ) {
        self.templateDigest = templateDigest
        workID = template.workID
        block = template.block
        searchTarget = template.searchTarget
        targets = template.targets
        chainPath = template.chainPath
        expiresInMilliseconds = min(
            maximumLifetimeMilliseconds,
            template.remainingLifetimeMilliseconds
        )
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
    case carrier
    case duplicate
    case unavailable
    case temporarilyInvalid
    case invalid
    case localFailure
}

public struct SubmitWorkResponse: Codable, Sendable {
    public let accepted: Bool
    public let disposition: WorkDisposition
    public let tipCID: String?
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLinks: [ParentGenesisLink]
    public let durableChildProofs: [DirectChildProofSummary]
}

/// Bounded miner-facing acknowledgement. Proof bytes stay on the authenticated
/// hierarchy plane.
public struct DirectChildProofSummary: Codable, Sendable, Equatable {
    public let directory: String
    public let childCID: String

    public init(directory: String, childCID: String) {
        self.directory = directory
        self.childCID = childCID
    }
}

public enum ChainServicePhase: String, Codable, Sendable {
    case awaitingGenesis
    case active
}

public struct ChainServiceStatusResponse: Codable, Sendable, Equatable {
    public let phase: ChainServicePhase
    public let chainPath: [String]
    public let nexusGenesisCID: String
    public let tipCID: String?
    public let height: UInt64?
    public let revision: UInt64?
    public let mempoolCount: Int
    public let mempoolBytes: Int
    /// See `ChainService.templateDigestLocked`; nil before the node serves
    /// templates (no validated tip).
    public let templateDigest: String?
}

/// One accepted block's header/summary: enough to build a recent-blocks index
/// without serving the full body (whose transactions could each be up to
/// `ChainServiceLimits.maximumPayloadBytes` — an N-block walk that fetched full
/// bodies would amplify to N × maxBlockSize).
public struct BlockSummary: Codable, Sendable, Equatable {
    public let cid: String
    public let height: UInt64
    public let parentCID: String?
    public let timestamp: Int64
    public let transactionCount: Int
}

public enum ChainServiceError: Error, Equatable, Sendable {
    case unresolvedChainSpec
    case invalidRecipientPlan
    case invalidMinimumWork
    case minimumWorkPlanTooLarge
    case requestTooLarge
    case invalidChildDirectory
    case invalidChildGenesis
    case invalidChildPolicyModules
    case childIntentTooLarge
    case childIntentLimitReached
    case childCandidateLimitReached
    case invalidParentCarrier
    case parentCarrierRequired
    case unresolvedTransactionContent
    case templateContextChanged
    case invalidWorkID
    case timestampOverflow
    case templateTooLarge
    case noDeploymentAvailable
    case mempoolUnavailable
    case parentUnavailable
    case validateWalkInProgress
}
