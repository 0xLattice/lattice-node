import Ivy

/// How much content this node serves to peers at once: operator policy, with
/// the overlay's defaults. Without pressure every request is served at once;
/// when all slots are busy requests wait, never refused, and freed slots are
/// shared by weight among the peers waiting.
public struct ContentServingLimits: Sendable, Equatable {
    /// Requests served at once, all peers combined.
    public var maxConcurrent: Int
    /// Bytes of Volumes being read or sent at once.
    public var maxInFlightVolumeBytes: Int

    public init(
        maxConcurrent: Int = 64,
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
    ) {
        self.maxConcurrent = maxConcurrent
        self.maxInFlightVolumeBytes = maxInFlightVolumeBytes
    }

    public static let `default` = ContentServingLimits()
}
