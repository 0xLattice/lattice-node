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

/// Answers nothing until released (at teardown), long after any request
/// deadline.
private struct StallingContentSource: IvyContentSource {
    let release: Latch

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await release.wait()
        return []
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        await release.wait()
        return []
    }
}

/// Counts the parent's serves of the attachment Volume of the evidence it
/// issued for `childCID`.
private actor EvidenceServeProbe {
    private(set) var carriedChild: String?
    private(set) var serves = 0
    private(set) var stalledRoot: String?
    private(set) var watchedRoots: Set<String> = []
    private(set) var rootServes = 0
    let release = Latch()

    func watch(_ childCID: String) { carriedChild = childCID }
    func watchRoots(_ roots: Set<String>) { watchedRoots = roots }
    func servedRoot() { rootServes += 1 }
    func stall(_ rootCID: String) { stalledRoot = rootCID }
    func served() { serves += 1 }
}

private struct ProbedContentSource: IvyContentSource {
    let parent: ChainProcess
    let probe: EvidenceServeProbe

    private var inner: ChainProcessIvyContentSource {
        ChainProcessIvyContentSource(process: parent)
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await inner.content(rootCID: rootCID, cids: cids, maxDataBytes: maxDataBytes)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        if await probe.stalledRoot == rootCID {
            await probe.release.wait()
            return []
        }
        if await probe.watchedRoots.contains(rootCID) {
            await probe.servedRoot()
        }
        if let child = await probe.carriedChild,
           let issued = try? await parent.store.issuedChildEvidence(
               childCID: child, directory: "Payments"
           ),
           issued.attachmentCID == rootCID {
            await probe.served()
        }
        return await inner.volume(rootCID: rootCID, maxDataBytes: maxDataBytes)
    }
}

