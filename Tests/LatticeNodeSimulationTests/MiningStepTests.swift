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

    func testPendingAdmissionsAreBounded() throws {
        var mining = Mining(tipCID: "A", spec: testSpec(), config: MiningConfig(maxPendingAdmissions: 1))
        _ = mining.step(.transactionReceived(try transfer(nonce: 0), origin: .local(replyID: 1)), now: 0)
        let refused = mining.step(.transactionReceived(try transfer(nonce: 1), origin: .local(replyID: 2)), now: 0)
        guard case .transactionRefused(2, .full)? = refused.first else { return XCTFail("\(refused)") }
    }

    func testTemplateJobsCoalesceAndAStaleBuildIsRebuiltOnTheNewTip() async throws {
        var mining = Mining(tipCID: "A", spec: testSpec())
        let request = TemplateRequest(rewardRecipient: address(key))
        guard case .buildTemplate(let job)? = mining.step(.templateRequested(replyID: 1, request), now: 0).first
        else { return XCTFail() }
        XCTAssertEqual(job.tipCID, "A")
        XCTAssertTrue(mining.step(.templateRequested(replyID: 2, request), now: 0).isEmpty,
                      "the same plan on the same tip and pool joins the running build")
        XCTAssertEqual(mining.waitingTemplateRequests, 2)

        _ = mining.step(.tipMoved(TipMove(tipCID: "B", confirmed: [], returned: [])), now: 1)
        let block = try await candidateBlock()
        let build = TemplateBuild(workID: "w", block: block, searchTarget: block.target, targets: [block.target])
        let rebuilt = mining.step(.templateBuilt(job, build), now: 2)
        guard case .buildTemplate(let fresh)? = rebuilt.first, rebuilt.count == 1 else {
            return XCTFail("a stale build is never issued: \(rebuilt)")
        }
        XCTAssertEqual(fresh.tipCID, "B")
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
