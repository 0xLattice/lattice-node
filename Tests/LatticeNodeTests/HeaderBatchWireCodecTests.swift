import XCTest
@testable import Lattice
@testable import LatticeNode
import Ivy
import Tally
import VolumeBroker
import LatticeNodeWire

/// Single fail-closed header-batch wire codec (deep review).
///
/// The getHeaders/headerBatch(2) wire format was implemented four times
/// (ChainNetwork+SyncRequests request builders + response parsers, and the
/// ParentChainBlockExtractor re-implementations). The extractor twin parsed
/// truncated responses into a silently-truncated PREFIX of a proof-carrying
/// header set (fail open on untrusted peer bytes) and skipped the tally
/// penalty for unsolicited/wrong-peer responses. These tests pin the unified
/// fail-closed behavior on both consumers and the canonical codec itself.
final class HeaderBatchWireCodecTests: XCTestCase {

    // MARK: - Extractor: fail-closed response handling

    func testExtractorRejectsTruncatedProofBatchEntirely() async throws {
        let (extractor, node, ivy) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let requestID = Data(repeating: 0xA1, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderProofResultBox()

        await extractor.registerPendingHeaderProofRequestForTesting(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }

        var payload = headerBatchWithProofsPayload(
            requestID: requestID,
            entries: [
                ("cid-a", Data("block-a".utf8), Data("proof-a".utf8)),
                ("cid-b", Data("block-b".utf8), Data("proof-b".utf8)),
            ]
        )
        payload = payload.dropLast(3) // truncate inside the second entry's proof

        await extractor.handleHeaderBatchWithProofsResponseForTesting(payload: payload, ivy: ivy, from: target)

        XCTAssertEqual(
            box.value?.count, 0,
            "a truncated proof-carrying header batch must be rejected WHOLE, never a prefix; got \(box.value?.map(\.cid) ?? [])"
        )
    }

    func testExtractorRejectsOversizedNumHeadersEntirely() async throws {
        let (extractor, node, ivy) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let requestID = Data(repeating: 0xA2, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderProofResultBox()

        await extractor.registerPendingHeaderProofRequestForTesting(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }

        let bound = extractor.maxAnnounceBackfillBlocks
        let payload = headerBatchWithProofsPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8), Data("proof-a".utf8))],
            declaredCountOverride: UInt32(bound + 1)
        )

        await extractor.handleHeaderBatchWithProofsResponseForTesting(payload: payload, ivy: ivy, from: target)

        XCTAssertEqual(
            box.value?.count, 0,
            "numHeaders above the bound (\(bound)) must reject the whole response"
        )
    }

    func testExtractorPenalizesUnsolicitedHeaderBatchResponse() async throws {
        let (extractor, node, ivy) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let unsolicited = PeerID(publicKey: "unsolicited-peer")
        let tally = await ivy.tally
        for _ in 0..<10 { tally.recordSuccess(peer: unsolicited) }
        let reputationBefore = tally.reputation(for: unsolicited)

        let payload = headerBatchWithProofsPayload(
            requestID: Data(repeating: 0xA3, count: 16),
            entries: [("cid-a", Data("block-a".utf8), Data("proof-a".utf8))]
        )
        await extractor.handleHeaderBatchWithProofsResponseForTesting(payload: payload, ivy: ivy, from: unsolicited)

        XCTAssertLessThan(
            tally.reputation(for: unsolicited), reputationBefore,
            "an unsolicited headerBatch2 response must cost the sender reputation"
        )
    }

    func testExtractorPenalizesWrongPeerAndKeepsRequestForTarget() async throws {
        let (extractor, node, ivy) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let requestID = Data(repeating: 0xA4, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let attacker = PeerID(publicKey: "attacker-peer")
        let box = HeaderProofResultBox()

        await extractor.registerPendingHeaderProofRequestForTesting(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }

        let tally = await ivy.tally
        for _ in 0..<10 { tally.recordSuccess(peer: attacker) }
        let reputationBefore = tally.reputation(for: attacker)

        await extractor.handleHeaderBatchWithProofsResponseForTesting(
            payload: headerBatchWithProofsPayload(
                requestID: requestID,
                entries: [("poison", Data("bad".utf8), Data("bad-proof".utf8))]
            ),
            ivy: ivy,
            from: attacker
        )

        XCTAssertNil(box.value, "wrong-peer response must not resume the pending request")
        XCTAssertLessThan(
            tally.reputation(for: attacker), reputationBefore,
            "a wrong-peer headerBatch2 response must cost the sender reputation"
        )

        await extractor.handleHeaderBatchWithProofsResponseForTesting(
            payload: headerBatchWithProofsPayload(
                requestID: requestID,
                entries: [("honest", Data("good".utf8), Data("proof".utf8))]
            ),
            ivy: ivy,
            from: target
        )
        XCTAssertEqual(box.value?.first?.cid, "honest")
        XCTAssertEqual(box.value?.first?.proof, Data("proof".utf8))
    }

    func testExtractorRejectsTruncatedPlainHeaderBatchEntirely() async throws {
        let (extractor, node, ivy) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let requestID = Data(repeating: 0xA5, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderResultBox()

        await extractor.registerPendingHeaderRequestForTesting(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }

        var payload = headerBatchPayload(
            requestID: requestID,
            entries: [
                ("cid-a", Data("block-a".utf8)),
                ("cid-b", Data("block-b".utf8)),
            ]
        )
        payload = payload.dropLast(3)

        await extractor.handleHeaderBatchResponseForTesting(payload: payload, ivy: ivy, from: target)

        XCTAssertEqual(box.value?.count, 0,
                       "a truncated header batch must be rejected WHOLE, never a prefix")
    }

    // MARK: - ChainNetwork: fail-closed now applies to plain headerBatch too

    func testChainNetworkHeaderBatchRejectsTruncatedResponseEntirely() async throws {
        let network = try await makeNetwork()
        let requestID = Data(repeating: 0xB1, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderResultBox()

        let inserted = await network.registerPendingHeaderRequest(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }
        XCTAssertTrue(inserted)

        var payload = headerBatchPayload(
            requestID: requestID,
            entries: [
                ("cid-a", Data("block-a".utf8)),
                ("cid-b", Data("block-b".utf8)),
            ]
        )
        payload = payload.dropLast(3)

        let outcome = await network.handleHeaderBatchResponse(payload: payload, from: target)
        XCTAssertEqual(outcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.count, 0,
                       "a truncated headerBatch must be rejected WHOLE, never a prefix")
    }

    func testChainNetworkHeaderBatchRejectsOversizedNumHeaders() async throws {
        let network = try await makeNetwork()
        let requestID = Data(repeating: 0xB2, count: 16)
        let target = PeerID(publicKey: "target-peer")
        let box = HeaderResultBox()

        let inserted = await network.registerPendingHeaderRequest(
            requestID: requestID,
            targetPeer: target
        ) { box.set($0) }
        XCTAssertTrue(inserted)

        let payload = headerBatchPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8))],
            declaredCountOverride: UInt32(ChainNetwork.maxHeaderBatchSize + 1)
        )

        let outcome = await network.handleHeaderBatchResponse(payload: payload, from: target)
        XCTAssertEqual(outcome, ChainNetwork.HeaderBatchResponseOutcome.accepted)
        XCTAssertEqual(box.value?.count, 0,
                       "numHeaders above maxHeaderBatchSize must reject the whole response")
    }

    // MARK: - Extractor: request-ID uniqueness (ChainNetwork discipline)

    func testExtractorRequestIDCollisionRedraws() async throws {
        let (extractor, node, _) = try await makeExtractor()
        defer { Task { await node.stop() } }
        let collidingID = Data(repeating: 0x55, count: 16)
        let redrawnID = Data(repeating: 0x66, count: 16)

        await extractor.registerPendingHeaderRequestForTesting(
            requestID: collidingID,
            targetPeer: PeerID(publicKey: "target-peer")
        ) { _ in }

        let draws = DrawCounter()
        let generated = await extractor.makeUniqueHeaderRequestIDForTesting { _ in
            draws.increment() == 1 ? collidingID : redrawnID
        }

        XCTAssertEqual(generated, redrawnID,
                       "a request ID colliding with an in-flight request must be redrawn")
        XCTAssertEqual(draws.count, 2)
    }

    // MARK: - Canonical codec: byte format pinned + round-trips

    func testEncodeHeaderRequestByteLayoutUnchanged() {
        let requestID = Data((0..<16).map { UInt8($0) })
        let payload = NetworkWireCodecs.encodeHeaderRequest(requestID: requestID, fromCID: "abc", count: 7)

        var expected = requestID
        expected.append(contentsOf: [0x03, 0x00])            // cidLen u16 LE
        expected.append(contentsOf: Array("abc".utf8))       // cid
        expected.append(contentsOf: [0x07, 0x00, 0x00, 0x00]) // count u32 LE
        XCTAssertEqual(payload, expected,
                       "encodeHeaderRequest must preserve the wire byte layout exactly")

        let parsed = NetworkWireCodecs.parseHeaderRequestPayload(payload!)
        XCTAssertEqual(parsed?.requestID, requestID)
        XCTAssertEqual(parsed?.fromCID, "abc")
        XCTAssertEqual(parsed?.count, 7)
    }

    func testEncodeHeaderRequestRejectsBadRequestID() {
        XCTAssertNil(NetworkWireCodecs.encodeHeaderRequest(
            requestID: Data(repeating: 0x01, count: 15), fromCID: "abc", count: 1
        ))
        XCTAssertNil(NetworkWireCodecs.encodeHeaderRequest(
            requestID: Data(repeating: 0x01, count: 17), fromCID: "abc", count: 1
        ))
    }

    func testHeaderBatchRoundTripValid() {
        let requestID = Data(repeating: 0xC1, count: 16)
        let entries: [(cid: String, data: Data)] = [
            ("cid-a", Data("block-a".utf8)),
            ("cid-b", Data("block-b-longer".utf8)),
        ]
        let payload = headerBatchPayload(requestID: requestID, entries: entries)

        XCTAssertEqual(NetworkWireCodecs.headerBatchResponseRequestID(payload), requestID)
        let parsed = NetworkWireCodecs.parseHeaderBatch(payload, maxHeaders: 1_000)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0].cid, "cid-a")
        XCTAssertEqual(parsed?[0].data, Data("block-a".utf8))
        XCTAssertEqual(parsed?[1].cid, "cid-b")
        XCTAssertEqual(parsed?[1].data, Data("block-b-longer".utf8))
    }

    func testHeaderBatch2RoundTripValidIncludingEmptyProof() {
        let requestID = Data(repeating: 0xC2, count: 16)
        let entries: [(cid: String, data: Data, proof: Data?)] = [
            ("cid-a", Data("block-a".utf8), Data("proof-a".utf8)),
            ("cid-b", Data("block-b".utf8), nil), // zero-length proof → nil
        ]
        let payload = headerBatchWithProofsPayload(requestID: requestID, entries: entries)

        XCTAssertEqual(NetworkWireCodecs.headerBatchResponseRequestID(payload), requestID)
        let parsed = NetworkWireCodecs.parseHeaderBatch2(payload, maxHeaders: 1_000)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0].cid, "cid-a")
        XCTAssertEqual(parsed?[0].data, Data("block-a".utf8))
        XCTAssertEqual(parsed?[0].proof, Data("proof-a".utf8))
        XCTAssertEqual(parsed?[1].cid, "cid-b")
        XCTAssertNil(parsed?[1].proof)
    }

    func testParseHeaderBatchFailClosed() {
        let requestID = Data(repeating: 0xC3, count: 16)
        let valid = headerBatchPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8)), ("cid-b", Data("block-b".utf8))]
        )

        // Shorter than requestID + numHeaders.
        XCTAssertNil(NetworkWireCodecs.parseHeaderBatch(Data(repeating: 0, count: 19), maxHeaders: 1_000))
        XCTAssertNil(NetworkWireCodecs.headerBatchResponseRequestID(Data(repeating: 0, count: 19)))
        // Every possible truncation of a valid payload must reject WHOLE.
        for keep in 20..<valid.count {
            XCTAssertNil(
                NetworkWireCodecs.parseHeaderBatch(valid.prefix(keep), maxHeaders: 1_000),
                "truncation to \(keep) bytes must reject the whole response"
            )
        }
        // Declared numHeaders above the bound.
        let oversized = headerBatchPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8))],
            declaredCountOverride: 1_001
        )
        XCTAssertNil(NetworkWireCodecs.parseHeaderBatch(oversized, maxHeaders: 1_000))
        // Invalid UTF-8 CID.
        var badCID = requestID
        badCID.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // numHeaders = 1
        badCID.append(contentsOf: [0x02, 0x00])             // cidLen = 2
        badCID.append(contentsOf: [0xFF, 0xFE])             // invalid UTF-8
        badCID.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // dataLen = 0
        XCTAssertNil(NetworkWireCodecs.parseHeaderBatch(badCID, maxHeaders: 1_000))
        // The untruncated payload still parses (sanity).
        XCTAssertEqual(NetworkWireCodecs.parseHeaderBatch(valid, maxHeaders: 1_000)?.count, 2)
    }

    func testParseHeaderBatch2FailClosed() {
        let requestID = Data(repeating: 0xC4, count: 16)
        let valid = headerBatchWithProofsPayload(
            requestID: requestID,
            entries: [
                ("cid-a", Data("block-a".utf8), Data("proof-a".utf8)),
                ("cid-b", Data("block-b".utf8), Data("proof-b".utf8)),
            ]
        )

        for keep in 20..<valid.count {
            XCTAssertNil(
                NetworkWireCodecs.parseHeaderBatch2(valid.prefix(keep), maxHeaders: 1_000),
                "truncation to \(keep) bytes must reject the whole response"
            )
        }
        let oversized = headerBatchWithProofsPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8), Data("proof-a".utf8))],
            declaredCountOverride: 1_001
        )
        XCTAssertNil(NetworkWireCodecs.parseHeaderBatch2(oversized, maxHeaders: 1_000))
        XCTAssertEqual(NetworkWireCodecs.parseHeaderBatch2(valid, maxHeaders: 1_000)?.count, 2)
    }

    // MARK: - Canonical codec: serving-side encoder (5th write-site unified)

    /// GOLDEN BYTES: the new encodeHeaderBatch must produce the exact bytes the
    /// old inline serving encoder produced. headerBatchPayload below is a
    /// byte-identical replica of that old inline encoder (it was pinned to it
    /// in #252), so equality proves zero wire-format change. Covers empty,
    /// single, multi-header, and zero-length data.
    func testEncodeHeaderBatchByteIdenticalToOldInlineEncoder() {
        let requestID = Data(repeating: 0xD1, count: 16)
        let cases: [[(cid: String, data: Data)]] = [
            [],                                                    // empty batch
            [("cid-a", Data("block-a".utf8))],                     // single
            [("cid-a", Data())],                                   // zero-length data
            [("cid-a", Data("block-a".utf8)),
             ("cid-b-longer", Data("block-b-much-longer".utf8))],  // multi-header
        ]
        for entries in cases {
            let encoded = NetworkWireCodecs.encodeHeaderBatch(requestID: requestID, headers: entries)
            let golden = headerBatchPayload(requestID: requestID, entries: entries)
            XCTAssertEqual(encoded, golden,
                           "encodeHeaderBatch must be byte-identical to the old inline serving encoder")
            // round-trip back through the canonical parser
            let parsed = NetworkWireCodecs.parseHeaderBatch(encoded, maxHeaders: 1_000)
            XCTAssertEqual(parsed?.count, entries.count)
            for (i, e) in entries.enumerated() {
                XCTAssertEqual(parsed?[i].cid, e.cid)
                XCTAssertEqual(parsed?[i].data, e.data)
            }
        }
    }

    /// GOLDEN BYTES for the proof-carrying variant. headerBatchWithProofsPayload
    /// is the byte-identical replica of the old inline getHeaders2 encoder.
    /// Covers empty, zero-length proof (nil), and multi-header.
    func testEncodeHeaderBatch2ByteIdenticalToOldInlineEncoder() {
        let requestID = Data(repeating: 0xD2, count: 16)
        let cases: [[(cid: String, data: Data, proof: Data?)]] = [
            [],                                                          // empty batch
            [("cid-a", Data("block-a".utf8), Data("proof-a".utf8))],     // single + proof
            [("cid-a", Data("block-a".utf8), nil)],                      // zero-length proof
            [("cid-a", Data("block-a".utf8), Data())],                   // explicit empty proof == nil on wire
            [("cid-a", Data("block-a".utf8), Data("proof-a".utf8)),
             ("cid-b", Data("block-b".utf8), nil),
             ("cid-c", Data(), Data("proof-c".utf8))],                   // multi-header, mixed proofs
        ]
        for entries in cases {
            let encoded = NetworkWireCodecs.encodeHeaderBatch2(requestID: requestID, entries: entries)
            let golden = headerBatchWithProofsPayload(requestID: requestID, entries: entries)
            XCTAssertEqual(encoded, golden,
                           "encodeHeaderBatch2 must be byte-identical to the old inline serving encoder")
            let parsed = NetworkWireCodecs.parseHeaderBatch2(encoded, maxHeaders: 1_000)
            XCTAssertEqual(parsed?.count, entries.count)
            for (i, e) in entries.enumerated() {
                XCTAssertEqual(parsed?[i].cid, e.cid)
                XCTAssertEqual(parsed?[i].data, e.data)
                // empty/nil proof both round-trip to nil
                let expectedProof = (e.proof?.isEmpty ?? true) ? nil : e.proof
                XCTAssertEqual(parsed?[i].proof, expectedProof)
            }
        }
    }

    /// Max-size batch (maxHeaderBatchSize entries) round-trips through the
    /// canonical encoder→parser pair with no truncation.
    func testEncodeHeaderBatchMaxSizeRoundTrip() {
        let requestID = Data(repeating: 0xD3, count: 16)
        let n = ChainNetwork.maxHeaderBatchSize
        let entries: [(cid: String, data: Data)] = (0..<n).map {
            ("cid-\($0)", Data("block-\($0)".utf8))
        }
        let encoded = NetworkWireCodecs.encodeHeaderBatch(requestID: requestID, headers: entries)
        XCTAssertEqual(encoded, headerBatchPayload(requestID: requestID, entries: entries))
        let parsed = NetworkWireCodecs.parseHeaderBatch(encoded, maxHeaders: n)
        XCTAssertEqual(parsed?.count, n)
        XCTAssertEqual(parsed?.last?.cid, "cid-\(n - 1)")
    }

    func testParsersAreSliceSafe() {
        let requestID = Data(repeating: 0xC5, count: 16)
        let payload = headerBatchWithProofsPayload(
            requestID: requestID,
            entries: [("cid-a", Data("block-a".utf8), Data("proof-a".utf8))]
        )
        var framed = Data("junk-prefix".utf8)
        framed.append(payload)
        let slice = framed.dropFirst("junk-prefix".utf8.count)

        XCTAssertEqual(NetworkWireCodecs.headerBatchResponseRequestID(slice), requestID)
        let parsed = NetworkWireCodecs.parseHeaderBatch2(slice, maxHeaders: 1_000)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?[0].cid, "cid-a")
        XCTAssertEqual(parsed?[0].proof, Data("proof-a".utf8))
    }

    // MARK: - Fixtures

    private func makeExtractor() async throws -> (ParentChainBlockExtractor, LatticeNode, Ivy) {
        let kp = CryptoUtils.generateKeyPair()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: nextTestPort(), storagePath: tmp, enableLocalDiscovery: false, minPeerKeyBits: 0
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        let extractor = ParentChainBlockExtractor(
            childDirectory: "Child", parentDirectory: nil,
            extractor: LatticeChildBlockExtractor(), node: node
        )
        let ivyKP = CryptoUtils.generateKeyPair()
        let ivy = Ivy(config: IvyConfig(
            publicKey: ivyKP.publicKey,
            listenPort: 0,
            bootstrapPeers: [],
            enableLocalDiscovery: false,
            stunServers: []
        ))
        return (extractor, node, ivy)
    }

    private func makeNetwork() async throws -> ChainNetwork {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = try DiskBroker(path: directory.appendingPathComponent("volumes.sqlite").path)
        let kp = CryptoUtils.generateKeyPair()
        return try await ChainNetwork(
            chainPath: ["Nexus"],
            config: IvyConfig(
                publicKey: kp.publicKey,
                listenPort: 0,
                bootstrapPeers: [],
                enableLocalDiscovery: false,
                stunServers: []
            ),
            sharedDiskBroker: disk
        )
    }

    // MARK: - Serving-side byte budget (silent frame-drop hazard)

    /// Documents the hazard the budget exists for: Ivy's `Message.serialize`
    /// returns EMPTY Data — a silent drop, never a truncation — once the
    /// peerMessage frame exceeds `maxFrameSize`. An unbudgeted header batch
    /// above the cap therefore never reaches the requester at all, and the
    /// requester loops on whatever tiny batch does fit.
    func testOversizedHeaderBatchIsSilentlyDroppedByIvyFraming() {
        let requestID = Data(repeating: 0xB2, count: 16)
        let big = Data(repeating: 0x42, count: 1 << 20) // 1 MiB per entry
        let headers: [(cid: String, data: Data)] = (0..<5).map { ("cid-\($0)", big) }
        let payload = NetworkWireCodecs.encodeHeaderBatch(requestID: requestID, headers: headers)
        XCTAssertGreaterThan(payload.count, Int(IvyConfig.defaultMaxFrameSize),
                             "fixture must exceed the frame cap")
        let frame = Message.peerMessage(topic: "headerBatch", payload: payload).serialize()
        XCTAssertTrue(frame.isEmpty,
                      "Ivy silently drops an over-cap frame — the serving handlers must budget the batch")
    }

    /// The handlers' batch-size decision layer: entries stop accumulating
    /// BEFORE the encoded response would bust the frame budget, the byte
    /// accounting matches the encoder exactly, and the truncated batch
    /// actually survives Ivy framing (non-empty serialized frame).
    func testHeaderBatchBudgetTruncatesBeforeFrameCap() {
        let requestID = Data(repeating: 0xB3, count: 16)
        let big = Data(repeating: 0x42, count: 1 << 20) // 1 MiB per entry
        var included: [(cid: String, data: Data)] = []
        var responseBytes = ChainNetwork.headerBatchBaseBytes
        for i in 0..<8 {
            let cid = "cid-\(i)"
            guard ChainNetwork.headerBatchHasRoom(
                currentBytes: responseBytes,
                cidByteCount: cid.utf8.count,
                dataByteCount: big.count,
                proofByteCount: nil
            ) else { break }
            responseBytes += ChainNetwork.headerBatchEntryBytes(
                cidByteCount: cid.utf8.count, dataByteCount: big.count, proofByteCount: nil)
            included.append((cid, big))
        }
        XCTAssertGreaterThan(included.count, 0, "budget must admit at least one entry")
        XCTAssertLessThan(included.count, 8, "budget must truncate an over-cap batch")
        let payload = NetworkWireCodecs.encodeHeaderBatch(requestID: requestID, headers: included)
        XCTAssertEqual(payload.count, responseBytes, "byte accounting must match the encoder exactly")
        XCTAssertLessThanOrEqual(payload.count, ChainNetwork.headerBatchByteBudget)
        let frame = Message.peerMessage(topic: "headerBatch", payload: payload).serialize()
        XCTAssertFalse(frame.isEmpty, "a budgeted batch must survive Ivy framing")
    }

    /// headerBatch2 accounting: a nil proof still encodes a 4-byte zero
    /// length, and proof bytes count against the budget byte-for-byte.
    func testHeaderBatch2BudgetAccountingMatchesEncoder() {
        let requestID = Data(repeating: 0xB4, count: 16)
        let entries: [(cid: String, data: Data, proof: Data?)] = [
            ("cid-a", Data("block-a".utf8), Data(repeating: 0x51, count: 96)),
            ("cid-b", Data("block-b".utf8), nil),
            ("cid-c", Data("block-c".utf8), Data(repeating: 0x52, count: 7)),
        ]
        var responseBytes = ChainNetwork.headerBatchBaseBytes
        for entry in entries {
            responseBytes += ChainNetwork.headerBatchEntryBytes(
                cidByteCount: entry.cid.utf8.count,
                dataByteCount: entry.data.count,
                proofByteCount: entry.proof?.count ?? 0)
        }
        let payload = NetworkWireCodecs.encodeHeaderBatch2(requestID: requestID, entries: entries)
        XCTAssertEqual(payload.count, responseBytes, "headerBatch2 byte accounting must match the encoder exactly")
    }
}

