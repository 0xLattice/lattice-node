import Foundation
import Lattice
import XCTest
@testable import LatticeNode

final class BlockFetcherTests: XCTestCase {
    /// A candidate ready for, or in, its admission is awaiting admission;
    /// one parked on evidence, or unknown, is not. The child's offer gate
    /// asks this for its own carried candidates: while one is in flight the
    /// chain builds nothing, and a park lifts the deferral.
    func testAwaitingAdmissionIsReadyOrActiveNeverParked() throws {
        let blockCID = "awaiting-admission"
        let rootCID = "awaiting-root"
        var fetcher = BlockFetcher()
        XCTAssertFalse(fetcher.isAwaitingAdmission(blockCID))
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: blockCID,
            package: nil,
            recoveryRootCID: rootCID
        )).accepted)
        XCTAssertTrue(fetcher.isAwaitingAdmission(blockCID), "ready")
        let ticket = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.isAwaitingAdmission(blockCID), "active")
        XCTAssertTrue(fetcher.complete(
            ticket.ticket,
            resolution: .wait(.evidence)
        ))
        XCTAssertFalse(fetcher.isAwaitingAdmission(blockCID), "parked")
        fetcher.retryExternalDependency(blockCID: blockCID, rootCID: rootCID)
        XCTAssertTrue(fetcher.isAwaitingAdmission(blockCID), "ready again")
        let again = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            again.ticket,
            resolution: .predecessor("awaiting-predecessor")
        ))
        XCTAssertFalse(fetcher.isAwaitingAdmission(blockCID), "parked on a predecessor")
    }

    func testParentFactTimeoutRetriesExactUnchangedEvidence() throws {
        let blockCID = "parent-fact-timeout"
        let rootCID = "parent-fact-root"
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: blockCID,
            package: nil,
            recoveryRootCID: rootCID
        )).accepted)
        let ticket = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            ticket.ticket,
            resolution: .wait(.evidence)
        ))

        fetcher.retryExternalDependency(blockCID: blockCID, rootCID: rootCID)

        XCTAssertEqual(fetcher.next()?.blockCID, blockCID)
    }

    func testLaterWaitIsReadiedByRetryNotByObserveAlone() throws {
        // Regression for the parent-fact SUCCESS gap: observe() (what
        // enqueueCandidate does) only re-readies a `.wait(.evidence)` attempt,
        // never a `.wait(.later)` one. A parent fact arriving successfully must
        // therefore call retryExternalDependency to re-ready the blocked candidate,
        // as acceptParentChainFact now does — otherwise it wedges until the poll.
        let blockCID = "later-wait"
        let rootCID = "later-root"
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: blockCID,
            package: nil,
            recoveryRootCID: rootCID
        )).accepted)
        let ticket = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(ticket.ticket, resolution: .wait(.later)))

        // observe() with the (now available) package does NOT re-ready a .later wait.
        _ = fetcher.observe(.init(
            blockCID: blockCID,
            package: try childPackage(rootCID: rootCID),
            recoveryRootCID: rootCID
        ))
        XCTAssertNil(fetcher.next(), "observe alone must not re-ready a .later wait")

        // retryExternalDependency (the call the fix adds) re-readies it.
        fetcher.retryExternalDependency(blockCID: blockCID, rootCID: rootCID)
        XCTAssertEqual(fetcher.next()?.blockCID, blockCID)
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

        var evidenceFirst = BlockFetcher()
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
        var evidenceFirstResult: BlockFetcher.Candidate?
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

        var providerFirst = BlockFetcher()
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
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let rootless = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            rootless.ticket,
            resolution: .wait(.evidence)
        ))
        XCTAssertTrue(fetcher.hasTimedWait)

        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: try childPackage(rootCID: "root")
        )).accepted)
        let authenticated = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(authenticated.recoveryRootCID, "root")
        XCTAssertTrue(fetcher.complete(
            authenticated.ticket,
            resolution: .connected
        ))
        XCTAssertFalse(fetcher.hasTimedWait)
        XCTAssertNil(fetcher.next())
    }

    func testInterruptedExternalDependencyRequeuesActiveAttempt() throws {
        let package = try childPackage(rootCID: "root")
        let seed = BlockFetcher.Seed(
            blockCID: "block",
            package: package
        )
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(seed).accepted)
        let active = try XCTUnwrap(fetcher.next())

        XCTAssertTrue(fetcher.requeue(seed))
        XCTAssertTrue(fetcher.complete(
            active.ticket,
            resolution: .wait(.evidence)
        ))
        let retry = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(retry.blockCID, "block")
        XCTAssertEqual(retry.recoveryRootCID, "root")
    }

    func testEvidenceEnrichmentDuringAdmissionSchedulesMergedFollowUp()
        throws
    {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: try childPackage(
                rootCID: "root"
            )
        )).accepted)
        let active = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: try childPackage(
                rootCID: "root",
                genesis: true
            )
        )).accepted)
        XCTAssertTrue(fetcher.complete(
            active.ticket,
            resolution: .connected
        ))

        let enriched = try XCTUnwrap(fetcher.next())
        XCTAssertNotNil(enriched.package?.package.parentGenesisLink)
    }

    func testProviderArrivingDuringAdmissionSchedulesImmediateRetry() throws {
        let first = provider("provider-a", session: 1)
        let replacement = provider("provider-b", session: 2)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: first
        )).accepted)
        let active = try XCTUnwrap(fetcher.next())

        fetcher.disconnect(first)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: replacement
        )).accepted)
        XCTAssertTrue(fetcher.complete(
            active.ticket,
            resolution: .wait(.content)
        ))

        let retry = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(retry.providers, [replacement])
    }

    func testProviderArrivingDuringOneRootRemainsForTheNextRoot() throws {
        let first = provider("provider-a", session: 1)
        let replacement = provider("provider-b", session: 2)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-a",
            provider: first
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-b"
        )).accepted)
        let active = try XCTUnwrap(fetcher.next())

        fetcher.disconnect(first)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: replacement
        )).accepted)
        XCTAssertTrue(fetcher.complete(
            active.ticket,
            resolution: .connected
        ))

        let nextRoot = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(nextRoot.providers, [replacement])
    }

    func testProviderLossDoesNotCreateAFalseImmediateRetry() throws {
        let exact = provider("provider", session: 1)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let active = try XCTUnwrap(fetcher.next())

        fetcher.disconnect(exact)
        XCTAssertTrue(fetcher.complete(
            active.ticket,
            resolution: .wait(.content)
        ))

        XCTAssertNil(fetcher.next())
        XCTAssertTrue(fetcher.hasTimedWait)
    }

    func testEvidenceRootsRemainDistinctWhileSharingProviders() throws {
        let exact = provider("provider", session: 1)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-a"
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            recoveryRootCID: "root-b"
        )).accepted)

        var roots: [String] = []
        while let candidate = fetcher.next() {
            if let root = candidate.recoveryRootCID {
                roots.append(root)
                XCTAssertEqual(candidate.providers, [exact])
            }
            XCTAssertTrue(fetcher.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }
        XCTAssertEqual(roots, ["root-a", "root-b"])
    }

    func testRecursivePredecessorsUnwindOnlyAfterConnection() throws {
        let exact = provider("provider", session: 1)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "D",
            package: nil,
            provider: exact
        )).accepted)

        let descendant = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(descendant.blockCID, "D")
        XCTAssertTrue(fetcher.complete(
            descendant.ticket,
            resolution: .predecessor("P")
        ))

        let predecessor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(predecessor.blockCID, "P")
        XCTAssertEqual(predecessor.providers, [exact])
        XCTAssertTrue(fetcher.complete(
            predecessor.ticket,
            resolution: .predecessor("Q")
        ))

        let ancestor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(ancestor.blockCID, "Q")
        XCTAssertTrue(fetcher.complete(
            ancestor.ticket,
            resolution: .connected
        ))

        let predecessorRetry = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(predecessorRetry.blockCID, "P")
        XCTAssertTrue(fetcher.complete(
            predecessorRetry.ticket,
            resolution: .connected
        ))

        let descendantRetry = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(descendantRetry.blockCID, "D")
        XCTAssertTrue(fetcher.complete(
            descendantRetry.ticket,
            resolution: .connected
        ))
        XCTAssertNil(fetcher.next())
    }

    func testPredecessorObligationSurvivesReadyQueueBackpressure() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "descendant",
            package: nil
        )).accepted)
        let descendant = try XCTUnwrap(fetcher.next())
        for index in 0..<BlockFetcher.readyCapacity {
            XCTAssertTrue(fetcher.observe(.init(
                blockCID: "queued-\(index)",
                package: nil
            )).accepted)
        }

        XCTAssertTrue(fetcher.complete(
            descendant.ticket,
            resolution: .predecessor("predecessor")
        ))
        for _ in 0..<BlockFetcher.readyCapacity {
            let queued = try XCTUnwrap(fetcher.next())
            XCTAssertTrue(fetcher.complete(
                queued.ticket,
                resolution: .terminal
            ))
        }
        XCTAssertEqual(fetcher.next()?.blockCID, "predecessor")
    }

    func testResetRejectsOldAdmissionCompletion() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil
        )).accepted)
        let stale = try XCTUnwrap(fetcher.next())

        fetcher.reset(retryWindow: .seconds(1))
        XCTAssertFalse(fetcher.complete(
            stale.ticket,
            resolution: .connected
        ))
        XCTAssertNil(fetcher.next())
    }

    /// Restart seeding is network history on both sides of the missing
    /// predecessor: the frontier AND the durable descendants waiting on it
    /// are weighed. Eager-wins is monotone, so an eager boot seed would pin a
    /// losing-fork descendant to execution for the process lifetime.
    func testResetSeedsDurableDescendantsWeighed() throws {
        var fetcher = BlockFetcher()
        fetcher.reset(
            retryWindow: .seconds(1),
            durableDescendants: ["P": [.init(blockCID: "O", rootCID: nil)]]
        )
        let predecessor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(predecessor.blockCID, "P")
        XCTAssertTrue(predecessor.weighed, "restart frontier is weighed")
        XCTAssertTrue(fetcher.complete(
            predecessor.ticket,
            resolution: .connected
        ))
        let descendant = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(descendant.blockCID, "O")
        XCTAssertTrue(descendant.weighed, "durable descendant is weighed")
    }

    func testDurableOrphansStartAtTheMissingFrontier() throws {
        var fetcher = BlockFetcher()
        fetcher.reset(
            retryWindow: .seconds(1),
            durableDescendants: [
                "P": [.init(blockCID: "O", rootCID: nil)],
                "O": [.init(blockCID: "D", rootCID: nil)],
            ]
        )
        let predecessor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(predecessor.blockCID, "P")
        XCTAssertTrue(fetcher.complete(
            predecessor.ticket,
            resolution: .connected
        ))

        let orphan = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(orphan.blockCID, "O")
        XCTAssertTrue(fetcher.complete(
            orphan.ticket,
            resolution: .connected
        ))
        XCTAssertEqual(fetcher.next()?.blockCID, "D")
    }

    func testLivePredecessorParkEvictsOldestRetainedInsteadOfDropping() throws {
        // Retention is an operator-budget cache: with the budget full of
        // stale waits, a live predecessor walk must still be able to park —
        // the oldest retained entry is evicted, never the fresh park.
        var fetcher = BlockFetcher()
        for index in 0..<BlockFetcher.parkedCapacity {
            XCTAssertTrue(fetcher.observe(.init(
                blockCID: "stale-\(index)",
                package: nil
            )).accepted)
            let candidate = try XCTUnwrap(fetcher.next())
            XCTAssertTrue(fetcher.complete(
                candidate.ticket,
                resolution: .wait(.evidence)
            ))
        }
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "descendant",
            package: nil
        )).accepted)
        let descendant = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            descendant.ticket,
            resolution: .predecessor("missing-ancestor")
        ))
        // The park is live: the seeded predecessor is next, and its
        // connection wakes the parked descendant.
        let predecessor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(predecessor.blockCID, "missing-ancestor")
        XCTAssertTrue(fetcher.complete(
            predecessor.ticket,
            resolution: .connected
        ))
        XCTAssertEqual(fetcher.next()?.blockCID, "descendant")
    }

    func testRecoverySeedingRespectsTheRetainedBudget() throws {
        // A history-heavy store can carry thousands of stale unresolved side
        // edges; seeding them all would exhaust the retained budget from
        // second zero and starve live walks.
        var durable: [String: Set<BlockFetcher.DurableDescendant>] = [:]
        for index in 0..<(BlockFetcher.parkedCapacity * 3) {
            durable["pred-\(index)"] = [
                .init(blockCID: "desc-\(index)", rootCID: nil)
            ]
        }
        var fetcher = BlockFetcher()
        fetcher.reset(retryWindow: .seconds(1), durableDescendants: durable)
        // A live park still succeeds immediately (evicting if needed).
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "live-descendant",
            package: nil
        )).accepted)
        var live: BlockFetcher.Candidate?
        while let candidate = fetcher.next() {
            if candidate.blockCID == "live-descendant" {
                live = candidate
                break
            }
            XCTAssertTrue(fetcher.complete(
                candidate.ticket,
                resolution: .terminal
            ))
        }
        let ticket = try XCTUnwrap(live).ticket
        XCTAssertTrue(fetcher.complete(
            ticket,
            resolution: .predecessor("live-missing")
        ))
        var sawLivePredecessor = false
        while let candidate = fetcher.next() {
            if candidate.blockCID == "live-missing" {
                sawLivePredecessor = true
                break
            }
            XCTAssertTrue(fetcher.complete(
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
        var fetcher = BlockFetcher(
            retryWindow: .seconds(1),
            evidenceRetryWindow: .seconds(1)
        )
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "hole",
            package: nil
        )).accepted)
        let start = ContinuousClock.now
        let hole = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            hole.ticket,
            resolution: .wait(.evidence),
            now: start
        ))
        // A successor parks on the hole, making it depended-upon.
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "successor",
            package: nil
        )).accepted)
        while let next = fetcher.next() {
            if next.blockCID == "successor" {
                XCTAssertTrue(fetcher.complete(
                    next.ticket,
                    resolution: .predecessor("hole"),
                    now: start
                ))
                break
            }
            XCTAssertTrue(fetcher.complete(
                next.ticket,
                resolution: .wait(.evidence),
                now: start
            ))
        }
        // Window expires: the depended-upon evidence wait re-readies instead
        // of fossilizing.
        fetcher.retry(now: start.advanced(by: .seconds(2)))
        let retried = try XCTUnwrap(
            fetcher.next(),
            "expired depended-upon evidence wait must re-enter admission"
        )
        XCTAssertEqual(retried.blockCID, "hole")
        // The renewed park arms a FRESH window, so the cycle is unbounded:
        // park again, expire again, re-ready again.
        XCTAssertTrue(fetcher.complete(
            retried.ticket,
            resolution: .wait(.evidence),
            now: start.advanced(by: .seconds(2))
        ))
        fetcher.retry(now: start.advanced(by: .seconds(4)))
        XCTAssertEqual(fetcher.next()?.blockCID, "hole")
    }

    func testPredecessorSeedInheritsDescendantProviders() throws {
        // A provider-less seed can only be fetched by dialing a pin holder —
        // unreachable when the sole holder is behind NAT and dials us. The
        // predecessor walk must carry the descendant's providers onto the
        // seed it creates.
        let supplier = provider("descendant-supplier", session: 7)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "descendant",
            package: nil,
            provider: supplier
        )).accepted)
        let descendant = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            descendant.ticket,
            resolution: .predecessor("hole")
        ))
        let hole = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(hole.blockCID, "hole")
        XCTAssertEqual(
            hole.providers,
            [supplier],
            "the predecessor seed must inherit the descendant's providers"
        )
    }

    func testDeficientProviderIsNotInheritedByThePredecessorSeed() throws {
        // Deficient-provider removal must persist through the predecessor
        // branch's stored-record re-read, or the known-bad provider is both
        // revived on the descendant and copied onto the predecessor seed.
        let good = provider("good-supplier", session: 1)
        let bad = provider("bad-supplier", session: 2)
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "descendant",
            package: nil,
            provider: good
        )).accepted)
        _ = fetcher.observe(.init(
            blockCID: "descendant",
            package: nil,
            provider: bad
        ))
        let descendant = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            descendant.ticket,
            resolution: .predecessor("hole"),
            deficientProviders: [bad]
        ))
        let hole = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(hole.blockCID, "hole")
        XCTAssertEqual(hole.providers, [good])
    }

    func testContentRetriesArePacedNotPerTick() throws {
        // During bulk catch-up thousands of guaranteed-to-park waiters must
        // not cycle the single admission slot every tick — a content wait
        // re-readies at most once per retryWindow/64.
        let exact = provider("provider", session: 1)
        var fetcher = BlockFetcher(retryWindow: .seconds(64))
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block",
            package: nil,
            provider: exact
        )).accepted)
        let start = ContinuousClock.now
        let first = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            first.ticket,
            resolution: .wait(.content),
            now: start
        ))
        // Immediately after the park the wait is paced, not ready.
        fetcher.retry(now: start.advanced(by: .milliseconds(100)))
        XCTAssertNil(fetcher.next(), "a fresh content wait must not re-ready on the next tick")
        // One pace interval later it re-readies.
        fetcher.retry(now: start.advanced(by: .seconds(2)))
        XCTAssertEqual(fetcher.next()?.blockCID, "block")
    }

    func testWeighedSeedPromotesOntoCandidate() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "weighed-block",
            package: nil,
            weighed: true
        )).accepted)
        let candidate = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(
            candidate.weighed,
            "a weighed seed must produce a weighed candidate"
        )
    }

    func testDefaultSeedIsEager() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "eager-block",
            package: nil
        )).accepted)
        let candidate = try XCTUnwrap(fetcher.next())
        XCTAssertFalse(
            candidate.weighed,
            "the default seed must stay on the eager tier"
        )
    }

    func testEagerSeedDowngradesAWeighedAttemptMonotonically() throws {
        // Order 1: weighed first, then an eager seed for the same CID.
        var weighedFirst = BlockFetcher()
        XCTAssertTrue(weighedFirst.observe(.init(
            blockCID: "block", package: nil, weighed: true
        )).accepted)
        _ = weighedFirst.observe(.init(blockCID: "block", package: nil))
        XCTAssertEqual(
            weighedFirst.next()?.weighed, false,
            "an eager seed touching a weighed CID must downgrade it to eager"
        )

        // Order 2: eager first, then weighed — still eager (never upgrades).
        var eagerFirst = BlockFetcher()
        XCTAssertTrue(eagerFirst.observe(.init(
            blockCID: "block", package: nil
        )).accepted)
        _ = eagerFirst.observe(.init(
            blockCID: "block", package: nil, weighed: true
        ))
        XCTAssertEqual(
            eagerFirst.next()?.weighed, false,
            "weighed must never override an eager attempt"
        )
    }

    func testRootedPackageSeedInheritsWeighedFromTheRootlessAttemptItSupersedes()
        throws
    {
        // Range-sync seeds a weighed rootless attempt; a recovered portable
        // attachment then seeds the same CID with its package (rooted, default
        // flag). The package supersedes the rootless attempt and must inherit
        // its tier — otherwise every below-tip child block executes eagerly.
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block", package: nil, weighed: true
        )).accepted)
        _ = fetcher.observe(.init(
            blockCID: "block", package: try childPackage(rootCID: "root")
        ))
        let candidate = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(candidate.recoveryRootCID, "root")
        XCTAssertTrue(
            candidate.weighed,
            "a package seed superseding a weighed attempt must stay weighed"
        )
        XCTAssertNil(fetcher.next(), "the rootless attempt was superseded")

        // Eager-wins still holds: a package seed never UPGRADES an eager
        // rootless attempt to weighed.
        var eagerRootless = BlockFetcher()
        XCTAssertTrue(eagerRootless.observe(.init(
            blockCID: "block", package: nil
        )).accepted)
        _ = eagerRootless.observe(.init(
            blockCID: "block", package: try childPackage(rootCID: "root")
        ))
        XCTAssertEqual(
            eagerRootless.next()?.weighed, false,
            "inheritance must never turn an eager attempt weighed"
        )
    }

    func testSecondPackageSeedNeverDowngradesAWeighedRootedAttempt() throws {
        // Two peers advertise the same attachment: the second package seed
        // lands on the EXISTING rooted attempt (the merge branch, not the
        // creation branch). A package seed carries no tier of its own, so it
        // must not re-eager the weighed block — otherwise every below-tip child
        // block seen from more than one peer executes eagerly.
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block", package: nil, weighed: true
        )).accepted)
        _ = fetcher.observe(.init(
            blockCID: "block", package: try childPackage(rootCID: "root")
        ))
        _ = fetcher.observe(.init(
            blockCID: "block", package: try childPackage(rootCID: "root")
        ))
        XCTAssertEqual(
            fetcher.next()?.weighed, true,
            "a second package seed must not downgrade a weighed rooted attempt"
        )

        // Eager-wins is intact where it belongs: a genuinely eager (rootless,
        // package-less) seed still downgrades a weighed rootless attempt.
        var rootless = BlockFetcher()
        XCTAssertTrue(rootless.observe(.init(
            blockCID: "block", package: nil, weighed: true
        )).accepted)
        _ = rootless.observe(.init(blockCID: "block", package: nil))
        XCTAssertEqual(
            rootless.next()?.weighed, false,
            "an eager package-less seed must still downgrade"
        )
    }

    func testExpiredEvidenceWaitWithoutDependentsReentersAdmission() throws {
        // The head a node syncs toward has no successor waiting on it. If its
        // single locate round-trip is lost, the park must still re-fire when
        // its window expires. The old behaviour REMOVED a dependent-less park
        // on expiry, which fossilized a child cold-sync one block short of the
        // tip — the only path to that block's securing proof once the legacy
        // sweeps were retired.
        var fetcher = BlockFetcher(
            retryWindow: .seconds(64),
            evidenceRetryWindow: .seconds(1)
        )
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "tip", package: nil
        )).accepted)
        let start = ContinuousClock.now
        let tip = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            tip.ticket, resolution: .wait(.evidence), now: start
        ))
        XCTAssertNil(fetcher.next(), "parked until the evidence window expires")
        fetcher.retry(now: start.advanced(by: .seconds(2)))
        XCTAssertEqual(
            fetcher.next()?.blockCID, "tip",
            "a dependent-less evidence park must re-enter admission, not be dropped"
        )
    }

    func testEvidenceParkExpiresOnItsOwnShortWindow() throws {
        // A lost locate must re-fire in seconds: evidence parks expire on the
        // dedicated evidence window, not the 64 s content window.
        var fetcher = BlockFetcher(
            retryWindow: .seconds(64),
            evidenceRetryWindow: .seconds(4)
        )
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "ev", package: nil
        )).accepted)
        let start = ContinuousClock.now
        let ev = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            ev.ticket, resolution: .wait(.evidence), now: start
        ))
        fetcher.retry(now: start.advanced(by: .seconds(2)))
        XCTAssertNil(fetcher.next(), "still inside the 4 s evidence window")
        fetcher.retry(now: start.advanced(by: .seconds(5)))
        XCTAssertEqual(
            fetcher.next()?.blockCID, "ev",
            "re-fires after the evidence window, long before the content window"
        )
    }

    func testDependentlessEvidenceParkRefiresWithinBudgetThenIsReclaimed() throws {
        // A dependent-less evidence park re-fires a bounded number of times —
        // enough to survive a lost locate on the head the node syncs toward —
        // and is then reclaimed, so an unresolvable losing-sibling park cannot
        // cycle through the single admission slot forever and starve it.
        var fetcher = BlockFetcher(
            retryWindow: .seconds(64),
            evidenceRetryWindow: .seconds(1)
        )
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "dead", package: nil
        )).accepted)
        let start = ContinuousClock.now
        let first = try XCTUnwrap(fetcher.next())
        XCTAssertTrue(fetcher.complete(
            first.ticket, resolution: .wait(.evidence), now: start
        ))
        for i in 1...5 {
            let now = start.advanced(by: .seconds(2 * i))
            fetcher.retry(now: now)
            let refired = try XCTUnwrap(
                fetcher.next(), "re-fire \(i) is within the budget"
            )
            XCTAssertEqual(refired.blockCID, "dead")
            XCTAssertTrue(fetcher.complete(
                refired.ticket, resolution: .wait(.evidence), now: now
            ))
        }
        fetcher.retry(now: start.advanced(by: .seconds(12)))
        XCTAssertNil(
            fetcher.next(),
            "past the budget a dependent-less evidence park is reclaimed"
        )
    }

    func testExpiredLaterWaitWithDependentsReentersAdmission() throws {
        // A missing parent genesis or continuity fact parks `.later`, and that
        // solicitation — like the evidence one — is fired only from inside an
        // admission attempt. So a depended-upon `.later` park must re-enter
        // admission when its window expires, or the park and every successor
        // behind it fossilize: at expiry the attempt keeps `.waiting` while
        // `expiresAt` is cleared, and `retry` skips a nil-`expiresAt` attempt
        // forever. There is no wake path short of a restart.
        //
        // This used to be unreachable in practice: a live parent answered in a
        // round trip, so the 2 h ceiling never arrived. It is reachable now —
        // a parent that has not upgraded does not serve the v2 fact topic at
        // all, so an unanswered query is the EXPECTED steady state for the
        // length of a roll, and a roll can outlast two hours.
        let ceiling = Duration.seconds(2 * 60 * 60)
        var fetcher = BlockFetcher(
            retryWindow: .seconds(64),
            evidenceRetryWindow: .seconds(4)
        )
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "needs-parent-fact", package: nil
        )).accepted)
        let start = ContinuousClock.now
        let blocked = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(blocked.blockCID, "needs-parent-fact")
        XCTAssertTrue(fetcher.complete(
            blocked.ticket, resolution: .wait(.later), now: start
        ))

        // A successor parks on it, making it depended-upon — the branch that
        // fossilizes rather than being reclaimed.
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "successor", package: nil
        )).accepted)
        let successor = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(
            successor.blockCID, "successor",
            "the parked predecessor must not be offered again here"
        )
        XCTAssertTrue(fetcher.complete(
            successor.ticket,
            resolution: .predecessor("needs-parent-fact"),
            now: start
        ))

        // Cross the ceiling. Anything short of it takes the ordinary paced
        // retry and proves nothing about expiry.
        fetcher.retry(now: start.advanced(by: ceiling + .seconds(1)))
        let retried = try XCTUnwrap(
            fetcher.next(),
            """
            An expired depended-upon `.later` park must re-enter admission and \
            re-fire its parent query. Fossilizing it strands this block and \
            every successor behind it until the process restarts.
            """
        )
        XCTAssertEqual(retried.blockCID, "needs-parent-fact")

        // The renewed park arms a FRESH ceiling, so the child keeps asking for
        // as long as the parent stays stale and heals itself once it rolls.
        let second = start.advanced(by: ceiling + .seconds(1))
        XCTAssertTrue(fetcher.complete(
            retried.ticket, resolution: .wait(.later), now: second
        ))
        fetcher.retry(now: second.advanced(by: ceiling + .seconds(1)))
        XCTAssertEqual(
            fetcher.next()?.blockCID, "needs-parent-fact",
            "the retry cycle must not decay after one renewal"
        )
    }

    func testWeighedSurvivesRepeatedWeighedObserves() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "block", package: nil, weighed: true
        )).accepted)
        _ = fetcher.observe(.init(
            blockCID: "block", package: nil, weighed: true
        ))
        XCTAssertEqual(
            fetcher.next()?.weighed, true,
            "weighed && weighed stays weighed"
        )
    }
}
