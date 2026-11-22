import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import cashew
import LatticeNodeSupport

/// The overlay topics for a chain core's weigh-log stream, content-by-CID
/// requests, and ancestor requests.
enum ChainSyncTopic {
    static let streamRequest = "lattice.overlay.stream.request.v1"
    static let streamPage = "lattice.overlay.stream.page.v1"
    static let dataRequest = "lattice.overlay.data.request.v1"
    static let headersResponse = "lattice.overlay.headers.response.v1"
    static let ancestorsRequest = "lattice.overlay.ancestors.request.v1"

    static let all: Set<String> = [streamRequest, streamPage, dataRequest, headersResponse, ancestorsRequest]
}

/// `SyncMessage.getStream`: the sender's weigh log after `after`, if the
/// asker's log id for it is `logID`.
struct StreamRequestMessage: CanonicalJSONMessage, Equatable, Sendable {
    let chainPath: [String]
    let requestID: UInt64
    let logID: String?
    let after: UInt64
    /// The asker's own log at this level.
    let own: String

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), logID.map(_isWireLogID) ?? true, own.isEmpty || _isWireLogID(own) else {
            throw OverlayWireError.malformed
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
        _isSyncWireCID(cid) && _isSyncWireCID(block) && (proof || cid == block)
    }
}

