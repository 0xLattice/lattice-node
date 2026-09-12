import Foundation

/// Replaces `url` atomically and syncs the file and its directory to stable
/// storage before returning.
public func writeDurably(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try syncToDisk(url.path)
    try syncToDisk(directory.path)
}

/// Writes `data` to `url` durably only if nothing is there yet; false when
/// something already is, which is left untouched.
public func createDurably(_ data: Data, at url: URL) throws -> Bool {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    // A kill between staging and link leaves the staged copy behind. Sweep
    // old ones, never recent ones: a staging file seconds old may belong to
    // a deploy that is still between its own staging and link.
    let prefix = ".\(url.lastPathComponent)."
    if let existing = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
    ) {
        for stale in existing
        where stale.lastPathComponent.hasPrefix(prefix)
            && Date().timeIntervalSince((try? stale.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? Date()) > 600 {
            try? FileManager.default.removeItem(at: stale)
        }
    }
    // Stage the whole file, synced, beside the target; link(2) then claims
    // the name atomically and fails if anything already holds it, so the
    // target is never partially written and never replaced.
    let staging = directory.appendingPathComponent(
        "\(prefix)\(UUID().uuidString)"
    )
    try data.write(to: staging)
    defer { unlink(staging.path) }
    try syncToDisk(staging.path)
    guard link(staging.path, url.path) == 0 else {
        if errno == EEXIST { return false }
        throw CtlError("cannot create \(url.path) (errno \(errno))")
    }
    try syncToDisk(directory.path)
    return true
}

/// Removes `url` only while it still holds exactly `expected`, so a caller
/// never deletes a file someone else has since written there.
public func removeIfUnchanged(_ url: URL, expected: Data) {
    guard (try? Data(contentsOf: url)) == expected else { return }
    try? FileManager.default.removeItem(at: url)
}

private func syncToDisk(_ path: String) throws {
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else {
        throw CtlError("cannot open \(path) to sync it (errno \(errno))")
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
        throw CtlError("cannot sync \(path) to disk (errno \(errno))")
    }
}
