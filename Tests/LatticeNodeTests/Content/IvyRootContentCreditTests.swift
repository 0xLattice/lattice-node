import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// The content source credits a peer only for a Volume this node requested
/// that verified against its CID, with that Volume's bytes.
final class IvyRootContentCreditTests: XCTestCase {
    private actor Credits {
        private(set) var entries: [(peer: PeerID, bytes: Int)] = []
        func add(_ peer: PeerID, _ bytes: Int) { entries.append((peer, bytes)) }
    }

    private let server = PeerID(publicKey: String(repeating: "ab", count: 32))

    /// A real content-addressed node: its CID and its canonical bytes.
    private func content(_ nonce: UInt64) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["signer"], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    private func source(
        serving entries: [String: Data],
        root: String,
        servedBy: PeerID?,
        credits: Credits
    ) -> IvyRootContentSource {
        IvyRootContentSource(
            fetch: { requested in
                guard requested == root else { return .empty }
                return AttributedVolumeResponse(rootCID: root, entries: entries, servedBy: servedBy, failure: nil)
            },
            credit: { peer, bytes in await credits.add(peer, bytes) }
        )
    }

    func testVerifiedRequestedVolumeCreditsItsServerWithItsBytes() async throws {
        let item = try content(1)
        let credits = Credits()
        let source = source(serving: [item.cid: item.data], root: item.cid, servedBy: server, credits: credits)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(fetched[item.cid], item.data)
        let entries = await credits.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.peer, server)
        XCTAssertEqual(entries.first?.bytes, item.data.count)
    }

    func testContentThatFailsVerificationEarnsNoCredit() async throws {
        let item = try content(2)
        var tampered = item.data
        tampered[tampered.startIndex] ^= 0xFF
        let credits = Credits()
        let source = source(serving: [item.cid: tampered], root: item.cid, servedBy: server, credits: credits)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(fetched.isEmpty)
        let entries = await credits.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testContentWithNoServingPeerCreditsNobody() async throws {
        let item = try content(3)
        let credits = Credits()
        let source = source(serving: [item.cid: item.data], root: item.cid, servedBy: nil, credits: credits)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(fetched[item.cid], item.data)
        let entries = await credits.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testAVerifiedInitialResponseIsCreditedOnce() async throws {
        let item = try content(4)
        let credits = Credits()
        let source = source(serving: [:], root: "unused", servedBy: server, credits: credits)
        let initial = AttributedVolumeResponse(
            rootCID: item.cid, entries: [item.cid: item.data], servedBy: server, failure: nil
        )
        _ = await source.withRootTracing(item.cid, initialResponse: initial) { session in
            await session.fetch([item.cid])
        }
        let entries = await credits.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.bytes, item.data.count)
    }

    func testContentForAnotherRootIsNotCredited() async throws {
        let wanted = try content(5)
        let other = try content(6)
        let credits = Credits()
        let server = self.server
        // The peer answers the request with a different Volume.
        let source = IvyRootContentSource(
            fetch: { _ in
                AttributedVolumeResponse(
                    rootCID: other.cid, entries: [other.cid: other.data], servedBy: server, failure: nil
                )
            },
            credit: { peer, bytes in await credits.add(peer, bytes) }
        )
        let fetched = await source.withRoot(wanted.cid) { session in await session.fetch([wanted.cid]) }
        XCTAssertTrue(fetched.isEmpty)
        let entries = await credits.entries
        XCTAssertTrue(entries.isEmpty)
    }
}
