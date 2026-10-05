import Foundation
import VolumeBroker
import XCTest
@testable import LatticeNode

final class CompleteVolumeArchiveTests: XCTestCase {
    func testArchiveUsesIvyCanonicalBigEndianSortedFraming() throws {
        let volume = SerializedVolume(
            root: "bafy-root",
            entries: ["bafy-z": Data([3, 4]), "bafy-root": Data([1, 2])]
        )
        let archive = try XCTUnwrap(encodeCompleteVolumeArchive(volume))
        var expected = Data([0, 2])
        expected.append(entry: "bafy-root", bytes: Data([1, 2]))
        expected.append(entry: "bafy-z", bytes: Data([3, 4]))
        XCTAssertEqual(archive, expected)
    }

    func testArchiveRequiresItsRootAndRejectsOversizedContent() {
        XCTAssertNil(encodeCompleteVolumeArchive(SerializedVolume(
            root: "missing", entries: ["member": Data()]
        )))
        XCTAssertNil(encodeCompleteVolumeArchive(SerializedVolume(
            root: "root", entries: ["root": Data(repeating: 0, count: 64 * 1024 * 1024)]
        )))
    }
}

private extension Data {
    mutating func append(entry cid: String, bytes: Data) {
        append(contentsOf: Swift.withUnsafeBytes(of: UInt16(cid.utf8.count).bigEndian, Array.init))
        append(contentsOf: cid.utf8)
        append(contentsOf: Swift.withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init))
        append(bytes)
    }
}
