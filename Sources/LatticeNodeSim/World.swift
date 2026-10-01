import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import Synchronization
import UInt256
import cashew

/// An in-memory content store the world builds blocks into and bootstraps
/// the genesis from.
public final class SimCAS: Fetcher, Storer, VolumeStorer, Sendable {
    private let entries = Mutex<[String: Data]>([:])

    public init(_ initial: [String: Data] = [:]) {
        entries.withLock { $0 = initial }
    }

    public func put(_ new: [String: Data]) {
        entries.withLock { $0.merge(new) { _, latest in latest } }
    }

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

    /// Every entry held, by CID.
    public var all: [String: Data] {
        entries.withLock { $0 }
    }

    public func contains(_ cid: String) -> Bool {
        entries.withLock { $0[cid] != nil }
    }

    public func removeAll(_ cids: some Sequence<String>) {
        entries.withLock { held in for cid in cids { held[cid] = nil } }
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
    /// Its body: the block Volume and its transactions, by CID — what the
    /// content layer delivers for `fetchBody`.
    public let body: [String: Data]
}

/// The kinds of lie the liar tells. The first three prove no work the chain
/// accepts (blame); the last two are weighed and excluded (never blame).
public enum Lie: CaseIterable, Sendable {
    case failedProofOfWork
    case offScheduleTarget
    case offScheduleTimestamp
    case wrongSpec
    case wrongPrevState
}

/// The generator's ground truth: the chain spec, the bootstrapped genesis,
/// the honest block tree in release order, a low-work spam fork, garbage, and
/// the liar's headers.
public struct World: Sendable {
    public static let genesisTime: Int64 = 1_700_000_000_000
    public static let blockInterval: Int64 = 1_000
    /// When the spam fork's second block is dated: far enough behind its
    /// schedule (4.9 half-lives) that ASERT makes every later spam target
    /// saturate toward the easiest the schedule allows.
    public static let spamLateBlockTime: Int64 = genesisTime + 50_000

    public let spec: ChainSpec
    public let context: ChainRuntimeContext
    public let genesis: SimBlock
    public let bootstrap: GenesisBootstrap
    public let blocks: [String: SimBlock]
    /// Honest blocks in release order.
    public let honest: [String]
    /// The spam fork from genesis, in order: valid proof-of-work at the
    /// easiest target the schedule allows.
    public let spam: [String]
    /// Headers whose parents are never served, each at the maximum target
    /// (any hash meets it): garbage that proves almost no work.
    public let garbage: [String]
    /// A block that is never served, and a header on it.
    public let withheld: String
    public let orphan: String
    /// An honest side block only the uncle script shows, to one node.
    public let uncle: String
    /// The liar's headers, each on an honest block.
    public let lies: [Lie: String]
    /// A header linked to the wrong-prevState lie: weighed, never selected.
    public let excludedChild: String
    /// Ground truth: the blocks a node must weigh and exclude.
    public let excluded: Set<String>
    /// A block with valid proof-of-work and header linkage whose body fails
    /// execution (its declared post-state is not the one it produces), and
    /// a block on it: weighed, then excluded by whoever executes it.
    public let invalidBody: String
    public let invalidBodyChild: String
    /// Ground truth: the blocks whose execution proves them invalid.
    public let invalidBodies: Set<String>
    /// What every node holds from the start: the genesis block, its spec
    /// and its states.
    public let genesisContent: [String: Data]
    /// For a split world: the honest blocks each side mines while
    /// partitioned (the common prefix included), lighter side first.
    public let sides: [[String]]

    public static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: UInt64(blockInterval),
        initialReward: 100,
        halvingInterval: 10_000,
        halfLife: 10
    )

    /// One hash in 32 meets the genesis target: a tampered header almost
    /// always fails proof-of-work.
    public static let genesisTarget = UInt256.max >> 5

