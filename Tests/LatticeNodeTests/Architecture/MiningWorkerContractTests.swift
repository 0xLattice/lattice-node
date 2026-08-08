import XCTest
import Lattice
import LatticeMinerCore
import cashew
@testable import LatticeNode

private actor ContractTestStore: Fetcher, Storer, VolumeStorer {
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

/// Pins the external mining-worker contract documented in
/// `docs/mining-workers.md`. The reference vector below is quoted verbatim in
/// that document; if this test changes, the document must change with it —
/// and any change here is consensus-breaking for external miners.
final class MiningWorkerContractTests: XCTestCase {
    /// SHA-256 of the Nexus genesis preimage prefix with nonce 12345, from
    /// Lattice's `makeProofOfWorkPreimagePrefix` + 8-byte big-endian nonce.
    private static let vectorNonce: UInt64 = 12_345
    private static let vectorHashHex =
        "20f5f3cd686a1287bf49fab897b39f560387282e60f2c982006b68a660137762"
    private static let vectorPrefixPrefixHex =
        "310000626166797265696736747066673369653766796c6132327279346d"

    func testReferenceVectorMatchesConsensusPreimage() async throws {
        let store = ContractTestStore()
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
        // A prefix-only midstate is byte-for-byte the block midstate: workers
        // given --prefix-hex need no block parse.
        XCTAssertEqual(
            ProofOfWork.hash(
                midstate: ProofOfWork.midstate(prefixBytes: prefix),
                nonce: Self.vectorNonce
            ).toHexString(),
            Self.vectorHashHex
        )
    }

    func testTemplateResponseCarriesConsensusPrefix() async throws {
        let store = ContractTestStore()
        let genesis = try await NexusGenesis.create(fetcher: store)
        let response = MiningTemplateResponse(
            template: MiningTemplate(
                workID: try BlockHeader(node: genesis.block).rawCID,
                block: genesis.block,
                searchTarget: .max,
                chainPath: ["Nexus"],
                expiresAt: ContinuousClock.now + .seconds(30),
                childCandidates: [],
                searchWitness: nil
            ),
            maximumLifetimeMilliseconds: 30_000
        )
        let decoded = try JSONDecoder().decode(
            TemplateResponse.self,
            from: try JSONEncoder().encode(response)
        )
        let expected = ProofOfWork.proofOfWorkHashPrefixBytes(genesis.block)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(decoded.prefixHex, expected)
        XCTAssertEqual(
            TemplateResponse.derivePrefixHex(blockHex: decoded.blockHex),
            expected
        )
    }
}
