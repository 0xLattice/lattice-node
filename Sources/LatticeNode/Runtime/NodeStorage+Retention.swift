import Foundation
import Lattice
import LatticeNodeCore
import VolumeBroker
import cashew

/// One hosted chain as a collection sees it.
struct ChainRetentionView: Sendable {
    let path: ChainPath
    /// The act-on chain by height.
    let chain: HeightIndex
    /// Blocks whose bodies stay whatever the budget.
    let held: Set<String>
}

/// Storing content and then retaining it is two steps, and a release between
/// them would remove what was stored. Every store-then-retain holds this
/// gate; a release takes it alone.
actor ContentGate {
    private var holders = 0
    private var releasing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        while releasing { await wait() }
        holders += 1
    }

    func leave() {
        holders -= 1
        wake()
    }

    func beginRelease() async {
        while releasing { await wait() }
        releasing = true
        while holders > 0 { await wait() }
    }

    func endRelease() {
        releasing = false
        wake()
    }

    private func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wake() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

/// The executed blocks whose bodies this store holds, and what keeps each
/// root: a body is a block's own Volume and its transactions', and a
/// transaction two held blocks carry is released with the second.
struct BodyLedger {
    struct Body {
        let path: ChainPath
        let roots: [String]
        let bytes: Int
    }

    /// The bodies counted against one chain's budget: its act-on chain from
    /// height `low` up to `tip` at `high`.
    struct Range {
        var tip = ""
        var low = 1
        var high = 0
        var bytes = 0
        var cids: Set<String> = []
    }

    var bodies: [String: Body] = [:]
    var references: [String: Int] = [:]
    var ranges: [ChainPath: Range] = [:]
    /// Bodies outside their chain's range that something still held.
    var deferred: Set<String> = []

    mutating func add(_ cid: String, _ body: Body) {
        guard bodies[cid] == nil else { return }
        bodies[cid] = body
        for root in body.roots { references[root, default: 0] += 1 }
    }

    /// Forgets a body; returns the roots no held body names any more.
    mutating func remove(_ cid: String) -> [String] {
        guard let body = bodies.removeValue(forKey: cid) else { return [] }
        deferred.remove(cid)
        return body.roots.filter { root in
            let count = (references[root] ?? 1) - 1
            references[root] = count > 0 ? count : nil
            return count <= 0
        }
    }
}

