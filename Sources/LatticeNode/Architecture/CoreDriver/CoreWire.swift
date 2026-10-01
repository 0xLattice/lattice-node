import Foundation
import Lattice
import LatticeNodeCore
import cashew

/// The overlay topics of the core's header sync (`--core-driver` only). A
/// node without the driver drops them like any unknown topic.
enum CoreDriverTopic {
    static let headersRequest = "lattice.overlay.headers.request.v1"
    static let headersResponse = "lattice.overlay.headers.response.v1"
    static let ancestorsRequest = "lattice.overlay.ancestors.request.v1"

    static let all: Set<String> = [headersRequest, headersResponse, ancestorsRequest]
}

/// Where a catch-up page stopped.
// PENDING #260: the key becomes (timestamp, cid).
struct WireHeaderKey: Codable, Equatable, Sendable {
    let height: UInt64
    let cid: String
}

/// `SyncMessage.getHeaders`.
// PENDING #260: `known` becomes `afterTimestamp: Int64` (decision 19).
struct HeadersRequestMessage: NodeJSONMessage, Equatable, Sendable {
    let chainPath: [String]
    let requestID: UInt64
    let known: [String]
    let after: WireHeaderKey?

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath),
              known.count <= HeadersRequest.maximumKnown,
              known.allSatisfy({ _isBoundedWireAtom($0) }),
              after.map({ _isBoundedWireAtom($0.cid) }) ?? true else {
            throw NodeNetworkWireError.malformed
        }
    }
}

/// The unknown parent of a header the sender sent, and up to `maximum` of its
/// ancestors, child to parent.
// PENDING #260: today's core asks for one header (`SyncMessage.getHeader`),
// sent as `maximum: 1`; #260's `getAncestors(cid, max)` maps one to one.
struct AncestorsRequestMessage: NodeJSONMessage, Equatable, Sendable {
    static let maximumAncestors = 2_048

    let chainPath: [String]
    let requestID: UInt64
    let cid: String
    let maximum: Int

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath),
              _isBoundedWireAtom(cid),
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

/// `SyncMessage.headers`: a relay (`requestID` 0) or an answer.
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
        case .getHeaders(let request):
            return (CoreDriverTopic.headersRequest, try HeadersRequestMessage(
                chainPath: chainPath,
                requestID: request.requestID,
                known: request.known,
                after: request.after.map { WireHeaderKey(height: $0.height, cid: $0.cid) }
            ).encoded())
        case .getHeader(let requestID, let cid):
            return (CoreDriverTopic.ancestorsRequest, try AncestorsRequestMessage(
                chainPath: chainPath,
                requestID: requestID, cid: cid, maximum: 1
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
        case CoreDriverTopic.headersRequest:
            let message = try HeadersRequestMessage.decoded(payload)
            return (message.chainPath, .getHeaders(HeadersRequest(
                requestID: message.requestID,
                known: message.known,
                after: message.after.map { HeaderKey(height: $0.height, cid: $0.cid) }
            )))
        case CoreDriverTopic.ancestorsRequest:
            let message = try AncestorsRequestMessage.decoded(payload)
            return (message.chainPath, .getHeader(requestID: message.requestID, cid: message.cid))
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
