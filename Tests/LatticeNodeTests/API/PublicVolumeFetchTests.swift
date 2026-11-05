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
            try await reader.fetchVolume(
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

    /// A read the node had no room for is busy (503), never absent.
    func testAReadTheNodeHadNoRoomForIsBusyNotAbsent() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-public-fetch-busy-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        let full = PublicVolumeFetches(limit: 1) { _ in throw NodeRuntimeError.busy }
        let app = makePublicReadApplication(service: service, host: "127.0.0.1", port: 8081, fetches: full)
        let root = try spec(77).rawCID
        try await app.test(.router) { client in
            try await client.execute(uri: "/volumes/\(root)", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.headers[.retryAfter], "1")
            }
        }
    }

    /// A reader that waited the bound without a place is 503, told to ask
    /// again after about as long as it waited; one that goes away while it
    /// waits leaves the queue at once.
    func testAWaitingReaderIsAnsweredOrLeavesWithItsConnection() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-public-fetch-wait-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        let first = try spec(78).rawCID
        let root = try spec(79).rawCID
        for wait in [Duration.seconds(2), .seconds(30)] {
            let gate = AsyncStream<Void>.makeStream()
            let reads = ReadCount()
            let fetches = PublicVolumeFetches(limit: 1, maximumWait: wait) { cid in
                await reads.add(cid)
                if cid == first { for await _ in gate.stream { break } }
                return nil
            }
            let held = Task { await fetches.archive(first) }
            try await eventually("the place is taken") { await reads.count == 1 }
            let app = makePublicReadApplication(service: service, host: "127.0.0.1", port: 0, fetches: fetches)
            if wait == .seconds(2) {
                try await app.test(.router) { client in
                    try await client.execute(uri: "/volumes/\(root)", method: .get) { response in
                        XCTAssertEqual(response.status, .serviceUnavailable)
                        XCTAssertEqual(response.headers[.retryAfter], "2", "ask again after about the wait")
                    }
                }
            } else {
                try await app.test(.live) { client in
                    let reader = TestClient(host: "localhost", port: try XCTUnwrap(client.port), configuration: .init(timeout: .seconds(60)))
                    reader.connect()
                    let request = Task { try? await reader.get("/volumes/\(root)") }
                    try await eventually("the reader waits") { await fetches.waitingCount == 1 }
                    try await reader.shutdown()
                    try await eventually("its connection closed, it left the queue", within: .seconds(10)) {
                        await fetches.waitingCount == 0
                    }
                    _ = await request.value
                }
            }
            gate.continuation.yield()
            _ = await held.value
            let roots = await reads.roots
            XCTAssertEqual(roots, [first], "the waiter's CID is never read")
        }
    }

    /// Reads at once: what the operator asked, within half the budget at
    /// the archive cap, at least one; none when asked for none.
    func testTheLimitFitsInHalfTheBudget() {
        let cap = maximumCompleteVolumeArchiveBytes
        XCTAssertEqual(PublicVolumeFetches.limit(requested: 0, inFlightVolumeBytes: 1 << 40), 0)
        XCTAssertEqual(PublicVolumeFetches.limit(requested: 4, inFlightVolumeBytes: 2 * cap), 1, "the default budget")
        XCTAssertEqual(PublicVolumeFetches.limit(requested: 4, inFlightVolumeBytes: 1), 1, "always one")
        XCTAssertEqual(PublicVolumeFetches.limit(requested: 4, inFlightVolumeBytes: 6 * cap), 3)
        XCTAssertEqual(PublicVolumeFetches.limit(requested: 4, inFlightVolumeBytes: 100 * cap), 4)
        XCTAssertEqual(PublicVolumeFetches.limit(requested: .max, inFlightVolumeBytes: .max), Int.max / 2 / cap)
    }

    /// While the limit's reads are in flight another CID waits, and is
    /// read once one of them ends.
    func testAReadPastTheLimitWaitsForAPlace() async throws {
        let volume = try spec(99)
        let serialized = try await serializedVolume(volume)
        let gate = AsyncStream<Void>.makeStream()
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 1) { root in
            await reads.add(root)
            if root == volume.rawCID { for await _ in gate.stream { break } }
            return root == volume.rawCID ? serialized : nil
        }
        let first = Task { await fetches.archive(volume.rawCID) }
        try await eventually("the first read started") { await reads.count == 1 }
        let other = Task { await fetches.archive("other") }
        try await eventually("the other CID waits") { await fetches.waitingCount == 1 }
        let whileFull = await reads.count
        XCTAssertEqual(whileFull, 1, "another CID past the limit waits, not read")
        gate.continuation.yield()
        guard case .archive(let got) = await first.value else { return XCTFail("the reader gets the Volume") }
        XCTAssertEqual(Data(got.readableBytesView), encodeCompleteVolumeArchive(serialized))
        guard case .notServed = await other.value else { return XCTFail("the waiter is read once the place frees") }
    }

    /// A burst many times the limit is all served, none busy, and never more
    /// than the limit read at once.
    func testABurstPastTheLimitIsAllServedWithinTheLimit() async throws {
        let volume = try spec(101)
        let serialized = try await serializedVolume(volume)
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 2) { _ in
            await reads.begin()
            try await Task.sleep(for: .milliseconds(20))
            await reads.end()
            return serialized
        }
        let answers = await withTaskGroup(of: PublicVolumeFetches.Answer.self) { group in
            for n in 0..<12 { group.addTask { await fetches.archive("cid-\(n)") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(answers.count, 12)
        for answer in answers {
            guard case .archive = answer else { return XCTFail("every reader in the burst is served") }
        }
        let peak = await reads.peak
        XCTAssertLessThanOrEqual(peak, 2, "at most the limit read at once")
    }

    /// A waiting reader that is cancelled leaves the queue: it is busy, its
    /// CID is never read, and the reader behind it takes the place.
    func testACancelledWaiterGivesUpItsPlace() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 1) { root in
            await reads.add(root)
            if root == "first" { for await _ in gate.stream { break } }
            return nil
        }
        let first = Task { await fetches.archive("first") }
        try await eventually("the first read started") { await reads.count == 1 }
        let cancelled = Task { await fetches.archive("cancelled") }
        try await eventually("it waits") { await fetches.waitingCount == 1 }
        let behind = Task { await fetches.archive("behind") }
        try await eventually("the reader behind it waits") { await fetches.waitingCount == 2 }
        cancelled.cancel()
        guard case .waited = await cancelled.value else { return XCTFail("a cancelled waiter has no place") }
        let left = await fetches.waitingCount
        XCTAssertEqual(left, 1, "it left the queue")
        gate.continuation.yield()
        _ = await first.value
        guard case .notServed = await behind.value else { return XCTFail("the reader behind is read") }
        let roots = await reads.roots
        XCTAssertEqual(roots, ["first", "behind"], "the cancelled CID is never read")
    }

    /// A reader that waits longer than the bound has no place, and its CID
    /// is never read.
    func testAWaitLongerThanTheBoundEnds() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 1, maximumWait: .milliseconds(50)) { root in
            await reads.add(root)
            for await _ in gate.stream { break }
            return nil
        }
        let first = Task { await fetches.archive("first") }
        try await eventually("the first read started") { await reads.count == 1 }
        guard case .waited = await fetches.archive("late") else { return XCTFail("past the bound it has no place") }
        gate.continuation.yield()
        _ = await first.value
        let roots = await reads.roots
        XCTAssertEqual(roots, ["first"])
    }

    /// Readers asking for one CID share one read, whether it is in flight
    /// or still waiting for a place.
    func testReadersOfOneCIDShareOneReadWhileWaiting() async throws {
        let volume = try spec(103)
        let serialized = try await serializedVolume(volume)
        let gate = AsyncStream<Void>.makeStream()
        let reads = ReadCount()
        let fetches = PublicVolumeFetches(limit: 1) { root in
            await reads.add(root)
            if root == "first" { for await _ in gate.stream { break } }
            return serialized
        }
        let first = Task { await fetches.archive("first") }
        try await eventually("the first read started") { await reads.count == 1 }
        let waiters = (0..<3).map { _ in Task { await fetches.archive(volume.rawCID) } }
        try await eventually("all three wait") { await fetches.waitingCount == 3 }
        gate.continuation.yield()
        _ = await first.value
        for waiter in waiters {
            guard case .archive = await waiter.value else { return XCTFail("every waiter gets the Volume") }
        }
        let roots = await reads.roots
        XCTAssertEqual(roots, ["first", volume.rawCID], "one read for the waiters of one CID")
    }

    private func serializedVolume(_ volume: VolumeImpl<ChainSpec>) async throws -> SerializedVolume {
        let captured = CapturedSerializedVolumes()
        try await volume.store(storer: captured)
        let volumes = await captured.volumes
        return try XCTUnwrap(volumes.first { $0.root == volume.rawCID })
    }
}

private actor ReadCount {
    private(set) var roots: [String] = []
    private(set) var peak = 0
    private var running = 0
    var count: Int { roots.count }
    func add(_ root: String) { roots.append(root) }
    func begin() { running += 1; peak = max(peak, running) }
    func end() { running -= 1 }
}

private actor CapturedSerializedVolumes: VolumeStorer {
    private(set) var volumes: [SerializedVolume] = []
    func store(volume: SerializedVolume) async throws { volumes.append(volume) }
}
