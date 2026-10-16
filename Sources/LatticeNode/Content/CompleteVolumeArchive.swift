import Foundation
import VolumeBroker

/// Ivy's canonical complete-Volume archive framing. Kept binary so the HTTP
/// bridge exposes the same content boundary as peer exchange, not a parallel
/// JSON representation.
public let maximumCompleteVolumeArchiveBytes = 64 * 1024 * 1024
public let maximumCompleteVolumeArchiveEntries = Int(UInt16.max)
private let maximumCIDBytes = 8192

public func encodeCompleteVolumeArchive(_ volume: SerializedVolume) -> Data? {
    guard !volume.entries.isEmpty,
          volume.entries.count <= maximumCompleteVolumeArchiveEntries,
          volume.entries[volume.root] != nil else { return nil }
    let entries = volume.entries.sorted { $0.key < $1.key }
    var size = 2
    for (cid, bytes) in entries {
        let cidLength = cid.utf8.count
        guard cidLength > 0,
              cidLength <= maximumCIDBytes,
              cidLength <= Int(UInt16.max),
              cid.utf8.allSatisfy({ $0 < 0x80 }),
              bytes.count <= Int(UInt32.max) else { return nil }
        let (metadataSize, metadataOverflow) = 6.addingReportingOverflow(cidLength)
        let (entrySize, entryOverflow) = metadataSize.addingReportingOverflow(bytes.count)
        let (nextSize, totalOverflow) = size.addingReportingOverflow(entrySize)
        guard !metadataOverflow, !entryOverflow, !totalOverflow,
              nextSize <= maximumCompleteVolumeArchiveBytes else { return nil }
        size = nextSize
    }
    var archive = Data(capacity: size)
    archive.appendBigEndian(UInt16(entries.count))
    for (cid, bytes) in entries {
        let cidBytes = Array(cid.utf8)
        archive.appendBigEndian(UInt16(cidBytes.count))
        archive.append(contentsOf: cidBytes)
        archive.appendBigEndian(UInt32(bytes.count))
        archive.append(bytes)
    }
    return archive
}

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
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
