import XCTest
@testable import LatticeNode

/// The read view's child directory index: every directory the act-on chain
/// has committed, each with its newest commitment, kept as the chain moves.
final class ChildDirectoryIndexTests: XCTestCase {
    /// Block hash → the child commitments its header records.
    private var commitments: [String: [String: String]] = [:]

    private func move(_ view: inout NodeReadView, to chain: [String]) {
        view.moveActOnChain(to: chain.last!, parent: { cid in
            chain.firstIndex(of: cid).flatMap { $0 > 0 ? chain[$0 - 1] : nil }
        }, height: chain.count - 1, commitments: { self.commitments[$0] })
    }

    private func entry(_ view: NodeReadView, _ directory: String) -> NodeReadView.CommittedChild? {
        view.children[directory]
    }

    func testEveryDirectoryEverCommittedIsListedWithItsNewestCommitment() {
        commitments = [
            "g": [:],
            "b1": ["stoa": "s1", "swap": "w1"],
            "b2": ["stoa": "s2"],
            "b3": [:],
        ]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "b2", "b3"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "s2", height: 2))
        XCTAssertEqual(entry(view, "swap"), .init(cid: "w1", height: 1), "a quiet child stays listed")
        XCTAssertEqual(view.children.count, 2)
        XCTAssertEqual(view.heights.count, 4)
    }

    func testTheTipAdvancingAddsOnlyWhatTheNewBlocksCommit() {
        commitments = ["g": [:], "b1": ["stoa": "s1"], "b2": [:], "b3": ["stoa": "s3", "new": "n3"]]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "b2"])
        move(&view, to: ["g", "b1", "b2", "b3"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "s3", height: 3))
        XCTAssertEqual(entry(view, "new"), .init(cid: "n3", height: 3))
    }

    /// A reorg drops commitments made only on the abandoned branch, and a
    /// directory whose newest commitment was there falls back to its newest
    /// on the chain that remains.
    func testAReorgFallsBackToTheNewestCommitmentThatRemains() {
        commitments = [
            "g": [:],
            "b1": ["stoa": "s1"],
            "a2": ["stoa": "sa", "gone": "x"],
            "c2": [:],
            "c3": ["other": "o3"],
        ]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "a2"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "sa", height: 2))
        move(&view, to: ["g", "b1", "c2", "c3"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "s1", height: 1))
        XCTAssertNil(entry(view, "gone"), "committed only on the abandoned branch")
        XCTAssertEqual(entry(view, "other"), .init(cid: "o3", height: 3))
        XCTAssertEqual((0..<view.heights.count).compactMap { view.heights[$0] }, ["g", "b1", "c2", "c3"])
    }

    func testABlockWithNoRecordedCommitmentsCommitsNothing() {
        commitments = ["g": [:], "b1": ["stoa": "s1"]]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "unknown"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "s1", height: 1))
    }
}
