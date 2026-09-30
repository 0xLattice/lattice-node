import Foundation
import Lattice
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// What a sync pass does with a proof fetched from a peer's child-evidence
/// index. Blame follows the bytes alone: bytes that verify are never
/// blamed, and bytes that fail are blamed on their sole supplier only when
/// every response was complete.
final class ChildEvidenceBlameTests: XCTestCase {
    /// Establishes: NODE-SEMANTICS-004.c
    func testVerifiedBytesAreNeverBlamed() {
        XCTAssertNil(NodeNetworkRuntime.childEvidenceBlame(
            failed: false, complete: true, soleSupplier: "supplier"
        ))
        XCTAssertNil(NodeNetworkRuntime.childEvidenceBlame(
            failed: false, complete: false, soleSupplier: "supplier"
        ))
    }

    func testFailedBytesBlameOnlyTheSoleSupplierOfACompleteFetch() {
        XCTAssertEqual(NodeNetworkRuntime.childEvidenceBlame(
            failed: true, complete: true, soleSupplier: "supplier"
        ), "supplier")
        XCTAssertNil(NodeNetworkRuntime.childEvidenceBlame(
            failed: true, complete: false, soleSupplier: "supplier"
        ))
        XCTAssertNil(NodeNetworkRuntime.childEvidenceBlame(
            failed: true, complete: true, soleSupplier: nil
        ))
    }

    func testAProofMustBindItsKeyAndGrind() async throws {
        let fixture = try await proofFixture()
        let valid = ChildEvidenceIndex.Entry(
            childCID: fixture.childCID,
            rootCID: fixture.proof.rootCID,
            attachmentCID: fixture.volume.rawCID
        )
        func check(
            _ entry: ChildEvidenceIndex.Entry,
            serialized: SerializedVolume? = nil,
            weighs: Bool? = nil
        ) async -> Bool {
            if case .valid = await ChildEvidenceIndex.verdict(
                serialized ?? fixture.volume.serialized,
                entry: entry,
                weighs: { _, _ in weighs }
            ) { return true }
            return false
        }
        let accepted = await check(valid)
        XCTAssertTrue(accepted)
        let heldAndWeighing = await check(valid, weighs: true)
        XCTAssertTrue(heldAndWeighing)
        // A carrier-only proof (no contribution) is refused: an honest
        // index never holds one.
        let carrier = await check(valid, weighs: false)
        XCTAssertFalse(carrier)
        let otherGrind = await check(ChildEvidenceIndex.Entry(
            childCID: valid.childCID,
            rootCID: protocolCID("another-grind"),
            attachmentCID: valid.attachmentCID
        ))
        XCTAssertFalse(otherGrind)
        let childDrift = await check(ChildEvidenceIndex.Entry(
            childCID: protocolCID("another-child"),
            rootCID: valid.rootCID,
            attachmentCID: valid.attachmentCID
        ))
        XCTAssertFalse(childDrift)
        let otherVolume = await check(ChildEvidenceIndex.Entry(
            childCID: valid.childCID,
            rootCID: valid.rootCID,
            attachmentCID: protocolCID("another-volume")
        ))
        XCTAssertFalse(otherVolume)
        let unavailable = await ChildEvidenceIndex.verdict(
            nil,
            entry: valid,
            weighs: { _, _ in nil }
        )
        guard case .invalid = unavailable else {
            return XCTFail("unavailable bytes verified: \(unavailable)")
        }
    }

    /// No local witness-size policy applies to a proof from a peer's index:
    /// one larger than a tight local limit that weighs is valid, so it is
    /// never skipped and re-fetched on every pass.
    func testAnOversizeWeighingProofIsAdmitted() async throws {
        let fixture = try await proofFixture()
        XCTAssertGreaterThan(fixture.volume.envelopeBytes.count, 64)
        let verdict = await ChildEvidenceIndex.verdict(
            fixture.volume.serialized,
            entry: ChildEvidenceIndex.Entry(
                childCID: fixture.childCID,
                rootCID: fixture.proof.rootCID,
                attachmentCID: fixture.volume.rawCID
            ),
            weighs: { _, _ in true }
        )
        guard case .valid = verdict else {
            return XCTFail("a weighing proof was \(verdict)")
        }
    }

