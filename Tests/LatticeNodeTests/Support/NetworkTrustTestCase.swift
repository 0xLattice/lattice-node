import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// Shared fixtures for the network-trust suites: an overlay runtime with
/// its process, scripted peers and hellos, canonical Nexus blocks and the
/// bounded waiters every suite polls with.
class NetworkTrustTestCase: XCTestCase {
    let nexusCID = "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let minimumRootWork = String(repeating: "0", count: 63) + "1"

    func overlayRuntime(
        keyByte: UInt8,
        requestTimeout: Duration,
        bootstrapPeers: [PeerEndpoint] = [],
        publicReadURL: String? = nil
    ) async throws -> (
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-overlay-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate(),
            publicReadURL: publicReadURL
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    bootstrapPeers: bootstrapPeers,
                    requestTimeout: requestTimeout,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let peerID = PeerID(publicKey: configuration.processPublicKey)
        return (
            runtime,
            process,
            peerID,
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ),
            try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
        )
    }

    func connectAndHello(
        _ peer: Ivy,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) async throws {
        try await peer.start()
        try await peer.connect(to: endpoint)
        for _ in 0..<100 {
            if (await peer.connectedPeers).contains(peerID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (await peer.connectedPeers).contains(peerID),
              case .enqueued = await peer.sendMessage(
                to: peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: hello
              ) else {
            throw NetworkTestError.failedStart
        }
    }

    func envelope(parentPath: [String]) throws -> ChildValidationPackageEnvelope {
        try ChildValidationPackageEnvelope(ChildValidationPackage(
            proof: proof()
        ))
    }

    func proof() -> ChildBlockProof {
        ChildBlockProof(
            rootCID: "proof-root",
            directoryPath: ["Payments"],
            entries: []
        )
    }

    /// Mine `depth` empty blocks on a fresh producer and weighed-admit them on
    /// `process` straight at the process (no commit publisher, so no walk
    /// fires): `process` then HOLDS the chain to `depth` while its validated
    /// tip stays at genesis — the deferred-execution catch-up state.
    func weighedChain(
        on process: ChainProcess,
        depth: Int
    ) async throws -> [Block] {
        let producer = try await canonicalNetworkProcess()
        let clock = TestBlockClock()
        var parent = try await producer.canonicalTipBlock()
        var blocks: [Block] = []
        for _ in 0..<depth {
            parent = try await acceptNexusBlock(
                on: parent,
                process: producer,
                timestamp: clock.next()
            )
            blocks.append(parent)
            let outcome = try await process.importBlock(
                BlockHeader(node: parent),
                remoteSource: FetcherContentSource(producer),
                mode: .header
            )
            guard outcome.decision.isAccepted else {
                throw NetworkTestError.failedPhase(
                    "weighed admit rejected: \(outcome.decision)"
                )
            }
        }
        return blocks
    }

    /// Strictly increasing, slightly-past block timestamps (admission is
    /// `timestamp <= now`).
    final class TestBlockClock {
        private var current = Int64(Date().timeIntervalSince1970 * 1_000) - 5_000
        func next() -> Int64 {
            current += 100
            return current
        }
    }

    /// Build an empty block on `parent`, grind its (max-target) nonce, and
    /// accept it eagerly on `process` — a producer's own history.
    func acceptNexusBlock(
        on parent: Block,
        process: ChainProcess,
        timestamp: Int64
    ) async throws -> Block {
        var nonce: UInt64 = 0
        var block = try await BlockBuilder.buildBlock(
            previous: parent,
            timestamp: timestamp,
            nonce: nonce,
            fetcher: process
        )
        while block.proofOfWorkHash() > block.target {
            nonce += 1
            block = try await BlockBuilder.buildBlock(
                previous: parent,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: process
            )
        }
        let outcome = try await process.importBlock(BlockHeader(node: block))
        guard outcome.decision.isAccepted else {
            throw NetworkTestError.failedPhase(
                "producer block rejected: \(outcome.decision)"
            )
        }
        return block
    }

    func canonicalNetworkBlock() async throws -> Block {
        let process = try await canonicalNetworkProcess()
        return try await process.canonicalTipBlock()
    }

    func canonicalNetworkBlockVolumes(
        count: Int
    ) async throws -> [SerializedVolume] {
        let process = try await canonicalNetworkProcess()
        var previous = try await process.canonicalTipBlock()
        var volumes: [SerializedVolume] = []
        for step in 1...count {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: Int64(step),
                nonce: UInt64(step),
                fetcher: process
            )
            let header = try BlockHeader(node: block)
            try await header.storeBlock(fetcher: process, storer: process)
            let volume = await process.volume(header.rawCID)
            volumes.append(try XCTUnwrap(volume))
            previous = block
        }
        return volumes
    }

    func canonicalNetworkProcess() async throws -> ChainProcess {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-block-\(UUID().uuidString)",
            isDirectory: true
        )
        return try await ChainProcess.open(configuration: try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5a", count: 32)
        ))
    }

    func unsignedTransaction(
        path: [String],
        genesisActions: [GenesisAction] = []
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: genesisActions,
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: path
        )
        return Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
    }

    func networkService(
        process: ChainProcess,
        runtime: NodeNetworkRuntime,
        acceptedBlockRecorder: NetworkEventRecorder? = nil
    ) -> ChainService {
        ChainService(
            process: process,
            network: ClosureNetworkInterface(
                childCandidateProvider: { [weak runtime] context in
                    guard let runtime else { return [] }
                    return await runtime.directChildCandidates(context)
                },
                chainStateChangePublisher: { [weak runtime] in
                    await runtime?.chainStateChanged()
                },
                childProofPublisher: { [weak runtime] publication in
                    guard let runtime else { throw CancellationError() }
                    _ = try await runtime.publishChildProof(
                        publication.proof,
                        childDirectory: publication.directory,
                        childCID: publication.childCID
                    )
                },
                acceptedBlockPublisher: { [weak runtime] blockCID in
                    await acceptedBlockRecorder?.append(blockCID)
                    guard let runtime else { throw CancellationError() }
                    try await runtime.publishAcceptedBlock(blockCID)
                },
                acceptedTransactionPublisher: { [weak runtime] rootCID in
                    guard let runtime else { throw CancellationError() }
                    try await runtime.publishTransaction(rootCID)
                },
                // Mirror the daemon: a weighed admit stored only the boundary, so the
                // validate walk pulls the deferred body over the network.
                executionBodySource: { [weak runtime] blockCID, admit in
                    guard let runtime else { throw CancellationError() }
                    return try await runtime.remoteContentSource
                        .withRoot(blockCID) { session in
                            try await admit(session)
                        }
                }
            ),
            parentLevel: runtime.parentLevel
        )
    }

    /// Handlers that pass the runtime's admission tier through (as the daemon
    /// does); `admissions` records each attempt as `<cid>|weighed` or
    /// `<cid>|eager`.
    func transactionServiceHandlers(
        _ service: ChainService,
        inventoryRequests: NetworkEventRecorder? = nil,
        transactions: NetworkEventRecorder? = nil,
        admissions: NetworkEventRecorder? = nil
    ) -> ClosureChainInterface {
        ClosureChainInterface(
            admission: { [weak service] admission in
                guard let service else { throw CancellationError() }
                await admissions?.append(
                    "\(admission.header.rawCID)|"
                        + (admission.weighed ? "weighed" : "eager")
                )
                return try await service.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            },
            transaction: { [weak service] transaction in
                guard let service else { throw CancellationError() }
                await transactions?.append("attempt")
                let inserted = try await service.submitNetworkTransaction(transaction)
                await transactions?.append("accepted")
                return inserted
            },
            transactionInventory: { [weak service] in
                guard let service else { return [] }
                await inventoryRequests?.append("request")
                return await service.transactionInventoryRoots()
            }
        )
    }

    func waitForTopic(
        _ topic: String,
        in recorder: TopicRecorder
    ) async throws {
        try await eventually("topic \(topic)") { await recorder.contains(topic) }
    }

    func waitForEvent(
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request"
    ) async throws {
        try await waitForEventCount(1, in: recorder, phase: phase)
    }

    func waitForEventCount(
        _ count: Int,
        in recorder: NetworkEventRecorder,
        phase: String = "transaction inventory request"
    ) async throws {
        try await eventually(phase) { (await recorder.snapshot()).count >= count }
    }

    func waitForMempoolCount(
        _ count: Int,
        service: ChainService,
        phase: String = "transaction mempool"
    ) async throws {
        try await eventually(phase) { await service.status().mempoolCount == count }
    }

    func signedNetworkTransaction(chainPath: [String]) throws -> Transaction {
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: key.privateKey
        ) else { throw NetworkTestError.failedStart }
        return Transaction(
            signatures: [key.publicKey: signature],
            body: header
        )
    }

    func transactionVolume(
        _ transaction: Transaction
    ) async throws -> SerializedVolume {
        let store = InMemoryContentStore()
        let volume = try VolumeImpl<Transaction>(node: transaction)
        try await volume.storeRecursively(storer: store)
        let serialized = SerializedVolume(
            root: volume.rawCID,
            entries: await store.allEntries()
        )
        try serialized.validate()
        return serialized
    }

    func hierarchyRetryFixture(
        keyByte: UInt8,
        summary: IssuedChildEvidenceSummary?,
        withholdFirstHello: Bool = false
    ) async throws -> HierarchyRetryFixture {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-hierarchy-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        let parentKey = signingKey(keyByte)
        let parentPeerKey = peerKey(parentKey)
        let parentPort = NetworkTransportTestPorts.allocate()
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus", "Retry"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        ).withParentEndpoint(ParentEndpoint(
            publicKey: parentPeerKey.hex,
            host: "127.0.0.1",
            port: parentPort
        ))
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    stunServers: [],
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    bootstrapPeers: [configuration.parentEndpoint!.ivy],
                    inboundAdmissionBypassPeerKeys: [parentPeerKey],
                    requestTimeout: .milliseconds(100),
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let recorder = HierarchyRetryRecorder(
            withholdFirstHello: withholdFirstHello
        )
        let parent = Ivy(config: IvyConfig(
            signingKey: parentKey,
            listenPort: parentPort,
            stunServers: [],
            mode: .privateNetwork
        ))
        let delegate = HierarchyRetryPeer(
            recorder: recorder,
            parentHello: try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: ["Nexus"]
            ).encode(),
            summary: summary
        )
        await parent.installTestDelegate(delegate)
        return HierarchyRetryFixture(
            storage: storage,
            configuration: configuration,
            runtime: runtime,
            process: process,
            parent: parent,
            recorder: recorder,
            delegate: delegate
        )
    }

    func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

    func authenticatedPeer(
        _ key: Curve25519.Signing.PrivateKey,
        role: AuthenticatedPeerRole
    ) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: peerKey(key),
            role: role,
            route: .direct,
            metadata: PeerMetadata()
        )
    }
}
