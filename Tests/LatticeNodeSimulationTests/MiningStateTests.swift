import Lattice
@testable import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// `MiningState.step`: preflight and template jobs carry the tip they ran on, a
/// recheck's or build's result for a moved tip is dropped and redone, an
/// admission's is applied and rechecked, the pool delta precedes every reply,
/// and `submitWork` is an event.
final class MiningStateTests: XCTestCase {
    let key = CryptoUtils.generateKeyPair()

    func transfer(nonce: UInt64, debit: Int64 = 2) throws -> Transaction {
        try signed(key, [AccountAction(owner: address(key), delta: -debit)], nonce: nonce)
    }

    func testALocalSubmitIsPreflightedThenPooledJournaledAnnouncedAndAnswered() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)

        let first = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 10)
        guard case .preflight(let job)? = first.first, first.count == 1 else {
            return XCTFail("expected one preflight job, got \(first)")
        }
        XCTAssertEqual(job.tipCID, "A")
        XCTAssertEqual(job.cid, cid)
        XCTAssertEqual(mining.mempool.count, 0, "nothing is pooled before its verdict")

        let second = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 20)
        guard case .poolChanged(let delta)? = second.first else {
            return XCTFail("the durable delta leads the step: \(second)")
        }
        XCTAssertEqual(delta.added.map(\.cid), [cid])
        XCTAssertEqual(delta.journaled.map(\.cid), [cid])
        XCTAssertTrue(second.contains { if case .transactionAdmitted(1, cid, 1, _) = $0 { true } else { false } })
        XCTAssertTrue(second.contains { if case .announceTransaction(cid) = $0 { true } else { false } })
        XCTAssertEqual(mining.mempool.item(cid)?.addedAt, 20)
        XCTAssertEqual(mining.journaled, [cid])
    }

    func testAPublicSubmitIsAnsweredAndAnnouncedButNeverJournaled() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .submitted(replyID: 1)), now: 0).first
        else { return XCTFail() }
        XCTAssertEqual(mining.pendingSubmitted, 1)
        let admitted = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 1)
        guard case .poolChanged(let delta)? = admitted.first else { return XCTFail("\(admitted)") }
        XCTAssertEqual(delta.added.map(\.cid), [cid])
        XCTAssertTrue(delta.journaled.isEmpty, "a public submit is volatile")
        XCTAssertTrue(mining.journaled.isEmpty)
        XCTAssertTrue(admitted.contains { if case .transactionAdmitted(1, cid, 1, _) = $0 { true } else { false } })
        XCTAssertTrue(admitted.contains { if case .announceTransaction(cid) = $0 { true } else { false } },
                      "relayed by ordinary gossip")
        XCTAssertEqual(mining.pendingSubmitted, 0)
    }

    func testPublicSubmitsHaveTheirOwnPendingBoundAndNeverCrowdOutLocalsOrPeers() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(maxPendingSubmitted: 1))
        func preflights(_ effects: [MiningEffect]) -> Int {
            effects.filter { if case .preflight = $0 { true } else { false } }.count
        }
        XCTAssertEqual(preflights(mining.step(.transactionReceived(try transfer(nonce: 0), origin: .submitted(replyID: 1)), now: 0)), 1)
        let over = mining.step(.transactionReceived(try transfer(nonce: 1), origin: .submitted(replyID: 2)), now: 0)
        guard case .transactionRefused(2, .full)? = over.first, over.count == 1 else {
            return XCTFail("over its bound a public submit is answered, never silently dropped: \(over)")
        }
        XCTAssertEqual(preflights(mining.step(
            .transactionReceived(try transfer(nonce: 2), origin: .peer(PeerID(key: "p", session: 1))), now: 0
        )), 1, "a public flood never takes a peer's room")
        XCTAssertEqual(preflights(mining.step(.transactionReceived(try transfer(nonce: 3), origin: .local(replyID: 3)), now: 0)), 1,
                       "nor a local submit's")
        XCTAssertEqual(mining.pendingSubmitted, 1)
    }

    /// Pooled, a public submit is an ordinary entry: it displaces nothing a
    /// better fee rate would not, local entries included.
    func testAPublicSubmitGetsNoCapacityPriority() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(mempool: MempoolLimits(maxCount: 1)))
        let local = try transfer(nonce: 0, debit: 2)
        guard case .preflight(let localJob)? = mining.step(.transactionReceived(local, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        _ = mining.step(.preflighted(localJob, .ready, balances: funded(localJob)), now: 0)
        let cheapKey = CryptoUtils.generateKeyPair()
        let cheap = try signed(cheapKey, [AccountAction(owner: address(cheapKey), delta: -1)], nonce: 0)
        guard case .preflight(let cheapJob)? = mining.step(.transactionReceived(cheap, origin: .submitted(replyID: 2)), now: 0).first
        else { return XCTFail() }
        let refused = mining.step(.preflighted(cheapJob, .ready, balances: funded(cheapJob)), now: 1)
        XCTAssertTrue(refused.contains { if case .transactionRefused(2, .full) = $0 { true } else { false } }, "\(refused)")
        XCTAssertTrue(mining.mempool.contains(try Mempool.cid(of: local)), "the local entry stays")
        // A better fee rate evicts by the ordinary rule, whatever its source.
        let richKey = CryptoUtils.generateKeyPair()
        let rich = try signed(richKey, [AccountAction(owner: address(richKey), delta: -50)], nonce: 0)
        guard case .preflight(let richJob)? = mining.step(.transactionReceived(rich, origin: .submitted(replyID: 3)), now: 2).first
        else { return XCTFail() }
        let evicting = mining.step(.preflighted(richJob, .ready, balances: funded(richJob)), now: 3)
        XCTAssertTrue(evicting.contains { if case .transactionAdmitted(3, _, _, _) = $0 { true } else { false } }, "\(evicting)")
        XCTAssertFalse(mining.mempool.contains(try Mempool.cid(of: local)))
    }

    /// A ready verdict read on a tip that has since moved is applied as if
    /// it arrived before the moves: the submit is admitted, the moves never
    /// refused it or issued its job again, and the pooled transaction gets
    /// exactly one recheck, on the current tip.
    func testAReadyVerdictOnAnOldTipIsAdmittedAndRecheckedOnceOnTheCurrentTip() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(maxReissues: 1))
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 7)), now: 0).first
        else { return XCTFail() }
        XCTAssertTrue(job.awaited)
        for tip in ["B", "C", "D"] {
            let moved = mining.step(.tipMoved(TipMove(tipCID: tip)), now: 1)
            XCTAssertFalse(moved.contains { if case .transactionRefused = $0 { true } else { false } }, "\(moved)")
            XCTAssertFalse(moved.contains { if case .preflight = $0 { true } else { false } }, "its job is still out")
        }
        let effects = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 2)
        XCTAssertEqual(effects.filter { if case .transactionAdmitted(7, cid, _, _) = $0 { true } else { false } }.count, 1, "\(effects)")
        XCTAssertTrue(mining.mempool.contains(cid))
        XCTAssertEqual(mining.journaled, [cid])
        let jobs = effects.compactMap { if case .preflight(let job) = $0 { job } else { nil } }
        XCTAssertEqual(jobs.count, 1, "\(effects)")
        XCTAssertEqual(jobs.first?.cid, cid)
        XCTAssertEqual(jobs.first?.checksPolicies, false, "an ordinary recheck")
        XCTAssertEqual(jobs.first?.tipCID, "D")
        XCTAssertEqual(jobs.first?.tipEpoch, mining.tipEpoch)
        XCTAssertEqual(mining.pendingAdmissions, 0)
        // Its recheck lands: nothing more is issued.
        let recheck = try XCTUnwrap(jobs.first)
        XCTAssertFalse(mining.step(.preflighted(recheck, .ready, balances: funded(recheck)), now: 3).contains {
            if case .preflight = $0 { true } else { false }
        })
        XCTAssertTrue(mining.mempool.contains(cid))
        XCTAssertEqual(mining.outstandingPreflights, 0)
    }

    /// A verdict that is not ready, read on a tip that has since moved, is
    /// refused once: no job is issued again, no second answer.
    func testANotReadyVerdictOnAnOldTipIsRefusedOnce() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .submitted(replyID: 7)), now: 0).first
        else { return XCTFail() }
        _ = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1)
        let effects = mining.step(.preflighted(job, .future, balances: [:]), now: 2)
        XCTAssertEqual(effects.count, 1, "\(effects)")
        guard case .transactionRefused(7, .nonceAhead)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(mining.pendingAdmissions, 0)
        XCTAssertEqual(mining.pendingSubmitted, 0)
        XCTAssertEqual(mining.outstandingPreflights, 0)
        XCTAssertTrue(mining.step(.preflighted(job, .future, balances: [:]), now: 3).isEmpty, "answered once")
    }

    /// A verdict read on an old tip brings that tip's balances. They shed
    /// nothing: an account's other pooled transactions and their journal
    /// rows stay, and the recheck on the current tip rebalances.
    func testAStaleVerdictsStaleLowBalancesShedNothing() throws {
        let sender = address(key)
        func pooled() throws -> (MiningState, PreflightJob, [String]) {
            var mining = MiningState(tipCID: "A", spec: testSpec())
            var cids: [String] = []
            for nonce in UInt64(0)...1 {
                let tx = try transfer(nonce: nonce, debit: 5)
                guard case .preflight(let job)? = mining.step(
                    .transactionReceived(tx, origin: .local(replyID: nonce + 1)), now: 0
                ).first else { throw XCTSkip("no job") }
                _ = mining.step(.preflighted(job, .ready, balances: [sender: 100]), now: 0)
                cids.append(job.cid)
            }
            guard case .preflight(let job)? = mining.step(
                .transactionReceived(try transfer(nonce: 2, debit: 5), origin: .local(replyID: 3)), now: 0
            ).first else { throw XCTSkip("no job") }
            return (mining, job, cids)
        }
        // On the tip it was read on, a balance of 5 cannot back 15: the
        // newcomer would shed the account's pooled transactions, and paying
        // less than they do, it is refused.
        var (fresh, freshJob, _) = try pooled()
        let refused = fresh.step(.preflighted(freshJob, .ready, balances: [sender: 5]), now: 1)
        XCTAssertTrue(refused.contains { if case .transactionRefused(3, .insufficientFunds) = $0 { true } else { false } },
                      "\(refused)")

        var (mining, job, cids) = try pooled()
        _ = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1)
        let effects = mining.step(.preflighted(job, .ready, balances: [sender: 5]), now: 2)
        XCTAssertTrue(effects.contains { if case .transactionAdmitted(3, _, _, _) = $0 { true } else { false } }, "\(effects)")
        for cid in cids + [job.cid] { XCTAssertTrue(mining.mempool.contains(cid), "\(effects)") }
        XCTAssertEqual(mining.journaled, Set(cids + [job.cid]))
        for case .poolChanged(let delta) in effects { XCTAssertTrue(delta.removed.isEmpty, "no journal row dropped") }
        XCTAssertTrue(effects.contains { if case .preflight(let recheck) = $0 { recheck.cid == job.cid } else { false } })
    }

    /// A local submit joining a peer's admission is answered by a job of its
    /// own, run ahead of other work; the peer's job no longer counts.
    func testALocalOriginJoiningAPeerAdmissionGetsANewAwaitedJob() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let peer = PeerID(key: "p", session: 1)
        guard case .preflight(let peerJob)? = mining.step(.transactionReceived(tx, origin: .peer(peer)), now: 0).first
        else { return XCTFail() }
        XCTAssertFalse(peerJob.awaited)
        let joined = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0)
        guard case .preflight(let awaited)? = joined.first, joined.count == 1 else { return XCTFail("\(joined)") }
        XCTAssertTrue(awaited.awaited)
        XCTAssertTrue(awaited.checksPolicies)
        XCTAssertNotEqual(awaited.id, peerJob.id)
        XCTAssertEqual(mining.pendingPeerAdmissions, 0, "out of the peer's bound")
        XCTAssertEqual(mining.outstandingPreflights, 1)

        XCTAssertTrue(mining.step(.preflighted(peerJob, .ready, balances: funded(peerJob)), now: 1).isEmpty, "ignored")
        XCTAssertTrue(mining.isPending(peerJob.cid))
        let admitted = mining.step(.preflighted(awaited, .ready, balances: funded(awaited)), now: 2)
        XCTAssertTrue(admitted.contains { if case .transactionAdmitted(1, _, _, _) = $0 { true } else { false } }, "\(admitted)")
        XCTAssertEqual(mining.mempool.count, 1)

        // A public submit joining a peer's admission takes it into its own
        // bound, the same way.
        var other = MiningState(tipCID: "A", spec: testSpec())
        let second = try transfer(nonce: 1)
        _ = other.step(.transactionReceived(second, origin: .peer(peer)), now: 0)
        let submitted = other.step(.transactionReceived(second, origin: .submitted(replyID: 2)), now: 0)
        guard case .preflight(let job)? = submitted.first else { return XCTFail("\(submitted)") }
        XCTAssertTrue(job.awaited)
        XCTAssertEqual(other.pendingPeerAdmissions, 0)
        XCTAssertEqual(other.pendingSubmitted, 1)
        // A peer's resend changes nothing.
        XCTAssertTrue(other.step(.transactionReceived(second, origin: .peer(peer)), now: 0).isEmpty)
    }

    func testAMoveThatLeavesBlocksAsksForTheirTransactions() {
        var mining = MiningState(tipCID: "A1", spec: testSpec())
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B2", confirmed: ["t"], left: ["A1"])), now: 1)
        XCTAssertTrue(moved.contains {
            if case .returnTransactions(["A1"], ["t"]) = $0 { true } else { false }
        }, "\(moved)")
        // A forward move leaves nothing to read.
        let forward = mining.step(.tipMoved(TipMove(tipCID: "B3", confirmed: ["u"])), now: 2)
        XCTAssertFalse(forward.contains { if case .returnTransactions = $0 { true } else { false } })
    }

    func testAWaitingSubmitTheMoveConfirmsIsAdmittedBeforeAnyVerdict() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        _ = mining.step(.transactionReceived(tx, origin: .local(replyID: 9)), now: 0)
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [cid])), now: 1)
        XCTAssertTrue(moved.contains {
            if case .transactionAdmitted(9, cid, _, _) = $0 { true } else { false }
        }, "\(moved)")
        XCTAssertFalse(moved.contains {
            if case .preflight(let job) = $0 { job.cid == cid } else { false }
        }, "no verdict on the new tip for what it confirms")
        XCTAssertEqual(mining.pendingAdmissions, 0)
    }

    func testAPeerTransactionIsRelayedOnceWhenItIsNewlyPooled() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        let peer = PeerID(key: "p", session: 1)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .peer(peer)), now: 0).first else {
            return XCTFail()
        }
        let admitted = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 1)
        XCTAssertTrue(admitted.contains { if case .announceTransaction(cid) = $0 { true } else { false } })
        XCTAssertFalse(admitted.contains { if case .transactionAdmitted = $0 { true } else { false } },
                       "a peer is never answered")
        let resent = mining.step(.transactionReceived(tx, origin: .peer(PeerID(key: "q", session: 1))), now: 2)
        XCTAssertFalse(resent.contains { if case .announceTransaction = $0 { true } else { false } },
                       "a resend of a pooled transaction is not relayed again")
    }

    /// An admission's job outstanding across many moves is issued once and
    /// posts once: a second verdict for it does nothing.
    func testAnAdmissionsJobOutlivesMovesAndPostsOnce() throws {
        var mining = MiningState(tipCID: "T0", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let queued)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        var issued = 1
        for move in 1...10 {
            for case .preflight(let job) in mining.step(.tipMoved(TipMove(tipCID: "T\(move)")), now: Int64(move))
            where job.cid == cid { issued += 1 }
        }
        XCTAssertEqual(issued, 1, "the moves never issue it again")
        let posted = mining.step(.preflighted(queued, .ready, balances: funded(queued)), now: 11)
        XCTAssertEqual(posted.filter { if case .transactionAdmitted(1, _, _, _) = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(mining.step(.preflighted(queued, .ready, balances: funded(queued)), now: 12).isEmpty, "posted once")
    }

    /// The move confirmed the admission: its late verdict does nothing. One
    /// never matched to its admission's job (confirmed, then returned by a
    /// reorg under a new job) admits and announces nothing, and the submit
    /// is answered exactly once.
    func testALateVerdictForAnAdmissionTheMoveConfirmedDoesNothing() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let queued)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        let running = queued
        let confirmed = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [cid])), now: 1)
        XCTAssertTrue(mining.step(.preflighted(running, .ready, balances: funded(running)), now: 1).isEmpty,
                      "confirmed: the late verdict does nothing")
        XCTAssertEqual(mining.mempool.count, 0)
        let returned = mining.step(.tipMoved(TipMove(tipCID: "C", returned: [tx])), now: 2)
        let fresh = returned.compactMap { if case .preflight(let job) = $0, job.cid == cid { job } else { nil } }
        XCTAssertEqual(fresh.count, 1, "the returned transaction gets a job of its own")
        XCTAssertNotEqual(fresh.first?.id, running.id)

        let stale = mining.step(.preflighted(running, .ready, balances: funded(running)), now: 3)
        XCTAssertTrue(stale.isEmpty, "\(stale)")
        XCTAssertEqual(mining.mempool.count, 0)
        XCTAssertTrue(mining.isPending(cid))
        let answers = (confirmed + returned + stale).filter {
            switch $0 {
            case .transactionAdmitted(1, _, _, _), .transactionRefused(1, _): true
            default: false
            }
        }
        XCTAssertEqual(answers.count, 1, "answered once, as confirmed: \(answers)")
        XCTAssertFalse((returned + stale).contains { if case .announceTransaction = $0 { true } else { false } })
    }

    /// A verdict for a pooled transaction that is not the current recheck
    /// (an earlier epoch's, or an admission job's) applies neither a
    /// rebalance nor a removal.
    func testAStaleVerdictForAPooledTransactionChangesNothing() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0, debit: 5)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let admission)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        _ = mining.step(.preflighted(admission, .ready, balances: funded(admission)), now: 0)
        let first = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1).compactMap {
            if case .preflight(let job) = $0 { job } else { nil }
        }
        let old = try XCTUnwrap(first.first)
        XCTAssertFalse(old.checksPolicies)
        _ = mining.step(.tipMoved(TipMove(tipCID: "C")), now: 2)

        // Too poor to pay it, or no longer valid: both would remove it.
        let sender = address(key)
        for stale in [
            MiningEvent.preflighted(old, .ready, balances: [sender: 0]),
            .preflighted(old, .invalid, balances: [:]),
            .preflighted(admission, .ready, balances: [sender: 0]),
            .preflighted(admission, .invalid, balances: [:]),
        ] {
            XCTAssertTrue(mining.step(stale, now: 3).isEmpty)
            XCTAssertTrue(mining.mempool.contains(cid))
        }
    }

    func testATipMoveRechecksAReadyTransactionWithoutItsPolicies() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let ready = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(.transactionReceived(ready, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        XCTAssertTrue(job.checksPolicies, "an arrival is judged by the policies")
        _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
        let arrivingKey = CryptoUtils.generateKeyPair()
        let arriving = try signed(arrivingKey, [AccountAction(owner: address(arrivingKey), delta: -2)], nonce: 0)
        _ = mining.step(.transactionReceived(arriving, origin: .local(replyID: 2)), now: 1)

        let moved = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 2)
        let jobs = Dictionary(uniqueKeysWithValues: moved.compactMap {
            if case .preflight(let job) = $0 { (job.cid, job.checksPolicies) } else { nil }
        })
        XCTAssertEqual(jobs[try Mempool.cid(of: ready)], false, "a ready one passed them already")
        XCTAssertNil(jobs[try Mempool.cid(of: arriving)], "an admission still waiting keeps its own job")
    }

    /// A tip move never judges the pool by its policies; a template does,
    /// at the height that would carry each, and what it refuses on the
    /// current tip leaves. A refusal on a tip since left is stale.
    func testWhatATemplatesPoliciesRefuseOnTheTipLeavesThePool() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        var cids: [String] = []
        for _ in 0..<2 {
            let key = CryptoUtils.generateKeyPair()
            let tx = try signed(key, [AccountAction(owner: address(key), delta: -1)], nonce: 0)
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
            else { return XCTFail() }
            _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
            cids.append(job.cid)
        }
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1)
        for case .preflight(let job) in moved {
            XCTAssertFalse(job.checksPolicies)
            _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 1)
        }
        _ = mining.step(.policyRefused(tipCID: "A", cids: [cids[0]]), now: 1)
        XCTAssertEqual(mining.mempool.count, 2, "refused on a tip since left")
        let effects = mining.step(.policyRefused(tipCID: "B", cids: [cids[0]]), now: 1)
        XCTAssertEqual(mining.mempool.items.map(\.cid), [cids[1]])
        XCTAssertTrue(effects.contains { if case .poolChanged(let delta) = $0 { delta.removed == [cids[0]] } else { false } })
    }

    /// A resend arriving while a tip move's check (without policies) of it
    /// is out is judged by the policies, on a job of its own: that check's
    /// verdict admits nothing. Only an admission adds to the pool.
    func testAResendIsNeverAdmittedByATipMovesCheck() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
        guard let recheck = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1).lazy.compactMap({
            if case .preflight(let job) = $0 { job } else { nil }
        }).first else { return XCTFail() }
        XCTAssertFalse(recheck.checksPolicies)
        _ = mining.step(.policyRefused(tipCID: "B", cids: [job.cid]), now: 1)
        guard case .preflight(let judged)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 2)), now: 1).first
        else { return XCTFail("the resend is judged by the policies") }
        XCTAssertTrue(judged.checksPolicies)

        XCTAssertTrue(mining.step(.preflighted(recheck, .ready, balances: funded(recheck)), now: 2).isEmpty)
        XCTAssertEqual(mining.mempool.count, 0)
        _ = mining.step(.preflighted(judged, .ready, balances: funded(judged)), now: 2)
        XCTAssertEqual(mining.mempool.count, 1)
    }

    /// A template is handed what the next block can carry, so its policies
    /// judge one block's worth, never the whole pool.
    func testATemplateJudgesOnlyWhatTheNextBlockCarries() throws {
        let base = testSpec()
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 2, maxStateGrowth: base.maxStateGrowth, maxBlockSize: base.maxBlockSize,
            premine: 0, targetBlockTime: base.targetBlockTime, initialReward: base.initialReward,
            halvingInterval: base.halvingInterval, halfLife: base.halfLife
        )
        var mining = MiningState(tipCID: "A", spec: spec)
        var cids: [Int64: String] = [:]
        for fee in [Int64(1), 3, 2] {
            let key = CryptoUtils.generateKeyPair()
            let tx = try signed(key, [AccountAction(owner: address(key), delta: -fee)], nonce: 0)
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
            else { return XCTFail() }
            _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
            cids[fee] = job.cid
        }
        let effects = mining.step(.templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0)
        guard case .buildTemplate(let job)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(try job.transactions.map(Mempool.cid(of:)), [cids[3], cids[2]])
        XCTAssertEqual(try mining.nextBlock.map(Mempool.cid(of:)), [cids[3], cids[2]],
                       "status's digest names what the template carries")
    }

    /// A restored row for a level that has not executed waits for its first
    /// tip instead of being refused: its row is kept.
    func testARestoredRowWaitsForItsLevelsFirstTip() throws {
        var mining = MiningState(tipCID: "", spec: nil)
        let tx = try transfer(nonce: 0)
        XCTAssertTrue(mining.step(.transactionReceived(tx, origin: .restored(addedAt: 1)), now: 0).isEmpty)
        XCTAssertEqual(mining.pendingAdmissions, 1)
        mining.spec = testSpec()
        let moved = mining.step(.tipMoved(TipMove(tipCID: "A")), now: 1)
        guard let job = moved.lazy.compactMap({ if case .preflight(let job) = $0 { job } else { nil } }).first
        else { return XCTFail("\(moved)") }
        XCTAssertTrue(job.checksPolicies)
        _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 1)
        XCTAssertEqual(mining.mempool.count, 1)
    }

    /// A fee sponsor's clients are pooled while its balance on the tip
    /// pays them, refused (to retry) past it, and shed lowest-paying first
    /// when a tip move reads less.
    func testASponsorBacksItsClientsUpToItsBalance() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let sponsor = CryptoUtils.generateKeyPair()
        var cids: [String] = []
        var refusals: [MempoolError] = []
        for (reply, fee) in [Int64(10), 30, 20].enumerated() {
            let tx = try SimTransactions.signed(keys: [CryptoUtils.generateKeyPair(), sponsor], accountActions: [
                AccountAction(owner: address(sponsor), delta: -fee),
            ], nonce: 0, chainPath: ["Nexus"])
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: UInt64(reply))), now: 0).first
            else { return XCTFail() }
            for case .transactionRefused(_, let error) in mining.step(
                .preflighted(job, .ready, balances: [address(sponsor): 45]), now: 0
            ) { refusals.append(error) }
            cids.append(job.cid)
        }
        XCTAssertEqual(refusals, [.insufficientFunds], "10 and 30 fit 45; 20 more does not")
        XCTAssertEqual(Set(mining.mempool.items.map(\.cid)), [cids[0], cids[1]])

        let moved = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1)
        for case .preflight(let job) in moved {
            _ = mining.step(.preflighted(job, .ready, balances: [address(sponsor): 35]), now: 1)
        }
        XCTAssertEqual(mining.mempool.items.map(\.cid), [cids[1]], "35 pays the 30, not the 10 as well")
    }

    func testATipMoveRemovesConfirmedRevalidatesThePoolAndReadmitsReturned() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let keptKey = CryptoUtils.generateKeyPair()
        let kept = try signed(keptKey, [AccountAction(owner: address(keptKey), delta: -2)], nonce: 0)
        let confirmed = try transfer(nonce: 0)
        let returnedKey = CryptoUtils.generateKeyPair()
        let returned = try signed(returnedKey, [AccountAction(owner: address(returnedKey), delta: -1)], nonce: 0)
        for tx in [kept, confirmed] {
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 9)), now: 0).first
            else { return XCTFail() }
            _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
        }

        let effects = mining.step(.tipMoved(TipMove(
            tipCID: "B", confirmed: [try Mempool.cid(of: confirmed)], returned: [returned]
        )), now: 5)

        guard case .poolChanged(let delta)? = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(delta.removed, [try Mempool.cid(of: confirmed)])
        XCTAssertEqual(mining.journaled, [try Mempool.cid(of: kept)])
        let jobs = effects.compactMap { if case .preflight(let job) = $0 { job } else { nil } }
        XCTAssertEqual(Set(jobs.map(\.cid)), Set(try [kept, returned].map(Mempool.cid(of:))))
        XCTAssertTrue(jobs.allSatisfy { $0.tipCID == "B" })

        let returnedJob = try XCTUnwrap(jobs.first { $0.cid == (try? Mempool.cid(of: returned)) })
        let admitted = mining.step(.preflighted(returnedJob, .ready, balances: funded(returnedJob)), now: 6)
        XCTAssertTrue(admitted.contains { if case .announceTransaction = $0 { true } else { false } },
                      "a returned transaction is announced again")
        let keptJob = try XCTUnwrap(jobs.first { $0.cid == (try? Mempool.cid(of: kept)) })
        let dropped = mining.step(.preflighted(keptJob, .invalid, balances: [:]), now: 7)
        guard case .poolChanged(let removal)? = dropped.first else { return XCTFail("\(dropped)") }
        XCTAssertEqual(removal.removed, [try Mempool.cid(of: kept)])
        XCTAssertTrue(mining.journaled.isEmpty)
    }

    func testRefusalsAnswerLocalSubmitsAndNeverPeers() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        _ = mining.step(.transactionReceived(tx, origin: .peer(PeerID(key: "p", session: 1))), now: 0)
        // A local submit joins the peer's pending admission, on a job of its
        // own (`testALocalOriginJoiningAPeerAdmissionGetsANewAwaitedJob`).
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 4)), now: 0).first
        else { return XCTFail() }
        let answered = mining.step(.preflighted(job, .invalid, balances: [:]), now: 1)
        guard case .transactionRefused(4, .invalidState)? = answered.first, answered.count == 1 else {
            return XCTFail("only the local submit is answered: \(answered)")
        }

        let restoredKey = CryptoUtils.generateKeyPair()
        let restored = try signed(restoredKey, [], nonce: 0)
        guard case .preflight(let restoredJob)? = mining.step(
            .transactionReceived(restored, origin: .restored(addedAt: 1)), now: 0
        ).first else { return XCTFail() }

        let refused = mining.step(.preflighted(restoredJob, .invalid, balances: [:]), now: 1)
        guard case .poolChanged(let delta)? = refused.first else { return XCTFail("\(refused)") }
        XCTAssertEqual(delta.removed, [try Mempool.cid(of: restored)], "the journal row goes with the refusal")
    }

    /// A journal row lives as long as its pool entry: a restored one the
    /// pool cannot hold goes, for its sender to resend.
    func testRestoredAndLocalArrivalsAreNeverRefusedForPendingCapacity() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(
            maxPendingPeerAdmissions: 1, maxPendingPerPeer: 1, maxPendingReturned: 1,
            mempool: MempoolLimits(maxCount: 1)
        ))
        let otherKey = CryptoUtils.generateKeyPair()
        let first = try transfer(nonce: 0)
        let second = try signed(otherKey, [AccountAction(owner: address(otherKey), delta: -1)], nonce: 0)
        var jobs: [PreflightJob] = []
        for tx in [first, second] {
            let effects = mining.step(.transactionReceived(tx, origin: .restored(addedAt: 1)), now: 0)
            guard case .preflight(let job)? = effects.first else { return XCTFail("no pending cap: \(effects)") }
            jobs.append(job)
        }
        let local = mining.step(.transactionReceived(try transfer(nonce: 1), origin: .local(replyID: 3)), now: 0)
        guard case .preflight? = local.first else { return XCTFail("no pending cap: \(local)") }

        _ = mining.step(.preflighted(jobs[0], .ready, balances: funded(jobs[0])), now: 1)
        // The pool is full and the second pays less.
        let full = mining.step(.preflighted(jobs[1], .ready, balances: funded(jobs[1])), now: 1)
        XCTAssertTrue(full.contains { if case .poolChanged(let delta) = $0 { delta.removed == [jobs[1].cid] } else { false } },
                      "a row not pooled again goes: \(full)")
    }

    func testPeerAdmissionsAreBoundedPerPeerAndInTotalWithoutCrowdingOutLocals() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(
            maxPendingPeerAdmissions: 2, maxPendingPerPeer: 1
        ))
        let (a, b, c) = (PeerID(key: "a", session: 1), PeerID(key: "b", session: 1), PeerID(key: "c", session: 1))
        func jobs(_ effects: [MiningEffect]) -> Int {
            effects.filter { if case .preflight = $0 { true } else { false } }.count
        }
        let fromA = try transfer(nonce: 0)
        XCTAssertEqual(jobs(mining.step(.transactionReceived(fromA, origin: .peer(a)), now: 0)), 1)
        XCTAssertEqual(jobs(mining.step(.transactionReceived(try transfer(nonce: 1), origin: .peer(a)), now: 0)), 0,
                       "over its own sub-cap, a peer's arrival is dropped")
        XCTAssertEqual(jobs(mining.step(.transactionReceived(try transfer(nonce: 2), origin: .peer(b)), now: 0)), 1)
        XCTAssertEqual(jobs(mining.step(.transactionReceived(try transfer(nonce: 3), origin: .peer(c)), now: 0)), 0,
                       "over the peers' total, dropped")
        XCTAssertEqual(mining.pendingPeerAdmissions, 2)
        for nonce in UInt64(4)...6 {
            XCTAssertEqual(jobs(mining.step(.transactionReceived(try transfer(nonce: nonce), origin: .local(replyID: nonce)), now: 0)), 1,
                           "a peer flood never refuses a local submit")
        }
        // A local submit joining a peer's admission takes it off the peer's bound.
        _ = mining.step(.transactionReceived(fromA, origin: .local(replyID: 99)), now: 0)
        XCTAssertEqual(mining.pendingAdmissions(from: a), 0)
        XCTAssertEqual(mining.pendingPeerAdmissions, 1)
    }

    func testReturnedTransactionsAreBoundedAndTheExcessSpilled() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(maxPendingReturned: 2))
        let returned = try (0..<5).map { try transfer(nonce: UInt64($0)) }
        let effects = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: returned)), now: 0)
        XCTAssertEqual(mining.pendingReturned, 2)
        XCTAssertEqual(mining.pendingAdmissions, 2)
        XCTAssertEqual(effects.filter { if case .preflight = $0 { true } else { false } }.count, 2)
    }

    func testAPendingSubmitTheChainConfirmsIsAnsweredAsAccepted() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 5)), now: 0).first
        else { return XCTFail() }
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [cid], returned: [])), now: 1)
        XCTAssertTrue(moved.contains { if case .transactionAdmitted(5, cid, _, _) = $0 { true } else { false } }, "\(moved)")
        XCTAssertFalse(moved.contains { if case .transactionRefused = $0 { true } else { false } })
        XCTAssertFalse(moved.contains { if case .preflight = $0 { true } else { false } }, "nothing left to classify")
        XCTAssertEqual(mining.pendingAdmissions, 0)
        XCTAssertTrue(mining.step(.preflighted(job, .ready, balances: funded(job)), now: 2).isEmpty)
    }

    /// A child template, under a carrier, takes the same pool: everything
    /// in it executes on the tip, and the job checks each against the
    /// carrier's state again.
    func testAChildCandidateRequestSelectsThePool() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)

        let carrier = try await candidateBlock()
        let context = ParentCarrier(cid: try BlockHeader(node: carrier).rawCID, block: carrier)
        guard case .buildTemplate(let contextual)? = mining.step(
            .templateRequested(replyID: 3, TemplateRequest(rewardRecipient: nil, parentCarrier: context)), now: 0
        ).first else { return XCTFail() }
        XCTAssertEqual(contextual.transactions.map(\.body.rawCID), [tx.body.rawCID])
        XCTAssertEqual(contextual.request.parentCarrier?.cid, context.cid)
    }

    /// Only what executes on the tip is pooled: a nonce ahead or evidence
    /// this node lacks is a retry for the sender, never held.
    func testOnlyAReadyTransactionIsPooled() throws {
        for (verdict, refusal) in [(MempoolDisposition.future, MempoolError.nonceAhead), (.unavailable, .unavailable)] {
            var mining = MiningState(tipCID: "A", spec: testSpec())
            let tx = try transfer(nonce: 1)
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .submitted(replyID: 1)), now: 0).first
            else { return XCTFail() }
            let refused = mining.step(.preflighted(job, verdict, balances: funded(job)), now: 1)
            XCTAssertTrue(refused.contains { if case .transactionRefused(1, refusal) = $0 { true } else { false } }, "\(refused)")
            XCTAssertEqual(mining.mempool.count, 0)
        }
    }

    /// A pooled transaction that no longer executes on the tip leaves; one
    /// this node cannot judge now stays, so a gap in its own evidence never
    /// flushes the pool.
    /// The pool holds only what is ready on the tip. One ahead, one that no
    /// longer executes, and one this node can no longer judge (a withdrawal
    /// whose receipt a reorg took) all leave, freeing their signers.
    func testATipMoveKeepsOnlyWhatIsStillReady() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let keys = (0..<4).map { _ in CryptoUtils.generateKeyPair() }
        let txs = try keys.map { try signed($0, [AccountAction(owner: address($0), delta: -2)], nonce: 0) }
        for tx in txs {
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
            else { return XCTFail() }
            _ = mining.step(.preflighted(job, .ready, balances: funded(job)), now: 0)
        }
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 1)
        let jobs = Dictionary(uniqueKeysWithValues: moved.compactMap {
            if case .preflight(let job) = $0 { (job.cid, job) } else { nil }
        })
        let cids = try txs.map(Mempool.cid(of:))
        for (cid, verdict) in zip(cids, [MempoolDisposition.future, .invalid, .unavailable, .ready]) {
            _ = mining.step(.preflighted(try XCTUnwrap(jobs[cid]), verdict, balances: funded(try XCTUnwrap(jobs[cid]))), now: 2)
        }
        XCTAssertEqual(mining.mempool.items.map(\.cid), [cids[3]])
    }

    func testARestoredJournalRowThePoolRefusesGoes() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec(maxBlockSize: 64))
        let tx = try transfer(nonce: 0)
        let detached = Transaction(signatures: tx.signatures, body: tx.body.removingNode())
        for arrival in [detached, tx] {
            let refused = mining.step(.transactionReceived(arrival, origin: .restored(addedAt: 1)), now: 0)
            guard case .poolChanged(let delta)? = refused.first else { return XCTFail("\(refused)") }
            XCTAssertEqual(delta.removed, [try Mempool.cid(of: tx)], "unresolved or too large, it is not pooled")
        }
    }

    func testAPeerResendingAPendingTransactionGrowsNothing() throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let peer = PeerID(key: "p", session: 1)
        _ = mining.step(.transactionReceived(tx, origin: .peer(peer)), now: 0)
        let before = (mining.pendingOrigins, mining.pendingAdmissions, mining.pendingPeerAdmissions)
        for _ in 0..<5 {
            XCTAssertTrue(mining.step(.transactionReceived(tx, origin: .peer(peer)), now: 0).isEmpty)
            XCTAssertTrue(mining.step(.transactionReceived(tx, origin: .peer(PeerID(key: "q", session: 1))), now: 0).isEmpty)
        }
        XCTAssertEqual(mining.pendingOrigins, before.0)
        XCTAssertEqual(mining.pendingAdmissions, before.1)
        XCTAssertEqual(mining.pendingPeerAdmissions, before.2)
    }

    /// A, B, A: an admission's old verdict is applied and rechecked on the
    /// current epoch; an old build is dropped.
    func testAJobFromBeforeATipMovesAwayAndBackIsStale() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let old)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first,
              case .buildTemplate(let oldBuild)? = mining.step(
                .templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0
              ).first
        else { return XCTFail() }
        _ = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: [])), now: 1)
        _ = mining.step(.tipMoved(TipMove(tipCID: "A", confirmed: [], returned: [])), now: 2)
        XCTAssertEqual(mining.tipCID, old.tipCID)
        XCTAssertNotEqual(mining.tipEpoch, old.tipEpoch)

        let stale = mining.step(.preflighted(old, .ready, balances: funded(old)), now: 3)
        let rechecks = stale.compactMap { if case .preflight(let job) = $0 { job } else { nil } }
        XCTAssertEqual(rechecks.map(\.tipEpoch), [mining.tipEpoch], "A, B, A: the old verdict is rechecked: \(stale)")
        XCTAssertEqual(rechecks.map(\.checksPolicies), [false])
        XCTAssertEqual(mining.mempool.count, 1)
        let block = try await candidateBlock()
        let build = TemplateBuild(workID: "w", block: block, searchTarget: block.target, targets: [block.target])
        XCTAssertTrue(mining.step(.templateBuilt(oldBuild, build), now: 3).isEmpty, "A, B, A: the old build is stale")
        XCTAssertEqual(mining.waitingTemplateRequests, 1)
    }

    /// A template request is refused as retriable after `maxReissues`
    /// moves; a submit waiting through the same moves is not.
    func testTemplateRepliesAreBoundedWhileTheTipChurns() throws {
        var mining = MiningState(tipCID: "T0", spec: testSpec(), config: MiningConfig(maxReissues: 3))
        let tx = try transfer(nonce: 0)
        _ = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0)
        _ = mining.step(.templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0)
        for move in 1...3 {
            let effects = mining.step(.tipMoved(TipMove(tipCID: "T\(move)", confirmed: [], returned: [])), now: Int64(move))
            XCTAssertFalse(effects.contains { if case .transactionRefused = $0 { true } else { false } })
            XCTAssertFalse(effects.contains { if case .templateRefused = $0 { true } else { false } })
        }
        let fourth = mining.step(.tipMoved(TipMove(tipCID: "T4", confirmed: [], returned: [])), now: 4)
        XCTAssertTrue(fourth.contains { if case .templateRefused(2, .contextChanged) = $0 { true } else { false } }, "\(fourth)")
        XCTAssertFalse(fourth.contains { if case .transactionRefused = $0 { true } else { false } }, "\(fourth)")
        XCTAssertEqual(mining.pendingAdmissions, 1)
        XCTAssertEqual(mining.waitingTemplateRequests, 0)
        XCTAssertFalse(fourth.contains { if case .buildTemplate = $0 { true } else { false } })
    }

    /// With no refusal for waiting, the pending bounds still hold however
    /// often the tip moves: the 257th public submit is answered `.full`,
    /// and a peer flood stays within its caps.
    func testPendingBoundsHoldAcrossManyMoves() throws {
        var mining = MiningState(tipCID: "T0", spec: testSpec())
        let bounds = mining.config
        var full: [UInt64] = []
        for reply in UInt64(1)...UInt64(bounds.maxPendingSubmitted + 1) {
            for case .transactionRefused(let replyID, .full) in mining.step(
                .transactionReceived(try transfer(nonce: reply), origin: .submitted(replyID: reply)), now: 0
            ) { full.append(replyID) }
        }
        XCTAssertEqual(full, [UInt64(bounds.maxPendingSubmitted + 1)])
        XCTAssertEqual(mining.pendingSubmitted, bounds.maxPendingSubmitted)

        let peers = (0..<20).map { PeerID(key: "flood\($0)", session: 1) }
        for move in 1...10 {
            for peer in peers {
                for _ in 0..<8 {
                    let key = CryptoUtils.generateKeyPair()
                    _ = mining.step(.transactionReceived(try signed(key, [], nonce: 0), origin: .peer(peer)), now: 0)
                }
                XCTAssertLessThanOrEqual(mining.pendingAdmissions(from: peer), bounds.maxPendingPerPeer)
            }
            _ = mining.step(.tipMoved(TipMove(tipCID: "T\(move)")), now: Int64(move))
            XCTAssertLessThanOrEqual(mining.pendingPeerAdmissions, bounds.maxPendingPeerAdmissions)
            XCTAssertEqual(mining.pendingSubmitted, bounds.maxPendingSubmitted)
        }
        XCTAssertEqual(mining.pendingPeerAdmissions, bounds.maxPendingPeerAdmissions)
    }

    func testAnOrdinaryReorgReturnsEveryTransactionByDefault() {
        XCTAssertEqual(MiningConfig().maxPendingReturned, MempoolLimits().maxCount)
    }

    func testTemplateJobsCoalesceAndATipMoveReissuesAWaitingBuild() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let request = TemplateRequest(rewardRecipient: address(key))
        guard case .buildTemplate(let job)? = mining.step(.templateRequested(replyID: 1, request), now: 0).first
        else { return XCTFail() }
        XCTAssertEqual(job.tipCID, "A")
        XCTAssertTrue(mining.step(.templateRequested(replyID: 2, request), now: 0).isEmpty,
                      "the same plan on the same tip and pool joins the running build")
        XCTAssertEqual(mining.waitingTemplateRequests, 2)

        // The move issues the waiting build again on the new tip, so an
        // executor may skip the stale job.
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: [])), now: 1)
        guard case .buildTemplate(let fresh)? = moved.last else { return XCTFail("\(moved)") }
        XCTAssertEqual(fresh.tipCID, "B")
        XCTAssertEqual(mining.waitingTemplateRequests, 2)

        let block = try await candidateBlock()
        let build = TemplateBuild(workID: "w", block: block, searchTarget: block.target, targets: [block.target])
        XCTAssertTrue(mining.step(.templateBuilt(job, build), now: 2).isEmpty, "a stale build is never issued")
        XCTAssertEqual(mining.templates.count, 0)

        let issued = mining.step(.templateBuilt(fresh, build), now: 3)
        let replies = issued.compactMap { effect -> UInt64? in
            if case .templateIssued(let replyID, let template) = effect, template.tipCID == "B" { return replyID }
            return nil
        }
        XCTAssertEqual(replies, [1, 2])
        XCTAssertNotNil(mining.templates.template("w"))
    }

    /// A pool or hosted-descendant change only rebuilds on the same tip:
    /// every template issued on that tip stays submittable. The tip moving
    /// flushes them all (Stratum's `clean_jobs`), with no clock involved.
    func testEveryTemplateOnATipIsKeptUntilTheTipMoves() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        var workIDs: [String] = []
        for replyID in UInt64(1)...20 {
            let block = try await candidateBlock(timestamp: Int64(replyID))
            let workID = "w\(replyID)"
            try issue(block, as: workID, replyID: replyID, &mining)
            workIDs.append(workID)
        }
        for workID in workIDs { XCTAssertNotNil(mining.templates.template(workID), workID) }

        _ = mining.step(.tipMoved(TipMove(tipCID: "B")), now: Int64.max)
        XCTAssertEqual(mining.templates.count, 0)
        let refused = mining.step(.submitWork(replyID: 99, workID: workIDs[0], nonce: 0), now: Int64.max)
        guard case .workRefused(99, .unknownWork)? = refused.first else { return XCTFail("\(refused)") }
    }

    func testAFailedBuildRefusesItsRequests() {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        guard case .buildTemplate(let job)? = mining.step(
            .templateRequested(replyID: 7, TemplateRequest(rewardRecipient: nil)), now: 0
        ).first else { return XCTFail() }
        let effects = mining.step(.templateBuilt(job, nil), now: 1)
        guard case .templateRefused(7, .buildFailed)? = effects.first else { return XCTFail("\(effects)") }
    }

    func testSubmitWorkIsAnEventThatClosesWorkOnlyWhenTheRootClears() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        // The root clears its own target: the work is done.
        let easy = try await candidateBlock(target: .max)
        try issue(easy, as: "easy", replyID: 1, &mining)
        let mined = mining.step(.submitWork(replyID: 2, workID: "easy", nonce: 5), now: 1)
        guard case .mined(2, let block)? = mined.first else { return XCTFail("\(mined)") }
        XCTAssertEqual(block.nonce, 5)
        XCTAssertNil(mining.templates.template("easy"))

        // A share that clears only an easier (child) threshold keeps the
        // work open for the root's target.
        let hard = try await candidateBlock(target: UInt256(1))
        try issue(hard, as: "hard", searchTarget: .max, replyID: 3, &mining)
        guard case .mined(4, _)? = mining.step(.submitWork(replyID: 4, workID: "hard", nonce: 5), now: 1).first
        else { return XCTFail() }
        XCTAssertNotNil(mining.templates.template("hard"))

        let unknown = mining.step(.submitWork(replyID: 5, workID: "nope", nonce: 0), now: 1)
        guard case .workRefused(5, .unknownWork)? = unknown.first else { return XCTFail("\(unknown)") }
    }

    private func issue(
        _ block: Block,
        as workID: String,
        searchTarget: UInt256? = nil,
        replyID: UInt64,
        _ mining: inout MiningState
    ) throws {
        guard case .buildTemplate(let job)? = mining.step(
            .templateRequested(replyID: replyID, TemplateRequest(rewardRecipient: "\(replyID)")), now: 0
        ).first else { throw XCTSkip("no job") }
        let target = searchTarget ?? block.target
        _ = mining.step(.templateBuilt(job, TemplateBuild(
            workID: workID, block: block, searchTarget: target, targets: [target]
        )), now: 0)
    }
}
