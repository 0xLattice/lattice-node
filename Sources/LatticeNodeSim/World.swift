import Foundation
import Lattice
import LatticeNodeCore
import Synchronization
import UInt256
import cashew

/// An in-memory content store the world builds blocks into and bootstraps
/// the genesis from.
public final class SimCAS: Fetcher, Storer, VolumeStorer {
    private let entries = Mutex<[String: Data]>([:])

    public init() {}

    public func fetch(rawCid: String) async throws -> Data {
        guard let data = entries.withLock({ $0[rawCid] }) else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    public func store(entries new: [String: Data]) async throws {
        entries.withLock { $0.merge(new) { _, latest in latest } }
    }

    public func store(volume: SerializedVolume) async throws {
        entries.withLock { $0.merge(volume.entries) { _, latest in latest } }
    }
}

/// One block the world generated.
public struct SimBlock: Sendable {
    public let cid: String
    public let block: Block
    public let children: ChildIndex
    public let parent: String?
    public let height: UInt64
    /// When a source may first show it (its own timestamp).
    public let releaseAt: Int64
    /// Its difficulty schedule's origin (its height-1 ancestor).
    let anchor: DifficultyAnchor?
}

/// The generator's ground truth: the chain spec, the bootstrapped genesis,
/// the honest block tree in release order, and a low-work spam fork.
public struct World: Sendable {
    public static let genesisTime: Int64 = 1_700_000_000_000
    public static let blockInterval: Int64 = 1_000
    public static let spamInterval: Int64 = 20_000

    public let spec: ChainSpec
    public let context: ChainRuntimeContext
    public let genesis: SimBlock
    public let bootstrap: GenesisBootstrap
    public let blocks: [String: SimBlock]
    /// Honest blocks in release order.
    public let honest: [String]
    /// The spam fork from genesis, in order.
    public let spam: [String]
    /// A block whose parent is never served: a header that does not connect.
    public let orphan: String

    public static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: UInt64(blockInterval),
        initialReward: 100,
        halvingInterval: 10_000,
        halfLife: 10
    )

    /// One hash in eight meets the genesis target, so a tampered header
    /// almost always fails proof-of-work.
    public static let genesisTarget = UInt256.max >> 3

