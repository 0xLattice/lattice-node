import Foundation
import Lattice
import UInt256
import cashew

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

    /// Policies may read the carrying block's height and timestamp, which a
    /// pool verdict (taken against the tip, at its own time) did not see. Offer
    /// only transactions the policies accept for THIS template; a skipped one
    /// stays pooled until it passes or a tip change evicts it.
    static func policyAcceptedTransactions(
        _ transactions: [Transaction],
        chainPath: [String],
        previous: Block,
        timestamp: Int64,
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async -> [Transaction] {
        guard !spec.wasmPolicies.isEmpty else { return transactions }
        let (height, overflow) = previous.height.addingReportingOverflow(1)
        guard !overflow else { return [] }
        var accepted: [Transaction] = []
        for transaction in transactions {
            guard let body = try? await transaction.body.resolve(fetcher: fetcher).node,
                  (try? await TransactionBody.batchVerifyPolicies(
                      bodies: [body],
                      spec: spec,
                      chainPath: chainPath,
                      height: height,
                      timestamp: timestamp,
                      fetcher: fetcher
                  )) == true else { continue }
            accepted.append(transaction)
        }
        return accepted
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
