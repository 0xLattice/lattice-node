import Foundation

/// For a block root, the Volume roots that make up its bundle.
///
/// A block's bundle is the content the protocol's `storeBlock` defines for it:
/// the block's own Volume, its transactions', its spec and policy modules,
/// and the materialized pre-state its validation reads. Never its post-state,
/// its parent or its child blocks. This is a cache of those roots, so a peer
/// can be sent them together: recorded when a block is stored, recomputed
/// from local content when a block has no row. It lives in its own file, read
/// by nothing else, and may be deleted while the node is stopped.
///
/// A cache is never an authority: nothing here throws. A file that cannot be
/// opened, read or written costs recorded bundles and nothing else, and the
/// first such failure is said on stderr.
final class VolumeBundleCache: @unchecked Sendable {
    static let fileName = "volume-bundles.db"

    private let database: NodeSQLite?
    private let lock = NSLock()
    private var reported = false

    init(directory: URL) {
        let path = directory.appendingPathComponent(Self.fileName).path
        do {
            let database = try NodeSQLite(path: path)
            // Losing a row costs a recomputation, so a write waits for no fsync.
            try database.execute("PRAGMA journal_mode=WAL")
            try database.execute("PRAGMA synchronous=NORMAL")
            try database.execute(
                "CREATE TABLE IF NOT EXISTS volume_bundles (root TEXT PRIMARY KEY, roots BLOB NOT NULL) WITHOUT ROWID"
            )
            self.database = database
        } catch {
            database = nil
            report("running without recorded Volume bundles: \(path) cannot be opened: \(error)")
        }
    }

    /// `roots` are served in order after `root`'s own Volume.
    func record(root: String, roots: [String]) {
        do {
            try database?.execute(
                "INSERT OR REPLACE INTO volume_bundles (root, roots) VALUES (?1, ?2)",
                params: [.text(root), .blob(try NodeStore.encode([root] + roots.filter { $0 != root }))]
            )
        } catch {
            report("a Volume bundle was not recorded: \(error)")
        }
    }

    /// The bundle recorded for `root`, its own Volume first, or nil.
    func bundle(root: String) -> [String]? {
        do {
            return try database?.rows(
                from: "volume_bundles",
                "SELECT roots FROM volume_bundles WHERE root = ?1",
                params: [.text(root)]
            ).first.map { try NodeStore.decode([String].self, from: try $0.blob("roots")) }
        } catch {
            report("a recorded Volume bundle was not read: \(error)")
            return nil
        }
    }

    private func report(_ message: String) {
        guard lock.withLock({ reported ? false : { reported = true; return true }() }) else { return }
        FileHandle.standardError.write(Data("lattice-node volume-bundles: \(message)\n".utf8))
    }
}
