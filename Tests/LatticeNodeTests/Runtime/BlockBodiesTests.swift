import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// `blockBodies: none`: a node keeps only the bodies it needs to operate
/// (the ones waiting to execute, each chain's tip, each genesis) and goes
/// on mining, syncing and restarting.
final class BlockBodiesTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    private func host(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        storageDirectory reused: URL? = nil,
        blockBodies: BlockBodies = .all
    ) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-bodies-\(UUID().uuidString)", isDirectory: true
        )
        if reused == nil { addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) } }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            blockBodies: blockBodies
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false), mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    private func transaction() throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0, chainPath: ["Nexus"]
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: key.privateKey
            ))],
            body: bodyHeader
        )
    }

    private func mine(_ runtime: NodeRuntime) async throws -> String {
        try BlockHeader(node: try await runtime.mineBlock()).rawCID
    }

    private func start(_ host: Host) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.open(configuration: host.configuration)
        return (try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        ), storage)
    }

    private func bodiesHeld(_ storage: NodeStorage, of blocks: [String]) async -> [String] {
        var held: [String] = []
        for cid in blocks where await storage.volume(cid) != nil { held.append(cid) }
        return held
    }

    /// A miner on `none` holds its tip's body and its genesis block, lets
    /// go of each body it built past, keeps mining, and restarts.
    func testAMinerOnNoneHoldsOnlyItsTipsBody() async throws {
        let miner = try host(keyByte: 0x91, blockBodies: .none)
        let genesis = miner.configuration.nexusGenesisCID
        var blocks: [String] = []
        do {
            let (runtime, storage) = try await start(miner)
            for _ in 0..<4 { blocks.append(try await mine(runtime)) }
            let tip = try XCTUnwrap(blocks.last)
            try await eventually("every body below the tip is let go of") {
                await self.bodiesHeld(storage, of: blocks) == [tip]
            }
            let genesisVolume = await storage.volume(genesis)
            XCTAssertNotNil(genesisVolume, "every node holds its genesis block")
            let state = await runtime.reads.account(owner: "nobody", blockCID: blocks[0])
            XCTAssertNotNil(state, "state is not a body")
            await runtime.stop()
        }

        let (runtime, storage) = try await start(miner)
        XCTAssertEqual(runtime.published.value?.actOnTip, blocks.last)
        let next = try await mine(runtime)
        XCTAssertEqual(runtime.published.value?.actOnHeight, UInt64(blocks.count + 1))
        try await eventually("the old tip's body goes once another block is the tip") {
            await self.bodiesHeld(storage, of: blocks + [next]) == [next]
        }
        await runtime.stop()
    }

    /// A node on `none` syncs a chain from a peer that keeps every body,
    /// letting go as it goes, and replays to the same tip. Its peer, on the
    /// default, lets go of nothing.
    func testAJoinerOnNoneSyncsFromAPeerThatKeepsEveryBody() async throws {
        let producer = try host(keyByte: 0x92)
        let (producerRuntime, producerStorage) = try await start(producer)
        var blocks: [String] = []
        for _ in 0..<8 { blocks.append(try await mine(producerRuntime)) }
        let tip = try XCTUnwrap(blocks.last)

        let joiner = try host(keyByte: 0x93, peers: [producer.endpoint], blockBodies: .none)
        do {
            let (runtime, storage) = try await start(joiner)
            try await eventually("the joiner executes the producer's tip") {
                runtime.published.value?.actOnTip == tip
            }
            try await eventually("the joiner holds only its tip's body") {
                await self.bodiesHeld(storage, of: blocks) == [tip]
            }
            await runtime.stop()
        }
        let kept = await bodiesHeld(producerStorage, of: blocks)
        XCTAssertEqual(kept, blocks, "a node keeping all lets go of no body")
        await producerRuntime.stop()

        let reopened = try await NodeStorage.open(configuration: joiner.configuration)
        let booted = try await NodeRuntime.boot(
            storage: reopened, configuration: joiner.configuration, coreConfig: .init()
        )
        XCTAssertEqual(booted.levels[booted.rootPath]?.snapshot.actOnTip, tip)
    }

    /// A transaction in the block the chain left is read back into the pool
    /// before that body goes, and the tip that carries it now holds it: the
    /// left block's body going does not take it.
    func testATransactionOfTheLeftBlockIsReturnedAndStaysWithTheTipThatCarriesIt() async throws {
        let shared = try transaction()
        let node = try host(keyByte: 0x94, blockBodies: .none)
        var (runtime, storage) = try await start(node)
        let admitted = try await runtime.submitTransaction(SubmitTransactionRequest(transaction: shared))
        let left = try await mine(runtime)
        let carried = await NodeRuntime.transactionIDs(ofBlock: left, fetcher: storage)
        XCTAssertEqual(carried, [admitted.transactionCID])
        await runtime.stop()

        // A producer with a heavier branch from genesis that does not carry it.
        let producer = try host(keyByte: 0x95)
        let (producerRuntime, _) = try await start(producer)
        _ = try await mine(producerRuntime)
        let producerTip = try await mine(producerRuntime)

        let again = try host(
            keyByte: 0x94, peers: [producer.endpoint],
            storageDirectory: node.configuration.storagePath, blockBodies: .none
        )
        runtime = try await NodeRuntime.start(
            storage: storage, configuration: again.configuration, overlay: again.overlay
        )
        try await eventually("the node reorgs onto the heavier branch") {
            runtime.published.value?.actOnTip == producerTip
        }
        try await eventually("the left block's transaction is returned to the pool") {
            runtime.published.value?.mempoolCount == 1
        }
        try await eventually("the left block's body is let go of") {
            await storage.volume(left) == nil
        }

        let tip = try await mine(runtime)
        let now = await NodeRuntime.transactionIDs(ofBlock: tip, fetcher: storage)
        XCTAssertEqual(now, [admitted.transactionCID], "the tip carries the transaction, and holds it")
        _ = try await mine(runtime)
        try await eventually("the transaction goes with the body that carried it") {
            await storage.volume(admitted.transactionCID) == nil
        }
        await runtime.stop()
        await producerRuntime.stop()
    }

    /// A node that kept every body is switched to `none`: at its next start
    /// it lets go of all but its tip's, whether a body was pinned under its
    /// block's name or, in a store written before bodies had names, under
    /// the chain's.
    func testSwitchingToNoneLetsGoOfTheBodiesARunThatKeptAllLeft() async throws {
        for legacy in [false, true] {
            let all = try host(keyByte: legacy ? 0x97 : 0x96)
            var blocks: [String] = []
            do {
                let (runtime, storage) = try await start(all)
                for _ in 0..<4 { blocks.append(try await mine(runtime)) }
                try await eventually("each body is pinned under its block's name") {
                    for cid in blocks where try await storage.broker.retainedRoots(scope: storage.scopes.body(cid)).isEmpty {
                        return false
                    }
                    return true
                }
                await runtime.stop()
                if legacy {
                    // As the previous version left it: every body under the chain's scope.
                    for cid in blocks {
                        let roots = try await storage.broker.retainedRoots(scope: storage.scopes.body(cid))
                        try await storage.broker.mergeRetainedRoots(scope: storage.scopes.chain, roots: roots)
                        try await storage.broker.releaseRetainedRoots(scope: storage.scopes.body(cid), roots: roots)
                    }
                }
                let held = await bodiesHeld(storage, of: blocks)
                XCTAssertEqual(held, blocks)
            }

            let none = try host(
                keyByte: legacy ? 0x97 : 0x96, storageDirectory: all.configuration.storagePath, blockBodies: .none
            )
            let (runtime, storage) = try await start(none)
            let tip = try XCTUnwrap(blocks.last)
            try await eventually("only the tip's body is left (legacy: \(legacy))") {
                await self.bodiesHeld(storage, of: blocks) == [tip]
            }
            let pinned = try await storage.broker.retainedRoots(scope: storage.scopes.body(tip))
            XCTAssertEqual(pinned, [tip], "the tip's body is under its own name")
            let genesis = await storage.volume(none.configuration.nexusGenesisCID)
            XCTAssertNotNil(genesis)
            let next = try await mine(runtime)
            XCTAssertEqual(runtime.published.value?.actOnTip, next)
            await runtime.stop()
        }
    }
}
