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

/// Pooled transactions a template's policy check refused on `tipCID` of
/// `path`, for that level's pool to drop.
struct PolicyRefusal: Sendable, Equatable {
    let path: ChainPath
    let tipCID: String
    let cids: [String]
}

/// One hosted child level as a template job reads it: its executed tip (nil
/// when it executed no root), its pool, its difficulty anchor, and the spec a
/// genesis is built from when it has no root yet, with the account that
/// genesis pays the spec's premine to.
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
