import Ivy
import Lattice
import UInt256
import VolumeBroker
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNode

private func awaitedUnwrap<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private func protocolCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

final class ChildEvidenceIndexTests: XCTestCase {
    func testChildEvidenceIsOneCompleteContentAddressedVolume() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let broker = MemoryBroker()
        try await attachment.store(storer: broker)
        let fetched = await broker.fetchVolumeLocal(root: attachment.rawCID)
        let volume = try XCTUnwrap(fetched)
        try volume.validate()
        XCTAssertEqual(volume.root, attachment.rawCID)
        XCTAssertEqual(volume.entries.count, 1)
        XCTAssertNotNil(volume.entries[attachment.rawCID])
        let rootData = try XCTUnwrap(volume.entries[attachment.rawCID])
        let framedBytes = 6 + attachment.rawCID.utf8.count + rootData.count
        XCTAssertLessThanOrEqual(
            framedBytes,
            ChildEvidenceVolume.maximumFramedBytes
        )
        XCTAssertEqual(
            ChildEvidenceVolume.maximumArchiveBytes,
            ChildEvidenceVolume.maximumFramedBytes + 2
        )

        let resolved = try ChildEvidenceVolume(
            serialized: volume,
            childCID: childCID
        )
        XCTAssertEqual(resolved.envelopeBytes, envelope)

