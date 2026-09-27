import XCTest
import Lattice
import cashew
@testable import LatticeNode

/// The anti-inflation guarantee rests on one physical grind mapping to one
/// canonical root CID. These tests pin the choke point every network block
/// decode goes through: a block is accepted only as its exact canonical
/// encoding under its exact CID, so a re-encoding of the same logical block
/// can never mint a second countable identity.
final class CanonicalBlockDecodeTests: XCTestCase {
    func testContentBoundBlockAcceptsOnlyCanonicalEncoding() async throws {
        let store = InMemoryContentStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let block = genesis.block
        let canonical = try XCTUnwrap(block.toData())
        let cid = try BlockHeader(node: block).rawCID

        XCTAssertNotNil(_contentBoundBlock(cid: cid, data: canonical))

        // cashew's Node.init?(data:) falls back to JSON, so a JSON
        // re-encoding of the same logical block genuinely decodes. Only the
        // canonical re-encode comparison stands between one grind and two
        // identities; it must reject regardless of the CID presented.
        let json = try XCTUnwrap(block.toJSON())
        XCTAssertNotNil(Block(data: json))
        XCTAssertNil(_contentBoundBlock(cid: cid, data: json))
    }

    func testContentBoundBlockRejectsForeignCID() async throws {
        let store = InMemoryContentStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let block = genesis.block
        let canonical = try XCTUnwrap(block.toData())
        let foreignCID = block.spec.rawCID

        XCTAssertNotEqual(foreignCID, try BlockHeader(node: block).rawCID)
        XCTAssertNil(_contentBoundBlock(cid: foreignCID, data: canonical))
    }
}
