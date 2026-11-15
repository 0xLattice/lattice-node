import Foundation
import Lattice

/// `POST /chains`: a child chain to create, once: its spec and, to mine its
/// genesis, the premine's recipient, the signed transactions the genesis
/// carries (each what `POST /transactions` takes) and the WASM modules the
/// spec names (base64). The node keeps these under its `specs/` directory;
/// hosting the path (its `hostedChains`) then mines the chain from them.
public struct HostedChain: Codable, Sendable {
    public let path: String
    public var spec: ChainSpec?
    public var premineTo: String?
    public var genesisTransactions: [SubmitTransactionRequest]?
    public var policyModules: [Data]?

    public init(
        path: String, spec: ChainSpec? = nil, premineTo: String? = nil,
        genesisTransactions: [SubmitTransactionRequest]? = nil, policyModules: [Data]? = nil
    ) {
        self.path = path
        self.spec = spec
        self.premineTo = premineTo
        self.genesisTransactions = genesisTransactions
        self.policyModules = policyModules
    }
}
