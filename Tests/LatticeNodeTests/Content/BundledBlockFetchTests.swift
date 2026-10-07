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

    private func storage(keyByte: UInt8) async throws -> NodeStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-bundled-fetch-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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
        XCTAssertNil(try producer.bundles.bundle(root: genesis))
        let walked = await producer.volumeBundle(genesis)
        XCTAssertEqual(walked.first, genesis)
        XCTAssertGreaterThan(walked.count, 1)
        for root in walked {
            let held = await producer.volume(root)
            XCTAssertNotNil(held, root)
        }
        XCTAssertEqual(try producer.bundles.bundle(root: genesis), walked)
        // A root that is no block bundles only itself, and nothing is recorded.
        let body = chain.transactions[0].body.rawCID
        let alone = await producer.volumeBundle(body)
        XCTAssertEqual(alone, [body])
        XCTAssertNil(try producer.bundles.bundle(root: body))
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
        var answersBundles = true

        init(_ storage: NodeStorage) { source = NodeStorageIvyContentSource(storage: storage) }

        var bundleRequestCount: Int { lock.withLock { bundleRequests } }

        func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] { [] }

        func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
            await source.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
        }

        func volumeBundle(rootCID: String) async -> [String] {
            lock.withLock { bundleRequests += 1 }
            return answersBundles ? await source.volumeBundle(rootCID: rootCID) : []
        }
    }

    private final class Connections: IvyDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [AuthenticatedPeer] = []
        var first: AuthenticatedPeer? { lock.withLock { peers.first } }
        func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async { lock.withLock { peers.append(peer) } }
    }

    /// Over a real overlay: a peer whose hello advertised nothing is never
    /// sent a bundle request, and one that advertised bundles but holds none
    /// for the block is asked once; both times the block arrives per Volume.
    func testABundleIsAskedOnlyOfAPeerThatAdvertisedItAndTraversalCoversTheRest() async throws {
        let producer = try await storage(keyByte: 0x56)
        let cid = try BlockHeader(node: try await transferChain(by: producer).transfer).rawCID
        let recorded = await producer.volumeBundle(cid)

        func config(_ key: Curve25519.Signing.PrivateKey, _ port: UInt16) -> IvyConfig {
            IvyConfig(
                signingKey: key, listenPort: port, requestTimeout: .seconds(5), stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false), externalAddress: ("127.0.0.1", port),
                mode: .overlay
            )
        }
        let serverKey = Curve25519.Signing.PrivateKey()
        let serverPort = NetworkTransportTestPorts.allocate()
        let server = Ivy(config: config(serverKey, serverPort))
        let client = Ivy(config: config(Curve25519.Signing.PrivateKey(), NetworkTransportTestPorts.allocate()))
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
        let serverPeer = try XCTUnwrap(connections.first)
        // The client serves nothing: every fetch goes to the server.
        await client.setContentSource(nil)

        // The server's hello advertised nothing.
        let remote = IvyRootContentSource(ivy: client)
        remote.peerCapabilities.set([(serverPeer, [])])
        let plain = try await storage(keyByte: 0x57).fetchChainBody(cid, remote: remote)
        XCTAssertEqual(Set(plain), Set(recorded))
        XCTAssertEqual(source.bundleRequestCount, 0)

        // It advertised bundles, and holds none for this block.
        source.answersBundles = false
        remote.peerCapabilities.set([(serverPeer, [ChainHandshake.volumeBundle])])
        let fallback = try await storage(keyByte: 0x58).fetchChainBody(cid, remote: remote)
        XCTAssertEqual(Set(fallback), Set(recorded))
        XCTAssertEqual(source.bundleRequestCount, 1)
    }
}
