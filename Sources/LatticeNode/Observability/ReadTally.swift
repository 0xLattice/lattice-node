import cashew
import Foundation
import Synchronization

/// Benchmark diagnostics: how many times the node's work reads each CID's
/// bytes, by where they came from. Every read is hashed and decoded by the
/// walk that asked for it, so a CID read more than once is decoded more than
/// once: what a cache of decoded content could save.
///
/// `LATTICE_READ_TALLY=1` turns it on. Off, `wrap` returns the source it is
/// given, and nothing is counted. It keeps every CID it saw until the
/// process ends, so it is for benchmarks, not for a node that runs on.
enum ReadTally {
    static let enabled = ProcessInfo.processInfo.environment["LATTICE_READ_TALLY"] == "1"

    private struct Seen {
        var reads = 0
        var bytes = 0
    }

    private struct Counts {
        var byCID: [String: Seen] = [:]
        var bySource: [String: (reads: Int, bytes: Int)] = [:]
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
            ReadTally.counts.withLock { counts in
                var bytes = 0
                for (cid, data) in found {
                    counts.byCID[cid, default: Seen()].reads += 1
                    counts.byCID[cid, default: Seen()].bytes = data.count
                    bytes += data.count
                }
                counts.bySource[name, default: (0, 0)].reads += found.count
                counts.bySource[name, default: (0, 0)].bytes += bytes
            }
            return found
        }
    }

    /// One line per source, then the totals: reads, the distinct CIDs read,
    /// and how many reads (and bytes) were of a CID already read, with how
    /// many CIDs were read once, twice, 3-4, 5-8 and 9 or more times.
    static func summary() -> [String] {
        counts.withLock { counts in
            var lines = counts.bySource.sorted { $0.key < $1.key }.map {
                "reads source \($0.key) reads \($0.value.reads) bytes \($0.value.bytes)"
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
