import Foundation
import Ivy
import Lattice
@testable import LatticeNodeCore
import LatticeNodeAPI
import Synchronization
import XCTest
@testable import LatticeNode
import cashew

/// Executions are a cache over durable blocks, across a crash, over real
/// stores driven as the runtime drives them: what a step weighed is durable
/// at once, what its executions decided is held until a flush, and a start
/// executes again, through the one connect pipeline and from what this node
/// stores alone, whatever a crash lost (Bitcoin's `ReplayBlocks` role).
final class DerivedCacheRestartTests: XCTestCase {
    private static let alpha: ChainPath = ["Nexus", "Alpha"]

    /// A node's core and stores. Each persist is written as the runtime
    /// writes it, each body is read from the store, each connect runs at
    /// once; `held` is what the runtime would flush next.
    private struct Node {
        var host: NodeCore
        let storage: NodeStorage
        var held: [ChainPath: [BlockImportBatch]] = [:]
        /// Every effect the core emitted.
        var seen: [NodeEffect] = []
        var failStop: @Sendable (any Error) -> Void = { fatalError("node runtime: body not stored: \($0)") }

        mutating func step(_ event: NodeEvent, now: Int64 = NodeRuntime.now()) async throws {
            try await step([event], now: now)
        }

        /// `events` in order, each before what the ones ahead of it caused,
        /// as the runtime's inputs queue behind what a start yields at once.
        mutating func step(_ events: [NodeEvent], now: Int64 = NodeRuntime.now()) async throws {
            var pending = events
            while !pending.isEmpty {
                let effects = host.step(pending.removeFirst(), now: now)
                seen += effects
                for case .persist(let batch) in effects {
                    try await storage.persistNodeBatch(batch, logID: host.logID)
                    for level in batch.levels { held[level.path, default: []] += level.batch.executed }
                }
                for effect in effects {
                    switch effect {
                    case .connect(let path, let job):
                        let levels = host.levels
                        pending += await NodeRuntime.connectJob(
                            job, at: path, levels: LiveLevels { $0(levels) }, storage: storage, failStop: failStop
                        ).run()
                    case .level(let path, .fetchBody(let cid)):
                        pending.append(.level(path, .bodyFetched(cid: cid)))
                    default:
                        break
                    }
                }
            }
        }

        mutating func flush() async throws {
            try await storage.flush(held, logID: host.logID)
            held = [:]
        }

        /// The flush's first transaction alone: where a crash inside it lands.
        func flushContentOnly() async throws {
            let states = await storage.held
            try await storage.broker.storeVolumesLocal(states.volumes, retaining: states.retaining)
        }

        func tip(_ path: ChainPath = ["Nexus"]) -> String {
            host.levels[path]?.snapshot.actOnTip ?? ""
        }

        func block(_ cid: String) async throws -> Block {
            let data = await storage.content([cid])[cid]
            return try XCTUnwrap(Block(data: try XCTUnwrap(data)))
        }

        /// Mine a block on `previous` carrying `transactions`, store it and
        /// weigh it as this node's grind; its execution runs at once, after
        /// `stored`.
        mutating func mine(
            on previous: Block, timestamp: Int64, transactions: [Transaction] = [],
            stored: () throws -> Void = {}
        ) async throws -> Block {
            var nonce: UInt64 = 0
            var block: Block
            repeat {
                block = try await BlockBuilder.buildBlock(
                    previous: previous, transactions: transactions, timestamp: timestamp, nonce: nonce, fetcher: storage
                )
                nonce += 1
            } while block.proofOfWorkHash() > block.target
            let children = try await storage.storeMinedBlock(block)
            try stored()
            try await step(.mined(MinedGrind(root: block, rootChildren: children, carried: [])))
            return block
        }
    }

