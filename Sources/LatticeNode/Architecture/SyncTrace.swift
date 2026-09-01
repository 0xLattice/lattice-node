import Foundation

/// Env-gated diagnostics for the sync/acquisition pipeline. The node is
/// deliberately log-quiet; this is a field-diagnosis seam, not a general
/// logging facility. Zero cost when disabled.
///
/// `LATTICE_SYNC_TRACE=1` writes to stderr. Any other non-empty value is
/// treated as a file path — needed under `lattice up`, which discards child
/// stderr. The pid is suffixed so sibling node processes sharing the env
/// (root + child under one `lattice up`) never interleave writes.
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

    static func log(_ message: @autoclosure () -> String) {
        guard let destination else { return }
        destination.write(
            Data("sync-trace \(Date().timeIntervalSince1970) \(message())\n"
                .utf8)
        )
    }
}
