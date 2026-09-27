import Foundation
import XCTest

extension XCTestCase {
    /// A fresh per-test directory under the system temporary directory,
    /// removed at teardown. `create` makes it before returning.
    func temporaryDirectory(
        prefix: String = "lattice-test",
        create: Bool = false
    ) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        if create {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