    /// Generate a world: `honestBlocks` honest blocks, each on the current
    /// GHOST head or, with `forkProbability`, on one of its three nearest
    /// ancestors; and `spamBlocks` slow blocks forking from genesis.
    public static func generate(
        rng: inout SplitMix64,
        honestBlocks: Int,
        forkProbability: Double,
        spamBlocks: Int
    ) async throws -> World {
        let cas = SimCAS()
        try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
        let genesisBlock = mined(try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: genesisTime,
            target: genesisTarget,
            fetcher: cas
        ))
        let genesis = try await record(genesisBlock, releaseAt: genesisTime, anchor: nil, in: cas)
        let context = try ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY])
        let bootstrap = try await ChainTree.bootstrap(
            genesis: BlockHeader(node: genesisBlock),
            fetcher: cas,
            context: context,
            validationContext: ValidationContext(nowMilliseconds: genesisTime)
        ).get()

        var blocks = [genesis.cid: genesis]
        var reference = GhostReference(genesis: genesis.cid)
        var honest: [String] = []
        for index in 1...max(honestBlocks, 1) {
            var parent = reference.head
            if rng.chance(forkProbability) {
                for _ in 0..<rng.draw(1...3) {
                    parent = blocks[parent]?.parent ?? parent
                }
            }
            let time = genesisTime + Int64(index) * blockInterval
            let next = try await extend(
                blocks[parent]!, timestamp: time, nonce: UInt64(index) << 32, in: cas
            )
            blocks[next.cid] = next
            honest.append(next.cid)
            reference.add(next.cid, parent: parent, work: workForTarget(next.block.target))
        }

        var spam: [String] = []
        var spamTip = genesis
        for index in 0..<spamBlocks {
            let time = genesisTime + Int64(index + 1) * spamInterval
            spamTip = try await extend(
                spamTip, timestamp: time, nonce: (UInt64(index) << 32) | 0xFFFF, in: cas
            )
            blocks[spamTip.cid] = spamTip
            spam.append(spamTip.cid)
        }
        let withheld = try await extend(genesis, timestamp: genesisTime + 1, nonce: 0xDEAD << 32, in: cas)
        let orphan = try await extend(
            withheld, timestamp: genesisTime + 2, nonce: 0xBEEF << 32, in: cas
        )
        blocks[orphan.cid] = orphan

        return World(
            spec: spec,
            context: context,
            genesis: genesis,
            bootstrap: bootstrap,
            blocks: blocks,
            honest: honest,
            spam: spam,
            orphan: orphan.cid
        )
    }

    private static func extend(
        _ parent: SimBlock,
        timestamp: Int64,
        nonce: UInt64,
        in cas: SimCAS
    ) async throws -> SimBlock {
        let built = try await BlockBuilder.buildBlock(
            previous: parent.block,
            timestamp: timestamp,
            nonce: nonce,
            difficultyAnchor: parent.anchor,
            fetcher: cas
        )
        // Detach the parent node: a block value carries its own fields and
        // links, never its whole ancestry.
        let block = mined(built.replacing(parent: built.parent?.removingNode(), nonce: built.nonce))
        let anchor = parent.anchor
            ?? DifficultyAnchor(blockHeight: 1, timestamp: block.timestamp, target: block.target)
        return try await record(block, releaseAt: timestamp, anchor: anchor, in: cas)
    }

    static func record(
        _ block: Block,
        releaseAt: Int64,
        anchor: DifficultyAnchor?,
        in cas: SimCAS
    ) async throws -> SimBlock {
        // The block's own Volume (its child index inside it), its spec and
        // its post-state: what bootstrap and the builder's difficulty walk read.
        let header = try BlockHeader(node: block)
        try await header.store(paths: [:], storer: cas as any VolumeStorer)
        try await block.spec.storeRecursively(storer: cas as any VolumeStorer)
        if block.postState.node != nil {
            try await block.postState.storeRecursively(storer: cas as any VolumeStorer)
        }
        guard let children = block.children.node else {
            throw SimulationError.malformedWorld("block \(header.rawCID) has no child index node")
        }
        return SimBlock(
            cid: header.rawCID,
            block: block,
            children: children,
            parent: block.parent?.rawCID,
            height: block.height,
            releaseAt: releaseAt,
            anchor: anchor
        )
    }

    /// The first nonce at or above the block's own that meets its target.
    static func mined(_ block: Block) -> Block {
        var nonce = block.nonce
        while true {
            let candidate = block.replacingNonce(nonce)
            if ChainTree.rootWork(of: candidate) != nil { return candidate }
            nonce &+= 1
        }
    }

    /// The first nonce at or above the block's own that MISSES its target: a
    /// tampered header a liar serves.
    static func forged(_ block: Block) -> Block {
        var nonce = block.nonce &+ 1
        while true {
            let candidate = block.replacingNonce(nonce)
            if ChainTree.rootWork(of: candidate) == nil { return candidate }
            nonce &+= 1
        }
    }

    /// `count` distinct blocks on genesis, each committing its own non-empty
    /// child index (so a receiver cannot rebuild it and must fetch it).
    public func carriers(count: Int) async throws -> [SimBlock] {
        let cas = SimCAS()
        var carriers: [SimBlock] = []
        for index in 0..<count {
            let built = try await BlockBuilder.buildBlock(
                previous: genesis.block,
                children: ["Carried\(index)": genesis.block],
                timestamp: World.genesisTime + World.blockInterval,
                nonce: UInt64(index) << 40,
                fetcher: cas
            )
            let block = World.mined(built.replacing(parent: built.parent?.removingNode(), nonce: built.nonce))
            carriers.append(try await World.record(
                block,
                releaseAt: block.timestamp,
                anchor: DifficultyAnchor(blockHeight: 1, timestamp: block.timestamp, target: block.target),
                in: cas
            ))
        }
        return carriers
    }

    /// Blocks released by `now`, in release order.
    public func released(_ order: [String], at now: Int64) -> [SimBlock] {
        order.compactMap { blocks[$0] }.filter { $0.releaseAt <= now }
    }
}

public enum SimulationError: Error, CustomStringConvertible {
    case malformedWorld(String)
    case invariant(String)

    public var description: String {
        switch self {
        case .malformedWorld(let detail): "malformed world: \(detail)"
        case .invariant(let detail): "invariant violated: \(detail)"
        }
    }
}

extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        replacing(parent: parent, nonce: nonce)
    }

    func replacing(parent: BlockHeader?, nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce
        )
    }
}
