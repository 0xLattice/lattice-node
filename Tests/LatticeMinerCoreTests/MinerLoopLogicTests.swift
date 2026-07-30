import XCTest
import Lattice
import UInt256
import cashew
@testable import LatticeMinerCore

private func testSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000
    )
}

final class MinerLoopLogicTests: XCTestCase {
    func testTemplateResponseDecodesCurrentWireShape() async throws {
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: InMemoryContentSource([:])
        )
        struct WireTemplate: Encodable {
            let workID: String
            let block: Block
            let searchTarget: UInt256
            let chainPath: [String]
            let expiresInMilliseconds: UInt64
        }
        let decoded = try JSONDecoder().decode(
            TemplateResponse.self,
            from: JSONEncoder().encode(WireTemplate(
                workID: "candidate",
                block: block,
                searchTarget: UInt256(255),
                chainPath: ["Nexus"],
                expiresInMilliseconds: 30_000
            ))
        )

        XCTAssertEqual(decoded.workID, "candidate")
        XCTAssertEqual(decoded.searchTarget, UInt256(255).toHexString())
        XCTAssertEqual(decoded.chainPath, ["Nexus"])
        XCTAssertEqual(decoded.expiresInMilliseconds, 30_000)
        XCTAssertEqual(decoded.staleToken, "candidate")
        XCTAssertEqual(Data(hex: decoded.blockHex), block.toData())
    }

    func testParseTargetRoundTrips() {
        let values: [UInt256] = [
            .max, UInt256(0), UInt256(1), UInt256(1000),
            UInt256([1, 2, 3, 4]), UInt256([0, 0, 0, 0xDEADBEEF]),
            UInt256([0xFFFFFFFFFFFFFFFF, 0, 0xA5A5A5A5A5A5A5A5, 0]),
        ]
        for v in values {
            XCTAssertEqual(MinerLoopLogic.parseTarget(v.toHexString()), v, "round-trip failed for \(v.toHexString())")
        }
    }

    func testParseTargetAcceptsShortHexAndPrefix() {
        XCTAssertEqual(MinerLoopLogic.parseTarget("ff"), UInt256(255))
        XCTAssertEqual(MinerLoopLogic.parseTarget("0xff"), UInt256(255))
        XCTAssertEqual(MinerLoopLogic.parseTarget("0"), UInt256(0))
    }

    func testParseTargetRejectsInvalid() {
        XCTAssertNil(MinerLoopLogic.parseTarget(""))
        XCTAssertNil(MinerLoopLogic.parseTarget("xyz"))
        XCTAssertNil(MinerLoopLogic.parseTarget("0xZZ"))
        // Too long (> 64 hex chars / 256 bits).
        XCTAssertNil(MinerLoopLogic.parseTarget(String(repeating: "f", count: 65)))
    }

    // MARK: - ProofOfWork

    func testProofOfWorkSearchFindsNonceInRequestedRange() async throws {
        let fetcher = InMemoryContentSource([:])
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let nonce = await ProofOfWork.searchNonce(
            midstate: ProofOfWork.midstate(for: block),
            target: UInt256.max,
            totalBatchSize: 4,
            workerCount: 1,
            nonceOffset: 7
        )

        XCTAssertEqual(nonce, 7)
    }

    func testProofOfWorkWithNonceOnlyChangesNonce() async throws {
        let fetcher = InMemoryContentSource([:])
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let sealed = ProofOfWork.withNonce(block, nonce: 42)

        XCTAssertEqual(sealed.nonce, 42)
        XCTAssertEqual(sealed.parent?.rawCID, block.parent?.rawCID)
        XCTAssertEqual(sealed.transactions.rawCID, block.transactions.rawCID)
        XCTAssertEqual(sealed.postState.rawCID, block.postState.rawCID)
        XCTAssertNotEqual(sealed.proofOfWorkHash(), block.proofOfWorkHash())
    }

    func testMinerHashExactlyMatchesLatticeConsensus() async throws {
        let fetcher = InMemoryContentSource([:])
        let block = try await BlockBuilder.buildGenesis(
            spec: testSpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let midstate = ProofOfWork.midstate(for: block)

        for nonce in [UInt64(0), 1, 42, .max] {
            XCTAssertEqual(
                ProofOfWork.hash(midstate: midstate, nonce: nonce),
                ProofOfWork.withNonce(block, nonce: nonce).proofOfWorkHash()
            )
        }
    }

    func testProofOfWorkSearchBatchWrapsAcrossUInt64Maximum() async throws {
        let fetcher = InMemoryContentSource([:])
        for timestamp in 1...64 {
            let block = try await BlockBuilder.buildGenesis(
                spec: testSpec(),
                timestamp: Int64(timestamp),
                target: UInt256.max,
                fetcher: fetcher
            )
            let midstate = ProofOfWork.midstate(for: block)
            let beforeWrap = ProofOfWork.hash(
                midstate: midstate,
                nonce: UInt64.max
            )
            let afterWrap = ProofOfWork.hash(midstate: midstate, nonce: 0)
            guard beforeWrap > afterWrap else { continue }

            XCTAssertEqual(
                ProofOfWork.searchBatch(
                    midstate: midstate,
                    target: afterWrap,
                    startNonce: UInt64.max,
                    count: 2
                ),
                0
            )
            return
        }
        XCTFail("could not construct a wrap-crossing nonce test vector")
    }
}
