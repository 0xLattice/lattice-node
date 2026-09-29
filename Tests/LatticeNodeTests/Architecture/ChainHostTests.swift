import Foundation
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

    private func configure(
        _ address: ChainAddress, root: URL, keyByte: UInt8
    ) -> ChainHost.Configure {
        let storage = root.appendingPathComponent(address.key, isDirectory: true)
        let key = String(repeating: String(format: "%02x", keyByte), count: 32)
        let listen = NetworkTransportTestPorts.allocate()
        let fact = NetworkTransportTestPorts.allocate()
        let rpc = NetworkTransportTestPorts.allocate()
        return { parentEndpoint in
            try NodeConfiguration(
                chainPath: address.components,
                storagePath: storage,
                privateKeyHex: key,
                listenPort: listen,
                factListenPort: fact,
                rpcPort: rpc,
                parentEndpoint: parentEndpoint
            )
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

    /// The deployed child is hosted from the start, seeded but not yet
    /// anchored: it activates once its parent records the anchor.
    func testADeployedChildActivatesIsCarriedAndStopsAlone() async throws {
        let root = temporaryDirectory(create: true)

        // Deploy: build the child genesis offline and seed the child's
        // storage with it; the anchor goes to Nexus once it runs.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 1_000
        )
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: child.components,
            fetcher: CoalescingFetcher(CompositeContentSource([MemoryBroker()]))
        )
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let childStorage = root.appendingPathComponent(child.key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: childStorage, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seed).write(
            to: childStorage.appendingPathComponent("child-genesis.json")
        )

        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
            child: configure(child, root: root, keyByte: 2),
        ])
        let failed = try await host.startAll()
        XCTAssertTrue(failed.isEmpty)
        func parent() async throws -> ChainService {
            try await service(host, nexus)
        }
        _ = try await parent().submitTransaction(SubmitTransactionRequest(
            transaction: try signedGenesisAnchorTransaction(
                directory: child.directory, childGenesisCID: genesisCID
            )
        ))
        try await eventually("Nexus records the anchor", within: .seconds(60)) {
            _ = try? await self.mine(parent())
            return try await parent().explorerChildGenesisCID(
                directory: self.child.directory
            ) == genesisCID
        }

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
