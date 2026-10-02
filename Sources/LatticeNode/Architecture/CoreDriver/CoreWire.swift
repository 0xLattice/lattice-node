import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// The overlay topics of the core's sync (`--core-driver` only): the weigh
/// log stream, content by CID, and ancestors. A node without the driver
/// drops them like any unknown topic.
enum CoreDriverTopic {
    static let streamRequest = "lattice.overlay.stream.request.v1"
    static let streamPage = "lattice.overlay.stream.page.v1"
    static let dataRequest = "lattice.overlay.data.request.v1"
    static let headersResponse = "lattice.overlay.headers.response.v1"
    static let ancestorsRequest = "lattice.overlay.ancestors.request.v1"

    static let all: Set<String> = [streamRequest, streamPage, dataRequest, headersResponse, ancestorsRequest]
}

/// `SyncMessage.getStream`: the sender's weigh log after `after`, if the
/// asker's log id for it is `logID`.
struct StreamRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let chainPath: [String]
    let requestID: UInt64
    let logID: String?
    let after: UInt64
    /// The asker's own log at this level.
    let own: String

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), logID.map(_isWireLogID) ?? true, own.isEmpty || _isWireLogID(own) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// One weigh log entry at its position: a header (`cid` = `block`) or a
/// proof (`cid` its content identity, `block` the child block it weighs).
struct WireLogEntry: Codable, Equatable, Sendable {
    let position: UInt64
    let proof: Bool
    let cid: String
    let block: String

    /// A header names its block; a proof names its grind's root: both CIDs.
    var isBounded: Bool {
        _isCoreWireCID(cid) && _isCoreWireCID(block) && (proof || cid == block)
    }
}

/// `SyncMessage.stream`: a page of the sender's weigh log, or a push of what
/// it appended (`requestID` 0).
struct StreamPageMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumEntries = 4_096

    let chainPath: [String]
    let requestID: UInt64
    let logID: String
    let entries: [WireLogEntry]
    let hasMore: Bool

    func validate() throws {
        // An empty log id only on an empty page (a level the sender does not
        // run).
        guard _isAbsoluteChainPath(chainPath), _isWireLogID(logID), !logID.isEmpty || entries.isEmpty,
              entries.count <= Self.maximumEntries, entries.allSatisfy(\.isBounded) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// `SyncMessage.getData`: weighed headers by CID, with their proofs.
struct DataRequestMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumCIDs = 4_096

    let chainPath: [String]
    let requestID: UInt64
    let cids: [String]

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), cids.count <= Self.maximumCIDs,
              cids.allSatisfy(_isCoreWireCID) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// `SyncMessage.getAncestors`: the unknown parent of a header the sender
/// sent, and up to `maximum` of its ancestors, child to parent.
struct AncestorsRequestMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumAncestors = 2_048

    let chainPath: [String]
    let requestID: UInt64
    let cid: String
    let maximum: Int

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath),
              _isCoreWireCID(cid),
              (1...Self.maximumAncestors).contains(maximum) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// One header: the block node's bytes, its child index's when it fits, and
/// a child header's `ChildBlockProof`s (a root header carries none).
struct WireHeaderEntry: Codable, Equatable, Sendable {
    static let maximumProofs = 16

    let block: Data
    let children: Data?
    let proofs: [Data]

    var isCanonical: Bool {
        Block(data: block)?.toData() == block
            && (children.map { ChildIndex(data: $0)?.toData() == $0 } ?? true)
            && proofs.count <= Self.maximumProofs
            && proofs.allSatisfy { (try? ChildBlockProof.deserialize($0)?.serialize()) == $0 }
    }
}

/// `SyncMessage.headers`: the answer to `getData` or `getAncestors`, or an
/// unsolicited header (`requestID` 0).
struct HeadersResponseMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumEntries = 4_096

    let chainPath: [String]
    let requestID: UInt64
    let entries: [WireHeaderEntry]
    let hasMore: Bool

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath),
              entries.count <= Self.maximumEntries,
              entries.allSatisfy(\.isCanonical) else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// The codec between a level's `SyncMessage` and the overlay: pure
