import Foundation
@testable import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// Operator pins: a Volume the operator names by CID is held, served and
/// announced until the operator unpins it, whatever it is.
final class OperatorPinTests: XCTestCase {
    private struct Host {
        let configuration: NodeConfiguration
        let overlay: IvyConfig
        let endpoint: PeerEndpoint
    }

    /// Each node advertises a routable address, since a loopback address is
    /// never accepted as a referral; dials to it are rewritten to loopback.
    private static func advertised(_ port: UInt16) -> String { "8.8.\(port >> 8).\(port & 0xFF)" }

    private func host(keyByte: UInt8, peers: [PeerEndpoint] = [], storageDirectory reused: URL? = nil) throws -> Host {
        let storageDirectory = reused ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-pins-\(UUID().uuidString)", isDirectory: true
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
            bootstrapPeers: peers,
            // One peer is enough: a node does not go looking for others.
            peerTarget: 1,
            externalAddress: Self.advertised(port),
            peerSearchInterval: 3_600
        )
        return Host(
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                // No background routing refresh: a node meets only the peers
                // it is given, and finds the rest by lookup.
                routingRefreshInterval: .seconds(3_600),
                externalAddress: (Self.advertised(port), port),
                mode: .overlay
            ),
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    private func start(_ host: Host) async throws -> (NodeRuntime, NodeStorage) {
        let storage = try await NodeStorage.open(configuration: host.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: host.configuration, overlay: host.overlay
        )
        await runtime.ivy.setDialEndpointRewriteForTesting { endpoint in
            endpoint.host.hasPrefix("8.8.")
                ? PeerEndpoint(publicKey: endpoint.publicKey, host: "127.0.0.1", port: endpoint.port)
                : endpoint
        }
        return (runtime, storage)
    }

    /// A node given a Volume by its operator holds it, keeps it across a
    /// restart, serves it to another node that finds it by lookup, and
    /// drops it when unpinned. Each node is connected only to a relay,
    /// which does not hold it.
    func testAVolumeTheOperatorProvidesIsHeldServedKeptAndDroppedWhenUnpinned() async throws {
        // Content outside any chain, as the operator has it.
        let volume = try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: 7, maxStateGrowth: 7_777, premine: 7,
            targetBlockTime: 7_000, initialReward: 7, halvingInterval: 7_777, halfLife: 7
        ))
        let root = volume.rawCID
        let captured = CapturedVolumes()
        try await volume.store(storer: captured)
        let volumes = await captured.volumes
        let entries = try XCTUnwrap(volumes.first { $0.root == root }).entries
        let (relayRuntime, _) = try await start(try host(keyByte: 0xc4))
        let relay = PeerEndpoint(
            publicKey: relayRuntime.configuration.processPublicKey, host: "127.0.0.1",
            port: relayRuntime.configuration.listenPort
        )

        var pinner = try host(keyByte: 0xc1, peers: [relay])
        do {
            let (runtime, storage) = try await start(pinner)
            try await runtime.pinVolume(root, entries: entries)
            let held = await storage.volume(root)
            XCTAssertNotNil(held)
            let pins = await runtime.pinnedVolumes()
            XCTAssertEqual(pins, [root])
            await runtime.stop()
        }

        pinner = try host(keyByte: 0xc1, peers: [relay], storageDirectory: pinner.configuration.storagePath)
        let (runtime, storage) = try await start(pinner)
        let held = await storage.volume(root)
        XCTAssertNotNil(held, "a pin survives a restart, which sweeps what no scope names")
        let (reader, readerStorage) = try await start(try host(keyByte: 0xc2, peers: [relay]))
        try await eventually("another node's operator reads it, found by lookup", within: .seconds(20)) {
            try await reader.fetchVolume(root)?.entries == entries
        }
        let notStored = await readerStorage.volume(root)
        XCTAssertNil(notStored, "what an operator reads from peers is not stored")
        // Once its application has validated it, it pins what it read.
        let fetched = try await reader.fetchVolume(root)
        let read = try XCTUnwrap(fetched)
        try await reader.pinVolume(root, entries: read.entries)
        let pinned = await readerStorage.volume(root)
        XCTAssertNotNil(pinned)
        await reader.stop()
        await relayRuntime.stop()

        try await runtime.unpinVolume(root)
        let dropped = await storage.volume(root)
        XCTAssertNil(dropped, "an unpinned Volume nothing else names goes")
        let left = await runtime.pinnedVolumes()
        XCTAssertEqual(left, [])
        await runtime.stop()
        do {
            try await runtime.pinVolume(root, entries: entries)
            XCTFail("a stopped node pins nothing")
        } catch NodeRuntimeError.stopped {}
    }

    /// A Volume the node does not hold and the operator does not provide
    /// is not pinned, even when a peer holds it: a pin is never read from
    /// peers.
    func testAPinTheOperatorDoesNotProvideIsRefusedEvenWhenAPeerHoldsIt() async throws {
        let volume = try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: 9, maxStateGrowth: 9_999, premine: 9,
            targetBlockTime: 9_000, initialReward: 9, halvingInterval: 9_999, halfLife: 9
        ))
        let holder = try host(keyByte: 0xc0)
        let (holderRuntime, holderStorage) = try await start(holder)
        let storer = NodeImportStorage(storage: await holderStorage.broker)
        try await volume.store(storer: storer)
        try await storer.commit()
        try await holderRuntime.pinVolume(volume.rawCID)

        let (runtime, storage) = try await start(try host(keyByte: 0xc3, peers: [holder.endpoint]))
        try await eventually("the node is connected to the holder") { await runtime.ivy.connectedPeers.count == 1 }
        do {
            try await runtime.pinVolume(volume.rawCID)
            XCTFail("a Volume the operator does not provide is not pinned")
        } catch NodeStorageError.missingMaterializedVolume(let root) {
            XCTAssertEqual(root, volume.rawCID)
        }
        let pins = await runtime.pinnedVolumes()
        XCTAssertEqual(pins, [])
        let held = await storage.volume(volume.rawCID)
        XCTAssertNil(held)
        await runtime.stop()
        await holderRuntime.stop()
    }

    /// Unpinning a CID the operator did not pin lets go of nothing.
    func testUnpinningWhatWasNotPinnedKeepsIt() async throws {
        let storage = try await NodeStorage.open(configuration: try host(keyByte: 0xc6).configuration)
        let volume = try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: 6, maxStateGrowth: 6_666, premine: 6,
            targetBlockTime: 6_000, initialReward: 6, halvingInterval: 6_666, halfLife: 6
        ))
        let storer = NodeImportStorage(storage: await storage.broker)
        try await volume.store(storer: storer)
        try await storer.commit()
        try await storage.unpin(volume.rawCID)
        let kept = await storage.volume(volume.rawCID)
        XCTAssertNotNil(kept)
    }
}

/// The Volumes a store was given, in order.
private actor CapturedVolumes: VolumeStorer {
    private(set) var volumes: [SerializedVolume] = []

    func store(volume: SerializedVolume) async throws { volumes.append(volume) }
}