    /// Generate a world: `honestBlocks` honest blocks, each on the current
    /// GHOST head or, with `forkProbability`, on any of the last eight blocks
    /// generated (side branches included), every third committing a child
    /// index and every seventh one too big to travel inline; an uncle; the
    /// liar's headers; `garbage` orphans; and a `spamBlocks`-long
    /// ASERT-saturation fork from genesis (block 2 dated far behind schedule,
    /// the rest right after it, at saturated targets).
    public static func generate(
        rng: inout SplitMix64,
        honestBlocks: Int,
        forkProbability: Double,
        spamBlocks: Int,
        garbage garbageCount: Int = 16,
        honestInterval: Int64 = blockInterval,
        stall: (afterBlock: Int, milliseconds: Int64)? = nil,
        genesisActions: Bool = false,
        sideLeaves: Int = 0,
        split: (lighter: Int, heavier: Int)? = nil
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
        for index in 1...max(honestBlocks, 3) {
            var parent = reference.head
            if rng.chance(forkProbability) {
                let recent = [genesis.cid] + honest.suffix(8)
                parent = recent[rng.draw(0...recent.count - 1)]
            }
            var time = genesisTime + Int64(index) * honestInterval
            if let stall, index > stall.afterBlock {
                time += stall.milliseconds
            }
            let childCount = index % 7 == 0 ? 48 : index % 3 == 0 ? 1 : 0
            let children = Dictionary(uniqueKeysWithValues: (0..<childCount).map {
                ("Child\(index)-\($0)", genesis.block)
            })
            // Every honest block pays its reward, so each execution produces
            // a new state. With `genesisActions`, every other block also
            // authorizes a child genesis and issues a link (signatures are
            // not deterministic on every platform, so the simulator's worlds
            // leave them out).
            let transactions = genesisActions && index % 2 == 0
                ? [try genesisAction(index: index, childGenesis: genesis.cid)] : []
            let next = try await extend(
                blocks[parent]!, timestamp: time, nonce: UInt64(index) << 32, children: children,
                transactions: transactions, rewardRecipient: miner, in: cas
            )
            blocks[next.cid] = next
            honest.append(next.cid)
            reference.add(next.cid, parent: parent, work: workForTarget(next.block.target))
        }

        // Side leaves: one honest side block on each of `sideLeaves` honest
        // blocks, dated half an interval after its parent.
        let main = honest
        for index in 0..<min(sideLeaves, main.count) {
            let parent = blocks[main[index * main.count / max(sideLeaves, 1)]]!
            let leaf = try await extend(
                parent, timestamp: parent.block.timestamp + honestInterval / 2,
                nonce: (UInt64(index) << 32) | 0x1EAF, in: cas
            )
            blocks[leaf.cid] = leaf
            honest.append(leaf.cid)
        }
        // A split: from the honest tip, a lighter side on schedule and a
        // heavier side mined faster over the same span (ASERT hardens it).
        var sides: [[String]] = []
        if let split {
            let fork = blocks[reference.head]!
            let common = bestChain(of: honest.compactMap { blocks[$0] }, genesis: genesis).map(\.cid)
            let span = Int64(split.lighter) * honestInterval
            for (side, count) in [split.lighter, split.heavier].enumerated() {
                var tip = fork
                var chain = common
                for index in 1...count {
                    tip = try await extend(
                        tip, timestamp: fork.block.timestamp + span * Int64(index) / Int64(count),
                        nonce: (UInt64(index) << 32) | UInt64(0x5_1D0 + side), in: cas
                    )
                    blocks[tip.cid] = tip
                    honest.append(tip.cid)
                    chain.append(tip.cid)
                }
                sides.append(chain)
            }
        }
        honest.sort { blocks[$0]!.releaseAt != blocks[$1]!.releaseAt
            ? blocks[$0]!.releaseAt < blocks[$1]!.releaseAt : $0 < $1 }

        var spam: [String] = []
        var spamTip = genesis
        for index in 0..<max(spamBlocks, 2) {
            let time = index == 0
                ? genesisTime + blockInterval
                : spamLateBlockTime + Int64(index - 1)
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
        blocks[withheld.cid] = withheld
        blocks[orphan.cid] = orphan
        var garbage: [String] = []
        for index in 0..<garbageCount {
            let unseen = try await extend(
                genesis, timestamp: genesisTime + 3, nonce: (UInt64(index) << 32) | 0x6A6, in: cas
            )
            // Every other one commits a child index too big to travel inline.
            let children = index % 2 == 0 ? [:] : Dictionary(uniqueKeysWithValues: (0..<48).map {
                ("Junk\(index)-\($0)", genesis.block)
            })
            let junk = try await extend(
                unseen, timestamp: genesisTime + 4, nonce: UInt64(index) << 32,
                children: children, target: .max, in: cas
            )
            blocks[junk.cid] = junk
            garbage.append(junk.cid)
        }
        let uncleParent = blocks[honest[2]]?.parent ?? genesis.cid
        let uncle = try await extend(
            blocks[uncleParent]!, timestamp: genesisTime + 2_500, nonce: 0x0CE1 << 32, in: cas
        )
        blocks[uncle.cid] = uncle

        // The liar's headers hang off honest block 2, dated just after it.
        let base = blocks[honest[1]]!
        let time = base.block.timestamp + 100
        var lies: [Lie: SimBlock] = [:]
        lies[.failedProofOfWork] = try await extend(base, timestamp: time, nonce: 0x1_1E << 32, in: cas)
            .forged(in: cas)
        lies[.offScheduleTarget] = try await extend(
            base, timestamp: time, nonce: 0x2_1E << 32,
            target: base.block.nextTarget << 2, in: cas
        )
        lies[.offScheduleTimestamp] = try await extend(
            base, timestamp: base.block.timestamp, nonce: 0x3_1E << 32, in: cas
        ).releasing(at: time, in: cas)
        let otherSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 99,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: UInt64(blockInterval),
            initialReward: 100,
            halvingInterval: 10_000,
            halfLife: 10
        )
        let honestShaped = try await extend(base, timestamp: time, nonce: 0x4_1E << 32, in: cas)
        lies[.wrongSpec] = try await record(
            mined(honestShaped.block.replacing(spec: try VolumeImpl<ChainSpec>(node: otherSpec))),
            releaseAt: time, anchor: honestShaped.anchor, in: cas
        )
        lies[.wrongPrevState] = try await record(
            mined(honestShaped.block.replacing(prevState: LatticeStateHeader(rawCID: genesis.cid))),
            releaseAt: time, anchor: honestShaped.anchor, in: cas
        )
        let excludedChild = try await extend(
            lies[.wrongPrevState]!, timestamp: time + 100, nonce: 0x5_1E << 32, in: cas
        )
        for lie in lies.values { blocks[lie.cid] = lie }
        blocks[excludedChild.cid] = excludedChild

        // The invalid body hangs off honest block 2 like the lies, dated just
        // after it, and a block on it makes its branch the heavier for a
        // while: it declares a post-state (a CID that is no state) which
        // executing it does not produce. The block on it links to that
        // post-state.
        let honestBody = try await extend(base, timestamp: time, nonce: 0x6_1E << 32, in: cas)
        let declared = LatticeStateHeader(rawCID: genesis.cid)
        let invalidBody = try await record(
            mined(honestBody.block.replacing(postState: declared)),
            releaseAt: time, anchor: honestBody.anchor, in: cas
        )
        let honestChild = try await extend(honestBody, timestamp: time + 100, nonce: 0x7_1E << 32, in: cas)
        let invalidBodyChild = try await record(
            mined(honestChild.block.replacing(
                parent: try BlockHeader(node: invalidBody.block).removingNode(),
                prevState: declared
            )),
            releaseAt: time + 100, anchor: honestChild.anchor, in: cas
        )
        blocks[invalidBody.cid] = invalidBody
        blocks[invalidBodyChild.cid] = invalidBodyChild

        return World(
            spec: spec,
            context: context,
            genesis: genesis,
            bootstrap: bootstrap,
            blocks: blocks,
            honest: honest,
            spam: spam,
            garbage: garbage,
            withheld: withheld.cid,
            orphan: orphan.cid,
            uncle: uncle.cid,
            lies: lies.mapValues(\.cid),
            excludedChild: excludedChild.cid,
            excluded: [lies[.wrongSpec]!.cid, lies[.wrongPrevState]!.cid],
            invalidBody: invalidBody.cid,
            invalidBodyChild: invalidBodyChild.cid,
            invalidBodies: [invalidBody.cid],
            genesisContent: try await content(of: genesis.block, states: true),
            sides: sides
        )
    }

