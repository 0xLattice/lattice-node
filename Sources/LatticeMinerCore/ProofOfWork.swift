import Crypto
import Lattice
import UInt256

public struct NonceSearchRange: Sendable, Equatable {
    public let startNonce: UInt64
    public let count: UInt64

    public init(startNonce: UInt64, count: UInt64) {
        self.startNonce = startNonce
        self.count = count
    }
}

public enum ProofOfWork {
    /// Nonce-independent PoW preimage bytes the miner hashes once into a midstate.
    /// The consensus byte layout is owned by `Lattice.Block`; this delegates to the
    /// single source of truth rather than re-deriving it (see #135).
    public static func proofOfWorkHashPrefixBytes(_ block: Block) -> ContiguousArray<UInt8> {
        ContiguousArray(Block.makeProofOfWorkPreimagePrefix(block: block))
    }

    public static func withNonce(_ block: Block, nonce: UInt64) -> Block {
        Block(
            version: block.version,
            parent: block.parent,
            transactions: block.transactions,
            target: block.target,
            nextTarget: block.nextTarget,
            spec: block.spec,
            parentState: block.parentState,
            prevState: block.prevState,
            postState: block.postState,
            children: block.children,
            height: block.height,
            timestamp: block.timestamp,
            nonce: nonce
        )
    }

    public static func midstate(for block: Block) -> SHA256 {
        let prefixBytes = proofOfWorkHashPrefixBytes(block)
        return prefixBytes.withUnsafeBufferPointer { ptr in
            var hasher = SHA256()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
            return hasher
        }
    }

    public static func hash(midstate: SHA256, nonce: UInt64) -> UInt256 {
        var nonceBytes = nonce.bigEndian
        var hasher = midstate
        withUnsafeBytes(of: &nonceBytes) { bytes in
            hasher.update(bufferPointer: bytes)
        }
        let digest = hasher.finalize()
        return digest.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            return UInt256([
                UInt64(bigEndian: p[0]),
                UInt64(bigEndian: p[1]),
                UInt64(bigEndian: p[2]),
                UInt64(bigEndian: p[3])
            ])
        }
    }

    public static func searchNonce(
        midstate: SHA256,
        target: UInt256,
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) async -> UInt64? {
        await searchNonce(
            midstate: midstate,
            target: target,
            ranges: nonceSearchRanges(
                totalBatchSize: totalBatchSize,
                workerCount: workerCount,
                nonceOffset: nonceOffset
            )
        )
    }

    public static func nonceSearchRanges(
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) -> [NonceSearchRange] {
        let workerCount = max(workerCount, 1)
        let totalBatchSize = max(totalBatchSize, 1)
        let baseCount = totalBatchSize / UInt64(workerCount)
        let remainder = Int(totalBatchSize % UInt64(workerCount))

        var ranges: [NonceSearchRange] = []
        ranges.reserveCapacity(workerCount)

        var startNonce = nonceOffset
        for i in 0..<workerCount {
            let count = baseCount &+ (i < remainder ? 1 : 0)
            if count == 0 { continue }
            ranges.append(NonceSearchRange(startNonce: startNonce, count: count))
            startNonce &+= count
        }
        return ranges
    }

    public static func searchNonce(
        midstate: SHA256,
        target: UInt256,
        ranges: [NonceSearchRange]
    ) async -> UInt64? {
        guard !ranges.isEmpty else { return nil }
        let args = SendableSearchArgs(
            midstate: midstate,
            target: target
        )

        return await withTaskGroup(of: UInt64?.self) { group in
            for range in ranges {
                group.addTask {
                    searchBatch(
                        midstate: args.midstate,
                        target: args.target,
                        startNonce: range.startNonce,
                        count: range.count
                    )
                }
            }
            for await result in group {
                if let nonce = result {
                    group.cancelAll()
                    return nonce
                }
            }
            return nil
        }
    }

    public static func searchBatch(
        midstate: SHA256,
        target: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        var nonce = startNonce
        var remaining = count

        while remaining > 0 {
            if nonce & 0x3FF == 0 && Task.isCancelled { return nil }

            var nonceBytes = nonce.bigEndian
            var hasher = midstate
            withUnsafeBytes(of: &nonceBytes) { bytes in
                hasher.update(bufferPointer: bytes)
            }
            let digest = hasher.finalize()
            let hash: UInt256 = digest.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt64.self)
                return UInt256([
                    UInt64(bigEndian: p[0]),
                    UInt64(bigEndian: p[1]),
                    UInt64(bigEndian: p[2]),
                    UInt64(bigEndian: p[3])
                ])
            }
            if target >= hash { return nonce }
            nonce &+= 1
            remaining -= 1
        }
        return nil
    }

}

private struct SendableSearchArgs: @unchecked Sendable {
    let midstate: SHA256
    let target: UInt256
}