        let resolvedWithoutExternalHint = try ChildEvidenceVolume(
            serialized: volume
        )
        XCTAssertEqual(resolvedWithoutExternalHint.envelopeBytes, envelope)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: volume,
            childCID: protocolCID("wrong-child")
        ))
    }

    func testChildEvidenceRootCommitsItsExactProofAndChild() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let left = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let right = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        XCTAssertEqual(left.rawCID, right.rawCID)
        XCTAssertEqual(left.serialized.entries, right.serialized.entries)
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: envelope + Data([0]),
                childCID: childCID
            ).rawCID
        )
        XCTAssertNotEqual(
            left.rawCID,
            try ChildEvidenceVolume(
                envelopeBytes: envelope,
                childCID: protocolCID("another-child")
            ).rawCID
        )
    }

    func testChildEvidenceRejectsMembershipDrift() async throws {
        let (envelope, childCID) = try await evidenceFixture()
        let attachment = try ChildEvidenceVolume(
            envelopeBytes: envelope,
            childCID: childCID
        )
        let extra = PublicKey(key: "uncommitted-evidence-member")
        let extraHeader = try HeaderImpl<PublicKey>(node: extra)
        var withExtra = attachment.serialized.entries
        withExtra[extraHeader.rawCID] = try extraHeader.mapToData()
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: withExtra
            ),
            childCID: childCID
        ))

        var missing = attachment.serialized.entries
        missing.removeValue(forKey: attachment.rawCID)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: missing
            ),
            childCID: childCID
        ))

        var corrupt = attachment.serialized.entries
        corrupt[attachment.rawCID]?.append(0)
        XCTAssertThrowsError(try ChildEvidenceVolume(
            serialized: SerializedVolume(
                root: attachment.rawCID,
                entries: corrupt
            ),
            childCID: childCID
        ))
    }

    func testChildEvidenceRootTopicIsOnOverlay() {
        XCTAssertEqual(
            NodeNetworkTopic.plane(for: NodeNetworkTopic.childEvidenceRoot),
            .overlay
        )
    }

    /// The portable-attachment protocol is replaced by the child-evidence
    /// index: its topics belong to no plane, so a peer that still sends one
    /// is dropped unread.
    func testPortableAttachmentTopicsAreRetired() {
        for topic in [
            "lattice.overlay.portable-attachment.available.v1",
            "lattice.overlay.portable-attachment.index.request.v1",
            "lattice.overlay.portable-attachment.index.response.v1",
            "lattice.overlay.portable-attachment.locate.request.v1",
        ] {
            XCTAssertNil(NodeNetworkTopic.plane(for: topic), topic)
        }
    }

    func testChildEvidenceRootMessageIsCanonicalAndCIDBound() throws {
        let root = protocolCID("index-root")
        let message = ChildEvidenceRootMessage(rootCID: root)
        let encoded = try message.encoded()
        XCTAssertEqual(try ChildEvidenceRootMessage.decoded(encoded), message)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"rootCID":"\#(root)"}"#
        )
        XCTAssertThrowsError(try ChildEvidenceRootMessage(rootCID: "not-a-cid").encoded())
        XCTAssertThrowsError(try ChildEvidenceRootMessage(rootCID: "").encoded())
        XCTAssertThrowsError(try ChildEvidenceRootMessage.decoded(
            Data(#"{"rootCID":"\#(root)","extra":1}"#.utf8)
        ))
        XCTAssertThrowsError(try ChildEvidenceRootMessage.decoded(
            Data(#"{ "rootCID":"\#(root)"}"#.utf8)
        ))
    }

    /// Parent facts are read from the co-hosted parent level, never asked
    /// on the wire: the retired topics belong to no plane, so a peer that
    /// still sends one is dropped unread.
    func testParentChainFactTopicsAreRetired() {
        XCTAssertNil(NodeNetworkTopic.plane(
            for: "lattice.hierarchy.parent-chain-fact.request.v2"
        ))
        XCTAssertNil(NodeNetworkTopic.plane(
            for: "lattice.hierarchy.parent-chain-fact.response.v2"
        ))
    }

    /// Run reports are read from the co-hosted parent level and pushed
    /// through the child's mailbox, never sent on the wire: the retired
    /// topics belong to no plane.
    func testParentRunReportTopicsAreRetired() {
        XCTAssertNil(NodeNetworkTopic.plane(
            for: "lattice.hierarchy.parent-run-report.v1"
        ))
        XCTAssertNil(NodeNetworkTopic.plane(
            for: "lattice.hierarchy.parent-run-report.request.v1"
        ))
    }

    func testEvidenceProofCapMatchesTransportCapacityNotOneFrame() {
        let frame = Int(IvyConfig.defaultProtocolMaxFrameSize)
        // The old cap was a single frame — the original wedge. A legitimate
        // deep multi-hop proof exceeds one frame; the volume-archive transport
        // chunks the evidence across frames, so the hard proof cap must exceed
        // one frame...
        XCTAssertGreaterThan(
            ChildValidationPackageEnvelope.maximumEncodedSize, frame
        )
        // The wrapped evidence Volume must stay under the transport's archive
        // ceiling (16 frames) so the archive never rejects it.
        XCTAssertLessThanOrEqual(
            ChildEvidenceVolume.maximumArchiveBytes, frame * 16
        )
    }

    private func evidenceFixture() async throws
        -> (envelope: Data, childCID: String) {
        let source = MemoryBroker()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: source
        )
        let block = try await NexusGenesis.create(
            fetcher: source
        ).block
        let childCID = try BlockHeader(node: block).rawCID
        return (
            Data("envelope".utf8),
            childCID
        )
    }
}

// MARK: - The index and its walk

/// Records every Volume the index stores, and serves them back as content.
private actor VolumeRecorder: VolumeStorer {
    private var volumes: [String: SerializedVolume] = [:]
    private(set) var storedRoots: [String] = []

    func store(volume: SerializedVolume) async throws {
        volumes[volume.root] = volume
        storedRoots.append(volume.root)
    }

    func resetStoredRoots() { storedRoots = [] }

    func volume(_ root: String) -> SerializedVolume? { volumes[root] }

    func source() -> InMemoryContentSource {
        InMemoryContentSource(volumes.values.reduce(into: [:]) {
            $0.merge($1.entries) { first, _ in first }
        })
    }
}

private actor FetchLog {
    private(set) var cids: [String] = []
    func record(_ requested: Set<String>) { cids.append(contentsOf: requested.sorted()) }
}

private struct CountingSource: ContentSource {
    let base: InMemoryContentSource
    let log: FetchLog

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        await log.record(cids)
        return await base.fetch(cids)
    }
}

