import LatticeNode
import NIOCore
import VolumeBroker

/// The public read port's Volumes that this node does not hold: read from
/// peers, checked against their CIDs, served, and not kept. Readers asking
/// for one CID share one read and one archive buffer, and at most `limit`
/// CIDs are read at once (the operator's `--public-read-fetches`); past
/// that, or when the node's own content budget is full, a read is busy,
/// never reported absent.
actor PublicVolumeFetches {
    enum Answer: Sendable {
        case archive(ByteBuffer)
        case notServed
        case busy
    }

    private let limit: Int
    private let fetch: @Sendable (String) async throws -> SerializedVolume?
    private var inFlight: [String: Task<Answer, Never>] = [:]

    /// `fetch` answers nil when no peer serves the Volume within the
    /// archive caps, and throws when the node had no room to read it or is
    /// stopping.
    init(limit: Int, fetch: @escaping @Sendable (String) async throws -> SerializedVolume?) {
        self.limit = limit
        self.fetch = fetch
    }

    func archive(_ root: String) async -> Answer {
        let task: Task<Answer, Never>
        if let shared = inFlight[root] {
            task = shared
        } else {
            guard inFlight.count < limit else { return .busy }
            let fetch = fetch
            task = Task {
                do {
                    return try await fetch(root).flatMap(encodeCompleteVolumeArchive).map { .archive(ByteBuffer(bytes: $0)) } ?? .notServed
                } catch {
                    // The node's budget was full, or it is stopping.
                    return .busy
                }
            }
            inFlight[root] = task
        }
        let answer = await task.value
        if inFlight[root] == task { inFlight[root] = nil }
        return answer
    }
}
