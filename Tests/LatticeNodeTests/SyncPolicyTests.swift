import XCTest
import UInt256
@testable import LatticeNode

/// L0 pure-decision tests for `SyncPolicy` (sync-modularization Tier-1, step 3a).
/// These are total functions of their arguments — no actor, no IO — so the
/// fork-choice/trigger logic that keeps regressing is exhaustively table-tested
/// here instead of only via live multi-node archaeology.
final class SyncPolicyTests: XCTestCase {

    // MARK: shouldAdmit — strictly heavier admits; exact tie holds incumbent

    func testShouldAdmit() {
        // (peerWork, localWork, expectAdmit)
        let cases: [(UInt256, UInt256, Bool)] = [
            (UInt256(101), UInt256(100), true),   // strictly heavier → admit
            (UInt256(100), UInt256(100), false),  // exact tie → hold incumbent
            (UInt256(99),  UInt256(100), false),  // lighter → refuse
            (UInt256(1),   .zero,        true),   // fresh node admits any positive work
            (.zero,        .zero,        false),  // zero vs zero → tie → refuse
        ]
        for (peer, local, expect) in cases {
            XCTAssertEqual(SyncPolicy.shouldAdmit(peerWork: peer, localWork: local), expect,
                           "shouldAdmit(peer:\(peer), local:\(local))")
        }
    }

    // MARK: workFloor — root passes localWork; child passes ZERO

    func testWorkFloor() {
        let local = UInt256(500)
        XCTAssertEqual(SyncPolicy.workFloor(chainPath: ["Nexus"], localWork: local), local,
                       "root chain floors at whole-chain work")
        XCTAssertEqual(SyncPolicy.workFloor(chainPath: ["Nexus", "toy"], localWork: local), .zero,
                       "child chain floors at ZERO (own-target sums meaningless)")
        XCTAssertEqual(SyncPolicy.workFloor(chainPath: ["Nexus", "toy", "toytoy"], localWork: local), .zero,
                       "grandchild also floors at ZERO")
    }

    // MARK: anchorableStopFloor — near-genesis → 0; deep → tip - retention + context

    func testAnchorableStopFloor() {
        // (tipHeight, retentionDepth, contextDepth, expected)
        let cases: [(UInt64, UInt64, UInt64, UInt64)] = [
            (100, 50, 10, 60),   // deep: 100 - 50 + 10
            (60,  50, 10, 0),    // tip == retention + context → boundary → 0
            (59,  50, 10, 0),    // tip < retention + context → 0 (near genesis)
            (5,   50, 10, 0),    // well within → 0
            (200, 120, 6, 86),   // realistic (retentionWindow=120): 200 - 120 + 6
        ]
        for (tip, ret, ctx, expect) in cases {
            XCTAssertEqual(SyncPolicy.anchorableStopFloor(tipHeight: tip, retentionDepth: ret, contextDepth: ctx), expect,
                           "anchorableStopFloor(tip:\(tip), ret:\(ret), ctx:\(ctx))")
        }
    }

    // MARK: heightGapTrigger — announce fires on gap>0; validated on gap>threshold

    func testHeightGapTrigger() {
        let threshold: UInt64 = 32
        // announceOnly: any positive gap triggers; equal height holds
        XCTAssertTrue(SyncPolicy.heightGapTrigger(gap: 1, announceOnly: true, catchUpThreshold: threshold))
        XCTAssertTrue(SyncPolicy.heightGapTrigger(gap: 93, announceOnly: true, catchUpThreshold: threshold))
        XCTAssertFalse(SyncPolicy.heightGapTrigger(gap: 0, announceOnly: true, catchUpThreshold: threshold))
        // validated (not announceOnly): must exceed the catch-up threshold
        XCTAssertFalse(SyncPolicy.heightGapTrigger(gap: 32, announceOnly: false, catchUpThreshold: threshold),
                       "gap == threshold does not trigger (strictly greater)")
        XCTAssertTrue(SyncPolicy.heightGapTrigger(gap: 33, announceOnly: false, catchUpThreshold: threshold))
        XCTAssertFalse(SyncPolicy.heightGapTrigger(gap: 5, announceOnly: false, catchUpThreshold: threshold))
    }

    // MARK: workAwareTrigger — ahead-by-height OR heavier; root-only own-work veto

    func testWorkAwareTriggerAheadByHeight() {
        // Ahead by height triggers even when NOT ahead by work — provided the
        // root own-work veto is not tripped (estimate not clearly below local).
        // localWork=1000, perBlock=100, estimate=1050: aheadByWork=(1050>1100)=false,
        // veto=(1050<1000)=false → relies purely on aheadByHeight (gap 100 > 32).
        XCTAssertTrue(SyncPolicy.workAwareTrigger(
            gap: 100, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(1_050), peerWorkPerBlock: UInt256(100), isRootChain: true))
    }

