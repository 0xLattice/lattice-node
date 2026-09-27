import Foundation
import Ivy

/// Read-URL discovery's state: the brief answer cache, the coalesced
/// in-flight discoveries and the outstanding overlay asks. The network
/// runtime performs every ask, send, resume and cancel; this value type
/// owns what they are keyed on and the bounds that shape them.
struct ReadURLDiscovery {
    struct CacheEntry {
        let urls: [String]
        let expires: Date
    }

    struct PendingReadEndpoint {
        let peer: AuthenticatedPeer
        let genesisCID: String
        let continuation: CheckedContinuation<[String], Never>
        let timeout: Task<Void, Never>
    }

    static let maximumReadEndpointAsks = 8
    static let maximumDeclaredURLsPerResponder = 2
    static let maximumCacheEntries = 64
    static let cacheSeconds: TimeInterval = 30
    static let readEndpointAskTimeout: Duration = .seconds(2)

    var cache: [String: CacheEntry] = [:]
    var tasks: [String: (token: LifetimeToken, task: Task<[String], Never>)] = [:]
    var pendingReadEndpoints: [UInt64: PendingReadEndpoint] = [:]

    /// The cached answer for `genesisCID`, if it has not expired by `now`.
    func cachedURLs(for genesisCID: String, now: Date) -> [String]? {
        guard let cached = cache[genesisCID], cached.expires > now else {
            return nil
        }
        return cached.urls
    }

    /// Drop expired answers, then cache `urls` for `genesisCID` while the
    /// cache is under its bound.
    mutating func store(_ urls: [String], for genesisCID: String, now: Date) {
        cache = cache.filter { $0.value.expires > now }
        if cache.count < Self.maximumCacheEntries {
            cache[genesisCID] = CacheEntry(
                urls: urls,
                expires: now.addingTimeInterval(Self.cacheSeconds)
            )
        }
    }

    /// Remove and return every ask outstanding against `key`.
    mutating func removePendingReadEndpoints(
        of key: PeerKey
    ) -> [UInt64: PendingReadEndpoint] {
        let removed = pendingReadEndpoints.filter {
            $0.value.peer.key == key
        }
        pendingReadEndpoints = pendingReadEndpoints.filter {
            $0.value.peer.key != key
        }
        return removed
    }
}
