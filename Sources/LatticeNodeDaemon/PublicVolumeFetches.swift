import LatticeNode
import VolumeBroker

/// The public read port's Volumes that this node does not hold: read from
/// peers, checked against their CIDs, served, and not kept. Readers asking
/// for one CID share one fetch, and at most `limit` CIDs are fetched at once
/// (the operator's `--public-read-fetches`); past that a read is busy, never
/// reported absent.
actor PublicVolumeFetches {
    enum Answer: Sendable {
        case volume(SerializedVolume)
        case notServed
        case busy
    }

    private let limit: Int
    private let fetch: @Sendable (String) async -> SerializedVolume?
    private var inFlight: [String: Task<SerializedVolume?, Never>] = [:]

    init(limit: Int, fetch: @escaping @Sendable (String) async -> SerializedVolume?) {
        self.limit = limit
        self.fetch = fetch
    }

    func volume(_ root: String) async -> Answer {
        let task: Task<SerializedVolume?, Never>
        if let shared = inFlight[root] {
            task = shared
        } else {
            guard inFlight.count < limit else { return .busy }
            let fetch = fetch
            task = Task { await fetch(root) }
            inFlight[root] = task
        }
        let volume = await task.value
        if inFlight[root] == task { inFlight[root] = nil }
        return volume.map { .volume($0) } ?? .notServed
    }
}
