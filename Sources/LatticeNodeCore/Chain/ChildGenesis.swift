import Foundation
import Lattice
import cashew

/// The rules a child chain's genesis is checked against before the chain is
/// created or its host starts: node policy, decided without I/O.
public enum ChildGenesis {
    /// The genesis transaction paying `spec`'s premine to `recipient`, as
    /// Nexus's genesis pays its own: one unsigned credit, which genesis
    /// validation bounds by the premine. None without a recipient or a
    /// premine. Throws for a premine an account action cannot carry or a
    /// recipient that is not an address, which no genesis could pay.
    public static func premine(spec: ChainSpec, to recipient: String?, on chainPath: ChainPath) throws -> [Transaction] {
        let amount = spec.premineAmount()
        guard let recipient, amount > 0 else { return [] }
        guard CryptoUtils.isValidAddress(recipient) else { throw PremineError("\(recipient) is not an address") }
        guard let delta = Int64(exactly: amount) else { throw PremineError("a premine of \(amount) is more than one account action carries") }
        let body = TransactionBody(
            accountActions: [AccountAction(owner: recipient, delta: delta)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 0, chainPath: chainPath
        )
        return [Transaction(signatures: [:], body: try HeaderImpl(node: body))]
    }

    /// Whether a genesis paying `recipient` and carrying `transactions` could
    /// be valid, checked before a chain is created or its host starts: the
    /// premine transaction and the creator's, and every transaction policy of
    /// the spec run on each with the module bytes in hand (`modules`). A
    /// genesis a policy refuses would be mined and refused, and the chain
    /// would never start.
    ///
    /// Genesis validation does not check signatures, so this does: a genesis
    /// carries only transactions their signers signed, which anyone can check
    /// against the block. Each is on `chainPath`, with no coin, deposit,
    /// receipt or withdrawal actions: a genesis pays only its premine.
    /// Policies run as of `timestamp` (milliseconds), the caller's clock.
    public static func checkPremine(
        spec: ChainSpec, to recipient: String?, transactions: [Transaction] = [],
        on chainPath: ChainPath, modules: [Data], timestamp: Int64
    ) throws {
        for (index, transaction) in transactions.enumerated() {
            guard let body = transaction.body.node else {
                throw PremineError("genesis transaction \(index) carries no body")
            }
            guard body.chainPath == chainPath else {
                throw PremineError("genesis transaction \(index) is for \(body.chainPath.joined(separator: "/")), not \(chainPath.joined(separator: "/"))")
            }
            guard transaction.signaturesAreValid(), transaction.signaturesMatchSigners() else {
                throw PremineError("genesis transaction \(index) is not signed by exactly its signers")
            }
            guard body.accountActions.isEmpty, body.depositActions.isEmpty,
                  body.receiptActions.isEmpty, body.withdrawalActions.isEmpty else {
                throw PremineError("genesis transaction \(index) moves coins; a genesis pays only its premine")
            }
        }
        let all = try premine(spec: spec, to: recipient, on: chainPath) + transactions
        guard UInt64(all.count) <= spec.maxNumberOfTransactionsPerBlock else {
            throw PremineError("a genesis of \(all.count) transactions is more than the spec's \(spec.maxNumberOfTransactionsPerBlock) per block")
        }
        let bodies = all.compactMap(\.body.node)
        let byCID = Dictionary(try modules.map {
            (try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: $0)).rawCID, $0)
        }) { first, _ in first }
        for policy in spec.wasmPolicies where policy.scope == .transaction {
            guard let bytes = byCID[policy.moduleCID] else { throw PremineError("no module for policy \(policy.moduleCID)") }
            for body in bodies {
                let context = WasmPolicyContext(
                    scope: .transaction, height: 0, timestamp: timestamp,
                    chainSpec: spec, chainPath: chainPath, transaction: body, action: nil, actionIndex: nil
                )
                guard try WasmPolicyEvaluator.evaluate(
                    policy: policy, contextData: context.canonicalData(), moduleBytes: bytes
                ) else {
                    throw PremineError(body.signers.isEmpty
                        ? "policy \(policy.moduleCID) refuses the genesis paying the premine to \(recipient ?? "")"
                        : "policy \(policy.moduleCID) refuses the genesis transaction signed by \(body.signers.joined(separator: ", "))")
                }
            }
        }
    }

    public struct PremineError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
