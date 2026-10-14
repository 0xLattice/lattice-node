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
        XCTAssertEqual(view.children.mostRecent(10).map(\.directory), ["stoa", "swap"], "most recent first")
        XCTAssertEqual(view.children.mostRecent(1).map(\.directory), ["stoa"])
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

    /// The tip moving back and forth between siblings returns the index to
    /// the same state each time: each height undoes exactly what it did.
    func testFlippingBetweenSiblingsRestoresTheSameIndex() {
        commitments = [
            "g": ["a": "a0"],
            "b1": ["a": "a1", "b": "b1"],
            "x2": ["a": "ax", "c": "cx"],
            "y2": ["b": "by"],
        ]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "x2"])
        let onX = view.children.mostRecent(10).map { "\($0.directory)=\($0.child.cid)@\($0.child.height)" }
        move(&view, to: ["g", "b1", "y2"])
        XCTAssertEqual(entry(view, "a"), .init(cid: "a1", height: 1))
        XCTAssertEqual(entry(view, "b"), .init(cid: "by", height: 2))
        XCTAssertNil(entry(view, "c"))
        XCTAssertEqual(
            view.children.mostRecent(10).map(\.directory), ["b", "a"],
            "the most recent list is rebuilt after the tip moves"
        )
        move(&view, to: ["g", "b1", "x2"])
        XCTAssertEqual(view.children.mostRecent(10).map { "\($0.directory)=\($0.child.cid)@\($0.child.height)" }, onX)
        move(&view, to: ["g"])
        XCTAssertEqual(entry(view, "a"), .init(cid: "a0", height: 0))
        XCTAssertEqual(view.children.count, 1)
    }

    func testABlockWithNoRecordedCommitmentsCommitsNothing() {
        commitments = ["g": [:], "b1": ["stoa": "s1"]]
        var view = NodeReadView()
        move(&view, to: ["g", "b1", "unknown"])
        XCTAssertEqual(entry(view, "stoa"), .init(cid: "s1", height: 1))
    }
}
