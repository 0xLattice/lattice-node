import Foundation
import XCTest
@testable import LatticeNodeDaemon

/// The node's recent output, kept in memory for `GET /logs`: whole lines,
/// bounded by count and by bytes.
final class NodeLogTests: XCTestCase {
    func testALineIsKeptOnceItEnds() {
        let log = NodeLog()
        log.append(Data("first\nsec".utf8))
        XCTAssertEqual(log.tail(10), "first\n")
        log.append(Data("ond\n".utf8))
        XCTAssertEqual(log.tail(10), "first\nsecond\n")
        XCTAssertEqual(log.tail(1), "second\n")
        XCTAssertEqual(log.tail(0), "")
    }

    func testTheOldestLinesGoPastTheLineBound() {
        let log = NodeLog()
        let total = NodeLog.maximumLines + 2_500
        for index in 0..<total { log.append(Data("line \(index)\n".utf8)) }
        let kept = log.tail(.max).split(separator: "\n")
        XCTAssertEqual(kept.count, NodeLog.maximumLines)
        XCTAssertEqual(kept.first, "line \(total - NodeLog.maximumLines)")
        XCTAssertEqual(kept.last, "line \(total - 1)")
    }

    func testTheOldestLinesGoPastTheByteBound() {
        let log = NodeLog()
        let line = String(repeating: "x", count: 8 << 10)
        for _ in 0..<(NodeLog.maximumBytes / (8 << 10) + 100) { log.append(Data((line + "\n").utf8)) }
        let kept = log.tail(.max)
        XCTAssertLessThanOrEqual(kept.utf8.count - kept.split(separator: "\n").count, NodeLog.maximumBytes)
        XCTAssertGreaterThan(kept.utf8.count, NodeLog.maximumBytes / 2)
    }

    func testAnEndlessLineIsKeptInParts() {
        let log = NodeLog()
        log.append(Data(String(repeating: "y", count: NodeLog.maximumLineBytes * 2 + 5).utf8))
        let kept = log.tail(.max).split(separator: "\n")
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.allSatisfy { $0.utf8.count == NodeLog.maximumLineBytes })
    }
}
