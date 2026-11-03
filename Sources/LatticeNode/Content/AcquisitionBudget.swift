import Foundation

/// One byte budget for every content session in the node, every hosted
/// chain together (`--max-acquisition-bytes`): Bitcoin's bound on block
/// download memory, blocks in flight times the largest block.
///
/// A session reserves its worst case once, before its first request to a
/// peer, and gives the whole reservation back when it ends, however it
/// ends. It never reserves again while it holds one, so no session waits
/// on the budget holding any of it, and the reservations held always come
/// back: the waiter first in line fits once they have (no reservation is
/// larger than the budget).
///
/// Past the bound a session waits; nothing asked for is declined for it.
/// Waiters are served first in, first out, by chain depth: a child chain
/// connects only as far as its parent has executed, so while a parent
/// catches up its fetches go first and its descendants' wait. At one
/// depth, each chain's next block to connect goes ahead of look-ahead
/// fetches, and the node's own work goes with the root's next blocks.
public final class AcquisitionBudget: @unchecked Sendable {
    /// What a reservation is for, which orders it in line.
    public enum Priority: Sendable, Equatable {
        /// The node's own work: a connect, a template, a mined block.
        case ownWork
        /// A body fetch for this block of a chain `depth` levels below the
        /// root: ahead of deeper chains' fetches, and ahead of look-ahead at
        /// its depth while the block is one a chain can connect next
        /// (`prioritize`).
        case body(String, depth: Int = 0)
    }

    /// Read and written under `lock` only.
    private final class Waiter: @unchecked Sendable {
        let bytes: Int
        let priority: Priority
        let sequence: UInt64
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelled = false

        init(bytes: Int, priority: Priority, sequence: UInt64) {
            self.bytes = bytes
            self.priority = priority
            self.sequence = sequence
        }
    }

    let capacity: Int
    private let lock = NSLock()
    private var used = 0
    private var peak = 0
    private var sequence: UInt64 = 0
    private var next: Set<String> = []
    private var waiters: [Waiter] = []

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// The bytes reserved now.
    var reserved: Int { lock.withLock { used } }

    /// The most bytes ever reserved at once.
    var peakReserved: Int { lock.withLock { peak } }

    /// The sessions waiting now.
    var waiting: Int { lock.withLock { waiters.count } }

    /// The blocks each chain can connect next: their body fetches wait
    /// ahead of look-ahead.
    func prioritize(_ blocks: Set<String>) {
        resume(lock.withLock {
            guard blocks != next else { return [] }
            next = blocks
            return grant()
        })
    }

    /// Reserves `bytes` (at most the capacity), waiting while they do not
    /// fit or others wait ahead. The bytes reserved, or nil when the task
    /// was cancelled first: then nothing is reserved.
    func reserve(_ bytes: Int, priority: Priority) async -> Int? {
        let bytes = min(max(bytes, 0), capacity)
        let waiter = lock.withLock {
            sequence += 1
            return Waiter(bytes: bytes, priority: priority, sequence: sequence)
        }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resume(lock.withLock {
                    // Cancelled before it was in line: never enqueued.
                    guard !waiter.cancelled else { return [(continuation, false)] }
                    waiter.continuation = continuation
                    waiters.append(waiter)
                    return grant()
                })
            }
        } onCancel: {
            resume(lock.withLock {
                waiter.cancelled = true
                // Granted already: the session ends and releases it.
                guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return [] }
                waiters.remove(at: index)
                var resumed = grant()
                if let continuation = waiter.continuation { resumed.append((continuation, false)) }
                waiter.continuation = nil
                return resumed
            })
        }
        return granted ? bytes : nil
    }

    func release(_ bytes: Int) {
        guard bytes != 0 else { return }
        resume(lock.withLock {
            used -= bytes
            precondition(used >= 0)
            return grant()
        })
    }

    /// Grants waiters in line while the first fits. Under the lock.
    private func grant() -> [(CheckedContinuation<Bool, Never>, Bool)] {
        var granted: [(CheckedContinuation<Bool, Never>, Bool)] = []
        while let index = first() {
            let waiter = waiters[index]
            guard waiter.bytes <= capacity - used else { break }
            waiters.remove(at: index)
            used += waiter.bytes
            peak = max(peak, used)
            if let continuation = waiter.continuation { granted.append((continuation, true)) }
            waiter.continuation = nil
        }
        return granted
    }

    /// The waiter first in line: the earliest at the shallowest depth, a
    /// next block to connect (or the node's own work, at the root) before
    /// look-ahead.
    private func first() -> Int? {
        func rank(_ waiter: Waiter) -> (depth: Int, lookAhead: Int) {
            switch waiter.priority {
            case .ownWork: (0, 0)
            case .body(let cid, let depth): (depth, next.contains(cid) ? 0 : 1)
            }
        }
        // `waiters` is in arrival order, so the first minimum is the earliest.
        return waiters.indices.min { rank(waiters[$0]) < rank(waiters[$1]) }
    }

    private func resume(_ continuations: [(CheckedContinuation<Bool, Never>, Bool)]) {
        for (continuation, value) in continuations { continuation.resume(returning: value) }
    }
}
