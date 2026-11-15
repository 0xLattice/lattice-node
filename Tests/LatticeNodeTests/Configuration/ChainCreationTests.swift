import Foundation
import Lattice
@testable import LatticeNode
import LatticeNodeAPI
import XCTest

/// A chain is created once, and never over one this node already follows
/// without a spec: the guard holds for a stopped node's files too.
final class ChainCreationTests: XCTestCase {
    private let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func root() throws -> HostLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"listen":4001,"rpc":4003,"peers":[]}"#.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        return HostLayout(root: root.path)
    }

    func testAPathALayerListsTakesNoSpec() throws {
        let layout = try root()
        try FileManager.default.createDirectory(at: ConfigFragments.directory(root: layout.root), withIntermediateDirectories: true)
        // Listed but not hosted: its parent waits.
        try Data(#"{"hostedChains":["Nexus/A/B"]}"#.utf8).write(to: ConfigFragments.file(root: layout.root, name: "operator"))
        XCTAssertThrowsError(try ChainCreation.create(HostedChain(path: "Nexus/A/B", spec: spec), layout: layout)) {
            XCTAssertTrue($0 is ChainCreation.Synced, "\($0)")
        }
        XCTAssertFalse(ChainCreation.isCreated("Nexus/A/B", layout: layout))
        XCTAssertTrue(try ChainCreation.create(HostedChain(path: "Nexus/C", spec: spec), layout: layout))
    }

    func testAPathStorageHoldsTakesNoSpec() throws {
        let layout = try root()
        let directory = layout.chainDirectory(for: ChainAddress.nexus)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try NodeSQLite(path: directory.appendingPathComponent("state.db").path)
        try database.execute("CREATE TABLE accepted_blocks (chain_path TEXT NOT NULL)")
        try database.execute("INSERT INTO accepted_blocks (chain_path) VALUES ('Nexus/A')")
        XCTAssertThrowsError(try ChainCreation.create(HostedChain(path: "Nexus/A", spec: spec), layout: layout)) {
            XCTAssertTrue($0 is ChainCreation.Synced, "\($0)")
        }
        XCTAssertTrue(try ChainCreation.create(HostedChain(path: "Nexus/B", spec: spec), layout: layout))
    }
}
