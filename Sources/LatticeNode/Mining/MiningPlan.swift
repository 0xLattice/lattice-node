import Foundation
import Lattice
import UInt256
import LatticeNodeCore
import cashew
import LatticeNodeAPI

/// The miner-facing plan and template checks the node runtime's RPC applies.
enum MiningPlan {
    struct ValidatedRecipientPlan {
        let current: String?
        let descendants: [MiningRecipient]
    }

    private static let maximumMiningPlanBytes = NodeAPILimits.maximumPayloadBytes

    /// A miner's recipients by chain path: this chain's, which its template
    /// commits, and the descendants', which travel with the child candidate
    /// requests. Each is a canonical address on a chain at or below this one,
    /// at most one per chain.
    static func validatedRecipientPlan(
        _ recipients: [MiningRecipient],
        chainPath currentPath: [String]
    ) throws -> ValidatedRecipientPlan {
        guard let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(recipients: recipients)
              ),
              encoded.count <= maximumMiningPlanBytes else {
            throw NodeAPIError.invalidRecipientPlan
        }
        var seen: Set<String> = []
        var current: String?
        var descendants: [MiningRecipient] = []
        for recipient in recipients {
            guard let address = ChainAddress(recipient.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  CryptoUtils.isValidAddress(recipient.address) else {
                throw NodeAPIError.invalidRecipientPlan
            }
            if address.components == currentPath {
                current = recipient.address
            } else {
                descendants.append(MiningRecipient(
                    chainPath: address.components,
                    address: recipient.address
                ))
            }
        }
        return ValidatedRecipientPlan(
            current: current,
            descendants: descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    /// A miner's minimum-work entries by chain path — this chain's and its
    /// descendants', which bound the template's search — and the descendants'
    /// alone, which travel with the child candidate requests.
    static func validatedMinimumWorkPlan(
        _ entries: [MiningMinimumWork],
        chainPath currentPath: [String]
    ) throws -> (works: [[String]: UInt256], descendants: [MiningMinimumWork]) {
        // The same payload cap the recipient plan honours. Bounding it here means
        // an oversized plan is a named refusal to the miner that sent it,
        // rather than a descendant request that silently fails to encode and
        // leaves that child with no candidate for the round.
        guard let encoded = try? JSONEncoder().encode(
                  MiningTemplateRequest(minimumWork: entries)
              ),
              encoded.count <= maximumMiningPlanBytes else {
            throw NodeAPIError.minimumWorkPlanTooLarge
        }
        var seen: Set<String> = []
        var works: [[String]: UInt256] = [:]
        var descendants: [MiningMinimumWork] = []
        for entry in entries {
            guard let address = ChainAddress(entry.chainPath),
                  address.components.count >= currentPath.count,
                  Array(address.components.prefix(currentPath.count))
                    == currentPath,
                  seen.insert(address.key).inserted,
                  entry.work > .zero,
                  entry.work <= maximumRepresentableWork else {
                throw NodeAPIError.invalidMinimumWork
            }
            works[address.components] = entry.work
            if address.components != currentPath {
                descendants.append(entry)
            }
        }
        return (
            works,
            descendants.sorted {
                $0.chainPath.lexicographicallyPrecedes($1.chainPath)
            }
        )
    }

    /// A miner's excluded chains: each a distinct chain below this one. A
    /// block carries its descendants, so excluding a chain while a hosted
    /// chain below it is left in is refused rather than silently dropping
    /// that chain too. A chain not hosted here is carried by no template;
    /// excluding it changes nothing.
    static func validatedExclusions(
        _ paths: [[String]],
        chainPath currentPath: [String],
        hosted: [[String]]
    ) throws -> Set<[String]> {
        var excluded: Set<[String]> = []
        for path in paths {
            guard ChainAddress(path) != nil,
                  path.count > currentPath.count,
                  Array(path.prefix(currentPath.count)) == currentPath,
                  excluded.insert(path).inserted else {
                throw NodeAPIError.invalidExclusion
            }
        }
        for chain in hosted where !excluded.contains(chain) {
            for depth in currentPath.count..<chain.count
            where excluded.contains(Array(chain.prefix(depth))) {
                throw NodeAPIError.excludedAncestor
            }
        }
        return excluded
    }

    /// Policies may read the carrying block's height and timestamp, which a
    /// pool verdict (taken against the tip, at its own time) did not see. Offer
    /// only transactions the policies accept for THIS template. Root and child
    /// templates alike: the pool's own verdicts are not taken at this height.
    /// `refused` names those the policies did not accept, for the pool to
    /// drop: a refusal, or an error Lattice classifies as invalid (a trap), as
    /// admission does. One this node could not judge (a body or module it
    /// lacks, a failed fetch) is neither carried nor dropped. `transactions` is what the next block can carry
    /// (`Mempool.nextBlock`), so policies run on one block's worth, never the
    /// whole pool.
    static func policyAcceptedTransactions(
        _ transactions: [Transaction],
        chainPath: [String],
        previous: Block,
        timestamp: Int64,
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async -> (accepted: [Transaction], refused: [String]) {
        guard !spec.wasmPolicies.isEmpty else { return (transactions, []) }
        let (height, overflow) = previous.height.addingReportingOverflow(1)
        guard !overflow else { return ([], []) }
        var accepted: [Transaction] = []
        var refused: [String] = []
        for transaction in transactions {
            guard let body = try? await transaction.body.resolve(fetcher: fetcher).node else { continue }
            let verdict: Bool
            do {
                verdict = try await TransactionBody.batchVerifyPolicies(
                    bodies: [body],
                    spec: spec,
                    chainPath: chainPath,
                    height: height,
                    timestamp: timestamp,
                    fetcher: fetcher
                )
            } catch {
                guard wasmPolicyErrorVerdict(error) == .invalid else { continue }
                verdict = false
            }
            if verdict {
                accepted.append(transaction)
            } else if let cid = try? Mempool.cid(of: transaction) {
                refused.append(cid)
            }
        }
        return (accepted, refused)
    }

    static func nextTimestamp(
        after previous: Int64,
        parentCarrier: Block?
    ) throws -> Int64 {
        let (minimum, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else { throw NodeAPIError.timestampOverflow }
        if let parentCarrier { return max(minimum, parentCarrier.timestamp) }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return max(minimum, now)
    }

}
