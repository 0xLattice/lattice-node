import Foundation
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
import cashew
@testable import LatticeBlockTree
@testable import LatticeNode

/// A hosted child level across a restart: a child genesis weighed by its
/// proof but not yet executed (its body never fetched) restores from the
/// header store, and boot keeps every root the child journal names.
final class ChildLevelRestartTests: XCTestCase {
    private let alpha = ["Nexus", "Alpha"]

    private func configuration(hosting hosted: [ChainPath]? = nil) throws -> NodeConfiguration {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-child-restart-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        return try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "3a", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(), rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: hosted ?? [alpha]
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
    /// replaying the whole journal at once restores. Two hosted children, a
    /// hosted grandchild under a hosted child, stream cursors, and a
    /// journaled grandchild whose middle level is not hosted: configuration
    /// cannot host it, and the restore never asks for its rows even when
    /// told it is hosted.
    func testAPerLevelBootRestoresWhatTheWholeJournalDoes() async throws {
        let beta = ["Nexus", "Beta"]
        let leaf = ["Nexus", "Alpha", "Leaf"]
        let orphan = ["Nexus", "Gamma", "Delta"]
        let configuration = try configuration(hosting: [alpha, beta, leaf])
        let geneses = try await weighChildGeneses(["Alpha", "Beta"], configuration)
        let store = try await NodeStorage.open(configuration: configuration).store
        let storedLogID = try await store.chainLogID()
        let logID = try XCTUnwrap(storedLogID)
        try await store.stageNodeFacts([
            NodeFactBatch(
                path: ["Nexus"], facts: [], volumeRoots: [],
                cursors: ["peer-a": StreamCursor(logID: "remote", position: 3)]
            ),
            NodeFactBatch(
                path: alpha, facts: [], volumeRoots: [],
                cursors: ["peer-a": StreamCursor(logID: "remote", position: 1), "peer-b": StreamCursor(logID: "", position: 0)]
            ),
            NodeFactBatch(
                path: orphan,
                facts: [BlockImportBatch(facts: [.block(ChainBlockFact(
                    blockHash: "orphan-genesis", parentBlockHash: nil, blockHeight: 0, postStateCID: "state",
                    prevStateCID: "previous-state", specCID: "spec", target: "target", nextTarget: "next-target",
                    timestamp: 0, stateDiff: .empty
                ))])],
                volumeRoots: [], cursors: [:]
            ),
        ], logID: logID)

        let reopened = try await NodeStorage.open(configuration: configuration)
        let restored = try await NodeRuntime.boot(
            storage: reopened, configuration: configuration, coreConfig: .init()
        )

        let journal = Dictionary(grouping: try await reopened.store.stagedImports(), by: \.chainPath)
            .mapValues { $0.map(\.batch) }
        XCTAssertNotNil(journal[orphan], "fixture guard: the unrestored level's rows are journaled")
        var specs: [ChainPath: [ChainSpec]] = [:]
        for path in [alpha, beta] {
            for case .block(let block) in (journal[path] ?? []).flatMap(\.facts) where block.parentBlockHash == nil {
                let spec = try await reopened.chainGenesisSpec(block.blockHash)
                specs[path, default: []].append(try XCTUnwrap(spec))
            }
        }
        var cursors: [ChainPath: [String: StreamCursor]] = [:]
        for path in [["Nexus"], alpha, beta, leaf, orphan] {
            cursors[path] = try await reopened.chainCursors(at: path)
        }
        XCTAssertEqual(cursors[alpha]?.count, 2, "fixture guard: cursors are journaled")
        let whole = try NodeCore.restore(
            root: try ChainCore.restore(
                replaying: journal[["Nexus"]] ?? [], context: try configuration.runtimeContext,
                specs: [NexusGenesis.spec], cursors: cursors[["Nexus"]] ?? [:]
            ),
            facts: journal, specs: specs, hosted: [alpha, beta, leaf],
            logID: logID, cursors: cursors
        )

        // The level-at-a-time restore asks for each restored level once,
        // parent before child, and never for a level whose parent it does
        // not run.
        var asked: [ChainPath] = []
        let skipping = try await NodeCore.restore(
            root: try ChainCore.restore(
                replaying: journal[["Nexus"]] ?? [], context: try configuration.runtimeContext,
                specs: [NexusGenesis.spec]
            ),
            hosted: [alpha, beta, leaf, orphan]
        ) { path in
            asked.append(path)
            return (journal[path] ?? [], specs[path] ?? [])
        }
        XCTAssertEqual(asked, [alpha, beta, leaf])
        XCTAssertNil(skipping.levels[orphan])

        XCTAssertEqual(Set(restored.levels.keys), [["Nexus"], alpha, beta, leaf])
        XCTAssertEqual(Set(restored.levels.keys), Set(whole.levels.keys))
        XCTAssertTrue(restored.levels[alpha]?.tree.contains(blockHash: geneses[0]) ?? false)
        XCTAssertTrue(restored.levels[beta]?.tree.contains(blockHash: geneses[1]) ?? false)
        XCTAssertEqual(restored.levels[alpha]?.sync.cursors.count, 2)
        for (path, level) in whole.levels {
            let mine = try XCTUnwrap(restored.levels[path], "level \(path)")
            XCTAssertEqual(mine.snapshot, level.snapshot, "snapshot \(path)")
            XCTAssertEqual(mine.sync.log.id, level.sync.log.id, "log id \(path)")
            XCTAssertEqual(mine.sync.log.entries, level.sync.log.entries, "log entries \(path)")
            XCTAssertEqual(mine.sync.cursors, level.sync.cursors, "cursors \(path)")
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
        try await weighChildGeneses(["Alpha"], configuration)[0]
    }

    /// One Nexus block carrying a genesis for each of `names` (Nexus
    /// children), weighed by its proof and persisted as the runtime persists
    /// it. The genesis CIDs, in `names` order.
    private func weighChildGeneses(_ names: [String], _ configuration: NodeConfiguration) async throws -> [String] {
        let storage = try await NodeStorage.open(configuration: configuration)
        var host = try await NodeRuntime.boot(
            storage: storage, configuration: configuration, coreConfig: .init()
        )

        // A Nexus block carrying each child's genesis, which commits the
        // carrier's entering state.
        // The storage holds the Nexus genesis content since its first boot.
        let content = storage
        let storer = NodeImportStorage(storage: await storage.broker)
        let nexusGenesis = try await NexusGenesis.create(fetcher: content).block
        var geneses: [String: Block] = [:]
        for (index, name) in names.enumerated() {
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 100_000, premine: UInt64(index),
                targetBlockTime: 1_000, initialReward: 1, halvingInterval: 10_000, halfLife: 10
            )
            geneses[name] = try await BlockBuilder.buildChildGenesis(
                spec: spec, parentState: nexusGenesis.postState,
                timestamp: nexusGenesis.timestamp + 1, target: .max, fetcher: content
            )
        }
        var carrier = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: geneses,
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
        let rootResolved = try await carrier.children.resolve(fetcher: content).node
        let rootChildren = try XCTUnwrap(rootResolved)
        var carried: [MinedGrind.Carried] = []
        for name in names {
            let childGenesis = try XCTUnwrap(geneses[name])
            let path = ["Nexus", name]
            let proof = try await ChildBlockProof.generate(
                rootHeader: BlockHeader(node: carrier), childDirectory: name, fetcher: content
            )
            let evidence = try await proof.verifySecuringWork(child: childGenesis, chainPath: path).get()
            let childResolved = try await childGenesis.children.resolve(fetcher: content).node
            carried.append(.init(
                path: path, block: childGenesis, children: try XCTUnwrap(childResolved),
                proof: proof, evidence: evidence
            ))
        }

        // One grind, persisted as the runtime persists it.
        let effects = host.step(
            .mined(MinedGrind(root: carrier, rootChildren: rootChildren, carried: carried)),
            now: carrier.timestamp + 1
        )
        for case .persist(let batch) in effects {
            try await storage.persistNodeBatch(batch, logID: host.logID)
        }
        return try names.map { name in
            let genesisCID = try BlockHeader(node: XCTUnwrap(geneses[name])).rawCID
            XCTAssertTrue(host.levels[["Nexus", name]]?.tree.contains(blockHash: genesisCID) ?? false)
            XCTAssertFalse(host.levels[["Nexus", name]]?.tree.isExecuted(blockHash: genesisCID) ?? true)
            return genesisCID
        }
    }
}
