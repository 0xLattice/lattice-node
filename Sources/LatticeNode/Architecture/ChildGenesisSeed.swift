import Foundation
import Lattice
import UInt256
import cashew

/// The inputs a deployer commits to when anchoring a self-contained child
/// genesis. Both sides must agree on these byte-for-byte: the deployer builds
/// the genesis to compute the CID it records on the parent (a GenesisAction),
/// and the child node rebuilds the identical genesis to self-admit it on
/// startup. Determinism (same spec + premine + timestamp + max target) makes the
/// two builds produce the same CID without shipping the genesis DAG closure.
public struct ChildGenesisSeed: Codable, Sendable {
    public let spec: ChainSpec
    public let premineTo: String?
    public let timestamp: Int64

    public init(spec: ChainSpec, premineTo: String?, timestamp: Int64) {
        self.spec = spec
        self.premineTo = premineTo
        self.timestamp = timestamp
    }
}

public enum ChildGenesisBuilder {
    /// Deterministically builds the self-contained child genesis (empty
    /// parentState, like a root genesis) that the parent only RECORDS by CID and
    /// the child node self-admits. The genesis target is `UInt256.max`: a
    /// self-contained genesis satisfies its own trivial PoW, exactly like a root
    /// genesis. The optional premine is an unsigned genesis account credit.
    public static func build(
        seed: ChildGenesisSeed,
        chainPath: [String],
        fetcher: any Fetcher
    ) async throws -> Block {
        var transactions: [Transaction] = []
        if let premineTo = seed.premineTo {
            let body = TransactionBody(
                accountActions: [AccountAction(
                    owner: premineTo,
                    delta: Int64(seed.spec.premineAmount())
                )],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0,
                chainPath: chainPath
            )
            transactions.append(Transaction(
                signatures: [:],
                body: try HeaderImpl(node: body)
            ))
        }
        return try await BlockBuilder.buildGenesis(
            spec: seed.spec,
            transactions: transactions,
            timestamp: seed.timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
    }
}
