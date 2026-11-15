import Foundation
import XCTest
@testable import LatticeNode

/// The node's recent log lines, kept in memory for `GET /logs`: bounded by
/// count and by bytes.
final class NodeLogTests: XCTestCase {
    func testLinesAreKeptInOrder() {
        let log = NodeLog()
        log.append("first")
        log.append("second\nthird")
        XCTAssertEqual(log.tail(10), "first\nsecond\nthird\n")
        XCTAssertEqual(log.tail(1), "third\n")
        XCTAssertEqual(log.tail(0), "")
    }

    func testTheOldestLinesGoPastTheLineBound() {
        let log = NodeLog()
        let total = NodeLog.maximumLines + 2_500
        for index in 0..<total { log.append("line \(index)") }
        let kept = log.tail(.max).split(separator: "\n")
        XCTAssertEqual(kept.count, NodeLog.maximumLines)
        XCTAssertEqual(kept.first, "line \(total - NodeLog.maximumLines)")
        XCTAssertEqual(kept.last, "line \(total - 1)")
    }

    func testTheOldestLinesGoPastTheByteBound() {
        let log = NodeLog()
        let line = String(repeating: "x", count: 8 << 10)
        for _ in 0..<(NodeLog.maximumBytes / (8 << 10) + 100) { log.append(line) }
        let kept = log.tail(.max)
        XCTAssertLessThanOrEqual(kept.utf8.count - kept.split(separator: "\n").count, NodeLog.maximumBytes)
        XCTAssertGreaterThan(kept.utf8.count, NodeLog.maximumBytes / 2)
    }

    func testALongLineIsKeptInParts() {
        let log = NodeLog()
        log.append(String(repeating: "y", count: NodeLog.maximumLineBytes * 2 + 5))
        let kept = log.tail(.max).split(separator: "\n")
        XCTAssertEqual(kept.map(\.utf8.count), [NodeLog.maximumLineBytes, NodeLog.maximumLineBytes, 5])
    }
}
