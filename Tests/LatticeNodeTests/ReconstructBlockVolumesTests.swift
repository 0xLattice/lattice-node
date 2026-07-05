import XCTest
@testable import LatticeNode
import VolumeBroker

/// Storage-layer invariant behind `reconstructBlockVolumes`: `getHeaders/getHeaders2` serve a
/// block via `fetchVolumeLocal(root: blockHash)`, which needs the block to have its OWN root-keyed
/// `volume_entries(blockHash, *)` grouping. A block that arrived embedded inside a parent block's
/// volume (root=parentHash — e.g. a child block carried in a Nexus block on the shared DiskBroker)
/// or was rebuilt by CID-only crash recovery has its bytes in `cas_data` (RPC serves it) but NO
/// root volume of its own — so header serving stalls at genesis and a follower syncs 0 headers.
///
/// The fix reconstructs the missing grouping on startup by re-storing each such block as its own
/// root volume (via `storeBlockData`). This test locks in that principle: an embedded block is not
/// root-servable, and re-storing it as its own root makes it root-servable again.
final class ReconstructBlockVolumesTests: XCTestCase {

    func testReStoringEmbeddedBlockAsItsOwnRootMakesItRootServable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = try DiskBroker(path: dir.appendingPathComponent("volumes.sqlite").path)

        let parentCID = "bafyparent0000000000000000000000000000000000000000000000000"
        let childCID  = "bafychild00000000000000000000000000000000000000000000000000"
        let parentData = Data("nexus-parent-block-bytes".utf8)
        let childData  = Data("toy-child-block-bytes".utf8)

        // Embedded: the child block lives ONLY as a non-root entry of the parent's volume —
        // volume_entries(parentCID, childCID), never volume_entries(childCID, childCID).
        try await disk.storeVolumeLocal(
            SerializedVolume(root: parentCID, entries: [parentCID: parentData, childCID: childData]))

        // Bug state: getHeaders2's lookup fetchVolumeLocal(root: childCID) has no grouping for the
        // child as a root, so it can't serve it (the from-tip walk breaks here).
        let beforeRoot = await disk.fetchVolumeLocal(root: childCID)
        XCTAssertNil(beforeRoot?.entries[childCID],
            "embedded child has no volume_entries(root=childCID) — this is why getHeaders2 stalled")
        // ...yet the bytes are present by CID (what RPC + crash recovery use, and what
        // reconstruction re-derives the root volume from).
        let byCID = await disk.fetchDataLocal(cid: childCID)
        XCTAssertEqual(byCID, childData,
            "the child's bytes are present in cas_data — reconstruction has the content it needs")

        // Reconstruction (what reconstructBlockVolumes does via storeBlockData): re-store the child
        // as its OWN root volume.
        try await disk.storeVolumeLocal(SerializedVolume(root: childCID, entries: [childCID: childData]))

        // Now header serving succeeds — fetchVolumeLocal(root: childCID) returns the block.
        let afterRoot = await disk.fetchVolumeLocal(root: childCID)
        XCTAssertEqual(afterRoot?.entries[childCID], childData,
            "after reconstruction the child is root-servable, so getHeaders2 serves it over P2P")
    }
}
