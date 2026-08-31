import Foundation
import Lattice
import XCTest
@testable import LatticeNode

final class CandidateAcquirerTests: XCTestCase {
    func testParentFactTimeoutRetriesExactUnchangedEvidence() throws {
        let blockCID = "parent-fact-timeout"
        let rootCID = "parent-fact-root"
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: blockCID,
            package: nil,
            recoveryRootCID: rootCID
        )).accepted)
        let ticket = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            ticket.ticket,
            resolution: .wait(.evidence)
        ))

        acquirer.retryExternalDependency(blockCID: blockCID, rootCID: rootCID)

        XCTAssertEqual(acquirer.next()?.blockCID, blockCID)
    }

    func testLaterWaitIsReadiedByRetryNotByObserveAlone() throws {
        // Regression for the parent-fact SUCCESS gap: observe() (what
        // enqueueCandidate does) only re-readies a `.wait(.evidence)` attempt,
        // never a `.wait(.later)` one. A parent fact arriving successfully must
        // therefore call retryExternalDependency to re-ready the blocked candidate,
        // as acceptParentChainFact now does — otherwise it wedges until the poll.
        let blockCID = "later-wait"
        let rootCID = "later-root"
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: blockCID,
            package: nil,
            recoveryRootCID: rootCID
        )).accepted)
        let ticket = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(ticket.ticket, resolution: .wait(.later)))

        // observe() with the (now available) package does NOT re-ready a .later wait.
        _ = acquirer.observe(.init(
            blockCID: blockCID,
            package: try childPackage(rootCID: rootCID),
            recoveryRootCID: rootCID
        ))
        XCTAssertNil(acquirer.next(), "observe alone must not re-ready a .later wait")

        // retryExternalDependency (the call the fix adds) re-readies it.
        acquirer.retryExternalDependency(blockCID: blockCID, rootCID: rootCID)
        XCTAssertEqual(acquirer.next()?.blockCID, blockCID)
    }

    private func provider(
        _ publicKey: String,
        session: UInt8
    ) -> CandidateProvider {
        CandidateProvider(
            publicKey: publicKey,
            sessionID: Data([session])
        )
    }

    private func childPackage(
        rootCID: String,
        genesis: Bool = false
    ) throws -> AuthenticatedChildPackage {
        struct GenesisWire: Encodable {
            let parentPath = ["Nexus"]
            let directory = "Payments"
            let childGenesisCID = "genesis"
            let parentStateCID = "parent-state"
        }
        let genesisLink = genesis
            ? try JSONDecoder().decode(
                ParentGenesisLink.self,
                from: JSONEncoder().encode(GenesisWire())
            )
            : nil
        return AuthenticatedChildPackage(package: ChildValidationPackage(
            proof: ChildBlockProof(
                rootCID: rootCID,
                directoryPath: ["Payments"],
                entries: []
            ),
            parentGenesisLink: genesisLink
        ))
    }

    func testEvidenceAndProviderArrivalOrdersConverge() throws {
        let exact = provider("provider", session: 1)
        let evidence = try childPackage(rootCID: "root")

        var evidenceFirst = CandidateAcquirer()
        XCTAssertTrue(evidenceFirst.observe(.init(
            blockCID: "block",
            package: evidence
        )).accepted)
        let discoveryAttempt = try XCTUnwrap(evidenceFirst.next())
        XCTAssertTrue(evidenceFirst.complete(
            discoveryAttempt.ticket,
            resolution: .wait(.content)
        ))
        XCTAssertTrue(evidenceFirst.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        var evidenceFirstResult: CandidateAcquirer.Candidate?
        while let candidate = evidenceFirst.next() {
            if candidate.recoveryRootCID == "root" {
                evidenceFirstResult = candidate
                break
            }
            XCTAssertTrue(evidenceFirst.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }

        var providerFirst = CandidateAcquirer()
        XCTAssertTrue(providerFirst.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let ordinary = try XCTUnwrap(providerFirst.next())
        XCTAssertNil(ordinary.recoveryRootCID)
        XCTAssertTrue(providerFirst.complete(
            ordinary.ticket,
            resolution: .wait(.evidence)
        ))
        XCTAssertTrue(providerFirst.observe(.init(
            blockCID: "block",
            package: evidence
        )).accepted)
        let providerFirstCandidate = try XCTUnwrap(providerFirst.next())

        let evidenceFirstCandidate = try XCTUnwrap(evidenceFirstResult)
        XCTAssertEqual(evidenceFirstCandidate.recoveryRootCID, "root")
        XCTAssertEqual(providerFirstCandidate.recoveryRootCID, "root")
        XCTAssertEqual(evidenceFirstCandidate.providers, [exact])
        XCTAssertEqual(providerFirstCandidate.providers, [exact])
    }

    func testAuthenticatedEvidenceSupersedesRootlessEvidenceWait()
        throws
    {
        let exact = provider("provider", session: 1)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let rootless = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            rootless.ticket,
            resolution: .wait(.evidence)
        ))
        XCTAssertTrue(acquirer.hasTimedWait)

        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: try childPackage(rootCID: "root")
        )).accepted)
        let authenticated = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(authenticated.recoveryRootCID, "root")
        XCTAssertTrue(acquirer.complete(
            authenticated.ticket,
            resolution: .connected
        ))
        XCTAssertFalse(acquirer.hasTimedWait)
        XCTAssertNil(acquirer.next())
    }

    func testInterruptedExternalDependencyRequeuesActiveAttempt() throws {
        let package = try childPackage(rootCID: "root")
        let seed = CandidateAcquirer.Seed(
            blockCID: "block",
            package: package
        )
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(seed).accepted)
        let active = try XCTUnwrap(acquirer.next())

        XCTAssertTrue(acquirer.requeue(seed))
        XCTAssertTrue(acquirer.complete(
            active.ticket,
            resolution: .wait(.evidence)
        ))
        let retry = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(retry.blockCID, "block")
        XCTAssertEqual(retry.recoveryRootCID, "root")
    }

    func testEvidenceEnrichmentDuringAdmissionSchedulesMergedFollowUp()
        throws
    {
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: try childPackage(
                rootCID: "root"
            )
        )).accepted)
        let active = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: try childPackage(
                rootCID: "root",
                genesis: true
            )
        )).accepted)
        XCTAssertTrue(acquirer.complete(
            active.ticket,
            resolution: .connected
        ))

        let enriched = try XCTUnwrap(acquirer.next())
        XCTAssertNotNil(enriched.package?.package.parentGenesisLink)
    }

    func testProviderArrivingDuringAdmissionSchedulesImmediateRetry() throws {
        let first = provider("provider-a", session: 1)
        let replacement = provider("provider-b", session: 2)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: first
        )).accepted)
        let active = try XCTUnwrap(acquirer.next())

        acquirer.disconnect(first)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: replacement
        )).accepted)
        XCTAssertTrue(acquirer.complete(
            active.ticket,
            resolution: .wait(.content)
        ))

        let retry = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(retry.providers, [replacement])
    }

    func testProviderArrivingDuringOneRootRemainsForTheNextRoot() throws {
        let first = provider("provider-a", session: 1)
        let replacement = provider("provider-b", session: 2)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-a",
            provider: first
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-b"
        )).accepted)
        let active = try XCTUnwrap(acquirer.next())

        acquirer.disconnect(first)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: replacement
        )).accepted)
        XCTAssertTrue(acquirer.complete(
            active.ticket,
            resolution: .connected
        ))

        let nextRoot = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(nextRoot.providers, [replacement])
    }

    func testProviderLossDoesNotCreateAFalseImmediateRetry() throws {
        let exact = provider("provider", session: 1)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let active = try XCTUnwrap(acquirer.next())

        acquirer.disconnect(exact)
        XCTAssertTrue(acquirer.complete(
            active.ticket,
            resolution: .wait(.content)
        ))

        XCTAssertNil(acquirer.next())
        XCTAssertTrue(acquirer.hasTimedWait)
    }

    func testEvidenceRootsRemainDistinctWhileSharingProviders() throws {
        let exact = provider("provider", session: 1)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-a"
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-b"
        )).accepted)

        var roots: [String] = []
        while let candidate = acquirer.next() {
            if let root = candidate.recoveryRootCID {
                roots.append(root)
                XCTAssertEqual(candidate.providers, [exact])
            }
            XCTAssertTrue(acquirer.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }
        XCTAssertEqual(roots, ["root-a", "root-b"])
    }

    func testRecursivePredecessorsUnwindOnlyAfterConnection() throws {
        let exact = provider("provider", session: 1)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "D",
            package: nil,
            provider: exact
        )).accepted)

        let descendant = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(descendant.blockCID, "D")
        XCTAssertTrue(acquirer.complete(
            descendant.ticket,
            resolution: .predecessor("P")
        ))

        let predecessor = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(predecessor.blockCID, "P")
        XCTAssertEqual(predecessor.providers, [exact])
        XCTAssertTrue(acquirer.complete(
            predecessor.ticket,
            resolution: .predecessor("Q")
        ))

        let ancestor = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(ancestor.blockCID, "Q")
        XCTAssertTrue(acquirer.complete(
            ancestor.ticket,
            resolution: .connected
        ))

        let predecessorRetry = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(predecessorRetry.blockCID, "P")
        XCTAssertTrue(acquirer.complete(
            predecessorRetry.ticket,
            resolution: .connected
        ))

        let descendantRetry = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(descendantRetry.blockCID, "D")
        XCTAssertTrue(acquirer.complete(
            descendantRetry.ticket,
            resolution: .connected
        ))
        XCTAssertNil(acquirer.next())
    }

    func testPredecessorObligationSurvivesReadyQueueBackpressure() throws {
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "descendant",
            package: nil
        )).accepted)
        let descendant = try XCTUnwrap(acquirer.next())
        for index in 0..<CandidateAcquirer.readyCapacity {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "queued-\(index)",
                package: nil
            )).accepted)
        }

        XCTAssertTrue(acquirer.complete(
            descendant.ticket,
            resolution: .predecessor("predecessor")
        ))
        for _ in 0..<CandidateAcquirer.readyCapacity {
            let queued = try XCTUnwrap(acquirer.next())
            XCTAssertTrue(acquirer.complete(
                queued.ticket,
                resolution: .terminal
            ))
        }
        XCTAssertEqual(acquirer.next()?.blockCID, "predecessor")
    }

    func testAcceptedLeafPageConsumesReservationBeforeFrontierCanUseIt()
        throws
    {
        let pageSize = 64
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "descendant",
            package: nil
        )).accepted)
        let descendant = try XCTUnwrap(acquirer.next())
        for index in 0..<(CandidateAcquirer.readyCapacity - pageSize) {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "queued-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertTrue(acquirer.reserveAcceptedLeafPage(pageSize))
        XCTAssertTrue(acquirer.complete(
            descendant.ticket,
            resolution: .predecessor("frontier")
        ))

        XCTAssertTrue(acquirer.consumeAcceptedLeafPage(
            (0..<pageSize).map {
                .init(blockCID: "leaf-\($0)", package: nil)
            }
        ))
    }

    func testRetainedWaitsAreBoundedAndRequestInventoryRecovery() throws {
        var acquirer = CandidateAcquirer()
        for index in 0..<CandidateAcquirer.retainedCapacity {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "waiting-\(index)",
                package: nil
            )).accepted)
            let candidate = try XCTUnwrap(acquirer.next())
            XCTAssertTrue(acquirer.complete(
                candidate.ticket,
                resolution: .wait(.evidence)
            ))
        }
        XCTAssertFalse(acquirer.takeInventoryRestart())

        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "overflow",
            package: nil
        )).accepted)
        let overflow = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            overflow.ticket,
            resolution: .wait(.evidence)
        ))
        XCTAssertTrue(acquirer.takeInventoryRestart())
        XCTAssertNil(acquirer.next())
    }

    func testResetRejectsOldAdmissionCompletion() throws {
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "block",
            package: nil
        )).accepted)
        let stale = try XCTUnwrap(acquirer.next())

        acquirer.reset(retryWindow: .seconds(1))
        XCTAssertFalse(acquirer.complete(
            stale.ticket,
            resolution: .connected
        ))
        XCTAssertNil(acquirer.next())
    }

    func testDurableOrphansStartAtTheMissingFrontier() throws {
        var acquirer = CandidateAcquirer()
        acquirer.reset(
            retryWindow: .seconds(1),
            durableDescendants: [
                "P": [.init(blockCID: "O", rootCID: nil)],
                "O": [.init(blockCID: "D", rootCID: nil)],
            ]
        )
        let predecessor = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(predecessor.blockCID, "P")
        XCTAssertTrue(acquirer.complete(
            predecessor.ticket,
            resolution: .connected
        ))

        let orphan = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(orphan.blockCID, "O")
        XCTAssertTrue(acquirer.complete(
            orphan.ticket,
            resolution: .connected
        ))
        XCTAssertEqual(acquirer.next()?.blockCID, "D")
    }

    func testLivePredecessorParkEvictsOldestRetainedInsteadOfDropping() throws {
        // Retention is an operator-budget cache: with the budget full of
        // stale waits, a live predecessor walk must still be able to park —
        // the oldest retained entry is evicted (re-derivable via inventory
        // restart), never the fresh park.
        var acquirer = CandidateAcquirer()
        for index in 0..<CandidateAcquirer.retainedCapacity {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "stale-\(index)",
                package: nil
            )).accepted)
            let candidate = try XCTUnwrap(acquirer.next())
            XCTAssertTrue(acquirer.complete(
                candidate.ticket,
                resolution: .wait(.evidence)
            ))
        }
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "descendant",
            package: nil
        )).accepted)
        let descendant = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            descendant.ticket,
            resolution: .predecessor("missing-ancestor")
        ))
        // Eviction requests inventory recovery for the displaced wait.
        XCTAssertTrue(acquirer.takeInventoryRestart())
        // The park is live: the seeded predecessor is next, and its
        // connection wakes the parked descendant.
        let predecessor = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(predecessor.blockCID, "missing-ancestor")
        XCTAssertTrue(acquirer.complete(
            predecessor.ticket,
            resolution: .connected
        ))
        XCTAssertEqual(acquirer.next()?.blockCID, "descendant")
    }

    func testRecoverySeedingRespectsTheRetainedBudget() throws {
        // A history-heavy store can carry thousands of stale unresolved side
        // edges; seeding them all would exhaust the retained budget from
        // second zero and starve live walks.
        var durable: [String: Set<CandidateAcquirer.DurableDescendant>] = [:]
        for index in 0..<(CandidateAcquirer.retainedCapacity * 3) {
            durable["pred-\(index)"] = [
                .init(blockCID: "desc-\(index)", rootCID: nil)
            ]
        }
        var acquirer = CandidateAcquirer()
        acquirer.reset(retryWindow: .seconds(1), durableDescendants: durable)
        // The un-seeded remainder is signalled for inventory recovery.
        XCTAssertTrue(acquirer.takeInventoryRestart())
        // A live park still succeeds immediately (evicting if needed).
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "live-descendant",
            package: nil
        )).accepted)
        var live: CandidateAcquirer.Candidate?
        while let candidate = acquirer.next() {
            if candidate.blockCID == "live-descendant" {
                live = candidate
                break
            }
            XCTAssertTrue(acquirer.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }
        let ticket = try XCTUnwrap(live).ticket
        XCTAssertTrue(acquirer.complete(
            ticket,
            resolution: .predecessor("live-missing")
        ))
        var sawLivePredecessor = false
        while let candidate = acquirer.next() {
            if candidate.blockCID == "live-missing" {
                sawLivePredecessor = true
                break
            }
            XCTAssertTrue(acquirer.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }
        XCTAssertTrue(sawLivePredecessor)
    }

    func testExpiredEvidenceWaitWithDependentsReentersAdmission() throws {
        // The evidence solicitation is a lossy single round-trip fired only
        // from inside an admission attempt. A depended-upon candidate whose
        // wait window expires must become ready again (re-firing the
        // solicitation on its next admission) — fossilizing it wedges the
        // whole successor chain behind one lost message.
        var acquirer = CandidateAcquirer(retryWindow: .seconds(1))
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "hole",
            package: nil
        )).accepted)
        let start = ContinuousClock.now
        let hole = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            hole.ticket,
            resolution: .wait(.evidence),
            now: start
        ))
        // A successor parks on the hole, making it depended-upon.
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "successor",
            package: nil
        )).accepted)
        while let next = acquirer.next() {
            if next.blockCID == "successor" {
                XCTAssertTrue(acquirer.complete(
                    next.ticket,
                    resolution: .predecessor("hole"),
                    now: start
                ))
                break
            }
            XCTAssertTrue(acquirer.complete(
                next.ticket,
                resolution: .wait(.evidence),
                now: start
            ))
        }
        // Window expires: the depended-upon evidence wait re-readies instead
        // of fossilizing.
        acquirer.retry(now: start.advanced(by: .seconds(2)))
        let retried = try XCTUnwrap(
            acquirer.next(),
            "expired depended-upon evidence wait must re-enter admission"
        )
        XCTAssertEqual(retried.blockCID, "hole")
        // The renewed park arms a FRESH window, so the cycle is unbounded:
        // park again, expire again, re-ready again.
        XCTAssertTrue(acquirer.complete(
            retried.ticket,
            resolution: .wait(.evidence),
            now: start.advanced(by: .seconds(2))
        ))
        acquirer.retry(now: start.advanced(by: .seconds(4)))
        XCTAssertEqual(acquirer.next()?.blockCID, "hole")
    }

    func testPredecessorSeedInheritsDescendantProviders() throws {
        // A provider-less seed can only be fetched by dialing a pin holder —
        // unreachable when the sole holder is behind NAT and dials us. The
        // predecessor walk must carry the descendant's providers onto the
        // seed it creates.
        let supplier = provider("descendant-supplier", session: 7)
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "descendant",
            package: nil,
            provider: supplier
        )).accepted)
        let descendant = try XCTUnwrap(acquirer.next())
        XCTAssertTrue(acquirer.complete(
            descendant.ticket,
            resolution: .predecessor("hole")
        ))
        let hole = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(hole.blockCID, "hole")
        XCTAssertEqual(
            hole.providers,
            [supplier],
            "the predecessor seed must inherit the descendant's providers"
        )
    }
}
