import Lattice
@testable import LatticeNodeSim
import UInt256
import XCTest
import cashew
@testable import LatticeNode

/// A pooled `child/X` = `C@P` transaction is carried with C at `children[X]`
/// by CID alone, unless the node hosts X (it mines X itself) or the
/// template does not enter P.
final class TransactionChildCommitmentTemplateTests: XCTestCase {
    private static let nexus = LevelWorld.nexus
    private static let alpha = LevelWorld.alpha
    private static let directory = LevelWorld.alpha.last!

    private struct Fixture {
        let cas: SimCAS
        let genesis: Block
        let child: SimBlock
        let commitment: Transaction
        let timestamp: Int64
        var entering: String { genesis.postState.rawCID }
    }

    /// `childTarget` nil: Alpha's genesis target; otherwise C claims it.
    private func fixture(childTarget: UInt256? = nil) async throws -> Fixture {
        var builder = try await LevelWorld.Builder(levels: 2)
        let genesis = try XCTUnwrap(builder.geneses[Self.nexus])
        let timestamp = World.genesisTime + LevelWorld.interval
        let child: SimBlock
        if let childTarget {
            let block = try await BlockBuilder.buildChildGenesis(
                spec: try XCTUnwrap(builder.specs[Self.alpha]), parentState: genesis.block.postState,
                timestamp: timestamp, target: childTarget, fetcher: builder.cas
            )
            child = try await builder.store(block, releaseAt: timestamp, anchor: nil)
        } else {
            child = try await builder.childGenesis(
                Self.alpha, parentState: genesis.block.postState.rawCID, at: timestamp
            )
        }
        let commitment = try Self.commit(
            child.cid + "@" + genesis.block.postState.rawCID, under: Self.directory, key: 0
        )
        return Fixture(cas: builder.cas, genesis: genesis.block, child: child, commitment: commitment, timestamp: timestamp)
    }

