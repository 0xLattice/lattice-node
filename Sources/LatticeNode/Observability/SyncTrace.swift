import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr, which `lattice up` sends to the
/// host's log file. Any other non-empty value is treated as a file path;
/// the pid is suffixed so node processes sharing the env never interleave.
/// (`<path>.trace-<pid>`). It is bounded: past `LATTICE_SYNC_TRACE_MAX_BYTES`
/// (default 64 MiB) a file rolls over to `<file>.1`, and at open the files
/// no live process holds are removed, so restarts do not accumulate them. One storage hosts every level of its
/// chain tree, so each line names the chain it traces (`[Nexus/Payments]`).
enum SyncTrace {
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var path: String?
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
            guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
            // Held for the process's life: marks the file live for sweeps.
            _ = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB)
            return handle
        }

        func write(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if let path, size > 0, size + UInt64(data.count) > cap {
                try? handle.close()
                try? FileManager.default.removeItem(atPath: path + ".1")
                try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
                guard let fresh = Self.open(path) else {
                    handle = .standardError
                    self.path = nil
                    return
                }
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
        removeDeadProcessFiles(value)
        let path = "\(value).trace-\(ProcessInfo.processInfo.processIdentifier)"
        return Sink(path: path, cap: cap) ?? Sink(stderr: ())
    }()

    /// Removes `<base>.trace-<digits>` (and its `.1`) that no process
    /// holds: each writer keeps an exclusive `flock` on its file, which
    /// holds across PID namespaces sharing the volume.
    private static func removeDeadProcessFiles(_ base: String) {
        let url = URL(fileURLWithPath: base)
        let directory = url.deletingLastPathComponent().path
        let prefix = url.lastPathComponent + ".trace-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        where name.hasPrefix(prefix) {
            let digits = name.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let path = directory + "/" + name
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.removeItem(atPath: path)
        }
    }

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
