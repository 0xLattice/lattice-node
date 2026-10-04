import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr, which `lattice up` sends to the
/// host's log file. Any other non-empty value is treated as a file path,
/// reused across restarts and bounded: past `LATTICE_SYNC_TRACE_MAX_BYTES`
/// (default 64 MiB) it rolls over to `<path>.1`, so the trace never holds
/// more than twice the cap on disk. One storage hosts every level of its
/// chain tree, so each line names the chain it traces (`[Nexus/Payments]`).
enum SyncTrace {
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        let path: String?
        let cap: UInt64
        var handle: FileHandle
        var size: UInt64

        init(stderr: Void) {
            path = nil; cap = .max; handle = .standardError; size = 0
        }

        init?(path: String, cap: UInt64) {
            self.path = path
            self.cap = cap
            guard let handle = Self.open(path) else { return nil }
            self.handle = handle
            size = handle.seekToEndOfFile()
        }

        static func open(_ path: String) -> FileHandle? {
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
            }
            return FileHandle(forWritingAtPath: path)
        }

        func write(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if let path, size > 0, size + UInt64(data.count) > cap {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: path + ".1")
                try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
                guard let fresh = Self.open(path) else { return }
                handle = fresh
                size = 0
            }
            handle.write(data)
            size += UInt64(data.count)
        }
    }

    private static let destination: Sink? = {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["LATTICE_SYNC_TRACE"], !value.isEmpty else {
            return nil
        }
        if value == "1" { return Sink(stderr: ()) }
        let cap = environment["LATTICE_SYNC_TRACE_MAX_BYTES"].flatMap(UInt64.init) ?? 64 << 20
        return Sink(path: value, cap: cap) ?? Sink(stderr: ())
    }()

    static var enabled: Bool { destination != nil }

    static func log(chain: [String], _ message: @autoclosure () -> String) {
        guard let destination else { return }
        destination.write(Data(
            "sync-trace \(Date().timeIntervalSince1970) [\(chain.joined(separator: "/"))] \(message())\n"
                .utf8
        ))
    }
}

extension NodeStorage {
    nonisolated func syncTrace(_ message: @autoclosure () -> String) {
        SyncTrace.log(chain: configuration.chainPath, message())
    }
}
