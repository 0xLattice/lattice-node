import Crypto
import Foundation
import Ivy
import XCTest
@testable import LatticeNode

final class PeerSetTests: XCTestCase {

    private struct Record: PeerRecord, Equatable {
        var a: Int?
        var b: String?
        var isEmpty: Bool { a == nil && b == nil }
    }

    private func key(_ byte: UInt8) throws -> PeerKey {
        let signing = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: byte, count: 32)
        )
        return try PeerKey(rawRepresentation: signing.publicKey.rawRepresentation)
    }

    func testUpdateCreatesTheRecordAndReturnsTheBodyResult() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        let result = set.update(k) { record -> Int in
            record.a = 7
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(set[k], Record(a: 7, b: nil))
        XCTAssertEqual(Set(set.keys), [k])
    }

    func testUpdateThatLeavesTheRecordEmptyPrunesIt() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        set.update(k) { $0.a = 1; $0.b = "x" }
        set.update(k) { $0.a = nil }
        XCTAssertEqual(set[k], Record(a: nil, b: "x"), "a partial clear keeps the key")
        set.update(k) { $0.b = nil }
        XCTAssertNil(set[k], "the last field cleared drops the key")
        XCTAssertTrue(set.keys.isEmpty)
    }

    func testUpdateOnAMissingKeyThatSetsNothingStoresNothing() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        let seen = set.update(k) { $0.a }
        XCTAssertNil(seen)
        XCTAssertNil(set[k])
        XCTAssertTrue(set.records.isEmpty)
    }

    func testRemoveReturnsTheRecordAndDropsOnlyThatKey() throws {
        var set = PeerSet<Record>()
        let k1 = try key(1)
        let k2 = try key(2)
        set.update(k1) { $0.a = 1 }
        set.update(k2) { $0.b = "two" }
        XCTAssertEqual(set.remove(k1), Record(a: 1, b: nil))
        XCTAssertNil(set.remove(k1), "a second remove finds nothing")
        XCTAssertNil(set[k1])
        XCTAssertEqual(set[k2], Record(a: nil, b: "two"))
    }

    func testRemoveAllHandsBackEveryRecordAndEmptiesTheSet() throws {
        var set = PeerSet<Record>()
        set.update(try key(1)) { $0.a = 1 }
        set.update(try key(2)) { $0.a = 2 }
        set.update(try key(3)) { $0.b = "three" }
        let removed = set.removeAll()
        XCTAssertEqual(removed.count, 3)
        XCTAssertEqual(Set(removed.compactMap(\.a)), [1, 2])
        XCTAssertEqual(removed.compactMap(\.b), ["three"])
        XCTAssertTrue(set.records.isEmpty)
        XCTAssertTrue(set.removeAll().isEmpty)
    }
}