final class ChildEvidenceIndexWalkTests: XCTestCase {
    private typealias Index = ChildEvidenceIndex
    private typealias Entry = ChildEvidenceIndex.Entry

    private func entry(_ child: String, _ root: String) -> Entry {
        Entry(
            childCID: protocolCID("child-\(child)"),
            rootCID: protocolCID("root-\(child)-\(root)"),
            attachmentCID: protocolCID("attachment-\(child)-\(root)")
        )
    }

    /// Inserts `batches` in order into the index at `root`.
    private func build(
        _ batches: [[Entry]],
        into recorder: VolumeRecorder,
        root: String? = nil
    ) async throws -> String? {
        var root = root
        for batch in batches {
            if let update = try await Index.inserting(
                batch,
                into: root,
                fetcher: await recorder.source(),
                storer: recorder
            ) {
                XCTAssertEqual(update.baseRoot, root)
                root = update.root
            }
        }
        return root
    }

    private var sample: [Entry] {
        (0..<6).flatMap { child in
            (0...(child % 3)).map { entry("\(child)", "\($0)") }
        }
    }

    func testRootIsIndependentOfInsertionOrder() async throws {
        let batch = try await build([sample], into: VolumeRecorder())
        let reversed = try await build(
            sample.reversed().map { [$0] },
            into: VolumeRecorder()
        )
        var generator = SplitMix64(state: 0x41)
        let shuffled = sample.shuffled(using: &generator)
        let split = try await build(
            [Array(shuffled.prefix(4)), Array(shuffled.dropFirst(4))],
            into: VolumeRecorder()
        )
        XCTAssertNotNil(batch)
        XCTAssertEqual(batch, reversed)
        XCTAssertEqual(batch, split)
    }

    func testInsertingIsIdempotent() async throws {
        let recorder = VolumeRecorder()
        let root = try await build([sample], into: recorder)
        let again = try await Index.inserting(
            sample, into: root, fetcher: await recorder.source(), storer: recorder
        )
        XCTAssertNil(again)
        let subset = try await Index.inserting(
            [sample[2]], into: root, fetcher: await recorder.source(), storer: recorder
        )
        XCTAssertNil(subset)
        let entries = try await Index.entries(
            for: [entry("3", "0").childCID],
            root: try XCTUnwrap(root),
            fetcher: await recorder.source()
        )
        XCTAssertEqual(entries, [
            entry("3", "0").childCID: [
                entry("3", "0").rootCID: entry("3", "0").attachmentCID,
            ],
        ])
    }

    func testOnlyTheChangedPathVolumesAreStored() async throws {
        let recorder = VolumeRecorder()
        let base = (0..<32).map { entry("\($0)", "0") }
        let root = try await build([base], into: recorder)
        await recorder.resetStoredRoots()
        let update = try await Index.inserting(
            [entry("7", "1")],
            into: root,
            fetcher: await recorder.source(),
            storer: recorder
        )
        let stored = await recorder.storedRoots
        let changed = try XCTUnwrap(update)
        XCTAssertEqual(Set(stored), Set(changed.added))
        XCTAssertTrue(changed.added.contains(changed.root))
        // The root, the outer nodes on one key's path, and its ProofSet:
        // a handful, not the 32-key index.
        XCTAssertLessThan(changed.added.count, 12)
        XCTAssertEqual(changed.added.count, changed.released.count)
        // A key that splits a compressed radix node re-prefixes a sibling:
        // that sibling is new too, and is stored with the path.
        await recorder.resetStoredRoots()
        let split = try await Index.inserting(
            [Entry(
                childCID: String(entry("9", "0").childCID.dropLast()) + "-",
                rootCID: entry("9", "1").rootCID,
                attachmentCID: entry("9", "1").attachmentCID
            )],
            into: changed.root,
            fetcher: await recorder.source(),
            storer: recorder
        )
        let splitStored = await recorder.storedRoots
        XCTAssertEqual(Set(splitStored), Set(try XCTUnwrap(split).added))
    }

