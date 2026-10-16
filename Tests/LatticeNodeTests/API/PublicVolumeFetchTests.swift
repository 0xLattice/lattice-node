import Foundation
import Hummingbird
import HummingbirdTesting
@testable import Ivy
import Lattice
import LatticeNodeCore
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon

/// The public read port serves a Volume this node does not hold by reading
/// it from peers, within the operator's `--public-read-fetches`.
final class PublicVolumeFetchTests: XCTestCase {
    private func node(keyByte: UInt8, peers: [PeerEndpoint] = []) async throws -> (NodeRuntime, NodeStorage) {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-public-fetch-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: .off,
            bootstrapPeers: peers,
            peerTarget: 1,
            peerSearchInterval: 3_600
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                routingRefreshInterval: .seconds(3_600),
                mode: .overlay
            )
        )
        return (runtime, storage)
    }

    private func spec(_ n: UInt64) throws -> VolumeImpl<ChainSpec> {
        try VolumeImpl<ChainSpec>(node: ChainSpec(
            maxNumberOfTransactionsPerBlock: n, maxStateGrowth: Int(n), premine: n,
            targetBlockTime: n, initialReward: n, halvingInterval: n, halfLife: n
        ))
    }

    /// A reader's public port serves a Volume only its peer pinned, checked
    /// and not kept; with fetches off it is 404.
    func testAVolumeOnlyAPeerHoldsIsServedFromThePublicPort() async throws {
        let volume = try spec(4_242)
        let root = volume.rawCID
        let (holder, holderStorage) = try await node(keyByte: 0xd1)
        let storer = NodeImportStorage(storage: await holderStorage.broker)
        try await volume.store(storer: storer)
        try await storer.commit()
        try await holder.pinVolume(root)
        let holderEndpoint = PeerEndpoint(
            publicKey: holder.configuration.processPublicKey, host: "127.0.0.1",
            port: holder.configuration.listenPort
        )
        let (reader, readerStorage) = try await node(keyByte: 0xd2, peers: [holderEndpoint])
        try await eventually("the reader is connected to the holder") { await reader.ivy.connectedPeers.count == 1 }

        let local = makePublicReadApplication(service: reader, host: "127.0.0.1", port: 8081)
        try await local.test(.router) { client in
            try await client.execute(uri: "/volumes/\(root)", method: .get) { response in
                XCTAssertEqual(response.status, .notFound, "with fetches off, only what the node holds")
            }
        }
        let fetches = PublicVolumeFetches(limit: 4) {
            try? await reader.fetchVolume(
                $0, maximumArchiveBytes: maximumCompleteVolumeArchiveBytes,
                maximumEntries: maximumCompleteVolumeArchiveEntries
            )
        }
        let app = makePublicReadApplication(service: reader, host: "127.0.0.1", port: 8081, fetches: fetches)
        try await app.test(.router) { client in
            try await eventually("the reader's public port serves it", within: .seconds(20)) {
                try await client.execute(uri: "/volumes/\(root)", method: .get) { response in
                    response.status == .ok
                        && response.headers[.contentType] == "application/vnd.lattice.volume"
                        && Data(response.body.readableBytesView).range(of: Data(root.utf8)) != nil
                }
            }
        }
        let kept = await readerStorage.volume(root)
        XCTAssertNil(kept, "what the public port reads from peers is not kept")
        await reader.stop()
        await holder.stop()
    }

    /// Past the operator's limit the read is busy (503), never absent.
    func testAReadPastTheLimitIsBusyNotAbsent() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-public-fetch-busy-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        let none = PublicVolumeFetches(limit: 0) { _ in XCTFail("no read past the limit"); return nil }
        let app = makePublicReadApplication(service: service, host: "127.0.0.1", port: 8081, fetches: none)
        let root = try spec(77).rawCID
        try await app.test(.router) { client in
            try await client.execute(uri: "/volumes/\(root)", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.headers[.retryAfter], "1")
            }
        }
    }

    /// A read the node had no room for is busy, not absent.
    func testAReadTheNodeHadNoRoomForIsBusy() async {
        let fetches = PublicVolumeFetches(limit: 4) { _ in throw NodeRuntimeError.busy }
        guard case .busy = await fetches.archive("full") else { return XCTFail("no room is busy") }
    }

    /// While the limit's reads are in flight another CID is busy; once one
    /// ends, its place is free again.
    func testALimitPlaceFreesWhenItsReadEnds() async throws {
        let volume = try spec(99)
        let captured = CapturedSerializedVolumes()
        try await volume.store(storer: captured)
        let volumes = await captured.volumes
        let serialized = try XCTUnwrap(volumes.first { $0.root == volume.rawCID })
        let gate = AsyncStream<Void>.makeStream()
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 1) { root in
            await reads.add()
            if root == volume.rawCID { for await _ in gate.stream { break } }
            return root == volume.rawCID ? serialized : nil
        }
        let first = Task { await fetches.archive(volume.rawCID) }
        try await eventually("the first read started") { await reads.count == 1 }
        guard case .busy = await fetches.archive("other") else { return XCTFail("another CID past the limit is busy") }
        gate.continuation.yield()
        guard case .archive(let got) = await first.value else { return XCTFail("the reader gets the Volume") }
        XCTAssertEqual(got, encodeCompleteVolumeArchive(serialized))
        guard case .notServed = await fetches.archive("other") else { return XCTFail("the place is free again") }
    }
}

private actor ReadCount {
    private(set) var count = 0
    func add() { count += 1 }
}

private actor CapturedSerializedVolumes: VolumeStorer {
    private(set) var volumes: [SerializedVolume] = []
    func store(volume: SerializedVolume) async throws { volumes.append(volume) }
}
