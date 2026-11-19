import Foundation
import Lattice
import LatticeNodeCore
import Synchronization
import cashew

/// What the loop decided and the store has not written yet: the steps
/// whose facts transaction waits in the store's lane (`StoreLane`), held so
/// that a read finds what a step wrote from the moment the step ended.
///
/// Every read of `NodeStore` that a running node makes of headers, child
/// indexes, saved proofs, and whether a block is accepted or executed asks
/// here first, then the store. A step is added before its transaction is
/// asked of the lane and removed after it committed, so between the two a
/// read finds it in one or the other, and never has to wait for the lane.
/// The reads that work on the store itself (what it counts, what it lets go
/// of) wait for the lane instead (`NodeStorage.flushState`, `written`).
///
/// A crash loses what is here: the store holds a prefix of what the loop
/// decided, and a start goes on from it.
final class PendingFacts: Sendable {
    private struct Step {
        var headers: [String: StoredHeader] = [:]
        /// A header's child index CID, to the header that carries it.
        var childIndexes: [String: String] = [:]
        /// Chain, then child block, then proof root.
        var proofs: [String: [String: [String: ChildBlockProof]]] = [:]
        var accepted: Set<String> = []
        var executed: Set<String> = []
        var bytes = 0
    }

    /// What a held header and a held fact are counted as. A proof's entries
    /// are counted by their bytes; a header and a fact are held as values,
    /// and measuring one would serialize it on the loop, so each is counted
    /// as more than its serialized size: a header's own node is a few
    /// hundred bytes, each child its index names about 100 (its path
    /// segment and a CID), a fact under 300. A header is counted by its
    /// children, so a Nexus block that commits many child chains counts as
    /// much more than one that commits none.
    static let headerBytes = 1_024
    static let childBytes = 256
    static let factBytes = 512

    private struct Held {
        var next: UInt64 = 0
        var steps: [(id: UInt64, step: Step)] = []
        var bytes = 0
    }

    /// The bytes held, as counted above: what the loop's wait for the lane
    /// bounds (`NodeStorage.laneIsBehind`).
    var bytes: Int { held.withLock(\.bytes) }

    private let held = Mutex(Held())

    private static func key(_ path: String, _ cid: String) -> String { path + "\n" + cid }

    /// Holds one step's levels until `remove`. Returns its token.
    func add(_ levels: [NodeFactBatch]) -> UInt64 {
        var step = Step()
        for level in levels {
            let path = level.path.joined(separator: "/")
            step.bytes += level.headers.reduce(0) { $0 + Self.headerBytes + $1.children.count * Self.childBytes }
            step.bytes += level.facts.reduce(0) { $0 + $1.facts.count } * Self.factBytes
            for stored in level.proofs {
                step.bytes += stored.proof.entries.reduce(0) { $0 + $1.cid.utf8.count + $1.data.count }
            }
            for header in level.headers {
                step.headers[header.blockCID] = header
                step.childIndexes[header.block.children.rawCID] = header.blockCID
            }
            for stored in level.proofs {
                step.proofs[path, default: [:]][stored.childCID, default: [:]][stored.proof.rootCID] = stored.proof
            }
            for fact in level.facts.flatMap(\.facts) {
                switch fact {
                case .block(let block): step.accepted.insert(Self.key(path, block.blockHash))
                case .validation(let validation): step.executed.insert(Self.key(path, validation.blockHash))
                default: break
                }
            }
        }
        return held.withLock { held in
            held.next += 1
            held.bytes += step.bytes
            held.steps.append((held.next, step))
            return held.next
        }
    }

    /// The store holds the step: it is read from there.
    func remove(_ id: UInt64) {
        held.withLock { held in
            guard let index = held.steps.firstIndex(where: { $0.id == id }) else { return }
            held.bytes -= held.steps[index].step.bytes
            held.steps.remove(at: index)
        }
    }

    /// The newest pending step that answers, if one does.
    private func newest<T>(_ find: (Step) -> T?) -> T? {
        held.withLock { held in
            for entry in held.steps.reversed() {
                if let found = find(entry.step) { return found }
            }
            return nil
        }
    }

    func header(_ cid: String) -> StoredHeader? {
        newest { $0.headers[cid] }
    }

    /// The header whose child index `cid` names.
    func headerCarrying(childIndex cid: String) -> StoredHeader? {
        newest { step in step.childIndexes[cid].flatMap { step.headers[$0] } }
    }

    /// The pending proofs of `children` at `path`, by child then root, the
    /// newest step's copy of each.
    func proofs(at path: String, for children: [String]) -> [String: [String: ChildBlockProof]] {
        held.withLock { held in
            var found: [String: [String: ChildBlockProof]] = [:]
            for entry in held.steps {
                guard let chain = entry.step.proofs[path] else { continue }
                for child in children {
                    guard let proofs = chain[child] else { continue }
                    found[child, default: [:]].merge(proofs) { _, newer in newer }
                }
            }
            return found
        }
    }

    func accepted(_ cid: String, at path: String) -> Bool {
        newest { $0.accepted.contains(Self.key(path, cid)) ? true : nil } ?? false
    }

    func executed(_ cid: String, at path: String) -> Bool {
        newest { $0.executed.contains(Self.key(path, cid)) ? true : nil } ?? false
    }
}
