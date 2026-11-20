import Ivy
import Lattice
import LatticeNodeCore
import cashew

extension NodeRuntime {
    /// The transactions peers announce, fetched from the peer that
    /// announced them: each fetch in flight and those fetched recently.
    /// Only the loop touches it.
    struct TransactionFetches: Sendable {
        let ivy: Ivy
        let inputs: Inputs
        /// Announced transactions being fetched, by CID.
        var fetching: Set<String> = []
        /// Transactions recently fetched, not refetched until a hosted chain's
        /// act-on tip moves (Bitcoin's recent rejects): a refused one is not fetched
        /// again in a loop. Bounded, oldest out.
        var recentlyFetched = RecentSet(capacity: 4_096)
        var recentlyFetchedTips: [String] = []

        /// A bounded set, oldest out.
        struct RecentSet {
            let capacity: Int
            private(set) var members: Set<String> = []
            private var order: [String] = []

            init(capacity: Int) { self.capacity = capacity }

            mutating func insert(_ cid: String) {
                guard members.insert(cid).inserted else { return }
                order.append(cid)
                if order.count > capacity { members.remove(order.removeFirst()) }
            }

            mutating func removeAll() {
                members.removeAll()
                order.removeAll()
            }
        }

        init(ivy: Ivy, inputs: Inputs) {
            self.ivy = ivy
            self.inputs = inputs
        }

        /// An announced transaction's fetch ended.
        mutating func fetched(_ cid: String) {
            fetching.remove(cid)
            recentlyFetched.insert(cid)
        }

        /// A peer announced a transaction: fetch it from that peer, and hand
        /// it, as the peer's, to the pool of the chain it names. An
        /// announcement carries only the transaction's CID, so its chain is
        /// known once it is fetched: every hosted level is asked whether it
        /// already holds it, and one naming a chain this host does not run is
        /// dropped. Only one not pooled, not awaiting its verdict, not being
        /// fetched and not recently fetched, within the cap on concurrent
        /// fetches; anything else is dropped, never blamed.
        mutating func fetch(
            _ cid: String, from peer: AuthenticatedPeer, as id: LatticeNodeCore.PeerID,
            levels: [ChainPath: ChainCore]
        ) {
            // No hosted level would take it yet (`ChainCore.synced`).
            guard levels.values.contains(where: \.synced) else { return }
            let pools = levels.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value.mining)
            // A fetched transaction may be worth fetching again once any
            // hosted chain moves: a child's tip moves without the root's.
            let tips = pools.map(\.tipCID)
            if recentlyFetchedTips != tips {
                recentlyFetchedTips = tips
                recentlyFetched.removeAll()
            }
            guard !pools.contains(where: { $0.mempool.contains(cid) || $0.isPending(cid) }),
                  !fetching.contains(cid), !recentlyFetched.members.contains(cid),
                  fetching.count < 64
            else { return }
            fetching.insert(cid)
            let (ivy, inputs) = (ivy, inputs)
            let hosted = Set(levels.keys)
            NodeRuntime.spawn {
                let response = await ivy.fetchVolume(rootCID: cid, from: peer)
                let transaction = try? await VolumeImpl<Transaction>(rawCID: cid, node: nil, encryptionInfo: nil)
                    .resolveRecursive(source: InMemoryContentSource(response.entries)).node
                // A transaction names its chain: it goes to that level's pool.
                let path = transaction?.body.node?.chainPath
                inputs.yield(.transactionFetched(cid: cid, transaction.flatMap { transaction in
                    path.flatMap { hosted.contains($0) ? .level($0, .mining(.transactionReceived(transaction, origin: .peer(id)))) : nil }
                }))
            }
        }
    }
}
