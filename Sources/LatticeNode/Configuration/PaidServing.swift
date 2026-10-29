import Lattice

/// What a reader pays this node for serving priority (operator choice, off
/// by default). A payment buys bytes of prepaid balance, which only counts
/// when serving is contended: a request that gets a free slot at once is
/// served and never charged.
///
/// Encoded as `GET /serving-terms` answers it.
public struct PaidServing: Sendable, Equatable, Encodable {
    /// The account readers pay. Nil: no payment is accepted.
    public let payTo: String?
    /// Bytes one coin unit buys, by the chain whose coin it is; the unit is
    /// the one the chain's balances count in.
    public let rates: [[String]: Int]
    /// Blocks built on the block that carried a payment before it is
    /// credited.
    public let depth: UInt64
    /// Where readers can earn balance by work instead (the operator's
    /// sponsor). Advertised only.
    public let workURL: String?

    /// Six blocks on top: the customary depth at which a reorganization
    /// taking a payment back is no longer a practical worry.
    public static let defaultDepth: UInt64 = 6

    public init(
        payTo: String? = nil, rates: [[String]: Int] = [:], depth: UInt64 = defaultDepth, workURL: String? = nil
    ) throws {
        if let payTo, !CryptoUtils.isValidAddress(payTo) { throw PaidServingError.invalidPayTo }
        guard payTo != nil || rates.isEmpty else { throw PaidServingError.ratesWithoutPayTo }
        for (chain, bytesPerCoin) in rates {
            guard ChainAddress(chain) != nil else { throw NodeConfigurationError.invalidChainPath }
            guard bytesPerCoin > 0 else { throw PaidServingError.invalidRate }
        }
        if let workURL, !NodeConfiguration.isValidPublicReadURL(workURL) { throw PaidServingError.invalidWorkURL }
        self.payTo = payTo
        self.rates = rates
        self.depth = depth
        self.workURL = workURL
    }

    private enum CodingKeys: String, CodingKey { case payTo, rates, depth, workURL }
    private struct Rate: Encodable { let bytesPerCoin: Int }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Absent settings are null, not missing.
        try container.encode(payTo, forKey: .payTo)
        try container.encode(
            Dictionary(uniqueKeysWithValues: rates.map { ($0.key.joined(separator: "/"), Rate(bytesPerCoin: $0.value)) }),
            forKey: .rates
        )
        try container.encode(depth, forKey: .depth)
        try container.encode(workURL, forKey: .workURL)
    }
}

public enum PaidServingError: Error, Equatable, CustomStringConvertible {
    case invalidPayTo
    case ratesWithoutPayTo
    case invalidRate
    case invalidWorkURL

    public var description: String {
        switch self {
        case .invalidPayTo: "--serving-pay-to must be an account address"
        case .ratesWithoutPayTo: "--serving-rate requires --serving-pay-to"
        case .invalidRate: "--serving-rate takes chain-path=bytesPerCoin, bytesPerCoin at least 1"
        case .invalidWorkURL: "--serving-work-url must be an absolute http(s) URL with a host and no credentials, query or fragment"
        }
    }
}
