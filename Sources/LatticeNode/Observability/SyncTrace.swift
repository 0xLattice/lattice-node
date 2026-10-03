import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr, which `lattice up` sends to the
/// host's log file. Any other non-empty value is treated as a file path;
/// the pid is suffixed so separate node processes sharing the env never
/// interleave writes. One storage hosts every level of its chain tree, so
/// each line names the chain it traces (`[Nexus/Payments]`).
enum SyncTrace {
    private static let destination: FileHandle? = {
        guard let value = ProcessInfo.processInfo
            .environment["LATTICE_SYNC_TRACE"], !value.isEmpty else {
            return nil
        }
        if value == "1" { return FileHandle.standardError }
        let path = "\(value).\(ProcessInfo.processInfo.processIdentifier)"
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return FileHandle.standardError
        }
        handle.seekToEndOfFile()
        return handle
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
