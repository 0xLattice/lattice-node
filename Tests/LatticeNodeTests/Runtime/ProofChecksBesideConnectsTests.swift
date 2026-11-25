import Foundation
import Lattice
import LatticeNodeAPI
import Synchronization
import XCTest
@testable import LatticeNode
import cashew

/// A child level weighs a header by its peer proof while the worker pool is
/// taken by connects: the check runs where the header was taken, never
/// queued behind blocks to execute.
final class ProofChecksBesideConnectsTests: XCTestCase {
    private static let alpha = ["Nexus", "Alpha"]
    private static let alphaSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    func testAChildHeaderIsWeighedByItsProofWhileConnectsHoldEveryWorker() async throws {
        // Connects run until `holding` is set, then wait on their worker
        // until the test ends.
        let holding = Mutex(false)
        let held = Mutex(0)
        let node = try testNode(keyByte: 0x5C) {
            try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: $0.storagePath, privateKeyHex: $0.privateKeyHex,
                listenPort: $0.listenPort, rpcPort: $0.rpcPort,
                hostedChildren: [Self.alpha], childSpecs: [Self.alpha: Self.alphaSpec]
            )
        }
        let storage = try await NodeStorage.openWhenFree(configuration: node.configuration)
        let runtime = try await NodeRuntime.start(
            storage: storage, configuration: node.configuration, overlay: node.overlay, workers: 1,
            observeJob: { kind, _, _ in
                guard kind == .connect, holding.withLock({ $0 }) else { return }
                held.withLock { $0 += 1 }
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        )
        addTeardownBlock { await runtime.stop() }

        // Alpha's genesis G, and the proof a peer would send with it: a
        // parent block committing G, ground to G's target, that this node
        // never sees.
        let built = try await runtime.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha))
        let genesis = try XCTUnwrap(Block(data: built.submit.block))
        let template = try await runtime.miningTemplate(MiningTemplateRequest(exclude: [Self.alpha])).block
        let children = try HeaderImpl<FlatDictionary<BlockHeader>>(
            node: FlatDictionary([Self.alpha[1]: try BlockHeader(node: genesis)])
        )
        func carrier(_ nonce: UInt64) -> Block {
            Block(
                version: template.version, parent: template.parent, transactions: template.transactions,
                target: template.target, nextTarget: template.nextTarget, spec: template.spec,
                parentState: template.parentState, prevState: template.prevState, postState: template.postState,
                children: children, height: template.height, timestamp: template.timestamp,
                rewardRecipient: template.rewardRecipient, nonce: nonce
            )
        }
        var nonce: UInt64 = 0
        while carrier(nonce).proofOfWorkHash() > genesis.target { nonce += 1 }
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier(nonce)), childDirectory: Self.alpha[1],
            fetcher: storage.workFetcher(.anyChain)
        ).serialize()

        // From here every connect holds the one worker: a Nexus block of
        // this node's own waits to execute, its submit unanswered.
        holding.withLock { $0 = true }
        let nexusOnly = MiningTemplateRequest(exclude: [Self.alpha])
        let mining = Task { [runtime, nexusOnly] in _ = try? await runtime.mineBlock(nexusOnly) }
        addTeardownBlock { mining.cancel() }
        try await eventually("a connect holds the worker") { held.withLock { $0 } > 0 }

        func push() async throws -> SubmitChildBlockStatus {
            let submit = built.submit
            return try await runtime.submitChildBlock(SubmitChildBlockRequest(
                chainPath: submit.chainPath, block: submit.block, children: submit.children,
                spec: submit.spec, proofs: [proof]
            )).status
        }
        let first = try await push()
        XCTAssertNotEqual(first, .dropped, "taken to wait for its proof's check")
        try await eventually("Alpha weighs G by its proof", within: .seconds(20)) { try await push() == .tree }
        XCTAssertEqual(held.withLock { $0 }, 1, "the connect still holds the worker")
        XCTAssertEqual(runtime.published.value?.actOnHeight, 0, "Nexus has executed nothing since")
    }
}
