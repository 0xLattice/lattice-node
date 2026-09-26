import Foundation
import Ivy
import Lattice
import UInt256
import cashew

enum NodeNetworkTopic {
    enum Plane { case overlay, hierarchy }

    static let overlayHello = "lattice.overlay.hello.v1"
    static let blockAnnouncement = "lattice.overlay.block.v1"
    static let transactionAvailable = "lattice.overlay.transaction.available.v1"
    static let transactionInventoryRequest =
        "lattice.overlay.transaction.inventory.request.v1"
    static let transactionInventoryResponse =
        "lattice.overlay.transaction.inventory.response.v1"
    static let acceptedLeavesRequest = "lattice.overlay.accepted-leaves.request.v1"
    static let acceptedLeavesResponse = "lattice.overlay.accepted-leaves.response.v1"
    static let forwardRangeRequest = "lattice.overlay.forward-range.request.v1"
    static let forwardRangeResponse = "lattice.overlay.forward-range.response.v1"
    static let ancestorRangeRequest = "lattice.overlay.ancestor-range.request.v1"
    static let ancestorRangeResponse = "lattice.overlay.ancestor-range.response.v1"
    static let portableAttachmentAvailable =
        "lattice.overlay.portable-attachment.available.v1"
    static let portableAttachmentIndexRequest =
        "lattice.overlay.portable-attachment.index.request.v1"
    static let portableAttachmentIndexResponse =
        "lattice.overlay.portable-attachment.index.response.v1"
    static let portableAttachmentLocateRequest =
        "lattice.overlay.portable-attachment.locate.request.v1"
    static let readEndpointRequest = "lattice.overlay.read-endpoint.request.v1"
    static let readEndpointResponse = "lattice.overlay.read-endpoint.response.v1"
    static let hierarchyHello = "lattice.hierarchy.hello.v1"
    static let childEvidenceAvailable = "lattice.hierarchy.evidence.available.v4"
    static let childEvidenceIndexRequest = "lattice.hierarchy.evidence.index.request.v4"
    static let childEvidenceIndexResponse = "lattice.hierarchy.evidence.index.response.v4"
    /// Parent → child: the parent's current template context (its validated
    /// tip and the miner's reward plan for the child's subtree). Pushed on
    /// every change; the child builds its candidate against it.
    static let parentTipAvailable = "lattice.hierarchy.parent-tip.available.v1"
    /// Child → parent: the child's current candidate for the parent's tip.
    /// Pushed on every change of its inputs; the parent caches the latest.
    static let childCandidateAvailable = "lattice.hierarchy.child-candidate.available.v1"
    // v2: the ANSWER changed meaning, not just the request shape. A v1 parent
    // attested any CONNECTED state, including one only weighed — a declared
    // post-state it never executed. A v2 parent attests only what it EXECUTED.
    // A v2 child cannot tell the two apart from the reply (it echoes the
    // request either way), so leaving the topic at v1 would let an upgraded
    // child bind a withdrawal to an unexecuted claim whenever its parent had
    // not rolled yet — the exact exposure this change exists to close, hiding
    // in the upgrade window.
    //
    // Bumping it makes the roll self-enforcing instead of procedural: a v1
    // parent does not know this topic, drops it unread, and the child parks on
    // `.wait(.later)` and retries. Fail closed and noisy-by-absence beats a
    // confident wrong answer.
    static let parentChainFactRequest =
        "lattice.hierarchy.parent-chain-fact.request.v2"
    static let parentChainFactResponse =
        "lattice.hierarchy.parent-chain-fact.response.v2"
    static let childGenesisAnchorRequest =
        "lattice.hierarchy.child-genesis-anchor.request.v1"
    static let childGenesisAnchorResponse =
        "lattice.hierarchy.child-genesis-anchor.response.v1"
    // §9.10: a parent PUSHES the run it credits to one of its committing
    // blocks to the children of that directory, on every change to that run
    // — every admitted block or strengthening with verifiable work — and a
    // child may ask for the runs of committers it names, the fallback for a
    // push missed while its session was down. A parent that does not know
    // this topic drops it unread and the child simply keeps the credit it
    // already holds: parents roll before children.
    static let parentRunReport = "lattice.hierarchy.parent-run-report.v1"
    static let parentRunReportRequest =
        "lattice.hierarchy.parent-run-report.request.v1"

    static func plane(for topic: String) -> Plane? {
        switch topic {
        case overlayHello, blockAnnouncement, transactionAvailable,
             transactionInventoryRequest, transactionInventoryResponse,
             acceptedLeavesRequest, acceptedLeavesResponse,
             forwardRangeRequest, forwardRangeResponse,
             ancestorRangeRequest, ancestorRangeResponse,
             portableAttachmentAvailable,
             portableAttachmentIndexRequest,
             portableAttachmentIndexResponse,
             portableAttachmentLocateRequest,
             readEndpointRequest, readEndpointResponse: .overlay
        case hierarchyHello, childEvidenceAvailable,
             childEvidenceIndexRequest, childEvidenceIndexResponse,
             parentTipAvailable, childCandidateAvailable,
             parentChainFactRequest, parentChainFactResponse,
             childGenesisAnchorRequest, childGenesisAnchorResponse,
             parentRunReport, parentRunReportRequest: .hierarchy
        default: nil
        }
    }
}

