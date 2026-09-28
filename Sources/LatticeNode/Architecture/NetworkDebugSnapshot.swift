#if DEBUG
import Foundation
import Ivy

/// A read-only view of `NodeNetworkRuntime`'s per-peer and per-session
/// state, computed on demand for tests. It observes; nothing in the runtime
/// reads it.
struct NetworkDebugSnapshot {
    struct OverlayPeer: Equatable {
        /// The peer's overlay hello was accepted (a session and its hello
        /// deadline exist from connect, before any hello).
        let helloAccepted: Bool
        let hasHelloDeadline: Bool
    }

    struct HierarchyPeer: Equatable {
        /// The hierarchy role the peer's hello earned, if any.
        let role: NodeNetworkRuntime.HierarchyPeer?
        let hasHelloDeadline: Bool
    }

    let overlay: [PeerKey: OverlayPeer]
    let hierarchy: [PeerKey: HierarchyPeer]
    /// Every peer key still held by a per-peer record or a pending request,
    /// across both planes.
    let heldPeerKeys: Set<PeerKey>
    /// Every session ID held by state keyed on a session rather than a peer
    /// key (in-flight serves and content leases).
    let heldSessionIDs: Set<Data>
    /// The session IDs of every live authenticated session on either plane
    /// (pre- and post-hello).
    let liveSessionIDs: Set<Data>
    /// The range sync's current request anchor (the block the next page is
    /// requested after, and its height).
    let rangeSyncAnchor: (afterCID: String, requestedHeight: UInt64)?
    let candidateOfferHeld: Bool
    let refusedChildEvidenceHintCount: Int
}
#endif
