import Lattice
import LatticeNodeCore
import LatticeNodeSim
import UInt256
import XCTest
import cashew

/// Tests issued-work retention, capacity, and submission independently from
/// template assembly.
final class WorkTemplateBookTests: XCTestCase {
    func testTemplateNeverSearchesAndOnlyAppliesSubmittedNonce() async throws {
        let block = try await candidateBlock()
        var book = WorkTemplateBook()
        let template = book.issue(work(block))

        XCTAssertEqual(template.block.nonce, 0)
        XCTAssertEqual(template.workID, try BlockHeader(node: block).rawCID)
        XCTAssertEqual(try book.submission(workID: template.workID, nonce: 42).nonce, 42)
    }

    func testUnissuedBuildCannotBeSubmittedOrEvictIssuedWork() async throws {
        var book = WorkTemplateBook(capacity: 1)
        let issued = book.issue(work(try await candidateBlock(timestamp: 1)))
        // A build the book never issued (the shell's preview) is unknown work.
        let preview = work(try await candidateBlock(timestamp: 2))
        XCTAssertNotEqual(preview.workID, issued.workID)

        XCTAssertThrowsError(try book.submission(workID: preview.workID, nonce: 0)) {
            XCTAssertEqual($0 as? TemplateError, .unknownWork)
        }
        XCTAssertEqual(try book.submission(workID: issued.workID, nonce: 42).nonce, 42)
    }

    func testReissuedWorkRefreshesTemplateCapacityOrder() async throws {
        var book = WorkTemplateBook(capacity: 2)
        let first = book.issue(work(try await candidateBlock(timestamp: 1)))
        let second = book.issue(work(try await candidateBlock(timestamp: 2)))
        let reissued = book.issue(work(try await candidateBlock(timestamp: 1)))
        XCTAssertEqual(reissued.workID, first.workID)
        let third = book.issue(work(try await candidateBlock(timestamp: 3)))

        _ = try book.submission(workID: first.workID, nonce: 0)
        _ = try book.submission(workID: third.workID, nonce: 0)
        XCTAssertThrowsError(try book.submission(workID: second.workID, nonce: 0)) {
            XCTAssertEqual($0 as? TemplateError, .unknownWork)
        }
    }

    func testFirstIssuedTemplateWinsWorkIDMetadataCollision() async throws {
        let block = try await candidateBlock(target: UInt256(1))
        var book = WorkTemplateBook()
        let first = book.issue(work(block))
        let conflicting = work(block, searchTarget: UInt256(7))
        XCTAssertEqual(book.issue(conflicting).searchTarget, first.searchTarget)

        book.invalidateAll()
        XCTAssertEqual(book.issue(conflicting).searchTarget, conflicting.searchTarget)
    }

    /// Proof-of-work arrivals are memoryless: no amount of time makes issued
    /// work unknown. Only a flush (the tip moving) or the capacity backstop
    /// does.
    func testIssuedWorkNeverExpiresOnAClock() async throws {
        var book = WorkTemplateBook()
        let template = book.issue(work(try await candidateBlock()))
        XCTAssertEqual(try book.submission(workID: template.workID, nonce: 42).nonce, 42)
        XCTAssertEqual(book.count, 1)
    }

    func testANonceMissingTheSearchTargetIsRefused() async throws {
        var book = WorkTemplateBook()
        let block = try await candidateBlock()
        let template = book.issue(work(block, searchTarget: .zero))
        XCTAssertThrowsError(try book.submission(workID: template.workID, nonce: 0)) {
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
    tipCID: String = "tip"
) -> WorkTemplate {
    WorkTemplate(
        workID: try! BlockHeader(node: block).rawCID,
        block: block,
        searchTarget: searchTarget ?? block.target,
        targets: [searchTarget ?? block.target],
        tipCID: tipCID,
        poolVersion: 0
    )
}
