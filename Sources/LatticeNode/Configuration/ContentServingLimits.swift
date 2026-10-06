import Ivy

/// How much content this node serves to peers at once: operator policy, with
/// the overlay's defaults. Without pressure every request is served at once;
/// past these limits requests wait, and freed slots are shared by weight,
/// favouring peers that have served this node verified content.
public struct ContentServingLimits: Sendable, Equatable {
    /// Requests served at once, all peers combined.
    public var maxConcurrent: Int
    /// Requests one peer may have served at once; nil derives min(8, total / 4).
    public var maxConcurrentPerPeer: Int?
    /// Requests one peer may have waiting when all of its slots are busy.
    public var maxQueuedPerPeer: Int
    /// Bytes of Volumes being read or sent at once.
    public var maxInFlightVolumeBytes: Int

    public init(
        maxConcurrent: Int = 64,
        maxConcurrentPerPeer: Int? = nil,
        maxQueuedPerPeer: Int = 64,
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
    ) {
        self.maxConcurrent = maxConcurrent
        self.maxConcurrentPerPeer = maxConcurrentPerPeer
        self.maxQueuedPerPeer = maxQueuedPerPeer
        self.maxInFlightVolumeBytes = maxInFlightVolumeBytes
    }

    public static let `default` = ContentServingLimits()
}
