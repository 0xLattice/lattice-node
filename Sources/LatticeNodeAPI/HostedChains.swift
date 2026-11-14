import Foundation
import Lattice

/// One hosted child chain inline: its path and, to mine its genesis, the
/// spec, the premine's recipient, the signed transactions the genesis
/// carries (each what `POST /transactions` takes) and the WASM modules the
/// spec names (base64): what `--host-chain path=spec.json`, `--premine-to`,
/// `--genesis-transactions` and `--policy-module` give from files.
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

/// The child chains a node hosts, inline, as it keeps them: what the last
/// accepted `POST /hosted-chains` set, saved in its data directory
/// (`hosted-chains.json`) and returned by `GET /hosted-chains` as `saved`.
/// It is itself a `POST /hosted-chains` body, so a client changes it by
/// reading it, changing it and posting it back.
public struct SavedHostedChains: Codable, Sendable {
    public var chains: [HostedChain]
    /// `--chain-peer` seeds: chain-path=public-key@host:port.
    public var chainPeer: [String]?

    public init(chains: [HostedChain], chainPeer: [String]? = nil) {
        self.chains = chains
        self.chainPeer = chainPeer
    }

    /// These chains with `chain` and its seeds added after them, the others
    /// unchanged; nil when `chain` is already listed.
    public func adding(_ chain: HostedChain, peers: [String] = []) -> SavedHostedChains? {
        guard !chains.contains(where: { $0.path == chain.path }) else { return nil }
        var next = self
        next.chains.append(chain)
        if !peers.isEmpty { next.chainPeer = (chainPeer ?? []) + peers }
        return next
    }
}
