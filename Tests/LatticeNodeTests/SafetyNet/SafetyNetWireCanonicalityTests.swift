import Foundation
import Lattice
import UInt256
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: every wire codec in `Sources/LatticeNode` is canonical.
///
/// For seeded random VALID messages of every codec, `decode(encode(m)) == m`
/// and `encode(decode(bytes)) == bytes` for `bytes = encode(m)`. The existing
/// `WireProtocolFuzzTests` cover the adversarial direction (mutated bytes must
/// be refused) from ONE hand-written seed per JSON decoder; this file covers
/// the honest direction across the value space, and also the codecs the fuzz
/// corpus does not reach: the child-evidence root, the two binary frames
/// (`ParentTipContextMessage` with its `minimumWorkTrailer`,
/// `ChildCandidateAvailableMessage` with its search witness), `ChainHello`,
/// `ChildValidationPackageEnvelope`, `ChildEvidenceVolume`, and the RPC
/// types with a custom Codable (`ContentBoundTransaction`,
/// `ContentBoundWasmPolicyModule`, `SubmitTransactionRequest`,
/// `MiningTemplateRequest`).
///
/// Deterministic: one fixed `SplitMix64` seed per codec (the shared generator
/// in `Support/SeededGenerator.swift`), so a failure names the codec and the
/// iteration and replays exactly. No byte golden is checked in
/// on purpose: the property is self-describing and every CID here changes
/// with the next consensus flag day.
final class SafetyNetWireCanonicalityTests: XCTestCase {

    private static let messagesPerCodec = 48

    // MARK: - Deterministic value generators

    private func cid(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }

    private func randomCID(_ generator: inout SplitMix64) -> String {
        cid("safety-net-wire-\(generator.next())")
    }

    /// `count` distinct canonical CIDs, sorted.
    private func randomCIDs(
        _ generator: inout SplitMix64, count: Int
    ) -> [String] {
        var set = Set<String>()
        while set.count < count { set.insert(randomCID(&generator)) }
        return set.sorted()
    }

    private func randomInt(
        _ generator: inout SplitMix64, _ range: ClosedRange<Int>
    ) -> Int {
        Int.random(in: range, using: &generator)
    }

    private func randomBool(_ generator: inout SplitMix64) -> Bool {
        Bool.random(using: &generator)
    }

    private func nonZeroID(_ generator: inout SplitMix64) -> UInt64 {
        max(1, UInt64.random(in: 1...UInt64.max, using: &generator))
    }