    func testWorkAwareTriggerAheadByWork() {
        // Not ahead by height (gap ≤ threshold), but heavier by > one block's work.
        XCTAssertTrue(SyncPolicy.workAwareTrigger(
            gap: 0, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(1_050), peerWorkPerBlock: UInt256(10), isRootChain: true),
            "estimatedPeerWork (1050) > localWork+perBlock (1010) → aheadByWork")
        // Heavier by less than one block's work → NOT enough (rounding guard).
        XCTAssertFalse(SyncPolicy.workAwareTrigger(
            gap: 0, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(1_005), peerWorkPerBlock: UInt256(10), isRootChain: true),
            "estimatedPeerWork (1005) ≤ localWork+perBlock (1010) → not enough")
    }

    func testWorkAwareTriggerNeitherAheadHoldsIncumbent() {
        XCTAssertFalse(SyncPolicy.workAwareTrigger(
            gap: 0, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(1_000), peerWorkPerBlock: UInt256(10), isRootChain: true),
            "equal work, equal height → hold incumbent")
    }

    func testWorkAwareTriggerRootOwnWorkVeto() {
        // Ahead by height (would trigger) BUT root single-target estimate clearly
        // below local → veto (segment would fail insufficientWork anyway).
        XCTAssertFalse(SyncPolicy.workAwareTrigger(
            gap: 100, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(500), peerWorkPerBlock: UInt256(5), isRootChain: true),
            "root: aheadByHeight but estimatedPeerWork < localWork → veto")
    }

    func testWorkAwareTriggerChildBypassesVeto() {
        // Same numbers as the root veto case, but a CHILD chain falls through the
        // veto (own-work meaningless; real weight decided at admission).
        XCTAssertTrue(SyncPolicy.workAwareTrigger(
            gap: 100, catchUpThreshold: 32, localWork: UInt256(1_000),
            estimatedPeerWork: UInt256(500), peerWorkPerBlock: UInt256(5), isRootChain: false),
            "child: aheadByHeight, no own-work veto → trigger")
    }

    func testWorkAwareTriggerFreshNodeNoVeto() {
        // localWork == 0 (fresh node): the veto requires localWork>0, so a fresh
        // root node ahead-by-height triggers even with a tiny estimate.
        XCTAssertTrue(SyncPolicy.workAwareTrigger(
            gap: 100, catchUpThreshold: 32, localWork: .zero,
            estimatedPeerWork: UInt256(1), peerWorkPerBlock: UInt256(1), isRootChain: true))
    }

    // MARK: SyncOutcome — unified failure model (kills silent-stall + stuck-refusal)

    func testTransientRetryBackoffLadder() {
        // 1,2,4,8,16 then capped at 30.
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 0), 0)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 1), 1)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 2), 2)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 3), 4)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 4), 8)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 5), 16)
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 6), 30, "1<<5=32 capped to 30")
        XCTAssertEqual(SyncPolicy.transientRetryDelaySeconds(attempt: 50), 30, "no overflow, stays capped")
    }

    func testShouldRetryFirstAttempt() {
        XCTAssertTrue(SyncPolicy.shouldRetrySync(lastOutcome: nil, tipsUnchanged: true, maxRetries: 8),
                      "no prior outcome → try")
    }

    func testShouldRetryAdmittedIsTerminal() {
        XCTAssertFalse(SyncPolicy.shouldRetrySync(lastOutcome: .admitted, tipsUnchanged: false, maxRetries: 8))
    }

    func testShouldRetryRefusedUnsticksOnlyOnTipChange() {
        // THE stuck-refusal fix: refused stays refused while tips are unchanged,
        // and frees the moment a tip changes.
        XCTAssertFalse(SyncPolicy.shouldRetrySync(lastOutcome: .refusedPermanent, tipsUnchanged: true, maxRetries: 8),
                       "tips unchanged → stay refused (no churn)")
        XCTAssertTrue(SyncPolicy.shouldRetrySync(lastOutcome: .refusedPermanent, tipsUnchanged: false, maxRetries: 8),
                      "a tip changed → re-evaluate")
    }

    func testShouldRetryInvalidDoesNotAutoRetry() {
        XCTAssertFalse(SyncPolicy.shouldRetrySync(lastOutcome: .invalid, tipsUnchanged: false, maxRetries: 8),
                       "bad data → no auto-retry (call site penalizes the peer)")
    }

    func testShouldRetryTransientAlwaysRetriesUntilBudget() {
        // THE silent-stall fix: a content miss ALWAYS schedules a retry (never a
        // silent nothing) until the retry budget is exhausted.
        XCTAssertTrue(SyncPolicy.shouldRetrySync(lastOutcome: .unavailableTransient(attempt: 0), tipsUnchanged: true, maxRetries: 8))
        XCTAssertTrue(SyncPolicy.shouldRetrySync(lastOutcome: .unavailableTransient(attempt: 7), tipsUnchanged: true, maxRetries: 8))
        XCTAssertFalse(SyncPolicy.shouldRetrySync(lastOutcome: .unavailableTransient(attempt: 8), tipsUnchanged: true, maxRetries: 8),
                       "budget exhausted → stop (bounded)")
    }
}
