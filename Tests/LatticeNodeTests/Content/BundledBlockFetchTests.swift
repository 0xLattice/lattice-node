import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// A block's Volumes fetched as one bundle: one request to a peer that
/// advertised bundles and recorded this one, the per-Volume traversal for
/// whatever a bundle lacks, and no bundle request to any other peer.
final class BundledBlockFetchTests: XCTestCase {
    private actor Requests {
        private(set) var bundles: [String] = []
        private(set) var volumes: [String] = []
        func bundle(_ root: String) { bundles.append(root) }
        func volume(_ root: String) { volumes.append(root) }
    }

    private let server = PeerID(publicKey: String(repeating: "ab", count: 32))

    private func storage(keyByte: UInt8, brokenCache: Bool = false) async throws -> NodeStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-bundled-fetch-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if brokenCache {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: 8_192).write(
                to: directory.appendingPathComponent(VolumeBundleCache.fileName)
            )
        }
        return try await NodeStorage.open(configuration: try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32)
        ))
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

    /// A block on `previous`, mined by `producer`, which stores its content
    /// (recording its bundle) and the state it executed to.
    private func mined(
        on previous: Block,
        _ transactions: [Transaction] = [],
        rewardRecipient: String? = nil,
        by producer: NodeStorage
    ) async throws -> Block {
        var nonce: UInt64 = 0
        var built: BlockBuildResult
        repeat {
            built = try await BlockBuilder.buildBlockWithTransition(
                previous: previous, transactions: transactions,
                timestamp: TestBlockClock().next(), nonce: nonce,
                rewardRecipient: rewardRecipient, fetcher: producer
            )
            nonce += 1
        } while built.block.proofOfWorkHash() > built.block.target
        _ = try await producer.storeMinedBlock(built.block)
        try await NodeStorage.storeExecutedState(try XCTUnwrap(built.materializedPostState), in: producer)
        return built.block
    }

    /// Block 1 pays its reward to a payer; block 2 carries the payer's
    /// transfer to a new account beside two transactions that move nothing.
    /// Validating block 2 reads state that block 1 wrote.
    private func transferChain(
        by producer: NodeStorage
    ) async throws -> (funding: Block, transfer: Block, transactions: [Transaction]) {
        let genesisCID = NexusGenesis.expectedBlockHash
        let genesisData = await producer.content([genesisCID])[genesisCID]
        let genesis = try XCTUnwrap(Block(data: try XCTUnwrap(genesisData)))
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
        let payee = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let funding = try await mined(on: genesis, rewardRecipient: payerAddress, by: producer)
        let bodyHeader = try HeaderImpl(node: TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddress, delta: -10),
                AccountAction(owner: payee, delta: 3),
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: 0, chainPath: ["Nexus"]
        ))
        let transfer = Transaction(
            signatures: [payer.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: bodyHeader, privateKeyHex: payer.privateKey
            ))],
            body: bodyHeader
        )
        let transactions = [transfer, try transaction(), try transaction()]
        return (funding, try await mined(on: funding, transactions, by: producer), transactions)
    }

    /// `producer` as a peer: every request counted and answered from its
    /// content source, a bundle through `bundle` (its recorded one by default).
    private func remote(
        _ producer: NodeStorage,
        requests: Requests,
        bundle: (@Sendable (String) async -> [String])? = nil
    ) -> IvyRootContentSource {
        let source = NodeStorageIvyContentSource(storage: producer)
        let server = self.server
        let volume: @Sendable (String) async -> AttributedVolumeResponse = { root in
            let entries = await source.volume(rootCID: root, maxDataBytes: .max)
            guard !entries.isEmpty else { return .empty }
            return AttributedVolumeResponse(
                rootCID: root,
                entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.cid, $0.data) }),
                servedBy: server
            )
        }
        return IvyRootContentSource(
            fetch: { root in
                await requests.volume(root)
                return await volume(root)
            },
            fetchBundle: { root in
                await requests.bundle(root)
                var volumes: [AttributedVolumeResponse] = []
                let members = if let bundle { await bundle(root) } else { await source.volumeBundle(rootCID: root) }
                for member in members {
                    let response = await volume(member)
                    if response != .empty { volumes.append(response) }
                }
                return volumes
            }
        )
    }

    /// The joiner holds genesis only: not block 1, nor the state it wrote.
    /// Everything block 2 needs to be validated arrives in its bundle.
    func testABlockSpendingExistingStateIsFetchedWithOneRequestAndValidatesFromItsBundle() async throws {
        let producer = try await storage(keyByte: 0x51)
        let joiner = try await storage(keyByte: 0x52)
        let chain = try await transferChain(by: producer)
        let cid = try BlockHeader(node: chain.transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        XCTAssertEqual(recorded.first, cid)
        XCTAssertTrue(recorded.contains(chain.transfer.prevState.rawCID))
        // A block stored with no record (genesis, as every block stored
        // before bundles were) has its bundle walked from local content, once.
        let genesis = NexusGenesis.expectedBlockHash
        XCTAssertNil(producer.bundles.bundle(root: genesis))
        let walked = await producer.volumeBundle(genesis)
        XCTAssertEqual(walked.first, genesis)
        XCTAssertGreaterThan(walked.count, 1)
        for root in walked {
            let held = await producer.volume(root)
            XCTAssertNotNil(held, root)
        }
        XCTAssertEqual(producer.bundles.bundle(root: genesis), walked)
        // A root that is no block bundles only itself, and nothing is recorded.
        let body = chain.transactions[0].body.rawCID
        let alone = await producer.volumeBundle(body)
        XCTAssertEqual(alone, [body])
        XCTAssertNil(producer.bundles.bundle(root: body))
        let missingPreState = await joiner.volume(chain.transfer.prevState.rawCID)
        XCTAssertNil(missingPreState)

        let requests = Requests()
        let stored = try await joiner.fetchChainBody(cid, remote: remote(producer, requests: requests))

        let bundles = await requests.bundles
        let volumes = await requests.volumes
        XCTAssertEqual(bundles, [cid])
        XCTAssertEqual(volumes, [])
        XCTAssertEqual(Set(stored), Set(recorded))
        // The joiner re-executes the block from what it now holds, and
        // reaches the post-state the block commits to.
        let replayed = try await BlockBuilder.buildBlock(
            previous: chain.funding, transactions: chain.transactions,
            timestamp: chain.transfer.timestamp, nonce: chain.transfer.nonce, fetcher: joiner
        )
        XCTAssertEqual(replayed.postState.rawCID, chain.transfer.postState.rawCID)
        // It recorded the same bundle, so it serves the block the same way.
        let rerecorded = await joiner.volumeBundle(cid)
        XCTAssertEqual(rerecorded, recorded)
    }

    /// A real content-addressed node: its CID and its canonical bytes.
    private func content(_ nonce: UInt64) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["signer"], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    func testABundledVolumeWithACorruptedEntryIsRejectedAndAttributedToItsServer() async throws {
        let root = try content(1)
        let member = try content(2)
        let unused = try content(3)
        var bytes = member.data
        bytes[bytes.startIndex] ^= 0xFF
        let tampered = bytes
        let server = self.server
        let other = PeerID(publicKey: String(repeating: "cd", count: 32))
        let requests = Requests()
        let credits = Requests()
        let source = IvyRootContentSource(
            fetch: { requested in
                await requests.volume(requested)
                guard requested == member.cid else { return .empty }
                return AttributedVolumeResponse(rootCID: member.cid, entries: [member.cid: member.data], servedBy: other)
            },
            fetchBundle: { requested in
                await requests.bundle(requested)
                return [
                    AttributedVolumeResponse(rootCID: root.cid, entries: [root.cid: root.data], servedBy: server),
                    AttributedVolumeResponse(rootCID: member.cid, entries: [member.cid: tampered], servedBy: server),
                    AttributedVolumeResponse(rootCID: unused.cid, entries: [unused.cid: unused.data], servedBy: server),
                ]
            },
            credit: { _, bytes in await credits.volume("\(bytes)") }
        )
        let result = await source.withRootTracing(root.cid) { session in
            let first = await session.fetch([root.cid])
            let second = await session.fetch([member.cid])
            return (first, second, session.accountedBytes)
        }
        XCTAssertEqual(result.value.0, [root.cid: root.data])
        // The bad Volume is its server's deficiency, and is then requested
        // like any Volume: the session still gets it.
        XCTAssertEqual(result.value.1, [member.cid: member.data])
        XCTAssertEqual(result.attribution.deficientVolumeSuppliers, [member.cid: [server.publicKey]])
        let bundles = await requests.bundles
        let volumes = await requests.volumes
        XCTAssertEqual(bundles, [root.cid])
        XCTAssertEqual(volumes, [member.cid])
        // Only verified Volumes the session used are credited and charged:
        // not the corrupted one, nor the one nothing asked for.
        let credited = await credits.volumes
        XCTAssertEqual(credited, ["\(root.data.count)", "\(member.data.count)"])
        XCTAssertEqual(
            result.value.2,
            root.cid.utf8.count + root.data.count + member.cid.utf8.count + member.data.count
                + 2 * IvyRootContentSource.retainedEntryOverhead
        )
    }

    /// The producer's content source behind a real overlay, counting the
    /// bundle requests that reach it.
    private final class CountingSource: IvyContentSource, @unchecked Sendable {
        private let source: NodeStorageIvyContentSource
        private let lock = NSLock()
        private var bundleRequests = 0
        private var volumeRequests = 0
        var answersBundles = true
        /// The bundle names a Volume whose read never returns.
        var neverEnds = false

        init(_ storage: NodeStorage) { source = NodeStorageIvyContentSource(storage: storage) }

        var bundleRequestCount: Int { lock.withLock { bundleRequests } }
        var volumeRequestCount: Int { lock.withLock { volumeRequests } }

        func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] { [] }

        func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
            lock.withLock { volumeRequests += 1 }
            if rootCID == "never" { try? await Task.sleep(for: .seconds(60)) }
            return await source.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
        }

        func volumeBundle(rootCID: String) async -> [String] {
            lock.withLock { bundleRequests += 1 }
            if neverEnds { return [rootCID, "never"] }
            return answersBundles ? await source.volumeBundle(rootCID: rootCID) : []
        }
    }

    private final class Connections: IvyDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [AuthenticatedPeer] = []
        var first: AuthenticatedPeer? { lock.withLock { peers.first } }
        var all: [AuthenticatedPeer] { lock.withLock { peers } }
        func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async { lock.withLock { peers.append(peer) } }
    }

    /// A client overlay connected to a server overlay that serves `producer`.
    private func overlay(
        serving producer: NodeStorage, requestTimeout: Duration = .seconds(5),
        clientInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
    ) async throws -> (client: Ivy, source: CountingSource, serverPeer: AuthenticatedPeer) {
        func config(
            _ key: Curve25519.Signing.PrivateKey, _ port: UInt16,
            inFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
        ) -> IvyConfig {
            IvyConfig(
                signingKey: key, listenPort: port, requestTimeout: requestTimeout, stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                maxInFlightVolumeBytes: inFlightVolumeBytes, externalAddress: ("127.0.0.1", port),
                mode: .overlay
            )
        }
        let serverKey = Curve25519.Signing.PrivateKey()
        let serverPort = NetworkTransportTestPorts.allocate()
        let server = Ivy(config: config(serverKey, serverPort))
        let client = Ivy(config: config(
            Curve25519.Signing.PrivateKey(), NetworkTransportTestPorts.allocate(),
            inFlightVolumeBytes: clientInFlightVolumeBytes
        ))
        let source = CountingSource(producer)
        let connections = Connections()
        await server.installNodeRuntime(delegate: Connections(), contentSource: source)
        await client.installNodeRuntime(delegate: connections, contentSource: CountingSource(producer))
        try await server.start()
        try await client.start()
        addTeardownBlock {
            await client.stop()
            await server.stop()
        }
        try await client.connect(to: PeerEndpoint(
            publicKey: serverKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            host: "127.0.0.1", port: serverPort
        ))
        let deadline = ContinuousClock.now + .seconds(10)
        while connections.first == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The client serves nothing: every fetch goes to the server.
        await client.setContentSource(nil)
        return (client, source, try XCTUnwrap(connections.first))
    }

    /// Over a real overlay: a peer whose hello advertised nothing is never
    /// sent a bundle request, and one that advertised bundles but holds none
    /// for the block is asked once; both times the block arrives per Volume.
    func testABundleIsAskedOnlyOfAPeerThatAdvertisedItAndTraversalCoversTheRest() async throws {
        let producer = try await storage(keyByte: 0x56)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        let (client, source, serverPeer) = try await overlay(serving: producer)

        // The server's hello advertised nothing.
        let remote = IvyRootContentSource(ivy: client)
        remote.peerCapabilities.set([(serverPeer, [])])
        let plain = try await storage(keyByte: 0x57).fetchChainBody(cid, remote: remote)
        XCTAssertEqual(Set(plain), Set(recorded))
        XCTAssertEqual(source.bundleRequestCount, 0)

        // It advertised bundles, and holds none for this block: an answer
        // that ends, so it is asked again for the next block.
        source.answersBundles = false
        remote.peerCapabilities.set([(serverPeer, [ChainHandshake.volumeBundle])])
        for (count, keyByte) in [(1, UInt8(0x58)), (2, 0x59)] {
            let fallback = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote)
            XCTAssertEqual(Set(fallback), Set(recorded))
            XCTAssertEqual(source.bundleRequestCount, count)
        }
    }

    /// A client connected to two servers, the first of which announced
    /// itself under `rendezvous`.
    private func hostAndBystander(
        _ host: NodeStorage, _ bystander: NodeStorage, rendezvous: String,
        recordsPerPeer: Int = IvyConfig.defaultMaxProviderRecordsPerPeer,
        requestTimeout: Duration = .seconds(5)
    ) async throws -> (remote: IvyRootContentSource, host: CountingSource, bystander: CountingSource) {
        func ivy() -> (Ivy, PeerEndpoint) {
            let (key, port) = (Curve25519.Signing.PrivateKey(), NetworkTransportTestPorts.allocate())
            let hex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            return (Ivy(config: IvyConfig(
                signingKey: key, listenPort: port, requestTimeout: requestTimeout, stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                maxProviderRecordsPerPeer: recordsPerPeer, externalAddress: ("127.0.0.1", port),
                mode: .overlay
            )), PeerEndpoint(publicKey: hex, host: "127.0.0.1", port: port))
        }
        let (client, _) = ivy()
        let connections = Connections()
        await client.installNodeRuntime(delegate: connections, contentSource: CountingSource(host))
        try await client.start()
        addTeardownBlock { await client.stop() }
        var sources: [CountingSource] = []
        var servers: [Ivy] = []
        for storage in [host, bystander] {
            let (server, endpoint) = ivy()
            sources.append(CountingSource(storage))
            await server.installNodeRuntime(delegate: Connections(), contentSource: sources[sources.count - 1])
            try await server.start()
            addTeardownBlock { await server.stop() }
            try await client.connect(to: endpoint)
            servers.append(server)
        }
        await client.setContentSource(nil)
        let hostID = await servers[0].localID
        let remote = IvyRootContentSource(ivy: client)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            await servers[0].announceProvider(
                rootCID: rendezvous, expiresAt: UInt64(Date().timeIntervalSince1970) + 600
            )
            let named = await client.providers(for: rendezvous)
            if connections.all.count == 2, named == [hostID] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        remote.peerCapabilities.set(connections.all.map { ($0, [ChainHandshake.volumeBundle]) })
        return (remote, sources[0], sources[1])
    }

    /// A chain's bundle is asked of the capable session its rendezvous names:
    /// a capable peer that holds the same bundle and is not named there is
    /// not asked.
    func testAChainsBundleIsAskedOfThePeerItsRendezvousNames() async throws {
        let producer = try await storage(keyByte: 0x71)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let (remote, host, bystander) = try await hostAndBystander(producer, producer, rendezvous: "alpha")
        for keyByte in [UInt8(0x72), 0x73, 0x74, 0x75, 0x76] {
            _ = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote, hosts: "alpha")
        }
        XCTAssertEqual(host.bundleRequestCount, 5)
        XCTAssertEqual(bystander.bundleRequestCount, 0)
    }

    /// Serving content does not cost a host its record: one that served more
    /// bundles than a peer may hold records for is still the one asked.
    func testAHostThatServedMoreThanItsRecordQuotaIsStillNamed() async throws {
        let producer = try await storage(keyByte: 0x7B)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let (remote, host, bystander) = try await hostAndBystander(
            producer, producer, rendezvous: "alpha", recordsPerPeer: 1
        )
        for keyByte in [UInt8(0x7C), 0x7D, 0x7E] {
            _ = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote, hosts: "alpha")
        }
        XCTAssertEqual(host.bundleRequestCount, 3)
        XCTAssertEqual(bystander.bundleRequestCount, 0)
    }

    /// The record is a hint: a named session with no bundle for the block is
    /// asked first, each block, and the bundle then comes from a capable
    /// session that is not named.
    func testABlockStillArrivesWhenThePeerItsRendezvousNamesHasNoBundle() async throws {
        let producer = try await storage(keyByte: 0x77)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        let (remote, host, bystander) = try await hostAndBystander(
            try await storage(keyByte: 0x78), producer, rendezvous: "alpha"
        )
        for (count, keyByte) in [(1, UInt8(0x79)), (2, 0x7A)] {
            let stored = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote, hosts: "alpha")
            XCTAssertEqual(Set(stored), Set(recorded))
            XCTAssertEqual(host.bundleRequestCount, count)
            XCTAssertEqual(bystander.bundleRequestCount, count)
        }
    }

    /// A named session is held to its bundles like any other: one that never
    /// ends a bundle is asked once, and the next block's bundle is asked of
    /// the others.
    func testANamedPeerThatNeverEndsABundleIsNotAskedForTheNextBlock() async throws {
        let producer = try await storage(keyByte: 0x7F)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        let (remote, host, bystander) = try await hostAndBystander(
            producer, producer, rendezvous: "alpha", requestTimeout: .seconds(1)
        )
        host.neverEnds = true
        // The first block keeps what the bundle sent before it stalled and
        // fetches the rest per Volume; the second asks the other session.
        for (others, keyByte) in [(0, UInt8(0x80)), (1, 0x81)] {
            let stored = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote, hosts: "alpha")
            XCTAssertEqual(Set(stored), Set(recorded))
            XCTAssertEqual(host.bundleRequestCount, 1)
            XCTAssertEqual(bystander.bundleRequestCount, others)
        }
    }

    /// A session whose bundle does not end loses the capability: it is asked
    /// for one bundle, and from then on fetched from per Volume.
    func testAPeerThatNeverEndsABundleIsAskedExactlyOnce() async throws {
        let producer = try await storage(keyByte: 0x5A)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        let (client, source, serverPeer) = try await overlay(serving: producer, requestTimeout: .seconds(1))
        source.neverEnds = true
        let remote = IvyRootContentSource(ivy: client)
        remote.peerCapabilities.set([(serverPeer, [ChainHandshake.volumeBundle])])
        for keyByte in [UInt8(0x5B), 0x5C] {
            let stored = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote)
            XCTAssertEqual(Set(stored), Set(recorded))
            XCTAssertEqual(source.bundleRequestCount, 1)
        }
        XCTAssertTrue(remote.peerCapabilities.sessions(speaking: ChainHandshake.volumeBundle).isEmpty)
        // A new session of the same peer is judged by its own hello.
        let reconnected = AuthenticatedPeer(
            key: serverPeer.key, role: serverPeer.role, route: serverPeer.route,
            metadata: serverPeer.metadata, sessionID: Data(repeating: 0x77, count: 32)
        )
        remote.peerCapabilities.set([(reconnected, [ChainHandshake.volumeBundle])])
        XCTAssertEqual(remote.peerCapabilities.sessions(speaking: ChainHandshake.volumeBundle), [reconnected])
    }

    /// A bundle this node's own in-flight budget cuts short, after a Volume
    /// arrived, is not the peer's failure: the session keeps the capability
    /// and is asked again, and the block arrives per Volume.
    func testABundleCutShortByThisNodesOwnCapacityCostsThePeerNothing() async throws {
        let producer = try await storage(keyByte: 0x61)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        // Room for less than the whole bundle at once.
        var bytes = 0
        for root in recorded {
            let volume = await producer.volume(root)
            bytes += try XCTUnwrap(volume).entries.values.reduce(0) { $0 + $1.count }
        }
        let (client, source, serverPeer) = try await overlay(
            serving: producer, clientInFlightVolumeBytes: bytes - 1
        )
        let cut = await client.fetchVolumeBundle(rootCID: cid, from: [serverPeer])
        XCTAssertFalse(cut.volumes.isEmpty)
        XCTAssertFalse(cut.ended)
        XCTAssertEqual(cut.failure, .localCapacityUnavailable)

        let remote = IvyRootContentSource(ivy: client)
        remote.peerCapabilities.set([(serverPeer, [ChainHandshake.volumeBundle])])
        for (count, keyByte) in [(2, UInt8(0x62)), (3, 0x63)] {
            let stored = try await storage(keyByte: keyByte).fetchChainBody(cid, remote: remote)
            XCTAssertEqual(Set(stored), Set(recorded))
            XCTAssertEqual(source.bundleRequestCount, count)
        }
        XCTAssertEqual(remote.peerCapabilities.sessions(speaking: ChainHandshake.volumeBundle), [serverPeer])
    }

    /// Held-aside bundle Volumes and stored content share one byte budget:
    /// content the traversal stores takes it from a Volume only held aside,
    /// which is dropped and then requested like any other.
    func testHeldAsideVolumesShareTheSessionsOneByteBudget() async throws {
        let root = try content(1)
        let held = try content(2)
        let other = try content(3)
        let all = [root, held, other]
        let budget = all.reduce(0) {
            $0 + $1.cid.utf8.count + $1.data.count + IvyRootContentSource.retainedEntryOverhead
        } - 1
        let server = self.server
        let requests = Requests()
        let volume: @Sendable (String) -> AttributedVolumeResponse = { requested in
            let data = all.first { $0.cid == requested }!.data
            return AttributedVolumeResponse(rootCID: requested, entries: [requested: data], servedBy: server)
        }
        let source = IvyRootContentSource(
            maximumStorageBytes: budget,
            fetch: { requested in
                await requests.volume(requested)
                return volume(requested)
            },
            fetchBundle: { _ in [volume(root.cid), volume(held.cid)] }
        )
        let result = await source.withRootTracing(root.cid) { session in
            let first = await session.fetch([root.cid])
            let second = await session.fetch([other.cid])
            let third = await session.fetch([held.cid])
            return (first, second, third)
        }
        XCTAssertEqual(result.value.0, [root.cid: root.data])
        XCTAssertEqual(result.value.1, [other.cid: other.data])
        // Stored content left no room for the held Volume: it was dropped,
        // so the traversal requested it, and the budget declined it once.
        XCTAssertEqual(result.value.2, [:])
        XCTAssertTrue(result.attribution.byteBudgetExceeded)
        let volumes = await requests.volumes
        XCTAssertEqual(volumes, [other.cid, held.cid])
    }

    /// A capable peer answers every bundle with a Volume that verifies and
    /// lacks part of the block; an honest peer holds the block and speaks no
    /// bundles. The runtime's retry asks for no bundle, and the block completes.
    func testARetryAsksForNoBundleSoABadBundleCannotWithholdABlock() async throws {
        let producer = try await storage(keyByte: 0x5D)
        let joiner = try await storage(keyByte: 0x5E)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        let blockBytes = await producer.content([cid])[cid]
        let partial = AttributedVolumeResponse(
            rootCID: cid, entries: [cid: try XCTUnwrap(blockBytes)], servedBy: server
        )
        let requests = Requests()
        let honest = NodeStorageIvyContentSource(storage: producer)
        let poisoned = IvyRootContentSource(
            fetch: { root in
                let entries = await honest.volume(rootCID: root, maxDataBytes: .max)
                guard !entries.isEmpty else { return .empty }
                return AttributedVolumeResponse(
                    rootCID: root,
                    entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.cid, $0.data) }),
                    servedBy: nil
                )
            },
            fetchBundle: { root in
                await requests.bundle(root)
                return [partial]
            }
        )
        // The loop the runtime fetches a body with: the first attempt fails
        // on the partial bundle, the second is made without one.
        var attempts: [Bool] = []
        var failures = 0
        let stored = await NodeRuntime.retryingBody { bundle in
            // A third attempt is a failure, not a wait.
            if attempts.count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            try Task.checkCancellation()
            attempts.append(bundle)
            return try await joiner.fetchChainBody(cid, remote: poisoned, bundle: bundle)
        } waiting: { _ in failures += 1 }
        XCTAssertEqual(Set(try XCTUnwrap(stored)), Set(recorded))
        XCTAssertEqual(attempts, [true, false])
        XCTAssertEqual(failures, 1)
        let bundles = await requests.bundles
        XCTAssertEqual(bundles, [cid])
    }

    /// A cache that cannot be opened costs recorded bundles and nothing else.
    func testABrokenBundleCacheStopsNeitherBootNorMiningNorFetching() async throws {
        let producer = try await storage(keyByte: 0x5F, brokenCache: true)
        let joiner = try await storage(keyByte: 0x60, brokenCache: true)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        XCTAssertNil(producer.bundles.bundle(root: cid))
        // Unrecorded, the bundle is still walked from local content.
        let walked = await producer.volumeBundle(cid)
        XCTAssertEqual(walked.first, cid)
        let requests = Requests()
        let stored = try await joiner.fetchChainBody(cid, remote: remote(producer, requests: requests))
        XCTAssertEqual(Set(stored), Set(walked))
        let volumes = await requests.volumes
        XCTAssertEqual(volumes, [])
    }

    /// A cache that opens and then cannot be written costs the record and
    /// nothing else: the fetched block is stored whole.
    func testABundleCacheThatCannotBeWrittenLeavesAFetchedBlockStored() async throws {
        let producer = try await storage(keyByte: 0x64)
        let joiner = try await storage(keyByte: 0x65)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)
        try NodeSQLite(
            path: joiner.configuration.storagePath.appendingPathComponent(VolumeBundleCache.fileName).path
        ).execute("DROP TABLE volume_bundles")

        let stored = try await joiner.fetchChainBody(cid, remote: remote(producer, requests: Requests()))

        XCTAssertEqual(Set(stored), Set(recorded))
        XCTAssertNil(joiner.bundles.bundle(root: cid))
        for root in recorded {
            let held = await joiner.volume(root)
            XCTAssertNotNil(held, root)
        }
    }
}
