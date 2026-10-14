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
}