    static func extend(
        _ parent: SimBlock,
        timestamp: Int64,
        nonce: UInt64,
        children: [String: Block] = [:],
        transactions: [Transaction] = [],
        target: UInt256? = nil,
        rewardRecipient: String? = nil,
        in cas: SimCAS
    ) async throws -> SimBlock {
        let built = try await BlockBuilder.buildBlock(
            previous: parent.block,
            transactions: transactions,
            children: children,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            difficultyAnchor: parent.anchor,
            rewardRecipient: rewardRecipient,
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
            anchor: anchor,
            body: try await content(of: block, states: false)
        )
    }

    /// A block's own content: its Volume and its transactions, and with
    /// `states` its spec and its declared states too.
    static func content(of block: Block, states: Bool) async throws -> [String: Data] {
        let cas = SimCAS()
        try await BlockHeader(node: block).store(paths: [:], storer: cas as any VolumeStorer)
        if block.transactions.node != nil {
            try await block.transactions.storeRecursively(storer: cas)
        }
        if states {
            try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
            try await block.spec.storeRecursively(storer: cas as any VolumeStorer)
            if block.postState.node != nil {
                try await block.postState.storeRecursively(storer: cas as any VolumeStorer)
            }
        }
        return cas.all
    }

    /// The honest miners' reward address.
    static let miner = CryptoUtils.createAddress(from: "ed01" + String(repeating: "5a", count: 32))