/// The block a child's candidate builder returns instead of building one.
private actor CandidateOverride {
    private(set) var block: Block?
    func set(_ block: Block?) { self.block = block }
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
        // An empty minimum-work trailer (tag 1, length 4, "[]") is refused.
        var emptyTrailer = legacy
        emptyTrailer.append(contentsOf: [1, 2, 0, 0, 0])
        emptyTrailer.append(Data("[]".utf8))
        XCTAssertThrowsError(
            try ParentTipContextMessage.decoded(emptyTrailer)
        )
    }

    /// The context carries the parent's tip and the miner's plan, and
    /// nothing about what the parent carried: a carried-child trailer (tag
    /// 2) is an unknown tag, refused like any other.
    func testParentTipContextNamesNoCarriedChild() async throws {
        XCTAssertEqual(
            NodeNetworkTopic.parentTipAvailable,
            "lattice.hierarchy.parent-tip.available.v1"
        )
        let parent = try await canonicalNetworkBlock()
        let parentCID = try BlockHeader(node: parent).rawCID
        let bare = try ParentTipContextMessage(
            sequence: 23,
            childPath: ["Nexus", "Payments"],
            tipCID: parentCID,
            tipData: try XCTUnwrap(parent.toData()),
            rewards: []
        ).encoded()
        // Tag 2, a two-byte length, the name.
        var named = bare
        named.append(contentsOf: [2, 0, UInt8(parentCID.utf8.count)])
        named.append(Data(parentCID.utf8))
        XCTAssertThrowsError(try ParentTipContextMessage.decoded(named))
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
        let childHandlers = ClosureChainInterface(
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
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
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
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, _ in
                await received.record(context.minimumWork)
                return fixture.candidate
            },
            admission: { _ in throw CancellationError() }
        )
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
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
        let childHandlers = ClosureChainInterface(
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
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
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
            let admitted = try await fixture.parentProcess.importBlock(
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

    /// The parent carries the child's block A, and does not carry A again
    /// nor count it as a template input. The child, not yet having admitted
    /// A, offers A', a sibling on A's parent: that is carried, and fork
    /// choice at the child settles the two.
    func testTheCarriedChildBlockIsNotCarriedAgainButASiblingIs() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9e)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let override = CandidateOverride()
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { [weak childService] context, parentSource in
                if let block = await override.block {
                    return DirectChildCandidate(directory: "Payments", block: block)
                }
                guard let childService else { return nil }
                return try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { _ in throw CancellationError() }
        )
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            XCTAssertEqual(first.block.height, 1)
            let carrier = try await storeCarrier(
                of: first, fixture: fixture
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture
            )
            try await eventually("the parent's context is on the carrier") {
                await fixture.parentRuntime.parentTipContextCIDForTesting()
                    == carrier.rawCID
            }
            let onCarrier = try await contextOnValidatedTip(fixture)
            let afterCarry = await fixture.parentRuntime.directChildCandidates(onCarrier)
            XCTAssertTrue(afterCarry.isEmpty, "the carried block is not carried again")
            let afterCarryDigest = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: onCarrier.parentCarrier.prevState.rawCID
            )
            XCTAssertTrue(afterCarryDigest.isEmpty, "nor is it a template input")

            // A sibling of A: built on A's parent, the child genesis.
            let sibling = try await siblingOf(first, fixture: fixture)
            let siblingCID = try BlockHeader(node: sibling).rawCID
            await override.set(sibling)
            await fixture.childRuntime.chainStateChanged()
            try await eventually("the parent holds the sibling offer") {
                await fixture.parentRuntime.heldOfferCIDsForTesting()
                    .contains(siblingCID)
            }
            let siblings = await fixture.parentRuntime.directChildCandidates(onCarrier)
            XCTAssertEqual(
                try siblings.map { try BlockHeader(node: $0.block).rawCID },
                [siblingCID],
                "a sibling of the carried block is carried"
            )
            let siblingDigest = await fixture.parentRuntime.childCandidateDigestInput(
                parentStateCID: onCarrier.parentCarrier.prevState.rawCID
            )
            XCTAssertEqual(siblingDigest, ["Payments:\(siblingCID)"])
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// An overlay peer announces the carried block and never serves it.
    /// The carry decision reads nothing an overlay peer says: the child
    /// admits the block from the parent's evidence, and its extension is
    /// carried.
    func testAnOverlayAnnouncerThatNeverServesTheCarriedBlockCannotStallTheChild() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xa6)
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { admission in
                try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
        let attacker = carriedAnnouncer(keyByte: 0xa6)
        await attacker.setContentSource(StallingContentSource(release: Latch()))
        var announcing: Task<Void, Never>?
        func stopAll() async {
            announcing?.cancel()
            await attacker.stop()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            announcing = try await announceRepeatedly(
                firstCID, from: attacker, to: fixture
            )
            try await eventually("the announced carried CID is tracked") {
                await fixture.childRuntime.blockFetcher.tracks(firstCID)
            }
            let carrier = try await storeCarrier(
                of: first, fixture: fixture
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture
            )
            // The announcer's stalled Volume requests cost the fetch up to
            // two request timeouts; the parent's evidence still lands it.
            try await eventually("the child admits the carried block", within: .seconds(90)) {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            var next: [DirectChildCandidate] = []
            try await eventually("the extension is carried") {
                let context = try await self.contextOnValidatedTip(fixture)
                next = await fixture.parentRuntime.directChildCandidates(context)
                return next.first?.block.parent?.rawCID == firstCID
            }
            XCTAssertEqual(next.first?.block.height, 2)
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The child's parent-evidence inbox is full (one parked entry fills a
    /// one-entry inbox) when the parent carries its block and announces the
    /// evidence. Nothing fetches what the inbox would refuse: the parent
    /// never serves the attachment while the inbox stays full, and once
    /// the inbox has room the block is admitted.
    func testAFullInboxCostsTheParentNoFetches() async throws {
        let fixture = try await provisionalRootFixture(
            keyByte: 0xe6, childInboxCapacity: 1
        )
        let parentService = networkService(
            process: fixture.parentProcess,
            runtime: fixture.parentRuntime
        )
        let probe = EvidenceServeProbe()
        // The filler: a parent-evidence entry for another block, held in
        // the inbox (its admission waits on a fact the parent will send),
        // which fills it.
        let filler = try await fabricatedEvidence(for: fixture.candidate, fixture: fixture)
        try await fixture.childProcess.store.storeParentEvidenceInbox(
            sourceID: testEvidenceSourceID,
            ordinal: 1_000,
            attachment: filler.attachment,
            package: filler.package,
            advanceScan: false
        )
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        let childHandlers = ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { admission in
                if admission.header.rawCID == filler.childCID {
                    return NodeImportOutcome(
                        decision: .unavailable(.parentStateContinuity(
                            parentPath: ["Nexus"],
                            fromStateCID: LatticeState.emptyHeader.rawCID,
                            toStateCID: testCID("filler-parent-state")
                        )),
                        parentCarrierLink: nil,
                        sameChainPredecessor: nil
                    )
                }
                return try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess,
                chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
            )
            let first = try await firstHeldCandidate(fixture)
            let firstCID = try BlockHeader(node: first.block).rawCID
            let full = try await fixture.childProcess.store.parentEvidenceInboxHasCapacity()
            XCTAssertFalse(full, "the filler fills the inbox")
            await probe.watch(firstCID)

            let carrier = try await storeCarrier(
                of: first, fixture: fixture
            )
            try await admitCarrier(
                carrier, service: parentService, fixture: fixture
            )
            try await alwaysDuring("the block waits while the inbox is full", .seconds(2)) {
                await !fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            let servedWhileFull = await probe.serves
            XCTAssertEqual(
                servedWhileFull, 0,
                "the full inbox cost the parent \(servedWhileFull) fetches"
            )

            // An import consumes the filler: room, and what an admission
            // that consumes an inbox entry does next (the capacity seam and
            // a scan of the parent's index).
            try await fixture.childProcess.store.consumeParentEvidence(
                childCID: filler.childCID, rootCID: filler.package.package.proof.rootCID
            )
            await fixture.childRuntime.parentEvidenceCapacityBecameAvailable()
            await fixture.childRuntime.requestEvidenceIndex()
            try await eventually("the carried block is admitted once the inbox has room") {
                await fixture.childProcess.hasAcceptedBlock(firstCID)
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    // MARK: - Orphaned parent evidence

    /// The attacker's evidence, stored in the child's inbox as a parent
    /// scan would retain it. Each block is built on `previous`.
    private func attackerEvidence(
        count: Int,
        on previous: Block,
        timestamp: (Int) -> Int64,
        firstOrdinal: UInt64,
        served: Bool = false,
        fixture: ProvisionalRootFixture
    ) async throws -> [(childCID: String, attachmentCID: String)] {
        let content = CoalescingFetcher(CompositeContentSource([
            fixture.parentProcess, fixture.childProcess,
        ]))
        var cids: [(childCID: String, attachmentCID: String)] = []
        for index in 0..<count {
            let block = try await BlockBuilder.buildBlock(
                previous: previous,
                timestamp: timestamp(index),
                nonce: UInt64(index) + 100,
                fetcher: content
            )
            try await BlockHeader(node: block).storeBlock(
                fetcher: content, storer: fixture.parentProcess
            )
            let evidence = try await fabricatedEvidence(
                for: DirectChildCandidate(directory: "Payments", block: block),
                fixture: fixture
            )
            if served {
                // The parent serves the attachment, as it does its index.
                try await evidence.attachment.store(storer: fixture.parentProcess)
            }
            try await fixture.childProcess.store.storeParentEvidenceInbox(
                sourceID: testEvidenceSourceID,
                ordinal: firstOrdinal + UInt64(index),
                attachment: evidence.attachment,
                package: evidence.package,
                advanceScan: false
            )
            cids.append((evidence.childCID, evidence.attachment.rawCID))
        }
        return cids
    }

    /// Child handlers that answer `stub` for the blocks it names and admit
    /// every other block through the child's service.
    private func stubbedChildHandlers(
        _ fixture: ProvisionalRootFixture,
        stub: @escaping @Sendable (String, NetworkCandidateImport) async throws -> NodeImportOutcome?
    ) -> ClosureChainInterface {
        let childService = networkService(
            process: fixture.childProcess,
            runtime: fixture.childRuntime
        )
        return ClosureChainInterface(
            childCandidateBuilder: { context, parentSource in
                try await childService.miningCandidate(
                    for: context,
                    parentContentSource: parentSource
                )
            },
            admission: { admission in
                if let outcome = try await stub(admission.header.rawCID, admission) {
                    return outcome
                }
                return try await childService.importNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource,
                    weighed: admission.weighed
                )
            }
        )
    }

    /// A child block on `previous` that a parent block on `parentBlock`
    /// (the parent's tip unless named) can carry: its parent state is that
    /// carrier's pre-state.
    private func carriableChildBlock(
        on previous: Block,
        nonce: UInt64,
        parentBlock: Block? = nil,
        spacing: Int64 = 1_000,
        content: any Fetcher,
        fixture: ProvisionalRootFixture
    ) async throws -> Block {
        let parentTip: Block
        if let parentBlock {
            parentTip = parentBlock
        } else {
            parentTip = try await fixture.parentProcess.validatedTipBlock()
        }
        let provisional = try await BlockBuilder.buildBlock(
            previous: parentTip,
            timestamp: parentTip.timestamp + spacing,
            nonce: 2,
            fetcher: content
        )
        return try await BlockBuilder.buildBlock(
            previous: previous,
            parentChainBlock: provisional,
            timestamp: provisional.timestamp,
            target: .max,
            nonce: nonce,
            fetcher: content
        )
    }

    /// The parent mines a block carrying no child.
    private func advanceParent(
        spacing: Int64 = 1_000,
        content: any Fetcher,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws {
        let tip = try await fixture.parentProcess.validatedTipBlock()
        let block = try await BlockBuilder.buildBlock(
            previous: tip, timestamp: tip.timestamp + spacing, nonce: 11, fetcher: content
        )
        let header = try BlockHeader(node: block)
        try await header.storeBlock(fetcher: content, storer: fixture.parentProcess)
        let admitted = try await service.importNetworkCandidate(
            header,
            authenticatedChildPackage: nil,
            preparingChildDirectories: [],
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
    }

    /// The parent carries `block` in a block of its own on `parentBlock`,
    /// with evidence, and admits it (a side block when `parentBlock` is not
    /// its tip).
    private func carryOnParentFork(
        _ block: Block,
        on parentBlock: Block,
        spacing: Int64 = 1_000,
        content: any Fetcher,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws {
        try await BlockHeader(node: block).storeBlock(
            fetcher: content, storer: fixture.parentProcess
        )
        let carrier = try await BlockBuilder.buildBlock(
            previous: parentBlock,
            children: ["Payments": block],
            timestamp: parentBlock.timestamp + spacing,
            nonce: 9,
            fetcher: content
        )
        let carrierHeader = try BlockHeader(node: carrier)
        try await carrierHeader.storeBlock(fetcher: content, storer: fixture.parentProcess)
        _ = try await fixture.parentProcess.prepareChildProofs(
            for: carrier,
            children: [DirectChildCandidate(directory: "Payments", block: block)],
            capacity: 16
        )
        let admitted = try await service.importNetworkCandidate(
            carrierHeader,
            authenticatedChildPackage: nil,
            preparingChildDirectories: ["Payments"],
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(admitted.decision.isAccepted, "\(admitted.decision)")
    }

    /// The parent carries `block` in a block of its own, with evidence: its
    /// index then serves the block's evidence to the child.
    private func carryOnParent(
        _ block: Block,
        content: any Fetcher,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws -> String {
        try await BlockHeader(node: block).storeBlock(
            fetcher: content, storer: fixture.parentProcess
        )
        let carrier = try await storeCarrier(
            of: DirectChildCandidate(directory: "Payments", block: block),
            fixture: fixture
        )
        try await admitCarrier(
            carrier, service: service, fixture: fixture
        )
        return try BlockHeader(node: block).rawCID
    }

    private func orphanCount(_ fixture: ProvisionalRootFixture) async -> Int {
        await fixture.childRuntime.orphanedParentEvidenceForTesting().count
    }

    private func orphaned(_ fixture: ProvisionalRootFixture) async -> Set<String> {
        Set(await fixture.childRuntime.orphanedParentEvidenceForTesting().keys)
    }

    /// Admits the child's first held candidate through a parent carrier and
    /// waits for the child to import it.
    private func admitCarriedBlock(
        _ fixture: ProvisionalRootFixture,
        service: ChainService
    ) async throws {
        let first = try await firstHeldCandidate(fixture)
        let firstCID = try BlockHeader(node: first.block).rawCID
        let carrier = try await storeCarrier(
            of: first, fixture: fixture
        )
        try await admitCarrier(
            carrier, service: service, fixture: fixture
        )
        try await eventually("the carried block is admitted") {
            await fixture.childProcess.hasAcceptedBlock(firstCID)
        }
    }

    /// A parent miner carries, one parent block each, a full inbox of child
    /// blocks descending from a block it withholds; the parent relays their
    /// evidence unvalidated. Each import parks behind the missing
    /// predecessor. Before, a parked entry kept its inbox slot until it
    /// decided, which it never does: the inbox stayed full, the honest
    /// carried block waited for room forever, and the chain stopped. Now
    /// each leaves the inbox as an orphan and the carried block is admitted.
    func testWithheldPredecessorDescendantsCannotFillTheInbox() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xe7)
        let parentService = networkService(
            process: fixture.parentProcess, runtime: fixture.parentRuntime
        )
        let capacity = NodeResourcePolicy.default.maximumPendingParentEvidence
        let withheld = testCID("withheld-predecessor")
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let fillers = Set(try await attackerEvidence(
            count: capacity,
            on: childGenesis,
            timestamp: { childGenesis.timestamp + Int64($0) + 1 },
            firstOrdinal: 1_000,
            fixture: fixture
        ).map(\.childCID))
        let room = try await fixture.childProcess.store.parentEvidenceInboxHasCapacity()
        XCTAssertFalse(room, "the attacker's evidence fills the inbox")
        let childHandlers = stubbedChildHandlers(fixture) { cid, _ in
            guard fillers.contains(cid) else { return nil }
            return NodeImportOutcome(
                decision: .unavailable(nil),
                parentCarrierLink: nil,
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: cid, predecessorCID: withheld
                )
            )
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            try await eventually("every attacker entry leaves the inbox as an orphan") {
                await self.orphaned(fixture) == fillers
            }
            let inbox = try await fixture.childProcess.store.parentEvidenceInbox()
            XCTAssertTrue(inbox.isEmpty, "no orphan holds inbox room")
            try await admitCarriedBlock(fixture, service: parentService)
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A parent miner carries a full inbox of child blocks stamped a century
    /// ahead: not yet valid, which no parent fact changes. Before, each kept
    /// its inbox slot and the chain stopped; now each is an orphan until its
    /// time, and the carried block is admitted.
    func testFutureStampedDescendantsCannotFillTheInbox() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xe8)
        let parentService = networkService(
            process: fixture.parentProcess, runtime: fixture.parentRuntime
        )
        let capacity = NodeResourcePolicy.default.maximumPendingParentEvidence
        let century: Int64 = 100 * 365 * 24 * 60 * 60 * 1_000
        let future = ParentEvidenceOrphans.clock() + century
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let fillers = Set(try await attackerEvidence(
            count: capacity,
            on: childGenesis,
            timestamp: { future + Int64($0) },
            firstOrdinal: 2_000,
            fixture: fixture
        ).map(\.childCID))
        let childHandlers = stubbedChildHandlers(fixture) { cid, _ in
            guard fillers.contains(cid) else { return nil }
            return NodeImportOutcome(
                decision: .temporarilyInvalid,
                parentCarrierLink: nil,
                sameChainPredecessor: nil,
                notBefore: future
            )
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            try await eventually("every future-stamped entry leaves the inbox as an orphan") {
                await self.orphaned(fixture) == fillers
            }
            let retries = await fixture.childRuntime.orphanedParentEvidenceForTesting().values
            XCTAssertTrue(
                retries.allSatisfy { $0 == .notBefore(future) }, "each waits for its time"
            )
            try await admitCarriedBlock(fixture, service: parentService)
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// Late orphans (behind a late block) and withheld ones, as the trigger
    /// meets them.
    private struct OrphanScenario {
        let lateBlock: Block
        let lateHeader: BlockHeader
        let behindLate: Set<String>
        /// The late orphans in the parent's index order.
        let lateOrdered: [String]
        let behindWithheld: Set<String>
        /// Undecided with no specific trigger (not yet valid, no time named).
        let undecided: Set<String>
        let attachments: [String: String]
        let admissions: NetworkEventRecorder
        /// Blocks whose entries wait in the inbox on a parent fact.
        let parentFactWaits: NetworkEventRecorder
        let handlers: ClosureChainInterface
    }

    /// `late` orphans behind a late block, `withheld` behind a block never
    /// published, `undecided` with no specific trigger, their evidence
    /// served by the parent. A late orphan decides (refused) once the late
    /// block is accepted.
    private func orphanScenario(
        late: Int,
        withheld: Int,
        undecided: Int = 0,
        fixture: ProvisionalRootFixture
    ) async throws -> OrphanScenario {
        let withheldCID = testCID("withheld-predecessor")
        let content = CoalescingFetcher(CompositeContentSource([
            fixture.parentProcess, fixture.childProcess,
        ]))
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let lateBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: childGenesis.timestamp + 1,
            nonce: 99,
            fetcher: content
        )
        let lateHeader = try BlockHeader(node: lateBlock)
        let lateCID = lateHeader.rawCID
        let entries = try await attackerEvidence(
            count: late + withheld + undecided,
            on: lateBlock,
            timestamp: { lateBlock.timestamp + Int64($0) + 1 },
            firstOrdinal: 6_000,
            served: true,
            fixture: fixture
        )
        let behindLate = Set(entries.prefix(late).map(\.childCID))
        let behindWithheld = Set(entries.dropFirst(late).prefix(withheld).map(\.childCID))
        let undecidedCIDs = Set(entries.dropFirst(late + withheld).map(\.childCID))
        let admissions = NetworkEventRecorder()
        let parentFactWaits = NetworkEventRecorder()
        let childProcess = fixture.childProcess
        let handlers = stubbedChildHandlers(fixture) { cid, admission in
            if await parentFactWaits.snapshot().contains(cid) {
                return NodeImportOutcome(
                    decision: .unavailable(.parentStateContinuity(
                        parentPath: ["Nexus"],
                        fromStateCID: LatticeState.emptyHeader.rawCID,
                        toStateCID: testCID("parent-fact-wait")
                    )),
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
            if undecidedCIDs.contains(cid) {
                await admissions.append(cid)
                return NodeImportOutcome(
                    decision: .temporarilyInvalid,
                    parentCarrierLink: nil,
                    sameChainPredecessor: nil
                )
            }
            guard behindLate.contains(cid) || behindWithheld.contains(cid) else {
                return nil
            }
            await admissions.append(cid)
            if behindLate.contains(cid), await childProcess.hasAcceptedBlock(lateCID) {
                // Decided, as the real import does, it consumes its entry.
                if let rootCID = admission.authenticatedChildPackage?.package.proof.rootCID {
                    try await childProcess.store.consumeParentEvidence(
                        childCID: cid, rootCID: rootCID
                    )
                }
                return NodeImportOutcome(
                    decision: .invalid, parentCarrierLink: nil, sameChainPredecessor: nil
                )
            }
            return NodeImportOutcome(
                decision: .unavailable(nil),
                parentCarrierLink: nil,
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: cid,
                    predecessorCID: behindLate.contains(cid) ? lateCID : withheldCID
                )
            )
        }
        return OrphanScenario(
            lateBlock: lateBlock,
            lateHeader: lateHeader,
            behindLate: behindLate,
            lateOrdered: entries.prefix(late).map(\.childCID),
            behindWithheld: behindWithheld,
            undecided: undecidedCIDs,
            attachments: Dictionary(uniqueKeysWithValues: entries.map {
                ($0.childCID, $0.attachmentCID)
            }),
            admissions: admissions,
            parentFactWaits: parentFactWaits,
            handlers: handlers
        )
    }

    /// Accepts the scenario's late block outside import (no trigger).
    private func acceptLateBlock(
        _ scenario: OrphanScenario,
        fixture: ProvisionalRootFixture
    ) async throws {
        let content = CoalescingFetcher(CompositeContentSource([
            fixture.parentProcess, fixture.childProcess,
        ]))
        let lateEvidence = try await fabricatedEvidence(
            for: DirectChildCandidate(directory: "Payments", block: scenario.lateBlock),
            fixture: fixture
        )
        try await scenario.lateHeader.storeBlock(
            fetcher: content, storer: fixture.parentProcess
        )
        let late = try await fixture.childProcess.importBlock(
            scenario.lateHeader,
            authenticatedChildPackage: lateEvidence.package,
            remoteSource: fixture.parentProcess,
            mode: .header
        )
        XCTAssertTrue(late.decision.isAccepted, "\(late.decision)")
    }

    /// Orphans behind a late block and behind a withheld one. The late
    /// block is accepted and the trigger runs while the fetcher still holds
    /// its own parked attempts: those orphans stay pooled at no cost (a
    /// release would have lost them). The fetcher then drops its attempts;
    /// the next trigger fetches exactly the orphans it releases from the
    /// parent, each once — never a rescan — and the withheld block's wait. A
    /// restart empties the pool, by design.
    func testATriggerFetchesExactlyTheOrphansItReleases() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xea)
        let probe = EvidenceServeProbe()
        let scenario = try await orphanScenario(late: 3, withheld: 2, fixture: fixture)
        let lateCID = scenario.lateHeader.rawCID
        func tries(_ cid: String) async -> Int {
            await scenario.admissions.snapshot().filter { $0 == cid }.count
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            await probe.watchRoots(Set(scenario.attachments.values))
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("every entry is an orphan") {
                await self.orphaned(fixture)
                    == scenario.behindLate.union(scenario.behindWithheld)
            }
            try await acceptLateBlock(scenario, fixture: fixture)

            // The trigger while the fetcher still holds the attempts.
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            let heldPool = await orphaned(fixture)
            XCTAssertTrue(
                heldPool.isSuperset(of: scenario.behindLate),
                "an orphan the fetcher holds stays pooled"
            )
            let servedWhileHeld = await probe.rootServes
            XCTAssertEqual(servedWhileHeld, 0)

            // The fetcher drops its attempts; the next trigger fetches.
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("each released orphan is fetched and imported again") {
                for cid in scenario.behindLate where await tries(cid) < 2 { return false }
                return true
            }
            try await alwaysDuring("exactly the released orphans, each once", .seconds(1)) {
                await probe.rootServes == scenario.behindLate.count
            }
            for cid in scenario.behindWithheld {
                let count = await tries(cid)
                XCTAssertEqual(count, 1, "the withheld block's orphans wait")
            }
            let waiting = await orphaned(fixture)
            XCTAssertEqual(waiting, scenario.behindWithheld)

            // A restart empties the pool; nothing replays the orphans.
            await fixture.childRuntime.stop()
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            let afterRestart = await orphanCount(fixture)
            XCTAssertEqual(afterRestart, 0, "the pool is memory only")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent session ends while released orphans are being fetched
    /// again: they go back to the pool (a blip is no reason to lose them),
    /// and the reconnect's hello fetches them. The request the blip cuts
    /// short can report the parent unable to serve before the runtime
    /// learns the session ended; that orphan too is the hello's. Before, it
    /// waited out the request timeout for an acceptance that never came.
    func testASessionBlipDuringARefetchKeepsTheOrphans() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xee)
        let probe = EvidenceServeProbe()
        let scenario = try await orphanScenario(late: 2, withheld: 0, fixture: fixture)
        let lateCID = scenario.lateHeader.rawCID
        func tries(_ cid: String) async -> Int {
            await scenario.admissions.snapshot().filter { $0 == cid }.count
        }
        func stopAll() async {
            await probe.release.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("both entries are orphans") {
                await self.orphaned(fixture) == scenario.behindLate
            }
            try await acceptLateBlock(scenario, fixture: fixture)
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            // The first refetch stalls at the parent; the session ends.
            let first = try XCTUnwrap(scenario.lateOrdered.first)
            await probe.stall(try XCTUnwrap(scenario.attachments[first]))
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("the refetch is in flight") {
                await probe.release.isHeld
            }
            await fixture.childRuntime.recycleParentSessionForTesting()
            await probe.stall("released")
            await probe.release.open()
            try await eventually("the orphans go back to the pool or are admitted") {
                var settled = true
                for cid in scenario.behindLate {
                    let pooled = await self.orphaned(fixture).contains(cid)
                    if !pooled, await tries(cid) < 2 { settled = false }
                }
                return settled
            }
            try await eventually("the reconnect's hello fetches them") {
                for cid in scenario.behindLate where await tries(cid) < 2 { return false }
                return true
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The mirror of a blip: the refetch is held on the old session until
    /// the reconnect's hello has released the pool (which found these
    /// orphans out of it), then fails on the ended session. The orphans are
    /// fetched from the new session at once, with no further hello or
    /// acceptance. Before, they went back to the pool with their own
    /// retries (a predecessor already accepted) and waited for a hello that
    /// had already come.
    func testARefetchCutShortAfterTheReconnectsHelloFetchesFromTheNewSession() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xf4)
        let scenario = try await orphanScenario(late: 2, withheld: 0, fixture: fixture)
        let lateCID = scenario.lateHeader.rawCID
        func tries(_ cid: String) async -> Int {
            await scenario.admissions.snapshot().filter { $0 == cid }.count
        }
        func stopAll() async {
            await fixture.childRuntime.freeEvidenceLaneForTesting()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("both entries are orphans") {
                await self.orphaned(fixture) == scenario.behindLate
            }
            try await acceptLateBlock(scenario, fixture: fixture)
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            // The refetch waits for an evidence slot on the old session.
            await fixture.childRuntime.fillEvidenceLaneForTesting()
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("the refetch holds the released orphans") {
                await self.orphaned(fixture).isEmpty
            }
            let blipped = await fixture.childRuntime.parentSessionIDForTesting()
            await fixture.childRuntime.recycleParentSessionForTesting()
            try await eventually("the reconnect's hello has released the pool") {
                await fixture.childRuntime.parentHelloReleasedForTesting(after: blipped)
            }
            for cid in scenario.behindLate {
                let before = await tries(cid)
                XCTAssertEqual(before, 1, "not fetched again yet")
            }
            // The held refetch resumes on the ended session.
            await fixture.childRuntime.freeEvidenceLaneForTesting()
            try await eventually("the new session fetches them") {
                for cid in scenario.behindLate where await tries(cid) < 2 { return false }
                return true
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// More released orphans than the inbox has room for: the refetch
    /// stops at the full inbox and resumes as room frees. The room each
    /// refetched orphan's decision frees resumes exactly the orphans the
    /// full inbox put back — it is no hello: an orphan with no specific
    /// trigger stays pooled, costing the parent nothing, and the refetches
    /// end. Before, each freed slot ran the hello's release (and cleared
    /// the marks of refetches still importing, so those went back to the
    /// pool and cycled).
    func testRoomFreedByRefetchesResumesOnlyTheOrphansAFullInboxPutBack() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xf3, childInboxCapacity: 8)
        let probe = EvidenceServeProbe()
        let scenario = try await orphanScenario(
            late: 4, withheld: 0, undecided: 1, fixture: fixture
        )
        let lateCID = scenario.lateHeader.rawCID
        let bystander = try XCTUnwrap(scenario.undecided.first)
        func tries(_ cid: String) async -> Int {
            await scenario.admissions.snapshot().filter { $0 == cid }.count
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            await probe.watchRoots(Set(scenario.attachments.values))
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("every entry is an orphan") {
                await self.orphaned(fixture) == scenario.behindLate.union(scenario.undecided)
            }
            try await acceptLateBlock(scenario, fixture: fixture)
            // Entries waiting on a parent fact leave room for one.
            let childGenesis = try await fixture.childProcess.canonicalTipBlock()
            for wait in try await attackerEvidence(
                count: 7,
                on: childGenesis,
                timestamp: { childGenesis.timestamp + Int64($0) + 100 },
                firstOrdinal: 8_100,
                fixture: fixture
            ) {
                await scenario.parentFactWaits.append(wait.childCID)
            }
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("each late orphan is fetched again and decided") {
                for cid in scenario.behindLate where await tries(cid) < 2 { return false }
                return true
            }
            try await alwaysDuring("the refetches end; the bystander stays pooled", .seconds(2)) {
                let served = await probe.rootServes
                let pooled = await self.orphaned(fixture)
                return served == scenario.behindLate.count && pooled == [bystander]
            }
            let bystanderTries = await tries(bystander)
            XCTAssertEqual(bystanderTries, 1, "no hello, no refetch")
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// The parent cannot serve an orphan released behind its accepted
    /// predecessor: back in the pool, it waits out the request timeout and
    /// the next acceptance fetches it again. Before, it kept its
    /// predecessor retry, which no later acceptance meets.
    func testAnOrphanTheParentCannotServeIsRetriedAfterTheRequestTimeout() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xf4)
        let probe = EvidenceServeProbe()
        let scenario = try await orphanScenario(late: 1, withheld: 0, fixture: fixture)
        let lateCID = scenario.lateHeader.rawCID
        let orphan = try XCTUnwrap(scenario.lateOrdered.first)
        func tries() async -> Int {
            await scenario.admissions.snapshot().filter { $0 == orphan }.count
        }
        func stopAll() async {
            await probe.release.open()
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("the entry is an orphan") {
                await self.orphaned(fixture) == [orphan]
            }
            try await acceptLateBlock(scenario, fixture: fixture)
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            // The parent answers the refetch with nothing.
            await probe.release.open()
            await probe.stall(try XCTUnwrap(scenario.attachments[orphan]))
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("the unserved orphan waits out the request timeout") {
                let retry = await fixture.childRuntime.orphanedParentEvidenceForTesting()[orphan]
                guard case .unservedUntil = retry else { return false }
                return true
            }
            await probe.stall("served")
            let unrelated = testCID("unrelated-acceptance")
            try await eventually("an acceptance after the timeout fetches it", within: .seconds(60), poll: .milliseconds(250)) {
                await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: unrelated)
                return await tries() >= 2
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A released orphan whose refetch queues no import (here another
    /// fetch of its attachment holds the lease) leaves no refetch mark: a
    /// stale mark would drop the orphan's next undecided import.
    func testARefetchThatQueuesNoImportLeavesNoRefetchMark() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xf5)
        let scenario = try await orphanScenario(late: 1, withheld: 0, fixture: fixture)
        let lateCID = scenario.lateHeader.rawCID
        let orphan = try XCTUnwrap(scenario.lateOrdered.first)
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: scenario.handlers
            )
            try await eventually("the entry is an orphan") {
                await self.orphaned(fixture) == [orphan]
            }
            try await acceptLateBlock(scenario, fixture: fixture)
            await fixture.childRuntime.dropFetcherAttemptsForTesting()
            await fixture.childRuntime.holdParentEvidenceLeaseForTesting(
                attachmentCID: try XCTUnwrap(scenario.attachments[orphan])
            )
            await fixture.childRuntime.triggerParentEvidenceRetryForTesting(accepted: lateCID)
            try await eventually("the orphan is released") {
                await !self.orphaned(fixture).contains(orphan)
            }
            try await alwaysDuring("no refetch mark is left behind", .seconds(1)) {
                await fixture.childRuntime.refetchedOrphansForTesting().isEmpty
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A lone child (no overlay peer) loses the evidence of carried blocks
    /// parked behind a withheld block: restarted, its pool is empty and the
    /// scan has passed them. A later carried descendant parks and the
    /// predecessor walk reaches them without evidence; the child asks its
    /// parent for each by CID (getdata), the parent answers from its index,
    /// and once the withheld block is published every block is admitted.
    func testALoneChildRecoversLostParentEvidenceByAskingItsParent() async throws {
        try await assertLoneChildRecovers(keyByte: 0xef, loss: .restart)
    }

    /// The same, the evidence lost to the pool's eviction (a pool of 1).
    func testALoneChildRecoversEvictedParentEvidenceByAskingItsParent() async throws {
        try await assertLoneChildRecovers(keyByte: 0xf0, loss: .eviction)
    }

    private enum EvidenceLoss { case restart, eviction }

    private func assertLoneChildRecovers(keyByte: UInt8, loss: EvidenceLoss) async throws {
        let fixture = try await provisionalRootFixture(
            keyByte: keyByte, childOrphanCapacity: loss == .eviction ? 1 : 1_024
        )
        let parentService = networkService(
            process: fixture.parentProcess, runtime: fixture.parentRuntime
        )
        let withheldContent = InMemoryContentStore()
        let content = CoalescingFetcher(CompositeContentSource([
            fixture.parentProcess, fixture.childProcess, withheldContent,
        ]))
        let childHandlers = stubbedChildHandlers(fixture) { _, _ in nil }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        var step = "start the runtimes"
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            step = "await the first held candidate"
            _ = try await firstHeldCandidate(fixture)
            let childGenesis = try await fixture.childProcess.canonicalTipBlock()
            let hour: Int64 = 3_600_000
            let forkPoint = try await fixture.parentProcess.validatedTipBlock()
            step = "build the withheld B1"
            let b1 = try await carriableChildBlock(
                on: childGenesis, nonce: 501, spacing: hour,
                content: content, fixture: fixture
            )
            try await BlockHeader(node: b1).storeBlock(
                fetcher: content, storer: withheldContent
            )
            step = "advance the parent"
            try await advanceParent(
                spacing: hour, content: content, service: parentService, fixture: fixture
            )
            step = "carry B2 and B3"
            var chain = [b1]
            for nonce: UInt64 in [502, 503] {
                let tip = try await fixture.parentProcess.validatedTipBlock()
                let block = try await carriableChildBlock(
                    on: chain.last!, nonce: nonce, spacing: hour,
                    content: content, fixture: fixture
                )
                try await carryOnParentFork(
                    block, on: tip, spacing: hour, content: content,
                    service: parentService, fixture: fixture
                )
                chain.append(block)
            }
            step = "B2 and B3 park"
            let cids = try chain.map { try BlockHeader(node: $0).rawCID }
            try await eventually("B2 and B3 were imported and parked") {
                let inbox = try await fixture.childProcess.store.parentEvidenceInbox()
                let orphans = await self.orphanCount(fixture)
                return inbox.isEmpty && orphans == (loss == .eviction ? 1 : 2)
            }
            // The scan has passed them: nothing re-serves them by ordinal.
            step = "the parent issues B3"
            var b3Issued: (sourceID: String, summary: IssuedChildEvidenceSummary)?
            try await eventually("the parent issued B3's evidence") {
                b3Issued = try await fixture.parentProcess.store.issuedChildEvidenceSummary(
                    childCID: cids[2], directory: "Payments"
                )
                return b3Issued != nil
            }
            let b3Ordinal = try XCTUnwrap(b3Issued).summary.ordinal
            // The live hints got here first; a scan re-reads them once the
            // fetcher's own attempts are gone, and its cursor passes them.
            // A scan skips a block the fetcher holds on the parent's word
            // without moving its cursor, and a hint queued before a drop
            // can land after it and hold B3
            // again: each round starts with the attempts gone.
            step = "the scan cursor passes B2 and B3"
            try await eventually("the scan cursor passes B2 and B3") {
                await fixture.childRuntime.dropFetcherAttemptsForTesting()
                await fixture.childRuntime.requestEvidenceIndexForTesting()
                let cursor = try await fixture.childProcess.store.parentEvidenceScanCursor()
                return cursor.ordinal >= b3Ordinal
            }
            step = "B2 and B3 are orphans again"
            try await eventually("B2 and B3 are orphans again") {
                let inbox = try await fixture.childProcess.store.parentEvidenceInbox()
                let orphans = await self.orphanCount(fixture)
                return inbox.isEmpty && orphans == (loss == .eviction ? 1 : 2)
            }
            step = "lose the evidence"
            switch loss {
            case .restart:
                await fixture.childRuntime.stop()
                try await fixture.childRuntime.start(
                    process: fixture.childProcess, chain: childHandlers
                )
            case .eviction:
                await fixture.childRuntime.dropFetcherAttemptsForTesting()
            }
            // The withheld block is published on a parent fork; then the
            // parent carries B4 on B3.
            step = "publish B1 on a parent fork"
            try await carryOnParentFork(
                b1, on: forkPoint, spacing: hour, content: content,
                service: parentService, fixture: fixture
            )
            step = "carry B4"
            let tip = try await fixture.parentProcess.validatedTipBlock()
            let b4 = try await carriableChildBlock(
                on: chain[2], nonce: 504, spacing: hour, content: content, fixture: fixture
            )
            try await carryOnParentFork(
                b4, on: tip, spacing: hour, content: content,
                service: parentService, fixture: fixture
            )
            step = "admit B1 through B4"
            let all = cids + [try BlockHeader(node: b4).rawCID]
            // Recovery is serial: B1, then B4 parks on B3, and each evicted
            // block is asked of the parent in turn (one getdata each, each
            // answered at once). Traced, this step is ~3 s plain and ~16 s
            // under ASan + UBSan locally — work, not a timer — and a CI
            // sanitizer runner is ~2x slower again.
            try await eventually("B1 through B4 are admitted", within: .seconds(60)) {
                var admitted = true
                for cid in all where await !fixture.childProcess.hasAcceptedBlock(cid) {
                    admitted = false
                }
                return admitted
            }
            await stopAll()
        } catch {
            XCTFail("threw at step '\(step)': \(String(reflecting: error))")
            await stopAll()
            throw error
        }
    }

    /// With a pool of 2, four orphans leave the inbox and a random one gives
    /// way at each insert past the bound: the pool holds 2.
    func testAFullOrphanPoolEvictsAtRandom() async throws {
        let fixture = try await provisionalRootFixture(
            keyByte: 0xeb, childOrphanCapacity: 2
        )
        let withheld = testCID("withheld-predecessor")
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let fillers = Set(try await attackerEvidence(
            count: 4,
            on: childGenesis,
            timestamp: { childGenesis.timestamp + Int64($0) + 1 },
            firstOrdinal: 7_000,
            fixture: fixture
        ).map(\.childCID))
        let tried = NetworkEventRecorder()
        let childHandlers = stubbedChildHandlers(fixture) { cid, _ in
            guard fillers.contains(cid) else { return nil }
            await tried.append(cid)
            return NodeImportOutcome(
                decision: .unavailable(nil),
                parentCarrierLink: nil,
                sameChainPredecessor: SameChainPredecessorRequirement(
                    descendantCID: cid, predecessorCID: withheld
                )
            )
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            try await eventually("every entry was tried and left the inbox") {
                let inbox = try await fixture.childProcess.store.parentEvidenceInbox()
                return Set(await tried.snapshot()) == fillers && inbox.isEmpty
            }
            try await eventually("the pool holds its bound") {
                await self.orphanCount(fixture) == 2
            }
            let pooled = await orphaned(fixture)
            XCTAssertTrue(pooled.isSubset(of: fillers))
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A node-local resource-policy decline decides the block for this node:
    /// its parent evidence is consumed, not kept as an orphan or in the
    /// inbox, and not tried again. Before, it stayed in the inbox for good.
    func testAPolicyDeclineConsumesTheParentEvidence() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0xec)
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let declined = try await attackerEvidence(
            count: 1,
            on: childGenesis,
            timestamp: { childGenesis.timestamp + Int64($0) + 1 },
            firstOrdinal: 4_000,
            fixture: fixture
        ).map(\.childCID)
        let held = try await fixture.childProcess.store.parentEvidenceInbox()
        XCTAssertEqual(held.count, 1, "fixture guard")
        let imports = NetworkEventRecorder()
        let childHandlers = stubbedChildHandlers(fixture) { cid, _ in
            guard cid == declined[0] else { return nil }
            await imports.append(cid)
            // This node's policy declines it (as an oversized spec is).
            throw NodePolicyDecline.chainSpecTooLarge
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            try await eventually("the declined block's evidence is consumed") {
                let inbox = try await fixture.childProcess.store.parentEvidenceInbox()
                return inbox.isEmpty
            }
            let orphans = await orphaned(fixture)
            XCTAssertFalse(orphans.contains(declined[0]), "decided, not an orphan")
            try await alwaysDuring("declined once, not retried", .seconds(1)) {
                await imports.snapshot() == [declined[0]]
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A full inbox costs the parent no fetch: the scan stops before the
    /// fetch, and when room frees the capacity callback runs the same scan
    /// again from the cursor.
    func testAFullInboxCostsNoFetchesAndTheScanResumesWithRoom() async throws {
        let fixture = try await provisionalRootFixture(
            keyByte: 0xed, childInboxCapacity: 1
        )
        let parentService = networkService(
            process: fixture.parentProcess, runtime: fixture.parentRuntime
        )
        let probe = EvidenceServeProbe()
        let content = CoalescingFetcher(CompositeContentSource([
            fixture.parentProcess, fixture.childProcess,
        ]))
        // The filler holds the one slot: it waits on a parent fact.
        let filler = try await fabricatedEvidence(for: fixture.candidate, fixture: fixture)
        try await fixture.childProcess.store.storeParentEvidenceInbox(
            sourceID: testEvidenceSourceID,
            ordinal: 5_000,
            attachment: filler.attachment,
            package: filler.package,
            advanceScan: false
        )
        let childGenesis = try await fixture.childProcess.canonicalTipBlock()
        let childHandlers = stubbedChildHandlers(fixture) { cid, _ in
            guard cid == filler.childCID else { return nil }
            return NodeImportOutcome(
                decision: .unavailable(.parentStateContinuity(
                    parentPath: ["Nexus"],
                    fromStateCID: LatticeState.emptyHeader.rawCID,
                    toStateCID: testCID("filler-parent-state")
                )),
                parentCarrierLink: nil,
                sameChainPredecessor: nil
            )
        }
        func stopAll() async {
            await fixture.childRuntime.stop()
            await fixture.parentRuntime.stop()
        }
        do {
            try await fixture.parentRuntime.start(
                process: fixture.parentProcess, chain: inertNetworkHandlers()
            )
            await fixture.parentRuntime.hierarchy.setContentSource(
                ProbedContentSource(parent: fixture.parentProcess, probe: probe)
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess, chain: childHandlers
            )
            _ = try await firstHeldCandidate(fixture)
            var attachments: Set<String> = []
            var cids: [String] = []
            for index in 0..<2 {
                // Siblings, so neither waits on the other.
                let block = try await carriableChildBlock(
                    on: childGenesis, nonce: UInt64(index) + 900,
                    content: content, fixture: fixture
                )
                let cid = try await carryOnParent(
                    block, content: content, service: parentService, fixture: fixture
                )
                var issued: (sourceID: String, summary: IssuedChildEvidenceSummary)?
                try await eventually("the parent issues the evidence") {
                    issued = try await fixture.parentProcess.store.issuedChildEvidenceSummary(
                        childCID: cid, directory: "Payments"
                    )
                    return issued != nil
                }
                attachments.insert(try XCTUnwrap(issued).summary.attachmentCID)
                cids.append(cid)
            }
            await probe.watchRoots(attachments)
            try await alwaysDuring("no fetch while the inbox is full", .seconds(2)) {
                await probe.rootServes == 0
            }
            try await fixture.childProcess.store.consumeParentEvidence(
                childCID: filler.childCID,
                rootCID: filler.package.package.proof.rootCID
            )
            await fixture.childRuntime.parentEvidenceCapacityBecameAvailable()
            try await eventually("the scan resumes once the inbox has room") {
                var all = true
                for cid in cids where await !fixture.childProcess.hasAcceptedBlock(cid) {
                    all = false
                }
                return all
            }
            await stopAll()
        } catch {
            await stopAll()
            throw error
        }
    }

    /// A parent-evidence entry for `candidate` under a made-up root: a
    /// Nexus genesis that commits to it (a proof that verifies on its own
    /// terms, no parent block).
    private func fabricatedEvidence(
        for candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture
    ) async throws -> (
        childCID: String,
        attachment: ChildEvidenceVolume,
        package: AuthenticatedChildPackage
    ) {
        let content = InMemoryContentStore()
        let fetcher = CoalescingFetcher(CompositeContentSource([
            content, fixture.parentProcess, fixture.childProcess,
        ]))
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": candidate.block],
            timestamp: 5,
            target: UInt256.max,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Payments",
            fetcher: fetcher
        )
        let childCID = try BlockHeader(node: candidate.block).rawCID
        let package = ChildValidationPackage(proof: proof)
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(package).encode(),
            childCID: childCID
        )
        return (childCID, attachment, AuthenticatedChildPackage(package: package))
    }

    /// A template's request context on the parent's validated tip: its
    /// provisional carrier's parent is the tip, one height above it.
    private func contextOnValidatedTip(
        _ fixture: ProvisionalRootFixture
    ) async throws -> ChildCandidateRequestContext {
        let tip = try await fixture.parentProcess.validatedTipBlock()
        return ChildCandidateRequestContext(
            parentCarrier: try await BlockBuilder.buildBlock(
                previous: tip,
                timestamp: tip.timestamp + 1_000,
                nonce: 2,
                fetcher: fixture.parentProcess
            ),
            rewards: []
        )
    }

    /// A child block on `candidate`'s parent for the same parent state:
    /// its sibling.
    private func siblingOf(
        _ candidate: DirectChildCandidate,
        fixture: ProvisionalRootFixture
    ) async throws -> Block {
        let childGenesis = try await fixture.childProcess.validatedTipBlock()
        XCTAssertEqual(candidate.block.parent?.rawCID, try BlockHeader(node: childGenesis).rawCID)
        let sibling = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            parentChainBlock: fixture.context.parentCarrier,
            timestamp: candidate.block.timestamp + 1,
            target: .max,
            fetcher: CoalescingFetcher(CompositeContentSource([
                fixture.childProcess, fixture.parentProcess,
            ]))
        )
        XCTAssertEqual(sibling.parentState.rawCID, candidate.block.parentState.rawCID)
        XCTAssertNotEqual(
            try BlockHeader(node: sibling).rawCID,
            try BlockHeader(node: candidate.block).rawCID
        )
        return sibling
    }

    private func carriedAnnouncer(keyByte: UInt8) -> Ivy {
        Ivy(config: IvyConfig(
            signingKey: signingKey(keyByte &+ 0x40),
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
    }

    private func firstHeldCandidate(
        _ fixture: ProvisionalRootFixture
    ) async throws -> DirectChildCandidate {
        var held: [DirectChildCandidate] = []
        try await eventually("the child's first candidate is held") {
            held = await fixture.parentRuntime.directChildCandidates(fixture.context)
            return !held.isEmpty
        }
        return try XCTUnwrap(held.first)
    }

    /// Connects `attacker` to the child's overlay and announces `cid` every
    /// 100 ms: a no-op while the attempt exists, a re-creation once it is
    /// ever reclaimed.
    private func announceRepeatedly(
        _ cid: String,
        from attacker: Ivy,
        to fixture: ProvisionalRootFixture
    ) async throws -> Task<Void, Never> {
        let childPeer = PeerID(publicKey: fixture.childConfiguration.processPublicKey)
        try await connectAndHello(
            attacker,
            peerID: childPeer,
            endpoint: PeerEndpoint(
                publicKey: fixture.childConfiguration.processPublicKey,
                host: "127.0.0.1",
                port: fixture.childConfiguration.listenPort
            ),
            hello: try ChainHello(
                nexusGenesisCID: fixture.childConfiguration.nexusGenesisCID,
                chainPath: fixture.childConfiguration.chainPath
            ).encode()
        )
        let payload = try BlockAnnouncementMessage(blockCID: cid).encoded()
        return Task {
            while !Task.isCancelled {
                _ = await attacker.sendMessage(
                    to: childPeer,
                    topic: NodeNetworkTopic.blockAnnouncement,
                    payload: payload
                )
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Builds and stores the parent block that carries `candidate`, with
    /// its child proof prepared, as the mined-block path does, so its
    /// admission issues (and pushes) the child's evidence.
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
        _ = try await fixture.parentProcess.prepareChildProofs(
            for: carrier,
            children: [candidate],
            capacity: 16
        )
        return carrierHeader
    }

    /// Admits the carrier on the parent through the service, which
    /// publishes the prepared child proof.
    private func admitCarrier(
        _ carrierHeader: BlockHeader,
        service: ChainService,
        fixture: ProvisionalRootFixture
    ) async throws {
        let carried = try await service.importNetworkCandidate(
            carrierHeader,
            authenticatedChildPackage: nil,
            preparingChildDirectories: ["Payments"],
            contentSource: fixture.parentProcess
        )
        XCTAssertTrue(carried.decision.isAccepted, "\(carried.decision)")
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
                childCandidateBuilder: { context, parentSource in
                    try await childService.miningCandidate(
                        for: context, parentContentSource: parentSource
                    )
                },
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
                            parentCarrierLink: nil,
                            sameChainPredecessor: nil
                        )
                    }
                    return try await childService.importNetworkCandidate(
                        admission.header,
                        authenticatedChildPackage: admission.authenticatedChildPackage,
                        preparingChildDirectories: admission.preparingChildDirectories,
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
                childCandidateProvider: { _ in [] },
                chainStateChangePublisher: {},
                childProofPublisher: { _ in },
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
        let childRuntime = fixture.childRuntime
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                childCandidateProvider: { _ in [] },
                chainStateChangePublisher: { [weak childRuntime] in
                    await childRuntime?.chainStateChanged()
                },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in }
            ),
            executionWalkRetryInterval: .seconds(60)
        )
        let childHandlers = ClosureChainInterface(
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
                chain: inertNetworkHandlers()
            )
            try await fixture.childRuntime.start(
                process: fixture.childProcess,
                chain: childHandlers
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
    func testChildCandidateWaitsWhileTheExecutionWalkSteps() async throws {
        let fixture = try await provisionalRootFixture(keyByte: 0x9d)
        _ = try await weighedOnlyChildBlock(fixture)
        let gate = Latch()
        let changes = NetworkEventRecorder()
        let parentProcess = fixture.parentProcess
        let childService = ChainService(
            process: fixture.childProcess,
            network: ClosureNetworkInterface(
                childCandidateProvider: { _ in [] },
                chainStateChangePublisher: { await changes.append("change") },
                childProofPublisher: { _ in },
                acceptedBlockPublisher: { _ in },
                executionBodySource: { _, admit in
                    await gate.wait()
                    return try await admit(parentProcess)
                }
            ),
            parentLevel: fixture.childRuntime.parentLevel
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
        childInboxCapacity: Int = 64,
        childOrphanCapacity: Int = 1_024,
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
            resourcePolicy: NodeResourcePolicy(
                maximumPendingParentEvidence: childInboxCapacity,
                maximumOrphanedParentEvidence: childOrphanCapacity
            )
        
    ).withParentEndpoint(ParentEndpoint(
            publicKey: parentConfiguration.processPublicKey,
            host: "127.0.0.1",
            port: parentConfiguration.factListenPort
        ))
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

extension NodeNetworkRuntime {
    /// The child block of every offer the child peers pushed and this
    /// chain holds.
    fileprivate func heldOfferCIDsForTesting() -> [String] {
        hierarchyState.hierarchyRecords.records.values.compactMap(\.offer?.childCID)
    }

    /// Holds every evidence Volume slot with overlay work, as a burst of
    /// portable attachments would.
    fileprivate func fillEvidenceLaneForTesting() {
        for index in 0..<Self.maximumEvidenceCandidates {
            sessionLeases.activeEvidenceVolumes.insert(EvidenceVolumeLease(
                plane: .overlay,
                sessionID: Data([0xee]),
                attachmentCID: "lane-filler-\(index)"
            ))
        }
    }

    fileprivate func orphanedParentEvidenceForTesting()
        -> [String: ParentEvidenceOrphans.Retry]
    {
        Dictionary(
            hierarchyState.parentEvidenceOrphans.entries.map {
                ($0.key.childCID, $0.value.retry)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Every fetcher attempt reclaimed, as its budget reclaims parks.
    fileprivate func dropFetcherAttemptsForTesting() {
        blockFetcher.reset(retryWindow: planeConfigurations.overlay.requestTimeout)
    }

    /// `accepted` nil: the parent's hello.
    fileprivate func triggerParentEvidenceRetryForTesting(accepted: String?) async {
        guard let process else { return }
        await parentEvidenceRetryTrigger(
            accepted: accepted, generation: runtimeGeneration, process: process
        )
    }

    fileprivate func refetchedOrphansForTesting() -> Set<String> {
        Set(hierarchyState.refetchedOrphans.map(\.childCID))
    }

    /// Holds the configured parent's evidence lease on `attachmentCID`, as
    /// another fetch of that attachment does.
    fileprivate func holdParentEvidenceLeaseForTesting(attachmentCID: String) {
        guard let parent = configuredParentPeer() else { return }
        sessionLeases.activeEvidenceVolumes.insert(EvidenceVolumeLease(
            plane: .hierarchy,
            sessionID: parent.sessionID,
            attachmentCID: attachmentCID
        ))
    }

    fileprivate func requestEvidenceIndexForTesting() async {
        guard let process else { return }
        await requestEvidenceIndex(generation: runtimeGeneration, process: process)
    }

    fileprivate func parentSessionIDForTesting() -> Data? {
        configuredParentPeer()?.sessionID
    }

    /// A parent session other than `blipped` said hello and released the
    /// orphan pool.
    fileprivate func parentHelloReleasedForTesting(after blipped: Data?) -> Bool {
        guard let current = configuredParentPeer()?.sessionID else { return false }
        return current != blipped && hierarchyState.parentHelloReleaseSession == current
    }

    fileprivate func recycleParentSessionForTesting() async {
        guard let parent = configuredParentPeer() else { return }
        _ = await hierarchy.recycleSession(ifCurrent: parent)
    }

    fileprivate func freeEvidenceLaneForTesting() {
        for lease in sessionLeases.activeEvidenceVolumes
        where lease.attachmentCID.hasPrefix("lane-filler-") {
            releaseEvidenceVolume(lease)
        }
    }

    /// The tip the context pushed to children was minted on.
    fileprivate func parentTipContextCIDForTesting() -> String? {
        hierarchyState.parentTipContext?.tipCID
    }
}
