import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import XCTest
@testable import LatticeNode

/// A level's list of child directories across a restart: built at boot from
/// the blocks the store holds, not only grown by executions while running.
final class ExecutedChildrenRuntimeTests: XCTestCase {
    private let alpha = ["Nexus", "Alpha"]
    private var beta: [String] { alpha + ["Beta"] }
    private let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    func testTheListIsRebuiltFromTheStoreOnBoot() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-executed-children-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory,
            privateKeyHex: String(repeating: "5e", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            externalAddress: "127.0.0.1",
            hostedChildren: [alpha, beta], childSpecs: [alpha: spec, beta: spec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", port), mode: .overlay
        )

        // Running: Alpha executes blocks that commit Beta. Scoped, so the
        // store is released before it is opened again.
        do {
            let storage = try await NodeStorage.open(configuration: configuration)
            let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
            let alphaReads = try XCTUnwrap(runtime.levelReads[alpha])
            let betaReads = try XCTUnwrap(runtime.levelReads[beta])
            let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
            try await eventually("Beta is mined under Alpha") {
                _ = try await runtime.mineBlock(MiningTemplateRequest(recipients: [
                    MiningRecipient(chainPath: self.alpha, address: recipient),
                ]))
                return (await betaReads.readSnapshot().height ?? 0) >= 1
            }
            try await eventually("Alpha lists Beta") {
                await alphaReads.explorerChainChildren(limit: 200).directories == ["Beta"]
            }
            await runtime.stop()

        }

        // Restarted from the same store, before anything new executes.
        let reopened = try await NodeStorage.open(configuration: configuration)
        let restored = try await NodeRuntime.boot(storage: reopened, configuration: configuration, coreConfig: .init())
        XCTAssertEqual(restored.levels[alpha]?.executedChildren.names, ["Beta"])
        XCTAssertEqual(restored.levels[["Nexus"]]?.executedChildren.names, ["Alpha"])
        XCTAssertEqual(restored.levels[beta]?.executedChildren.names, [])
    }
}
