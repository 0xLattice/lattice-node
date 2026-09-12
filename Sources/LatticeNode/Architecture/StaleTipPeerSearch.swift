import Foundation
import Ivy

/// Widens this node's peer search while its own tip stands still.
///
/// An eclipse only works for as long as the victim keeps asking the same
/// peers. Running a node is cheap, so the defence is not a connection quota:
/// it is that a node which has stopped making progress goes looking for other
/// peers instead of waiting on the ones it already holds. Default bootstrap
/// peers give a node a source an attacker cannot supply; this is the other
/// half — the going-looking.
///
/// **Progress is measured, never asserted.** The height source is this node's
/// own acquired (weighed-inclusive) tip, which advances only when a header's
/// proof of work has been verified locally. A claimed height is free to
/// fabricate, so no peer's announcement or hello tip is consulted here.
///
/// **Discovery only, and blameless.** Widening the search re-dials and
/// discovers; it never disconnects, scores, punishes or prefers a peer, and
/// it has no bearing on validation or fork choice. Under partial synchrony a
/// slow peer and a withholding peer are indistinguishable, so an idle tip is
/// never evidence against anyone — it is only a reason to look further. A
/// search that finds nothing costs a handful of dials and says nothing about
/// the peers already held.
///
/// **Bounded.** At most one widening per `interval`, at most
/// `maximumDiscoveredDials` endpoints dialled from the one provider lookup,
/// and the configured set is the operator's own list. Nothing here scales
/// with chain height or with the number of connected peers, and it stops the
/// moment the tip advances again.
actor StaleTipPeerSearch {
    /// How long the acquired tip may stand still before the node widens its
    /// search, and the minimum spacing between two widenings. `0` disables the
    /// search entirely.
    let interval: TimeInterval
    /// Most endpoints dialled from one provider lookup. The lookup itself is
    /// bounded by the overlay's routing fan-out, and this bounds what a single
    /// widening does with the result.
    let maximumDiscoveredDials: Int

    private let clock: @Sendable () async -> Date
    private let acquiredHeight: @Sendable () async -> UInt64?
    private let configuredPeersWithoutSession: @Sendable () async -> [PeerEndpoint]
    private let discoveredPeersWithoutSession: @Sendable () async -> [PeerEndpoint]
    private let dial: @Sendable (PeerEndpoint) async -> Void

    private var lastHeight: UInt64?
    private var lastProgressAt: Date?
    private var lastSearchAt: Date?

    init(
        interval: TimeInterval,
        maximumDiscoveredDials: Int,
        clock: @escaping @Sendable () async -> Date,
        acquiredHeight: @escaping @Sendable () async -> UInt64?,
        configuredPeersWithoutSession: @escaping @Sendable () async -> [PeerEndpoint],
        discoveredPeersWithoutSession: @escaping @Sendable () async -> [PeerEndpoint],
        dial: @escaping @Sendable (PeerEndpoint) async -> Void
    ) {
        self.interval = interval
        self.maximumDiscoveredDials = maximumDiscoveredDials
        self.clock = clock
        self.acquiredHeight = acquiredHeight
        self.configuredPeersWithoutSession = configuredPeersWithoutSession
        self.discoveredPeersWithoutSession = discoveredPeersWithoutSession
        self.dial = dial
    }

    /// One observation. The first one only records where the tip stands, so a
    /// node that has just started is never treated as idle.
    func tick() async {
        guard interval > 0 else { return }
        let now = await clock()
        let height = await acquiredHeight()
        guard let progressAt = lastProgressAt,
              (height ?? 0) <= (lastHeight ?? 0) else {
            // Either the first observation or the tip reached a new high: the
            // node is making progress, so there is nothing to look for. This is
            // also what stops the search once a stalled node recovers.
            lastHeight = height
            lastProgressAt = now
            return
        }
        // Only a NEW HIGH counts. A tip that moves backwards — a mid-walk
        // reorg, an exclusion re-projection — is not progress, and treating it
        // as progress would let a tip flipping between two heights reset the
        // timer forever, suppressing the search exactly when it is needed.
        guard now.timeIntervalSince(progressAt) >= interval else { return }
        if let lastSearchAt, now.timeIntervalSince(lastSearchAt) < interval {
            // Already widened within this interval. The bound holds however
            // often the caller ticks, so a long stall cannot accumulate dials.
            return
        }
        lastSearchAt = now
        await widen()
    }

    /// Re-dial the configured peers we hold no session with, then dial a few
    /// endpoints from one provider lookup. Re-dialling a configured peer also
    /// clears the overlay's reconnect suppression, which is the one state in
    /// which it has permanently given up on a peer the operator asked for.
    private func widen() async {
        for endpoint in await configuredPeersWithoutSession() {
            await dial(endpoint)
        }
        for endpoint in await discoveredPeersWithoutSession()
            .prefix(maximumDiscoveredDials) {
            await dial(endpoint)
        }
    }
}
