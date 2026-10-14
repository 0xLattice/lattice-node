import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// A peer that sends a Volume failing its check (an entry not matching its
/// CID, or another root) is reported when the check fails, and the Volume
/// is requested again; a failure this node caused blames no one.
final class IvyRootContentBlockTests: XCTestCase {
    private actor Log {
        private(set) var reported: [(root: String, peer: PeerID)] = []
        private(set) var credited: [PeerID] = []
        private(set) var asked = 0
        func report(_ root: String, _ peer: PeerID) { reported.append((root, peer)) }
        func credit(_ peer: PeerID) { credited.append(peer) }
        func ask() -> Int {
            asked += 1
            return asked
        }
    }

    private let bad = PeerID(publicKey: String(repeating: "ab", count: 32))
    private let honest = PeerID(publicKey: String(repeating: "cd", count: 32))

    /// A real content-addressed node: its CID and its canonical bytes.
    private func content(_ nonce: UInt64) throws -> (cid: String, data: Data) {
        let node = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["signer"], nonce: nonce, chainPath: ["Nexus"]
        )
        return (try HeaderImpl(node: node).rawCID, try XCTUnwrap(node.toData()))
    }

    /// Answers the n-th request with `answers[n]`, and nothing after.
    private func source(
        _ answers: [AttributedVolumeResponse],
        log: Log,
        maximumStorageBytes: Int = NodeResourcePolicy.default.maximumAcquisitionStorageBytes
    ) -> IvyRootContentSource {
        IvyRootContentSource(
            maximumStorageBytes: maximumStorageBytes,
            fetch: { _ in
                let n = await log.ask()
                return n <= answers.count ? answers[n - 1] : .empty
            },
            credit: { peer, _ in await log.credit(peer) },
            report: { root, peer in await log.report(root, peer) }
        )
    }

    func testAPeerSendingAnEntryThatDoesNotMatchItsCIDIsReportedAndTheVolumeComesFromAnother() async throws {
        let item = try content(1)
        var tampered = item.data
        tampered[tampered.startIndex] ^= 0xFF
        let log = Log()
        let source = source([
            AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: tampered], servedBy: bad),
            AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: item.data], servedBy: honest),
        ], log: log)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(fetched, [item.cid: item.data])
        let reported = await log.reported
        XCTAssertEqual(reported.map(\.root), [item.cid])
        XCTAssertEqual(reported.map(\.peer), [bad])
        let credited = await log.credited
        XCTAssertEqual(credited, [honest])
    }

    func testAPeerSendingAnotherRootIsReportedAndTheVolumeComesFromAnother() async throws {
        let wanted = try content(2)
        let other = try content(3)
        let log = Log()
        let source = source([
            AttributedVolumeResponse(rootCID: other.cid, entries: [other.cid: other.data], servedBy: bad),
            AttributedVolumeResponse(rootCID: wanted.cid, entries: [wanted.cid: wanted.data], servedBy: honest),
        ], log: log)
        let fetched = await source.withRoot(wanted.cid) { session in await session.fetch([wanted.cid]) }
        XCTAssertEqual(fetched, [wanted.cid: wanted.data])
        let reported = await log.reported
        XCTAssertEqual(reported.map(\.peer), [bad])
    }

    func testAnHonestPeerIsNotReported() async throws {
        let item = try content(4)
        let log = Log()
        let source = source([
            AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: item.data], servedBy: honest),
        ], log: log)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertEqual(fetched, [item.cid: item.data])
        let reported = await log.reported
        XCTAssertTrue(reported.isEmpty)
        let asked = await log.asked
        XCTAssertEqual(asked, 1)
    }

    /// A peer already reported in this fetch is not reported again, and its
    /// next bad Volume ends the attempt rather than asking again.
    func testAPeerThatKeepsSendingABadVolumeIsReportedOnce() async throws {
        let item = try content(5)
        var tampered = item.data
        tampered[tampered.startIndex] ^= 0xFF
        let bad = AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: tampered], servedBy: self.bad)
        let log = Log()
        let source = source([bad, bad, bad], log: log)
        let fetched = await source.withRoot(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(fetched.isEmpty)
        let reported = await log.reported
        XCTAssertEqual(reported.map(\.peer), [self.bad])
        let asked = await log.asked
        XCTAssertEqual(asked, 2)
    }

    /// No Volume found, this node's own capacity, and this node's own byte
    /// budget are not a peer's fault: nobody is reported.
    func testAFailureThisNodeCausedBlamesNoOne() async throws {
        let item = try content(6)
        let log = Log()
        let unserved = source([.empty, .localCapacityUnavailable], log: log)
        for _ in 0..<2 {
            let fetched = await unserved.withRoot(item.cid) { session in await session.fetch([item.cid]) }
            XCTAssertTrue(fetched.isEmpty)
        }
        let budgetLog = Log()
        let overBudget = source([
            AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: item.data], servedBy: honest),
        ], log: budgetLog, maximumStorageBytes: 1)
        let declined = await overBudget.withRootTracing(item.cid) { session in await session.fetch([item.cid]) }
        XCTAssertTrue(declined.value.isEmpty)
        XCTAssertTrue(declined.attribution.byteBudgetExceeded)
        let reported = await log.reported
        XCTAssertTrue(reported.isEmpty)
        let reportedOverBudget = await budgetLog.reported
        XCTAssertTrue(reportedOverBudget.isEmpty)
    }

    /// A bad Volume handed to the session up front blocks its sender, and
    /// the traversal then requests the root.
    func testABadInitialResponseBlocksItsSender() async throws {
        let item = try content(7)
        var tampered = item.data
        tampered[tampered.startIndex] ^= 0xFF
        let log = Log()
        let source = source([
            AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: item.data], servedBy: honest),
        ], log: log)
        let initial = AttributedVolumeResponse(rootCID: item.cid, entries: [item.cid: tampered], servedBy: bad)
        let result = await source.withRootTracing(item.cid, initialResponse: initial) { session in
            await session.fetch([item.cid])
        }
        XCTAssertEqual(result.value, [item.cid: item.data])
        let reported = await log.reported
        XCTAssertEqual(reported.map(\.peer), [bad])
    }
}
