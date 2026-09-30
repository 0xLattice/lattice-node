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

/// One header on the wire: the block node and, when it fits the page, the
/// `ChildIndex` its `children` link commits. Omitted children are fetched by
/// CID; the page only pre-seeds them.
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

/// `getheaders(locator)`: the requester's best header chain, log-spaced from
/// its tip back to genesis.
public struct HeadersRequest: Sendable, Equatable {
    public static let maximumLocatorEntries = 32

    public let requestID: UInt64
    public let locator: [String]

    public init(requestID: UInt64, locator: [String]) {
        self.requestID = requestID
        self.locator = locator
    }
}

/// `headers(entries, hasMore)`: consecutive headers of the server's best
/// header chain after the first locator entry it holds on that chain.
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
    /// The inv: a block the sender holds.
    case announce(blockCID: String, height: UInt64)
    case getHeaders(HeadersRequest)
    case headers(HeadersResponse)
}
