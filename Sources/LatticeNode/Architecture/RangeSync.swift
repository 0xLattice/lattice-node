import Foundation
import Ivy

/// The single forward-apply range-sync slot. The network runtime performs
/// every send, suspension and timer arm; this value type owns the slot's
/// state, the progress epoch, the re-entry probe and the bounds that shape
/// paging.
struct RangeSync {
    struct State {
        let peer: AuthenticatedPeer
        var requestID: UInt64
        var awaiting: Bool
        var hasMore: Bool
        /// Anchor for the NEXT request — the last block we have requested, not
        /// the last we have applied — so paging pipelines ahead of application.
        var requestedAfterCID: String
        var requestedHeight: UInt64
        /// The peer's advertised height when this sync began: paging is only
        /// DONE once our applied tip reaches it. Every requested page can be
        /// enqueued while the applied tip is still far behind, so we cannot
        /// treat "no more pages to request" as "caught up".
        var targetHeight: UInt64
        var progressEpoch: UInt64
        var progressBaselineHeight: UInt64
        /// Consecutive re-drives that produced no applied progress. Reset every
        /// time the applied tip climbs; once it hits the cap the slot is released
        /// so a peer that advertises a tall tip but withholds one block cannot
        /// occupy the single sync slot indefinitely.
        var redriveAttempts: Int
        /// Whether `requestedAfterCID` was fixed by a common-ancestor response.
        /// Until it is, the anchor is only our own frontier — possibly a losing
        /// sibling off the peer's main chain — so an unanswered request must
        /// re-negotiate, never page forward from it.
        var negotiated: Bool
        var responseTimeout: Task<Void, Never>?
        var progressTimeout: Task<Void, Never>?

        /// A request went out under `requestID`; `timeout` reclaims it if
        /// no response arrives.
        mutating func awaitResponse(requestID: UInt64, timeout: Task<Void, Never>) {
            self.requestID = requestID
            awaiting = true
            responseTimeout = timeout
        }

        /// The outstanding request is answered or abandoned: disarm its
        /// timeout and open the latch for the next request.
        mutating func settleResponse() {
            responseTimeout?.cancel()
            awaiting = false
            responseTimeout = nil
        }
    }

    /// A gap larger than this (announced height minus ours) starts a forward-apply
    /// range sync (negotiated locator, pages, progress watchdog, peer rotation);
    /// only the true live edge uses the direct predecessor path.
    static let depthThreshold: UInt64 = 2

    /// Cap on requested-but-not-yet-applied pages, so a deep sync never buffers
    /// more than this window no matter how far behind we are.
    static let maxPagesAhead: UInt64 = 2

    /// Consecutive no-progress re-drives before the sync slot is released for a
    /// different peer. Any applied progress resets the count, so this only trips
    /// on a peer that has genuinely stopped advancing our tip.
    static let maxRedrives: Int = 8

    /// The running sync; one range sync runs at a time.
    var state: State?
    /// Monotonic across all range syncs so a stale progress-deadline task from a
    /// previous sync can never alias a new sync's epoch.
    private var nextProgressEpoch: UInt64 = 0
    /// The re-entry probe armed after a clear.
    var reentryTask: Task<Void, Never>?

    mutating func advanceProgressEpoch() -> UInt64 {
        nextProgressEpoch &+= 1
        return nextProgressEpoch
    }

    /// Disarm both of the running sync's timeouts and free the slot.
    mutating func clear() {
        state?.responseTimeout?.cancel()
        state?.progressTimeout?.cancel()
        state = nil
    }
}
