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
            rewardRecipient: block.rewardRecipient,
            nonce: nonce
        )
    }

    public static func midstate(for block: Block) -> SHA256 {
        midstate(prefixBytes: proofOfWorkHashPrefixBytes(block))
    }

    public static func midstate(
        prefixBytes: ContiguousArray<UInt8>
    ) -> SHA256 {
        prefixBytes.withUnsafeBufferPointer { ptr in
            var hasher = SHA256()
            hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
            return hasher
        }
    }

    /// The proof-of-work hash of `nonce` over a block's midstate. The nonce
    /// is appended big-endian: Lattice's `Block.proofOfWorkNonceBytes` is the
    /// consensus encoding, inlined here so the search loop allocates nothing
    /// per nonce (`testMinerHashExactlyMatchesLatticeConsensus` pins the two).
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

            if target >= hash(midstate: midstate, nonce: nonce) { return nonce }
            nonce &+= 1
            remaining -= 1
        }
        return nil
    }
}
