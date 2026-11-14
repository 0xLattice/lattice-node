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

    /// A private file replaces a readable one and is never readable by
    /// others: staged 0600 from its creation, no staging copy left.
    func testAPrivateWriteReplacesAndStaysOwnerOnly() throws {
        let file = directory.appendingPathComponent("tokens.json")
        try writeDurably(Data("old".utf8), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try writePrivateDurably(Data("new".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0o777) & 0o077, 0, "readable by others")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["tokens.json"])
    }
}