    /// Pinning what each update adds and unpinning what it releases keeps
    /// exactly the current root's Volumes pinned.
    func testReplacedVolumesAreUnpinnedExactly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-evidence-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // The broker the node's store uses.
        let broker = try DiskBroker(
            path: directory.appendingPathComponent("volumes.db").path
        )
        let owner = "scope:child-evidence"
        var root: String?
        for (index, next) in (sample + (0..<8).map { entry("x\($0)", "0") })
            .enumerated() {
            guard let update = try await Index.inserting(
                [next], into: root, fetcher: broker, storer: broker
            ) else { continue }
            try await broker.pinBatch(roots: update.added, owner: owner)
            if !update.released.isEmpty {
                try await broker.unpinBatch(items: update.released.map {
                    (root: $0, owner: owner, count: 1)
                })
            }
            root = update.root
            let pinned = Set(await broker.pinnedRoots(owners: [owner]))
            let reachable = Set(await Index.volumes(
                root: try XCTUnwrap(root), fetcher: broker
            ).reachable)
            XCTAssertEqual(pinned, reachable, "after insert \(index)")
        }
    }

    func testEqualRootsFetchNothing() async throws {
        let recorder = VolumeRecorder()
        let root = try awaitedUnwrap(try await build([sample], into: recorder))
        let log = FetchLog()
        let peer = CoalescingFetcher(CountingSource(
            base: await recorder.source(), log: log
        ))
        let missing = try await Index.missingEntries(
            peerRoot: root, localRoot: root, wanted: [],
            peer: peer, local: await recorder.source()
        )
        XCTAssertTrue(missing.isEmpty)
        let fetched = await log.cids
        XCTAssertTrue(fetched.isEmpty, "\(fetched)")
    }

    func testSupersetYieldsExactlyTheMissingEntries() async throws {
        let held = (0..<6).map { entry("\($0)", "0") }
        let extra = [entry("1", "1"), entry("3", "1"), entry("3", "2")]
        let unheld = (6..<10).map { entry("\($0)", "0") }
        let local = VolumeRecorder()
        let localRoot = try await build([held], into: local)
        let peer = VolumeRecorder()
        let peerRoot = try awaitedUnwrap(
            try await build([held + extra + unheld], into: peer) as String?
        )
        let missing = try await Index.missingEntries(
            peerRoot: peerRoot, localRoot: localRoot, wanted: [],
            peer: await peer.source(), local: await local.source()
        )
        XCTAssertEqual(Set(missing), Set(extra))
        // A wanted block the local index does not hold is looked up.
        let wanted = try await Index.missingEntries(
            peerRoot: peerRoot, localRoot: localRoot,
            wanted: [entry("8", "0").childCID],
            peer: await peer.source(), local: await local.source()
        )
        XCTAssertEqual(Set(wanted), Set(extra + [entry("8", "0")]))
    }

    func testJunkKeysForUnheldBlocksCauseNoValueFetches() async throws {
        let held = (0..<3).map { entry("\($0)", "0") }
        let junk = (0..<64).map { entry("junk\($0)", "0") }
        let local = VolumeRecorder()
        let localRoot = try await build([held], into: local)
        let peer = VolumeRecorder()
        let peerRoot = try awaitedUnwrap(
            try await build([held + [entry("0", "1")] + junk], into: peer)
        )
        var junkSets = Set<String>()
        for item in junk {
            junkSets.insert(try await proofSetCID(
                item.childCID, root: peerRoot, fetcher: await peer.source()
            ))
        }
        let log = FetchLog()
        let missing = try await Index.missingEntries(
            peerRoot: peerRoot, localRoot: localRoot, wanted: [],
            peer: CoalescingFetcher(CountingSource(
                base: await peer.source(), log: log
            )),
            local: await local.source()
        )
        XCTAssertEqual(missing, [entry("0", "1")])
        let fetched = Set(await log.cids)
        XCTAssertTrue(fetched.isDisjoint(with: junkSets))
        XCTAssertTrue(fetched.isDisjoint(with: Set(junk.map(\.attachmentCID))))
    }

    func testTheSessionBudgetBoundsAWalk() async throws {
        let held = (0..<16).map { entry("\($0)", "0") }
        let local = VolumeRecorder()
        let localRoot = try await build([held], into: local)
        let peer = VolumeRecorder()
        let peerRoot = try awaitedUnwrap(try await build(
            [held + (0..<16).map { entry("\($0)", "1") }],
            into: peer
        ))
        let served = FetchLog()
        let source = IvyRootContentSource(
            maximumVolumes: 4,
            maximumMembers: 64,
            maximumStorageBytes: 1 << 20
        ) { requested in
            await served.record([requested])
            let volume = await peer.volume(requested)
            return AttributedVolumeResponse(
                rootCID: requested,
                entries: volume?.entries ?? [:],
                servedBy: nil
            )
        }
        let localSource = await local.source()
        let result = await source.withRootTracing(peerRoot) { session in
            await Index.collect(
                peerRoot: peerRoot,
                localRoot: localRoot,
                wanted: [],
                peer: CoalescingFetcher(session),
                local: localSource,
                weighs: { _, _ in nil }
            )
        }
        XCTAssertTrue(result.value.failed)
        XCTAssertTrue(result.value.verified.isEmpty)
        XCTAssertFalse(result.attribution.allResponsesComplete)
        let requests = await served.cids
        XCTAssertLessThanOrEqual(requests.count, 4)
        XCTAssertNil(NodeNetworkRuntime.childEvidenceBlame(
            failed: result.value.failed,
            complete: result.attribution.allResponsesComplete,
            soleSupplier: "peer"
        ))
    }

    /// Where the two radix shapes compress differently, the walk aligns
    /// their labels and still finds the differing key.
    func testRadixPrefixMismatchIsAligned() async throws {
        func raw(_ key: String, _ root: String) -> Entry {
            Entry(
                childCID: key,
                rootCID: protocolCID("root-\(key)-\(root)"),
                attachmentCID: protocolCID("attachment-\(key)-\(root)")
            )
        }
        let local = VolumeRecorder()
        let localRoot = try await build(
            [[raw("k-aa", "0"), raw("k-ab", "0")]], into: local
        )
        let peer = VolumeRecorder()
        let peerRoot = try awaitedUnwrap(try await build(
            [[raw("k-aa", "0"), raw("k-aa", "1")]], into: peer
        ))
        let missing = try await Index.missingEntries(
            peerRoot: peerRoot, localRoot: localRoot, wanted: [],
            peer: await peer.source(), local: await local.source()
        )
        XCTAssertEqual(missing, [raw("k-aa", "1")])
    }

    /// A sparse peer against a dense local index: the peer's one compressed
    /// label spans the whole local subtree, and aligning labels reads only
    /// the local nodes on the differing key's path.
    func testASparsePeerReadsOnlyTheDifferingLocalPath() async throws {
        let local = VolumeRecorder()
        let localRoot = try await build(
            [(0..<256).map { entry("\($0)", "0") }], into: local
        )
        let localVolumes = await Index.volumes(
            root: try XCTUnwrap(localRoot), fetcher: await local.source()
        ).reachable
        let peer = VolumeRecorder()
        let peerRoot = try awaitedUnwrap(try await build(
            [[entry("7", "0"), entry("7", "1")]], into: peer
        ))
        let log = FetchLog()
        let missing = try await Index.missingEntries(
            peerRoot: peerRoot, localRoot: localRoot, wanted: [],
            peer: await peer.source(),
            local: CoalescingFetcher(CountingSource(
                base: await local.source(), log: log
            ))
        )
        XCTAssertEqual(missing, [entry("7", "1")])
        let reads = Set(await log.cids)
        XCTAssertGreaterThan(localVolumes.count, 300)
        // The root, the outer nodes on one key's path, and its ProofSet.
        XCTAssertLessThanOrEqual(reads.count, 12, "\(reads.count) local reads")
    }

    /// Nodes that pull each other's missing entries reach one root: a node
    /// that learned nothing while others did (offline), and nodes holding
    /// disjoint proofs for the same blocks, end with the union.
    func testPullingMissingEntriesConvergesToOneRoot() async throws {
        let blocks = (0..<5).map { "\($0)" }
        let splits: [[Entry]] = [
            blocks.map { entry($0, "a") },
            blocks.map { entry($0, "a") } + [entry("1", "b"), entry("4", "c")],
            blocks.map { entry($0, "a") } + [entry("2", "d"), entry("1", "e")],
        ]
        var nodes: [(recorder: VolumeRecorder, root: String?)] = []
        for split in splits {
            let recorder = VolumeRecorder()
            nodes.append((recorder, try await build([split], into: recorder)))
        }
        for _ in 0..<2 {
            for local in nodes.indices {
                for peer in nodes.indices where peer != local {
                    let missing = try await Index.missingEntries(
                        peerRoot: try XCTUnwrap(nodes[peer].root),
                        localRoot: nodes[local].root,
                        wanted: [],
                        peer: await nodes[peer].recorder.source(),
                        local: await nodes[local].recorder.source()
                    )
                    nodes[local].root = try await build(
                        [missing],
                        into: nodes[local].recorder,
                        root: nodes[local].root
                    )
                }
            }
        }
        let union = try await build([splits.flatMap { $0 }], into: VolumeRecorder())
        XCTAssertEqual(Set(nodes.map(\.root)), [union])
    }

    private func proofSetCID(
        _ key: String,
        root: String,
        fetcher: any Fetcher
    ) async throws -> String {
        let trie = try await Index.Root(
            rawCID: root, node: nil, encryptionInfo: nil
        ).resolve(paths: [[key]: .targeted], fetcher: fetcher).node
        return try XCTUnwrap(try trie?.get(key: key)).rawCID
    }
}

