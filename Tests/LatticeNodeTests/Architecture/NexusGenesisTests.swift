import XCTest
import Lattice
import UInt256
import cashew
@testable import LatticeNode

private actor GenesisTestStore: Fetcher, Storer, VolumeStorer {
    private var entries: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }

    func store(entries newEntries: [String: Data]) async throws {
        entries.merge(newEntries) { existing, _ in existing }
    }

    func store(volume: SerializedVolume) async throws {
        entries.merge(volume.entries) { existing, _ in existing }
    }
}

final class NexusGenesisArchitectureTests: XCTestCase {
    func testCanonicalNexusGenesisIsDeterministicAndUnsigned() async throws {
        let store = GenesisTestStore()
        let first = try await NexusGenesis.create(fetcher: store)
        let second = try await NexusGenesis.create(fetcher: store)
        let computed = try await NexusGenesis.computedBlockHash(fetcher: store)
        let verified = try NexusGenesis.verifyGenesis(first)

        XCTAssertEqual(first.blockHash, second.blockHash)
        XCTAssertEqual(first.blockHash, computed)
        XCTAssertEqual(computed, NexusGenesis.expectedBlockHash)
        XCTAssertTrue(verified)

        let transactions = try XCTUnwrap(first.block.transactions.node)
        let transaction = try XCTUnwrap(try transactions.allKeysAndValues()["0"]?.node)
        let body = try XCTUnwrap(transaction.body.node)
        XCTAssertTrue(transaction.signatures.isEmpty)
        XCTAssertTrue(body.signers.isEmpty)
        XCTAssertEqual(body.chainPath, ["Nexus"])
        XCTAssertEqual(body.accountActions.count, 1)
        XCTAssertEqual(body.accountActions[0].owner, NexusGenesis.ownerAddress)
        XCTAssertEqual(
            body.accountActions[0].delta,
            Int64(NexusGenesis.spec.premineAmount())
        )
    }

    func testCanonicalNexusGenesisBootstrapsAsConfiguredRoot() async throws {
        let store = GenesisTestStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let header = try BlockHeader(node: genesis.block)
        XCTAssertTrue(try NexusGenesis.verifyGenesis(genesis))
        try await LatticeState.emptyHeader.storeRecursively(storer: store)
        try await header.storeBlock(fetcher: store, storer: store)

        let strict = try await genesis.block.validateGenesis(
            fetcher: store,
            chainPath: ["Nexus"]
        )
        XCTAssertTrue(strict.0)

        let bootstrap = try await ChainLevel.bootstrap(
            context: try ChainRuntimeContext(path: ["Nexus"]),
            genesisHeader: header,
            fetcher: store,
            validationContentStorer: store,
            materializedVolumeStorer: store,
            stage: { _ in }
        )
        let tip = await bootstrap.level.chain.getMainChainTip()
        XCTAssertEqual(tip, genesis.blockHash)
    }

    func testComputedVerificationRejectsTampering() async throws {
        let store = GenesisTestStore()
        let canonical = try await NexusGenesis.create(fetcher: store)
        let block = canonical.block
        let tampered = Block(
            version: block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: block.postState,
            children: block.children,
            height: block.height,
            timestamp: block.timestamp + 1,
            nonce: block.nonce
        )
        let result = GenesisResult(
            block: tampered,
            blockHash: try BlockHeader(node: tampered).rawCID
        )

        let verified = try NexusGenesis.verifyGenesis(result)
        XCTAssertFalse(verified)
    }
}
