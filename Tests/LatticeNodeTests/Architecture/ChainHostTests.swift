import Foundation
import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// One process hosting Nexus and a child: the child is wired to its co-hosted
/// parent over loopback, activates on its deployed genesis, is carried by
/// Nexus blocks, and each level stops and starts without the other.
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

    func testADeployedChildActivatesIsCarriedAndEachLevelRestartsAlone() async throws {
        let root = temporaryDirectory(create: true)
        let host = try ChainHost(chains: [
            nexus: configure(nexus, root: root, keyByte: 1),
        ])
        try await host.startAll()
        // Looked up per use, never held: a stopped level's storage is
        // released only once nothing references its process.
        func parent() async throws -> ChainService {
            try await service(host, nexus)
        }

        // Deploy: build the child genesis offline, anchor its CID on Nexus.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: 1_000
        )
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: child.components,
            fetcher: CoalescingFetcher(CompositeContentSource([MemoryBroker()]))
        )
        let genesisCID = try BlockHeader(node: genesis).rawCID
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

        // Attach the seeded child to the running host.
        let childStorage = root.appendingPathComponent(child.key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: childStorage, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(seed).write(
            to: childStorage.appendingPathComponent("child-genesis.json")
        )
        try await host.attach(
            child, configure: configure(child, root: root, keyByte: 2)
        )
        try await eventually("the child activates on its genesis", within: .seconds(60)) {
            let status = await self.childStatus(host)
            return status?.phase == .active && status?.tipCID == genesisCID
        }

        // Nexus blocks carry the child's candidate.
        try await eventually("a carried child block is admitted", within: .seconds(120)) {
            _ = try? await self.mine(parent())
            return (await self.childStatus(host)?.height ?? 0) >= 1
        }

        // The child stops; Nexus keeps mining.
        await host.stop(child)
        let stoppedChild = await host.node(child)
        XCTAssertNil(stoppedChild)
        let before = try await parent().status().height ?? 0
        _ = try await mine(parent())
        let after = try await parent().status().height ?? 0
        XCTAssertGreaterThan(after, before)

        // The child reopens its own storage in the same process.
        try await host.start(child)
        let restarted = await childStatus(host)
        XCTAssertEqual(restarted?.phase, .active)
        XCTAssertGreaterThanOrEqual(restarted?.height ?? 0, 1)

        // Nexus stops and starts; the child keeps serving meanwhile.
        await host.stop(nexus)
        let childWhileNexusDown = await childStatus(host)
        XCTAssertEqual(childWhileNexusDown?.phase, .active)
        try await host.start(nexus)
        let reopened = try await parent().status()
        XCTAssertEqual(reopened.height, after)

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
