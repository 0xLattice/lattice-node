import Crypto
import Foundation
import Ivy
import Lattice
import LatticeNodeCore
import cashew
import UInt256
import VolumeBroker
import LatticeNodeAPI
import LatticeNodeStore

extension NodeRuntime {
    // MARK: - Jobs

    /// A block's transactions with their bodies resolved (the pool takes
    /// resolved content only); none when its body is not held.
    static func transactions(ofBlock cid: String, fetcher: any Fetcher) async -> [Transaction] {
        guard let block = try? await BlockHeader(rawCID: cid).resolve(fetcher: fetcher).node,
              let carried = try? await block.orderedTransactions(fetcher: fetcher)
        else { return [] }
        var resolved: [Transaction] = []
        for transaction in carried {
            guard let body = try? await transaction.body.resolve(fetcher: fetcher), body.node != nil else { continue }
            resolved.append(Transaction(signatures: transaction.signatures, body: body))
        }
        return resolved
    }

    /// The transactions of a block the chain left, which are this node's
    /// to return to its pool: from this store, and when it let go of the
    /// body, from peers, the block's own Volume first (its header record
    /// names the transactions and does not hold them).
    static func transactions(
        ofLeftBlock cid: String, at path: ChainPath, storage: NodeStorage, remote: IvyRootContentSource?
    ) async -> [Transaction] {
        guard let remote, await !storage.stores.reads(.chain(path)).hasVolume(root: cid) else {
            return await transactions(ofBlock: cid, fetcher: storage.localFetcher(.chain(path)))
        }
        let hosts = ChainHosts.of(path, nexusGenesisCID: storage.configuration.nexusGenesisCID)
        return await remote.withRootTracing(cid, bundle: false, hosts: hosts) { session in
            await transactions(ofBlock: cid, fetcher: CoalescingFetcher(CompositeContentSource([storage.stores.reads(.chain(path)), session])))
        }.value
    }

    static func transactionIDs(ofBlock cid: String, fetcher: any Fetcher) async -> [String] {
        await transactions(ofBlock: cid, fetcher: fetcher).compactMap { try? Mempool.cid(of: $0) }
    }

    /// How a connect job stores the blocks it found valid
    /// (`NodeStorage.storeValidBlocks`); a test's stands in to fail it.
    typealias StoreValidBlocks = @Sendable (
        NodeStorage, [(cid: String, decoded: Block?)], ChainPath, any Fetcher
    ) async throws -> [String: [String]]

    /// A level's connect job (`ChainEffect.connect`): its blocks executed in
    /// order (`ConnectRun`), each reading the state the previous one
    /// produced from memory, then the bodies of the valid ones stored in one
    /// transaction (`storeValidBlocks`), and for each valid block the IDs of
    /// the transactions it carries, read from the body it executed (the
    /// index storing it walked, or when the index names a transaction by a
    /// non-standard CID, the body). A valid block whose body could not be
    /// read to store it is reported not stored and ends the job: it is not
    /// connected (durable before visible). The store's write failing is a
    /// local fault, not a body unavailable: `failStop` (Bitcoin's
    /// `AbortNode`), and nothing of the job is reported. The verdicts come
    /// back as one event: the step that applies them commits them once.
    /// Execution is the node's own work: what this store lacks is read from
    /// peers. A child level's parent fact is read from the live parent level
    /// (`ParentContinuity`).
    static func connectJob(
        _ jobs: [ConnectJob],
        at path: ChainPath,
        levels: LiveLevels,
        storage: NodeStorage,
        remote: IvyRootContentSource? = nil,
        failStop: @escaping @Sendable (any Error) -> Void,
        store: @escaping StoreValidBlocks = { try await $0.storeValidBlocks($1, at: $2, from: $3) }
    ) -> RuntimeJob {
        RuntimeJob(path: path, tipCID: nil, kind: .connect) {
            guard let first = jobs.first else { return [] }
            return await reading(first.blockHash, at: path, storage: storage, remote: remote) { fetcher in
                let (verdicts, reads) = await ConnectRun.run(
                    jobs,
                    fetcher: fetcher,
                    parentFacts: ParentContinuity(levels: levels),
                    validationContext: { ValidationContext(nowMilliseconds: now()) }
                )
                let valid = verdicts.filter(\.isValid).map { (cid: $0.blockHash, decoded: $0.connectedBlock) }
                var carried: [String: [String]] = [:]
                if !valid.isEmpty {
                    do {
                        carried = try await store(storage, valid, path, reads)
                    } catch is VolumeStores.NotHosted {
                        // The level is gone: nothing to store, no one to tell.
                        return []
                    } catch {
                        failStop(error)
                        return []
                    }
                }
                var results: [ConnectResult] = []
                for verdict in verdicts {
                    guard verdict.isValid else {
                        results.append(ConnectResult(verdict))
                        continue
                    }
                    // Durable before visible: a valid block whose body was
                    // not stored is not connected, and the job ends at it.
                    guard let held = carried[verdict.blockHash] else {
                        results.append(ConnectResult(verdict, stored: false))
                        break
                    }
                    // The pool knows a transaction by its standard CID; an
                    // index entry may name it by another form of the same bytes.
                    let transactions = if held.allSatisfy(CIDIdentity.isStandard) {
                        held
                    } else {
                        await transactionIDs(ofBlock: verdict.blockHash, fetcher: reads)
                    }
                    results.append(ConnectResult(verdict, transactions: transactions))
                }
                return [.level(path, .connected(results))]
            }
        }
    }

    /// `ChainEffect.readTransactions`: each block's transaction IDs.
    static func readJob(_ blocks: [String], at path: ChainPath, storage: NodeStorage) -> RuntimeJob {
        let fetcher = storage.localFetcher(.chain(path))
        return RuntimeJob(path: path, tipCID: nil) {
            var read: [String: [String]] = [:]
            for cid in blocks { read[cid] = await transactionIDs(ofBlock: cid, fetcher: fetcher) }
            return [.level(path, .transactionsRead(read))]
        }
    }

    /// The operator's own work reads content the one way: what this store
    /// holds, then a block's header record, then what is in memory (a body
    /// fetched for its connect, what earlier reads asked of peers), then
    /// peers, each answer checked against its CID by the reader. What the
    /// read asked of peers is kept in memory, never written to the store:
    /// only the node's own storing of a block does that.
    /// Without an overlay (`remote` nil) the read is from this store.
    static func reading<T: Sendable>(
        _ rootCID: String,
        at path: ChainPath,
        below: Bool = false,
        storage: NodeStorage,
        remote: IvyRootContentSource?,
        _ work: @Sendable (any Fetcher) async -> T
    ) async -> T {
        guard let remote else { return await work(storage.workFetcher(below ? .subtree(path) : .chain(path))) }
        // A child chain's content is asked first of the chain's own hosts,
        // as its bodies are; Nexus's of any peer.
        let hosts = ChainHosts.of(path, nexusGenesisCID: storage.configuration.nexusGenesisCID)
        return await remote.withRootTracing(rootCID, bundle: false, hosts: hosts) { session in
            // Peers serve whole Volumes by their roots. A block's own Volume
            // this store does not hold is read whole first, so what it lists
            // is read from it, not asked of peers one entry at a time.
            // One this node derived fetching the block's body is read from
            // memory, as is all of that body.
            if await !storage.stores.reads(below ? .subtree(path) : .chain(path)).hasVolume(root: rootCID),
               await storage.readCache.volume(rootCID) == nil {
                _ = await session.volume(rootCID: rootCID)
            }
            return await work(storage.ownReads(through: session, below ? .subtree(path) : .chain(path)))
        }.value
    }

}
