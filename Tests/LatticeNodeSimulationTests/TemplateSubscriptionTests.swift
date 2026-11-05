import Lattice
import LatticeNodeCore
import UInt256
import XCTest

/// Template subscriptions: pushes on context changes, builds coalesced by
/// events (never a timer), and work retained per tip (Stratum's
/// `clean_jobs`).
final class TemplateSubscriptionTests: XCTestCase {
    private let plan = TemplateRequest(rewardRecipient: "miner")

    private func build(_ timestamp: Int64, digest: String) async throws -> TemplateBuild {
        let block = try await candidateBlock(timestamp: timestamp)
        return TemplateBuild(
            workID: try BlockHeader(node: block).rawCID, block: block,
            searchTarget: block.target, targets: [block.target], digest: digest
        )
    }

    private func jobs(_ effects: [MiningEffect]) -> [TemplateJob] {
        effects.compactMap { if case .buildTemplate(let job) = $0 { job } else { nil } }
    }

    private func pushes(_ effects: [MiningEffect]) -> [(subscribers: [UInt64], template: WorkTemplate, clean: Bool)] {
        effects.compactMap {
            if case .templatePushed(let subscribers, let template, let clean) = $0 { (subscribers, template, clean) } else { nil }
        }
    }

    func testSubscriberGetsATemplateThenOneOnEachContextChange() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        guard let first = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0)).first else {
            return XCTFail("subscribing builds")
        }
        let pushed = pushes(mining.step(.templateBuilt(first, try await build(1, digest: "d1")), now: 1))
        XCTAssertEqual(pushed.map(\.subscribers), [[1]])
        XCTAssertEqual(pushed.map(\.clean), [true], "a subscriber's first template is clean")

        // A hosted descendant moved: same tip, so earlier work stays valid.
        guard let second = jobs(mining.step(.templateContextChanged, now: 2)).first else {
            return XCTFail("a context change builds")
        }
        let next = pushes(mining.step(.templateBuilt(second, try await build(2, digest: "d2")), now: 3))
        XCTAssertEqual(next.map(\.clean), [false])
        XCTAssertNotNil(mining.templates.template(pushed[0].template.workID), "earlier work kept")
    }

    func testABurstOfChangesDuringABuildYieldsExactlyOneMoreBuild() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        guard let running = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0)).first else {
            return XCTFail()
        }
        for _ in 0..<10 {
            XCTAssertTrue(jobs(mining.step(.templateContextChanged, now: 0)).isEmpty, "no build while one runs")
        }
        let ended = mining.step(.templateBuilt(running, try await build(1, digest: "d1")), now: 1)
        XCTAssertEqual(pushes(ended).count, 1, "the finished build is still valid work on this tip")
        let again = jobs(ended)
        XCTAssertEqual(again.count, 1, "one more build, however many changes arrived")
        XCTAssertEqual(again.first?.contextVersion, mining.contextVersion)

        let settled = mining.step(.templateBuilt(again[0], try await build(2, digest: "d2")), now: 2)
        XCTAssertTrue(jobs(settled).isEmpty, "nothing moved since: no further build")
    }

    func testAnUnchangedTemplateIsNotPushedAgain() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let same = try await build(1, digest: "d1")
        let first = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0))[0]
        XCTAssertEqual(pushes(mining.step(.templateBuilt(first, same), now: 1)).count, 1)
        let second = jobs(mining.step(.templateContextChanged, now: 2))[0]
        XCTAssertTrue(pushes(mining.step(.templateBuilt(second, same), now: 3)).isEmpty)
    }

    /// Fast-churning children never make work unknown while the tip holds;
    /// the tip moving flushes it all and the next push is clean.
    func testChildChurnKeepsWorkAndATipMoveFlushesIt() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        var workIDs: [String] = []
        var job = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0))[0]
        for round in 1...20 {
            let pushed = pushes(mining.step(.templateBuilt(job, try await build(Int64(round), digest: "d\(round)")), now: 0))
            XCTAssertEqual(pushed.map(\.clean), [round == 1])
            workIDs.append(pushed[0].template.workID)
            job = jobs(mining.step(.templateContextChanged, now: 0))[0]
        }
        for (index, workID) in workIDs.enumerated() {
            let effects = mining.step(.submitWork(replyID: UInt64(100 + index), workID: workID, nonce: 0), now: 0)
            guard case .mined? = effects.first else { return XCTFail("work \(index) refused: \(effects)") }
        }

        workIDs = []
        for round in 21...23 {
            let pushed = pushes(mining.step(.templateBuilt(job, try await build(Int64(round), digest: "d\(round)")), now: 0))
            workIDs.append(pushed[0].template.workID)
            job = jobs(mining.step(.templateContextChanged, now: 0))[0]
        }
        _ = mining.step(.tipMoved(TipMove(tipCID: "B")), now: 0)
        for workID in workIDs {
            let effects = mining.step(.submitWork(replyID: 200, workID: workID, nonce: 0), now: 0)
            guard case .workRefused(_, .unknownWork)? = effects.first else {
                return XCTFail("work on the old tip accepted: \(effects)")
            }
        }
        // The move's own build (dropped: it ran on the old tip), then the
        // shell's context change builds on B; then descendant moves.
        guard let onB = jobs(mining.step(.templateContextChanged, now: 0)).first else { return XCTFail() }
        XCTAssertEqual(onB.tipCID, "B")
        let afterMove = pushes(mining.step(.templateBuilt(onB, try await build(30, digest: "b1")), now: 0))
        XCTAssertEqual(afterMove.map(\.clean), [true], "the first push on a new tip is clean")
        let child = jobs(mining.step(.templateContextChanged, now: 0))[0]
        let childBuild = try await build(31, digest: "b2")
        XCTAssertEqual(pushes(mining.step(.templateBuilt(child, childBuild), now: 0)).map(\.clean), [false])
    }

    func testALateSubscriberGetsTheCurrentTemplateAtOnce() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let job = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0))[0]
        let first = pushes(mining.step(.templateBuilt(job, try await build(1, digest: "d1")), now: 0))[0].template
        let late = mining.step(.templateSubscribed(subscriberID: 2, plan), now: 0)
        XCTAssertTrue(jobs(late).isEmpty)
        XCTAssertEqual(pushes(late).map(\.subscribers), [[2]])
        XCTAssertEqual(pushes(late).first?.template.workID, first.workID)
        XCTAssertEqual(pushes(late).first?.clean, true)
    }

    /// One who subscribes while a build runs gets a clean first push even
    /// when the plan's other subscribers get an unclean one.
    func testASubscriberJoiningMidBuildGetsACleanFirstPush() async throws {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        let first = jobs(mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0))[0]
        _ = mining.step(.templateBuilt(first, try await build(1, digest: "d1")), now: 0)
        let second = jobs(mining.step(.templateContextChanged, now: 0))[0]
        XCTAssertTrue(pushes(mining.step(.templateSubscribed(subscriberID: 2, plan), now: 0)).isEmpty)
        let pushed = pushes(mining.step(.templateBuilt(second, try await build(2, digest: "d2")), now: 0))
        XCTAssertEqual(pushed.map(\.subscribers), [[2], [1]])
        XCTAssertEqual(pushed.map(\.clean), [true, false])
    }

    func testUnsubscribedPlansStopBuilding() {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        _ = mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0)
        _ = mining.step(.templateUnsubscribed(subscriberID: 1), now: 0)
        XCTAssertEqual(mining.templateSubscribers, 0)
        XCTAssertTrue(jobs(mining.step(.templateContextChanged, now: 0)).isEmpty)
    }

    func testSubscribersAreBounded() {
        var mining = MiningState(tipCID: "A", spec: testSpec(), config: MiningConfig(maxTemplateSubscribers: 1))
        _ = mining.step(.templateSubscribed(subscriberID: 1, plan), now: 0)
        let refused = mining.step(.templateSubscribed(subscriberID: 2, plan), now: 0)
        guard case .subscriptionRefused(2, .busy)? = refused.first else { return XCTFail("\(refused)") }
        XCTAssertEqual(mining.templateSubscribers, 1)
    }

    /// A pull request does not join a build issued before the context moved.
    func testAPullRequestDoesNotJoinABuildFromAnOlderContext() {
        var mining = MiningState(tipCID: "A", spec: testSpec())
        XCTAssertEqual(jobs(mining.step(.templateRequested(replyID: 1, plan), now: 0)).count, 1)
        _ = mining.step(.templateContextChanged, now: 0)
        XCTAssertEqual(jobs(mining.step(.templateRequested(replyID: 2, plan), now: 0)).count, 1)
    }
}
