import cashew
import Foundation
import Synchronization

/// Benchmark diagnostics: how many times the node's work reads each CID's
/// bytes, by where they came from, by the work that read them and by what
/// they are. Every read is hashed and decoded by the walk that asked for
/// it, so a CID read more than once is decoded more than once: what a cache
/// of decoded content could save.
///
/// For the sync benchmark only: `ChildSyncBench` turns it on (`enable`)
/// before its follower starts, and nothing else does, so a node never
/// counts. Off, `wrap` returns the source it is given, `reading` runs its
/// work as it is, and nothing is counted. On, it keeps every CID it saw
/// until the process ends.
enum ReadTally {
    private static let on = Atomic<Bool>(false)

    static var enabled: Bool { on.load(ordering: .relaxed) }

    /// Count from now on: before the node whose reads are counted starts.
    static func enable() { on.store(true, ordering: .relaxed) }

    /// The work reading, for the reads it makes (a job's kind). Approximate:
    /// reads that cashew's `CoalescingFetcher` batches together are counted
    /// under the job that started the batch.
    @TaskLocal static var reader = "other"

    /// `work`, its reads counted under `label`.
    static func reading<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await work() }
        return try await $reader.withValue(label) { try await work() }
    }

    private struct Seen {
        var reads = 0
        var bytes = 0
        var kind = ""
    }

    private struct Tally {
        var reads = 0
        var repeated = 0
        var bytes = 0
    }

    private struct Counts {
        var byCID: [String: Seen] = [:]
        var bySource: [String: (reads: Int, bytes: Int)] = [:]
        /// By reader, then by kind.
        var byReader: [String: [String: Tally]] = [:]
    }

    private static let counts = Mutex(Counts())

    /// `source`, counted under `name` while the tally is on.
    static func wrap(_ name: String, _ source: any ContentSource) -> any ContentSource {
        enabled ? Tallied(name: name, source: source) : source
    }

    private struct Tallied: ContentSource {
        let name: String
        let source: any ContentSource

        func fetch(_ cids: Set<String>) async -> [String: Data] {
            let found = await source.fetch(cids)
            let reader = ReadTally.reader
            ReadTally.counts.withLock { counts in
                var bytes = 0
                for (cid, data) in found {
                    var seen = counts.byCID[cid] ?? Seen(kind: Kind.of(data))
                    seen.reads += 1
                    seen.bytes = data.count
                    counts.byCID[cid] = seen
                    bytes += data.count
                    var tally = counts.byReader[reader, default: [:]][seen.kind, default: Tally()]
                    tally.reads += 1
                    tally.repeated += seen.reads > 1 ? 1 : 0
                    tally.bytes += data.count
                    counts.byReader[reader, default: [:]][seen.kind] = tally
                }
                counts.bySource[name, default: (0, 0)].reads += found.count
                counts.bySource[name, default: (0, 0)].bytes += bytes
            }
            return found
        }
    }

    /// What a DAG-CBOR node is, by its top-level map's keys (sorted, joined
    /// by commas), or its major type when it is no map.
    enum Kind {
        static func of(_ data: Data) -> String {
            var reader = Reader(bytes: [UInt8](data))
            guard let (major, count) = reader.head() else { return "unreadable" }
            guard major == 5 else { return "major\(major)" }
            var keys: [String] = []
            for _ in 0..<min(count, 64) {
                guard let (keyMajor, length) = reader.head(), keyMajor == 3,
                      let key = reader.take(Int(length)) else { return "unreadable" }
                keys.append(String(decoding: key, as: UTF8.self))
                guard reader.skip() else { return "unreadable" }
            }
            return keys.sorted().joined(separator: ",")
        }

        private struct Reader {
            let bytes: [UInt8]
            var at = 0

            mutating func head() -> (UInt8, UInt64)? {
                guard at < bytes.count else { return nil }
                let initial = bytes[at]
                at += 1
                let (major, info) = (initial >> 5, initial & 0x1f)
                switch info {
                case 0..<24: return (major, UInt64(info))
                case 24...27:
                    let width = 1 << Int(info - 24)
                    guard let raw = take(width) else { return nil }
                    return (major, raw.reduce(0) { $0 << 8 | UInt64($1) })
                default: return nil
                }
            }

            mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
                guard count >= 0, at + count <= bytes.count else { return nil }
                defer { at += count }
                return bytes[at..<(at + count)]
            }

            /// Past one whole item.
            mutating func skip() -> Bool {
                guard let (major, value) = head() else { return false }
                switch major {
                case 0, 1, 7: return true
                case 2, 3: return take(Int(value)) != nil
                case 4: return (0..<value).allSatisfy { _ in skip() }
                case 5: return (0..<value).allSatisfy { _ in skip() && skip() }
                case 6: return skip()
                default: return false
                }
            }
        }
    }

    /// One line per source; per reader and kind; then the totals: reads,
    /// the distinct CIDs read, and how many reads (and bytes) were of a CID
    /// already read, with how many CIDs were read once, twice, 3-4, 5-8 and
    /// 9 or more times.
    static func summary() -> [String] {
        counts.withLock { counts in
            var lines = counts.bySource.sorted { $0.key < $1.key }.map {
                "reads source \($0.key) reads \($0.value.reads) bytes \($0.value.bytes)"
            }
            for (reader, kinds) in counts.byReader.sorted(by: { $0.key < $1.key }) {
                for (kind, tally) in kinds.sorted(by: { $0.key < $1.key }) {
                    lines.append("reads by \(reader) kind \(kind.isEmpty ? "-" : kind) reads \(tally.reads) repeated \(tally.repeated) bytes \(tally.bytes)")
                }
            }
            var reads = 0, bytes = 0, repeatReads = 0, repeatBytes = 0
            var buckets = [0, 0, 0, 0, 0]
            for seen in counts.byCID.values {
                reads += seen.reads
                bytes += seen.reads * seen.bytes
                repeatReads += seen.reads - 1
                repeatBytes += (seen.reads - 1) * seen.bytes
                let bucket = switch seen.reads {
                case 1: 0
                case 2: 1
                case 3...4: 2
                case 5...8: 3
                default: 4
                }
                buckets[bucket] += 1
            }
            lines.append(
                "reads total reads \(reads) bytes \(bytes) cids \(counts.byCID.count) repeated \(repeatReads) repeatedBytes \(repeatBytes)"
                    + " once \(buckets[0]) twice \(buckets[1]) upTo4 \(buckets[2]) upTo8 \(buckets[3]) more \(buckets[4])"
            )
            return lines
        }
    }
}

extension NodeRuntime.RuntimeJob {
    /// This job, its reads counted under `label` while the tally is on.
    func reading(_ label: String) -> Self {
        guard ReadTally.enabled else { return self }
        let run = self.run
        return Self(path: path, tipCID: tipCID, kind: kind, queued: queued) {
            await ReadTally.reading(label) { await run() }
        }
    }
}
