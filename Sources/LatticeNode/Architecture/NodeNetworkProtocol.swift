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
    /// Child → parent: the evidence for one carried child block, by CID
    /// (Bitcoin's getdata). The parent answers from its durable issued index
    /// with a `childEvidenceAvailable` hint, or stays silent. Additive: a
    /// parent that does not know the topic drops it unread, and the child's
    /// overlay locate still runs.
    static let parentEvidenceRequest = "lattice.hierarchy.evidence.request.v1"

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
             parentEvidenceRequest: .hierarchy
        default: nil
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

struct ParentEvidenceRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let childCID: String

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              _isCanonicalWireCID(childCID) else {
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

func _contentBoundBlock(cid: String, data: Data) -> Block? {
    guard let block = Block(data: data), block.toData() == data,
          let header = try? BlockHeader(node: block), header.rawCID == cid else {
        return nil
    }
    return block
}