enum ParentChainFact: Codable, Equatable, Sendable {
    case genesis(childGenesisCID: String, parentStateCID: String)
    case continuity(fromStateCID: String, toStateCID: String)
}

/// A child asks only its authenticated immediate-parent process whether a fact
/// exists in that parent's locally validated, recovered graph. A successful
/// response echoes this exact canonical message.
struct ParentChainFactMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let fact: ParentChainFact

    func validate() throws {
        guard requestID != 0 else {
            throw NodeNetworkWireError.malformed
        }
        switch fact {
        case .genesis(let childGenesisCID, let parentStateCID):
            guard _isCanonicalWireCID(childGenesisCID),
                  _isCanonicalWireCID(parentStateCID) else {
                throw NodeNetworkWireError.malformed
            }
        case .continuity(let fromStateCID, let toStateCID):
            // `from` must be the empty state. Every child block anchors its
            // `parentState` at the PARENT CHAIN'S GENESIS, so Lattice builds
            // exactly one shape of continuity requirement and no correct child
            // can ask for another — which makes any other `from` malformed, not
            // merely unusual.
            //
            // This is the whole bound on serving cost. That shape is answered
            // by the executed-from-genesis frontier without walking the chain
            // — cost independent of HEIGHT, bounded by the blocks declaring
            // that one post-state, each costing a proof-of-work solve — while
            // a general `from` would run a full ancestry walk on the consensus
            // actor for a peer. Refusing it here is not a budget: the
            // question the protocol actually asks is still answered in full,
            // and identically on every node, so nothing is left to ration.
            //
            // Answering it anyway would also attest a continuity claim this
            // node never checked — the response echoes the request verbatim —
            // which is the same "unverified treated as verification" shape the
            // executed-frontier rule exists to close.
            guard _isCanonicalWireCID(fromStateCID),
                  _isCanonicalWireCID(toStateCID),
                  fromStateCID != toStateCID,
                  fromStateCID == LatticeState.emptyHeader.rawCID else {
                throw NodeNetworkWireError.malformed
            }
        }
    }
}

/// The run a parent credits to one of its committing blocks (Lattice §9.10),
/// pushed to the children of `directory` whenever that run changes. The
/// quantity is the parent's word — the trust a child already extends to its
/// configured parent for state continuity — but the child binds the report
/// before reading any number: its own directory, this child block, one of the
/// committer's grinds already credited there. Malformed here means it could
/// not have come from a correct parent: `ownWork` never exceeds `runWork`.
struct ParentRunReportMessage: NodeJSONMessage, Equatable, Sendable {
    let directory: String
    let committerCID: String
    let childBlockCID: String
    let grinds: [String]
    let runWork: WorkSum
    let ownWork: WorkSum
    let revision: UInt64

    init(
        directory: String, committerCID: String, childBlockCID: String,
        grinds: [String], runWork: WorkSum, ownWork: WorkSum, revision: UInt64
    ) {
        self.directory = directory
        self.committerCID = committerCID
        self.childBlockCID = childBlockCID
        self.grinds = grinds
        self.runWork = runWork
        self.ownWork = ownWork
        self.revision = revision
    }

    init(_ report: ParentRunReport) {
        self.init(
            directory: report.directory,
            committerCID: report.blockHash,
            childBlockCID: report.childBlock,
            grinds: report.grinds.sorted(),
            runWork: report.runWork,
            ownWork: report.ownWork,
            revision: report.revision
        )
    }

    var report: ParentRunReport {
        ParentRunReport(
            blockHash: committerCID,
            directory: directory,
            childBlock: childBlockCID,
            grinds: Set(grinds),
            runWork: runWork,
            ownWork: ownWork,
            revision: revision
        )
    }

