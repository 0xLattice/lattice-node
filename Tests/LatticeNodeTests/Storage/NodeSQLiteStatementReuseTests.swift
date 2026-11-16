import Foundation
import XCTest
@testable import LatticeNode

/// `NodeSQLite` reuses one prepared statement per SQL text. A statement is
/// never shared while in use, and is reset when a call is done with it.
final class NodeSQLiteStatementReuseTests: XCTestCase {
    private func database() throws -> (NodeSQLite, String) {
        let path = temporaryDirectory(create: true).appendingPathComponent("test.db").path
        let database = try NodeSQLite(path: path)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)")
        for k in 1...3 {
            try database.execute("INSERT INTO t (k, v) VALUES (?1, ?2)", params: [.int(Int64(k)), .text("v\(k)")])
        }
        return (database, path)
    }

    /// A `forEach` body that runs the same SQL gets its own statement; the
    /// outer iteration is not disturbed.
    func testTheSameSQLRunsInsideAForEachOverIt() throws {
        let (database, _) = try database()
        let sql = "SELECT k FROM t WHERE k >= ?1 ORDER BY k"
        var pairs: [[Int64]] = []
        try database.forEach(sql, params: [.int(1)]) { outer in
            let k = outer.int(0)!
            var inner: [Int64] = []
            try database.forEach(sql, params: [.int(k)]) { inner.append($0.int(0)!) }
            pairs.append(inner)
        }
        XCTAssertEqual(pairs, [[1, 2, 3], [2, 3], [3]])
        XCTAssertEqual(try database.query(sql, params: [.int(2)]).count, 2)
    }

    /// A statement that failed (a constraint) is reset and serves the next call.
    func testAStatementThatFailedServesTheNextCall() throws {
        let (database, _) = try database()
        let insert = "INSERT INTO t (k, v) VALUES (?1, ?2)"
        XCTAssertThrowsError(try database.execute(insert, params: [.int(1), .text("dup")]))
        XCTAssertEqual(try database.execute(insert, params: [.int(4), .text("v4")]), 1)
        XCTAssertEqual(try database.query("SELECT v FROM t WHERE k = ?1", params: [.int(4)]).first?["v"]?.textValue, "v4")
    }

    /// A finished read leaves no read transaction open: another connection
    /// can checkpoint the whole WAL.
    func testAFinishedReadHoldsNoSnapshot() throws {
        let (database, path) = try database()
        _ = try database.query("SELECT k FROM t ORDER BY k")
        try database.forEach("SELECT k FROM t ORDER BY k") { _ in }
        let other = try NodeSQLite(path: path)
        let result = try other.query("PRAGMA wal_checkpoint(TRUNCATE)").first
        XCTAssertEqual(result?["busy"]?.intValue, 0)
    }

    /// Calls from many threads on one connection each read their own rows.
    func testConcurrentCallsOnOneConnection() throws {
        let (database, _) = try database()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let k = Int64(index % 3 + 1)
            let rows = try? database.query("SELECT v FROM t WHERE k = ?1", params: [.int(k)])
            XCTAssertEqual(rows?.first?["v"]?.textValue, "v\(k)")
        }
    }
}
