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

    func testAPathStorageHoldsTakesNoSpec() async throws {
        let layout = try root()
        let storage = layout.chainDirectory(for: ChainAddress.nexus)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let store = try NodeStore(databasePath: NodeStore.databasePath(storage: storage), nexusGenesisCID: "genesis")
        try await store.persistAcceptedBlockRows(
            [AcceptedBlockRecord(blockCID: "block-a", parentCID: nil)], at: "Nexus/A", admissionSequence: 1, status: .header
        )
        XCTAssertTrue(try NodeStore.holdsBlocks(of: "Nexus/A", storage: storage))
        XCTAssertFalse(try NodeStore.holdsBlocks(of: "Nexus/B", storage: storage))
        XCTAssertThrowsError(try ChainCreation.create(HostedChain(path: "Nexus/A", spec: spec), layout: layout)) {
            XCTAssertTrue($0 is ChainCreation.Synced, "\($0)")
        }
        XCTAssertTrue(try ChainCreation.create(HostedChain(path: "Nexus/B", spec: spec), layout: layout))
    }

    /// A store that cannot be read refuses the creation: it might hold the
    /// chain.
    func testAnUnreadableStoreRefusesTheCreation() throws {
        let layout = try root()
        let storage = layout.chainDirectory(for: ChainAddress.nexus)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: NodeStore.databasePath(storage: storage))
        XCTAssertThrowsError(try ChainCreation.create(HostedChain(path: "Nexus/A", spec: spec), layout: layout))
        XCTAssertFalse(ChainCreation.isCreated("Nexus/A", layout: layout))
    }
}
