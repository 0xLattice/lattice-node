import Foundation
@testable import LatticeNode

extension NodeStorage {
    /// `open`, once no other storage in this process holds the directory.
    /// A stopped runtime's lock goes with its storage's last reference,
    /// which its tasks can hold a moment past `stop()`; a node restarts by
    /// exiting, so only a test reopens in the same process. Any other
    /// failure to open is thrown at once.
    static func openWhenFree(configuration: NodeConfiguration) async throws -> NodeStorage {
        var opened: NodeStorage?
        try await eventually("a stopped node lets go of \(configuration.storagePath.lastPathComponent)") {
            do {
                opened = try await NodeStorage.open(configuration: configuration)
            } catch NodeStorageError.storageInUse {}
            return opened != nil
        }
        return opened!
    }
}