/// translation, every decision stays in the core.
enum CoreWire {
    static func encode(_ message: SyncMessage, at chainPath: [String]) throws -> (topic: String, payload: Data) {
        switch message {
        case .getStream(let requestID, let logID, let after, let own):
            return (CoreDriverTopic.streamRequest, try StreamRequestMessage(
                chainPath: chainPath, requestID: requestID, logID: logID, after: after, own: own
            ).encoded())
        case .stream(let page):
            return (CoreDriverTopic.streamPage, try StreamPageMessage(
                chainPath: chainPath,
                requestID: page.requestID,
                logID: page.logID,
                entries: page.entries.map {
                    WireLogEntry(position: $0.position, proof: $0.entry.kind == .proof, cid: $0.entry.cid, block: $0.entry.block)
                },
                hasMore: page.hasMore
            ).encoded())
        case .getData(let requestID, let cids):
            return (CoreDriverTopic.dataRequest, try DataRequestMessage(
                chainPath: chainPath, requestID: requestID, cids: cids
            ).encoded())
        case .getAncestors(let requestID, let cid, let max):
            return (CoreDriverTopic.ancestorsRequest, try AncestorsRequestMessage(
                chainPath: chainPath,
                requestID: requestID, cid: cid,
                maximum: Swift.min(Swift.max(max, 1), AncestorsRequestMessage.maximumAncestors)
            ).encoded())
        case .headers(let response):
            return (CoreDriverTopic.headersResponse, try HeadersResponseMessage(
                chainPath: chainPath,
                requestID: response.requestID,
                entries: try response.entries.map { entry in
                    guard let block = entry.block.toData() else { throw NodeNetworkWireError.malformed }
                    return WireHeaderEntry(
                        block: block,
                        children: entry.children?.toData(),
                        proofs: try entry.proofs.map { try $0.serialize() }
                    )
                },
                hasMore: response.hasMore
            ).encoded())
        }
    }

    /// Nil for a topic that is not the core's; throws for a malformed frame.
    static func decode(topic: String, payload: Data) throws -> (chainPath: [String], message: SyncMessage)? {
        switch topic {
        case CoreDriverTopic.streamRequest:
            let message = try StreamRequestMessage.decoded(payload)
            return (message.chainPath, .getStream(
                requestID: message.requestID, logID: message.logID, after: message.after, own: message.own
            ))
        case CoreDriverTopic.streamPage:
            let message = try StreamPageMessage.decoded(payload)
            return (message.chainPath, .stream(StreamPage(
                requestID: message.requestID,
                logID: message.logID,
                entries: message.entries.map {
                    StreamEntry(
                        position: $0.position,
                        entry: LogEntry(kind: $0.proof ? .proof : .header, cid: $0.cid, block: $0.block)
                    )
                },
                hasMore: message.hasMore
            )))
        case CoreDriverTopic.dataRequest:
            let message = try DataRequestMessage.decoded(payload)
            return (message.chainPath, .getData(requestID: message.requestID, cids: message.cids))
        case CoreDriverTopic.ancestorsRequest:
            let message = try AncestorsRequestMessage.decoded(payload)
            return (message.chainPath, .getAncestors(requestID: message.requestID, cid: message.cid, max: message.maximum))
        case CoreDriverTopic.headersResponse:
            let message = try HeadersResponseMessage.decoded(payload)
            return (message.chainPath, .headers(HeadersResponse(
                requestID: message.requestID,
                entries: try message.entries.map { entry in
                    guard let block = Block(data: entry.block) else { throw NodeNetworkWireError.malformed }
                    return HeaderEntry(
                        block: block,
                        children: try entry.children.map {
                            guard let index = ChildIndex(data: $0) else { throw NodeNetworkWireError.malformed }
                            return index
                        },
                        proofs: try entry.proofs.map {
                            guard let proof = ChildBlockProof.deserialize($0) else { throw NodeNetworkWireError.malformed }
                            return proof
                        }
                    )
                },
                hasMore: message.hasMore
            )))
        default:
            return nil
        }
    }
}

/// The core's sync message, for files that import Tally (whose `PeerID`
/// clashes with the core's).
typealias CoreSyncMessage = SyncMessage

/// A CID on the core's wire: canonical, and no longer than a CID can be.
func _isCoreWireCID(_ value: String) -> Bool {
    value.utf8.count <= 128 && CIDIdentity.isCanonical(value)
}

/// A weigh log id: printable ASCII, at most 128 bytes.
func _isWireLogID(_ value: String) -> Bool {
    value.utf8.count <= 128 && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
}
