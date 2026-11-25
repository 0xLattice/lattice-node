import Lattice
@testable import LatticeNodeSim
import XCTest
import LatticeNodeCore
import cashew
@testable import LatticeNode

/// Pending transactions asserting one key (oldValue == newValue) go into one
/// template together; a write of that key cannot join them.
final class AssertTemplateTests: XCTestCase {
    private static let nexus = LevelWorld.nexus

    private static func transaction(_ action: Action, key index: Int, nonce: UInt64 = 0) throws -> Transaction {
        let key = SimTransactions.keys[index]
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [action],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: nonce, chainPath: Self.nexus
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    /// Block 1 lists the offer; templates are fit on it.
    private func template(pooled: [Transaction]) async throws -> (block: Block, cas: SimCAS) {
        var builder = try await LevelWorld.Builder(levels: 1)
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus]).block
        let listed = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [try Self.transaction(Action(key: "offer", oldValue: nil, newValue: "v"), key: 0)],
            timestamp: World.genesisTime + LevelWorld.interval, fetcher: builder.cas
        )
        _ = try await builder.store(listed, releaseAt: listed.timestamp, anchor: nil)
        let resolved = try await listed.spec.resolve(fetcher: builder.cas).node
        let spec = try XCTUnwrap(resolved)
        let template = try await MiningTemplateAssembly.fit(
            chainPath: Self.nexus, previous: listed,
            pooled: pooled, provided: [], hosted: [], parentCarrier: nil,
            timestamp: listed.timestamp + LevelWorld.interval, rewardRecipient: nil, minimumWork: [:],
            difficultyAnchor: nil, spec: spec, fetcher: builder.cas
        )
        return (template.block, builder.cas)
    }

    private func carried(_ block: Block, _ cas: SimCAS) async throws -> [String] {
        try await block.orderedTransactions(fetcher: cas).map { try Mempool.cid(of: $0) }
    }

    func testAssertsOfOneKeyShareATemplate() async throws {
        let assert = Action(key: "offer", oldValue: "v", newValue: "v")
        let orders = try (1...3).map { try Self.transaction(assert, key: $0) }
        let (block, cas) = try await template(pooled: orders)
        let carriedCIDs = try await carried(block, cas)
        XCTAssertEqual(Set(carriedCIDs), Set(try orders.map(Mempool.cid(of:))))
        let valid = try await block.validateNexus(fetcher: cas).0
        XCTAssertTrue(valid)
    }

    func testAWriteOfTheKeyExcludesItsAsserts() async throws {
        let assert = Action(key: "offer", oldValue: "v", newValue: "v")
        let write = try Self.transaction(Action(key: "offer", oldValue: "v", newValue: "w"), key: 0, nonce: 1)
        let orders = try (1...3).map { try Self.transaction(assert, key: $0) }
        let (block, cas) = try await template(pooled: [write] + orders)
        let carriedCIDs = try await carried(block, cas)
        XCTAssertEqual(carriedCIDs, [try Mempool.cid(of: write)])
    }
}
