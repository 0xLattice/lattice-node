import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest

/// `Mining.step`: preflight and template jobs carry the tip they ran on, a
/// result for a moved tip is dropped and redone, the pool delta precedes
/// every reply, and `submitWork` is an event.
final class MiningStepTests: XCTestCase {
    let key = CryptoUtils.generateKeyPair()

    func transfer(nonce: UInt64, debit: Int64 = 2) throws -> Transaction {
        try signed(key, [AccountAction(owner: address(key), delta: -debit)], nonce: nonce)
    }

    func testALocalSubmitIsPreflightedThenPooledJournaledAnnouncedAndAnswered() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)

        let first = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 10)
        guard case .preflight(let job)? = first.first, first.count == 1 else {
            return XCTFail("expected one preflight job, got \(first)")
        }
        XCTAssertEqual(job.tipCID, "A")
        XCTAssertEqual(job.cid, cid)
        XCTAssertEqual(mining.mempool.count, 0, "nothing is pooled before its verdict")

        let second = mining.step(.preflighted(job, .ready), now: 20)
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

    func testAMoveThatLeavesBlocksAsksForTheirTransactions() {
        var mining = Mining(tipCID: "A1", spec: testSpec())
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B2", left: ["A1"], entered: ["B1", "B2"])), now: 1)
        XCTAssertTrue(moved.contains {
            if case .returnTransactions(["A1"], ["B1", "B2"]) = $0 { true } else { false }
        }, "\(moved)")
        let forward = mining.step(.tipMoved(TipMove(tipCID: "B3", entered: ["B3"])), now: 2)
        XCTAssertFalse(forward.contains { if case .returnTransactions = $0 { true } else { false } })
    }

    func testAPeerTransactionIsRelayedOnceWhenItIsNewlyPooled() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        let peer = PeerID(key: "p", session: 1)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .peer(peer)), now: 0).first else {
            return XCTFail()
        }
        let admitted = mining.step(.preflighted(job, .ready), now: 1)
        XCTAssertTrue(admitted.contains { if case .announceTransaction(cid) = $0 { true } else { false } })
        XCTAssertFalse(admitted.contains { if case .transactionAdmitted = $0 { true } else { false } },
                       "a peer is never answered")
        let resent = mining.step(.transactionReceived(tx, origin: .peer(PeerID(key: "q", session: 1))), now: 2)
        XCTAssertFalse(resent.contains { if case .announceTransaction = $0 { true } else { false } },
                       "a resend of a pooled transaction is not relayed again")
    }

    func testAVerdictOnAMovedTipIsDroppedAndTheMoveReissuesIt() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let stale)? = mining.step(
            .transactionReceived(tx, origin: .peer(PeerID(key: "p", session: 1))), now: 0
        ).first else { return XCTFail() }

        let moved = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: [])), now: 1)
        guard case .preflight(let current)? = moved.first else { return XCTFail("the move reissues: \(moved)") }
        XCTAssertEqual(current.tipCID, "B")
        XCTAssertEqual(mining.outstandingPreflights, 1, "only the job on the current tip is tracked")

        XCTAssertTrue(mining.step(.preflighted(stale, .ready), now: 2).isEmpty)
        XCTAssertEqual(mining.mempool.count, 0, "a stale verdict is never applied")
        XCTAssertEqual(mining.pendingAdmissions, 1)

        _ = mining.step(.preflighted(current, .ready), now: 3)
        XCTAssertEqual(mining.mempool.count, 1)
        XCTAssertEqual(mining.pendingAdmissions, 0)
        XCTAssertEqual(mining.outstandingPreflights, 0)
    }

    func testATipMoveRemovesConfirmedRevalidatesThePoolAndReadmitsReturned() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let kept = try transfer(nonce: 1)
        let confirmed = try transfer(nonce: 0)
        let returnedKey = CryptoUtils.generateKeyPair()
        let returned = try signed(returnedKey, [AccountAction(owner: address(returnedKey), delta: -1)], nonce: 0)
        for tx in [kept, confirmed] {
            guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 9)), now: 0).first
            else { return XCTFail() }
            _ = mining.step(.preflighted(job, tx.body.node?.nonce == 0 ? .ready : .future), now: 0)
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
        let admitted = mining.step(.preflighted(returnedJob, .ready), now: 6)
        XCTAssertTrue(admitted.contains { if case .announceTransaction = $0 { true } else { false } },
                      "a returned transaction is announced again")
        let keptJob = try XCTUnwrap(jobs.first { $0.cid == (try? Mempool.cid(of: kept)) })
        let dropped = mining.step(.preflighted(keptJob, .invalid), now: 7)
        guard case .poolChanged(let removal)? = dropped.first else { return XCTFail("\(dropped)") }
        XCTAssertEqual(removal.removed, [try Mempool.cid(of: kept)])
        XCTAssertTrue(mining.journaled.isEmpty)
    }

    func testRefusalsAnswerLocalSubmitsAndNeverPeers() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(
            .transactionReceived(tx, origin: .peer(PeerID(key: "p", session: 1))), now: 0
        ).first else { return XCTFail() }
        // A second arrival joins the first's pending verdict: one job.
        let joined = mining.step(.transactionReceived(tx, origin: .local(replyID: 4)), now: 0)
        XCTAssertTrue(joined.isEmpty)
        let answered = mining.step(.preflighted(job, .invalid), now: 1)
        guard case .transactionRefused(4, .invalidState)? = answered.first, answered.count == 1 else {
            return XCTFail("only the local submit is answered: \(answered)")
        }

        let restoredKey = CryptoUtils.generateKeyPair()
        let restored = try signed(restoredKey, [], nonce: 0)
        guard case .preflight(let restoredJob)? = mining.step(
            .transactionReceived(restored, origin: .restored(addedAt: 1)), now: 0
        ).first else { return XCTFail() }

        let refused = mining.step(.preflighted(restoredJob, .invalid), now: 1)
        guard case .poolChanged(let delta)? = refused.first else { return XCTFail("\(refused)") }
        XCTAssertEqual(delta.removed, [try Mempool.cid(of: restored)], "the journal row goes with the refusal")
    }

    func testRestoredAndLocalArrivalsAreNeverRefusedForCapacityAndKeepTheirJournalRows() throws {
        var mining = Mining(tipCID: "A", spec: testSpec(), config: MiningConfig(
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

        _ = mining.step(.preflighted(jobs[0], .ready), now: 1)
        // The pool is full and the second pays less: a capacity refusal, not a verdict.
        let full = mining.step(.preflighted(jobs[1], .ready), now: 1)
        XCTAssertFalse(full.contains { if case .poolChanged(let delta) = $0 { !delta.removed.isEmpty } else { false } },
                       "a capacity refusal never removes a journal row: \(full)")
    }

    func testPeerAdmissionsAreBoundedPerPeerAndInTotalWithoutCrowdingOutLocals() throws {
        var mining = Mining(tipCID: "A", spec: testSpec(), config: MiningConfig(
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
        var mining = Mining(tipCID: "A", spec: testSpec(), config: MiningConfig(maxPendingReturned: 2))
        let returned = try (0..<5).map { try transfer(nonce: UInt64($0)) }
        let effects = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: returned)), now: 0)
        XCTAssertEqual(mining.pendingReturned, 2)
        XCTAssertEqual(mining.pendingAdmissions, 2)
        XCTAssertEqual(effects.filter { if case .preflight = $0 { true } else { false } }.count, 2)
    }

    func testAPendingSubmitTheChainConfirmsIsAnsweredAsAccepted() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        let cid = try Mempool.cid(of: tx)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 5)), now: 0).first
        else { return XCTFail() }
        let moved = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [cid], returned: [])), now: 1)
        XCTAssertTrue(moved.contains { if case .transactionAdmitted(5, cid, _, _) = $0 { true } else { false } }, "\(moved)")
        XCTAssertFalse(moved.contains { if case .transactionRefused = $0 { true } else { false } })
        XCTAssertFalse(moved.contains { if case .preflight = $0 { true } else { false } }, "nothing left to classify")
        XCTAssertEqual(mining.pendingAdmissions, 0)
        XCTAssertTrue(mining.step(.preflighted(job, .ready), now: 2).isEmpty)
    }

    func testAChildCandidateRequestSelectsTheContextualPool() async throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let job)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first
        else { return XCTFail() }
        // A withdrawal waiting on its parent receipt classifies unavailable.
        _ = mining.step(.preflighted(job, .unavailable), now: 0)

        guard case .buildTemplate(let plain)? = mining.step(
            .templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0
        ).first else { return XCTFail() }
        XCTAssertTrue(plain.transactions.isEmpty)

        let carrier = try await candidateBlock()
        let context = ParentCarrier(cid: try BlockHeader(node: carrier).rawCID, block: carrier)
        guard case .buildTemplate(let contextual)? = mining.step(
            .templateRequested(replyID: 3, TemplateRequest(rewardRecipient: nil, parentCarrier: context)), now: 0
        ).first else { return XCTFail("another carrier is another plan") }
        XCTAssertEqual(contextual.transactions.map(\.body.rawCID), [tx.body.rawCID])
        XCTAssertEqual(contextual.request.parentCarrier?.cid, context.cid)
    }

    func testOnlyADeterministicCheckFailureRemovesARestoredJournalRow() throws {
        var mining = Mining(tipCID: "A", spec: testSpec(maxBlockSize: 64))
        let tx = try transfer(nonce: 0)
        let detached = Transaction(signatures: tx.signatures, body: tx.body.removingNode())
        let unresolved = mining.step(.transactionReceived(detached, origin: .restored(addedAt: 1)), now: 0)
        XCTAssertTrue(unresolved.isEmpty, "unresolved content is not a verdict: \(unresolved)")

        let tooLarge = mining.step(.transactionReceived(tx, origin: .restored(addedAt: 1)), now: 0)
        guard case .poolChanged(let delta)? = tooLarge.first else { return XCTFail("\(tooLarge)") }
        XCTAssertEqual(delta.removed, [try Mempool.cid(of: tx)], "too large on any tip is a verdict")
    }

    func testAPeerResendingAPendingTransactionGrowsNothing() throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
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

    func testAJobFromBeforeATipMovesAwayAndBackIsStale() async throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let tx = try transfer(nonce: 0)
        guard case .preflight(let old)? = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0).first,
              case .buildTemplate(let oldBuild)? = mining.step(
                .templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0
              ).first
        else { return XCTFail() }
        _ = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: [])), now: 1)
        let back = mining.step(.tipMoved(TipMove(tipCID: "A", confirmed: [], returned: [])), now: 2)
        XCTAssertEqual(mining.tipCID, old.tipCID)
        XCTAssertNotEqual(mining.tipEpoch, old.tipEpoch)
        let fresh = back.compactMap { if case .preflight(let job) = $0 { job } else { nil } }
        XCTAssertEqual(fresh.map(\.tipEpoch), [mining.tipEpoch])

        XCTAssertTrue(mining.step(.preflighted(old, .ready), now: 3).isEmpty, "A, B, A: the old verdict is stale")
        XCTAssertEqual(mining.mempool.count, 0)
        let block = try await candidateBlock()
        let build = TemplateBuild(workID: "w", block: block, searchTarget: block.target, targets: [block.target])
        XCTAssertTrue(mining.step(.templateBuilt(oldBuild, build), now: 3).isEmpty, "A, B, A: the old build is stale")
        XCTAssertEqual(mining.waitingTemplateRequests, 1)
    }

    func testRepliesAreBoundedWhileTheTipChurns() throws {
        var mining = Mining(tipCID: "T0", spec: testSpec(), config: MiningConfig(maxReissues: 3))
        let tx = try transfer(nonce: 0)
        _ = mining.step(.transactionReceived(tx, origin: .local(replyID: 1)), now: 0)
        _ = mining.step(.templateRequested(replyID: 2, TemplateRequest(rewardRecipient: nil)), now: 0)
        for move in 1...3 {
            let effects = mining.step(.tipMoved(TipMove(tipCID: "T\(move)", confirmed: [], returned: [])), now: Int64(move))
            XCTAssertFalse(effects.contains { if case .transactionRefused = $0 { true } else { false } })
            XCTAssertFalse(effects.contains { if case .templateRefused = $0 { true } else { false } })
        }
        let fourth = mining.step(.tipMoved(TipMove(tipCID: "T4", confirmed: [], returned: [])), now: 4)
        XCTAssertTrue(fourth.contains { if case .transactionRefused(1, .contextChanged) = $0 { true } else { false } }, "\(fourth)")
        XCTAssertTrue(fourth.contains { if case .templateRefused(2, .contextChanged) = $0 { true } else { false } }, "\(fourth)")
        XCTAssertEqual(mining.pendingAdmissions, 0)
        XCTAssertEqual(mining.waitingTemplateRequests, 0)
        XCTAssertFalse(fourth.contains { if case .preflight = $0 { true } else { false } })
        XCTAssertFalse(fourth.contains { if case .buildTemplate = $0 { true } else { false } })
    }

    func testAnOrdinaryReorgReturnsEveryTransactionByDefault() {
        XCTAssertEqual(MiningConfig().maxPendingReturned, MempoolLimits().maxCount)
    }

    func testTemplateJobsCoalesceAndATipMoveReissuesAWaitingBuild() async throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
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
        XCTAssertEqual(mining.templates.template("w")?.expiresAt, 3 + mining.templates.lifetime)
    }

    func testAFailedBuildRefusesItsRequests() {
        var mining = Mining(tipCID: "A", spec: testSpec())
        guard case .buildTemplate(let job)? = mining.step(
            .templateRequested(replyID: 7, TemplateRequest(rewardRecipient: nil)), now: 0
        ).first else { return XCTFail() }
        let effects = mining.step(.templateBuilt(job, nil), now: 1)
        guard case .templateRefused(7, .buildFailed)? = effects.first else { return XCTFail("\(effects)") }
    }

    func testSubmitWorkIsAnEventThatClosesWorkOnlyWhenTheRootClears() async throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
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
        _ mining: inout Mining
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
