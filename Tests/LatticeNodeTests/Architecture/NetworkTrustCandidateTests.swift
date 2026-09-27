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

private actor MinimumWorkRecorder {
    private var values: [[MiningMinimumWork]] = []

    func record(_ value: [MiningMinimumWork]) {
        values.append(value)
    }

    func last() -> [MiningMinimumWork]? { values.last }
    func count() -> Int { values.count }
}

private actor HierarchyVolumeProbe: IvyDelegate, IvyContentSource {
    private let hello: Data
    private var helloCount = 0
    private var volumeRequests = 0

    init(hello: Data) {
        self.hello = hello
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        switch message.topic {
        case NodeNetworkTopic.hierarchyHello:
            helloCount += 1
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: hello
            )
        case NodeNetworkTopic.childEvidenceIndexRequest:
            guard let request = try? ChildEvidenceIndexRequestMessage.decoded(
                message.payload
            ), let response = try? ChildEvidenceIndexResponseMessage(
                requestID: request.requestID,
                childPath: request.childPath,
                sourceID: testEvidenceSourceID,
                cursor: 0,
                through: 0,
                entries: [],
                next: 0
            ).encoded() else { return }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.childEvidenceIndexResponse,
                payload: response
            )
        default:
            break
        }
    }

    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) -> [ContentEntry] {
        []
    }

    func volume(rootCID: String, maxDataBytes: Int) -> [ContentEntry] {
        volumeRequests += 1
        return []
    }

    func didReceiveHello() -> Bool { helloCount > 0 }
    func resetVolumeRequests() { volumeRequests = 0 }
    func volumeRequestCount() -> Int { volumeRequests }
}

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
    func testContextualCandidateWireBindsCarrierRewardAndCommittedContent() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let childReward = MiningReward(
            chainPath: ["Nexus", "Payments"],
            transaction: try unsignedTransaction(path: ["Nexus", "Payments"])
        )
        let descendantReward = MiningReward(
            chainPath: ["Nexus", "Payments", "Receipts"],
            transaction: try unsignedTransaction(
                path: ["Nexus", "Payments", "Receipts"]
            )
        )
        let request = ParentTipContextMessage(
            sequence: 11,
            childPath: ["Nexus", "Payments"],
            tipCID: parentCID,
            tipData: parentData,
            rewards: [childReward, descendantReward]
        )
        let decodedRequest = try ParentTipContextMessage.decoded(
            request.encoded()
        )
        XCTAssertEqual(decodedRequest.sequence, 11)
        XCTAssertEqual(decodedRequest.rewards.map(\.chainPath), [
            ["Nexus", "Payments"],
            ["Nexus", "Payments", "Receipts"],
        ])
        XCTAssertNotNil(decodedRequest.rewards[0].transaction.body.node)

        let response = ChildCandidateAvailableMessage(
            sequence: 11,
            childPath: ["Nexus", "Payments"],
            childCID: parentCID,
            blockData: parentData,
            searchWitness: nil
        )
        let decodedResponse = try ChildCandidateAvailableMessage.decoded(
            response.encoded()
        )
        XCTAssertEqual(decodedResponse.childCID, parentCID)
        XCTAssertNil(decodedResponse.searchWitness)

        var forgedTarget = try response.encoded()
        let targetOffset = 8 + 2
            + (2 + "Nexus".utf8.count)
            + (2 + "Payments".utf8.count)
            + 2 + parentCID.utf8.count
        forgedTarget.insert(
            contentsOf: Data(repeating: 0x66, count: 64),
            at: targetOffset
        )
        XCTAssertThrowsError(
            try ChildCandidateAvailableMessage.decoded(forgedTarget)
        )

        XCTAssertThrowsError(try ParentTipContextMessage(
            sequence: 12,
            childPath: ["Nexus", "Payments"],
            tipCID: parentCID,
            tipData: parentData,
            rewards: [MiningReward(
                chainPath: ["Nexus", "Other"],
                transaction: try unsignedTransaction(path: ["Nexus", "Other"])
            )]
        ).encoded())
    }

    func testCandidateWireRejectsMismatchedAndOversizedContent() async throws {
        let block = try await canonicalNetworkBlock()
        let childCID = try BlockHeader(node: block).rawCID
        let blockData = try XCTUnwrap(block.toData())
        func candidate(_ data: Data) -> ChildCandidateAvailableMessage {
            ChildCandidateAvailableMessage(
                sequence: 19,
                childPath: ["Nexus", "Payments"],
                childCID: childCID,
                blockData: data,
                searchWitness: nil
            )
        }

        XCTAssertThrowsError(try candidate(blockData + Data([0])).encoded())
        XCTAssertThrowsError(try candidate(
            Data(repeating: 0, count: Int(IvyConfig.defaultProtocolMaxFrameSize))
        ).encoded())

        XCTAssertThrowsError(try ChildEvidenceAvailableMessage(
            childPath: ["Nexus", "Payments"],
            sourceID: testEvidenceSourceID,
            ordinal: 1,
            childCID: childCID,
            rootCID: childCID,
            attachmentCID: "not-a-cid"
        ).encoded()) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .malformed)
        }
    }

    /// A miner's minimum work rides the candidate request only when it has
    /// entries, so a request without one keeps the exact bytes it always had.
    func testCandidateRequestCarriesMinimumWorkOnlyWhenPresent() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        func request(
            _ minimumWork: [MiningMinimumWork]
        ) -> ParentTipContextMessage {
            ParentTipContextMessage(
                sequence: 21,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: [],
                minimumWork: minimumWork
            )
        }

        let legacy = try request([]).encoded()
        XCTAssertEqual(legacy.suffix(parentData.count), parentData)
        XCTAssertTrue(
            try ParentTipContextMessage.decoded(legacy).minimumWork.isEmpty
        )

        let entries = [
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments"],
                work: UInt256(1) << 32
            ),
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "Receipts"],
                work: UInt256(9)
            ),
        ]
        let encoded = try request(entries).encoded()
        XCTAssertGreaterThan(encoded.count, legacy.count)
        XCTAssertEqual(
            try ParentTipContextMessage.decoded(encoded).minimumWork,
            entries
        )

        // Another subtree, zero work, a truncated trailer, and an empty one
        // (which a present-only-when-used field can never encode) are refused.
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Other"],
            work: UInt256(1)
        )]).encoded())
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: .zero
        )]).encoded())
        // More work than the hardest valid target (1) can represent.
        XCTAssertThrowsError(try request([MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: workForTarget(UInt256(1)) + UInt256(1)
        )]).encoded())
        // Beyond the payload cap the rewards field also honours.
        XCTAssertThrowsError(try request((0..<20_000).map {
            MiningMinimumWork(
                chainPath: ["Nexus", "Payments", "d\($0)"],
                work: UInt256(1) << 16
            )
        }).encoded())
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(encoded + Data([0]))
        )

        // The operator's opt-in to commit the minimum-work target is one
        // The wire carries a search plan and nothing more: there is no
        // trailing commit byte, so a filter cannot travel as a commitment.
        XCTAssertEqual(
            try ParentTipContextMessage.decoded(encoded).minimumWork,
            entries
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(encoded + Data([1])),
            "a trailing byte is not part of this message"
        )
        XCTAssertEqual(
            try ParentTipContextMessage(
                sequence: 21,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: []
            ).encoded(),
            legacy
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([1]))
        )
        // An empty minimum-work trailer (tag 1, length 4, "[]") and an empty
        // carried-child trailer (tag 2, length 0) are refused alike.
        var emptyTrailer = legacy
        emptyTrailer.append(contentsOf: [1, 2, 0, 0, 0])
        emptyTrailer.append(Data("[]".utf8))
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(emptyTrailer)
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([2, 0, 0]))
        )
    }

    /// The carried child rides the context as a tagged trailer after the
    /// minimum work, only when the tip's branch carried one: the legacy
    /// bytes are untouched, trailers are ordered and single, and an empty
    /// or unbounded name is refused.
    func testCandidateRequestNamesTheCarriedChildOnlyWhenPresent() async throws {
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let minimumWork = [MiningMinimumWork(
            chainPath: ["Nexus", "Payments"],
            work: UInt256(1) << 32
        )]
        func request(
            _ carried: String?,
            minimumWork: [MiningMinimumWork] = []
        ) -> ParentTipContextMessage {
            ParentTipContextMessage(
                sequence: 23,
                childPath: ["Nexus", "Payments"],
                tipCID: parentCID,
                tipData: parentData,
                rewards: [],
                minimumWork: minimumWork,
                carriedChildCID: carried
            )
        }

        let legacy = try request(nil).encoded()
        XCTAssertEqual(legacy.suffix(parentData.count), parentData)
        XCTAssertNil(try ParentTipContextMessage.decoded(legacy).carriedChildCID)

        let named = try request(parentCID).encoded()
        XCTAssertEqual(
            try ParentTipContextMessage.decoded(named).carriedChildCID,
            parentCID
        )
        XCTAssertEqual(
            named.count,
            legacy.count + 1 + 2 + parentCID.utf8.count,
            "one tag, one length, the name"
        )
        let both = try request(parentCID, minimumWork: minimumWork).encoded()
        let decodedBoth = try ParentTipContextMessage.decoded(both)
        XCTAssertEqual(decodedBoth.minimumWork, minimumWork)
        XCTAssertEqual(decodedBoth.carriedChildCID, parentCID)

        // Trailers out of order: the carried child before the minimum work.
        let workOnly = try request(nil, minimumWork: minimumWork).encoded()
        var reordered = legacy
        reordered.append(named.suffix(from: legacy.count))
        reordered.append(workOnly.suffix(from: legacy.count))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(reordered))
        // The same trailer twice.
        var twice = named
        twice.append(named.suffix(from: legacy.count))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(twice))
        // An empty name, an unknown tag, a truncated name.
        XCTAssertThrowsError(try request("").encoded())
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(legacy + Data([3, 1, 0]))
        )
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(named.dropLast())
        )
    }

    func testCandidateRequestEnforcesHierarchyRewardAndFrameBounds() async throws {
        XCTAssertEqual(
            ParentTipContextMessage.maximumRewardBytes,
            ChainServiceLimits.maximumPayloadBytes
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let parentData = try XCTUnwrap(parent.toData())
        let maximumDepthPath = ["Nexus"] + Array(
            repeating: String(repeating: "x", count: 64),
            count: 256
        )
        let valid = try ParentTipContextMessage(
            sequence: 15,
            childPath: maximumDepthPath,
            tipCID: parentCID,
            tipData: parentData,
            rewards: []
        ).encoded()
        XCTAssertLessThan(
            valid.count,
            ParentTipContextMessage.maximumEncodedBytes
        )

        // The reward list has no invented count cap; it is bounded structurally by
        // the wire capacity (UInt16 count prefix) and the reward-byte cap. The
        // total message is still bounded by the frame size below.
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(Data(
            repeating: 0,
            count: ParentTipContextMessage.maximumEncodedBytes + 1
        ))) { error in
            XCTAssertEqual(error as? NodeNetworkWireError, .oversized)
        }
    }

    func testCandidateSlotsGiveEveryPathOnePeerBeforeDuplicateClaims() {
        let slots = NodeNetworkRuntime.interleavedChildPeerIndices(
            peerCounts: [4] + Array(repeating: 1, count: 63),
            limit: 64
        )
        XCTAssertEqual(slots.count, 64)
        XCTAssertEqual(Set(slots.map(\.path)).count, 64)
        XCTAssertTrue(slots.allSatisfy { $0.peer == 0 })
    }

    func testCandidateAcquirerIsBoundedFIFOAndDeduplicated() throws {
        var acquirer = CandidateAcquirer()
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "second",
            package: nil
        )).accepted)
        XCTAssertTrue(acquirer.observe(.init(
            blockCID: "first",
            package: nil
        )).accepted)
        let first = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(first.blockCID, "first")
        XCTAssertTrue(acquirer.complete(
            first.ticket,
            resolution: .terminal
        ))
        let second = try XCTUnwrap(acquirer.next())
        XCTAssertEqual(second.blockCID, "second")
        XCTAssertTrue(acquirer.complete(
            second.ticket,
            resolution: .terminal
        ))
        XCTAssertNil(acquirer.next())

        for index in 0..<CandidateAcquirer.readyCapacity {
            XCTAssertTrue(acquirer.observe(.init(
                blockCID: "cid-\(index)",
                package: nil
            )).accepted)
        }
        XCTAssertFalse(acquirer.observe(.init(
            blockCID: "overflow",
            package: nil
        )).accepted)
    }

    func testProofPreparationRotatesAcrossMoreThanSixtyFourChildPaths() {
        let first = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: 0,
            limit: 64
        )
        let second = NodeNetworkRuntime.rotatedPeerIndices(
            peerCount: 65,
            start: first.next,
            limit: 64
        )
        XCTAssertEqual(first.indices.count, 64)
        XCTAssertFalse(first.indices.contains(64))
        XCTAssertTrue(second.indices.contains(64))
        XCTAssertFalse(second.indices.contains(0))
    }

    func testDisconnectedChildPathsCannotAccumulatePeerRotationState() {
        var rotations = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("Nexus/stale-\($0)", $0)
        })
        rotations["Nexus/active"] = 3
        NodeNetworkRuntime.pruneChildPeerRotations(
            &rotations,
            activeRoles: [.child(["Nexus", "active"])]
        )
        XCTAssertEqual(rotations, ["Nexus/active": 3])
    }

    /// A child never asks for a parent template. The parent pushes its
    /// context (its validated tip) when the child wires in; the child builds
    /// its candidate against the tip's post-state, reading the tip from the
    /// parent's own session and nothing from anyone else, and pushes the
    /// candidate up; the parent's next template finds it already held.
    func testChildPushesACandidateForThePushedParentTipAndTheParentHoldsIt()
        async throws
    {
        let descendantKey = signingKey(0x91)
        let fixture = try await provisionalRootFixture(keyByte: 0x8f)
        let parentTip = try await fixture.parentProcess.validatedTipBlock()
        let parentTipCID = try BlockHeader(node: parentTip).rawCID
        let builds = NetworkEventRecorder()
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { context, parentSource in
                // The carrier the child builds against is the parent's tip's
                // post-state, and the tip itself is fetched from the parent.
                guard context.parentCarrier.prevState.rawCID
                    == parentTip.postState.rawCID else {
                    throw NetworkTestError.failedPhase("carrier on the parent tip")
                }
                let fetched = await parentSource.fetch([parentTipCID])
                guard fetched[parentTipCID] == parentTip.toData() else {
                    throw NetworkTestError.failedPhase(
                        "parent tip content from the parent session"
                    )
                }
                await builds.append(parentTipCID)
                return fixture.candidate
            },
            admission: { _ in throw CancellationError() }
        )
        let descendantHello = try ChainHello(
            nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
            chainPath: fixture.childConfiguration.chainPath + ["Leaf"]
        ).encode()
        let probe = HierarchyVolumeProbe(hello: descendantHello)
        let descendant = Ivy(config: IvyConfig(
            signingKey: descendantKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            privateContentExchangeEnabled: true,
            mode: .privateNetwork
        ))
        await descendant.installTestDelegate(probe)
        await descendant.setContentSource(probe)

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            try await descendant.start()
            try await descendant.connect(to: PeerEndpoint(
                publicKey: fixture.childConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.childConfiguration.factListenPort
            ))
            for _ in 0..<250 {
                if await probe.didReceiveHello() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard await probe.didReceiveHello() else {
                throw NetworkTestError.failedPhase("descendant hierarchy hello")
            }
            await probe.resetVolumeRequests()

            // No template was requested, and the parent asked for nothing:
            // the candidate is simply held once the child pushed it.
            try await waitForChildCandidate(fixture)
            let candidates = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            let descendantVolumeRequests = await probe.volumeRequestCount()
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(descendantVolumeRequests, 0)
            let buildsAfterFirst = await builds.snapshot().count
            XCTAssertEqual(buildsAfterFirst, 1, "built once per context")
            // Asking again costs no round trip and no rebuild.
            let again = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            XCTAssertEqual(again.count, 1)
            let buildsAfterSecond = await builds.snapshot().count
            XCTAssertEqual(buildsAfterSecond, 1)
            let digestInput = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: fixture.context.parentCarrier.prevState.rawCID
            )
            let candidateCID = try BlockHeader(node: fixture.candidate.block).rawCID
            XCTAssertEqual(digestInput, ["Payments:\(candidateCID)"])
        } catch {
            await descendant.stop()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await descendant.stop()
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// The parent pushes a miner's minimum work to the child that builds the
    /// block, and only the entries at or below that child; the same plan
    /// again pushes nothing, a changed plan pushes once more.
    func testParentPushesDescendantMinimumWorkAndTheChildBuildsWithIt() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x96)
        let received = MinimumWorkRecorder()
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { context, _ in
                await received.record(context.minimumWork)
                return fixture.candidate
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            try await waitForChildCandidate(fixture)
            let initialPlan = await received.last()
            XCTAssertEqual(initialPlan, [])

            let childEntry = MiningMinimumWork(
                chainPath: ["Nexus", "Payments"],
                work: UInt256(1) << 8
            )
            await fixture.parentRuntime.updateDescendantPlan(
                rewards: [],
                minimumWork: [
                    MiningMinimumWork(
                        chainPath: ["Nexus"],
                        work: UInt256(1) << 20
                    ),
                    childEntry,
                ]
            )
            for _ in 0..<250 {
                if await received.last() == [childEntry] { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            // The parent's own minimum is the parent's business, not the
            // child's: only the child's entry crosses.
            let forwarded = await received.last()
            XCTAssertEqual(forwarded, [childEntry])
            let builds = await received.count()

            // The same plan again is not a change: nothing is pushed.
            await fixture.parentRuntime.updateDescendantPlan(
                rewards: [],
                minimumWork: [
                    MiningMinimumWork(
                        chainPath: ["Nexus"],
                        work: UInt256(1) << 20
                    ),
                    childEntry,
                ]
            )
            try await alwaysDuring("a repeated plan builds nothing new", .milliseconds(300)) {
                await received.count() == builds
            }
            let buildsAfterRepeat = await received.count()
            XCTAssertEqual(buildsAfterRepeat, builds)
            let candidates = await fixture.parentRuntime.directChildCandidates(
                ChildCandidateRequestContext(
                    parentCarrier: fixture.context.parentCarrier,
                    rewards: [],
                    minimumWork: [childEntry]
                )
            )
            XCTAssertEqual(candidates.count, 1)
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// When the parent's tip moves, the candidate the child pushed for the
    /// old tip is not carried (its parent state is stale); the parent pushes
    /// the new tip, the child rebuilds on it and pushes again, and only then
    /// is a candidate held for the new tip. A restarted parent session
    /// starts the child over the same way.
    func testParentTipChangeDropsTheStaleCandidateUntilTheChildRepushes()
        async throws
    {
        let fixture = try await provisionalRootFixture(keyByte: 0x9a)
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            for _ in 0..<250 {
                if await childService.status().phase == .active { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await waitForChildCandidate(fixture)

            // The parent's tip moves to a block that CHANGES its state (an
            // empty block leaves the post-state, and so every candidate
            // built on it, exactly as valid as before): anchoring another
            // child genesis.
            let oldTip = try await fixture.parentProcess.validatedTipBlock()
            let otherGenesis = try await ChildGenesisBuilder.build(
                seed: ChildGenesisSeed(
                    spec: NexusGenesis.spec, premineTo: nil,
                    timestamp: oldTip.timestamp + 500
                ),
                chainPath: ["Nexus", "Other"],
                fetcher: fixture.parentProcess
            )
            let otherAnchor = try signedGenesisAnchorTransaction(
                directory: "Other",
                childGenesisCID: try BlockHeader(node: otherGenesis).rawCID,
                chainPath: ["Nexus"]
            )
            try await VolumeImpl<Transaction>(node: otherAnchor).storeRecursively(
                storer: fixture.parentProcess
            )
            let next = try await BlockBuilder.buildBlock(
                previous: oldTip,
                transactions: [otherAnchor],
                timestamp: oldTip.timestamp + 1_000,
                nonce: 3,
                fetcher: fixture.parentProcess
            )
            XCTAssertNotEqual(next.postState.rawCID, oldTip.postState.rawCID)
            let admitted = try await fixture.parentProcess.admit(
                try BlockHeader(node: next)
            )
            XCTAssertTrue(admitted.decision.isAccepted)
            await fixture.parentRuntime.chainStateChanged()
            let newProvisional = try await BlockBuilder.buildBlock(
                previous: next,
                timestamp: next.timestamp + 1_000,
                nonce: 4,
                fetcher: fixture.parentProcess
            )
            let newContext = ChildCandidateRequestContext(
                parentCarrier: newProvisional,
                rewards: []
            )
            // The child rebuilds on the new tip and pushes; until then the
            // stale candidate is not carried for the new tip.
            var heldForNewTip: [DirectChildCandidate] = []
            for _ in 0..<500 {
                heldForNewTip = await fixture.parentRuntime.directChildCandidates(
                    newContext
                )
                if !heldForNewTip.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(heldForNewTip.count, 1, "rebuilt for the new tip")
            XCTAssertEqual(
                heldForNewTip.first?.block.parentState.rawCID,
                next.postState.rawCID
            )
            // The old context no longer has a candidate: the child's latest
            // replaced it.
            let heldForOldTip = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            XCTAssertTrue(heldForOldTip.isEmpty)
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// Once this chain has carried a child's block, neither that block nor
    /// a sibling of it (another candidate on the same child parent) is
    /// carried again: the child admits the carried block and builds on it,
    /// and every sibling carried meanwhile would only reorg the child's tip
    /// to the heavier carrier, so a child could never get ahead of its own
    /// forks. The next candidate, built on the carried block, is carried.
    /// The parent's context names the child block its branch carried; the
    /// child holds its offer until it admits that block, and the parent
    /// does not carry the named block again. Once the child admits it, the
    /// candidate it builds on it is carried.
    func testACarriedChildBlockIsNamedToTheChildAndNotCarriedAgain() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9e)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            var held: [DirectChildCandidate] = []
            for _ in 0..<250 {
                held = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !held.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let first = try XCTUnwrap(held.first)
            XCTAssertEqual(first.block.height, 1)
            let firstHeader = try BlockHeader(node: first.block)

            // This chain carries it: a children-only carrier leaves the
            // post-state, so the fixture context still names this tip's
            // state. Admitted through the service, which publishes the
            // child proof, as a mined block's admission does.
            let parentTip = try await fixture.parentProcess.validatedTipBlock()
            let carrier = try await BlockBuilder.buildBlock(
                previous: parentTip,
                children: ["Payments": first.block],
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
            // As the mined-block path does: the child proof is prepared
            // before the carrier's admission, and the admission publishes it.
            _ = try await fixture.parentProcess.prepareChildProofs(
                for: carrier,
                children: [first],
                capacity: 16
            )
            let carried = try await parentService.admitNetworkCandidate(
                carrierHeader,
                authenticatedChildPackage: nil,
                preparingChildDirectories: ["Payments"],
                contentSource: fixture.parentProcess
            )
            XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
            // Bounded poll, not a fixed wait: the parent re-mints its context
            // after the carrier validates, and a sanitizer build is slow.
            var afterCarry = await fixture.parentRuntime.directChildCandidates(
                fixture.context
            )
            for _ in 0..<500 where !afterCarry.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                afterCarry = await fixture.parentRuntime.directChildCandidates(
                    fixture.context
                )
            }
            XCTAssertTrue(afterCarry.isEmpty, "the carried block is not carried again")
            let digest = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: fixture.context.parentCarrier.prevState.rawCID
            )
            XCTAssertTrue(digest.isEmpty, "nor is it a template input")
            // The child was told which block was carried, at push latency,
            // and offers nothing on the tip before it.
            var named: String?
            for _ in 0..<250 {
                named = await fixture.childRuntime.receivedCarriedChildCIDForTesting()
                if named != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(named, firstHeader.rawCID, "the context names the carried block")
            // The hold is the child's own: its offer task deferred behind the
            // named block, which this child has not admitted. (Here the
            // admission handler throws, so the scan round that serves the
            // block finds nothing holding an attempt for it and releases the
            // hold again: what is pinned is that the hold happened.)
            var holds = 0
            for _ in 0..<250 {
                holds = await fixture.childRuntime.carriedHoldCountForTesting()
                if holds > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(holds, 0, "the child held its offer behind the carried block")

            // The child admits and validates its carried block, then builds
            // on it; that candidate is carried.
            let childGenesis = try await fixture.childProcess.validatedTipBlock()
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
                        toStateCID: first.block.parentState.rawCID
                    )
                )
            )
            let weighed = try await fixture.childProcess.admit(
                firstHeader,
                authenticatedChildPackage: package,
                remoteSource: fixture.parentProcess,
                mode: .weighed
            )
            XCTAssertTrue(weighed.decision.isAccepted, "\(weighed.decision)")
            let validated = try await fixture.childProcess.admit(
                firstHeader,
                authenticatedChildPackage: package,
                remoteSource: fixture.parentProcess,
                mode: .validate
            )
            XCTAssertTrue(validated.decision.isAccepted, "\(validated.decision)")
            await fixture.childRuntime.chainStateChanged()
            var next: [DirectChildCandidate] = []
            for _ in 0..<250 {
                next = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !next.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(next.first?.block.height, 2, "built on the carried block")
            XCTAssertEqual(next.first?.block.parent?.rawCID, firstHeader.rawCID)
            let stillHeld = await fixture.childRuntime.candidateOfferHeldForTesting()
            XCTAssertFalse(stillHeld, "the hold lifts once the carried block is admitted")
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// A weighed block ahead of the validated tip with no walk stepping —
    /// parked on a fact it cannot get, or never armed — does not withhold
    /// the child's candidate: the child builds on its validated tip, since
    /// that is how a chain outweighs a branch it cannot validate.
    func testAParkedValidateWalkDoesNotWithholdTheChildsCandidate() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9c)
        // No evidence source: the walk the deferral arms parks on the
        // continuity fact it cannot get, and the retry is out of the way.
        let childRuntime = fixture.childRuntime
        let childService = ChainService(
            process: fixture.childProcess,
            childCandidateProvider: { _ in [] },
            chainStateChangePublisher: { [weak childRuntime] in
                await childRuntime?.chainStateChanged()
            },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            validateWalkRetryInterval: .seconds(60)
        )
        let childHandlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak childService] context, parentSource in
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        let weighedOnly = try await weighedOnlyChildBlock(fixture)
        let tips = await fixture.childProcess.metricsTipHeights()
        XCTAssertEqual(tips.weighed, 1)
        XCTAssertEqual(tips.validated, 0)

        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                handlers: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                handlers: childHandlers
            )
            var held: [DirectChildCandidate] = []
            for _ in 0..<250 {
                held = await fixture.parentRuntime.directChildCandidates(fixture.context)
                if !held.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(held.count, 1, "offered with the walk parked")
            XCTAssertEqual(held.first?.block.height, 1, "built on the validated tip")
            XCTAssertNotEqual(
                held.first.map { try? BlockHeader(node: $0.block).rawCID },
                weighedOnly.header.rawCID
            )
        } catch {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
            throw error
        }
        await fixture.childRuntime.stop()
        await fixture.parentRuntime.stop()
    }

    /// A child whose last candidate landed and awaits validation builds no
    /// other (a second at the same height would only fork it): the request
    /// arms the walk if nothing did, and while the walk steps nothing is
    /// built either. When the walk stops, the service reports a state
    /// change so the deferred candidate is offered, built on the tip the
    /// walk reached.
    func testChildCandidateWaitsWhileTheValidateWalkSteps() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9d)
        let weighedOnly = try await weighedOnlyChildBlock(fixture)
        let gate = Latch()
        let changes = NetworkEventRecorder()
        let parentProcess = fixture.parentProcess
        let package = weighedOnly.package
        let childService = ChainService(
            process: fixture.childProcess,
            childCandidateProvider: { _ in [] },
            chainStateChangePublisher: { await changes.append("change") },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            validateBodySource: { _, admit in
                await gate.wait()
                return try await admit(parentProcess)
            },
            validateEvidenceSource: { _, _ in package }
        )
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
        let carried = try await fixture.parentProcess.admit(carrierHeader)
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
        let weighed = try await fixture.childProcess.admit(
            weighedHeader,
            authenticatedChildPackage: package,
            remoteSource: fixture.parentProcess,
            mode: .weighed
        )
        XCTAssertTrue(weighed.decision.isAccepted, "\(weighed.decision)")
        return (weighedHeader, package)
    }

    private func provisionalRootFixture(
        keyByte: UInt8
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
            factListenPort: NetworkTransportTestPorts.allocate(),
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
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate(),
            parentEndpoint: ParentEndpoint(
                publicKey: parentConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: parentConfiguration.factListenPort
            )
        )
        let parentRuntime = try NodeNetworkRuntime(configuration: parentConfiguration)
        let childRuntime = try NodeNetworkRuntime(
            configuration: childConfiguration
        )
        let parentProcess = try await ChainProcess.open(
            configuration: parentConfiguration
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
        let carrierAdmission = try await parentProcess.admit(carrierHeader)
        XCTAssertTrue(carrierAdmission.decision.isAccepted)
        let activated = try await childProcess.activateSeededChildGenesis(
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
                rewards: []
            ),
            candidate: DirectChildCandidate(
                directory: "Payments",
                block: candidateBlock
            )
        )
    }

    private func waitForChildCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws {
        try await eventually("direct child candidate session") {
            await fixture.parentRuntime.directChildCandidates(fixture.context).count == 1
        }
    }
}
