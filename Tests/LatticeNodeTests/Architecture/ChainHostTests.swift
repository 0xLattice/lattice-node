import Foundation
import Ivy
import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// One process hosting Nexus and a child: the child is wired to its co-hosted
/// parent over loopback, activates on its deployed genesis, is carried by
/// Nexus blocks, and a child level stops without its parent.
final class ChainHostTests: XCTestCase {
    private let nexus = ChainAddress(["Nexus"])!
    private let child = ChainAddress(["Nexus", "Payments"])!
    private let grandchild = ChainAddress(["Nexus", "Payments", "Refunds"])!

    private func configure(
        _ address: ChainAddress,
        root: URL,
        keyByte: UInt8,
        listen: UInt16 = NetworkTransportTestPorts.allocate(),
        bootstrapPeers: [PeerEndpoint] = []
    ) -> ChainHost.Configure {
        let storage = root.appendingPathComponent(address.key, isDirectory: true)
        let key = String(repeating: String(format: "%02x", keyByte), count: 32)
        let fact = NetworkTransportTestPorts.allocate()
        let rpc = NetworkTransportTestPorts.allocate()
        return {
            try NodeConfiguration(
                chainPath: address.components,
                storagePath: storage,
                privateKeyHex: key,
                listenPort: listen,
                factListenPort: fact,
                rpcPort: rpc,
                bootstrapPeers: bootstrapPeers
            )
        }
    }

