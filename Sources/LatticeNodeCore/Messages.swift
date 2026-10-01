import Lattice

/// A peer as the core sees it: its key and the session it arrived on. An
/// event from a session the core no longer holds misses the `Sync.peers`
/// lookup and is ignored, so a dead session needs no fence.
public struct PeerID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let key: String
    public let session: UInt64

    public init(key: String, session: UInt64) {
        self.key = key
        self.session = session
    }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.key != rhs.key ? lhs.key < rhs.key : lhs.session < rhs.session
    }

    public var description: String { "\(key)#\(session)" }
}

/// One header on the wire: the block node and, when it fits, the root
/// `ChildIndex` its `children` link commits. An omitted child index is
/// fetched by CID. (A child chain's header adds its proof here.)
public struct HeaderEntry: Sendable {
    public let block: Block
    public let children: ChildIndex?

    public init(block: Block, children: ChildIndex?) {
        self.block = block
        self.children = children
    }
}

/// A header the core inserted, with the content that must be durable beside
/// its facts: the block node and its child index.
public struct StoredHeader: Sendable {
    public let blockCID: String
    public let block: Block
    public let children: ChildIndex

    public init(blockCID: String, block: Block, children: ChildIndex) {
        self.blockCID = blockCID
        self.block = block
        self.children = children
    }
}

/// Where a header sits in a catch-up page: pages list a weighed subgraph by
/// height, then CID, so every parent precedes its children.
public struct HeaderKey: Sendable, Hashable, Comparable {
    public let height: UInt64
    public let cid: String

    public init(height: UInt64, cid: String) {
        self.height = height
        self.cid = cid
    }

    public static func < (lhs: HeaderKey, rhs: HeaderKey) -> Bool {
        lhs.height != rhs.height ? lhs.height < rhs.height : lhs.cid < rhs.cid
    }
}

/// Catch-up: "your weighed headers after these known CIDs". The server
/// answers every header it weighed that is neither one of `known` nor an
/// ancestor of one — side branches included — in `HeaderKey` order, after
/// `after` (the last header of the previous page).
public struct HeadersRequest: Sendable, Equatable {
    public static let maximumKnown = 64

    public let requestID: UInt64
    public let known: [String]
    public let after: HeaderKey?

    public init(requestID: UInt64, known: [String], after: HeaderKey?) {
        self.requestID = requestID
        self.known = known
        self.after = after
    }
}

/// Headers the sender weighed: a relay (`requestID` 0) or the answer to a
/// request. `hasMore` continues a catch-up page.
public struct HeadersResponse: Sendable {
    public let requestID: UInt64
    public let entries: [HeaderEntry]
    public let hasMore: Bool

    public init(requestID: UInt64, entries: [HeaderEntry], hasMore: Bool) {
        self.requestID = requestID
        self.entries = entries
        self.hasMore = hasMore
    }
}

/// The sync messages the core reads and writes, decoded. The wire encoding
/// belongs to the shell.
public enum SyncMessage: Sendable {
    case getHeaders(HeadersRequest)
    /// One header by CID: the unknown parent of a header the sender sent.
    case getHeader(requestID: UInt64, cid: String)
    case headers(HeadersResponse)
}
