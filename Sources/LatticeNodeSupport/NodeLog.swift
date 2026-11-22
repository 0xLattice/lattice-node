import Foundation

/// The node's recent log lines, for `GET /logs`. Each line the node logs
/// (`logLine`) goes to its standard error, where whatever runs the node
/// collects it (journald, launchd, Docker, Fly), and is kept here too, in
/// memory: the node keeps no log file. Anything else written to standard
/// error, a crash report among it, goes straight there and is not kept.
public final class NodeLog: @unchecked Sendable {
    /// At most this many lines are kept, and at most `maximumBytes` of them.
    public static let maximumLines = 10_000
    public static let maximumBytes = 4 << 20
    /// A longer line is kept in parts of this many bytes.
    public static let maximumLineBytes = 16 << 10

    private let lock = NSLock()
    /// A ring: `count` lines from `start`. A dropped line's slot is emptied
    /// at once, so its memory goes with it.
    private var slots = [String](repeating: "", count: NodeLog.maximumLines)
    private var start = 0
    private var count = 0
    private var bytes = 0

    public init() {}

    /// Keeps `text`, one line for each of its lines.
    public func append(_ text: String) {
        var parts: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = line.utf8
            repeat {
                parts.append(String(decoding: rest.prefix(Self.maximumLineBytes), as: UTF8.self))
                rest = rest.dropFirst(Self.maximumLineBytes)
            } while !rest.isEmpty
        }
        lock.withLock { parts.forEach(keep) }
    }

    private func keep(_ line: String) {
        if count == Self.maximumLines { drop() }
        slots[(start + count) % Self.maximumLines] = line
        count += 1
        bytes += line.utf8.count
        while bytes > Self.maximumBytes, count > 1 { drop() }
    }

    private func drop() {
        bytes -= slots[start].utf8.count
        slots[start] = ""
        start = (start + 1) % Self.maximumLines
        count -= 1
    }

    /// The last `count` lines kept, each ending in a newline.
    public func tail(_ count: Int) -> String {
        let lines = lock.withLock {
            let taken = min(max(0, count), self.count)
            return (self.count - taken..<self.count).map { slots[(start + $0) % Self.maximumLines] }
        }
        return lines.map { $0 + "\n" }.joined()
    }
}

/// The node's log.
public let nodeLog = NodeLog()

/// One line of the node's log, stamped with the time (ISO 8601, UTC): on its
/// standard error, and kept for `/logs`.
public func logLine(_ line: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + line
    FileHandle.standardError.write(Data((line + "\n").utf8))
    nodeLog.append(line)
}

/// `duration` in seconds, for a log line.
package func seconds(_ duration: Duration) -> String {
    let (whole, fraction) = duration.components
    return String(format: "%.3f s", Double(whole) + Double(fraction) / 1e18)
}
