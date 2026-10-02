import Foundation
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// A hosted child level across a restart: a child genesis weighed by its
/// proof but not yet executed (its body never fetched) restores from the
/// header store, and boot keeps every root the child journal names.
final class ChildLevelRestartTests: XCTestCase {
    private let alpha = ["Nexus", "Alpha"]

    private func configuration() throws -> NodeConfiguration {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-restart-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        return try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storage,
            privateKeyHex: String(repeating: "3a", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(), rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [alpha]
        )
    }

    func testAWeighedUnexecutedChildGenesisSurvivesARestart() async throws {
        let configuration = try configuration()
        let genesisCID = try await weighChildGenesis(configuration)
        let stores = try CoreDriver.levelStores(configuration)

        // Restart: boot reconciles the retained roots, then a sweep.
        let reopened = try await ChainProcess.open(configuration: configuration)
        _ = try await reopened.broker.sweep()
        let restored = try await CoreDriver.boot(
            process: reopened, configuration: configuration, coreConfig: .init(),
            headers: try CoreHeaderStore(directory: configuration.storagePath)
        )
        XCTAssertTrue(restored.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? false)
        XCTAssertFalse(restored.levels[alpha]?.tree.isExecuted(blockHash: genesisCID) ?? true)
        let childRoots = try await stores[alpha]!.stagedImports().flatMap(\.volumeRoots)
        XCTAssertFalse(childRoots.isEmpty)
        for root in childRoots {
            let volume = await reopened.volume(root)
            XCTAssertNotNil(volume, "child root \(root) was swept")
        }
    }

    /// A first run: Alpha's genesis weighed by a mined Nexus block that
    /// carries it, persisted as the driver persists, never executed. The
    /// process closes (its storage lock released) on return.
    /// A crash between level writes: the parent's facts are durable, the
    /// child's never written. Restore keeps the parent's block, the child
    /// level comes back without the genesis, and nothing fails.
    func testACrashBetweenLevelWritesRestoresTheParentAhead() async throws {
        let configuration = try configuration()
        let genesisCID = try await weighChildGenesis(configuration, writing: [["Nexus"]])
        let reopened = try await ChainProcess.open(configuration: configuration)
        let restored = try await CoreDriver.boot(
            process: reopened, configuration: configuration, coreConfig: .init(),
            headers: try CoreHeaderStore(directory: configuration.storagePath)
        )
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.actOnHeight, 0)
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.bestHeaderHeight, 1, "the parent's write is durable")
        XCTAssertFalse(restored.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? true, "the child's never was")
    }

    private func weighChildGenesis(
        _ configuration: NodeConfiguration, writing written: Set<[String]>? = nil
    ) async throws -> String {
        let process = try await ChainProcess.open(configuration: configuration)
        let headers = try CoreHeaderStore(directory: configuration.storagePath)
        var host = try await CoreDriver.boot(
            process: process, configuration: configuration, coreConfig: .init(), headers: headers
        )

        // A Nexus block carrying Alpha's genesis, which commits the carrier's
        // entering state.
        // The process holds the Nexus genesis content since its first boot.
        let content = process
        let storer = NodeImportStorage(storage: await process.broker)
        let nexusGenesis = try await NexusGenesis.create(fetcher: content).block
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 1_000, initialReward: 1, halvingInterval: 10_000, halfLife: 10
        )
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: spec, parentState: nexusGenesis.postState,
            timestamp: nexusGenesis.timestamp + 1, target: .max, fetcher: content
        )
        var carrier = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Alpha": childGenesis],
            timestamp: nexusGenesis.timestamp + 1_000, fetcher: content
        )
        var nonce: UInt64 = 0
        while ChainTree.rootWork(of: carrier) == nil {
            nonce += 1
            carrier = Block(
                version: carrier.version, parent: carrier.parent, transactions: carrier.transactions,
                target: carrier.target, nextTarget: carrier.nextTarget, spec: carrier.spec,
                parentState: carrier.parentState, prevState: carrier.prevState, postState: carrier.postState,
                children: carrier.children, height: carrier.height, timestamp: carrier.timestamp,
                rewardRecipient: carrier.rewardRecipient, nonce: nonce
            )
        }
        try await BlockHeader(node: carrier).storeBlock(fetcher: content, storer: storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: carrier), childDirectory: "Alpha", fetcher: content
        )
        let evidence = try await proof.verifySecuringWork(child: childGenesis, chainPath: alpha).get()
        let rootResolved = try await carrier.children.resolve(fetcher: content).node
        let childResolved = try await childGenesis.children.resolve(fetcher: content).node
        let rootChildren = try XCTUnwrap(rootResolved)
        let childChildren = try XCTUnwrap(childResolved)

        // One grind, persisted as the driver persists it.
        let effects = host.step(.mined(MinedGrind(root: carrier, rootChildren: rootChildren, carried: [
            .init(path: alpha, block: childGenesis, children: childChildren, proof: proof, evidence: evidence),
        ])), now: carrier.timestamp + 1)
        let levels = try CoreDriver.levelStores(configuration)
        for case .persist(let batch) in effects {
            for (path, level) in batch.levels where written?.contains(path) ?? true {
                try await process.persistCoreBatch(level, logID: host.logID, headers: headers, into: levels[path])
            }
        }
        let genesisCID = try BlockHeader(node: childGenesis).rawCID
        XCTAssertTrue(host.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? false)
        XCTAssertFalse(host.levels[alpha]?.tree.isExecuted(blockHash: genesisCID) ?? true)
        return genesisCID
    }
}
