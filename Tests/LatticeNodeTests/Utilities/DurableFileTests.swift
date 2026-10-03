import Foundation
import XCTest
import LatticeCtlCore

/// The pending-deploy file is the only copy of a child genesis seed whose CID
/// may already be anchored. Two deploys of the same child racing each other
/// must never replace or delete the other's copy.
final class DurableFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-file-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Both racers saw no pending file; the second to write must not replace
    /// the first's seed.
    func testCreateNeverReplacesAnExistingFile() throws {
        let url = directory.appendingPathComponent("pending/Nexus-Market.json")
        let first = Data("seed A".utf8)
        let second = Data("seed B".utf8)

        XCTAssertTrue(try createDurably(first, at: url))
        XCTAssertFalse(try createDurably(second, at: url))
        XCTAssertEqual(try Data(contentsOf: url), first)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        XCTAssertEqual(leftovers, ["Nexus-Market.json"])
    }

    /// A refused racer cleans up only its own seed, never the survivor's.
    func testRemoveLeavesAFileSomeoneElseWrote() throws {
        let url = directory.appendingPathComponent("pending/Nexus-Market.json")
        let mine = Data("seed A".utf8)
        let theirs = Data("seed B".utf8)
        try writeDurably(theirs, to: url)

        removeIfUnchanged(url, expected: mine)
        XCTAssertEqual(try Data(contentsOf: url), theirs)

        removeIfUnchanged(url, expected: theirs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