    func validate() throws {
        guard _isBoundedWireAtom(directory), !directory.isEmpty,
              _isCanonicalWireCID(committerCID),
              _isCanonicalWireCID(childBlockCID),
              !grinds.isEmpty,
              Set(grinds).count == grinds.count,
              grinds.allSatisfy(_isCanonicalWireCID),
              ownWork <= runWork else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// The most committers one re-serve request may name — what a correct child
/// asks for (its newest carriers, `ChainProcess.recentCommitterCapacity`).
/// Structural, not a budget: a larger request is one no correct child sends,
/// so it is malformed rather than served slowly. Each named committer costs
/// the parent one O(1) read and at most one push.
let maximumParentRunReportRequestCommitters = 256

/// A child asks its authenticated immediate parent to re-serve the runs of the
/// committers it names — on admitting a block one of them carried, and for
/// its recent committers after each evidence catch-up round: the fallback for
/// a push it could not yet bind or missed while its session was down. The
/// parent answers with one `ParentRunReportMessage` per named
/// committer that commits into the asking child's directory, and nothing for
/// the rest: a committer the parent does not serve is silence, not a claim.
struct ParentRunReportRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let committerCIDs: [String]

    func validate() throws {
        guard requestID != 0,
              !committerCIDs.isEmpty,
              committerCIDs.count <= maximumParentRunReportRequestCommitters,
              Set(committerCIDs).count == committerCIDs.count,
              committerCIDs.allSatisfy(_isCanonicalWireCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// An adopting child still `awaitingGenesis` asks its authenticated immediate
/// parent for the genesis CID the parent recorded for the child's OWN directory
/// (the parent knows the directory from the authenticated `.child` role, so the
/// request carries none). The child learns the CID verify-not-trust off the
/// parent's committed record — it never guesses it — and re-confirms the CID
/// before admitting the fetched, self-verifying genesis.
struct ChildGenesisAnchorRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64

    func validate() throws {
        guard requestID != 0 else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildGenesisAnchorResponseMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let genesisCID: String

    func validate() throws {
        guard requestID != 0, _isCanonicalWireCID(genesisCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// Asks an overlay peer — typically one DHT-discovered as a provider of
/// `genesisCID` — for the declared public read URLs of the chain whose genesis
/// that is. The peer answers from self-description only (its own configured
/// URL, or ones its wired children declared in their hellos); the answer is
/// UNVERIFIED — a browser must match the served genesis against the parent's
/// on-chain anchor before trusting any URL. Unknown to legacy peers, which
/// drop the topic silently; the asker falls back on timeout.
struct ReadEndpointRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let genesisCID: String

    func validate() throws {
        guard requestID != 0, _isCanonicalWireCID(genesisCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ReadEndpointResponseMessage: NodeJSONMessage, Equatable, Sendable {
    /// Plenty for one node's self-description while bounding relayed state.
    static let maximumURLs = 8

    let requestID: UInt64
    let genesisCID: String
    let readURLs: [String]

    func validate() throws {
        guard requestID != 0, _isCanonicalWireCID(genesisCID),
              readURLs.count <= Self.maximumURLs,
              readURLs.allSatisfy({ normalizedPublicReadURL($0) == $0 })
        else {
            throw NodeNetworkWireError.malformed
        }
    }
}

enum NodeNetworkWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

private let _maximumNodeMessageSize = Int(IvyConfig.defaultProtocolMaxFrameSize) - 256

protocol NodeJSONMessage: Codable {
    func validate() throws
}

extension NodeJSONMessage {
    func encoded() throws -> Data {
        try validate()
        let data = try _canonicalJSONEncode(self)
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw NodeNetworkWireError.malformed
        }
        try value.validate()
        guard try value.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return value
    }
}

struct BlockAnnouncementMessage: NodeJSONMessage, Equatable, Sendable {
    let blockCID: String
    /// The announcer's height for `blockCID`. Lets a receiver tell a shallow
    /// propagation (handled by an ordinary predecessor pull) from a deep gap
    /// that warrants forward-apply range sync. Optional for wire compatibility.
    let height: UInt64?

    init(blockCID: String, height: UInt64? = nil) {
        self.blockCID = blockCID
        self.height = height
    }

    func validate() throws {
        guard _isBoundedWireAtom(blockCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// Announces one complete transaction Volume. The exact authenticated
/// advertiser is the first retrieval target; validity still comes from
/// content addressing and Lattice preflight.
struct TransactionAvailableMessage: NodeJSONMessage, Equatable, Sendable {
    let volumeRootCID: String

    func validate() throws {
        guard _isBoundedWireAtom(volumeRootCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct TransactionInventoryRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let afterRootCID: String?

    func validate() throws {
        guard requestID != 0,
              afterRootCID.map({ _isBoundedWireAtom($0) }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct TransactionInventoryResponseMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumRoots = 64

    let requestID: UInt64
    let afterRootCID: String?
    let volumeRootCIDs: [String]
    let hasMore: Bool

    func validate() throws {
        guard requestID != 0,
              afterRootCID.map({ _isBoundedWireAtom($0) }) ?? true,
              volumeRootCIDs.count <= Self.maximumRoots,
              volumeRootCIDs == Array(Set(volumeRootCIDs)).sorted(),
              volumeRootCIDs.allSatisfy({ _isBoundedWireAtom($0) }),
              volumeRootCIDs.allSatisfy({ cid in
                  afterRootCID.map({ cid > $0 }) ?? true
              }),
              !hasMore || volumeRootCIDs.count == Self.maximumRoots else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// A paginated inventory of accepted-forest leaves. Every retained accepted
/// block is an ancestor of one leaf, so ordinary predecessor pulls reconstruct
/// the complete graph without trusting remote aggregate state.
struct AcceptedLeavesRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let afterCID: String?
    /// The first page fixes a durable admission sequence; following pages use
    /// it so a changing forest cannot move a branch behind the CID cursor.
    let snapshotSequence: Int64?

    init(
        requestID: UInt64,
        afterCID: String?,
        snapshotSequence: Int64? = nil
    ) {
        self.requestID = requestID
        self.afterCID = afterCID
        self.snapshotSequence = snapshotSequence
    }

    func validate() throws {
        guard requestID != 0,
              snapshotSequence.map({ $0 >= 0 }) ?? true,
              afterCID.map({ _isBoundedWireAtom($0) }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct AcceptedLeavesResponseMessage: NodeJSONMessage, Equatable, Sendable {
    /// One inventory page is deliberately small enough to fit the receiver's
    /// per-peer low-priority admission budget.
    static let maximumLeaves = 64

    let requestID: UInt64
    let afterCID: String?
    let snapshotSequence: Int64
    let blockCIDs: [String]
    let hasMore: Bool

    init(
        requestID: UInt64,
        afterCID: String?,
        snapshotSequence: Int64,
        blockCIDs: [String],
        hasMore: Bool
    ) {
        self.requestID = requestID
        self.afterCID = afterCID
        self.snapshotSequence = snapshotSequence
        self.blockCIDs = blockCIDs
        self.hasMore = hasMore
    }

    func validate() throws {
        guard requestID != 0,
              snapshotSequence >= 0,
              afterCID.map({ _isBoundedWireAtom($0) }) ?? true,
              blockCIDs.count <= Self.maximumLeaves,
              blockCIDs == Array(Set(blockCIDs)).sorted(),
              blockCIDs.allSatisfy({ _isBoundedWireAtom($0) }),
              blockCIDs.allSatisfy({ cid in afterCID.map({ cid > $0 }) ?? true }),
              !hasMore || blockCIDs.count == Self.maximumLeaves else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// Requests the next contiguous, chain-ordered slice of a peer's MAIN chain
/// going FORWARD from `afterCID` (a block the requester already holds — its own
/// frontier). Unlike the leaves inventory (which ships only tips and forces one
/// predecessor pull per block), and unlike a tip-anchored backward walk (which
/// would force a receiver to buffer the whole gap before applying), this lets a
/// receiver pull one bounded page, apply it genesis-ward immediately, advance
/// its frontier, and page again — O(page) working set at any chain depth.
/// Ordering is only a hint: the receiver still verifies each fetched block's
/// parent linkage, proof-of-work, and re-executed state, so a lying peer only
/// wastes bounded, self-limited work.
struct ForwardRangeRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    /// The requester's current frontier; the response starts at its child.
    let afterCID: String

    func validate() throws {
        guard requestID != 0, _isBoundedWireAtom(afterCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ForwardRangeResponseMessage: NodeJSONMessage, Equatable, Sendable {
    /// One page's worth of block CIDs. Small enough that block-apply time (not
    /// round-trips) dominates a deep catch-up, and that a modest chain already
    /// exercises multi-page paging.
    static let maximumBlocks = 64

    let requestID: UInt64
    let afterCID: String
    /// Main-chain blocks forward from `afterCID`, genesis-ward first:
    /// `[child(afterCID), grandchild(afterCID), …]`. Empty when the responder
    /// has nothing after `afterCID` (caught up, or `afterCID` off its chain).
    let blockCIDs: [String]
    /// True when the responder holds more blocks beyond this page.
    let hasMore: Bool

    func validate() throws {
        guard requestID != 0,
              _isBoundedWireAtom(afterCID),
              blockCIDs.count <= Self.maximumBlocks,
              blockCIDs.allSatisfy({ _isBoundedWireAtom($0) }),
              !hasMore || blockCIDs.count == Self.maximumBlocks else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// Negotiates the common ancestor before streaming, so a receiver whose
/// frontier sits on a losing sibling is not told "empty = caught up" and
/// marooned. The `locator` is the receiver's own accepted main-chain CIDs,
/// newest-first at exponentially increasing height gaps back to (and
/// including) genesis — Bitcoin `getblocks` style. The responder answers with
/// the highest locator entry that lies on ITS main chain: because every entry
/// is a block the receiver itself accepted, the negotiated start can never
/// rewind the receiver past its own verified history.
struct AncestorRangeRequestMessage: NodeJSONMessage, Equatable, Sendable {
    /// A bounded locator: log-spaced, so it covers any depth in a handful of
    /// entries. 32 comfortably spans a chain far past any realistic height.
    static let maximumLocatorEntries = 32

    let requestID: UInt64
    let locator: [String]

    func validate() throws {
        guard requestID != 0,
              !locator.isEmpty,
              locator.count <= Self.maximumLocatorEntries,
              locator.allSatisfy({ _isBoundedWireAtom($0) }) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct AncestorRangeResponseMessage: NodeJSONMessage, Equatable, Sendable {
    /// Same page cap and `hasMore` semantics as the forward-range page.
    static let maximumBlocks = ForwardRangeResponseMessage.maximumBlocks

    let requestID: UInt64
    /// The highest locator entry on the responder's main chain — the negotiated
    /// stream start. `nil` means NONE of the locator entries are on its main
    /// chain (disjoint retention): distinct from "caught up", which is a
    /// present `commonAncestor` with an empty `blockCIDs`.
    let commonAncestor: String?
    /// Main-chain blocks forward FROM `commonAncestor`, genesis-ward first.
    /// Empty with a present `commonAncestor` means the receiver is caught up to
    /// this responder. Always empty when `commonAncestor` is nil.
    let blockCIDs: [String]
    let hasMore: Bool

    func validate() throws {
        guard requestID != 0,
              blockCIDs.count <= Self.maximumBlocks,
              blockCIDs.allSatisfy({ _isBoundedWireAtom($0) }),
              commonAncestor.map({ _isBoundedWireAtom($0) }) ?? true,
              !(commonAncestor == nil && !blockCIDs.isEmpty),
              !hasMore || blockCIDs.count == Self.maximumBlocks else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// One physical outer-root attachment for a root-independent direct child
/// edge. The edge CID addresses the canonical direct-edge object; `rootCID`
/// identifies the upstream proof context; `attachmentCID` is its CAS manifest.
struct PortableAttachmentSummary: Codable, Equatable, Hashable, Sendable {
    let edgeCID: String
    let rootCID: String
    let attachmentCID: String

    fileprivate var isValid: Bool {
        _isCanonicalWireCID(edgeCID)
            && _isCanonicalWireCID(rootCID)
            && _isCanonicalWireCID(attachmentCID)
    }
}

struct PortableAttachmentAvailableMessage: NodeJSONMessage, Equatable, Sendable {
    let edgeCID: String
    let rootCID: String
    let attachmentCID: String

    func validate() throws {
        guard PortableAttachmentSummary(
            edgeCID: edgeCID,
            rootCID: rootCID,
            attachmentCID: attachmentCID
        ).isValid else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct PortableAttachmentIndexRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let after: PortableAttachmentSummary?

    func validate() throws {
        guard requestID != 0, after?.isValid ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct PortableAttachmentIndexResponseMessage: NodeJSONMessage, Equatable, Sendable {
    // Page size matches the sibling index/range messages (accepted-leaves,
    // child-evidence index, forward-range all page at 64). A page of 1 made
    // the incoming-carrier attachment walk advance one entry per round trip —
    // an arbitrary throttle, not a size bound, that crawled deep child-evidence
    // sync. `hasMore` pagination is unchanged.
    static let maximumEntries = 64

    let requestID: UInt64
    let after: PortableAttachmentSummary?
    let entries: [PortableAttachmentSummary]
    let hasMore: Bool

    func validate() throws {
        let sorted = entries.sorted {
            ($0.edgeCID, $0.rootCID) < ($1.edgeCID, $1.rootCID)
        }
        guard requestID != 0,
              after?.isValid ?? true,
              entries.count <= Self.maximumEntries,
              entries == sorted,
              Set(entries).count == entries.count,
              entries.allSatisfy({ entry in
                  entry.isValid && (after.map({ cursor in
                      (entry.edgeCID, entry.rootCID)
                          > (cursor.edgeCID, cursor.rootCID)
                  }) ?? true)
              }),
              !hasMore || !entries.isEmpty else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// Solicits the portable child-evidence a peer holds for ONE specific child
/// block CID. A peer that mined (or relayed with a package) the carrier can
/// recover the block's `ChildValidationPackage`; it answers by sending the
/// requester a `PortableAttachmentAvailableMessage` for that block, which the
/// requester recovers through the ordinary portable-evidence path. This lets a
/// cold-syncing adopter obtain per-block evidence directly from the block's
/// supplier, instead of relying on its own parent having mined the carriers.
struct PortableAttachmentLocateRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childCID: String

    func validate() throws {
        guard requestID != 0, _isCanonicalWireCID(childCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

private func _isCanonicalWireCID(_ value: String) -> Bool {
    _isBoundedWireAtom(value) && CIDIdentity.isCanonical(value)
}

struct ChildEvidenceAvailableMessage: NodeJSONMessage, Equatable, Sendable {
    let childPath: [String]
    let sourceID: String
    let ordinal: UInt64
    let childCID: String
    let rootCID: String
    let attachmentCID: String

    func validate() throws {
        guard _isAbsoluteChainPath(childPath), childPath.count > 1,
              UUID(uuidString: sourceID) != nil,
              ordinal > 0,
              _isCanonicalWireCID(childCID),
              _isCanonicalWireCID(rootCID),
              _isCanonicalWireCID(attachmentCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildEvidenceIndexRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let sourceID: String?
    let cursor: UInt64
    let through: UInt64?

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              sourceID.map({ UUID(uuidString: $0) != nil }) ?? true,
              sourceID != nil || (cursor == 0 && through == nil),
              through.map({ cursor <= $0 }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildEvidenceIndexResponseMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumEntries = 64

    let requestID: UInt64
    let childPath: [String]
    let sourceID: String
    let cursor: UInt64
    let through: UInt64
    let entries: [IssuedChildEvidenceSummary]
    let next: UInt64

    func validate() throws {
        let sorted = entries.sorted { $0.ordinal < $1.ordinal }
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              UUID(uuidString: sourceID) != nil,
              cursor <= next, next <= through,
              entries.count <= Self.maximumEntries,
              entries == sorted,
              Set(entries.map(\.ordinal)).count
                == entries.count,
              entries.allSatisfy({ entry in
                  entry.ordinal > cursor
                    && entry.ordinal <= next
                    && _isCanonicalWireCID(entry.childCID)
                    && _isCanonicalWireCID(entry.rootCID)
                    && _isCanonicalWireCID(entry.attachmentCID)
              }),
              entries.last?.ordinal == next || entries.isEmpty,
              !entries.isEmpty || next == through else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// The parent's template context, pushed to its immediate child whenever it
/// changes: the parent's validated tip block and the miner's reward plan and
/// minimum work for the child's subtree. A child candidate is a function of
/// this context and the child's own state, never of one parent template.
struct ParentTipContextMessage: Sendable {
    static let maximumRewardBytes = ChainServiceLimits.maximumPayloadBytes
    static let maximumEncodedBytes = _maximumNodeMessageSize

    /// Monotonic per parent session; a lower one is stale and ignored.
    let sequence: UInt64
    let childPath: [String]
    let tipCID: String
    let tipData: Data
    let rewards: [MiningReward]
    /// Encoded after the parent block only when non-empty, so a request
    /// without minimum work keeps its exact prior layout.
    let minimumWork: [MiningMinimumWork]

    init(
        sequence: UInt64,
        childPath: [String],
        tipCID: String,
        tipData: Data,
        rewards: [MiningReward],
        minimumWork: [MiningMinimumWork] = []
    ) {
        self.sequence = sequence
        self.childPath = childPath
        self.tipCID = tipCID
        self.tipData = tipData
        self.rewards = rewards
        self.minimumWork = minimumWork
    }

    func encoded() throws -> Data {
        guard sequence != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(tipCID),
              tipData.count <= Int(UInt32.max),
              _contentBoundBlock(cid: tipCID, data: tipData) != nil else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let tipBytes = Data(tipCID.utf8)
        let rewardBytes = try _encodeMiningRewards(
            rewards,
            under: childPath
        )
        let minimumWorkBytes = try _encodeMiningMinimumWork(
            minimumWork,
            under: childPath
        )
        guard rewardBytes.count <= Self.maximumRewardBytes,
              rewardBytes.count <= Int(UInt32.max),
              minimumWorkBytes.count <= Int(UInt32.max) else {
            throw NodeNetworkWireError.malformed
        }
        let size = 8 + 2 + pathBytes.reduce(0) { $0 + 2 + $1.count }
            + 2 + tipBytes.count + 4 + rewardBytes.count
            + 4 + tipData.count
            + (minimumWorkBytes.isEmpty ? 0 : 4 + minimumWorkBytes.count)
        guard size <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(capacity: size)
        data.appendUInt64(sequence)
        data.appendUInt16(UInt16(pathBytes.count))
        for component in pathBytes {
            data.appendUInt16(UInt16(component.count))
            data.append(component)
        }
        data.appendUInt16(UInt16(tipBytes.count))
        data.append(tipBytes)
        data.appendUInt32(UInt32(rewardBytes.count))
        data.append(rewardBytes)
        data.appendUInt32(UInt32(tipData.count))
        data.append(tipData)
        if !minimumWorkBytes.isEmpty {
            data.appendUInt32(UInt32(minimumWorkBytes.count))
            data.append(minimumWorkBytes)
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let sequence = data.readUInt64(at: &position), sequence != 0,
              let pathCount = data.readUInt16(at: &position), pathCount > 1 else {
            throw NodeNetworkWireError.malformed
        }
        var childPath: [String] = []
        childPath.reserveCapacity(Int(pathCount))
        for _ in 0..<pathCount {
            guard let length = data.readUInt16(at: &position), length > 0,
                  data.distance(from: position, to: data.endIndex) >= Int(length) else {
                throw NodeNetworkWireError.malformed
            }
            let end = data.index(position, offsetBy: Int(length))
            guard let component = String(
                data: data[position..<end],
                encoding: .utf8
            ) else {
                throw NodeNetworkWireError.malformed
            }
            childPath.append(component)
            position = end
        }
        guard let tipLength = data.readUInt16(at: &position), tipLength > 0,
              data.distance(from: position, to: data.endIndex) >= Int(tipLength) else {
            throw NodeNetworkWireError.malformed
        }
        let tipEnd = data.index(position, offsetBy: Int(tipLength))
        guard let tipCID = String(
            data: data[position..<tipEnd],
            encoding: .utf8
        ) else {
            throw NodeNetworkWireError.malformed
        }
        position = tipEnd
        guard let rewardLength = data.readUInt32(at: &position),
              rewardLength <= Self.maximumRewardBytes,
              data.distance(from: position, to: data.endIndex)
                > Int(rewardLength) + 4 else {
            throw NodeNetworkWireError.malformed
        }
        let rewardEnd = data.index(position, offsetBy: Int(rewardLength))
        guard let rewards = try? _decodeMiningRewards(
            Data(data[position..<rewardEnd]),
            under: childPath
        ) else {
            throw NodeNetworkWireError.malformed
        }
        position = rewardEnd
        guard let blockLength = data.readUInt32(at: &position), blockLength > 0,
              data.distance(from: position, to: data.endIndex) >= Int(blockLength) else {
            throw NodeNetworkWireError.malformed
        }
        let blockEnd = data.index(position, offsetBy: Int(blockLength))
        let tipData = Data(data[position..<blockEnd])
        position = blockEnd
        var minimumWork: [MiningMinimumWork] = []
        if position < data.endIndex {
            guard let length = data.readUInt32(at: &position), length > 0,
                  data.distance(from: position, to: data.endIndex) >= Int(length) else {
                throw NodeNetworkWireError.malformed
            }
            let entriesEnd = data.index(position, offsetBy: Int(length))
            guard let entries = try? _decodeMiningMinimumWork(
                      Data(data[position..<entriesEnd]),
                      under: childPath
                  ),
                  !entries.isEmpty else {
                throw NodeNetworkWireError.malformed
            }
            minimumWork = entries
            position = entriesEnd
        }
        let message = Self(
            sequence: sequence,
            childPath: childPath,
            tipCID: tipCID,
            tipData: tipData,
            rewards: rewards,
            minimumWork: minimumWork
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }
}

/// The child's current candidate for its parent's tip, pushed to the parent
/// whenever one of its inputs changed. Ephemeral mining input, never
/// parent-owned child-chain state; the parent keeps only the latest.
struct ChildCandidateAvailableMessage: Sendable {
    /// Monotonic per child session; a lower one is stale and ignored.
    let sequence: UInt64
    let childPath: [String]
    /// The parent tip the candidate was built for.
    let parentTipCID: String
    let childCID: String
    let blockData: Data
    let searchWitness: ChildSchedulingWitness?

    init(
        sequence: UInt64,
        childPath: [String],
        parentTipCID: String,
        childCID: String,
        blockData: Data,
        searchWitness: ChildSchedulingWitness?
    ) {
        self.sequence = sequence
        self.childPath = childPath
        self.parentTipCID = parentTipCID
        self.childCID = childCID
        self.blockData = blockData
        self.searchWitness = searchWitness
    }

    func encoded() throws -> Data {
        guard sequence != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(parentTipCID), _isBoundedWireAtom(childCID),
              blockData.count <= Int(UInt32.max),
              _contentBoundBlock(cid: childCID, data: blockData) != nil else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let parentBytes = Data(parentTipCID.utf8)
        let childBytes = Data(childCID.utf8)
        let witnesses = try Self.encodedWitnesses(
            search: searchWitness
        )
        var size = 8 + 2 + pathBytes.reduce(0) { $0 + 2 + $1.count }
        size += 2 + parentBytes.count + 2 + childBytes.count
        size += 4 + blockData.count
        size += 1 + witnesses.reduce(0) {
            $0 + 9 + $1.proof.count + $1.terminal.count
        }
        guard size <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(capacity: size)
        data.appendUInt64(sequence)
        data.appendUInt16(UInt16(pathBytes.count))
        for component in pathBytes {
            data.appendUInt16(UInt16(component.count))
            data.append(component)
        }
        data.appendUInt16(UInt16(parentBytes.count))
        data.append(parentBytes)
        data.appendUInt16(UInt16(childBytes.count))
        data.append(childBytes)
        data.appendUInt32(UInt32(blockData.count))
        data.append(blockData)
        data.append(UInt8(witnesses.count))
        for witness in witnesses {
            data.append(witness.roles)
            data.appendUInt32(UInt32(witness.proof.count))
            data.append(witness.proof)
            data.appendUInt32(UInt32(witness.terminal.count))
            data.append(witness.terminal)
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let sequence = data.readUInt64(at: &position), sequence != 0,
              let childPath = data.readChainPath(at: &position),
              let parentTipCID = data.readString(at: &position),
              let childCID = data.readString(at: &position) else {
            throw NodeNetworkWireError.malformed
        }
        guard let blockLength = data.readUInt32(at: &position), blockLength > 0,
              data.distance(from: position, to: data.endIndex) > Int(blockLength) else {
            throw NodeNetworkWireError.malformed
        }
        let blockEnd = data.index(position, offsetBy: Int(blockLength))
        let blockData = Data(data[position..<blockEnd])
        position = blockEnd
        guard let searchWitness = readWitnesses(data, at: &position),
              position == data.endIndex else {
            throw NodeNetworkWireError.malformed
        }
        let message = Self(
            sequence: sequence,
            childPath: childPath,
            parentTipCID: parentTipCID,
            childCID: childCID,
            blockData: blockData,
            searchWitness: searchWitness
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }

    private struct EncodedWitness {
        let roles: UInt8
        let proof: Data
        let terminal: Data
    }

    private static func encoded(
        _ witness: ChildSchedulingWitness,
        roles: UInt8
    ) throws -> EncodedWitness {
        guard let terminal = witness.terminal.toData() else {
            throw NodeNetworkWireError.malformed
        }
        let proof = try witness.proof.serialize()
        guard !proof.isEmpty, !terminal.isEmpty,
              proof.count <= Int(UInt32.max),
              terminal.count <= Int(UInt32.max) else {
            throw NodeNetworkWireError.oversized
        }
        return EncodedWitness(
            roles: roles,
            proof: proof,
            terminal: terminal
        )
    }

    private static func encodedWitnesses(
        search: ChildSchedulingWitness?
    ) throws -> [EncodedWitness] {
        guard let search else { return [] }
        return [try encoded(search, roles: 1)]
    }

    /// Outer nil signals a malformed frame; inner nil means no witness present.
    private static func readWitnesses(
        _ data: Data,
        at position: inout Data.Index
    ) -> ChildSchedulingWitness?? {
        guard position < data.endIndex else { return nil }
        let count = Int(data[position])
        position = data.index(after: position)
        guard count <= 1 else { return nil }
        guard count == 1 else { return .some(nil) }
        guard position < data.endIndex else { return nil }
        let roles = data[position]
        position = data.index(after: position)
        guard roles == 1,
              let proofBytes = data.readUInt32Bytes(at: &position),
              let terminalBytes = data.readUInt32Bytes(at: &position),
              !proofBytes.isEmpty, !terminalBytes.isEmpty,
              let proof = ChildBlockProof.deserialize(proofBytes),
              (try? proof.serialize()) == proofBytes,
              let terminal = Block(data: terminalBytes),
              terminal.toData() == terminalBytes else {
            return nil
        }
        return .some(ChildSchedulingWitness(proof: proof, terminal: terminal))
    }
}

private func _encodeMiningRewards(
    _ rewards: [MiningReward],
    under childPath: [String]
) throws -> Data {
    guard rewards.count <= Int(UInt16.max) else {
        throw NodeNetworkWireError.oversized
    }
    var seen: Set<String> = []
    for reward in rewards {
        let pathKey = reward.chainPath.joined(separator: "/")
        guard _isAbsoluteChainPath(reward.chainPath),
              reward.chainPath.count >= childPath.count,
              Array(reward.chainPath.prefix(childPath.count)) == childPath,
              seen.insert(pathKey).inserted,
              let body = reward.transaction.body.node,
              body.chainPath == reward.chainPath,
              (try? ContentBoundTransaction(
                transaction: reward.transaction
              )) != nil else {
            throw NodeNetworkWireError.malformed
        }
    }
    let data = try _canonicalJSONEncode(rewards)
    guard data.count <= ParentTipContextMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    return data
}

private func _decodeMiningRewards(
    _ data: Data,
    under childPath: [String]
) throws -> [MiningReward] {
    guard data.count <= ParentTipContextMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    guard let rewards = try? JSONDecoder().decode(
            [MiningReward].self,
            from: data
          ),
          try _encodeMiningRewards(rewards, under: childPath) == data else {
        throw NodeNetworkWireError.malformed
    }
    return rewards
}

/// Empty for no entries, which the request then omits entirely.
private func _encodeMiningMinimumWork(
    _ entries: [MiningMinimumWork],
    under childPath: [String]
) throws -> Data {
    guard !entries.isEmpty else { return Data() }
    guard entries.count <= Int(UInt16.max) else {
        throw NodeNetworkWireError.oversized
    }
    var seen: Set<String> = []
    for entry in entries {
        guard _isAbsoluteChainPath(entry.chainPath),
              entry.chainPath.count >= childPath.count,
              Array(entry.chainPath.prefix(childPath.count)) == childPath,
              seen.insert(entry.chainPath.joined(separator: "/")).inserted,
              entry.work > .zero,
              entry.work <= maximumRepresentableWork else {
            throw NodeNetworkWireError.malformed
        }
    }
    let data = try _canonicalJSONEncode(entries)
    guard data.count <= ParentTipContextMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    return data
}

private func _decodeMiningMinimumWork(
    _ data: Data,
    under childPath: [String]
) throws -> [MiningMinimumWork] {
    guard data.count <= ParentTipContextMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    guard let entries = try? JSONDecoder().decode(
            [MiningMinimumWork].self,
            from: data
          ),
          try _encodeMiningMinimumWork(entries, under: childPath) == data else {
        throw NodeNetworkWireError.malformed
    }
    return entries
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    func readUInt16(at position: inout Index) -> UInt16? {
        guard distance(from: position, to: endIndex) >= 2 else { return nil }
        let value = UInt16(self[position])
            | (UInt16(self[index(after: position)]) << 8)
        position = index(position, offsetBy: 2)
        return value
    }

    func readUInt64(at position: inout Index) -> UInt64? {
        guard distance(from: position, to: endIndex) >= 8 else { return nil }
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 8) {
            value |= UInt64(self[position]) << UInt64(shift)
            position = index(after: position)
        }
        return value
    }

    func readUInt32(at position: inout Index) -> UInt32? {
        guard distance(from: position, to: endIndex) >= 4 else { return nil }
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(self[position]) << UInt32(shift)
            position = index(after: position)
        }
        return value
    }

    func readString(at position: inout Index) -> String? {
        guard let length = readUInt16(at: &position), length > 0,
              distance(from: position, to: endIndex) >= Int(length) else {
            return nil
        }
        let end = index(position, offsetBy: Int(length))
        guard let value = String(data: self[position..<end], encoding: .utf8) else {
            return nil
        }
        position = end
        return value
    }

    func readUInt32Bytes(at position: inout Index) -> Data? {
        guard let length = readUInt32(at: &position),
              distance(from: position, to: endIndex) >= Int(length) else {
            return nil
        }
        let end = index(position, offsetBy: Int(length))
        let bytes = Data(self[position..<end])
        position = end
        return bytes
    }

    func readChainPath(at position: inout Index) -> [String]? {
        guard let count = readUInt16(at: &position), count > 1 else { return nil }
        var path: [String] = []
        path.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let component = readString(at: &position) else { return nil }
            path.append(component)
        }
        return path
    }
}

func _contentBoundBlock(cid: String, data: Data) -> Block? {
    guard let block = Block(data: data), block.toData() == data,
          let header = try? BlockHeader(node: block), header.rawCID == cid else {
        return nil
    }
    return block
}
