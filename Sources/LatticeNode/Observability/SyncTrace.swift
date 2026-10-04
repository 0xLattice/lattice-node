import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr, which `lattice up` sends to the
/// host's log file. Any other non-empty value is treated as a file path,
/// shared by every node process and restart and opened for append (each
/// line one `write`, tagged with its pid and chain). It is bounded: once it
/// passes `LATTICE_SYNC_TRACE_MAX_BYTES` (default 64 MiB) it is truncated
/// and starts over. No renames, deletes or locks, so writers never fight.
enum SyncTrace {
    private struct Sink: Sendable {
        let fd: Int32
        let cap: Int64

        func write(_ line: String) {
            var bytes = Array(line.utf8)
            _ = bytes.withUnsafeMutableBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
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
        let fd = open(value, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        return fd >= 0 ? Sink(fd: fd, cap: cap) : Sink(fd: STDERR_FILENO, cap: 0)
    }()

    static var enabled: Bool { destination != nil }

    static func log(chain: [String], _ message: @autoclosure () -> String) {
        guard let destination else { return }
        destination.write(
            "sync-trace \(Date().timeIntervalSince1970) \(ProcessInfo.processInfo.processIdentifier) [\(chain.joined(separator: "/"))] \(message())\n"
        )
    }
}

extension NodeStorage {
    nonisolated func syncTrace(_ message: @autoclosure () -> String) {
        SyncTrace.log(chain: configuration.chainPath, message())
    }
}
