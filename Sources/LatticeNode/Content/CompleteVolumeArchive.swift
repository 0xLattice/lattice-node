import Foundation
import Ivy
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

    /// Many complete Volumes already held by this node, as
    /// `encodeCompleteVolumeRecords` frames them; never read from peers.
    public func completeVolumeRecords(rootCIDs: [String]) async -> CompleteVolumeRecords {
        await encodeCompleteVolumeRecords(rootCIDs) { await completeVolumeArchive(rootCID: $0) }
    }
}

/// At most this many roots in one many-Volume read.
public let maximumCompleteVolumeRecordsRoots = 32
/// A many-Volume body stays within one protocol frame, like the node's other
/// bounded reads; a single Volume over it is read by its own CID.
public let maximumCompleteVolumeRecordsBytes = Int(IvyConfig.defaultProtocolMaxFrameSize)

/// The answer to a many-Volume read: the framed records, and whether every
/// requested root is among them.
public struct CompleteVolumeRecords: Sendable, Equatable {
    public let body: Data
    public let complete: Bool
}

/// Each root's complete archive, in request order and once per root, framed
/// `u16 root length | root | u32 archive length | archive` (big-endian). A
/// root `archive` does not answer is left out. The first archive whose
/// record would take the body past `maximumBytes` ends it: the rest are left
/// out unread, so one request reads at most the bound plus one archive.
public func encodeCompleteVolumeRecords(
    _ roots: [String],
    maximumBytes: Int = maximumCompleteVolumeRecordsBytes,
    archive: (String) async -> Data?
) async -> CompleteVolumeRecords {
    var body = Data()
    var seen = Set<String>()
    var complete = true
    for root in roots where seen.insert(root).inserted {
        let rootBytes = Array(root.utf8)
        guard rootBytes.count <= Int(UInt16.max), let archive = await archive(root),
              archive.count <= Int(UInt32.max) else {
            complete = false
            continue
        }
        guard body.count + 6 + rootBytes.count + archive.count <= maximumBytes else {
            return CompleteVolumeRecords(body: body, complete: false)
        }
        body.appendBigEndian(UInt16(rootBytes.count))
        body.append(contentsOf: rootBytes)
        body.appendBigEndian(UInt32(archive.count))
        body.append(archive)
    }
    return CompleteVolumeRecords(body: body, complete: complete)
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
