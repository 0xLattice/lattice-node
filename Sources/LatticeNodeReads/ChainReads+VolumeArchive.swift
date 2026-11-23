import Foundation
import Ivy
import VolumeBroker
import LatticeNodeNet
import LatticeNodeStore

extension ChainReads {
    /// One complete Volume already held by this node; never read from
    /// peers. The public read port reads a miss from peers separately,
    /// within the operator's `--public-read-fetches`.
    public func completeVolumeArchive(rootCID: String) async -> Data? {
        guard let volume = await storage.volume(rootCID), volume.root == rootCID else {
            return nil
        }
        return encodeCompleteVolumeArchive(volume)
    }

    /// Many complete Volumes already held by this node, as
    /// `encodeCompleteVolumeRecords` frames them; never read from peers.
    public func completeVolumeRecords(rootCIDs: [String]) async -> CompleteVolumeRecords {
        await encodeCompleteVolumeRecords(rootCIDs) { root in
            guard let volume = await storage.volume(root), volume.root == root else { return .notHeld }
            return encodeCompleteVolumeArchive(volume).map(HeldVolume.archive) ?? .unencodable
        }
    }
}
