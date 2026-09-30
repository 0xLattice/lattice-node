import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
@testable import LatticeBlockTree
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private enum NetworkRuntimeStartOutcome: Equatable, Sendable {
    case started
    case failed(NodeNetworkRuntimeError)
    case unexpected(String)
}

final class NetworkTrustHierarchySessionTests: NetworkTrustTestCase {
    func testDuplicateParentQueryCannotReleaseActivePeerSlot() throws {
        let first = try PeerKey(
            rawRepresentation: Data(repeating: 1, count: PeerKey.byteCount)
        )
        let second = try PeerKey(
            rawRepresentation: Data(repeating: 2, count: PeerKey.byteCount)
        )
        var guardState = ParentStateQueryGuard(capacity: 1)

        let held = try XCTUnwrap(guardState.acquire(first))
        XCTAssertNil(guardState.acquire(first))
        XCTAssertNil(guardState.acquire(second))
        XCTAssertEqual(Set(guardState.peers.keys), [first])

        guardState.release(held)
        XCTAssertNotNil(guardState.acquire(second))
    }

    func testChainHelloPinsProtocolIdentityButNotLocalWorkFloor() throws {
        let hello = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"]
        )
        let encoded = try hello.encode()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("minimumRootWork"))
        let decoded = try ChainHello.decode(encoded)
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))

        XCTAssertThrowsError(try decoded.validateCompatibility(
            expectedNexusGenesisCID: "different-nexus",
            expectedChainPath: ["Nexus"]
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .wrongNexusGenesis)
        }

        let legacy = try JSONDecoder().decode(
            ChainHello.self,
            from: try JSONSerialization.data(withJSONObject: [
                "version": ChainHello.protocolVersion - 1,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
                "minimumRootWorkHex": minimumRootWork,
            ])
        )
        XCTAssertThrowsError(try legacy.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        )) { error in
            XCTAssertEqual(error as? ChainHelloError, .incompatibleProtocol)
        }

    }

    func testOverlayHelloDeadlineAndOneShotAuthorization() async throws {
        let fixture = try await overlayRuntime(
            keyByte: 0x7b,
            requestTimeout: .milliseconds(150)
        )
        let silent = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7c),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let authorizedDelegate = OverlayAnnouncingPeer(announcing: [])
        let authorized = Ivy(config: IvyConfig(
            signingKey: signingKey(0x7d),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        await authorized.installTestDelegate(authorizedDelegate)

        do {
            try await fixture.runtime.start(
                process: fixture.process,
                chain: inertNetworkHandlers()
            )
            try await silent.start()
            try await silent.connect(to: fixture.endpoint)
            for _ in 0..<100 {
                if (await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertTrue(silentConnected)
            for _ in 0..<100 {
                if !(await silent.connectedPeers).contains(fixture.peerID) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let silentStillConnected = await silent.connectedPeers
                .contains(fixture.peerID)
            XCTAssertFalse(silentStillConnected)
            await silent.stop()

            try await connectAndHello(
                authorized,
                peerID: fixture.peerID,
                endpoint: fixture.endpoint,
                hello: fixture.hello
            )
            for _ in 0..<100 {
                if await authorizedDelegate.authorizedSessionCount() == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let initialRequests = await authorizedDelegate.authorizedSessionCount()
            XCTAssertEqual(initialRequests, 1)

            guard case .enqueued = await authorized.sendMessage(
                to: fixture.peerID,
                topic: NodeNetworkTopic.overlayHello,
                payload: fixture.hello
            ) else {
                throw NetworkTestError.failedSend
            }
            try await alwaysDuring("a second hello opens no second session", .milliseconds(300)) {
                await authorizedDelegate.authorizedSessionCount() == 1
            }
            let finalRequests = await authorizedDelegate.authorizedSessionCount()
            let authorizedConnected = await authorized.connectedPeers
                .contains(fixture.peerID)
            XCTAssertEqual(finalRequests, 1)
            XCTAssertTrue(authorizedConnected)
        } catch {
            await authorized.stop()
            await silent.stop()
            await fixture.runtime.stop()
            throw error
        }
        await authorized.stop()
        await silent.stop()
        await fixture.runtime.stop()
    }

    func testRestartRecoversAcceptedOrphanOnlyAfterLocalAttachment()
        async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recovery-suffix-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "6d", count: 32),
            listenPort: overlayPort,
            rpcPort: rpcPort
        )

        // Persist P (not admitted) -> O (accepted orphan: its height-1 parent
        // in hand anchors it) -> D (not admitted: its parent is held but
        // disconnected and its grandparent unknown, so admission cannot
        // anchor it and asks for its predecessor), then reopen. Replaying the
        // remote leaf D must park it behind P — the deepest missing ancestor,
        // not its held parent O — and wake O and D once P connects.
        var stagingProcess: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let genesis = try await stagingProcess!.canonicalTipBlock()
        let predecessorCandidate = try await BlockBuilder.buildBlock(
            previous: genesis,
            timestamp: 3_600_000,
            nonce: 1,
            fetcher: stagingProcess!
        )
        let predecessor = try XCTUnwrap(BlockBuilder.mine(
            block: predecessorCandidate,
            target: predecessorCandidate.target,
            maxAttempts: 4_096
        ))
        let predecessorHeader = try BlockHeader(node: predecessor)
        try await predecessorHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let orphanCandidate = try await BlockBuilder.buildBlock(
            previous: predecessor,
            timestamp: 7_200_000,
            nonce: 2,
            fetcher: stagingProcess!
        )
        let orphan = try XCTUnwrap(BlockBuilder.mine(
            block: orphanCandidate,
            target: orphanCandidate.target,
            maxAttempts: 4_096
        ))
        let orphanHeader = try BlockHeader(node: orphan)
        try await orphanHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let descendantCandidate = try await BlockBuilder.buildBlock(
            previous: orphan,
            timestamp: 10_800_000,
            nonce: 3,
            fetcher: stagingProcess!
        )
        let descendant = try XCTUnwrap(BlockBuilder.mine(
            block: descendantCandidate,
            target: descendantCandidate.target,
            maxAttempts: 4_096
        ))
        let descendantHeader = try BlockHeader(node: descendant)
        try await descendantHeader.storeBlock(
            fetcher: stagingProcess!,
            storer: stagingProcess!
        )
        let remoteContent = InMemoryContentStore()
        for header in [predecessorHeader, orphanHeader, descendantHeader] {
            try await header.storeBlock(
                fetcher: stagingProcess!,
                storer: remoteContent
            )
        }
        let orphanAdmission = try await stagingProcess!.importBlock(orphanHeader)
        let descendantAdmission = try await stagingProcess!.importBlock(descendantHeader)
        guard case .acceptedSide = orphanAdmission.decision else {
            return XCTFail("expected an accepted orphan, got \(orphanAdmission.decision)")
        }
        XCTAssertEqual(descendantAdmission.decision, .unavailable(nil))
        XCTAssertEqual(
            orphanAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: predecessorHeader.rawCID
            )
        )
        XCTAssertEqual(
            descendantAdmission.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: descendantHeader.rawCID,
                predecessorCID: orphanHeader.rawCID
            )
        )
        stagingProcess = nil

        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                stunServers: [],
                mode: .overlay
            )
)
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let recoveredProcess = try await ChainProcess.open(
            configuration: configuration
        )
        let recoveredRequirements = await recoveredProcess
            .unresolvedSameChainPredecessors()
        XCTAssertEqual(
            recoveredRequirements,
            [
                SameChainPredecessorRequirement(
                    descendantCID: orphanHeader.rawCID,
                    predecessorCID: predecessorHeader.rawCID
                ),
            ]
        )

        let handlers = ClosureChainInterface(admission: { admission in
            try await recoveredProcess.importBlock(
                admission.header,
                authenticatedChildPackage:
                    admission.authenticatedChildPackage,
                remoteSource: admission.contentSource
            )
        })
        let clientDelegate = OverlayAnnouncingPeer(
            announcing: [descendantHeader.rawCID]
        )
        let client = Ivy(config: IvyConfig(
            signingKey: signingKey(96),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        await client.installTestDelegate(clientDelegate)
        await client.setContentSource(remoteContent)

        do {
            try await runtime.start(
                process: recoveredProcess,
                chain: handlers
            )
            try await client.start()
            let runtimePeer = PeerID(publicKey: configuration.processPublicKey)
            try await client.connect(to: PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ))
            for _ in 0..<100 {
                if (await client.connectedPeers).contains(runtimePeer) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard (await client.connectedPeers).contains(runtimePeer) else {
                throw NetworkTestError.failedStart
            }
            guard case .enqueued = await client.sendMessage(
                to: runtimePeer,
                topic: NodeNetworkTopic.overlayHello,
                payload: try ChainHello(
                    nexusGenesisCID: configuration.nexusGenesisCID,
                    chainPath: configuration.chainPath
                ).encode()
            ) else {
                throw NetworkTestError.failedSend
            }
            for _ in 0..<200 {
                if await recoveredProcess.status().tipCID
                    == descendantHeader.rawCID {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let recoveredStatus = await recoveredProcess.status()
            XCTAssertEqual(recoveredStatus.tipCID, descendantHeader.rawCID)
            XCTAssertEqual(recoveredStatus.height, descendant.height)
        } catch {
            await client.stop()
            await runtime.stop()
            throw error
        }
        await client.stop()
        await runtime.stop()
    }

    /// Quiet network: the peer holding P connects after startup and says
    /// only its hello and its tip claim. Its tip D is already held here, so
    /// the gap test sees no gap; the parked ancestry makes the node page the
    /// peer's chain from the fork point, and P arrives from the peer that
    /// claimed it.
    func testRestartRecoversLegacyDurableOrphanSuffixInConnectionOrder()
        async throws
    {
        try await assertLegacyOrphanSuffixRecovers(
            peers: [.holder], expectsRangeSync: true
        )
    }

    /// The same with the node's own tip ahead of the fork point, so the
    /// peer's claim is at our edge, not beyond it.
    func testParkedAncestryIsPagedFromAPeerAtOurEdge() async throws {
        try await assertLegacyOrphanSuffixRecovers(
            peers: [.holder], canonicalAhead: true, expectsRangeSync: true
        )
    }

    /// No peer at all, P's bytes held locally: startup itself must run the
    /// recovered frontier, since no later event ever starts the worker.
    func testRestartRunsRecoveredFrontierWithoutAnyPeer() async throws {
        try await assertLegacyOrphanSuffixRecovers(peers: [])
    }

    /// A session that claims nothing says hello first; it is never asked,
    /// and the holder's claim that follows brings P.
    func testRecoveredFrontierReachesAHolderAfterASessionThatLacksIt()
        async throws
    {
        try await assertLegacyOrphanSuffixRecovers(
            peers: [.lacking, .holder], expectsRangeSync: true
        )
    }

    /// Two sessions claim their tips at startup: the first takes the range-
    /// sync slot and answers no range request, so the holder's claim meets a
    /// busy slot. Its claim stays recorded and unasked; when the range sync's
    /// own response and progress timeouts release the slot, the re-entry
    /// probe asks the holder, and P arrives from it.
    func testHolderClaimThatMetABusySlotIsAskedWhenTheSlotClears() async throws {
        try await assertLegacyOrphanSuffixRecovers(
            peers: [.silent, .holder],
            expectsRangeSync: true,
            requestTimeout: .seconds(1),
            within: .seconds(60)
        )
    }

    /// Claims are asked oldest first. The holder claims while a silent
    /// session holds the slot; that session's key sorts first, and it
    /// reconnects over and over, each time with a fresh, unasked claim. The
    /// holder's older claim is still asked when the slot next clears.
    func testReconnectingSessionCannotJumpAnOlderClaim() async throws {
        let holderKey = peerKey(signingKey(97)).hex
        let smaller = try XCTUnwrap(
            (UInt8(1)...UInt8(255)).first {
                $0 != 97 && peerKey(signingKey($0)).hex < holderKey
            }
        )
        try await assertLegacyOrphanSuffixRecovers(
            peers: [.silent, .holder],
            keyBytes: [smaller, 97],
            silentReconnectsEvery: .seconds(2),
            expectsRangeSync: true,
            requestTimeout: .seconds(1),
            within: .seconds(20)
        )
    }

    /// Keeps a reconnecting peer's sessions (and their weakly held
    /// delegates) alive until teardown.
    private actor ReconnectedClients {
        private(set) var clients: [Ivy] = []
        private var delegates: [any IvyDelegate] = []
        func append(_ client: Ivy, _ delegate: any IvyDelegate) {
            clients.append(client)
            delegates.append(delegate)
        }
    }

    private enum RecoveryPeer {
        /// Claims its tip and serves its chain's ranges and Volumes.
        case holder
        /// Says hello and nothing else.
        case lacking
        /// Claims the holder's tip, then answers no range request.
        case silent
    }

    /// `peers` connect after startup in order, each saying its hello (and,
    /// by role, its tip claim). With none, P's bytes are held locally
    /// instead. `canonicalAhead`: the node's own main chain holds a block at
    /// height 1 besides the suffix, so a peer claiming D is at our edge.
    /// `expectsRangeSync`: the holder must be sent a range request before P
    /// is admitted — the claim, not any fallback, brought P. The holder
    /// serves P's Volume only after that request, so no other path can
    /// admit P first.
    private func assertLegacyOrphanSuffixRecovers(
        peers: [RecoveryPeer],
        canonicalAhead: Bool = false,
        keyBytes: [UInt8]? = nil,
        silentReconnectsEvery: Duration? = nil,
        expectsRangeSync: Bool = false,
        requestTimeout: Duration = .seconds(15),
        within deadline: Duration = .seconds(10)
    ) async throws {
        let predecessorHeldLocally = peers.isEmpty
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-recovery-suffix-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let rpcPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "6d", count: 32),
            listenPort: overlayPort,
            rpcPort: rpcPort
        )

        // A store written before admission stopped walking ancestry (Lattice
        // 37.0.0) can hold a multi-block durable orphan suffix: P (not
        // admitted) <- O <- D, both accepted side blocks. Admission no longer
        // produces D, so stage both facts directly, as that node durably
        // wrote them, then reopen in place. Recovery must seed D parked
        // behind O and O behind P; P connecting wakes O, and O connecting
        // wakes D, which reaches the tip.
        var stagingProcess: ChainProcess? = try await ChainProcess.open(
            configuration: configuration
        )
        let genesis = try await stagingProcess!.canonicalTipBlock()
        // This node held the boundaries of the two side blocks it accepted,
        // O and D; P's bytes only when `predecessorHeldLocally`, otherwise
        // only the peer holds them.
        let remoteContent = InMemoryContentStore()
        var building: CoalescingFetcher? = CoalescingFetcher(CompositeContentSource([
            stagingProcess!, remoteContent,
        ]))
        func mined(on previous: Block, timestamp: Int64, nonce: UInt64) async throws
            -> (Block, BlockHeader)
        {
            let candidate = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: timestamp,
                nonce: nonce,
                fetcher: building!
            )
            let block = try XCTUnwrap(BlockBuilder.mine(
                block: candidate,
                target: candidate.target,
                maxAttempts: 4_096
            ))
            let header = try BlockHeader(node: block)
            try await header.storeBlock(fetcher: building!, storer: remoteContent)
            return (block, header)
        }
        let (predecessor, predecessorHeader) = try await mined(
            on: genesis, timestamp: 3_600_000, nonce: 1
        )
        let (orphan, orphanHeader) = try await mined(
            on: predecessor, timestamp: 7_200_000, nonce: 2
        )
        let (descendant, descendantHeader) = try await mined(
            on: orphan, timestamp: 10_800_000, nonce: 3
        )
        for header in [orphanHeader, descendantHeader]
            + (predecessorHeldLocally ? [predecessorHeader] : []) {
            try await header.storeBlock(fetcher: building!, storer: stagingProcess!)
        }
        if canonicalAhead {
            let (_, ahead) = try await mined(
                on: genesis, timestamp: 1_800_000, nonce: 9
            )
            try await ahead.storeBlock(fetcher: building!, storer: stagingProcess!)
            let admitted = try await stagingProcess!.importBlock(ahead)
            XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
        }
        // The facts a weighed admission wrote. A work contribution is only
        // ever read back from a store, so it is built the same way.
        struct StoredContribution: Encodable {
            let id: String
            let work: UInt256
        }
        func weighedFacts(_ block: Block, _ header: BlockHeader) throws -> [ChainFact] {
            let contribution = try JSONDecoder().decode(
                VerifiedWorkContribution.self,
                from: JSONEncoder().encode(StoredContribution(
                    id: header.rawCID,
                    work: workForTarget(block.target)
                ))
            )
            return [
                .block(ChainBlockFact(
                    blockHash: header.rawCID,
                    parentBlockHash: block.parent?.rawCID,
                    blockHeight: block.height,
                    postStateCID: block.postState.rawCID,
                    prevStateCID: block.prevState.rawCID,
                    specCID: block.spec.rawCID,
                    target: block.target.toHexString(),
                    nextTarget: block.nextTarget.toHexString(),
                    timestamp: block.timestamp,
                    stateDiff: .empty,
                    childCommitments: [:]
                )),
                .work(ChainWorkFact(
                    blockHash: header.rawCID,
                    contribution: contribution
                )),
            ]
        }
        try await stagingProcess!.store.stage(
            BlockImportBatch(facts: try weighedFacts(orphan, orphanHeader)),
            volumeRoots: []
        )
        try await stagingProcess!.store.stage(
            BlockImportBatch(facts: try weighedFacts(descendant, descendantHeader)),
            volumeRoots: []
        )
        // The staging fetcher holds the process: release both, so the
        // reopen below takes the storage lock.
        building = nil
        stagingProcess = nil

        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: overlayPort,
                requestTimeout: requestTimeout,
                stunServers: [],
                mode: .overlay
            )
)
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let recoveredProcess = try await ChainProcess.open(
            configuration: configuration
        )
        let recoveredRequirements = await recoveredProcess
            .unresolvedSameChainPredecessors()
        XCTAssertEqual(
            recoveredRequirements,
            [
                SameChainPredecessorRequirement(
                    descendantCID: descendantHeader.rawCID,
                    predecessorCID: orphanHeader.rawCID
                ),
                SameChainPredecessorRequirement(
                    descendantCID: orphanHeader.rawCID,
                    predecessorCID: predecessorHeader.rawCID
                ),
            ].sorted {
                $0.descendantCID < $1.descendantCID
            }
        )

        let connections = NetworkEventRecorder()
        // Range requests the holder receives and P's admission, in order.
        let events = NetworkEventRecorder()
        let predecessorCID = predecessorHeader.rawCID
        let handlers = ClosureChainInterface(admission: { admission in
            let outcome = try await recoveredProcess.importBlock(
                admission.header,
                authenticatedChildPackage:
                    admission.authenticatedChildPackage,
                remoteSource: admission.contentSource
            )
            if outcome.decision.isAccepted, outcome.sameChainPredecessor == nil {
                await connections.append(admission.header.rawCID)
                if admission.header.rawCID == predecessorCID {
                    await events.append("P admitted")
                }
            }
            return outcome
        })
        // A quiet network: the peers connect after startup, and nothing
        // announces a block beyond each holder's one tip claim.
        let chain = [predecessorHeader, orphanHeader, descendantHeader].map(\.rawCID)
        let genesisCID = try BlockHeader(node: genesis).rawCID
        var clients: [Ivy] = []
        // Ivy holds its delegate weakly: keep them alive for the test.
        var delegates: [any IvyDelegate] = []
        var reconnects: Task<Void, Never>?
        let reconnected = ReconnectedClients()
        for (index, role) in peers.enumerated() {
            let client = Ivy(config: IvyConfig(
                signingKey: signingKey(keyBytes?[index] ?? UInt8(96 + index)),
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            ))
            let delegate: any IvyDelegate
            switch role {
            case .holder:
                delegate = RangeServingPeer(
                    genesisCID: genesisCID, chain: chain, receiver: recoveredProcess,
                    events: events
                )
                await client.setContentSource(
                    expectsRangeSync
                        ? GatedVolumeSource(
                            base: remoteContent,
                            gatedRoot: predecessorCID,
                            opensOn: "range request",
                            events: events
                        )
                        : remoteContent
                )
            case .lacking:
                delegate = OverlayAnnouncingPeer(announcing: [])
                await client.setContentSource(InMemoryContentStore())
            case .silent:
                delegate = RangeServingPeer(
                    genesisCID: genesisCID, chain: chain, receiver: recoveredProcess,
                    servesRanges: false
                )
                await client.setContentSource(InMemoryContentStore())
            }
            await client.installTestDelegate(delegate)
            clients.append(client)
            delegates.append(delegate)
        }

        do {
            try await runtime.start(
                process: recoveredProcess,
                chain: handlers
            )
            // Startup runs the recovered frontier at once, with no session to
            // fetch it from, so it parks on content. Peers connect only
            // after that.
            if !peers.isEmpty {
                try await Task.sleep(for: .seconds(1))
            }
            let helloPayload = try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
            let runtimeKey = configuration.processPublicKey
            for client in clients {
                try await recoveryPeerConnects(
                    client, to: runtimeKey, port: overlayPort, hello: helloPayload
                )
                // Hellos land in order: this session's claim is handled
                // before the next one connects.
                try await Task.sleep(for: .milliseconds(200))
            }
            // The first (silent) peer reconnects on a period: each time a new
            // session with a fresh claim, and the old one gone.
            if let period = silentReconnectsEvery,
               let silentIndex = peers.firstIndex(of: .silent) {
                // Only Sendable lets cross into the task: the key, the first
                // session, and what each new session's delegate needs.
                let silentKey = signingKey(
                    keyBytes?[silentIndex] ?? UInt8(96 + silentIndex)
                ).rawRepresentation
                let first = clients[silentIndex]
                let chain = chain
                let genesisCID = genesisCID
                let receiver = recoveredProcess
                let reconnected = reconnected
                reconnects = Task {
                    var current = first
                    while !Task.isCancelled {
                        try? await Task.sleep(for: period)
                        guard !Task.isCancelled else { break }
                        guard let key = try? Curve25519.Signing.PrivateKey(
                            rawRepresentation: silentKey
                        ) else { break }
                        let next = Ivy(config: IvyConfig(
                            signingKey: key,
                            listenPort: 0,
                            stunServers: [],
                            mode: .overlay
                        ))
                        let delegate = RangeServingPeer(
                            genesisCID: genesisCID, chain: chain,
                            receiver: receiver, servesRanges: false
                        )
                        await next.installTestDelegate(delegate)
                        await next.setContentSource(InMemoryContentStore())
                        await current.stop()
                        try? await recoveryPeerConnects(
                            next, to: runtimeKey, port: overlayPort, hello: helloPayload
                        )
                        await reconnected.append(next, delegate)
                        current = next
                    }
                }
            }
            try await eventually("the suffix reaches the tip", within: deadline) {
                await recoveredProcess.status().tipCID == descendantHeader.rawCID
            }
            let recoveredStatus = await recoveredProcess.status()
            XCTAssertEqual(recoveredStatus.height, descendant.height)
            if expectsRangeSync {
                let order = await events.snapshot()
                XCTAssertEqual(
                    order.first, "range request",
                    "the holder's claim started a range sync before P was admitted: \(order)"
                )
            }
            // P's admission connects the durable suffix in the graph; the
            // fetcher still owes O and D their parked attempts, which it must
            // wake in connection order: P wakes O, O's completion wakes D.
            let expected = [
                predecessorHeader.rawCID, orphanHeader.rawCID, descendantHeader.rawCID,
            ]
            try await eventually("the parked suffix is woken") {
                await connections.snapshot().count >= expected.count
            }
            let connected = await connections.snapshot()
            XCTAssertEqual(
                connected, expected,
                "admitted in order: P, then the O it wakes, then the D O wakes"
            )
        } catch {
            // Await the task: a reconnect in flight at cancel still appends its
            // Ivy, which must be in the list stopped below.
            reconnects?.cancel()
            await reconnects?.value
            for client in clients + (await reconnected.clients) { await client.stop() }
            await runtime.stop()
            throw error
        }
        reconnects?.cancel()
        await reconnects?.value
        for client in clients + (await reconnected.clients) { await client.stop() }
        await runtime.stop()
        withExtendedLifetime(delegates) {}
    }

    func testRealNetworkRuntimeRestartsBothPlanesWithAtomicHandlers() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-network-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "5b", count: 32)
        )
        let planes = try NodeNetworkPlaneConfigurations(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: 0,
                stunServers: [],
                mode: .overlay
            )
)
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: planes
        )
        let process = try await ChainProcess.open(
            configuration: configuration
        )
        let handlers = inertNetworkHandlers()

        do {
            // `start` requires the complete generation value; there is no
            // running state in which admission can be installed or replaced.
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }

            var startOutcomes: [NetworkRuntimeStartOutcome] = []
            await withTaskGroup(of: NetworkRuntimeStartOutcome.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await runtime.start(
                                process: process,
                                chain: handlers
                            )
                            return .started
                        } catch let error as NodeNetworkRuntimeError {
                            return .failed(error)
                        } catch {
                            return .unexpected(String(describing: error))
                        }
                    }
                }
                for await outcome in group { startOutcomes.append(outcome) }
            }
            XCTAssertEqual(startOutcomes.filter { $0 == .started }.count, 1)
            XCTAssertEqual(
                startOutcomes.filter { $0 == .failed(.alreadyRunning) }.count,
                1
            )
            try await runtime.canonicalTipDidChange()

            await runtime.stop()
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("a stopped runtime must reject canonical-tip changes")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
            await runtime.stop()

            try await runtime.start(process: process, chain: handlers)
            try await runtime.canonicalTipDidChange()
            await runtime.stop()

            let starting = await runtime.enqueueStart(
                process: process,
                chain: handlers
            )
            await runtime.stop()
            try await starting.value
            do {
                try await runtime.canonicalTipDidChange()
                XCTFail("stop queued during start must leave the runtime stopped")
            } catch {
                XCTAssertEqual(error as? NodeNetworkRuntimeError, .notRunning)
            }
        } catch {
            await runtime.stop()
            throw error
        }
    }
}

/// Connects `client` to the runtime at `port` and sends its overlay hello.
private func recoveryPeerConnects(
    _ client: Ivy,
    to runtimeKey: String,
    port: UInt16,
    hello: Data
) async throws {
    let runtimePeer = PeerID(publicKey: runtimeKey)
    try await client.start()
    try await client.connect(to: PeerEndpoint(
        publicKey: runtimeKey,
        host: "127.0.0.1",
        port: port
    ))
    try await eventually("peer connected") {
        (await client.connectedPeers).contains(runtimePeer)
    }
    guard case .enqueued = await client.sendMessage(
        to: runtimePeer,
        topic: NodeNetworkTopic.overlayHello,
        payload: hello
    ) else {
        throw NetworkTestError.failedSend
    }
}
