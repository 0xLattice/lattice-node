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
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-restart-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        return try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "3a", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(), rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [alpha]
        )
    }

    func testAWeighedUnexecutedChildGenesisSurvivesARestart() async throws {
        let configuration = try configuration()
        let genesisCID = try await weighChildGenesis(configuration)

        // Restart: boot reconciles the retained roots, then a sweep.
        let reopened = try await NodeStorage.open(configuration: configuration)
        _ = try await reopened.broker.sweep()
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: configuration, coreConfig: .init()
        )
        XCTAssertTrue(restored.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? false)
        XCTAssertFalse(restored.levels[alpha]?.tree.isExecuted(blockHash: genesisCID) ?? true)
        let childRoots = try await reopened.store.stagedImports(at: alpha)
            .flatMap(\.volumeRoots)
        XCTAssertFalse(childRoots.isEmpty)
        for root in childRoots {
            let volume = await reopened.volume(root)
            XCTAssertNotNil(volume, "child root \(root) was swept")
        }
    }

    /// One grind is one transaction across every level it touches.
    func testParentAndChildFactsRestoreTogether() async throws {
        let configuration = try configuration()
        let genesisCID = try await weighChildGenesis(configuration)
        let reopened = try await NodeStorage.open(configuration: configuration)
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: configuration, coreConfig: .init()
        )
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.actOnHeight, 0)
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.bestHeaderHeight, 1)
        XCTAssertTrue(restored.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? false)
    }

    /// Boot reads a level's journal only when it hosts that level: Alpha's
    /// rows stay in state.db, and a start that no longer hosts Alpha
    /// restores Nexus alone, exactly as it was.
    func testABootThatNoLongerHostsAChildDoesNotRestoreIt() async throws {
        let configuration = try configuration()
        _ = try await weighChildGenesis(configuration)
        let unhosted = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: configuration.storagePath,
            privateKeyHex: String(repeating: "3a", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(), rpcPort: NetworkTransportTestPorts.allocate()
        )
        let reopened = try await NodeStorage.open(configuration: unhosted)
        let alphaRows = try await reopened.store.stagedImports(at: alpha)
        XCTAssertFalse(alphaRows.isEmpty, "fixture guard: Alpha's journal must still be present")
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: unhosted, coreConfig: .init()
        )
        XCTAssertEqual(Set(restored.levels.keys), [["Nexus"]])
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.bestHeaderHeight, 1)
    }

    /// Boot reads one level's journal at a time; what it restores is what
    /// replaying the whole journal at once restores.
    func testAPerLevelBootRestoresWhatTheWholeJournalDoes() async throws {
        let configuration = try configuration()
        _ = try await weighChildGenesis(configuration)
        let reopened = try await NodeStorage.open(configuration: configuration)
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: configuration, coreConfig: .init()
        )

        let journal = Dictionary(grouping: try await reopened.store.stagedImports(), by: \.chainPath)
            .mapValues { $0.map(\.batch) }
        var specs: [ChainPath: [ChainSpec]] = [:]
        for case .block(let block) in (journal[alpha] ?? []).flatMap(\.facts) where block.parentBlockHash == nil {
            let spec = try await reopened.chainGenesisSpec(block.blockHash)
            specs[alpha, default: []].append(try XCTUnwrap(spec))
        }
        let cursors = [
            ["Nexus"]: try await reopened.chainCursors(at: ["Nexus"]),
            alpha: try await reopened.chainCursors(at: alpha),
        ]
        let whole = try NodeCore.restore(
            root: try ChainCore.restore(
                replaying: journal[["Nexus"]] ?? [], context: try configuration.runtimeContext,
                specs: [NexusGenesis.spec], cursors: cursors[["Nexus"]] ?? [:]
            ),
            facts: journal, specs: specs, hosted: [alpha],
            logID: try await reopened.chainLogID() ?? "", cursors: cursors
        )
        XCTAssertEqual(Set(restored.levels.keys), Set(whole.levels.keys))
        for (path, level) in whole.levels {
            XCTAssertEqual(restored.levels[path]?.snapshot, level.snapshot, "level \(path)")
            XCTAssertEqual(
                restored.levels[path]?.sync.log.entries.count, level.sync.log.entries.count, "log \(path)"
            )
        }
    }

    /// A credited proof commits with the work fact it produced.
    func testACreditedChildProofIsSavedWithItsWorkFact() async throws {
        let configuration = try configuration()
        let genesisCID = try await weighChildGenesis(configuration)
        let reopened = try await NodeStorage.open(configuration: configuration)
        let work = try await reopened.store.stagedImports(at: alpha).flatMap(\.batch.facts)
            .compactMap { fact -> String? in
                guard case .work(let work) = fact, work.blockHash == genesisCID else { return nil }
                return work.contribution.id
            }
        XCTAssertFalse(work.isEmpty)
        let proofs = try await reopened.store.savedProofs()[alpha]?[genesisCID] ?? [:]
        XCTAssertEqual(Set(proofs.keys), Set(work))
    }

    /// A kill between a write and the fact that names it. Pins are in the
    /// store and a start leaves them as it finds them, so what decides is
    /// the name content was pinned under: content no scope names goes, and
    /// what the chain scope names stays (a block that is executed again
    /// stores the same).
    func testAStartKeepsWhatAScopeNamesAndDropsTheRest() async throws {
        let configuration = try configuration()
        func spec(_ premine: UInt64) throws -> VolumeImpl<ChainSpec> {
            try VolumeImpl<ChainSpec>(node: ChainSpec(
                maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 100_000, premine: premine,
                targetBlockTime: 1_000, initialReward: 1, halvingInterval: 10_000, halfLife: 10
            ))
        }
        let (unpinned, chained) = (try spec(7), try spec(9))
        do {
            let storage = try await NodeStorage.open(configuration: configuration)
            let storer = NodeImportStorage(storage: await storage.broker)
            for volume in [unpinned, chained] { try await volume.store(storer: storer) }
            try await storer.commit()
            try await storage.broker.mergeRetainedRoots(scope: storage.scopes.chain, roots: [chained.rawCID])
        }

        let reopened = try await NodeStorage.open(configuration: configuration)
        let sweptUnpinned = await reopened.volume(unpinned.rawCID)
        XCTAssertNil(sweptUnpinned, "no scope named it")
        let kept = await reopened.volume(chained.rawCID)
        XCTAssertNotNil(kept, "the chain scope named it, and a start leaves pins as it finds them")
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: configuration, coreConfig: .init()
        )
        XCTAssertEqual(restored.levels[["Nexus"]]?.snapshot.actOnHeight, 0)
    }

    private func weighChildGenesis(_ configuration: NodeConfiguration) async throws -> String {
        let storage = try await NodeStorage.open(configuration: configuration)
        var host = try await NodeRuntime.boot(
            storage: storage, configuration: configuration, coreConfig: .init()
        )

        // A Nexus block carrying Alpha's genesis, which commits the carrier's
        // entering state.
        // The storage holds the Nexus genesis content since its first boot.
        let content = storage
        let storer = NodeImportStorage(storage: await storage.broker)
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
        try await storer.commit()
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: carrier), childDirectory: "Alpha", fetcher: content
        )
        let evidence = try await proof.verifySecuringWork(child: childGenesis, chainPath: alpha).get()
        let rootResolved = try await carrier.children.resolve(fetcher: content).node
        let childResolved = try await childGenesis.children.resolve(fetcher: content).node
        let rootChildren = try XCTUnwrap(rootResolved)
        let childChildren = try XCTUnwrap(childResolved)

        // One grind, persisted as the runtime persists it.
        let effects = host.step(.mined(MinedGrind(root: carrier, rootChildren: rootChildren, carried: [
            .init(path: alpha, block: childGenesis, children: childChildren, proof: proof, evidence: evidence),
        ])), now: carrier.timestamp + 1)
        for case .persist(let batch) in effects {
            try await storage.persistNodeBatch(batch, logID: host.logID)
        }
        let genesisCID = try BlockHeader(node: childGenesis).rawCID
        XCTAssertTrue(host.levels[alpha]?.tree.contains(blockHash: genesisCID) ?? false)
        XCTAssertFalse(host.levels[alpha]?.tree.isExecuted(blockHash: genesisCID) ?? true)
        return genesisCID
    }
}