/// `SyncMessage.stream`: a page of the sender's weigh log, or a push of what
/// it appended (`requestID` 0).
struct StreamPageMessage: CanonicalJSONMessage, Equatable, Sendable {
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
            throw OverlayWireError.malformed
        }
    }

    /// `_canonicalJSONEncode`'s bytes, written directly: a page is up to
    /// thousands of entries, and the generic encoder's cost per field was
    /// most of serving one. Only strings that are printable ASCII without
    /// `"` or `\` are written here, the ones JSON spells as they are (a CID
    /// always is); a page holding any other is left to the encoder.
    func canonicalJSON() throws -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(96 + entries.count * 160)
        func plain(_ value: String) -> Bool {
            value.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7E && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }
        }
        func raw(_ text: StaticString) {
            out.append(contentsOf: UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
        }
        func quoted(_ value: String) {
            out.append(UInt8(ascii: "\""))
            out.append(contentsOf: value.utf8)
            out.append(UInt8(ascii: "\""))
        }
        guard chainPath.allSatisfy(plain), plain(logID),
              entries.allSatisfy({ plain($0.cid) && plain($0.block) }) else {
            return try _canonicalJSONEncode(self)
        }
        raw(#"{"chainPath":["#)
        for (index, name) in chainPath.enumerated() {
            if index > 0 { raw(",") }
            quoted(name)
        }
        raw(#"],"entries":["#)
        for (index, entry) in entries.enumerated() {
            raw(index > 0 ? #",{"block":"# : #"{"block":"#)
            quoted(entry.block)
            raw(#","cid":"#)
            quoted(entry.cid)
            raw(#","position":"#)
            out.append(contentsOf: String(entry.position).utf8)
            raw(entry.proof ? #","proof":true}"# : #","proof":false}"#)
        }
        raw(hasMore ? #"],"hasMore":true,"logID":"# : #"],"hasMore":false,"logID":"#)
        quoted(logID)
        raw(#","requestID":"#)
        out.append(contentsOf: String(requestID).utf8)
        raw("}")
        return Data(out)
    }
}

/// `SyncMessage.getData`: weighed headers by CID, with their proofs.
struct DataRequestMessage: CanonicalJSONMessage, Equatable, Sendable {
    static let maximumCIDs = 4_096

    let chainPath: [String]
    let requestID: UInt64
    let cids: [String]

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), cids.count <= Self.maximumCIDs,
              cids.allSatisfy(_isSyncWireCID) else {
            throw OverlayWireError.malformed
        }
    }
}

/// `SyncMessage.getAncestors`: the unknown parent of a header the sender
/// sent, and up to `maximum` of its ancestors, child to parent.
struct AncestorsRequestMessage: CanonicalJSONMessage, Equatable, Sendable {
    static let maximumAncestors = 2_048

    let chainPath: [String]
    let requestID: UInt64
    let cid: String
    let maximum: Int

    func validate() throws {
        guard _isAbsoluteChainPath(chainPath),
              _isSyncWireCID(cid),
              (1...Self.maximumAncestors).contains(maximum) else {
            throw OverlayWireError.malformed
        }
    }
}

/// One header: the block node's bytes, its child index's when it fits, and
/// a child header's `ChildBlockProof`s (a root header carries none), and a
/// child genesis's spec.
struct WireHeaderEntry: Codable, Equatable, Sendable {
    let block: Data
    let children: Data?
    let proofs: [Data]
    var spec: Data? = nil

    /// The entry decoded once, nil when any part is not canonical. A node's
    /// DAG-CBOR decode accepts only bytes its value encodes back to, so a
    /// decode is the whole canonical check for the block, the child index
    /// and the spec, and the block's CID is the hash of the bytes received.
    var decoded: HeaderEntry? {
        guard let decodedBlock = Block(data: block) else { return nil }
        var index: FlatDictionary<BlockHeader>?
        if let children {
            guard let decodedIndex = FlatDictionary<BlockHeader>(data: children) else { return nil }
            index = decodedIndex
        }
        var decodedProofs: [ChildBlockProof] = []
        for bytes in proofs {
            guard let proof = ChildBlockProof.deserialize(bytes), (try? proof.serialize()) == bytes else { return nil }
            decodedProofs.append(proof)
        }
        var decodedSpec: ChainSpec?
        if let spec {
            guard let value = ChainSpec(data: spec) else { return nil }
            decodedSpec = value
        }
        return HeaderEntry(
            block: decodedBlock, children: index, proofs: decodedProofs, spec: decodedSpec, cid: _standardCID(of: block)
        )
    }
}

/// `SyncMessage.headers`: the answer to `getData` or `getAncestors`, or an
/// unsolicited header (`requestID` 0).
struct HeadersResponseMessage: CanonicalJSONMessage, Equatable, Sendable {
    static let maximumEntries = 4_096

    let chainPath: [String]
    let requestID: UInt64
    let entries: [WireHeaderEntry]
    let hasMore: Bool

    /// Each entry's content is checked where it is decoded, once: see
    /// `ChainSyncWire.decode`.
    func validate() throws {
        guard _isAbsoluteChainPath(chainPath), entries.count <= Self.maximumEntries else {
            throw OverlayWireError.malformed
        }
    }
}

/// The codec between a level's `SyncMessage` and the overlay: pure
/// translation, every decision stays in the core.
enum ChainSyncWire {
    static func encode(_ message: SyncMessage, at chainPath: [String]) throws -> (topic: String, payload: Data) {
        switch message {
        case .getStream(let requestID, let logID, let after, let own):
            return (ChainSyncTopic.streamRequest, try StreamRequestMessage(
                chainPath: chainPath, requestID: requestID, logID: logID, after: after, own: own
            ).encoded())
        case .stream(let page):
            return (ChainSyncTopic.streamPage, try StreamPageMessage(
                chainPath: chainPath,
                requestID: page.requestID,
                logID: page.logID,
                entries: page.entries.map {
                    WireLogEntry(position: $0.position, proof: $0.entry.kind == .proof, cid: $0.entry.cid, block: $0.entry.block)
                },
                hasMore: page.hasMore
            ).encoded())
        case .getData(let requestID, let cids):
            return (ChainSyncTopic.dataRequest, try DataRequestMessage(
                chainPath: chainPath, requestID: requestID, cids: cids
            ).encoded())
        case .getAncestors(let requestID, let cid, let max):
            return (ChainSyncTopic.ancestorsRequest, try AncestorsRequestMessage(
                chainPath: chainPath,
                requestID: requestID, cid: cid,
                maximum: Swift.min(Swift.max(max, 1), AncestorsRequestMessage.maximumAncestors)
            ).encoded())
        case .headers(let response):
            return (ChainSyncTopic.headersResponse, try HeadersResponseMessage(
                chainPath: chainPath,
                requestID: response.requestID,
                entries: try response.entries.map { entry in
                    guard let block = entry.block.toData() else { throw OverlayWireError.malformed }
                    return WireHeaderEntry(
                        block: block,
                        children: entry.children?.toData(),
                        proofs: try entry.proofs.map { try $0.serialize() },
                        spec: entry.spec?.toData()
                    )
                },
                hasMore: response.hasMore
            ).encoded())
        }
    }

    /// Nil for a topic outside chain synchronization; throws for a malformed frame.
    static func decode(topic: String, payload: Data) throws -> (chainPath: [String], message: SyncMessage)? {
        switch topic {
        case ChainSyncTopic.streamRequest:
            let message = try StreamRequestMessage.decoded(payload)
            return (message.chainPath, .getStream(
                requestID: message.requestID, logID: message.logID, after: message.after, own: message.own
            ))
        case ChainSyncTopic.streamPage:
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
        case ChainSyncTopic.dataRequest:
            let message = try DataRequestMessage.decoded(payload)
            return (message.chainPath, .getData(requestID: message.requestID, cids: message.cids))
        case ChainSyncTopic.ancestorsRequest:
            let message = try AncestorsRequestMessage.decoded(payload)
            return (message.chainPath, .getAncestors(requestID: message.requestID, cid: message.cid, max: message.maximum))
        case ChainSyncTopic.headersResponse:
            let message = try HeadersResponseMessage.decoded(payload)
            SyncTrace.log(chain: message.chainPath, "headers received \(Self.fieldsLine(message.entries, payload: payload.count)) request \(message.requestID)")
            return (message.chainPath, .headers(HeadersResponse(
                requestID: message.requestID,
                entries: try message.entries.map {
                    guard let entry = $0.decoded else { throw OverlayWireError.malformed }
                    return entry
                },
                hasMore: message.hasMore
            )))
        default:
            return nil
        }
    }
}

extension ChainSyncWire {
    /// A trace line's name for a message this node sends: its kind, request
    /// and size.
    static func traceLabel(_ message: SyncMessage) -> String {
        switch message {
        case .getStream(let id, _, let after, _): "getStream request \(id) after \(after)"
        case .getData(let id, let cids): "getData request \(id) cids \(cids.count)"
        case .getAncestors(let id, _, let max): "getAncestors request \(id) max \(max)"
        case .stream(let page): "stream request \(page.requestID) entries \(page.entries.count)"
        case .headers(let response): "headers request \(response.requestID) entries \(response.entries.count)"
        }
    }

    /// A trace line's account of a headers response: the bytes of each
    /// field its entries carry, before the JSON text that frames them.
    static func fieldsLine(_ entries: [WireHeaderEntry], payload: Int) -> String {
        "entries \(entries.count) block \(entries.reduce(0) { $0 + $1.block.count })"
            + " children \(entries.reduce(0) { $0 + ($1.children?.count ?? 0) })"
            + " proofs \(entries.reduce(0) { $0 + $1.proofs.count }) proofBytes \(entries.reduce(0) { $0 + $1.proofs.reduce(0) { $0 + $1.count } })"
            + " spec \(entries.reduce(0) { $0 + ($1.spec?.count ?? 0) }) payload \(payload)"
    }
}

/// The chain sync message, for files that import Tally (whose `PeerID`
/// clashes with `LatticeNodeCore.PeerID`).
typealias ChainSyncMessage = SyncMessage

/// A CID on the chain-sync wire: canonical, and no longer than a CID can be.
func _isSyncWireCID(_ value: String) -> Bool {
    value.utf8.count <= 128 && CIDIdentity.isCanonical(value)
}

/// A weigh log id: printable ASCII, at most 128 bytes.
func _isWireLogID(_ value: String) -> Bool {
    value.utf8.count <= 128 && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
}

/// The standard CID (CIDv1, dag-cbor, sha2-256) of `bytes`, spelled as
/// `BlockHeader(node:).rawCID` spells it for the node they encode: multibase
/// "b", then lowercase unpadded RFC 4648 base32.
func _standardCID(of bytes: Data) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var text = [UInt8(ascii: "b")]
    var buffer: UInt32 = 0
    var bits = 0
    for byte in [0x01, 0x71, 0x12, 0x20] + Array(SHA256.hash(data: bytes)) {
        buffer = buffer << 8 | UInt32(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            text.append(alphabet[Int(buffer >> UInt32(bits) & 31)])
        }
    }
    if bits > 0 { text.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
    return String(decoding: text, as: UTF8.self)
}
