import Foundation
import UInt256

/// Pure, IO-free sync DECISIONS extracted from the `LatticeNode` sync monolith
/// (Tier-1 step 3a of the sync-modularization plan). Every function here is a
/// total function of its arguments — no actor, no chain state, no clock, no
/// network — so the fork-choice / trigger logic that keeps regressing can be
/// exhaustively table-tested at L0 (`SyncPolicyTests`) instead of only via live
/// multi-node archaeology.
///
/// This extraction is behavior-PRESERVING: the bodies are moved verbatim from
/// the inline/static logic in `LatticeNode+Sync.swift`, and the former call
/// sites now delegate here. The LOCKED migration target (plan v4) is to switch
/// admission from windowed own-work to `trueCumWork` (subtreeWeight + inherited),
/// consistent with live fork choice — that is the separate, DELIBERATE step 3c
/// with its own baseline and an L4 non-divergence invariant, NOT this step.
enum SyncPolicy {

    // MARK: - Admission

    /// Admit a fully-validated synced chain only if STRICTLY heavier; an exact
    /// tie holds the incumbent (the next block to extend either fork breaks it,
    /// so the network still converges). Verify-not-trust: the synced chain has
    /// already passed full PoW + consensus validation before this compare.
    static func shouldAdmit(peerWork: UInt256, localWork: UInt256) -> Bool {
        peerWork > localWork
    }

    /// Pre-admission work floor handed to the syncer's `insufficientWork` gate.
    /// ROOT chains pass whole-chain work (the correct Nakamoto pre-filter — self-
    /// PoW-verified headers). CHILD chains pass ZERO: their own-target sums are
    /// meaningless for ordering (real weight = inherited securing work, decided at
    /// the admission choke point). A whole-chain floor for children would pre-refuse
    /// every valid carrier fast-forward (the live "insufficientWork" freeze).
    static func workFloor(chainPath: [String], localWork: UInt256) -> UInt256 {
        chainPath.count > 1 ? .zero : localWork
    }

    // MARK: - Header-walk anchoring

    /// Lowest anchorable stop point for the header walk. A stop point needs
    /// `contextDepth` local ancestors below it to build anchor context; stop
    /// points within `contextDepth` of the retention floor can't, and would strand
    /// the sync on genesis-anchored validation (which can only ever fail there), so
    /// the walk continues past them to a deeper anchorable block or genesis. Near
    /// genesis (tip within retention+context) everything is reachable → floor 0.
    static func anchorableStopFloor(tipHeight: UInt64, retentionDepth: UInt64, contextDepth: UInt64) -> UInt64 {
        guard tipHeight > retentionDepth + contextDepth else { return 0 }
        return tipHeight - retentionDepth + contextDepth
    }

    // MARK: - Sync triggers

    /// Announce-driven trigger when NO block body is available (unvalidated
    /// cid,height): a fresh announce triggers on any positive height gap; a
    /// validated tip uses the catch-up threshold. Equal height holds the incumbent.
    /// (Work-aware convergence for a shorter-but-heavier announce is the separate,
    /// deliberate change tracked as plan step 3b / `fix/announce-work-convergence`.)
    static func heightGapTrigger(gap: UInt64, announceOnly: Bool, catchUpThreshold: UInt64) -> Bool {
        announceOnly ? gap > 0 : gap > catchUpThreshold
    }

    /// Work-aware trigger for a fully-decoded peer block: sync if the peer is
    /// ahead by height OR appears heavier even at equal/lower height (a harder-mined
    /// fork). ROOT-only own-work veto: if the single-target work estimate is clearly
    /// below local, skip the bandwidth (the segment would fail `insufficientWork`
    /// anyway). Children fall through the veto (own-work meaningless) and are decided
    /// at the admission choke point after their proofs are verified.
    static func workAwareTrigger(
        gap: UInt64,
        catchUpThreshold: UInt64,
        localWork: UInt256,
        estimatedPeerWork: UInt256,
        peerWorkPerBlock: UInt256,
        isRootChain: Bool
    ) -> Bool {
        let aheadByHeight = gap > catchUpThreshold
        let aheadByWork = localWork > .zero && estimatedPeerWork > localWork + peerWorkPerBlock
        guard aheadByHeight || aheadByWork else { return false }
        // Own-target estimate veto — ROOT chains only.
        if isRootChain, localWork > .zero, estimatedPeerWork < localWork { return false }
        return true
    }
}