    private func configuration(hosting hosted: [ChainPath] = []) throws -> NodeConfiguration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-derived-cache-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: "5c", count: 32),
            hostedChildren: hosted
        )
    }

    private func open(_ configuration: NodeConfiguration) async throws -> Node {
        let storage = try await NodeStorage.open(configuration: configuration)
        return Node(
            host: try await NodeRuntime.boot(storage: storage, configuration: configuration, coreConfig: .init()),
            storage: storage
        )
    }

    /// A crash with executions held, inside the flush between its two
    /// transactions, and right after it: the start acts on the tip of the
    /// last flush and executes again what was lost, from the bodies this
    /// node stored, to the same tip, whose state its next flush stores.
    func testACrashAtEachPointRestartsToTheSameTipAndState() async throws {
        for point in ["held", "between the flush's transactions", "after the flush"] {
            let configuration = try configuration()
            let (flushed, tip, state): (String, String, String)
            do {
                var node = try await open(configuration)
                let clock = TestBlockClock()
                var block = try await node.block(node.tip())
                for _ in 0..<2 { block = try await node.mine(on: block, timestamp: clock.next()) }
                try await node.flush()
                flushed = node.tip()
                for _ in 0..<3 { block = try await node.mine(on: block, timestamp: clock.next()) }
                (tip, state) = (try BlockHeader(node: block).rawCID, block.postState.rawCID)
                XCTAssertEqual(node.tip(), tip, point)
                switch point {
                case "between the flush's transactions": try await node.flushContentOnly()
                case "after the flush": try await node.flush()
                default: break
                }
            }
            do {
                var node = try await open(configuration)
                XCTAssertEqual(node.tip(), point == "after the flush" ? tip : flushed, "\(point): the last flush's tip")
                try await node.step(.tick)
                XCTAssertEqual(node.tip(), tip, point)
                try await node.flush()
                let stored = await node.storage.broker.hasVolume(root: state)
                XCTAssertTrue(stored, "\(point): the tip's state is stored")
            }
            let reopened = try await open(configuration)
            XCTAssertEqual(reopened.tip(), tip, point)
        }
    }

    /// A stop flushes: the start is on the stopped tip before any step and
    /// has nothing to execute again.
    func testACleanRestartExecutesNothingAgain() async throws {
        let configuration = try configuration()
        let tip: String
        do {
            var node = try await open(configuration)
            let clock = TestBlockClock()
            var block = try await node.block(node.tip())
            for _ in 0..<3 { block = try await node.mine(on: block, timestamp: clock.next()) }
            try await node.flush()
            tip = node.tip()
        }
        var node = try await open(configuration)
        XCTAssertEqual(node.tip(), tip)
        let effects = node.host.step(.tick, now: NodeRuntime.now())
        XCTAssertFalse(effects.contains { if case .connect = $0 { true } else { false } }, "nothing executes again")
    }

    /// The act-on chain moved to a heavier branch whose executions were not
    /// flushed: the start acts on the flushed branch, the heavier one
    /// weighed, and executes it again.
    func testAReorgAcrossTheFlushBoundaryIsExecutedAgain() async throws {
        let configuration = try configuration()
        let (flushed, heavier): (String, String)
        do {
            var node = try await open(configuration)
            let clock = TestBlockClock()
            let genesis = try await node.block(node.tip())
            var a = genesis
            for _ in 0..<2 { a = try await node.mine(on: a, timestamp: clock.next()) }
            try await node.flush()
            flushed = node.tip()
            var b = genesis
            for _ in 0..<3 { b = try await node.mine(on: b, timestamp: clock.next()) }
            heavier = try BlockHeader(node: b).rawCID
            XCTAssertEqual(node.tip(), heavier)
        }
        var node = try await open(configuration)
        XCTAssertEqual(node.tip(), flushed, "the tip went back to the flushed branch")
        XCTAssertEqual(node.host.levels[["Nexus"]]?.snapshot.bestHeaderTip, heavier, "the heavier branch is weighed")
        try await node.step(.tick)
        XCTAssertEqual(node.tip(), heavier)
    }

    /// A child chain no other node hosts: its genesis, carried by a Nexus
    /// block this node mined, executes again after a crash from what this
    /// node stores alone.
    func testAChildChainOnlyThisNodeHostsExecutesAgainFromItsOwnStore() async throws {
        let configuration = try configuration(hosting: [Self.alpha])
        let (carrier, genesis): (String, String)
        do {
            var node = try await open(configuration)
            (carrier, genesis) = try await mineChildGenesis(&node)
            XCTAssertEqual(node.tip(), carrier)
            XCTAssertEqual(node.tip(Self.alpha), genesis, "the child genesis executed")
            XCTAssertFalse(node.held[Self.alpha, default: []].isEmpty)
        }
        var node = try await open(configuration)
        XCTAssertNotEqual(node.tip(Self.alpha), genesis, "its execution was lost")
        try await node.step(.tick)
        XCTAssertEqual(node.tip(), carrier)
        XCTAssertEqual(node.tip(Self.alpha), genesis)
    }

    /// A Nexus block on `previous` (the tip unless given) carrying a genesis
    /// of `alpha`, mined and stored here, weighed with the genesis it
    /// carries: their CIDs.
    private func mineChildGenesis(_ node: inout Node, on previous: Block? = nil) async throws -> (String, String) {
        let tip = try await node.block(node.tip())
        let nexusGenesis = previous ?? tip
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 100_000, premine: 0,
                targetBlockTime: 1_000, initialReward: 1, halvingInterval: 10_000, halfLife: 10
            ),
            parentState: nexusGenesis.postState, timestamp: nexusGenesis.timestamp + 1, target: .max,
            fetcher: node.storage
        )
        let carrier = try await mineCarrier(&node, on: nexusGenesis, carrying: childGenesis)
        return (carrier, try BlockHeader(node: childGenesis).rawCID)
    }

    /// A Nexus block on `previous` carrying `child` of `alpha`, mined and
    /// stored here, weighed with the block it carries: its CID.
    private func mineCarrier(_ node: inout Node, on previous: Block, carrying child: Block) async throws -> String {
        let content = node.storage
        var carrier = try await BlockBuilder.buildBlock(
            previous: previous, children: [Self.alpha[1]: child],
            timestamp: previous.timestamp + 1_000, fetcher: content
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
        let rootChildren = try await node.storage.storeMinedBlock(carrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: BlockHeader(node: carrier), childDirectory: Self.alpha[1], fetcher: content
        )
        let evidence = try proof.verifySecuringWork(child: child, chainPath: Self.alpha).get()
        let childResolved = try await child.children.resolve(fetcher: content).node
        let childChildren = try XCTUnwrap(childResolved)
        try await node.step(.mined(MinedGrind(root: carrier, rootChildren: rootChildren, carried: [.init(
            path: Self.alpha, block: child, children: childChildren, proof: proof, evidence: evidence
        )])))
        return try BlockHeader(node: carrier).rawCID
    }

    /// A child block whose carrier's branch the parent's start leaves (a
    /// heavier branch executes again first) cannot execute from what this
    /// node holds: the child's journal is judged once the parent's replay is
    /// over, as Bitcoin loads its mempool once `ActivateBestChain` has
    /// connected what it can, not when the child chain next moves.
    func testAChildsJournalIsJudgedOnceItsParentsReplayLeftTheCarrier() async throws {
        let configuration = try configuration(hosting: [Self.alpha])
        let (genesis, heavier): (String, String)
        do {
            var node = try await open(configuration)
            let clock = TestBlockClock()
            let nexusGenesis = try await node.block(node.tip())
            // A transaction, so that only this branch produces the state the
            // child genesis commits as its parent state.
            let side = try await node.mine(
                on: nexusGenesis, timestamp: clock.next(),
                transactions: [try signed(CryptoUtils.generateKeyPair(), nonce: 0)]
            )
            XCTAssertNotEqual(side.postState.rawCID, nexusGenesis.postState.rawCID)
            (_, genesis) = try await mineChildGenesis(&node, on: side)
            XCTAssertEqual(node.tip(Self.alpha), genesis)
            var block = nexusGenesis
            for _ in 0..<3 { block = try await node.mine(on: block, timestamp: clock.next()) }
            heavier = try BlockHeader(node: block).rawCID
            XCTAssertEqual(node.tip(), heavier)
        }
        var node = try await open(configuration)
        let replays = try await replays(of: node, [["Nexus"], Self.alpha])
        guard case .level(_, .replay(let held)) = replays[1] else { return XCTFail() }
        XCTAssertEqual(held, [genesis], "the child genesis executes again from its own body")
        try await node.step(replays + [.tick])
        XCTAssertEqual(node.tip(), heavier)
        XCTAssertNotEqual(node.tip(Self.alpha), genesis, "its carrier's branch was left")
        XCTAssertNil(node.host.levels[["Nexus"]]?.replaying)
        XCTAssertNil(node.host.levels[Self.alpha]?.replaying, "the child's journal is judged")
    }

    /// A child block whose carrier the parent's start executes again waits
    /// for it: the child's journal is judged on that block, though the
    /// child tried it before its parent had executed the carrier.
    func testAChildsJournalWaitsForItsParentsReplay() async throws {
        let configuration = try configuration(hosting: [Self.alpha])
        let block: String
        do {
            var node = try await open(configuration)
            let (carrier, genesis) = try await mineChildGenesis(&node)
            try await node.flush()
            // A transaction, so that only `side` produces the state the
            // child block commits as its parent state.
            let side = try await node.mine(
                on: try await node.block(carrier), timestamp: TestBlockClock().next(),
                transactions: [try signed(CryptoUtils.generateKeyPair(), nonce: 0)]
            )
            let child = try await BlockBuilder.buildBlock(
                previous: try await node.block(genesis),
                parentChainBlock: try await BlockBuilder.buildBlock(
                    previous: side, timestamp: side.timestamp + 1, fetcher: node.storage
                ),
                timestamp: side.timestamp + 1, fetcher: node.storage
            )
            _ = try await mineCarrier(&node, on: side, carrying: child)
            block = try BlockHeader(node: child).rawCID
            XCTAssertEqual(node.tip(Self.alpha), block)
        }
        var node = try await open(configuration)
        let row = NodeEvent.level(Self.alpha, .mining(.transactionReceived(
            try signed(CryptoUtils.generateKeyPair(), nonce: 0, chainPath: Self.alpha),
            origin: .restored(addedAt: 1)
        )))
        // The child's replay first: it tries its genesis before its parent
        // has executed the carrier again.
        try await node.step(try await replays(of: node, [Self.alpha, ["Nexus"]]) + [row, .tick])
        XCTAssertEqual(node.tip(Self.alpha), block)
        let judged = node.seen.compactMap { effect -> String? in
            guard case .level(let path, .mining(.preflight(let job))) = effect, path == Self.alpha else { return nil }
            return job.tipCID
        }
        XCTAssertEqual(judged, [block], "judged once the child block executed again")
    }

    /// What a start sends each of `paths`, in that order: the blocks it
    /// executes again from this node's bodies.
    private func replays(of node: Node, _ paths: [ChainPath]) async throws -> [NodeEvent] {
        var events: [NodeEvent] = []
        for path in paths {
            let level = try XCTUnwrap(node.host.levels[path])
            events.append(.level(path, .replay(await NodeRuntime.replay(of: level, storage: node.storage))))
        }
        return events
    }

    /// A body that cannot be stored stops the node, and the verdict of the
    /// execution that stored it is never applied: the body is what a
    /// restart would execute again (Bitcoin's `AbortNode` on a failed block
    /// write, geth's `log.Crit`).
    func testABodyThatCannotBeStoredStopsTheNode() async throws {
        let configuration = try configuration()
        var node = try await open(configuration)
        let stopped = Mutex<(any Error)?>(nil)
        node.failStop = { error in stopped.withLock { $0 = $0 ?? error } }
        let genesis = node.tip()
        _ = try await node.mine(on: try await node.block(genesis), timestamp: TestBlockClock().next()) {
            // The disk refuses the next body: its pins under the body scope.
            _ = try NodeSQLite(path: configuration.storagePath.appendingPathComponent("volumes.db").path).execute("""
                CREATE TRIGGER refuse_bodies BEFORE INSERT ON retained_roots
                WHEN NEW.scope LIKE '%:body:%' BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        XCTAssertNotNil(stopped.withLock { $0 })
        XCTAssertEqual(node.tip(), genesis, "the execution's verdict was not applied")
    }

    private func runtimeConfiguration(keyByte: String) throws -> (NodeConfiguration, IvyConfig) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-derived-cache-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate()
        )
        // No peer: what a start executes again comes from this store alone.
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: port,
            bootstrapPeers: [],
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        return (configuration, overlay)
    }

    private func signed(
        _ key: (privateKey: String, publicKey: String), nonce: UInt64, chainPath: ChainPath = ["Nexus"]
    ) throws -> Transaction {
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: nonce, chainPath: chainPath
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: body, privateKeyHex: key.privateKey
            ))],
            body: body
        )
    }

    /// The journal is judged on the tip a start reaches executing again
    /// what it holds, not on the one the crash left: a transaction valid
    /// only after a block whose execution the crash lost is pooled.
    func testAJournaledTransactionIsJudgedOnceTheStartHasExecutedAgain() async throws {
        let (configuration, overlay) = try runtimeConfiguration(keyByte: "5d")
        let key = CryptoUtils.generateKeyPair()
        let carrier: String
        do {
            var node = try await open(configuration)
            let genesis = try await node.block(node.tip())
            let block = try await node.mine(
                on: genesis, timestamp: TestBlockClock().next(), transactions: [try signed(key, nonce: 0)]
            )
            carrier = try BlockHeader(node: block).rawCID
            XCTAssertEqual(node.tip(), carrier)
            // Admitted on the carrier, so journaled at once; the carrier's
            // execution is held, and the crash loses it.
            _ = try await node.storage.persistLocalTransaction(try signed(key, nonce: 1))
        }
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        try await eventually("pooled on the carrier executed again") {
            let status = await runtime.status()
            return status.tipCID == carrier && status.mempoolCount == 1
        }
        await runtime.stop()
        let journal = try await storage.localTransactions()
        XCTAssertEqual(journal.map { $0.transaction.body.node?.nonce }, [1])
    }

    /// A row whose transaction left the pool goes with the next flush,
    /// unless the transaction is pooled again first: a reorg that returns a
    /// confirmed local transaction before the flush keeps its row (geth's
    /// journal holds what the pool holds at `rotate`).
    func testARowStaysWhenItsTransactionIsPooledAgainBeforeTheFlush() throws {
        let transaction = try signed(CryptoUtils.generateKeyPair(), nonce: 0)
        let item = MempoolItem(cid: "returned", transaction: transaction, addedAt: 0)
        var unflushed = NodeRuntime.Loop.Unflushed()
        unflushed.poolChanged(PoolDelta(removed: [item.cid]))
        XCTAssertEqual(unflushed.journal, [item.cid], "confirmed: its row goes with the flush")
        unflushed.poolChanged(PoolDelta(added: [item]))
        XCTAssertTrue(unflushed.journal.isEmpty, "returned before the flush: its row stays")
    }

    /// A flush is due at once when an execution found a block invalid (its
    /// body is never stored, so a restart could not find it invalid
    /// again), and otherwise at the bound: its bytes of post-state, or one
    /// execution per MiB of it.
    func testAFlushIsDueAtOnceForAnExclusionAndAtOneExecutionPerMiB() {
        typealias Key = NodeRuntime.Loop.BodyKey
        let limit = 8 << 20
        var unflushed = NodeRuntime.Loop.Unflushed()
        XCTAssertFalse(unflushed.due(limit: limit))
        unflushed.excluded = [Key(path: ["Nexus"], cid: "invalid")]
        XCTAssertTrue(unflushed.due(limit: .max), "an exclusion is written at once")
        unflushed = NodeRuntime.Loop.Unflushed()
        unflushed.bodies = (0..<7).map { Key(path: ["Nexus"], cid: "\($0)") }
        XCTAssertFalse(unflushed.due(limit: limit), "7 executions under an 8 MiB bound")
        unflushed.bodies.append(Key(path: ["Nexus"], cid: "7"))
        XCTAssertTrue(unflushed.due(limit: limit), "8 executions: one per MiB")
        unflushed.bodies = []
        unflushed.bytes = limit
        XCTAssertTrue(unflushed.due(limit: limit), "the post-states reach the bound")
    }

    /// The journal row of a local transaction a block confirmed goes with
    /// the flush that writes the block's execution, so a crash before it
    /// judges the row again on the tip the start reaches (Bitcoin's wallet
    /// writes its best block with the chainstate's flush; geth's journal
    /// drops a transaction at `rotate`).
    func testAConfirmedTransactionsJournalRowGoesWithTheFlush() async throws {
        let (configuration, overlay) = try runtimeConfiguration(keyByte: "5e")
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        _ = try await runtime.submitTransaction(SubmitTransactionRequest(
            transaction: try signed(CryptoUtils.generateKeyPair(), nonce: 0)
        ))
        _ = try await runtime.mineBlock()
        try await eventually("the block confirms it") { await runtime.status().mempoolCount == 0 }
        let kept = try await storage.localTransactions()
        XCTAssertEqual(kept.count, 1, "its row waits for the flush")
        runtime.maintain()
        try await eventually("the flush drops its row") { (try? await storage.localTransactions().isEmpty) ?? false }
        await runtime.stop()
    }
}
