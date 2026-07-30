import Foundation
import Ivy
import Lattice

public enum ChildValidationPackageEnvelopeError: Error, Equatable, Sendable {
    case oversized
    case malformed
}

/// A child package whose cross-chain facts were derived by local validation.
///
/// Peer input can contain only a proof. Keeping this wrapper internal to the
/// node prevents a received genesis or continuity claim from reaching Lattice.
public struct AuthenticatedChildPackage: Sendable {
    let package: ChildValidationPackage

    init(package: ChildValidationPackage) {
        self.package = package
    }
}

/// Deterministic, bounded transport for one structural child-work proof.
/// Consensus meaning remains entirely in Lattice.
public struct ChildValidationPackageEnvelope: Sendable {
    // Leave room for Ivy framing.
    public static let maximumEncodedSize = Int(IvyConfig.defaultProtocolMaxFrameSize)
        - 1024

    private static let magic = Data("LNCPKG06".utf8)

    public let proofBytes: Data

    public init(proof: ChildBlockProof) throws {
        proofBytes = try proof.serialize()
        try validateCanonicalContents()
    }

    public init(_ package: ChildValidationPackage) throws {
        try self.init(proof: package.proof)
    }

    private init(proofBytes: Data) throws {
        self.proofBytes = proofBytes
        try validateCanonicalContents()
    }

    public func encode() throws -> Data {
        try validateCanonicalContents()
        var data = Data(capacity: Self.magic.count + proofBytes.count)
        data.append(Self.magic)
        data.append(proofBytes)
        guard data.count <= Self.maximumEncodedSize else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        return data
    }

    public static func decode(
        _ data: Data,
        maximumEncodedSize localMaximumEncodedSize: Int = maximumEncodedSize
    ) throws -> ChildValidationPackageEnvelope {
        guard localMaximumEncodedSize > 0,
              data.count <= min(maximumEncodedSize, localMaximumEncodedSize)
        else {
            throw ChildValidationPackageEnvelopeError.oversized
        }
        guard data.count > magic.count, data.prefix(magic.count) == magic else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        // Canonicity is enforced by `init(proofBytes:)` → `validateCanonicalContents`
        // (`proof.serialize() == proofBytes`). A re-`encode() == data` check would be
        // tautological here: `encode()` is `magic + proofBytes`, and the magic prefix
        // is already verified above, so it always equals `data`.
        return try ChildValidationPackageEnvelope(
            proofBytes: Data(data.dropFirst(magic.count))
        )
    }

    func makeValidationPackage(
        parentGenesisLink: ParentGenesisLink? = nil,
        parentStateContinuityLink: ParentStateContinuityLink? = nil
    ) throws -> ChildValidationPackage {
        guard let proof = ChildBlockProof.deserialize(proofBytes) else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
        return ChildValidationPackage(
            proof: proof,
            parentGenesisLink: parentGenesisLink,
            parentStateContinuityLink: parentStateContinuityLink
        )
    }

    private func validateCanonicalContents() throws {
        guard !proofBytes.isEmpty,
              proofBytes.count + Self.magic.count <= Self.maximumEncodedSize,
              let proof = ChildBlockProof.deserialize(proofBytes),
              (try? proof.serialize()) == proofBytes,
              _isBoundedWireAtom(proof.rootCID),
              proof.directoryPath.allSatisfy({ _isBoundedDirectoryAtom($0) })
        else {
            throw ChildValidationPackageEnvelopeError.malformed
        }
    }
}