    /// A signed transaction whose one `GenesisAction` authorizes a child
    /// chain, from a signer derived from `index` (the same world, the same
    /// bytes).
    static func genesisAction(index: Int, childGenesis: String) throws -> Transaction {
        var seed = [UInt8](repeating: 0x5A, count: 32)
        withUnsafeBytes(of: UInt64(index).bigEndian) { seed.replaceSubrange(24..<32, with: $0) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = "ed01" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let privateKey = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Kid\(index)", blockCID: childGenesis)],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: publicKey)], nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: privateKey),
              let preimage = TransactionSigning.preimage(bodyHeader: bodyHeader),
              CryptoUtils.verify(message: preimage, signature: signature, publicKeyHex: publicKey) else {
            throw SimulationError.malformedWorld("genesis action \(index) does not sign")
        }
        return Transaction(signatures: [publicKey: signature], body: bodyHeader)
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
    /// child index of `entries` entries.
    public func carriers(count: Int, entries: Int = 1) async throws -> [SimBlock] {
        let cas = SimCAS()
        var carriers: [SimBlock] = []
        for index in 0..<count {
            let children = Dictionary(uniqueKeysWithValues: (0..<entries).map {
                ("Carried\(index)-\($0)", genesis.block)
            })
            carriers.append(try await World.extend(
                genesis,
                timestamp: World.genesisTime + World.blockInterval,
                nonce: UInt64(index) << 40,
                children: children,
                in: cas
            ))
        }
        return carriers
    }

    /// `count` blocks extending `parent`, one `interval` apart after it: a
    /// side branch built beside the world's own blocks.
    public func branch(from parent: SimBlock, count: Int, interval: Int64 = World.blockInterval) async throws -> [SimBlock] {
        let cas = SimCAS()
        var tip = parent
        var branch: [SimBlock] = []
        for index in 0..<count {
            tip = try await World.extend(
                tip,
                timestamp: tip.block.timestamp + interval,
                nonce: (UInt64(index) << 36) | 0xB7A,
                in: cas
            )
            branch.append(tip)
        }
        return branch
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

extension SimBlock {
    /// The same block with a nonce that misses its target.
    func forged(in cas: SimCAS) async throws -> SimBlock {
        try await World.record(World.forged(block), releaseAt: releaseAt, anchor: anchor, in: cas)
    }

    func releasing(at time: Int64, in cas: SimCAS) async throws -> SimBlock {
        try await World.record(block, releaseAt: time, anchor: anchor, in: cas)
    }
}

extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        replacing(parent: parent, nonce: nonce)
    }

    func replacing(
        parent: BlockHeader? = nil,
        nonce: UInt64? = nil,
        spec newSpec: VolumeImpl<ChainSpec>? = nil,
        prevState newPrevState: LatticeStateHeader? = nil,
        postState newPostState: LatticeStateHeader? = nil
    ) -> Block {
        Block(
            version: version,
            parent: parent ?? self.parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: newSpec ?? spec,
            parentState: parentState,
            prevState: newPrevState ?? prevState,
            postState: newPostState ?? postState,
            children: children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce ?? self.nonce
        )
    }
}
