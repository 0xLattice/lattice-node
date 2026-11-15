import Foundation
import Lattice

/// A `hostedChains` entry of the node's configuration (lattice.json or a
/// fragment of config.d) that creates the chain: its spec and, to mine its
/// genesis, the premine's recipient, the signed transactions the genesis
/// carries (each what `POST /transactions` takes) and the WASM modules the
/// spec names (base64). The node keeps these under its `specs/` directory,
/// as `lattice child create` keeps them; an entry with a path alone is a
/// chain synced from its peers.
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
