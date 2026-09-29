import Foundation
import Lattice
import UInt256
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
            await ChildEvidenceIndex.verified(
                serialized ?? fixture.volume.serialized,
                entry: entry,
                maximumEncodedSize: NodeResourcePolicy.default.maximumParentWitnessBytes,
                weighs: { _, _ in weighs }
            ) != nil
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
        let unavailable = await ChildEvidenceIndex.verified(
            nil,
            entry: valid,
            maximumEncodedSize: NodeResourcePolicy.default.maximumParentWitnessBytes,
            weighs: { _, _ in nil }
        )
        XCTAssertNil(unavailable)
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