    /// Size never excuses a proof that contributes no work to a held block:
    /// it is invalid, and blamed on the sole supplier of a complete fetch.
    func testAPaddedNonWeighingProofForAHeldBlockIsBlamed() async throws {
        let fixture = try await proofFixture()
        let verdict = await ChildEvidenceIndex.verdict(
            fixture.volume.serialized,
            entry: ChildEvidenceIndex.Entry(
                childCID: fixture.childCID,
                rootCID: fixture.proof.rootCID,
                attachmentCID: fixture.volume.rawCID
            ),
            weighs: { _, _ in false }
        )
        guard case .invalid = verdict else {
            return XCTFail("a non-weighing proof was \(verdict)")
        }
        XCTAssertEqual(NodeNetworkRuntime.childEvidenceBlame(
            failed: true, complete: true, soleSupplier: "supplier"
        ), "supplier")
    }

    /// A peer whose index holds many proofs for a block this node does not
    /// hold yet: one pass admits one of them, and the rest wait for the walk
    /// once the block is held and indexed.
    func testAnUnheldBlockAdmitsAtMostOneProofPerPass() async throws {
        let (childCID, proofs) = try await grinds(6)
        let broker = MemoryBroker()
        var entries: [ChildEvidenceIndex.Entry] = []
        for proof in proofs {
            let volume = try ChildEvidenceVolume(
                envelopeBytes: try ChildValidationPackageEnvelope(
                    ChildValidationPackage(proof: proof)
                ).encode(),
                childCID: childCID
            )
            try await volume.store(storer: broker)
            entries.append(ChildEvidenceIndex.Entry(
                childCID: childCID,
                rootCID: proof.rootCID,
                attachmentCID: volume.rawCID
            ))
        }
        let update = try await ChildEvidenceIndex.inserting(
            entries, into: nil, fetcher: broker, storer: broker
        )
        let root = try XCTUnwrap(update).root
        let collected = await ChildEvidenceIndex.collect(
            peerRoot: root,
            localRoot: nil,
            wanted: [childCID],
            peer: broker,
            local: broker,
            weighs: { _, _ in nil }
        )
        XCTAssertFalse(collected.failed)
        XCTAssertEqual(collected.verified.count, 1)
    }

    /// `count` distinct grinds proving one child block.
    private func grinds(_ count: Int) async throws -> (String, [ChildBlockProof]) {
        let content = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: content as any Storer
        )
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        var proofs: [ChildBlockProof] = []
        for timestamp in 0..<count {
            let root = try await BlockBuilder.buildGenesis(
                spec: NexusGenesis.spec,
                children: ["Leaf": leaf],
                timestamp: Int64(2 + timestamp),
                target: UInt256.max,
                fetcher: content
            )
            let rootHeader = try BlockHeader(node: root)
            try await rootHeader.storeRecursively(storer: content as any Storer)
            proofs.append(try await ChildBlockProof.generate(
                rootHeader: rootHeader,
                childDirectory: "Leaf",
                fetcher: content
            ))
        }
        return (try BlockHeader(node: leaf).rawCID, proofs)
    }

    private func proofFixture() async throws -> (
        proof: ChildBlockProof, childCID: String, volume: ChildEvidenceVolume
    ) {
        let content = InMemoryContentStore()
        try await LatticeState.emptyHeader.storeRecursively(
            storer: content as any Storer
        )
        let leaf = try await BlockBuilder.buildChildGenesis(
            spec: NexusGenesis.spec,
            parentState: LatticeState.emptyHeader,
            timestamp: 1,
            target: UInt256.max,
            fetcher: content
        )
        let root = try await BlockBuilder.buildGenesis(
            spec: NexusGenesis.spec,
            children: ["Leaf": leaf],
            timestamp: 2,
            target: UInt256.max,
            fetcher: content
        )
        let rootHeader = try BlockHeader(node: root)
        try await rootHeader.storeRecursively(storer: content as any Storer)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Leaf",
            fetcher: content
        )
        let childCID = try BlockHeader(node: leaf).rawCID
        let volume = try ChildEvidenceVolume(
            envelopeBytes: try ChildValidationPackageEnvelope(
                ChildValidationPackage(proof: proof)
            ).encode(),
            childCID: childCID
        )
        return (proof, childCID, volume)
    }

    private func protocolCID(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }
}
