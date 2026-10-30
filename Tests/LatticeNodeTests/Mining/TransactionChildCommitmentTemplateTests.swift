import Lattice
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// A pooled `child/X` = C transaction is carried with C at `children[X]`,
/// unless the node mines X itself or C does not enter the template's state.
final class TransactionChildCommitmentTemplateTests: XCTestCase {
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha

    private struct Fixture {
        let cas: SimCAS
        let genesis: Block
        let child: SimBlock
        let commitment: Transaction
        let timestamp: Int64
    }

    private func fixture() async throws -> Fixture {
        var builder = try await LevelWorld.Builder(levels: 2)
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let timestamp = World.genesisTime + LevelWorld.interval
        let child = try await builder.childGenesis(
            Self.alpha, parentState: genesis.block.postState.rawCID, at: timestamp
        )
        let key = SimTransactions.keys[0]
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [Action(key: CHILD_COMMITMENT_KEY_PREFIX + Self.alpha.last!, oldValue: nil, newValue: child.cid)],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: Self.nexus
        ))
        let commitment = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
        return Fixture(cas: builder.cas, genesis: genesis.block, child: child, commitment: commitment, timestamp: timestamp)
    }

    private func template(
        _ fixture: Fixture, committed: [String: DirectChildCandidate], provided: [DirectChildCandidate] = []
    ) async throws -> Block {
        let resolved = try await fixture.genesis.spec.resolve(fetcher: fixture.cas).node
        let spec = try XCTUnwrap(resolved)
        return try await MiningTemplateAssembly.fit(
            chainPath: Self.nexus, lifetime: .seconds(30), previous: fixture.genesis,
            pooled: [fixture.commitment], provided: provided, committed: committed, parentCarrier: nil,
            timestamp: fixture.timestamp, rewardRecipient: nil, minimumWork: [:], difficultyAnchor: nil,
            spec: spec, fetcher: fixture.cas
        ).block
    }

    private func carried(_ block: Block, _ cas: SimCAS) async throws -> (child: String?, transactions: Int) {
        let children = try await block.children.resolve(fetcher: cas).node
        let transactions = try await MiningTemplateAssembly.blockTransactions(in: block, fetcher: cas)
        return (children?[Self.alpha.last!]?.rawCID, transactions.count)
    }

    func testTheTemplateCarriesTheCommittedChildWithItsTransaction() async throws {
        let fixture = try await fixture()
        let committed = await NodeRuntime.committedChildren(
            in: [fixture.commitment], entering: fixture.genesis.postState, hosted: [], fetcher: fixture.cas
        )
        XCTAssertEqual(committed.keys.sorted(), [fixture.child.cid])
        let block = try await template(fixture, committed: committed)
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertEqual(child, fixture.child.cid)
        XCTAssertEqual(transactions, 1)
        let valid = try await block.validateNexus(fetcher: fixture.cas).0
        XCTAssertTrue(valid)
    }

    /// A node mining Alpha carries its own Alpha candidate, so the commitment
    /// is not carried and its transaction is left out.
    func testAHostedChainsCommitmentIsLeftOut() async throws {
        let fixture = try await fixture()
        let committed = await NodeRuntime.committedChildren(
            in: [fixture.commitment], entering: fixture.genesis.postState,
            hosted: [Self.alpha.last!], fetcher: fixture.cas
        )
        XCTAssertTrue(committed.isEmpty)
        let block = try await template(fixture, committed: committed)
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertNil(child)
        XCTAssertEqual(transactions, 0)
    }

    /// C commits the genesis's post-state as its carrier's; a template
    /// entering any other state cannot carry it.
    func testAChildEnteringAnotherStateIsNotCarried() async throws {
        let fixture = try await fixture()
        let committed = await NodeRuntime.committedChildren(
            in: [fixture.commitment], entering: LatticeStateHeader(rawCID: fixture.child.cid), hosted: [], fetcher: fixture.cas
        )
        XCTAssertTrue(committed.isEmpty)
    }

    /// The template's own candidate holds the directory: the commitment does
    /// not match it, so its transaction is dropped and the block stays valid.
    func testAnOwnCandidateWinsTheDirectory() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let fixture = try await fixture()
        let committed = await NodeRuntime.committedChildren(
            in: [fixture.commitment], entering: fixture.genesis.postState, hosted: [], fetcher: fixture.cas
        )
        let own = try await builder.childGenesis(
            Self.alpha, parentState: fixture.genesis.postState.rawCID, at: fixture.timestamp + 1
        )
        XCTAssertNotEqual(own.cid, fixture.child.cid)
        let block = try await template(
            fixture, committed: committed,
            provided: [DirectChildCandidate(directory: Self.alpha.last!, block: own.block)]
        )
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertEqual(child, own.cid)
        XCTAssertEqual(transactions, 0)
    }
}