/// Which peer root and which parked blocks the one serial worker serves.
final class ChildEvidenceSyncSchedulingTests: XCTestCase {
    private func key(_ byte: Int) throws -> PeerKey {
        try PeerKey(String(repeating: String(format: "%02x", byte), count: 32))
    }

    /// A low-key peer that is dirty again after every pass (a partial pass,
    /// a stream of new roots) cannot starve the other dirty peers.
    func testARedirtyingLowKeyPeerCannotStarveTheOthers() throws {
        let low = try key(0x01)
        let others = try (2...5).map { try key($0) }
        var dirty = Set([low] + others)
        var last: PeerKey?
        var served: [PeerKey] = []
        for _ in 0..<(2 * (others.count + 1)) {
            guard let next = NodeNetworkRuntime.nextChildEvidencePeer(
                dirty: dirty, after: last
            ) else { break }
            served.append(next)
            last = next
            if next != low { dirty.remove(next) }
        }
        XCTAssertTrue(Set(others).isSubset(of: Set(served.prefix(others.count + 1))))
        XCTAssertLessThanOrEqual(served.prefix(others.count + 1).filter { $0 == low }.count, 1)
    }

    /// Parked blocks are looked up in rotation, not as a sorted prefix: a
    /// pass starts past the last block the previous pass searched.
    func testParkedBlocksAreLookedUpInRotation() {
        let keys = ["a", "b", "c", "d", "e"]
        func pass(_ cursor: String?) -> [String] {
            NodeNetworkRuntime.rotatedChildProofWaits(keys, after: cursor, limit: 2)
        }
        XCTAssertEqual(pass(nil), ["a", "b"])
        XCTAssertEqual(pass("b"), ["c", "d"])
        XCTAssertEqual(pass("d"), ["e", "a"])
        // The cursor block was decided meanwhile: start past where it was.
        XCTAssertEqual(pass("bb"), ["c", "d"])
        XCTAssertEqual(pass("z"), ["a", "b"])
    }
}
