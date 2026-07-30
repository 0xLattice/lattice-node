import Foundation
import Lattice
import VolumeBroker
import cashew

enum ChildEvidenceVolumeError: Error, Equatable, Sendable {
    case malformed
    case oversized
}

/// One complete evidence Volume containing only the parent-issued proof
/// envelope. Child-chain validation content remains owned and served by the
/// child chain.
struct ChildEvidenceVolume: Sendable {
    private struct Manifest: Scalar {
        let childCID: String
        let envelope: Data
    }

    static let maximumFramedBytes =
        ChildValidationPackageEnvelope.maximumEncodedSize
        + 1024
    static let maximumArchiveBytes = maximumFramedBytes + 2

    let serialized: SerializedVolume
    let envelopeBytes: Data

    var rawCID: String { serialized.root }

    init(
        envelopeBytes: Data,
        childCID: String
    ) throws {
        guard !envelopeBytes.isEmpty, !childCID.isEmpty else {
            throw ChildEvidenceVolumeError.malformed
        }
        let manifest = Manifest(
            childCID: childCID,
            envelope: envelopeBytes
        )
        let header = try VolumeImpl<Manifest>(node: manifest)
        let rootData = try header.mapToData()
        try self.init(
            serialized: SerializedVolume(
                root: header.rawCID,
                entries: [header.rawCID: rootData]
            ),
            childCID: childCID
        )
    }

    init(serialized: SerializedVolume, childCID: String? = nil) throws {
        try serialized.validate()
        guard let rootData = serialized.entries[serialized.root],
              let manifest = Manifest(data: rootData),
              !manifest.childCID.isEmpty,
              !manifest.envelope.isEmpty,
              serialized.entries.count == 1 else {
            throw ChildEvidenceVolumeError.malformed
        }
        let canonicalRoot = try VolumeImpl<Manifest>(node: manifest)
        guard canonicalRoot.rawCID == serialized.root,
              try canonicalRoot.mapToData() == rootData else {
            throw ChildEvidenceVolumeError.malformed
        }
        guard childCID.map({ $0 == manifest.childCID }) ?? true else {
            throw ChildEvidenceVolumeError.malformed
        }
        let rootFramedBytes = 6 + serialized.root.utf8.count + rootData.count
        guard rootFramedBytes <= Self.maximumFramedBytes else {
            throw ChildEvidenceVolumeError.oversized
        }
        self.serialized = serialized
        envelopeBytes = manifest.envelope
    }

    func store(storer: any VolumeStorer) async throws {
        try await storer.store(volume: serialized)
    }
}
