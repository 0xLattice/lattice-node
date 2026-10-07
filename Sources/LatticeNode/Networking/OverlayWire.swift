import Foundation
import Ivy
import Lattice
import UInt256
import cashew

enum OverlayTopic {
    static let overlayHello = "lattice.overlay.hello.v1"
    static let transactionAvailable = "lattice.overlay.transaction.available.v1"
}

enum OverlayWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

private let _maximumNodeMessageSize = Int(IvyConfig.defaultProtocolMaxFrameSize) - 256

protocol CanonicalJSONMessage: Codable {
    func validate() throws
}

extension CanonicalJSONMessage {
    func encoded() throws -> Data {
        try validate()
        let data = try _canonicalJSONEncode(self)
        guard data.count <= _maximumNodeMessageSize else {
            throw OverlayWireError.oversized
        }
        return data
    }

    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw OverlayWireError.oversized
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw OverlayWireError.malformed
        }
        try value.validate()
        guard try _canonicalJSONEncode(value) == data else {
            throw OverlayWireError.nonCanonical
        }
        return value
    }
}

/// Announces one complete transaction Volume. The exact authenticated
/// advertiser is the first retrieval target; validity still comes from
/// content addressing and Lattice preflight.
struct TransactionAvailableMessage: CanonicalJSONMessage, Equatable, Sendable {
    let volumeRootCID: String

    func validate() throws {
        guard _isBoundedWireAtom(volumeRootCID) else {
            throw OverlayWireError.malformed
        }
    }
}

private func _isCanonicalWireCID(_ value: String) -> Bool {
    _isBoundedWireAtom(value) && CIDIdentity.isCanonical(value)
}