// MARK: - Wire payload builders (byte format pinned to the serving encoder
// in ChainNetwork+IvyDelegate getHeaders/getHeaders2 handlers)

fileprivate func headerBatchPayload(
    requestID: Data,
    entries: [(cid: String, data: Data)] = [],
    declaredCountOverride: UInt32? = nil
) -> Data {
    var payload = requestID
    var count = (declaredCountOverride ?? UInt32(entries.count)).littleEndian
    payload.append(Data(bytes: &count, count: 4))
    for entry in entries {
        let cidBytes = Data(entry.cid.utf8)
        var cidLength = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLength, count: 2))
        payload.append(cidBytes)
        var dataLength = UInt32(entry.data.count).littleEndian
        payload.append(Data(bytes: &dataLength, count: 4))
        payload.append(entry.data)
    }
    return payload
}

fileprivate func headerBatchWithProofsPayload(
    requestID: Data,
    entries: [(cid: String, data: Data, proof: Data?)] = [],
    declaredCountOverride: UInt32? = nil
) -> Data {
    var payload = requestID
    var count = (declaredCountOverride ?? UInt32(entries.count)).littleEndian
    payload.append(Data(bytes: &count, count: 4))
    for entry in entries {
        let cidBytes = Data(entry.cid.utf8)
        var cidLength = UInt16(cidBytes.count).littleEndian
        payload.append(Data(bytes: &cidLength, count: 2))
        payload.append(cidBytes)
        var dataLength = UInt32(entry.data.count).littleEndian
        payload.append(Data(bytes: &dataLength, count: 4))
        payload.append(entry.data)
        let proof = entry.proof ?? Data()
        var proofLength = UInt32(proof.count).littleEndian
        payload.append(Data(bytes: &proofLength, count: 4))
        payload.append(proof)
    }
    return payload
}

// MARK: - Result boxes

fileprivate final class HeaderResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [(cid: String, data: Data)]?
    var value: [(cid: String, data: Data)]? { lock.withLock { _value } }
    func set(_ value: [(cid: String, data: Data)]) { lock.withLock { _value = value } }
}

fileprivate final class DrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _count += 1
            return _count
        }
    }
}

fileprivate final class HeaderProofResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [(cid: String, data: Data, proof: Data?)]?
    var value: [(cid: String, data: Data, proof: Data?)]? { lock.withLock { _value } }
    func set(_ value: [(cid: String, data: Data, proof: Data?)]) { lock.withLock { _value = value } }
}