    /// A printable-ASCII wire atom without `/` (so it is also a directory).
    private func randomAtom(_ generator: inout SplitMix64) -> String {
        let alphabet = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:~"
        )
        return String((0..<randomInt(&generator, 1...12)).map { _ in
            alphabet[randomInt(&generator, 0...(alphabet.count - 1))]
        })
    }

    /// An absolute chain path of at least `minimumCount` components.
    private func randomChainPath(
        _ generator: inout SplitMix64, minimumCount: Int
    ) -> [String] {
        let extra = randomInt(&generator, max(0, minimumCount - 1)...3)
        let path = ["Nexus"] + (0..<extra).map { _ in randomAtom(&generator) }
        precondition(_isAbsoluteChainPath(path), "generator produced a bad path")
        return path
    }

    // MARK: - The property

    /// `decode(encode(m)) == m` and `encode(decode(bytes)) == bytes`, for
    /// `messagesPerCodec` seeded messages. A generator that cannot produce a
    /// message its own validator accepts FAILS (`encoded()` throws) rather
    /// than being skipped.
    private func assertCanonical<M: NodeJSONMessage & Equatable>(
        _ type: M.Type,
        seed: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ make: (inout SplitMix64) throws -> M
    ) throws {
        let name = String(describing: M.self)
        var generator = SplitMix64(state: seed)
        for iteration in 0..<Self.messagesPerCodec {
            let message = try make(&generator)
            let bytes = try message.encoded()
            let decoded = try M.decoded(bytes)
            XCTAssertEqual(
                decoded, message,
                "\(name) #\(iteration): decode(encode(m)) != m",
                file: file, line: line
            )
            XCTAssertEqual(
                try decoded.encoded(), bytes,
                "\(name) #\(iteration): encode(decode(bytes)) != bytes",
                file: file, line: line
            )
        }
    }

    // MARK: - JSON messages (every NodeJSONMessage conformer)

    func testBlockAnnouncementIsCanonical() throws {
        try assertCanonical(BlockAnnouncementMessage.self, seed: 0x01) { g in
            BlockAnnouncementMessage(
                blockCID: self.randomCID(&g),
                height: self.randomBool(&g)
                    ? UInt64.random(in: 0...UInt64.max, using: &g) : nil
            )
        }
    }

    func testTransactionAvailableIsCanonical() throws {
        try assertCanonical(TransactionAvailableMessage.self, seed: 0x02) { g in
            TransactionAvailableMessage(volumeRootCID: self.randomCID(&g))
        }
    }

    func testTransactionInventoryRequestIsCanonical() throws {
        try assertCanonical(TransactionInventoryRequestMessage.self, seed: 0x03) { g in
            TransactionInventoryRequestMessage(
                requestID: self.nonZeroID(&g),
                afterRootCID: self.randomBool(&g) ? self.randomCID(&g) : nil
            )
        }
    }

    /// Cursor pages: entries must be unique, sorted, all after the cursor, and
    /// `hasMore` only on a full page.
    private func cursorPage(
        _ generator: inout SplitMix64, pageSize: Int
    ) -> (after: String?, entries: [String], hasMore: Bool) {
        let full = randomBool(&generator) && randomBool(&generator)
        let count = full ? pageSize : randomInt(&generator, 0...(pageSize - 1))
        let pool = randomCIDs(&generator, count: count + 1)
        let after = randomBool(&generator) ? pool[0] : nil
        return (after, Array(pool.dropFirst()), full && randomBool(&generator))
    }

    func testTransactionInventoryResponseIsCanonical() throws {
        try assertCanonical(TransactionInventoryResponseMessage.self, seed: 0x04) { g in
            let page = self.cursorPage(
                &g, pageSize: TransactionInventoryResponseMessage.maximumRoots
            )
            return TransactionInventoryResponseMessage(
                requestID: self.nonZeroID(&g),
                afterRootCID: page.after,
                volumeRootCIDs: page.entries,
                hasMore: page.hasMore
            )
        }
    }

    func testAcceptedLeavesRequestIsCanonical() throws {
        try assertCanonical(AcceptedLeavesRequestMessage.self, seed: 0x05) { g in
            AcceptedLeavesRequestMessage(
                requestID: self.nonZeroID(&g),
                afterCID: self.randomBool(&g) ? self.randomCID(&g) : nil,
                snapshotSequence: self.randomBool(&g)
                    ? Int64.random(in: 0...Int64.max, using: &g) : nil
            )
        }
    }

    func testAcceptedLeavesResponseIsCanonical() throws {
        try assertCanonical(AcceptedLeavesResponseMessage.self, seed: 0x06) { g in
            let page = self.cursorPage(
                &g, pageSize: AcceptedLeavesResponseMessage.maximumLeaves
            )
            return AcceptedLeavesResponseMessage(
                requestID: self.nonZeroID(&g),
                afterCID: page.after,
                snapshotSequence: Int64.random(in: 0...Int64.max, using: &g),
                blockCIDs: page.entries,
                hasMore: page.hasMore
            )
        }
    }

    func testForwardRangeRequestIsCanonical() throws {
        try assertCanonical(ForwardRangeRequestMessage.self, seed: 0x07) { g in
            ForwardRangeRequestMessage(
                requestID: self.nonZeroID(&g), afterCID: self.randomCID(&g)
            )
        }
    }

    func testForwardRangeResponseIsCanonical() throws {
        try assertCanonical(ForwardRangeResponseMessage.self, seed: 0x08) { g in
            let full = self.randomBool(&g)
            let count = full
                ? ForwardRangeResponseMessage.maximumBlocks
                : self.randomInt(&g, 0...(ForwardRangeResponseMessage.maximumBlocks - 1))
            // Chain order, not sorted: the validator does not sort this page.
            let blocks = (0..<count).map { _ in self.randomCID(&g) }
            return ForwardRangeResponseMessage(
                requestID: self.nonZeroID(&g),
                afterCID: self.randomCID(&g),
                blockCIDs: blocks,
                hasMore: full && self.randomBool(&g)
            )
        }
    }

    func testAncestorRangeRequestIsCanonical() throws {
        try assertCanonical(AncestorRangeRequestMessage.self, seed: 0x09) { g in
            let count = self.randomInt(
                &g, 1...AncestorRangeRequestMessage.maximumLocatorEntries
            )
            return AncestorRangeRequestMessage(
                requestID: self.nonZeroID(&g),
                locator: (0..<count).map { _ in self.randomCID(&g) }
            )
        }
    }

    func testAncestorRangeResponseIsCanonical() throws {
        try assertCanonical(AncestorRangeResponseMessage.self, seed: 0x0a) { g in
            let ancestor = self.randomBool(&g) ? self.randomCID(&g) : nil
            var blocks: [String] = []
            var hasMore = false
            if ancestor != nil {
                let full = self.randomBool(&g)
                let count = full
                    ? AncestorRangeResponseMessage.maximumBlocks
                    : self.randomInt(&g, 0...(AncestorRangeResponseMessage.maximumBlocks - 1))
                blocks = (0..<count).map { _ in self.randomCID(&g) }
                hasMore = full && self.randomBool(&g)
            }
            return AncestorRangeResponseMessage(
                requestID: self.nonZeroID(&g),
                commonAncestor: ancestor,
                blockCIDs: blocks,
                hasMore: hasMore
            )
        }
    }

    // MARK: - Core driver header sync topics

    func testCoreStreamRequestIsCanonical() throws {
        try assertCanonical(StreamRequestMessage.self, seed: 0x40) { g in
            StreamRequestMessage(
                chainPath: self.randomChainPath(&g, minimumCount: 1),
                requestID: self.nonZeroID(&g),
                logID: self.randomBool(&g) ? self.randomCID(&g) : nil,
                after: UInt64(self.randomInt(&g, 0...1_000_000))
            )
        }
    }

    func testCoreStreamPageIsCanonical() throws {
        try assertCanonical(StreamPageMessage.self, seed: 0x43) { g in
            StreamPageMessage(
                chainPath: self.randomChainPath(&g, minimumCount: 1),
                requestID: UInt64(self.randomInt(&g, 0...1_000_000)),
                logID: self.randomCID(&g),
                entries: (0..<self.randomInt(&g, 0...8)).map { index in
                    let block = self.randomCID(&g)
                    let proof = self.randomBool(&g)
                    return WireLogEntry(position: UInt64(index + 1), proof: proof, cid: proof ? self.randomCID(&g) : block, block: block)
                },
                hasMore: self.randomBool(&g)
            )
        }
    }

    func testCoreDataRequestIsCanonical() throws {
        try assertCanonical(DataRequestMessage.self, seed: 0x44) { g in
            DataRequestMessage(
                chainPath: self.randomChainPath(&g, minimumCount: 1),
                requestID: self.nonZeroID(&g),
                cids: (0..<self.randomInt(&g, 0...8)).map { _ in self.randomCID(&g) }
            )
        }
    }

    func testCoreAncestorsRequestIsCanonical() throws {
        try assertCanonical(AncestorsRequestMessage.self, seed: 0x41) { g in
            AncestorsRequestMessage(
                chainPath: self.randomChainPath(&g, minimumCount: 1),
                requestID: self.nonZeroID(&g),
                cid: self.randomCID(&g),
                maximum: self.randomInt(&g, 1...AncestorsRequestMessage.maximumAncestors)
            )
        }
    }

    func testCoreHeadersResponseIsCanonical() throws {
        try assertCanonical(HeadersResponseMessage.self, seed: 0x42) { g in
            let entries = try (0..<self.randomInt(&g, 0...8)).map { _ -> WireHeaderEntry in
                let block = Block(
                    parent: self.randomBool(&g) ? VolumeImpl<Block>(rawCID: self.randomCID(&g)) : nil,
                    transactions: HeaderImpl(rawCID: self.randomCID(&g)),
                    target: UInt256(UInt64.random(in: 1...UInt64.max, using: &g)),
                    nextTarget: UInt256(UInt64.random(in: 1...UInt64.max, using: &g)),
                    spec: VolumeImpl(rawCID: self.randomCID(&g)),
                    parentState: LatticeStateHeader(rawCID: self.randomCID(&g)),
                    prevState: LatticeStateHeader(rawCID: self.randomCID(&g)),
                    postState: LatticeStateHeader(rawCID: self.randomCID(&g)),
                    children: HeaderImpl(rawCID: self.randomCID(&g)),
                    height: UInt64(self.randomInt(&g, 0...1_000_000)),
                    timestamp: Int64(self.randomInt(&g, 0...Int(Int32.max))),
                    rewardRecipient: nil,
                    nonce: UInt64.random(in: 0...UInt64.max, using: &g)
                )
                let children = self.randomBool(&g)
                    ? ChildIndex(entries: [self.randomAtom(&g): VolumeImpl<Block>(rawCID: self.randomCID(&g))])
                    : nil
                let proofs = try (0..<self.randomInt(&g, 0...2)).map { _ in
                    try ChildBlockProof(
                        rootCID: self.randomCID(&g),
                        directoryPath: self.randomChainPath(&g, minimumCount: 2),
                        entries: [(cid: self.randomCID(&g), data: Data(self.randomAtom(&g).utf8))]
                    ).serialize()
                }
                return WireHeaderEntry(
                    block: try XCTUnwrap(block.toData()),
                    children: try children.map { try XCTUnwrap($0.toData()) },
                    proofs: proofs
                )
            }
            return HeadersResponseMessage(
                chainPath: self.randomChainPath(&g, minimumCount: 1),
                requestID: UInt64.random(in: 0...UInt64.max, using: &g),
                entries: entries,
                hasMore: self.randomBool(&g)
            )
        }
    }

    func testReadEndpointRequestIsCanonical() throws {
        try assertCanonical(ReadEndpointRequestMessage.self, seed: 0x0d) { g in
            ReadEndpointRequestMessage(
                requestID: self.nonZeroID(&g), genesisCID: self.randomCID(&g)
            )
        }
    }

    func testReadEndpointResponseIsCanonical() throws {
        try assertCanonical(ReadEndpointResponseMessage.self, seed: 0x0e) { g in
            let count = self.randomInt(&g, 0...ReadEndpointResponseMessage.maximumURLs)
            let urls = (0..<count).map { index -> String in
                // Already-normalized bases only: the validator demands
                // `normalizedPublicReadURL(url) == url`.
                let port = self.randomBool(&g) ? ":\(self.randomInt(&g, 1...65535))" : ""
                let path = self.randomBool(&g) ? "/read" : ""
                return "https://node\(index)-\(g.next() % 1000).example\(port)\(path)"
            }
            return ReadEndpointResponseMessage(
                requestID: self.nonZeroID(&g),
                genesisCID: self.randomCID(&g),
                readURLs: urls
            )
        }
    }

    func testChildEvidenceRootIsCanonical() throws {
        try assertCanonical(ChildEvidenceRootMessage.self, seed: 0x0f) { g in
            ChildEvidenceRootMessage(rootCID: self.randomCID(&g))
        }
    }

    // MARK: - Content fixtures for the binary frames

    /// A real direct-child proof (root genesis carrying one child genesis),
    /// the shape `ChildValidationPackageEnvelope` and the candidate frame's
    /// search witness transport. Distinct `timestamp`s give distinct proofs.
    private func childProof(
        timestamp: Int64
    ) async throws -> (proof: ChildBlockProof, root: Block) {
        let store = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(storer: store as any Storer)
        let child = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: store
        )
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Payments": child],
            timestamp: timestamp + 1,
            target: UInt256.max,
            fetcher: store
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: store as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Payments",
            fetcher: store
        )
        return (proof, root)
    }

    /// An unsigned-but-content-bound transaction under `chainPath`: the frame
    /// binds body bytes to the body CID, never the signature.
    private func rewardTransaction(
        chainPath: [String], generator: inout SplitMix64
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: [AccountAction(
                owner: randomCID(&generator),
                delta: Int64(randomInt(&generator, 1...1_000_000))
            )],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [randomCID(&generator)],
            nonce: UInt64.random(in: 0...UInt64.max, using: &generator),
            chainPath: chainPath
        )
        return Transaction(
            signatures: [randomAtom(&generator): randomAtom(&generator)],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
    }

    // MARK: - Binary hierarchy frames

    func testChainHelloIsCanonical() throws {
        var generator = SplitMix64(state: 0x1b)
        for iteration in 0..<Self.messagesPerCodec {
            let hello = ChainHello(
                nexusGenesisCID: randomCID(&generator),
                chainPath: randomChainPath(&generator, minimumCount: 1),
                publicReadURL: randomBool(&generator)
                    ? "https://hello\(generator.next() % 1000).example" : nil
            )
            let bytes = try hello.encode()
            let decoded = try ChainHello.decode(bytes)
            XCTAssertEqual(decoded, hello, "ChainHello #\(iteration)")
            XCTAssertEqual(
                try decoded.encode(), bytes,
                "ChainHello #\(iteration): encode(decode(bytes)) != bytes"
            )
        }
    }

    func testChildValidationPackageEnvelopeIsCanonical() async throws {
        for timestamp in stride(from: Int64(1), through: 13, by: 3) {
            let proof = try await childProof(timestamp: timestamp).proof
            let envelope = try ChildValidationPackageEnvelope(proof: proof)
            let bytes = try envelope.encode()
            let decoded = try ChildValidationPackageEnvelope.decode(bytes)
            let provenance = "ChildValidationPackageEnvelope timestamp=\(timestamp)"
            XCTAssertEqual(decoded.proofBytes, envelope.proofBytes, provenance)
            XCTAssertEqual(
                try decoded.encode(), bytes,
                "\(provenance): encode(decode(bytes)) != bytes"
            )
            XCTAssertEqual(
                try decoded.makeValidationPackage().proof.serialize(),
                try proof.serialize(),
                provenance
            )
        }
    }

    func testChildEvidenceVolumeIsCanonical() async throws {
        var generator = SplitMix64(state: 0x1c)
        for timestamp in stride(from: Int64(2), through: 14, by: 3) {
            let proof = try await childProof(timestamp: timestamp).proof
            let envelopeBytes = try ChildValidationPackageEnvelope(proof: proof).encode()
            let volume = try ChildEvidenceVolume(
                envelopeBytes: envelopeBytes,
                childCID: randomCID(&generator)
            )
            let decoded = try ChildEvidenceVolume(serialized: volume.serialized)
            let provenance = "ChildEvidenceVolume timestamp=\(timestamp)"
            XCTAssertEqual(decoded.rawCID, volume.rawCID, provenance)
            XCTAssertEqual(decoded.envelopeBytes, envelopeBytes, provenance)
            XCTAssertEqual(
                decoded.serialized.entries, volume.serialized.entries,
                "\(provenance): the re-read volume differs from the stored one"
            )
        }
    }

    func testContentBoundWasmPolicyModuleIsCanonical() throws {
        var generator = SplitMix64(state: 0x1e)
        for iteration in 0..<Self.messagesPerCodec {
            // `WasmPolicyModule` validates nothing about the bytes; the codec
            // binds them to their root CID, which is what is checked here.
            let bytes = Data((0..<randomInt(&generator, 1...64)).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            })
            let module = try ContentBoundWasmPolicyModule(bytes: bytes)
            let encoded = try _canonicalJSONEncode(module)
            let decoded = try JSONDecoder().decode(ContentBoundWasmPolicyModule.self, from: encoded)
            let provenance = "ContentBoundWasmPolicyModule #\(iteration)"
            XCTAssertEqual(decoded.rootCID, module.rootCID, provenance)
            XCTAssertEqual(decoded.bytes, bytes, provenance)
            XCTAssertEqual(
                try _canonicalJSONEncode(decoded), encoded,
                "\(provenance): encode(decode(bytes)) != bytes"
            )
        }
    }

    func testSubmitTransactionRequestIsCanonical() throws {
        var generator = SplitMix64(state: 0x1f)
        for iteration in 0..<Self.messagesPerCodec {
            let request = SubmitTransactionRequest(transaction: try rewardTransaction(
                chainPath: randomChainPath(&generator, minimumCount: 1),
                generator: &generator
            ))
            let encoded = try _canonicalJSONEncode(request)
            let decoded = try JSONDecoder().decode(SubmitTransactionRequest.self, from: encoded)
            let provenance = "SubmitTransactionRequest #\(iteration)"
            XCTAssertEqual(decoded.transaction.body.rawCID, request.transaction.body.rawCID, provenance)
            XCTAssertEqual(decoded.transaction.signatures, request.transaction.signatures, provenance)
            XCTAssertEqual(
                try _canonicalJSONEncode(decoded), encoded,
                "\(provenance): encode(decode(bytes)) != bytes"
            )
        }
    }

    func testMiningTemplateRequestIsCanonical() throws {
        var generator = SplitMix64(state: 0x21)
        for iteration in 0..<Self.messagesPerCodec {
            let recipients = (0..<randomInt(&generator, 0...3)).map { _ -> MiningRecipient in
                MiningRecipient(
                    chainPath: randomChainPath(&generator, minimumCount: 1),
                    address: CryptoUtils.createAddress(
                        from: String(UInt64.random(in: 0...UInt64.max, using: &generator))
                    )
                )
            }
            // `minimumWork` is omitted from the wire when empty; both shapes
            // every run, by construction.
            let minimumWork = iteration.isMultiple(of: 2) ? [] : [MiningMinimumWork(
                chainPath: randomChainPath(&generator, minimumCount: 1),
                work: UInt256(UInt64.random(in: 1...UInt64.max, using: &generator))
            )]
            let request = MiningTemplateRequest(recipients: recipients, minimumWork: minimumWork)
            let encoded = try _canonicalJSONEncode(request)
            let decoded = try JSONDecoder().decode(MiningTemplateRequest.self, from: encoded)
            let provenance = "MiningTemplateRequest #\(iteration)"
            XCTAssertEqual(decoded.minimumWork, request.minimumWork, provenance)
            XCTAssertEqual(decoded.recipients, request.recipients, provenance)
            XCTAssertEqual(
                try _canonicalJSONEncode(decoded), encoded,
                "\(provenance): encode(decode(bytes)) != bytes"
            )
        }
    }

    func testContentBoundTransactionIsCanonical() throws {
        var generator = SplitMix64(state: 0x1d)
        for iteration in 0..<Self.messagesPerCodec {
            let transaction = try rewardTransaction(
                chainPath: randomChainPath(&generator, minimumCount: 1),
                generator: &generator
            )
            let bound = try ContentBoundTransaction(transaction: transaction)
            let bytes = try _canonicalJSONEncode(bound)
            let decoded = try JSONDecoder().decode(ContentBoundTransaction.self, from: bytes)
            let provenance = "ContentBoundTransaction #\(iteration)"
            XCTAssertEqual(decoded.signatures, bound.signatures, provenance)
            XCTAssertEqual(
                try decoded.transaction().body.rawCID,
                transaction.body.rawCID,
                provenance
            )
            XCTAssertEqual(
                try _canonicalJSONEncode(decoded), bytes,
                "\(provenance): encode(decode(bytes)) != bytes"
            )
        }
    }
}
