import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// Ports of the book tests in `MiningTemplateBookTests`
/// (MiningAndTransactionPoolTests) to the `TemplateBook` value, with time
/// passed in. The assembly tests stay with the shell's template job.
final class TemplateBookTests: XCTestCase {
    func testTemplateNeverSearchesAndOnlyAppliesSubmittedNonce() async throws {
        let block = try await candidateBlock()
        var book = TemplateBook()
        let template = book.issue(work(block, expiresAt: 30_000), now: 0)

        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.workID, try BlockHeader(node: block).rawCID)
        XCTAssertEqual(try book.submission(workID: template.workID, nonce: 42, now: 1).nonce, 42)
    }

    func testUnissuedBuildCannotBeSubmittedOrEvictIssuedWork() async throws {
        var book = TemplateBook(capacity: 1)
        let issued = book.issue(work(try await candidateBlock(timestamp: 1), expiresAt: 30_000), now: 0)
        // A build the book never issued (the shell's preview) is unknown work.
        let preview = work(try await candidateBlock(timestamp: 2), expiresAt: 30_000)
        XCTAssertNotEqual(preview.workID, issued.workID)

        XCTAssertThrowsError(try book.submission(workID: preview.workID, nonce: 0, now: 1)) {
            XCTAssertEqual($0 as? TemplateError, .unknownWork)
        }
        XCTAssertEqual(try book.submission(workID: issued.workID, nonce: 42, now: 1).nonce, 42)
    }

    func testReissuedWorkRefreshesTemplateCapacityOrder() async throws {
        var book = TemplateBook(capacity: 2)
        let first = book.issue(work(try await candidateBlock(timestamp: 1), expiresAt: 30_000), now: 0)
        let second = book.issue(work(try await candidateBlock(timestamp: 2), expiresAt: 30_000), now: 0)
        let reissued = book.issue(work(try await candidateBlock(timestamp: 1), expiresAt: 30_000), now: 0)
        XCTAssertEqual(reissued.workID, first.workID)
        let third = book.issue(work(try await candidateBlock(timestamp: 3), expiresAt: 30_000), now: 0)

        _ = try book.submission(workID: first.workID, nonce: 0, now: 1)
        _ = try book.submission(workID: third.workID, nonce: 0, now: 1)
        XCTAssertThrowsError(try book.submission(workID: second.workID, nonce: 0, now: 1)) {
            XCTAssertEqual($0 as? TemplateError, .unknownWork)
        }
    }

    func testFirstLiveTemplateWinsWorkIDMetadataCollision() async throws {
        let block = try await candidateBlock(target: UInt256(1))
        var book = TemplateBook()
        let first = book.issue(work(block, expiresAt: 30_000), now: 0)
        let conflicting = work(block, searchTarget: UInt256(7), expiresAt: 30_000)

        XCTAssertEqual(book.issue(conflicting, now: 0).searchTarget, first.searchTarget)

        book.invalidateAll()
        book.issue(work(block, expiresAt: 250), now: 0)
        let reused = book.issue(conflicting, now: 0)
        XCTAssertLessThanOrEqual(reused.expiresAt, 250, "a live template keeps its own lifetime")

        // Once the first has expired, the next issue replaces it.
        XCTAssertEqual(book.issue(conflicting, now: 250).searchTarget, conflicting.searchTarget)
    }

    func testExpiredWorkIsRefusedAndDropped() async throws {
        var book = TemplateBook()
        let template = book.issue(work(try await candidateBlock(), expiresAt: 100), now: 0)
        XCTAssertThrowsError(try book.submission(workID: template.workID, nonce: 0, now: 100)) {
            XCTAssertEqual($0 as? TemplateError, .expired)
        }
        XCTAssertEqual(book.count, 0)
    }

    func testANonceMissingTheSearchTargetIsRefused() async throws {
        var book = TemplateBook()
        let block = try await candidateBlock()
        let template = book.issue(work(block, searchTarget: .zero, expiresAt: 30_000), now: 0)
        XCTAssertThrowsError(try book.submission(workID: template.workID, nonce: 0, now: 1)) {
            XCTAssertEqual($0 as? TemplateError, .missesSearchTarget)
        }
        XCTAssertEqual(book.count, 1, "a miss leaves the work open")
    }
}

/// A block at height 0 stands in for a candidate: the book reads only its
/// fields and proof-of-work hash.
func candidateBlock(timestamp: Int64 = 1, target: UInt256 = .max) async throws -> Block {
    let cas = SimCAS()
    try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
    return try await BlockBuilder.buildGenesis(
        spec: testSpec(), timestamp: timestamp, target: target, fetcher: cas
    )
}

func work(
    _ block: Block,
    searchTarget: UInt256? = nil,
    tipCID: String = "tip",
    expiresAt: Int64
) -> WorkTemplate {
    WorkTemplate(
        workID: try! BlockHeader(node: block).rawCID,
        block: block,
        searchTarget: searchTarget ?? block.target,
        targets: [searchTarget ?? block.target],
        tipCID: tipCID,
        poolVersion: 0,
        expiresAt: expiresAt
    )
}