extension NodeStorage {
    /// Runs a store-then-retain so that no release runs between the two.
    nonisolated func holdingContent<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await contentGate.enter()
        do {
            let value = try await body()
            await contentGate.leave()
            return value
        } catch {
            await contentGate.leave()
            throw error
        }
    }

    /// A body stored and retained for a block whose execution is not
    /// journaled yet: its roots are released for no other block's sake.
    func notePending(_ cid: String, roots: [String]) {
        pendingBodies[cid] = roots
    }

    /// Bodies a job is about to read stay until it has.
    func holdBodies(_ cids: [String]) {
        for cid in cids { reading[cid, default: 0] += 1 }
    }

    func unholdBodies(_ cids: [String]) {
        for cid in cids {
            let count = (reading[cid] ?? 1) - 1
            reading[cid] = count > 0 ? count : nil
        }
    }

    /// Reads which executed blocks' bodies this store holds. Until it has,
    /// nothing is released: a root's holders are not all known.
    func loadBodies(hosting paths: [ChainPath]) async {
        guard configuration.retainBlockBytes != nil, !ledgerLoaded else { return }
        for path in paths {
            guard let executed = try? await store.executedBlockCIDs(at: path) else { continue }
            for cid in executed where ledger.bodies[cid] == nil {
                if let body = await blockBody(cid, at: path) { ledger.add(cid, body) }
            }
        }
        ledgerLoaded = true
    }

    /// Keeps each hosted chain's bodies within the operator's budget, after
    /// the step that executed `executed`. Awaited by the node loop between
    /// steps, so the chains it is given are the chains as they stand.
    ///
    /// Per chain the newest bodies on the act-on chain stay while they fit,
    /// the tip's always; the body of every other executed block goes, a
    /// losing fork's among them. Held blocks stay. The Nexus genesis is
    /// never counted or released. Facts and headers stay, so nothing here
    /// changes what the node weighs or selects.
    func collect(_ chains: [ChainRetentionView], executed: [(path: ChainPath, cid: String)]) async {
        guard let budget = configuration.retainBlockBytes else { return }
        for (path, cid) in executed {
            pendingBodies[cid] = nil
            if let body = await blockBody(cid, at: path) { ledger.add(cid, body) }
        }
        guard ledgerLoaded else { return }

        var leaving: [String] = []
        for chain in chains {
            let held = chain.held.union(reading.keys)
            let top = chain.chain.count - 1
            guard top >= 1, let tip = chain.chain[top] else { continue }
            let bytes = { (cid: String) in self.ledger.bodies[cid]?.bytes ?? 0 }
            var range = ledger.ranges[chain.path] ?? BodyLedger.Range()
            if range.high >= 1, range.high <= top, chain.chain[range.high] == range.tip {
                // The chain grew from the tip this range ended at.
                for height in stride(from: range.high + 1, through: top, by: 1) {
                    guard let cid = chain.chain[height] else { continue }
                    range.cids.insert(cid)
                    range.bytes += bytes(cid)
                }
            } else {
                // Another branch: count again from its tip down. The tip
                // stays whatever its size.
                range = BodyLedger.Range(low: top, high: top, bytes: bytes(tip), cids: [tip])
                while range.low > 1, let cid = chain.chain[range.low - 1], range.bytes + bytes(cid) <= budget {
                    range.cids.insert(cid)
                    range.bytes += bytes(cid)
                    range.low -= 1
                }
                leaving.append(contentsOf: ledger.bodies.filter { $0.value.path == chain.path }.keys)
            }
            range.tip = tip
            range.high = top
            while range.bytes > budget, range.low < top, let cid = chain.chain[range.low] {
                range.cids.remove(cid)
                range.bytes -= bytes(cid)
                range.low += 1
                leaving.append(cid)
            }
            ledger.ranges[chain.path] = range
            // A block executed off the act-on chain was never in the range.
            leaving.append(contentsOf: executed.filter { $0.path == chain.path }.map(\.cid))
            leaving.append(contentsOf: ledger.deferred.filter { ledger.bodies[$0]?.path == chain.path })
            let genesis = chain.chain[0]
            leaving.removeAll { cid in
                guard let body = ledger.bodies[cid], body.path == chain.path else { return false }
                if cid == genesis || range.cids.contains(cid) { return true }
                if held.contains(cid) {
                    ledger.deferred.insert(cid)
                    return true
                }
                return false
            }
        }

        var released: [String] = []
        for cid in Set(leaving) { released.append(contentsOf: ledger.remove(cid)) }
        guard !released.isEmpty else { return }
        await contentGate.beginRelease()
        // Inside the gate: a body stored a moment ago is pending by now.
        let pending = Set(pendingBodies.values.joined())
        do {
            try await broker.releaseRetainedRoots(
                scope: retentionScope, roots: released.filter { !pending.contains($0) })
        } catch {
            syncTrace("bodies not released: \(error)")
        }
        await contentGate.endRelease()
    }

    /// A block's body as this store holds it: the roots of its own Volume and
    /// of each transaction's, and their size. Nil for a block whose own
    /// Volume this store does not hold.
    private func blockBody(_ cid: String, at path: ChainPath) async -> BodyLedger.Body? {
        guard await broker.hasVolume(root: cid),
              let data = await broker.fetchDataLocal(cid: cid), let block = Block(data: data) else { return nil }
        let transactions = await NodeRuntime.transactionIDs(ofBlock: cid, fetcher: localFetcher)
        let bytes = (try? await block.logicalContentByteSize(fetcher: localFetcher)) ?? data.count
        return BodyLedger.Body(path: path, roots: [cid] + transactions, bytes: bytes)
    }
}
