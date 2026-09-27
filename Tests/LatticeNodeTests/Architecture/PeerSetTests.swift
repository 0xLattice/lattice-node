import Crypto
import Foundation
import Ivy
import XCTest
@testable import LatticeNode

final class PeerSetTests: XCTestCase {

    private struct Record: PeerRecord, Equatable {
        var a: Int?
        var b: String?
        var session: Data?
        var isEmpty: Bool { a == nil && b == nil && session == nil }
        var liveSessionID: Data? { session }
    }

    private func peer(_ k: PeerKey, session: UInt8) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: k,
            role: .endpoint,
            route: .direct,
            metadata: PeerMetadata(),
            sessionID: Data([session])
        )
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
        XCTAssertEqual(set[k], Record(a: 7, b: nil, session: nil))
        XCTAssertEqual(Set(set.keys), [k])
    }

    func testUpdateThatLeavesTheRecordEmptyPrunesIt() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        set.update(k) { $0.a = 1; $0.b = "x" }
        set.update(k) { $0.a = nil }
        XCTAssertEqual(set[k], Record(a: nil, b: "x", session: nil), "a partial clear keeps the key")
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
        XCTAssertEqual(set.remove(k1), Record(a: 1, b: nil, session: nil))
        XCTAssertNil(set.remove(k1), "a second remove finds nothing")
        XCTAssertNil(set[k1])
        XCTAssertEqual(set[k2], Record(a: nil, b: "two", session: nil))
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

    /// A write after a suspension names the session it was begun for: it
    /// lands only on the record still bound to that session, and never
    /// creates a record for a peer whose session ended meanwhile.
    func testSessionUpdateTouchesOnlyTheRecordOfThatSession() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        let first = peer(k, session: 1)
        let second = peer(k, session: 2)

        XCTAssertNil(
            set.update(session: first) { $0.a = 1 },
            "no record: nothing written"
        )
        XCTAssertNil(set[k], "a session write never creates the key")

        set.update(k) { $0.session = first.sessionID }
        XCTAssertEqual(set.update(session: first) { record -> Int in
            record.a = 1
            return 7
        }, 7)
        XCTAssertEqual(set[k]?.a, 1)

        // The peer reconnects: the record now belongs to the new session.
        set.update(k) { $0.session = second.sessionID }
        XCTAssertNil(
            set.update(session: first) { $0.a = 99 },
            "the ended session's late write is dropped"
        )
        XCTAssertEqual(set[k]?.a, 1)

        // The peer disconnects: the key is gone and stays gone.
        set.remove(k)
        XCTAssertNil(set.update(session: second) { $0.b = "late" })
        XCTAssertTrue(set.records.isEmpty)
    }

    func testSessionUpdateThatEmptiesTheRecordPrunesIt() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        let live = peer(k, session: 1)
        set.update(k) { $0.session = live.sessionID; $0.a = 1 }
        set.update(session: live) { $0.session = nil; $0.a = nil }
        XCTAssertNil(set[k])
    }

    func testUpdateExistingNeverCreatesARecord() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        XCTAssertNil(set.updateExisting(k) { $0.a = 1 })
        XCTAssertNil(set[k])

        set.update(k) { $0.b = "kept" }
        XCTAssertEqual(set.updateExisting(k) { record -> String? in
            record.a = 2
            return record.b
        }, "kept")
        XCTAssertEqual(set[k], Record(a: 2, b: "kept", session: nil))
        set.updateExisting(k) { $0.a = nil; $0.b = nil }
        XCTAssertNil(set[k], "an emptied record is pruned")
    }

    /// A session's end removes only the binding sampled for it: a record a
    /// newer session took meanwhile stays.
    func testRemoveIfBoundToLeavesANewerSessionsRecord() throws {
        var set = PeerSet<Record>()
        let k = try key(1)
        let first = Data([1])
        set.update(k) { $0.session = first; $0.a = 1 }
        set.update(k) { $0.session = Data([2]) }  // the reconnect
        XCTAssertNil(set.remove(k, ifBoundTo: first))
        XCTAssertEqual(set[k]?.session, Data([2]))
        XCTAssertEqual(set.remove(k, ifBoundTo: Data([2]))?.a, 1)
        XCTAssertNil(set[k])
        XCTAssertNil(set.remove(k, ifBoundTo: nil), "no record: nothing removed")
        set.update(k) { $0.b = "unbound" }
        XCTAssertEqual(set.remove(k, ifBoundTo: nil)?.b, "unbound", "nil matches an unbound record")
    }
}
