import XCTest
import Lattice
import UInt256
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// Pins the external mining-worker contract documented in
/// `docs/mining-workers.md`. The reference vector below is quoted verbatim in
/// that document; if this test changes, the document must change with it —
/// and any change here is consensus-breaking for external miners.
final class MiningWorkerContractTests: XCTestCase {
    /// SHA-256 of the Nexus genesis preimage prefix with nonce 12345, from
    /// Lattice's `makeProofOfWorkPreimagePrefix` + 8-byte big-endian nonce.
    private static let vectorNonce: UInt64 = 12_345
    private static let vectorHashHex =
        "0179e03e9b0545582bb0aba1729d83b611b16e49abcefe44d6c1d35e85c4b3a3"
    private static let vectorPrefixPrefixHex =
        "31000062616679726569663765766172756b6d7a7074636576657865686c"

    func testReferenceVectorMatchesConsensusPreimage() async throws {
        let store = InMemoryContentStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let block = genesis.block
        let prefix = ProofOfWork.proofOfWorkHashPrefixBytes(block)
        let prefixHex = prefix.map { String(format: "%02x", $0) }.joined()
        // The full prefix is long; pin its head plus the derived hash, which
        // commits to every byte.
        XCTAssertEqual(
            String(prefixHex.prefix(60)),
            String(Self.vectorPrefixPrefixHex.prefix(60))
        )
        let midstate = ProofOfWork.midstate(for: block)
        XCTAssertEqual(
            ProofOfWork.hash(
                midstate: midstate,
                nonce: Self.vectorNonce
            ).toHexString(),
            Self.vectorHashHex
        )
        // The midstate search is the consensus hash of the whole preimage.
        XCTAssertEqual(
            UInt256.hash(Block.makeProofOfWorkPreimage(block: block, nonce: Self.vectorNonce)).toHexString(),
            Self.vectorHashHex
        )
    }

    /// A miner reads the block out of the template and derives the PoW
    /// prefix from it: the block survives the template's JSON with every
    /// byte of its preimage, and the targets with it.
    func testTemplateResponseCarriesConsensusPrefix() async throws {
        let store = InMemoryContentStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let response = MiningTemplateResponse(
            template: MiningTemplate(
                workID: try BlockHeader(node: genesis.block).rawCID,
                block: genesis.block,
                searchTarget: .max,
                chainPath: ["Nexus"],
                childCandidates: [],
                searchWitness: nil,
                thresholds: [.max]
            ),
            templateDigest: "digest"
        )
        struct Wire: Decodable {
            let block: Block
            let targets: [UInt256]
        }
        let decoded = try JSONDecoder().decode(Wire.self, from: try JSONEncoder().encode(response))
        XCTAssertEqual(
            ProofOfWork.proofOfWorkHashPrefixBytes(decoded.block),
            ProofOfWork.proofOfWorkHashPrefixBytes(genesis.block)
        )
        XCTAssertEqual(decoded.targets, response.targets)
    }
}
