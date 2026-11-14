import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import UInt256
import XCTest
@testable import LatticeNode
import LatticeNodeAPI

/// How long a template takes to build on a node shaped like the testnet
/// miner: Nexus, one hosted child (Alpha) and `TEMPLATE_BUILD_BENCH_LEAVES`
/// leaf chains under it. Times a template after one leaf's tip moves, the
/// change a grandchild-only share makes. Opt-in: TEMPLATE_BUILD_BENCH=1.
final class TemplateBuildBench: XCTestCase {
    func testTemplateBuildAfterOneLeafMoves() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["TEMPLATE_BUILD_BENCH"] == "1", "set TEMPLATE_BUILD_BENCH=1 to measure")
        let leafCount = environment["TEMPLATE_BUILD_BENCH_LEAVES"].flatMap(Int.init) ?? 11
        let alpha = ["Nexus", "Alpha"]
        let alphaSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 3_600_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        // Leaf0 keeps the maximum target; the others' long schedule hardens
        // them, so a share can move Leaf0 alone, as one app chain's hit does.
        let easySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 1, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let hardSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 3_600_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let leaves = (0..<leafCount).map { alpha + ["Leaf\($0)"] }
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-template-bench-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        var specs: [[String]: ChainSpec] = [alpha: alphaSpec]
        for (index, leaf) in leaves.enumerated() { specs[leaf] = index == 0 ? easySpec : hardSpec }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory, privateKeyHex: String(repeating: "5a", count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [alpha] + leaves, childSpecs: specs
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let request = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: alpha, address: recipient)])
        let leafReads = try leaves.map { try XCTUnwrap(runtime.levelReads[$0]) }

        // The hardest target a Leaf0-only share must miss: Nexus, Alpha and
        // every other leaf.
        func others(_ template: MiningTemplateResponse) -> UInt256? {
            guard let alphaBlock = template.block.children.node?.entries["Alpha"]?.node,
                  let entries = alphaBlock.children.node?.entries, entries.count == leafCount else { return nil }
            var easiest = max(template.block.target, alphaBlock.target)
            for (directory, leaf) in entries where directory != "Leaf0" {
                guard let block = leaf.node else { return nil }
                easiest = max(easiest, block.target)
            }
            return easiest
        }
        // Every leaf past genesis, and everything but Leaf0 hardened.
        var mined = 0
        var hardened = false
        while mined < 96 {
            var ready = true
            for reads in leafReads where (await reads.readSnapshot().height ?? 0) < 2 { ready = false }
            let template = try await runtime.miningTemplate(request)
            if ready, let easiest = others(template), easiest < UInt256.max / UInt256(4) * UInt256(3) { hardened = true; break }
            _ = try await runtime.mineBlock(request)
            mined += 1
            try await eventually("block \(mined) executes") { runtime.published.value?.actOnHeight == UInt64(mined) }
        }

        guard hardened else {
            let template = try await runtime.miningTemplate(request)
            var heights: [Int] = []
            for reads in leafReads { heights.append(Int(await reads.readSnapshot().height ?? 0)) }
            let lead = { (t: UInt256) in String(t.description.prefix(12)) + "…(\(t.description.count))" }
            let alphaBlock = template.block.children.node?.entries["Alpha"]?.node
            let leafTargets = (alphaBlock?.children.node?.entries ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.node.map { lead($0.target) } ?? "?")" }
            return XCTFail(
                "not hardened within \(mined) blocks: nexus \(lead(template.block.target)), "
                    + "alpha \(alphaBlock.map { lead($0.target) } ?? "none"), leaves \(leafTargets), leaf heights \(heights)"
            )
        }

        // Each round: a share that meets only Leaf0 moves it, then the next
        // template is timed.
        var unchanged: [Double] = []
        var afterShare: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<10 {
            let template = try await runtime.miningTemplate(request)
            let easiest = try XCTUnwrap(others(template))
            let start = clock.now
            _ = try await runtime.miningTemplate(request)
            unchanged.append(Double((clock.now - start).components.attoseconds) / 1e15 + Double((clock.now - start).components.seconds) * 1e3)
            var nonce: UInt64 = 0
            while template.block.replacingNonce(nonce).proofOfWorkHash() <= easiest {
                nonce += 1
                guard nonce < 10_000 else { return XCTFail("no Leaf0-only nonce") }
            }
            let before = await leafReads[0].readSnapshot().height ?? 0
            _ = try await runtime.submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
            _ = try? await eventually("the share moves the leaves", within: .seconds(3)) {
                (await leafReads[0].readSnapshot().height ?? 0) > before
            }
            let timed = clock.now
            _ = try await runtime.miningTemplate(request)
            let elapsed = clock.now - timed
            afterShare.append(Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let median = { (xs: [Double]) in xs.sorted()[xs.count / 2] }
        print(String(
            format: "template-build bench: %d leaves; median template %.1f ms unchanged, %.1f ms after a leaf-only share",
            leafCount, median(unchanged), median(afterShare)
        ))
        await runtime.stop()
    }
}
