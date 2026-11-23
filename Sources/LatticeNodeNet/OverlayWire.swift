import Foundation
import Ivy
import Lattice
import UInt256
import cashew

package enum OverlayTopic {
    package static let overlayHello = "lattice.overlay.hello.v1"
    package static let transactionAvailable = "lattice.overlay.transaction.available.v1"
}

package enum OverlayWireError: Error, Equatable, Sendable {
    case oversized
    case malformed
    case nonCanonical
}

private let _maximumNodeMessageSize = Int(IvyConfig.defaultProtocolMaxFrameSize) - 256

package protocol CanonicalJSONMessage: Codable {
    func validate() throws
    /// The message's one canonical spelling: `_canonicalJSONEncode`'s bytes.
    func canonicalJSON() throws -> Data
}

extension CanonicalJSONMessage {
    package func canonicalJSON() throws -> Data {
        try _canonicalJSONEncode(self)
    }

    package func encoded() throws -> Data {
        try validate()
        let data = try canonicalJSON()
        guard data.count <= _maximumNodeMessageSize else {
            throw OverlayWireError.oversized
        }
        return data
    }

    package static func decoded(_ data: Data) throws -> Self {
        guard data.count <= _maximumNodeMessageSize else {
            throw OverlayWireError.oversized
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw OverlayWireError.malformed
        }
        try value.validate()
        guard try value.canonicalJSON() == data else {
            throw OverlayWireError.nonCanonical
        }
        return value
    }
}

/// Announces one complete transaction Volume. The exact authenticated
/// advertiser is the first retrieval target; validity still comes from
/// content addressing and Lattice preflight.
package struct TransactionAvailableMessage: CanonicalJSONMessage, Equatable, Sendable {
    package let volumeRootCID: String

    package init(volumeRootCID: String) {
        self.volumeRootCID = volumeRootCID
    }

    package func validate() throws {
        guard _isBoundedWireAtom(volumeRootCID) else {
            throw OverlayWireError.malformed
        }
    }
}
