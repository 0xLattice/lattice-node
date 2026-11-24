import Foundation
import Ivy
import Lattice
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// The pool's retained roots across a restart: startup clears the live-pool
/// scope and keeps the durable one; the restored local journal is retained
/// in the live scope again once the pool re-admits it.
final class MempoolRetentionTests: XCTestCase {
    func testRestoredLocalRootsArePinnedAgainAfterStartupClearsTheLiveOwner() async throws {
        let node = try testNode(keyByte: 0x5e)
        let (configuration, overlay) = (node.configuration, node.overlay)
        let roots = try await submitLocals(configuration, overlay)

        let reopened = try await NodeStorage.openWhenFree(configuration: configuration)
        let live = reopened.liveMempoolOwner
        let durable = reopened.durableMempoolOwner
        let clearedLive = try await reopened.broker.retainedRoots(scope: live)
        let keptDurable = try await reopened.broker.retainedRoots(scope: durable)
        XCTAssertTrue(clearedLive.isEmpty, "startup left \(clearedLive)")
        XCTAssertEqual(Set(keptDurable), roots)

        let runtime = try await NodeRuntime.start(storage: reopened, configuration: configuration, overlay: overlay)
        try await eventually("the journal is pooled again") { runtime.published.value?.mempoolCount == roots.count }
        try await eventually("every restored local root is retained live again") {
            Set(try await reopened.broker.retainedRoots(scope: live)).isSuperset(of: roots)
        }
        await runtime.stop()
    }

    /// Three local submissions on a first run; the storage closes on return.
    private func submitLocals(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> Set<String> {
        let storage = try await NodeStorage.openWhenFree(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        var roots: Set<String> = []
        for _ in 0..<3 {
            let key = CryptoUtils.generateKeyPair()
            let body = try HeaderImpl(node: TransactionBody(
                accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: ["Nexus"]
            ))
            let transaction = Transaction(
                signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
                body: body
            )
            roots.insert(try await runtime.submitTransaction(SubmitTransactionRequest(transaction: transaction)).transactionCID)
        }
        await runtime.stop()
        return roots
    }
}
