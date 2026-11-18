import Foundation
import XCTest
@testable import LatticeNode

/// A read on a connection sees every commit made before it began, even
/// while another thread's read on that connection is still stepping.
final class NodeSQLiteReadTests: XCTestCase {
    func testAReadSeesACommitMadeWhileAnotherReadWasOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("node-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.db").path
        let writer = try NodeSQLite(path: path)
        try writer.configureDurability()
        try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        try writer.execute("INSERT INTO t (id) VALUES (1)")
        let reads = try NodeSQLite(path: path, create: false)

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let open = Thread {
            try? reads.forEach("SELECT id FROM t") { _ in
                started.signal()
                release.wait()
            }
        }
        open.start()
        started.wait()
        try writer.execute("INSERT INTO t (id) VALUES (2)")

        let counted = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var count: Int64?
        Thread {
            count = try? reads.query("SELECT count(*) AS n FROM t").first?["n"]?.intValue
            counted.signal()
        }.start()
        // While the first read is open, the second waits for it, then reads
        // the commit; begun beside it, it would have joined its snapshot.
        let early = counted.wait(timeout: .now() + .milliseconds(200)) == .success
        release.signal()
        if !early { counted.wait() }
        XCTAssertEqual(count, 2)
    }
}