    private static func commit(_ value: String, under directory: String, key index: Int) throws -> Transaction {
        let key = SimTransactions.keys[index]
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [Action(key: CHILD_COMMITMENT_KEY_PREFIX + directory, oldValue: nil, newValue: value)],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)], nonce: 0, chainPath: Self.nexus
        ))
        return Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(bodyHeader: body, privateKeyHex: key.privateKey))],
            body: body
        )
    }

    private func template(
        _ fixture: Fixture, pooled: [Transaction], provided: [DirectChildCandidate] = [],
        hosted: Set<String> = [], fetcher: SimCAS? = nil
    ) async throws -> MiningTemplate {
        let resolved = try await fixture.genesis.spec.resolve(fetcher: fixture.cas).node
        let spec = try XCTUnwrap(resolved)
        return try await MiningTemplateAssembly.fit(
            chainPath: Self.nexus, lifetime: .seconds(30), previous: fixture.genesis,
            pooled: pooled, provided: provided, hosted: hosted.union(provided.map(\.directory)), parentCarrier: nil,
            timestamp: fixture.timestamp, rewardRecipient: nil, minimumWork: [:], difficultyAnchor: nil,
            spec: spec, fetcher: fetcher ?? fixture.cas
        )
    }

    private func carried(_ block: Block, _ cas: SimCAS) async throws -> (child: String?, transactions: Int) {
        let children = try await block.children.resolve(fetcher: cas).node
        let transactions = try await MiningTemplateAssembly.blockTransactions(in: block, fetcher: cas)
        return (children?[Self.directory]?.rawCID, transactions.count)
    }

    /// C is carried by CID from a store that never held it, and the block
    /// validates without it.
    func testTheTemplateCarriesTheCommittedChildByCID() async throws {
        let fixture = try await fixture()
        let withoutChild = SimCAS()
        withoutChild.put(fixture.cas.all.filter { $0.key != fixture.child.cid })
        let block = try await template(fixture, pooled: [fixture.commitment], fetcher: withoutChild).block
        let (child, transactions) = try await carried(block, withoutChild)
        XCTAssertEqual(child, fixture.child.cid)
        XCTAssertEqual(transactions, 1)
        let valid = try await block.validateNexus(fetcher: withoutChild).0
        XCTAssertTrue(valid)
    }

    /// The chains a template reports are walked from the blocks it holds: a
    /// child carried by CID is not one, even where its content is at hand.
    func testCommittedChainsNeverReadACommittedChild() async throws {
        let fixture = try await fixture()
        let block = try await template(fixture, pooled: [fixture.commitment]).block
        let chains = MiningTemplateAssembly.committedChains(root: block, chainPath: Self.nexus)
        XCTAssertEqual(chains.map(\.chainPath), [Self.nexus])
    }

    /// The template's own candidate holds the directory: the commitment is
    /// left out of every pass, so the block stays valid and the template is built.
    func testAnOwnCandidateWinsTheDirectory() async throws {
        var builder = try await LevelWorld.Builder(levels: 2)
        let fixture = try await fixture()
        let own = try await builder.childGenesis(
            Self.alpha, parentState: fixture.entering, at: fixture.timestamp + 1
        )
        XCTAssertNotEqual(own.cid, fixture.child.cid)
        let block = try await template(
            fixture, pooled: [fixture.commitment],
            provided: [DirectChildCandidate(directory: Self.directory, block: own.block)]
        ).block
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertEqual(child, own.cid)
        XCTAssertEqual(transactions, 0)
        let chains = MiningTemplateAssembly.committedChains(root: block, chainPath: Self.nexus)
        XCTAssertEqual(chains.map(\.chainPath), [Self.nexus, Self.alpha], "an own candidate is reported")
    }

    /// A hosting node never carries a commitment into its own directory,
    /// even in a round it built no candidate there.
    func testAHostedDirectoryIsLeftOutWithoutACandidate() async throws {
        let fixture = try await fixture()
        let block = try await template(fixture, pooled: [fixture.commitment], hosted: [Self.directory]).block
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertNil(child)
        XCTAssertEqual(transactions, 0)
    }

    /// A commitment built on another state is left out: carrying it would
    /// make the block invalid.
    func testACommitmentOnAnotherStateIsLeftOut() async throws {
        let fixture = try await fixture()
        let stale = try Self.commit(fixture.child.cid + "@" + fixture.child.cid, under: Self.directory, key: 1)
        let block = try await template(fixture, pooled: [stale]).block
        let (child, transactions) = try await carried(block, fixture.cas)
        XCTAssertNil(child)
        XCTAssertEqual(transactions, 0)
    }

    /// C's target is its author's: an easy one must not widen the search,
    /// or every nonce is a child-only hit and the root is never found.
    func testACommittedChildDoesNotSetTheSearch() async throws {
        let fixture = try await fixture(childTarget: .max)
        let without = try await template(fixture, pooled: [])
        let with = try await template(fixture, pooled: [fixture.commitment])
        let (child, _) = try await carried(with.block, fixture.cas)
        XCTAssertEqual(child, fixture.child.cid, "the commitment is carried")
        XCTAssertEqual(with.searchTarget, without.searchTarget)
        XCTAssertEqual(with.targets, without.targets)
    }

    /// Preflight reads the transaction alone: another state, a malformed
    /// value or a non-directory name is never carried. A hosted directory
    /// is not read at all: a hosting node pools and relays the commitment.
    func testPreflightCarriesOnlyWhatThisTipCan() async throws {
        let fixture = try await fixture()
        let state = fixture.entering
        let cid = fixture.child.cid
        func carries(_ value: String, under directory: String = Self.directory) throws -> Bool {
            let body = try XCTUnwrap(Self.commit(value, under: directory, key: 0).body.node)
            return NodeRuntime.carriesChildCommitments(body, entering: state)
        }
        XCTAssertTrue(try carries(cid + "@" + state))
        XCTAssertFalse(try carries(cid + "@" + cid), "another state")
        XCTAssertFalse(try carries(cid), "no parent state")
        XCTAssertFalse(try carries("not-a-cid@" + state), "non-standard CID")
        XCTAssertFalse(try carries(cid + "@" + state, under: Self.directory + "/b"), "not a directory")
    }
}
