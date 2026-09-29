import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// Records the first authenticated session Ivy reports.
private actor ConnectedPeerRecorder: IvyDelegate {
    private var peer: AuthenticatedPeer?

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) {
        if self.peer == nil { self.peer = peer }
    }

    func connectedPeer() -> AuthenticatedPeer? { peer }
}

/// Answers the runtime's transaction-inventory request with an empty page so
/// the session becomes ready, and records every topic it receives.
private final class InventoryAnsweringPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
        guard message.topic == NodeNetworkTopic.transactionInventoryRequest,
              let request = try? TransactionInventoryRequestMessage.decoded(
                message.payload
              ), let response = try? TransactionInventoryResponseMessage(
                requestID: request.requestID,
                afterRootCID: request.afterRootCID,
                volumeRootCIDs: [],
                hasMore: false
              ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.transactionInventoryResponse,
            payload: response
        )
    }
}

/// Counts every Volume request a session makes. The first request parks
/// until `release()`; every later one answers at once.
private actor GatedVolumeFetch {
    private let response: AttributedVolumeResponse
    private var requests = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(response: AttributedVolumeResponse) {
        self.response = response
    }

    func fetch() async -> AttributedVolumeResponse {
        requests += 1
        if requests == 1, !released {
            await withCheckedContinuation { waiter = $0 }
        }
        return response
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func requestCount() -> Int { requests }
}

/// How peers and the process exchange complete Volumes: root equality,
/// all-or-nothing visibility, member-set immutability, the serving source's
/// refusals, and multi-frame transfer through real Ivy.
final class NetworkTrustVolumeExchangeTests: NetworkTrustTestCase {

    private func header(_ key: String) throws -> HeaderImpl<PublicKey> {
        try HeaderImpl<PublicKey>(node: PublicKey(key: key))
    }

    private func entry(
        _ header: HeaderImpl<PublicKey>
    ) throws -> (cid: String, data: Data) {
        (header.rawCID, try header.mapToData())
    }

    // MARK: - Root equality

    /// Establishes: NODE-STORAGE-001.d
    func testSessionFetchRefusesAVolumeRootedAtAnotherCID() async throws {
        let requested = try entry(header("requested-root"))
        let served = try entry(header("served-root"))
        let supplier = peerKey(signingKey(0xc3)).hex
        // A valid Volume rooted elsewhere that also carries the requested
        // object with correct bytes: only the root check refuses it.
        let wrongRoot = AttributedVolumeResponse(
            rootCID: served.cid,
            entries: [served.cid: served.data, requested.cid: requested.data],
            servedBy: PeerID(publicKey: supplier)
        )
        try SerializedVolume(root: served.cid, entries: wrongRoot.entries).validate()
        let source = IvyRootContentSource { _ in wrongRoot }

        let result = await source.withRootTracing(requested.cid) { session in
            await session.fetch([requested.cid])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [requested.cid: [supplier]]
        )
    }

    /// Establishes: NODE-STORAGE-001.d
    func testSessionFetchOfANestedRootRefusesAVolumeRootedAtTheSessionRoot()
        async throws
    {
        let sessionRoot = try entry(header("session-root"))
        let nested = try entry(header("nested-root"))
        let supplier = peerKey(signingKey(0xcc)).hex
        // The session's own root, carrying the nested object with correct
        // bytes: only the check against the root asked for refuses it.
        let sessionRooted = AttributedVolumeResponse(
            rootCID: sessionRoot.cid,
            entries: [sessionRoot.cid: sessionRoot.data, nested.cid: nested.data],
            servedBy: PeerID(publicKey: supplier)
        )
        try SerializedVolume(
            root: sessionRoot.cid,
            entries: sessionRooted.entries
        ).validate()
        let source = IvyRootContentSource { _ in sessionRooted }

        let result = await source.withRootTracing(sessionRoot.cid) { session in
            await session.fetch([nested.cid])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [nested.cid: [supplier]]
        )
    }

    /// Establishes: NODE-STORAGE-001.d
    func testSessionRefusesAnInitialResponseRootedAtAnotherCID() async throws {
        let requested = try entry(header("requested-root"))
        let served = try entry(header("served-root"))
        let supplier = peerKey(signingKey(0xc4)).hex
        let wrongRoot = AttributedVolumeResponse(
            rootCID: served.cid,
            entries: [served.cid: served.data, requested.cid: requested.data],
            servedBy: PeerID(publicKey: supplier)
        )
        try SerializedVolume(root: served.cid, entries: wrongRoot.entries).validate()
        let source = IvyRootContentSource { _ in .empty }

        let result = await source.withRootTracing(
            requested.cid,
            initialResponse: wrongRoot
        ) { session in
            await session.fetch([requested.cid])
        }

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [requested.cid: [supplier]]
        )
    }

    // MARK: - All or nothing

    /// Establishes: NODE-STORAGE-001.i
    func testSessionFetchReturnsNothingWhenOneRequestedObjectIsMissing()
        async throws
    {
        let root = try entry(header("root"))
        let left = try entry(header("left"))
        let right = try entry(header("right"))
        let missing = try entry(header("missing"))
        let volume = AttributedVolumeResponse(
            rootCID: root.cid,
            entries: [root.cid: root.data, left.cid: left.data, right.cid: right.data],
            servedBy: nil
        )
        let source = IvyRootContentSource { requested in
            requested == root.cid ? volume : .empty
        }

        let result = await source.withRootTracing(root.cid) { session in
            let partial = await session.fetch([root.cid, left.cid, missing.cid])
            let complete = await session.fetch([root.cid, left.cid, right.cid])
            return (partial, complete)
        }

        XCTAssertTrue(result.value.0.isEmpty, "two served objects stay invisible beside a missing one")
        XCTAssertEqual(result.value.1, volume.entries)
        XCTAssertFalse(result.attribution.allResponsesComplete)
    }

    // MARK: - Member sets

    /// Establishes: NODE-STORAGE-001.n
    func testASessionRequestsEachRootAtMostOnce() async throws {
        let root = try entry(header("once-root"))
        let volume = AttributedVolumeResponse(
            rootCID: root.cid,
            entries: [root.cid: root.data],
            servedBy: nil
        )

        // A failed request is not repeated within the session.
        let failing = GatedVolumeFetch(response: .empty)
        await failing.release()
        let sequential = IvyRootContentSource { _ in await failing.fetch() }
        let repeated = await sequential.withRoot(root.cid) { session in
            var results: [[String: Data]] = []
            for _ in 0..<3 {
                results.append(await session.fetch([root.cid]))
            }
            return results
        }
        XCTAssertEqual(repeated, [[:], [:], [:]])
        let sequentialRequests = await failing.requestCount()
        XCTAssertEqual(sequentialRequests, 1)

        // A fetch while the root's one request is in flight does not
        // request it again, nor does one after it is stored.
        let gated = GatedVolumeFetch(response: volume)
        let concurrent = IvyRootContentSource { _ in await gated.fetch() }
        let results = try await concurrent.withRoot(root.cid) { session in
            async let first = session.fetch([root.cid])
            try await eventually("the first request is in flight") {
                await gated.requestCount() == 1
            }
            let during = await session.fetch([root.cid])
            await gated.release()
            let firstResult = await first
            let after = await session.fetch([root.cid])
            return [firstResult, during, after]
        }
        XCTAssertEqual(results, [volume.entries, [:], volume.entries])
        let concurrentRequests = await gated.requestCount()
        XCTAssertEqual(concurrentRequests, 1)
    }

    /// Establishes: NODE-STORAGE-001.e
    func testTheProcessRefusesAnotherMemberSetForAStoredRoot() async throws {
        let process = try await canonicalNetworkProcess()
        let root = try entry(header("stored-root"))
        let first = try entry(header("first-member"))
        let second = try entry(header("second-member"))
        let original = SerializedVolume(
            root: root.cid,
            entries: [root.cid: root.data, first.cid: first.data]
        )
        try await process.store(volume: original)

        let replaced = SerializedVolume(
            root: root.cid,
            entries: [root.cid: root.data, second.cid: second.data]
        )
        let grown = SerializedVolume(
            root: root.cid,
            entries: [root.cid: root.data, first.cid: first.data, second.cid: second.data]
        )
        let shrunk = SerializedVolume(
            root: root.cid,
            entries: [root.cid: root.data]
        )
        for conflicting in [replaced, grown, shrunk] {
            do {
                try await process.store(volume: conflicting)
                XCTFail("stored \(conflicting.entries.count) members over the original")
            } catch {}
        }
        try await process.store(volume: original)

        let stored = await process.volume(root.cid)
        XCTAssertEqual(stored?.root, original.root)
        XCTAssertEqual(stored?.entries, original.entries)
    }

    /// Establishes: NODE-STORAGE-001.e
    func testASessionKeepsCorrectlyAddressedPaddingOnlyWithinItsLimits()
        async throws
    {
        let root = try entry(header("padded-root"))
        let first = try entry(header("unreferenced-padding-1"))
        let second = try entry(header("unreferenced-padding-2"))
        let next = try entry(header("next-root"))
        let padded = [root.cid: root.data, first.cid: first.data, second.cid: second.data]
        let volumes = [padded, [next.cid: next.data]]
        let responses = Dictionary(uniqueKeysWithValues: zip(
            [root.cid, next.cid],
            volumes
        ).map { rootCID, entries in
            (rootCID, AttributedVolumeResponse(rootCID: rootCID, entries: entries, servedBy: nil))
        })
        let paddedBytes = padded.reduce(0) { $0 + $1.key.utf8.count + $1.value.count + 6 }
        let memberBound = IvyRootContentSource(
            maximumMembers: padded.count,
            maximumStorageBytes: .max
        ) { responses[$0] ?? .empty }
        let byteBound = IvyRootContentSource(
            maximumMembers: .max,
            maximumStorageBytes: paddedBytes
        ) { responses[$0] ?? .empty }

        for source in [memberBound, byteBound] {
            let result = await source.withRootTracing(root.cid) { session in
                _ = await session.fetch([root.cid])
                let padding = await session.fetch([first.cid, second.cid])
                let beyond = await session.fetch([next.cid])
                return (padding, beyond)
            }

            XCTAssertEqual(result.value.0, [first.cid: first.data, second.cid: second.data])
            XCTAssertTrue(result.value.1.isEmpty, "the next Volume exceeds the session's limit")
            XCTAssertFalse(result.attribution.allResponsesComplete)
        }
    }

    // MARK: - Initial response

    /// Establishes: NODE-STORAGE-001.j
    func testAnInitialResponseWithOneBadEntryIsRefusedAndAttributed()
        async throws
    {
        let root = try entry(header("initial-root"))
        let member = try entry(header("initial-member"))
        let corrupt = try entry(header("initial-corrupt"))
        let supplier = peerKey(signingKey(0xc5)).hex
        let initial = AttributedVolumeResponse(
            rootCID: root.cid,
            entries: [
                root.cid: root.data,
                member.cid: member.data,
                corrupt.cid: Data([0x01]),
            ],
            servedBy: PeerID(publicKey: supplier)
        )
        let source = IvyRootContentSource { _ in .empty }

        let result = await source.withRootTracing(
            root.cid,
            initialResponse: initial
        ) { session in
            await session.fetch([root.cid, member.cid])
        }

        XCTAssertTrue(result.value.isEmpty, "valid entries do not vouch for a corrupt one")
        XCTAssertEqual(
            result.attribution.deficientVolumeSuppliers,
            [root.cid: [supplier]]
        )
    }

    // MARK: - Serving source

    /// Establishes: NODE-STORAGE-001.k
    func testTheServingSourceRefusesEveryEntryLevelContentRequest()
        async throws
    {
        let process = try await canonicalNetworkProcess()
        let durableRoot = try entry(header("durable-root"))
        let durableMember = try entry(header("durable-member"))
        let transientRoot = try entry(header("transient-root"))
        let transientMember = try entry(header("transient-member"))
        try await process.store(volume: SerializedVolume(
            root: durableRoot.cid,
            entries: [durableRoot.cid: durableRoot.data, durableMember.cid: durableMember.data]
        ))
        let transient = SerializedVolume(
            root: transientRoot.cid,
            entries: [transientRoot.cid: transientRoot.data, transientMember.cid: transientMember.data]
        )
        let source = ChainProcessIvyContentSource(
            process: process,
            transientRootVolume: { $0 == transient.root ? transient : nil }
        )
        let requests: [(root: String, cids: [String])] = [
            (durableRoot.cid, [durableRoot.cid]),
            (durableRoot.cid, [durableRoot.cid, durableMember.cid]),
            (durableRoot.cid, [durableMember.cid]),
            (transientRoot.cid, [transientRoot.cid, transientMember.cid]),
            (transientRoot.cid, [transientMember.cid]),
        ]

        for role in [AuthenticatedPeerRole.endpoint, .carrier] {
            let peer = authenticatedPeer(signingKey(0xc6), role: role)
            for request in requests {
                let authorized = await source.authorizesContentRequest(
                    from: peer,
                    rootCID: request.root,
                    cids: request.cids
                )
                XCTAssertFalse(authorized, "\(role) \(request.cids.count) of \(request.root)")
            }
            let volumeAllowed = await source.authorizesVolumeRequest(
                from: peer,
                rootCID: durableRoot.cid
            )
            XCTAssertTrue(volumeAllowed)
        }
    }

    /// Establishes: NODE-STORAGE-001.k
    func testTheServingSourceServesAVolumeOverBudgetWholeOrNotAtAll()
        async throws
    {
        let process = try await canonicalNetworkProcess()
        let members = try [
            entry(header(String(repeating: "r", count: 40))),
            entry(header(String(repeating: "a", count: 90))),
            entry(header(String(repeating: "b", count: 160))),
            entry(header(String(repeating: "c", count: 250))),
        ]
        let volume = SerializedVolume(
            root: members[0].cid,
            entries: Dictionary(uniqueKeysWithValues: members.map { ($0.cid, $0.data) })
        )
        let source = ChainProcessIvyContentSource(
            process: process,
            transientRootVolume: { $0 == volume.root ? volume : nil }
        )
        let total = volume.entries.values.reduce(0) { $0 + $1.count }
        let whole = volume.entries.sorted { $0.key < $1.key }.map {
            ContentEntry(cid: $0.key, data: $0.value)
        }

        let exact = await source.volume(rootCID: volume.root, maxDataBytes: total)
        XCTAssertEqual(exact, whole)
        for budget in [total - 1, total - members[1].data.count, members[3].data.count] {
            let served = await source.volume(rootCID: volume.root, maxDataBytes: budget)
            XCTAssertTrue(served.isEmpty, "budget \(budget) of \(total) served \(served.count) entries")
        }
    }

    // MARK: - Transaction Volumes

    /// Establishes: NODE-STORAGE-001.l
    func testATransactionVolumeWithACorruptUnreferencedEntryIsNotPooled()
        async throws
    {
        let target = try await overlayRuntime(
            keyByte: 0xc7,
            requestTimeout: .seconds(2) * testTimeScale
        )
        let service = networkService(
            process: target.process,
            runtime: target.runtime
        )
        let attempts = NetworkEventRecorder()
        let handlers = transactionServiceHandlers(service, transactions: attempts)
        let transaction = try signedNetworkTransaction(chainPath: ["Nexus"])
        let clean = try await transactionVolume(transaction)
        let padding = try entry(header("unreferenced-valid-padding"))
        let corrupt = try entry(header("unreferenced-corrupt-padding"))
        var corruptEntries = clean.entries
        corruptEntries[padding.cid] = padding.data
        corruptEntries[corrupt.cid] = Data([0x01])
        let corrupted = SerializedVolume(root: clean.root, entries: corruptEntries)
        XCTAssertThrowsError(try corrupted.validate())

        let corruptTopics = TopicRecorder()
        let corruptPeer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc8),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let corruptDelegate = InventoryAnsweringPeer(recorder: corruptTopics)
        await corruptPeer.installTestDelegate(corruptDelegate)
        let corruptSource = RecordingVolumesSource([corrupted])
        await corruptPeer.setContentSource(corruptSource)
        let honestTopics = TopicRecorder()
        let honestPeer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc9),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let honestDelegate = InventoryAnsweringPeer(recorder: honestTopics)
        await honestPeer.installTestDelegate(honestDelegate)
        await honestPeer.setContentSource(VolumeSource(one: clean))
        let announcement = try TransactionAvailableMessage(
            volumeRootCID: clean.root
        ).encoded()

        do {
            try await target.runtime.start(process: target.process, chain: handlers)
            try await connectAndHello(
                corruptPeer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: corruptTopics
            )
            // The target holds a root's per-session lease from its fetch
            // until the Volume is judged, and fetches a pooled root no
            // more. A second fetch of the root from this peer therefore
            // proves the first was fetched, judged and not pooled.
            try await eventually(
                "the corrupt Volume is fetched, judged and fetched again",
                poll: .milliseconds(100)
            ) {
                guard case .enqueued = await corruptPeer.sendMessage(
                    to: target.peerID,
                    topic: NodeNetworkTopic.transactionAvailable,
                    payload: announcement
                ) else { throw NetworkTestError.failedSend }
                return await corruptSource.requests().count >= 2
            }
            let served = await corruptSource.requests()
            XCTAssertEqual(Set(served), [clean.root])
            let pooledFromCorrupt = await service.status().mempoolCount
            let attempted = await attempts.snapshot()
            XCTAssertEqual(pooledFromCorrupt, 0)
            XCTAssertEqual(attempted, [])

            // The same root from an honest supplier is pooled: the refusal
            // was the corrupt Volume, not the transaction.
            try await connectAndHello(
                honestPeer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            try await waitForTopic(
                NodeNetworkTopic.transactionInventoryRequest,
                in: honestTopics
            )
            guard case .enqueued = await honestPeer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: announcement
            ) else { throw NetworkTestError.failedSend }
            try await waitForMempoolCount(1, service: service)
        } catch {
            await honestPeer.stop()
            await corruptPeer.stop()
            await target.runtime.stop()
            throw error
        }
        await honestPeer.stop()
        await corruptPeer.stop()
        await target.runtime.stop()
    }

    // MARK: - Frames through real Ivy

    /// Establishes: NODE-STORAGE-001.g
    func testAVolumeOfSeveralFramesArrivesWholeThroughRealIvy() async throws {
        let frameSize: UInt32 = 80 * 1_024
        let members = try (0..<5).map { index in
            try entry(header(String(repeating: "\(index)", count: 60_000)))
        }
        let volume = SerializedVolume(
            root: members[0].cid,
            entries: Dictionary(uniqueKeysWithValues: members.map { ($0.cid, $0.data) })
        )
        try volume.validate()
        let payloadBytes = volume.entries.values.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(payloadBytes, 3 * Int(frameSize))

        let process = try await canonicalNetworkProcess()
        let serverKey = signingKey(0xca)
        let serverPort = NetworkTransportTestPorts.allocate()
        let server = Ivy(config: IvyConfig(
            signingKey: serverKey,
            listenPort: serverPort,
            stunServers: [],
            protocolMaxFrameSize: frameSize,
            mode: .overlay
        ))
        await server.setContentSource(ChainProcessIvyContentSource(
            process: process,
            transientRootVolume: { $0 == volume.root ? volume : nil }
        ))
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(0xcb),
            listenPort: 0,
            requestTimeout: .seconds(5) * testTimeScale,
            stunServers: [],
            protocolMaxFrameSize: frameSize,
            mode: .overlay
        ))
        let recorder = ConnectedPeerRecorder()
        await client.installTestDelegate(recorder)

        do {
            try await server.start()
            try await client.start()
            try await client.connect(to: PeerEndpoint(
                publicKey: peerKey(serverKey).hex,
                host: "127.0.0.1",
                port: serverPort
            ))
            try await eventually("an authenticated session to the server") {
                await recorder.connectedPeer() != nil
            }
            let connected = await recorder.connectedPeer()
            let peer = try XCTUnwrap(connected)
            let source = IvyRootContentSource(ivy: client, peer: peer)

            let result = await source.withRootTracing(volume.root) { session in
                _ = await session.fetch([volume.root])
                return await session.fetch(Set(volume.entries.keys))
            }

            XCTAssertEqual(result.value, volume.entries)
            XCTAssertEqual(result.attribution.servedByPublicKeys, [peerKey(serverKey).hex])
            XCTAssertTrue(result.attribution.allResponsesComplete)
        } catch {
            await client.stop()
            await server.stop()
            throw error
        }
        await client.stop()
        await server.stop()
    }
}