    /// The CID `seed` builds to for the hosted child, and the child's storage
    /// seeded with it (what `lattice child deploy` writes).
    private func seedChild(
        root: URL, timestamp: Int64
    ) async throws -> (seed: ChildGenesisSeed, genesisCID: String) {
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: timestamp
        )
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: child.components,
            fetcher: CoalescingFetcher(CompositeContentSource([MemoryBroker()]))
        )
        let childStorage = root.appendingPathComponent(child.key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: childStorage, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seed).write(
            to: childStorage.appendingPathComponent("child-genesis.json")
        )
        return (seed, try BlockHeader(node: genesis).rawCID)
    }

    /// Submits the anchor of `genesisCID` to the host's Nexus and mines until
    /// its validated tip commits it.
    private func anchor(_ genesisCID: String, on host: ChainHost) async throws {
        let parent = try await service(host, nexus)
        _ = try await parent.submitTransaction(SubmitTransactionRequest(
            transaction: try signedGenesisAnchorTransaction(
                directory: child.directory, childGenesisCID: genesisCID
            )
        ))
        try await eventually("Nexus records the anchor", within: .seconds(60)) {
            _ = try? await self.mine(parent)
            return await parent.explorerChildGenesisCID(
                directory: self.child.directory
            ) == genesisCID
        }
    }

    func testAChildIsHostedOnlyWithItsParent() {
        let root = temporaryDirectory()
        XCTAssertThrowsError(try ChainHost(chains: [
            child: configure(child, root: root, keyByte: 2),
        ])) { error in
            XCTAssertEqual(
                error as? ChainHostError,
                .notAncestorClosed(child: "Nexus/Payments", missingParent: "Nexus")
            )
        }
    }

    func testTheChildIsWiredToItsCoHostedParentOverLoopback() async throws {
        let root = temporaryDirectory()
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let parentConfiguration = await host.configuration(nexus)
        let childConfiguration = await host.configuration(child)
        let parent = try XCTUnwrap(parentConfiguration)
        XCTAssertNil(parent.parentEndpoint)
        XCTAssertEqual(
            childConfiguration?.parentEndpoint,
            ParentEndpoint(
                publicKey: parent.processPublicKey,
                host: "127.0.0.1",
                port: parent.factListenPort
            )
        )
        let paths = await host.paths
        XCTAssertEqual(paths, [nexus, child])
    }

    /// A child that cannot start (here: another writer holds its storage)
    /// is skipped and reported; the rest of the tree runs.
    func testAChildThatFailsToStartLeavesTheTreeRunning() async throws {
        let root = temporaryDirectory(create: true)
        let childStorage = root.appendingPathComponent(child.key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: childStorage, withIntermediateDirectories: true
        )
        let otherWriter = try StorageDirectoryLock(directory: childStorage)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let failed = try await host.startAll()
        XCTAssertEqual(failed.map(\.path), [child])
        let nexusRuns = await host.node(nexus) != nil
        let childRuns = await host.node(child) != nil
        XCTAssertTrue(nexusRuns)
        XCTAssertFalse(childRuns)
        await host.stopAll()
        _ = otherWriter
    }

    /// A child whose parent level is not running has no parent facts, so it
    /// is refused at start rather than run failing closed forever.
    func testAChildWhoseParentFailedToStartIsRefused() async throws {
        let root = temporaryDirectory(create: true)
        let childStorage = root.appendingPathComponent(child.key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: childStorage, withIntermediateDirectories: true
        )
        let otherWriter = try StorageDirectoryLock(directory: childStorage)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
            grandchild: configure(grandchild, root: root, keyByte: 3),
        ])
        let failed = try await host.startAll()
        XCTAssertEqual(failed.map(\.path), [child, grandchild])
        XCTAssertEqual(
            failed.last?.error as? ChainHostError,
            .parentNotRunning(child: grandchild.key, parent: child.key)
        )
        let nexusRuns = await host.node(nexus) != nil
        let grandchildRuns = await host.node(grandchild) != nil
        XCTAssertTrue(nexusRuns)
        XCTAssertFalse(grandchildRuns)
        await host.stopAll()
        _ = otherWriter
    }

    /// Stopping a mid-level stops every level below it, children first, and
    /// leaves its ancestors running.
    func testStoppingAMidLevelStopsItsDescendants() async throws {
        let root = temporaryDirectory(create: true)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
            grandchild: configure(grandchild, root: root, keyByte: 3),
        ])
        let failed = try await host.startAll()
        XCTAssertTrue(failed.isEmpty)
        let stopped = await host.stop(child)
        XCTAssertEqual(stopped, [grandchild])
        let childRuns = await host.node(child) != nil
        let grandchildRuns = await host.node(grandchild) != nil
        let nexusRuns = await host.node(nexus) != nil
        XCTAssertFalse(childRuns)
        XCTAssertFalse(grandchildRuns)
        XCTAssertTrue(nexusRuns)
        await host.stopAll()
    }

    /// The parent's own state-change publish reaches the hosted child level:
    /// a mined parent block wakes the child's parent-fact waits through the
    /// closure the host attached.
    func testAParentTipChangeReachesTheHostedChild() async throws {
        let root = temporaryDirectory(create: true)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let failed = try await host.startAll()
        XCTAssertTrue(failed.isEmpty)
        let childNode = await host.node(child)
        let childNetwork = try XCTUnwrap(childNode).network
        let before = await childNetwork.parentTipChanges
        _ = try await mine(service(host, nexus))
        try await eventually("the child hears the parent's tip move") {
            await childNetwork.parentTipChanges > before
        }
        await host.stopAll()
    }

    /// The deployed child is hosted from the start, seeded but not yet
    /// anchored: it waits, and the parent tip change that commits its anchor
    /// activates it, with no further parent block.
    func testADeployedChildActivatesIsCarriedAndStopsAlone() async throws {
        let root = temporaryDirectory(create: true)
        let (_, genesisCID) = try await seedChild(root: root, timestamp: 1_000)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let failed = try await host.startAll()
        XCTAssertTrue(failed.isEmpty)
        let awaiting = await childStatus(host)?.phase
        XCTAssertEqual(awaiting, .awaitingGenesis)
        func parent() async throws -> ChainService {
            try await service(host, nexus)
        }
        try await anchor(genesisCID, on: host)

        try await eventually("the child activates on its genesis", within: .seconds(60)) {
            let status = await self.childStatus(host)
            return status?.phase == .active && status?.tipCID == genesisCID
        }

        // Nexus blocks carry the child's candidate.
        try await eventually("a carried child block is admitted", within: .seconds(120)) {
            _ = try? await self.mine(parent())
            return (await self.childStatus(host)?.height ?? 0) >= 1
        }

        // The child stops, as the host contains a failed level; Nexus keeps
        // mining.
        await host.stop(child)
        let stoppedChild = await host.node(child)
        XCTAssertNil(stoppedChild)
        let before = try await parent().status().height ?? 0
        _ = try await mine(parent())
        let after = try await parent().status().height ?? 0
        XCTAssertGreaterThan(after, before)

        await host.stopAll()
    }

    /// A seed that rebuilds to another genesis than the one the parent
    /// anchored (a corrected re-deploy the seed file missed) never activates,
    /// however often the parent's tip moves.
    func testASeedThatIsNotTheAnchoredGenesisDoesNotActivate() async throws {
        let root = temporaryDirectory(create: true)
        _ = try await seedChild(root: root, timestamp: 1_000)
        let other = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 2_000
        )
        let anchored = try BlockHeader(node: await ChildGenesisBuilder.build(
            seed: other,
            chainPath: child.components,
            fetcher: CoalescingFetcher(CompositeContentSource([MemoryBroker()]))
        )).rawCID
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let failed = try await host.startAll()
        XCTAssertTrue(failed.isEmpty)
        try await anchor(anchored, on: host)

        let childNode = await host.node(child)
        let childNetwork = try XCTUnwrap(childNode).network
        let before = await childNetwork.parentTipChanges
        for _ in 0..<3 { _ = try await mine(service(host, nexus)) }
        try await eventually("the child hears the parent's later blocks") {
            await childNetwork.parentTipChanges >= before + 3
        }
        // Let the last trigger's attempt finish.
        try await Task.sleep(for: .milliseconds(500))
        let phase = await childStatus(host)?.phase
        XCTAssertEqual(phase, .awaitingGenesis)

        await host.stopAll()
    }

    /// A node that adopted the child holds no seed: it fetches the anchored
    /// genesis from a child-overlay provider (here the deployer's host) once
    /// its own Nexus has synced the anchor.
    func testAnAdoptedChildFetchesItsAnchoredGenesis() async throws {
        try await adoptFromDeployer(staleSeed: false)
    }

    /// A seed that is unusable here (it builds another CID than the anchored
    /// one) does not strand the child: it falls back to fetching the
    /// anchored genesis from a provider.
    func testAStaleSeedFallsBackToFetchingTheAnchoredGenesis() async throws {
        try await adoptFromDeployer(staleSeed: true)
    }

    /// A deployer host activates the child from its seed; an adopter host,
    /// peered with it on both levels, activates the same genesis by fetch.
    private func adoptFromDeployer(staleSeed: Bool) async throws {
        let deployerRoot = temporaryDirectory(create: true)
        let (_, genesisCID) = try await seedChild(
            root: deployerRoot, timestamp: 1_000
        )
        let deployerNexusPort = NetworkTransportTestPorts.allocate()
        let deployerChildPort = NetworkTransportTestPorts.allocate()
        let deployer = try ChainHost(chains: [
            nexus: configure(
                nexus, root: deployerRoot, keyByte: 1, listen: deployerNexusPort
            ),
            child: configure(
                child, root: deployerRoot, keyByte: 2, listen: deployerChildPort
            ),
        ])
        var failed = try await deployer.startAll()
        XCTAssertTrue(failed.isEmpty)
        try await anchor(genesisCID, on: deployer)
        try await eventually("the deployer's child activates", within: .seconds(60)) {
            await self.childStatus(deployer)?.phase == .active
        }

        func endpoint(_ host: ChainHost, _ address: ChainAddress, _ port: UInt16)
            async throws -> PeerEndpoint {
            let configuration = await host.configuration(address)
            return PeerEndpoint(
                publicKey: try XCTUnwrap(configuration).processPublicKey,
                host: "127.0.0.1",
                port: port
            )
        }
        let adopterRoot = temporaryDirectory(create: true)
        if staleSeed {
            _ = try await seedChild(root: adopterRoot, timestamp: 2_000)
        }
        let nexusPeer = try await endpoint(deployer, nexus, deployerNexusPort)
        let childPeer = try await endpoint(deployer, child, deployerChildPort)
        let adopter = try ChainHost(chains: [
            nexus: configure(
                nexus, root: adopterRoot, keyByte: 3, bootstrapPeers: [nexusPeer]
            ),
            child: configure(
                child, root: adopterRoot, keyByte: 4, bootstrapPeers: [childPeer]
            ),
        ])
        failed = try await adopter.startAll()
        XCTAssertTrue(failed.isEmpty)
        try await eventually(
            "the adopted child fetches its genesis",
            within: .seconds(120),
            poll: .milliseconds(500)
        ) {
            // Each deployer block the adopter's Nexus syncs is a trigger.
            _ = try? await self.mine(self.service(deployer, self.nexus))
            let status = await self.childStatus(adopter)
            return status?.phase == .active && status?.tipCID == genesisCID
        }

        await adopter.stopAll()
        await deployer.stopAll()
    }

    /// Stopping a level joins its genesis activation attempt: an attempt in
    /// flight at stop neither outlives the level (the storage opens again at
    /// once in this process) nor persists the genesis after it stopped.
    func testStoppingALevelJoinsItsGenesisActivation() async throws {
        let root = temporaryDirectory(create: true)
        let (_, genesisCID) = try await seedChild(root: root, timestamp: 1_000)
        let parentKey = String(repeating: "01", count: 32)
        let configuration = try configure(child, root: root, keyByte: 2)()
            .withParentEndpoint(ParentEndpoint(
                publicKey: try NodeConfiguration(
                    chainPath: nexus.components,
                    storagePath: root.appendingPathComponent("unused"),
                    privateKeyHex: parentKey,
                    listenPort: 1, factListenPort: 2, rpcPort: 3
                ).processPublicKey,
                host: "127.0.0.1",
                port: NetworkTransportTestPorts.allocate()
            ))
        let parent = GatedAnchorParentLevel(genesisCID: genesisCID)
        // Scoped, so nothing but the level's own tasks holds its process
        // once it has stopped.
        do {
            let node = try await LatticeNode.Node.build(
                configuration: configuration, parentLevel: parent
            )
            try await eventually("an activation attempt is in flight") {
                await parent.asked
            }
            let stopped = Task { await node.shutdown() }
            // The attempt is still parked on the parent's read while stop
            // waits for it.
            try await Task.sleep(for: .milliseconds(200))
            await parent.gate.open()
            await stopped.value
        }

        let reopened = try await ChainProcess.open(configuration: configuration)
        let phase = await reopened.status().phase
        XCTAssertEqual(phase, .awaitingGenesis)
    }

    private func service(
        _ host: ChainHost, _ address: ChainAddress
    ) async throws -> ChainService {
        let node = await host.node(address)
        return try XCTUnwrap(node).service
    }

    private func childStatus(_ host: ChainHost) async -> ChainServiceStatusResponse? {
        guard let node = await host.node(child) else { return nil }
        return await node.service.status()
    }

    private func mine(_ service: ChainService) async throws -> SubmitWorkResponse {
        let template = try await service.miningTemplate(
            MiningTemplateRequest(rewards: [])
        )
        return try await service.submitWork(SubmitWorkRequest(
            workID: template.workID, nonce: solvedNonce(for: template)
        ))
    }
}

/// A parent level whose anchor read parks until `gate` opens, then answers
/// `genesisCID`, which it also reports recorded.
private actor GatedAnchorParentLevel: ParentLevel {
    let genesisCID: String
    let gate = Latch()
    private(set) var asked = false

    init(genesisCID: String) {
        self.genesisCID = genesisCID
    }

    func hasProducedState(_ stateCID: String) async -> Bool { false }

    func recordedGenesisLink(
        directory: String, childGenesisCID: String
    ) async -> ParentGenesisLink? {
        guard childGenesisCID == genesisCID else { return nil }
        return ParentGenesisLink(
            parentPath: ["Nexus"],
            directory: directory,
            childGenesisCID: childGenesisCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
    }

    func anchoredGenesisCID(directory: String) async -> String? {
        asked = true
        await gate.wait()
        return genesisCID
    }

    func runReport(carrier: String, directory: String) async -> ParentRunReport? { nil }
}
