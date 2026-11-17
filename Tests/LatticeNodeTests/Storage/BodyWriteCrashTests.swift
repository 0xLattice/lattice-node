import Foundation
import Lattice
@testable import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// A valid block's body is written by the step that applies its connect's
/// verdict, in the one volumes.db transaction that writes its post-state,
/// before its facts. A crash at any point leaves content without facts or
/// nothing, never facts without content, and the block executes again.
/// The body is only in memory before that step, as a fetch from peers
/// leaves it.
final class BodyWriteCrashTests: XCTestCase {
    private static let nexus: ChainPath = ["Nexus"]

    private func configuration(state: StateRetention) throws -> NodeConfiguration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-body-crash-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try NodeConfiguration(
            chainPath: Self.nexus,
            storagePath: directory,
            privateKeyHex: String(repeating: "5c", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            state: state
        )
    }

    /// The next block on genesis, carrying one transaction, and its body's
    /// Volumes as a fetch derives them. Nothing of it is stored.
    private struct Next {
        let block: Block
        let cid: String
        let transaction: String
        let body: [SerializedVolume]
    }

    private func next(on storage: NodeStorage) async throws -> Next {
        let genesisCID = NexusGenesis.expectedBlockHash
        let genesisData = await storage.content([genesisCID])[genesisCID]
        let genesis = try XCTUnwrap(Block(data: try XCTUnwrap(genesisData)))
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: Self.nexus
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
        let timestamp = TestBlockClock().next()
        var nonce: UInt64 = 0
        var block: Block
        repeat {
            block = try await BlockBuilder.buildBlockWithTransition(
                previous: genesis, transactions: [transaction], timestamp: timestamp, nonce: nonce, fetcher: storage
            ).block
            nonce += 1
        } while block.proofOfWorkHash() > block.target
        let header = try BlockHeader(node: block)
        let walked = NodeImportStorage(storage: nil, keepsVolumes: true)
        try await header.storeBlock(fetcher: storage, storer: walked)
        return Next(
            block: block, cid: header.rawCID, transaction: try Mempool.cid(of: transaction),
            body: await walked.takeVolumes().map(\.volume)
        )
    }

    /// Steps `event` as the runtime does: each batch persisted, a body fetch
    /// answered at once (the body is in memory), each connect job run,
    /// reading what this store lacks from memory and then from peers that
    /// hold nothing. Returns the connect jobs' verdicts, not yet stepped.
    private func step(_ host: inout NodeCore, _ event: NodeEvent, storage: NodeStorage) async throws -> [NodeEvent] {
        var pending = [event]
        var verdicts: [NodeEvent] = []
        while !pending.isEmpty {
            let effects = host.step(pending.removeFirst(), now: NodeRuntime.now())
            for case .persist(let batch) in effects {
                try await storage.persistNodeBatch(batch, logID: host.logID)
            }
            for effect in effects {
                switch effect {
                case .connect(let path, let job):
                    let levels = host.levels
                    verdicts += await NodeRuntime.connectJob(
                        job, at: path, levels: LiveLevels { $0(levels) }, storage: storage,
                        remote: IvyRootContentSource(fetch: { _ in .empty }, fetchBundle: { _ in [] })
                    ).run()
                case .level(let path, .fetchBody(let cid)):
                    pending.append(.level(path, .bodyFetched(cid: cid)))
                default:
                    break
                }
            }
        }
        return verdicts
    }

    /// Weighs the next block on a fresh store with its body only in memory,
    /// and runs its connect job. Returns the block and the job's verdict,
    /// unstepped, with the host it would step on: nothing is written yet.
    private func connected(
        _ configuration: NodeConfiguration
    ) async throws -> (next: Next, storage: NodeStorage, host: NodeCore, verdict: NodeEvent) {
        let storage = try await NodeStorage.open(configuration: configuration)
        var host = try await NodeRuntime.boot(storage: storage, configuration: configuration, coreConfig: .init())
        let next = try await next(on: storage)
        await storage.readCache.put(next.body, block: next.cid)
        let children = try XCTUnwrap(next.block.children.node)
        let verdicts = try await step(
            &host, .mined(MinedGrind(root: next.block, rootChildren: children, carried: [])), storage: storage
        )
        let verdict = try XCTUnwrap(verdicts.first)
        guard case .level(_, .connected(let decided, _, let body)) = verdict else {
            throw CocoaError(.featureUnsupported)
        }
        XCTAssertNil(decided.retryFailure)
        XCTAssertNotNil(body, "a valid block's job hands its body to the step")
        return (next, storage, host, verdict)
    }

