import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

private struct ProvisionalRootFixture {
    let childConfiguration: NodeConfiguration
    let parentRuntime: NodeNetworkRuntime
    let childRuntime: NodeNetworkRuntime
    let parentProcess: ChainProcess
    let childProcess: ChainProcess
    let context: ChildCandidateRequestContext
    let candidate: DirectChildCandidate
}

final class NetworkTrustCandidateTests: NetworkTrustTestCase {

    func testCandidateFetcherIsBoundedFIFOAndDeduplicated() throws {
        var fetcher = BlockFetcher()
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "second",
            package: nil
        )).accepted)
        XCTAssertTrue(fetcher.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        let first = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(first.blockCID, "first")
        XCTAssertTrue(fetcher.complete(
            first.ticket,
            resolution: .terminal
        ))
        let second = try XCTUnwrap(fetcher.next())
        XCTAssertEqual(second.blockCID, "second")
        XCTAssertTrue(fetcher.complete(
            second.ticket,
            resolution: .terminal
        ))
        XCTAssertNil(fetcher.next())

        for index in 0..<BlockFetcher.readyCapacity {
            XCTAssertTrue(fetcher.observe(.init(
                blockCID: "cid-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertFalse(fetcher.observe(.init(
            blockCID: "overflow",
            package: nil
        )).accepted)
    }

    // MARK: - Orphaned parent evidence

    /// The child's first candidate.
    private func firstHeldCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws -> DirectChildCandidate {
        // What the parent's template asks for: a carrier on its validated
        // tip, stamped now.
        let tip = try await fixture.parentProcess.validatedTipBlock()
        let context = ChildCandidateRequestContext(
            parentCarrier: try await BlockBuilder.buildBlock(
                previous: tip,
                timestamp: max(
                    Int64(Date().timeIntervalSince1970 * 1_000), tip.timestamp + 1
                ),
                fetcher: fixture.parentProcess
            ),
            recipients: []
        )
        return try await childCandidate(fixture, for: context)
    }

    /// The child's candidate for `context`, built as its hosted level builds
    /// it: against the parent's local content.
    private func childCandidate(
        _ fixture: ProvisionalRootFixture,
        for context: ChildCandidateRequestContext
    ) async throws -> DirectChildCandidate {
        let childService = networkService(
            process: fixture.childProcess, runtime: fixture.childRuntime
        )
        var built: DirectChildCandidate?
        try await eventually("the child builds its candidate") {
            built = try? await childService.miningCandidate(
                for: context, parentContentSource: fixture.parentProcess
            )
            return built != nil
        }
        await childService.shutdown()
        return try XCTUnwrap(built)
    }

    /// Builds and stores the parent block that carries `candidate`.
    private func storeCarrier(
        of candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture
    ) async throws -> BlockHeader {
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentTip,
            children: ["Payments": candidate.block],
            timestamp: parentTip.timestamp + 1_000,
            nonce: 7,
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.parentProcess, fixture.childProcess,
            ]))
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeBlock(
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.parentProcess, fixture.childProcess,
            ])),
            storer: fixture.parentProcess
        )
        return carrierHeader
    }

    /// Admits the carrier on the parent through the service, then hands the
    /// child the block it carries with the proof composed from the carrier.
    private func admitCarrier(
        _ carrierHeader: BlockHeader,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws {
        let carried = try await service.importNetworkCandidate(
            carrierHeader,
            authenticatedChildPackage: nil,
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
        let carrier = try await carrierHeader.resolve(
            paths: [["children", "Payments"]: .targeted],
            fetcher: fixture.parentProcess
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrier,
            childDirectory: "Payments",
            fetcher: fixture.parentProcess
        )
        let hop = await proof.directHop()
        let childCID = try XCTUnwrap(hop?.childCID)
        await fixture.childRuntime.deliverCarriedForTesting(BlockFetcher.Seed(
            blockCID: childCID,
            package: AuthenticatedChildPackage(
                package: ChildValidationPackage(proof: proof)
            ),
            weighed: true
        ))
    }

    // MARK: - Local parent facts

    /// The parent state the carried block's scripted admission requires
    /// continuity to (`carryFirstCandidate`).
    private static let carriedParentState = testCID("carried-parent-state")

    /// A fixture whose child reads its parent facts through a
    /// `StubParentLevel` over the parent's own process, holding the carried
    /// block's parent state unless `withheld`.
    private func stubbedParentFixture(
        keyByte: UInt8, withheld: Bool
    ) async throws -> (fixture: ProvisionalRootFixture, parent: StubParentLevel) {
        let fixture = try await provisionalRootFixture(keyByte: keyByte) {
            StubParentLevel(
                produced: [Self.carriedParentState], withheld: withheld, base: $0
            )
        }
        let parent = try XCTUnwrap(fixture.childRuntime.parentLevel as? StubParentLevel)
        return (fixture, parent)
    }

    /// Starts both levels and has the parent carry the child's first
    /// candidate. Returns its CID. The child admits through its service once
    /// the package holds the continuity link to `carriedParentState`; until
    /// then its admission needs that parent fact (a weighed admission never
    /// asks for one, so the requirement is scripted).
    private func carryFirstCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws -> String {
        let parentService = networkService(
            process: fixture.parentProcess, runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess, runtime: fixture.childRuntime
        )
        try await fixture.parentRuntime.start(
            process: fixture.parentProcess, chain: inertNetworkHandlers()
        )
        try await fixture.childRuntime.start(
            process: fixture.childProcess,
            chain: ClosureChainInterface(
                admission: { admission in
                    guard admission.authenticatedChildPackage?.package
                        .parentStateContinuityLink?.toStateCID
                        == Self.carriedParentState
                    else {
                        return NodeImportOutcome(
                            decision: .unavailable(.parentStateContinuity(
                                parentPath: ["Nexus"],
                                fromStateCID: LatticeState.emptyHeader.rawCID,
                                toStateCID: Self.carriedParentState
                            )),
                            sameChainPredecessor: nil
                        )
                    }
                    return try await childService.importNetworkCandidate(
                        admission.header,
                        authenticatedChildPackage: admission.authenticatedChildPackage,
                        contentSource: admission.contentSource,
                        weighed: admission.weighed
                    )
                }
            )
        )
        let first = try await firstHeldCandidate(fixture)
        let carrier = try await storeCarrier(of: first, fixture: fixture)
        try await admitCarrier(carrier, service: parentService, fixture: fixture)
        return try BlockHeader(node: first.block).rawCID
    }

    /// A carried block whose admission needs its parent's state continuity
    /// reads it from the parent level and is admitted at once.
    func testACarriedBlockIsAdmittedOnTheParentLevelsFact() async throws {
        let (fixture, parent) = try await stubbedParentFixture(
            keyByte: 0xa1, withheld: false
        )
        do {
            let carried = try await carryFirstCandidate(fixture)
            try await eventually("the carried block is admitted") {
                await fixture.childProcess.hasAcceptedBlock(carried)
            }
            let asked = await parent.continuityQuestions
            XCTAssertFalse(asked.isEmpty, "admission read the parent level's fact")
            XCTAssertEqual(Set(asked), [Self.carriedParentState])
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// A fact the parent level does not hold yet parks the block with no
    /// timer: it is not asked again until the parent's tip moves, and then
    /// it is admitted.
    func testABlockParkedOnAParentFactReReadiesOnTheParentTip() async throws {
        let (fixture, parent) = try await stubbedParentFixture(
            keyByte: 0xa2, withheld: true
        )
        do {
            let carried = try await carryFirstCandidate(fixture)
            try await eventually("admission asked the parent level") {
                await !parent.continuityQuestions.isEmpty
            }
            try await alwaysDuring("parked on the missing fact", .seconds(2)) {
                await !fixture.childProcess.hasAcceptedBlock(carried)
            }
            let parked = await parent.continuityQuestions.count
            try await alwaysDuring("no timer asks again", .seconds(2)) {
                await parent.continuityQuestions.count == parked
            }

            await parent.release()
            await fixture.childRuntime.parentChanged(.tipChanged)
            try await eventually("admitted once the parent's tip moves") {
                await fixture.childProcess.hasAcceptedBlock(carried)
            }
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// Lost-wake window: the parent's tip moves (and the fact lands) after
    /// admission read the fact but before the block parks, so the wake finds
    /// no park to re-ready. The park still sees the tip moved and re-checks,
    /// and the block is admitted with no further wake.
    func testATipChangeBetweenTheFactReadAndTheParkStillReReadies() async throws {
        let (fixture, parent) = try await stubbedParentFixture(
            keyByte: 0xa4, withheld: true
        )
        let runtime = fixture.childRuntime
        await parent.onNextWithheldQuestion { [weak runtime] in
            await runtime?.parentChanged(.tipChanged)
        }
        do {
            let carried = try await carryFirstCandidate(fixture)
            try await eventually("admitted without another wake") {
                await fixture.childProcess.hasAcceptedBlock(carried)
            }
            let tipChanges = await runtime.parentTipChanges
            XCTAssertEqual(tipChanges, 1, "the only wake fired before the park")
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// A parked block holds no request state: nothing is pending on the
    /// parent, so each tip change asks at most once and nothing
    /// accumulates while the parent still lacks the fact.
    func testParentFactWaitsHoldNoPendingState() async throws {
        let (fixture, parent) = try await stubbedParentFixture(
            keyByte: 0xa3, withheld: true
        )
        do {
            let carried = try await carryFirstCandidate(fixture)
            try await eventually("admission asked the parent level") {
                await !parent.continuityQuestions.isEmpty
            }
            let before = await parent.continuityQuestions.count
            let wakes = 20
            for _ in 0..<wakes {
                await fixture.childRuntime.parentChanged(.tipChanged)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await alwaysDuring("still parked", .milliseconds(500)) {
                await !fixture.childProcess.hasAcceptedBlock(carried)
            }
            let asked = await parent.continuityQuestions.count - before
            XCTAssertLessThanOrEqual(asked, wakes, "one read per wake at most")
            let tracked = await fixture.childRuntime.blockFetcher.tracks(carried)
            XCTAssertTrue(tracked, "the block stays parked, not dropped")

            await parent.release()
            await fixture.childRuntime.parentChanged(.tipChanged)
            try await eventually("admitted on the next tip change") {
                await fixture.childProcess.hasAcceptedBlock(carried)
            }
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// The validate walk reads a weighed child block's parent fact from the
    /// parent level: while the parent lacks it the walk parks, and its retry
    /// executes the block once the parent holds it.
    func testTheValidateWalkReadsTheParentFactLocally() async throws {
        let (fixture, parent) = try await stubbedParentFixture(
            keyByte: 0xa4, withheld: true
        )
        let parentProcess = fixture.parentProcess
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                acceptedBlockPublisher: { _ in },
                executionBodySource: { _, admit in
                    try await admit(parentProcess)
                }
            ),
            parentLevel: parent,
            executionWalkRetryInterval: .milliseconds(200)
        )
        _ = try await weighedOnlyChildBlock(fixture)
        // Behind: the request arms the walk.
        _ = try? await childService.miningCandidate(
            for: fixture.context, parentContentSource: parentProcess
        )
        try await eventually("the walk asked the parent level") {
            await !parent.continuityQuestions.isEmpty
        }
        try await alwaysDuring("the walk parks without the fact", .seconds(1)) {
            await fixture.childProcess.metricsTipHeights().validated == 0
        }

        await parent.release()
        try await eventually("the walk executes the block") {
            await fixture.childProcess.metricsTipHeights().validated == 1
        }
        await childService.shutdown()
    }

    /// A weighed block ahead of the validated tip with no walk stepping —
    /// parked on a fact it cannot get, or never armed — does not withhold
    /// the child's candidate: the child builds on its validated tip, since
    /// that is how a chain outweighs a branch it cannot validate.
    /// Establishes: NODE-MEMPOOL-001.b
    func testAParkedExecutionWalkDoesNotWithholdTheChildsCandidate() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9c)
        // No evidence source: the walk the deferral arms parks on the
        // continuity fact it cannot get, and the retry is out of the way.
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                acceptedBlockPublisher: { _ in }
            ),
            executionWalkRetryInterval: .seconds(60)
        )
        let weighedOnly = try await weighedOnlyChildBlock(fixture)
        let tips = await fixture.childProcess.metricsTipHeights()
        XCTAssertEqual(tips.weighed, 1)
        XCTAssertEqual(tips.validated, 0)

        var built: DirectChildCandidate?
        for _ in 0..<250 {
            built = try? await childService.miningCandidate(
                for: fixture.context, parentContentSource: fixture.parentProcess
            )
            if built != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(built, "built with the walk parked")
        XCTAssertEqual(built?.block.height, 1, "built on the validated tip")
        XCTAssertNotEqual(
            built.map { try? BlockHeader(node: $0.block).rawCID },
            weighedOnly.header.rawCID
        )
        await childService.shutdown()
    }

    /// A child whose last candidate landed and awaits validation builds no
    /// other (a second at the same height would only fork it): the request
    /// arms the walk if nothing did, and while the walk steps nothing is
    /// built either. When the walk stops, the service reports a state
    /// change so the deferred candidate is offered, built on the tip the
    /// walk reached.
    func testChildCandidateWaitsWhileTheExecutionWalkSteps() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9d)
        _ = try await weighedOnlyChildBlock(fixture)
        let gate = Latch()
        let changes = NetworkEventRecorder()
        let parentProcess = fixture.parentProcess
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                acceptedBlockPublisher: { _ in },
                executionBodySource: { _, admit in
                    await gate.wait()
                    return try await admit(parentProcess)
                }
            ),
            parentLevel: fixture.childRuntime.parentLevel
        )
        // Each reported state change tells the hosted children the tip moved.
        await childService.attachChildLevel(directory: "Observer") { change in
            guard case .tipChanged = change else { return }
            Task { await changes.append("change") }
        }
        // Behind and not parked: the request itself is refused and arms the
        // walk, whose first step then holds at the gate.
        var behind: Error?
        do {
            _ = try await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
        } catch {
            behind = error
        }
        guard case .validateWalkInProgress? = behind as? ChainServiceError else {
            return XCTFail("expected the candidate deferred while behind, got \(String(describing: behind))")
        }
        for _ in 0..<250 {
            if await gate.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stepping = await gate.isHeld
        XCTAssertTrue(stepping, "the walk is mid-step")

        var deferred: Error?
        do {
            _ = try await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
        } catch {
            deferred = error
        }
        guard case .validateWalkInProgress? = deferred as? ChainServiceError else {
            return XCTFail("expected the candidate deferred, got \(String(describing: deferred))")
        }
        let changesBeforeRelease = await changes.snapshot().count

        await gate.open()
        var built: DirectChildCandidate?
        for _ in 0..<250 {
            built = try? await childService.miningCandidate(
                for: fixture.context,
                parentContentSource: parentProcess
            )
            if built != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(built?.block.height, 2, "built on the tip the walk reached")
        let validated = await fixture.childProcess.metricsTipHeights().validated
        XCTAssertEqual(validated, 1)
        // One report for the step, one more for the walk stopping: the
        // second is what turns the deferral into an offer.
        var changesAfter = 0
        for _ in 0..<100 {
            changesAfter = await changes.snapshot().count
            if changesAfter - changesBeforeRelease >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(changesAfter - changesBeforeRelease, 2)
    }

    /// A child block the fixture child has weighed but not executed: its
    /// weighed tip is ahead of its validated tip. The fixture's child genesis
    /// is self-contained (empty parent state), so the block's package carries
    /// the continuity fact the runtime would otherwise fetch.
    private func weighedOnlyChildBlock(
        _ fixture: ProvisionalRootFixture
    ) async throws -> (header: BlockHeader, package: AuthenticatedChildPackage) {
        let childGenesis = try await fixture.childProcess.validatedTipBlock()
        let weighedOnly = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: fixture.context.parentCarrier,
            timestamp: childGenesis.timestamp + 1_000,
            target: .max,
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.childProcess, fixture.parentProcess,
            ]))
        )
        let weighedHeader = try BlockHeader(node: weighedOnly)
        try await weighedHeader.storeBlock(
            fetcher: fixture.parentProcess, storer: fixture.childProcess
        )
        // The parent carries it (a carrier with no transactions leaves the
        // parent's post-state, so the fixture context still fits).
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentTip,
            children: ["Payments": weighedOnly],
            timestamp: parentTip.timestamp + 1_000,
            nonce: 5,
            fetcher: fixture.parentProcess
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carried = try await fixture.parentProcess.importBlock(carrierHeader)
        XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Payments",
            fetcher: fixture.parentProcess
        )
        let package = AuthenticatedChildPackage(
            package: ChildValidationPackage(
                proof: proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: ["Nexus"],
                    fromStateCID: childGenesis.parentState.rawCID,
                    toStateCID: weighedOnly.parentState.rawCID
                )
            )
        )
        let weighed = try await fixture.childProcess.importBlock(
            weighedHeader,
            authenticatedChildPackage: package,
            remoteSource: fixture.parentProcess,
            mode: .header
        )
        XCTAssertTrue(weighed.decision.isAccepted, "\(weighed.decision)")
        return (weighedHeader, package)
    }

    private func provisionalRootFixture(
        keyByte: UInt8,
        parentLevel: (LocalParentLevel) -> any ParentLevel = { $0 }
    ) async throws -> ProvisionalRootFixture {
        let parentStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-parent-\(UUID().uuidString)",
            isDirectory: true
        )
        let childStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-provisional-child-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parentStorage)
            try? FileManager.default.removeItem(at: childStorage)
        }
        let parentConfiguration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: parentStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let childConfiguration = try NodeConfiguration(
            chainPath: ["Nexus", "Payments"],
            storagePath: childStorage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte &+ 1),
                count: 32
            ),
            listenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let parentRuntime = try NodeNetworkRuntime(configuration: parentConfiguration)
        let parentProcess = try await ChainProcess.open(
            configuration: parentConfiguration
        )
        let childRuntime = try NodeNetworkRuntime(
            configuration: childConfiguration,
            parentLevel: parentLevel(LocalParentLevel(parentProcess))
        )
        let childProcess = try await ChainProcess.open(
            configuration: childConfiguration
        )
        let parentGenesis = try await parentProcess.canonicalTipBlock()
        let timestamp = parentGenesis.timestamp + 3_600_000
        // A self-contained child genesis (empty parentState): the parent only
        // RECORDS its CID via a plain GenesisAction; the child rebuilds it from
        // the same seed and self-admits it. It is never carried on the carrier.
        let seed = ChildGenesisSeed(
            spec: NexusGenesis.spec, premineTo: nil, timestamp: timestamp
        )
        let childGenesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: childConfiguration.chainPath,
            fetcher: parentProcess
        )
        let childHeader = try BlockHeader(node: childGenesis)
        let authorization = try signedGenesisAnchorTransaction(
            directory: "Payments",
            childGenesisCID: childHeader.rawCID,
            chainPath: parentConfiguration.chainPath
        )
        try await VolumeImpl<Transaction>(node: authorization).storeRecursively(
            storer: parentProcess
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentGenesis,
            transactions: [authorization],
            timestamp: timestamp,
            nonce: 1,
            fetcher: parentProcess
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let carrierAdmission = try await parentProcess.importBlock(carrierHeader)
        XCTAssertTrue(carrierAdmission.decision.isAccepted)
        let activated = try await childProcess.activateChildGenesis(
            seed: seed,
            confirmParentRecordedGenesis: { _ in true }
        )
        XCTAssertTrue(activated)

        let provisional = try await BlockBuilder.buildBlock(
            previous: carrier,
            timestamp: timestamp + 3_600_000,
            nonce: 2,
            fetcher: parentProcess
        )
        // The fixture candidate is a co-mined height-1 child block bound to the
        // provisional parent carrier (a genesis is never a candidate).
        let candidateBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: provisional,
            timestamp: provisional.timestamp,
            target: .max,
            fetcher: CoalescingFetcher(CompositeContentSource([
                childProcess, parentProcess,
            ]))
        )
        return ProvisionalRootFixture(
            childConfiguration: childConfiguration,
            parentRuntime: parentRuntime,
            childRuntime: childRuntime,
            parentProcess: parentProcess,
            childProcess: childProcess,
            context: ChildCandidateRequestContext(
                parentCarrier: provisional,
                recipients: []
            ),
            candidate: DirectChildCandidate(
                directory: "Payments",
                block: candidateBlock
            )
        )
    }
}

extension NodeNetworkRuntime {
    /// Hands the child level a carried block with its proof, as the
    /// parent's mined handoff or a peer's evidence index does.
    fileprivate func deliverCarriedForTesting(_ seed: CandidateSeed) {
        enqueueCandidate(seed, generation: runtimeGeneration)
    }
}
