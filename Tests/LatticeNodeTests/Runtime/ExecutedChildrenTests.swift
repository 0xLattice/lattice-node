import LatticeNodeCore
import XCTest

/// The child directories a chain's executed blocks commit: grow-only, each
/// directory with its newest commitment by height.
final class ExecutedChildrenTests: XCTestCase {
    private func listed(_ children: ExecutedChildren) -> [String] {
        children.mostRecent(100).map { "\($0.directory)=\($0.cid)@\($0.height)" }
    }

    func testEachDirectoryKeepsItsNewestCommitmentAndQuietOnesStay() {
        let children = ExecutedChildren()
        children.record(["stoa": "s1", "swap": "w1"], height: 1)
        children.record(["stoa": "s2"], height: 2)
        children.record([:], height: 3)
        XCTAssertEqual(listed(children), ["stoa=s2@2", "swap=w1@1"])
        XCTAssertEqual(children["swap"]?.cid, "w1", "a quiet child stays listed")
        XCTAssertNil(children["nothing"])
    }

    /// Blocks execute in any order across branches; an older one arriving
    /// later never replaces a newer commitment, and at one height the smaller
    /// CID is kept, so the result does not depend on arrival order.
    func testArrivalOrderDoesNotMatter() {
        let a = ExecutedChildren(), b = ExecutedChildren()
        let blocks: [([String: String], UInt64)] = [
            (["stoa": "s5"], 5), (["stoa": "s3", "x": "x3"], 3), (["stoa": "sz"], 5), (["stoa": "sa"], 5),
        ]
        for (commitments, height) in blocks { a.record(commitments, height: height) }
        for (commitments, height) in blocks.reversed() { b.record(commitments, height: height) }
        XCTAssertEqual(listed(a), ["stoa=s5@5", "x=x3@3"])
        XCTAssertEqual(listed(a), listed(b))
    }

    /// Execution is irrevocable: a directory committed only on a branch that
    /// later lost stays listed.
    func testNothingIsRemoved() {
        let children = ExecutedChildren()
        children.record(["gone": "g2"], height: 2)
        children.record(["kept": "k3"], height: 3)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children["gone"]?.cid, "g2")
    }

    func testTheMostRecentListIsRebuiltAfterAChangeAndBounded() {
        let children = ExecutedChildren()
        children.record(["a": "a1"], height: 1)
        XCTAssertEqual(listed(children), ["a=a1@1"])
        children.record(["b": "b2"], height: 2)
        XCTAssertEqual(listed(children), ["b=b2@2", "a=a1@1"])
        XCTAssertEqual(children.mostRecent(1).map(\.directory), ["b"])
        for n in 0..<150 { children.record(["d\(n)": "c\(n)"], height: 10) }
        XCTAssertEqual(children.mostRecent(500).count, ExecutedChildren.recentLimit)
    }
}
