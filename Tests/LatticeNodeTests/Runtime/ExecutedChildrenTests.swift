import LatticeNodeCore
import XCTest

/// The child directories a chain's executed blocks commit: grow-only, in order.
final class ExecutedChildrenTests: XCTestCase {
    func testDirectoriesAreKeptOnceInOrderAndNeverRemoved() {
        let children = ExecutedChildren()
        children.record(["swap", "stoa"])
        children.record([])
        children.record(["stoa", "bitcoin"])
        XCTAssertEqual(children.names, ["bitcoin", "stoa", "swap"])
    }

    func testPagesFollowTheOrderFromAfterAnyName() {
        let children = ExecutedChildren()
        children.record(["a", "c", "e", "g"])
        XCTAssertEqual(children.page(after: nil, limit: 2).names, ["a", "c"])
        XCTAssertEqual(children.page(after: nil, limit: 2).more, true)
        XCTAssertEqual(children.page(after: "c", limit: 2).names, ["e", "g"])
        XCTAssertEqual(children.page(after: "c", limit: 2).more, false)
        // A cursor need not be listed: it continues from where it would sort.
        XCTAssertEqual(children.page(after: "d", limit: 10).names, ["e", "g"])
        XCTAssertEqual(children.page(after: "z", limit: 10).names, [])
        XCTAssertEqual(children.page(after: "z", limit: 10).more, false)
    }
}
