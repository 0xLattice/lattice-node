import Foundation
import Lattice
import cashew

public enum ChainServiceLimits {
    /// Fits beneath the HTTP upload ceiling and leaves hierarchy-frame room for
    /// the provisional parent carrier and framing.
    public static let maximumPayloadBytes = 1 << 20

    /// A child intent may carry one consensus-sized genesis block and every
    /// immutable policy module named by its spec. The daemon applies this cap
    /// while collecting the request body, before JSON decoding.
    public static let maximumChildIntentPayloadBytes = 64 << 20
}

public enum ContentBoundWasmPolicyModuleError: Error, Equatable, Sendable {
    case moduleCIDMismatch
}

/// The complete one-Volume representation of a WASM policy module.
///
/// Carrying the bytes with their root keeps child deployment content-bound and
/// avoids creating an ambient CID upload namespace.
public struct ContentBoundWasmPolicyModule: Codable, Sendable {
    public let rootCID: String
    public let bytes: Data

    public init(bytes: Data) throws {
        let header = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: bytes)
        )
        self.rootCID = header.rawCID
        self.bytes = bytes
    }

    public init(rootCID: String, bytes: Data) throws {
        let expected = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: bytes)
        ).rawCID
        guard rootCID == expected else {
            throw ContentBoundWasmPolicyModuleError.moduleCIDMismatch
        }
        self.rootCID = rootCID
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey {
        case rootCID
        case bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootCID: container.decode(String.self, forKey: .rootCID),
            bytes: container.decode(Data.self, forKey: .bytes)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootCID, forKey: .rootCID)
        try container.encode(bytes, forKey: .bytes)
    }

    func header() throws -> WasmPolicyModuleHeader {
        let header = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: bytes)
        )
        guard header.rawCID == rootCID else {
            throw ContentBoundWasmPolicyModuleError.moduleCIDMismatch
        }
        return header
    }
}

public enum ContentBoundTransactionError: Error, Equatable, Sendable {
    case unresolvedBody
    case bodyCIDMismatch
}

/// JSON-safe transaction payload. Cashew headers encode references only, so an
/// RPC request must carry the concrete body alongside its signatures.
public struct ContentBoundTransaction: Codable, Sendable {
    public let signatures: [String: String]
    public let body: TransactionBody

    public init(transaction: Transaction) throws {
        guard let body = transaction.body.node else {
            throw ContentBoundTransactionError.unresolvedBody
        }
        let header = try HeaderImpl(node: body)
        guard header.rawCID == transaction.body.rawCID else {
            throw ContentBoundTransactionError.bodyCIDMismatch
        }
        self.signatures = transaction.signatures
        self.body = body
    }

    public init(signatures: [String: String], body: TransactionBody) {
        self.signatures = signatures
        self.body = body
    }

    public func transaction() throws -> Transaction {
        Transaction(signatures: signatures, body: try HeaderImpl(node: body))
    }
}
