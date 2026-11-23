import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr, which whatever runs the node
/// collects (journald, launchd, Docker, Fly); it is not kept for `/logs`. Any other non-empty value is treated as a file path,
/// shared by every node process and restart and opened for append (each
/// line one `write`, tagged with its pid and chain). It is bounded: once it
/// passes `LATTICE_SYNC_TRACE_MAX_BYTES` (default 64 MiB) it is truncated
/// and starts over. No renames, deletes or locks, so writers never fight.
package enum SyncTrace {
    private struct Sink: Sendable {
        let fd: Int32
        let cap: Int64

        func append(_ line: String) {
            var bytes = Array(line.utf8)
            _ = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress, $0.count) }
            guard cap > 0 else { return }
            var info = stat()
            if fstat(fd, &info) == 0, Int64(info.st_size) > cap {
                _ = ftruncate(fd, 0)
            }
        }
    }

    private static let destination: Sink? = {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["LATTICE_SYNC_TRACE"], !value.isEmpty else {
            return nil
        }
        if value == "1" { return Sink(fd: STDERR_FILENO, cap: 0) }
        let cap = environment["LATTICE_SYNC_TRACE_MAX_BYTES"].flatMap(Int64.init) ?? 64 << 20
        let fd = open(value, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        return fd >= 0 ? Sink(fd: fd, cap: cap) : Sink(fd: STDERR_FILENO, cap: 0)
    }()

    package static var enabled: Bool { destination != nil }

    /// The time a line is stamped with, read only while tracing (0
    /// otherwise), so durations between lines' stamps and these agree.
    package static func now() -> Double {
        enabled ? Date().timeIntervalSince1970 : 0
    }

    /// Milliseconds from `start` to `end`, for a line.
    package static func ms(_ start: Double, _ end: Double) -> String {
        String(format: "%.1f", (end - start) * 1_000)
    }

    package static func log(chain: [String], _ message: @autoclosure () -> String) {
        guard let destination else { return }
        destination.append(
            "sync-trace \(Date().timeIntervalSince1970) \(ProcessInfo.processInfo.processIdentifier) [\(chain.joined(separator: "/"))] \(message())\n"
        )
    }
}

/// When one piece of work was queued, started and done, stamped while
/// tracing only.
package struct TraceTimes: Sendable {
    package var queued: Double
    package var started: Double
    package var done: Double

    package init(queued: Double, started: Double, done: Double) {
        self.queued = queued
        self.started = started
        self.done = done
    }

    /// The line's part for this work's life once the loop takes it at
    /// `taken`: waiting to start, running, then waiting for the loop.
    package func line(taken: Double) -> String {
        "queued \(SyncTrace.ms(queued, started)) run \(SyncTrace.ms(started, done)) loop \(SyncTrace.ms(done, taken)) ms"
    }
}
