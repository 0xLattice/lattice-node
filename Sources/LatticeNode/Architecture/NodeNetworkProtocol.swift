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
    static let portableAttachmentAvailable =
        "lattice.overlay.portable-attachment.available.v1"
    static let portableAttachmentIndexRequest =
        "lattice.overlay.portable-attachment.index.request.v1"
    static let portableAttachmentIndexResponse =
        "lattice.overlay.portable-attachment.index.response.v1"
    static let hierarchyHello = "lattice.hierarchy.hello.v1"
    static let childEvidenceAvailable = "lattice.hierarchy.evidence.available.v4"
    static let childEvidenceIndexRequest = "lattice.hierarchy.evidence.index.request.v4"
    static let childEvidenceIndexResponse = "lattice.hierarchy.evidence.index.response.v4"
    static let childCandidateRequest = "lattice.hierarchy.child-candidate.request.v1"
    static let childCandidateResponse = "lattice.hierarchy.child-candidate.response.v1"
    static let childCandidateReservationRequest =
        "lattice.hierarchy.child-candidate.reservation.request.v1"
    static let childCandidateReservationResponse =
        "lattice.hierarchy.child-candidate.reservation.response.v1"
    static let parentChainFactRequest =
        "lattice.hierarchy.parent-chain-fact.request.v1"
    static let parentChainFactResponse =
        "lattice.hierarchy.parent-chain-fact.response.v1"

    static func plane(for topic: String) -> Plane? {
        switch topic {
        case overlayHello, blockAnnouncement, transactionAvailable,
             transactionInventoryRequest, transactionInventoryResponse,
             acceptedLeavesRequest, acceptedLeavesResponse,
             forwardRangeRequest, forwardRangeResponse,
             portableAttachmentAvailable,
             portableAttachmentIndexRequest,
             portableAttachmentIndexResponse: .overlay
        case hierarchyHello, childEvidenceAvailable,
             childEvidenceIndexRequest, childEvidenceIndexResponse,
             childCandidateRequest, childCandidateResponse,
             childCandidateReservationRequest, childCandidateReservationResponse,
             parentChainFactRequest, parentChainFactResponse: .hierarchy
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
            guard _isCanonicalWireCID(fromStateCID),
                  _isCanonicalWireCID(toStateCID),
                  fromStateCID != toStateCID else {
                throw NodeNetworkWireError.malformed
            }
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
    static let maximumEntries = 1

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

struct ChildCandidateReservationRequestMessage:
    NodeJSONMessage, Equatable, Sendable {
    static let maximumCandidateCIDs = 16

    let requestID: UInt64
    let childPath: [String]
    let candidateCIDs: [String]
    let handoffCIDs: [String]

    init(
        requestID: UInt64,
        childPath: [String],
        candidateCIDs: [String],
        handoffCIDs: [String] = []
    ) {
        self.requestID = requestID
        self.childPath = childPath
        self.candidateCIDs = candidateCIDs
        self.handoffCIDs = handoffCIDs
    }

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              candidateCIDs.count + handoffCIDs.count
                <= Self.maximumCandidateCIDs,
              candidateCIDs == Array(Set(candidateCIDs)).sorted(),
              handoffCIDs == Array(Set(handoffCIDs)).sorted(),
              Set(candidateCIDs).isDisjoint(with: handoffCIDs),
              candidateCIDs.allSatisfy(_isCanonicalWireCID),
              handoffCIDs.allSatisfy(_isCanonicalWireCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

struct ChildCandidateReservationResponseMessage:
    NodeJSONMessage, Equatable, Sendable {
    let requestID: UInt64
    let childPath: [String]
    let accepted: Bool

    func validate() throws {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1 else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// One provisional parent carrier context sent only to its immediate child.
struct ChildCandidateRequestMessage: Sendable {
    static let maximumBudgetMilliseconds: UInt32 = 60_000
    static let maximumRewardBytes = ChainServiceLimits.maximumPayloadBytes
    static let maximumEncodedBytes = _maximumNodeMessageSize

    let requestID: UInt64
    let budgetMilliseconds: UInt32
    let mode: MiningMode
    let childPath: [String]
    let parentCID: String
    let parentData: Data
    let rewards: [MiningReward]

    init(
        requestID: UInt64,
        budgetMilliseconds: UInt32,
        mode: MiningMode = .normal,
        childPath: [String],
        parentCID: String,
        parentData: Data,
        rewards: [MiningReward]
    ) {
        self.requestID = requestID
        self.budgetMilliseconds = budgetMilliseconds
        self.mode = mode
        self.childPath = childPath
        self.parentCID = parentCID
        self.parentData = parentData
        self.rewards = rewards
    }

    func encoded() throws -> Data {
        guard requestID != 0,
              (1...Self.maximumBudgetMilliseconds).contains(budgetMilliseconds),
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(parentCID),
              parentData.count <= Int(UInt32.max),
              _contentBoundBlock(cid: parentCID, data: parentData) != nil else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let parentBytes = Data(parentCID.utf8)
        let rewardBytes = try _encodeMiningRewards(
            rewards,
            under: childPath
        )
        guard rewardBytes.count <= Self.maximumRewardBytes,
              rewardBytes.count <= Int(UInt32.max) else {
            throw NodeNetworkWireError.malformed
        }
        let size = 13 + 2 + pathBytes.reduce(0) { $0 + 2 + $1.count }
            + 2 + parentBytes.count + 4 + rewardBytes.count
            + 4 + parentData.count
        guard size <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var data = Data(capacity: size)
        data.appendUInt64(requestID)
        data.appendUInt32(budgetMilliseconds)
        data.append(mode == .normal ? 0 : 1)
        data.appendUInt16(UInt16(pathBytes.count))
        for component in pathBytes {
            data.appendUInt16(UInt16(component.count))
            data.append(component)
        }
        data.appendUInt16(UInt16(parentBytes.count))
        data.append(parentBytes)
        data.appendUInt32(UInt32(rewardBytes.count))
        data.append(rewardBytes)
        data.appendUInt32(UInt32(parentData.count))
        data.append(parentData)
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= Self.maximumEncodedBytes else {
            throw NodeNetworkWireError.oversized
        }
        var position = data.startIndex
        guard let requestID = data.readUInt64(at: &position), requestID != 0,
              let budgetMilliseconds = data.readUInt32(at: &position),
              position < data.endIndex else {
            throw NodeNetworkWireError.malformed
        }
        let mode: MiningMode
        switch data[position] {
        case 0: mode = .normal
        case 1: mode = .deployment
        default: throw NodeNetworkWireError.malformed
        }
        position = data.index(after: position)
        guard
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
        guard let parentLength = data.readUInt16(at: &position), parentLength > 0,
              data.distance(from: position, to: data.endIndex) >= Int(parentLength) else {
            throw NodeNetworkWireError.malformed
        }
        let parentEnd = data.index(position, offsetBy: Int(parentLength))
        guard let parentCID = String(
            data: data[position..<parentEnd],
            encoding: .utf8
        ) else {
            throw NodeNetworkWireError.malformed
        }
        position = parentEnd
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
              data.distance(from: position, to: data.endIndex) == Int(blockLength) else {
            throw NodeNetworkWireError.malformed
        }
        let message = Self(
            requestID: requestID,
            budgetMilliseconds: budgetMilliseconds,
            mode: mode,
            childPath: childPath,
            parentCID: parentCID,
            parentData: Data(data[position...]),
            rewards: rewards
        )
        guard try message.encoded() == data else {
            throw NodeNetworkWireError.nonCanonical
        }
        return message
    }
}

/// A contextual unmined child template returned to the exact requesting parent.
/// It is ephemeral mining input, never parent-owned child-chain state.
struct ChildCandidateResponseMessage: Sendable {
    let requestID: UInt64
    let childPath: [String]
    let parentCID: String
    let childCID: String
    let blockData: Data
    let searchWitness: ChildSchedulingWitness?
    let deploymentWitness: ChildSchedulingWitness?

    init(
        requestID: UInt64,
        childPath: [String],
        parentCID: String,
        childCID: String,
        blockData: Data,
        searchWitness: ChildSchedulingWitness?,
        deploymentWitness: ChildSchedulingWitness?
    ) {
        self.requestID = requestID
        self.childPath = childPath
        self.parentCID = parentCID
        self.childCID = childCID
        self.blockData = blockData
        self.searchWitness = searchWitness
        self.deploymentWitness = deploymentWitness
    }

    func encoded() throws -> Data {
        guard requestID != 0,
              _isAbsoluteChainPath(childPath), childPath.count > 1,
              childPath.count <= Int(UInt16.max),
              _isBoundedWireAtom(parentCID), _isBoundedWireAtom(childCID),
              blockData.count <= Int(UInt32.max),
              _contentBoundBlock(cid: childCID, data: blockData) != nil else {
            throw NodeNetworkWireError.malformed
        }
        let pathBytes = childPath.map { Data($0.utf8) }
        let parentBytes = Data(parentCID.utf8)
        let childBytes = Data(childCID.utf8)
        let witnesses = try Self.encodedWitnesses(
            search: searchWitness,
            deployment: deploymentWitness
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
        data.appendUInt64(requestID)
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
        guard let requestID = data.readUInt64(at: &position), requestID != 0,
              let childPath = data.readChainPath(at: &position),
              let parentCID = data.readString(at: &position),
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
        guard let witnesses = readWitnesses(data, at: &position),
              position == data.endIndex else {
            throw NodeNetworkWireError.malformed
        }
        let message = Self(
            requestID: requestID,
            childPath: childPath,
            parentCID: parentCID,
            childCID: childCID,
            blockData: blockData,
            searchWitness: witnesses.search,
            deploymentWitness: witnesses.deployment
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
        let directoryPath: [String]
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
            terminal: terminal,
            directoryPath: witness.proof.directoryPath
        )
    }

    private static func encodedWitnesses(
        search: ChildSchedulingWitness?,
        deployment: ChildSchedulingWitness?
    ) throws -> [EncodedWitness] {
        switch (search, deployment) {
        case (nil, nil):
            return []
        case (.some(let search), nil):
            return [try encoded(search, roles: 1)]
        case (nil, .some(let deployment)):
            return [try encoded(deployment, roles: 2)]
        case (.some(let search), .some(let deployment)):
            let encodedSearch = try encoded(search, roles: 1)
            let encodedDeployment = try encoded(deployment, roles: 2)
            if encodedSearch.proof == encodedDeployment.proof,
               encodedSearch.terminal == encodedDeployment.terminal {
                return [try encoded(search, roles: 3)]
            }
            guard encodedSearch.directoryPath != encodedDeployment.directoryPath else {
                throw NodeNetworkWireError.malformed
            }
            return [encodedSearch, encodedDeployment]
        }
    }

    private static func readWitnesses(
        _ data: Data,
        at position: inout Data.Index
    ) -> (
        search: ChildSchedulingWitness?,
        deployment: ChildSchedulingWitness?
    )? {
        guard position < data.endIndex else { return nil }
        let count = Int(data[position])
        position = data.index(after: position)
        guard count <= 2 else { return nil }
        var search: ChildSchedulingWitness?
        var deployment: ChildSchedulingWitness?
        var paths: Set<[String]> = []
        for index in 0..<count {
            guard position < data.endIndex else { return nil }
            let roles = data[position]
            position = data.index(after: position)
            guard roles > 0, roles <= 3,
                  let proofBytes = data.readUInt32Bytes(at: &position),
                  let terminalBytes = data.readUInt32Bytes(at: &position),
                  !proofBytes.isEmpty, !terminalBytes.isEmpty,
                  let proof = ChildBlockProof.deserialize(proofBytes),
                  (try? proof.serialize()) == proofBytes,
                  let terminal = Block(data: terminalBytes),
                  terminal.toData() == terminalBytes,
                  paths.insert(proof.directoryPath).inserted else {
                return nil
            }
            let witness = ChildSchedulingWitness(
                proof: proof,
                terminal: terminal
            )
            if roles & 1 != 0 {
                guard search == nil else { return nil }
                search = witness
            }
            if roles & 2 != 0 {
                guard deployment == nil else { return nil }
                deployment = witness
            }
            if count == 2 && roles != UInt8(index + 1) {
                return nil
            }
        }
        if count == 1, search != nil, deployment != nil {
            return (search, deployment)
        }
        if count == 1, search == nil, deployment == nil {
            return nil
        }
        return (search, deployment)
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
    guard data.count <= ChildCandidateRequestMessage.maximumRewardBytes else {
        throw NodeNetworkWireError.oversized
    }
    return data
}

private func _decodeMiningRewards(
    _ data: Data,
    under childPath: [String]
) throws -> [MiningReward] {
    guard data.count <= ChildCandidateRequestMessage.maximumRewardBytes else {
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
