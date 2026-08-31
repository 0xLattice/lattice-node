import Foundation

/// Env-gated stderr diagnostics for the sync/acquisition pipeline
/// (`LATTICE_SYNC_TRACE=1`). The node is deliberately log-quiet; this is a
/// field-diagnosis seam, not a general logging facility. Zero cost when
/// disabled.
enum SyncTrace {
    static let enabled =
        ProcessInfo.processInfo.environment["LATTICE_SYNC_TRACE"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(
            Data("sync-trace \(Date().timeIntervalSince1970) \(message())\n"
                .utf8)
        )
    }
}
