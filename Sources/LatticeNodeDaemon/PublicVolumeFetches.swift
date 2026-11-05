import LatticeNode
import NIOCore
import VolumeBroker

/// The public read port's Volumes that this node does not hold: read from
/// peers, checked against their CIDs, served, and not kept. Readers asking
/// for one CID share one read and one archive buffer, and at most `limit`
/// CIDs are read at once (the operator's `--public-read-fetches`); past
/// that a reader waits, first come first served, for a place. A read is
/// busy, never reported absent, when the node's own content budget is full,
/// and a reader that waited `maximumWait` without a place is answered so.
actor PublicVolumeFetches {
    enum Answer: Sendable {
        case archive(ByteBuffer)
        case notServed
        /// The node's own content budget had no room, or it is stopping.
        case busy
        /// The reader waited `maximumWait`, or was cancelled, without a place.
        case waited
    }

    /// How many reads run at once: what the operator asked for, but no
    /// more than fit at the archive cap in half the in-flight content
    /// budget, so the node's own sync keeps the other half; at least one.
    /// A read is never capped below the archive cap: a provider streams a
    /// whole archive however little of it the reader takes. 0 is none.
    static func limit(requested: Int, inFlightVolumeBytes: Int) -> Int {
        guard requested > 0 else { return 0 }
        return max(1, min(requested, inFlightVolumeBytes / 2 / maximumCompleteVolumeArchiveBytes))
    }

    private struct Waiter {
        let id: UInt64
        let root: String
        let resume: CheckedContinuation<Task<Answer, Never>?, Never>
    }

    private let limit: Int
    let maximumWait: Duration
    private let fetch: @Sendable (String) async throws -> SerializedVolume?
    private var inFlight: [String: Task<Answer, Never>] = [:]
    /// Readers waiting for a place, oldest first. Only while every place is
    /// taken: a freed place goes straight to the oldest.
    private var waiting: [Waiter] = []
    private var nextWaiter: UInt64 = 0

    var waitingCount: Int { waiting.count }

    /// `fetch` answers nil when no peer serves the Volume within the
    /// archive caps, and throws when the node had no room to read it or is
    /// stopping. `limit` is at least one.
    init(
        limit: Int,
        maximumWait: Duration = .seconds(30),
        fetch: @escaping @Sendable (String) async throws -> SerializedVolume?
    ) {
        precondition(limit > 0, "a node that reads none for its public port has no PublicVolumeFetches")
        self.limit = limit
        self.maximumWait = maximumWait
        self.fetch = fetch
    }

    func archive(_ root: String) async -> Answer {
        let task: Task<Answer, Never>
        if let shared = inFlight[root] {
            task = shared
        } else if inFlight.count < limit {
            task = start(root)
        } else {
            guard let started = await place(for: root) else { return .waited }
            task = started
        }
        let answer = await task.value
        if inFlight[root] == task {
            inFlight[root] = nil
            if !waiting.isEmpty { start(waiting.removeFirst()) }
        }
        return answer
    }

    private func start(_ root: String) -> Task<Answer, Never> {
        let fetch = fetch
        let task = Task<Answer, Never> {
            do {
                return try await fetch(root).flatMap(encodeCompleteVolumeArchive).map { .archive(ByteBuffer(bytes: $0)) } ?? .notServed
            } catch {
                // The node's budget was full, or it is stopping.
                return .busy
            }
        }
        inFlight[root] = task
        return task
    }

    /// The oldest waiter's read takes the freed place, and every reader
    /// waiting for the same CID shares it.
    private func start(_ next: Waiter) {
        let task = start(next.root)
        let sharing = waiting.filter { $0.root == next.root }
        waiting.removeAll { $0.root == next.root }
        for waiter in [next] + sharing { waiter.resume.resume(returning: task) }
    }

    /// Waits for a place: the read started there, or nil when the reader
    /// was cancelled or waited `maximumWait`.
    private func place(for root: String) async -> Task<Answer, Never>? {
        let id = nextWaiter
        nextWaiter += 1
        let timeout = Task { [maximumWait] in
            guard (try? await Task.sleep(for: maximumWait)) != nil else { return }
            self.leave(id)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                waiting.append(Waiter(id: id, root: root, resume: continuation))
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    private func leave(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(returning: nil)
    }
}