    /// What a restart finds: the block weighed and not executed, and
    /// whether its body and post-state are held and pinned.
    private func assertUnexecuted(
        _ next: Next, _ configuration: NodeConfiguration, contentHeld: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let storage = try await NodeStorage.open(configuration: configuration)
        _ = try await storage.broker.sweep()
        let executed = try await storage.store.hasExecutedBlock(next.cid, at: Self.nexus)
        XCTAssertFalse(executed, "no validation fact", file: file, line: line)
        let pinned = try await Set(storage.broker.retainedRoots(scope: storage.scopes.body(next.cid)))
        XCTAssertEqual(pinned, contentHeld ? [next.cid, next.transaction] : [], file: file, line: line)
        for root in [next.cid, next.transaction, next.block.postState.rawCID] {
            let held = await storage.volume(root) != nil
            XCTAssertEqual(held, contentHeld, root, file: file, line: line)
        }
        let host = try await NodeRuntime.boot(storage: storage, configuration: configuration, coreConfig: .init())
        let level = try XCTUnwrap(host.levels[Self.nexus])
        XCTAssertTrue(level.tree.contains(blockHash: next.cid), "its header is durable", file: file, line: line)
        XCTAssertFalse(level.tree.isExecuted(blockHash: next.cid), file: file, line: line)
        XCTAssertEqual(level.snapshot.actOnTip, NexusGenesis.expectedBlockHash, file: file, line: line)
    }

    /// After a restart the block executes again from its body, fetched
    /// again (here, put in memory again), and is the act-on tip with its
    /// body and post-state held and pinned.
    private func assertRecovers(_ next: Next, _ configuration: NodeConfiguration) async throws {
        let storage = try await NodeStorage.open(configuration: configuration)
        var host = try await NodeRuntime.boot(storage: storage, configuration: configuration, coreConfig: .init())
        await storage.readCache.put(next.body, block: next.cid)
        for verdict in try await step(&host, .tick, storage: storage) {
            _ = try await step(&host, verdict, storage: storage)
        }
        XCTAssertEqual(host.levels[Self.nexus]?.snapshot.actOnTip, next.cid)
        let executed = try await storage.store.hasExecutedBlock(next.cid, at: Self.nexus)
        XCTAssertTrue(executed)
        let pinned = try await Set(storage.broker.retainedRoots(scope: storage.scopes.body(next.cid)))
        XCTAssertEqual(pinned, [next.cid, next.transaction])
        let state = await storage.volume(next.block.postState.rawCID)
        XCTAssertNotNil(state)
    }

    /// The job ran and the step never did: nothing of the block is written.
    func testACrashBeforeTheStepLeavesNothingOfTheBlock() async throws {
        for state in [StateRetention.all, .recent] {
            let configuration = try configuration(state: state)
            let next = try await connected(configuration).next
            try await assertUnexecuted(next, configuration, contentHeld: false)
            try await assertRecovers(next, configuration)
        }
    }

    /// The step's content write fails: neither body nor post-state nor any
    /// fact is written.
    func testAFailedContentWriteLeavesNothingOfTheBlock() async throws {
        let configuration = try configuration(state: .recent)
        let next = try await failingStep(configuration, locking: "volumes.db")
        try await assertUnexecuted(next, configuration, contentHeld: false)
        try await assertRecovers(next, configuration)
    }

    /// The content transaction commits and the facts transaction fails:
    /// the body and post-state are held and pinned, the block is not
    /// executed, and it executes again.
    func testAFailedFactsWriteLeavesContentWithoutFacts() async throws {
        for state in [StateRetention.all, .recent] {
            let configuration = try configuration(state: state)
            let next = try await failingStep(configuration, locking: "state.db")
            try await assertUnexecuted(next, configuration, contentHeld: true)
            try await assertRecovers(next, configuration)
        }
    }

    /// Steps the verdict while another connection holds `file`'s write
    /// lock, so that database's commit fails as a crash there would.
    private func failingStep(_ configuration: NodeConfiguration, locking file: String) async throws -> Next {
        var (next, storage, host, verdict) = try await connected(configuration)
        let lock = try NodeSQLite(path: configuration.storagePath.appendingPathComponent(file).path)
        try lock.execute("BEGIN EXCLUSIVE")
        do {
            _ = try await step(&host, verdict, storage: storage)
            XCTFail("the step's persist commits under a held \(file) lock")
        } catch {}
        try lock.execute("ROLLBACK")
        return next
    }
}
