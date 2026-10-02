import Crypto
import Foundation
import Lattice
import LatticeNodeCore
import UInt256
import cashew

/// A proof the world made, the evidence `verifySecuringWork` gives it, and
/// when it becomes public.
public struct ProofTruth: Sendable {
    public let proof: ChildBlockProof
    public let evidence: VerifiedChildEvidence
    public let releaseAt: Int64
}

/// One grind the world mined: its root and the child blocks it carries.
public struct LevelGrind: Sendable {
    public let releaseAt: Int64
    public let root: SimBlock
    /// Whether the root meets its own target (a root-chain block), rather
    /// than a share that clears only the child targets.
    public let rootIsBlock: Bool
    public let mined: MinedGrind
    /// Mined by the proof withholder: its headers are shown without proofs,
    /// whose release waits until `proofsAt`.
    public let withheld: Bool
    public let proofsAt: Int64
}

/// A child header an adversary shows: a block and one proof.
public struct LevelHeader: Sendable {
    public let path: ChainPath
    public let block: SimBlock
    public let proof: ChildBlockProof
    public let releaseAt: Int64
}

/// The generator's ground truth for two or three levels merge-mined from one
/// root chain: Nexus, Alpha under it, and Beta under Alpha. Each child
/// chain's genesis commits its carrier's entering state, a state its parent
/// level executes, and weighs by the grind that carries it. Every grind is one root: a Nexus block when its hash meets the
/// Nexus target, otherwise a share that clears only the child targets
/// (child-only history). Some child blocks are carried by a second root (two
/// grinds, deduped by root); one Alpha block has a forged post-state (it
/// weighs and its execution excludes it, with a block on it); the proof
/// withholder mines a side branch whose proofs appear late; and two headers
/// lie: one with a proof whose root misses the block's target (it carries no
/// work) and one off the timestamp schedule with a proof that weighs.
public struct LevelWorld: Sendable {
    public static let nexus: ChainPath = [DEFAULT_ROOT_DIRECTORY]
    public static let alpha: ChainPath = nexus + ["Alpha"]
    public static let beta: ChainPath = alpha + ["Beta"]
    public static let interval: Int64 = World.blockInterval

    public let paths: [ChainPath]
    public let cas: SimCAS
    public let specs: [ChainPath: ChainSpec]
    public let geneses: [ChainPath: SimBlock]
    public let rootBootstrap: GenesisBootstrap
    /// Every block a node may weigh, per level (the root's genesis included).
    public let blocks: [ChainPath: [String: SimBlock]]
    public let grinds: [LevelGrind]
    /// Per level, block and root.
    public let proofs: [ChainPath: [String: [String: ProofTruth]]]
    /// Blocks whose execution proves them invalid.
    public let invalid: [ChainPath: Set<String>]
    public let zeroWork: LevelHeader?
    public let offSchedule: LevelHeader?

    public var hosted: Set<ChainPath> { Set(paths.dropFirst()) }

    public static func specFor(_ path: ChainPath) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100 + UInt64(path.count),
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: UInt64(interval),
            initialReward: 100,
            halvingInterval: 10_000,
            halfLife: 10
        )
    }

    /// Each level's genesis target: a child target is easier than its
    /// parent's, so a share can miss Nexus and clear a child.
    public static func genesisTarget(_ path: ChainPath) -> UInt256 {
        UInt256.max >> [5, 3, 2][min(path.count - 1, 2)]
    }

    public static func generate(
        rng: inout SplitMix64,
        levels: Int,
        grinds grindCount: Int,
        forkProbability: Double,
        shareProbability: Double,
        doubleProbability: Double,
        withholdDelay: Int64
    ) async throws -> LevelWorld {
        var builder = try await Builder(levels: min(max(levels, 2), 3))
        try await builder.run(
            rng: &rng,
            grinds: max(grindCount, 12),
            forkProbability: forkProbability,
            shareProbability: shareProbability,
            doubleProbability: doubleProbability,
            withholdDelay: withholdDelay
        )
        return builder.world()
    }

    /// The released blocks of one level (a block is released with its first
    /// grind), withheld ones included only once their proofs are public.
    public func released(_ path: ChainPath, at now: Int64, withheld: Bool) -> [SimBlock] {
        (blocks[path] ?? [:]).values
            .filter { $0.releaseAt <= now && (withheld || !isWithheld(path, $0.cid)) }
            .sorted { $0.releaseAt != $1.releaseAt ? $0.releaseAt < $1.releaseAt : $0.cid < $1.cid }
    }

    public func isWithheld(_ path: ChainPath, _ cid: String) -> Bool {
        grinds.contains { grind in
            grind.withheld && (grind.mined.carried.contains { $0.path == path && Self.cid($0.block) == cid })
        }
    }

    /// The public proofs of one block.
    public func publicProofs(_ path: ChainPath, _ cid: String, at now: Int64) -> [ChildBlockProof] {
        (proofs[path]?[cid] ?? [:]).sorted { $0.key < $1.key }
            .filter { $0.value.releaseAt <= now }.map(\.value.proof)
    }

    static func cid(_ block: Block) -> String {
        (try? BlockHeader(node: block).rawCID) ?? ""
    }

    // MARK: - Building

    struct Builder {
        let paths: [ChainPath]
        let cas = SimCAS()
        let key: (privateKey: String, publicKey: String)
        let address: String
        var specs: [ChainPath: ChainSpec] = [:]
        var geneses: [ChainPath: SimBlock] = [:]
        var rootBootstrap: GenesisBootstrap!
        var blocks: [ChainPath: [String: SimBlock]] = [:]
        var grinds: [LevelGrind] = []
        var proofs: [ChainPath: [String: [String: ProofTruth]]] = [:]
        var invalid: [ChainPath: Set<String>] = [:]
        var nexusNonce: UInt64 = 0
        var zeroWork: LevelHeader?
        var offSchedule: LevelHeader?
        /// Per level: the valid blocks honest miners build on, and their work.
        var references: [ChainPath: GhostReference] = [:]
        var recent: [ChainPath: [String]] = [:]
        /// Blocks honest miners never build on (the invalid branch, the
        /// withheld branch).
        var avoided: Set<String> = []
        var nonce: UInt64 = 0

        init(levels: Int) async throws {
            paths = Array([LevelWorld.nexus, LevelWorld.alpha, LevelWorld.beta].prefix(levels))
            // A fixed key, so the world's content is the same on every run
            // where signing is deterministic.
            let secret = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x5A, count: 32))
            let privateKey = secret.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            let publicKey = "ed01" + secret.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            key = (privateKey, publicKey)
            address = CryptoUtils.createAddress(from: publicKey)
            try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
            for path in paths { specs[path] = LevelWorld.specFor(path) }
            let genesis = World.mined(try await BlockBuilder.buildGenesis(
                spec: specs[LevelWorld.nexus]!,
                timestamp: World.genesisTime,
                target: LevelWorld.genesisTarget(LevelWorld.nexus),
                fetcher: cas
            ))
            let stored = try await store(genesis, releaseAt: World.genesisTime, anchor: nil)
            geneses[LevelWorld.nexus] = stored
            blocks[LevelWorld.nexus, default: [:]][stored.cid] = stored
            var reference = GhostReference(genesis: stored.cid)
            reference.add(stored.cid, parent: nil, work: workForTarget(genesis.target))
            references[LevelWorld.nexus] = reference
            recent[LevelWorld.nexus] = [stored.cid]
            rootBootstrap = try await ChainTree.bootstrap(
                genesis: BlockHeader(node: stored.block),
                fetcher: cas,
                context: try ChainRuntimeContext(path: LevelWorld.nexus, genesisCID: stored.cid),
                validationContext: ValidationContext(nowMilliseconds: World.genesisTime)
            ).get()
        }

        func world() -> LevelWorld {
            LevelWorld(
                paths: paths, cas: cas, specs: specs, geneses: geneses, rootBootstrap: rootBootstrap,
                blocks: blocks, grinds: grinds, proofs: proofs, invalid: invalid, zeroWork: zeroWork, offSchedule: offSchedule
            )
        }

        /// A child chain's genesis committing `parentState` (its carrier's
        /// entering state), dated `time`: its reference starts with it, and
        /// the grind that carries it weighs it.
        mutating func childGenesis(_ path: ChainPath, parentState: String, at time: Int64) async throws -> SimBlock {
            let genesis = try await BlockBuilder.buildChildGenesis(
                spec: specs[path]!, parentState: LatticeStateHeader(rawCID: parentState),
                timestamp: time, target: LevelWorld.genesisTarget(path), fetcher: cas
            )
            let stored = try await store(genesis, releaseAt: time, anchor: nil)
            geneses[path] = stored
            references[path] = GhostReference(genesis: stored.cid)
            recent[path] = []
            return stored
        }

        func store(_ block: Block, releaseAt: Int64, anchor: DifficultyAnchor?) async throws -> SimBlock {
            // The block's transactions (World.record stores its own Volume,
            // spec and post-state).
            if block.transactions.node != nil {
                try await block.transactions.storeRecursively(storer: cas)
            }
            return try await World.record(block, releaseAt: releaseAt, anchor: anchor, in: cas)
        }

        /// A block on `parent` of its level, bound to its carrier's entering
        /// state, with every ancestor node detached.
        func build(
            on parent: SimBlock,
            carrierPrevState: String?,
            transactions: [Transaction] = [],
            children: [String: Block] = [:],
            timestamp: Int64,
            nonce: UInt64
        ) async throws -> SimBlock {
            for transaction in transactions {
                try await VolumeImpl<Transaction>(node: transaction).storeRecursively(storer: cas as any VolumeStorer)
            }
            let built = try await BlockBuilder.buildBlock(
                previous: parent.block,
                transactions: transactions,
                children: children,
                timestamp: timestamp,
                nonce: nonce,
                difficultyAnchor: parent.anchor,
                rewardRecipient: address,
                fetcher: cas
            )
            let block = built.with(
                parent: built.parent?.removingNode(),
                parentState: carrierPrevState.map { LatticeStateHeader(rawCID: $0) }
            )
            let anchor = parent.anchor
                ?? DifficultyAnchor(blockHeight: 1, timestamp: block.timestamp, target: block.target)
            return try await store(block, releaseAt: timestamp, anchor: anchor)
        }

        /// The first nonce after the builder's counter whose root hash
        /// satisfies `accept`.
        mutating func mine(_ block: Block, _ accept: (UInt256) -> Bool) -> Block {
            while true {
                nonce &+= 1
                let candidate = block.with(nonce: nonce)
                if accept(candidate.proofOfWorkHash()) { return candidate }
            }
        }

        mutating func parent(_ path: ChainPath, rng: inout SplitMix64, forkProbability: Double) -> SimBlock {
            let head = references[path]!.head
            var choice = head
            if rng.chance(forkProbability) {
                let options = recent[path]!.suffix(6).filter { !avoided.contains($0) }
                if !options.isEmpty { choice = options[rng.draw(0...options.count - 1)] }
            }
            return blocks[path]![avoided.contains(choice) ? head : choice]!
        }

        enum Outcome {
            case block
            case share
            case zeroWork
        }

        /// Mine a root on `nexusParent` carrying `carried` (outermost child
        /// first), record it, and make each carried block's proof.
        mutating func grind(
            on nexusParent: SimBlock,
            carrying carried: [(path: ChainPath, block: SimBlock)],
            transactions: [Transaction] = [],
            at time: Int64,
            outcome: Outcome,
            proofsAt: Int64? = nil,
            withheld: Bool = false,
            truth: Bool = true
        ) async throws -> (root: SimBlock, grind: MinedGrind, proofs: [(ChainPath, ProofTruth)]) {
            let unmined = try await build(
                on: nexusParent, carrierPrevState: nil, transactions: transactions,
                children: carried.first.map { [$0.path[1]: $0.block.block] } ?? [:],
                timestamp: time, nonce: 0
            )
            let targets = carried.map(\.block.block.target)
            let rootTarget = unmined.block.target
            let mined = mine(unmined.block) { hash in
                switch outcome {
                case .block: rootTarget >= hash && targets.allSatisfy { $0 >= hash }
                case .share: hash > rootTarget && targets.allSatisfy { $0 >= hash }
                case .zeroWork: hash > rootTarget && targets.allSatisfy { $0 < hash }
                }
            }
            let root = try await store(mined, releaseAt: time, anchor: unmined.anchor)
            var made: [(ChainPath, ProofTruth)] = []
            var carriedOut: [MinedGrind.Carried] = []
            var proof: ChildBlockProof?
            var carrier = root.block
            for (path, block) in carried {
                let hop = try await ChildBlockProof.generate(
                    rootHeader: BlockHeader(node: carrier), childDirectory: path[path.count - 1], fetcher: cas
                )
                let composed = proof.map { $0.composing(hop: hop) } ?? hop
                proof = composed
                carrier = block.block
                let evidence = try await composed.verifySecuringWork(child: block.block, chainPath: path).get()
                if outcome != .zeroWork, evidence.contribution == nil {
                    throw SimulationError.malformedWorld("a mined proof carries no work")
                }
                made.append((path, ProofTruth(proof: composed, evidence: evidence, releaseAt: proofsAt ?? time)))
                carriedOut.append(MinedGrind.Carried(
                    path: path, block: block.block, children: block.children, proof: composed, evidence: evidence
                ))
            }
            let grind = MinedGrind(root: root.block, rootChildren: root.children, carried: carriedOut)
            if outcome != .zeroWork, truth {
                grinds.append(LevelGrind(
                    releaseAt: time, root: root, rootIsBlock: outcome == .block, mined: grind,
                    withheld: withheld, proofsAt: proofsAt ?? time
                ))
                if outcome == .block {
                    admit(root, at: LevelWorld.nexus, grind: root.cid, work: workForTarget(root.block.target))
                }
                for (path, truth) in made {
                    let cid = WorldCID.of(truth.evidence)
                    proofs[path, default: [:]][cid, default: [:]][truth.proof.rootCID] = truth
                    if let block = carried.first(where: { $0.path == path })?.block {
                        admit(block, at: path, grind: root.cid, work: truth.evidence.contribution?.work ?? .zero)
                    }
                }
            }
            return (root, grind, made)
        }

        /// Record a block (or another grind at a held one) as weighable.
        mutating func admit(_ block: SimBlock, at path: ChainPath, grind: String, work: UInt256) {
            if blocks[path]?[block.cid] == nil {
                blocks[path, default: [:]][block.cid] = block
                recent[path, default: []].append(block.cid)
            }
            if !avoided.contains(block.cid) {
                references[path]?.add(block.cid, parent: block.parent, grinds: [grind: work])
            }
        }

        mutating func run(
            rng: inout SplitMix64,
            grinds count: Int,
            forkProbability: Double,
            shareProbability: Double,
            doubleProbability: Double,
            withholdDelay: Int64
        ) async throws {
            let alphaStart = 3
            let betaStart = 5
            let invalidAt = count / 2
            let withheldAt = 2 * count / 3
            let lieAt = count / 3
            for index in 1...count {
                let time = World.genesisTime + Int64(index) * LevelWorld.interval
                let nexusParent = parent(LevelWorld.nexus, rng: &rng, forkProbability: index <= alphaStart ? 0 : forkProbability)
                var carried: [(path: ChainPath, block: SimBlock)] = []
                if index >= alphaStart {
                    carried = try await carriedBlocks(
                        nexusParent: nexusParent, index: index, betaStart: betaStart,
                        time: time, rng: &rng, forkProbability: forkProbability
                    )
                }
                let outcome: Outcome = !carried.isEmpty && rng.chance(shareProbability) ? .share : .block
                _ = try await grind(on: nexusParent, carrying: carried, at: time, outcome: outcome)
                if !carried.isEmpty, rng.chance(doubleProbability) {
                    _ = try await grind(on: nexusParent, carrying: carried, at: time + 1, outcome: .share)
                }
                if index == invalidAt { try await invalidBranch(at: time, rng: &rng) }
                if index == withheldAt { try await withheldBranch(at: time, delay: withholdDelay) }
                if index == lieAt { try await lies(at: time) }
            }
        }

        /// The blocks one honest grind carries: an Alpha block (the first is
        /// Alpha's genesis) and, once Beta runs, a Beta block in it (the
        /// first is Beta's genesis). A genesis commits its carrier's
        /// entering state.
        mutating func carriedBlocks(
            nexusParent: SimBlock,
            index: Int,
            betaStart: Int,
            time: Int64,
            rng: inout SplitMix64,
            forkProbability: Double
        ) async throws -> [(path: ChainPath, block: SimBlock)] {
            guard geneses[LevelWorld.alpha] != nil else {
                let genesis = try await childGenesis(
                    LevelWorld.alpha, parentState: nexusParent.block.postState.rawCID, at: time
                )
                return [(LevelWorld.alpha, genesis)]
            }
            let alphaParent = parent(LevelWorld.alpha, rng: &rng, forkProbability: index <= betaStart ? 0 : forkProbability)
            var betaBlock: SimBlock?
            if paths.count > 2, index >= betaStart {
                if geneses[LevelWorld.beta] == nil {
                    betaBlock = try await childGenesis(
                        LevelWorld.beta, parentState: alphaParent.block.postState.rawCID, at: time
                    )
                } else {
                    let betaParent = parent(LevelWorld.beta, rng: &rng, forkProbability: forkProbability)
                    betaBlock = try await build(
                        on: betaParent, carrierPrevState: alphaParent.block.postState.rawCID,
                        timestamp: time, nonce: UInt64(index)
                    )
                }
            }
            let alphaBlock = try await build(
                on: alphaParent,
                carrierPrevState: nexusParent.block.postState.rawCID,
                children: betaBlock.map { [LevelWorld.beta[2]: $0.block] } ?? [:],
                timestamp: time,
                nonce: UInt64(index)
            )
            return [(LevelWorld.alpha, alphaBlock)] + (betaBlock.map { [(LevelWorld.beta, $0)] } ?? [])
        }

        /// An Alpha block with a forged post-state, and a block on it, each
        /// carried by its own share: both weigh; execution excludes the first.
        mutating func invalidBranch(at time: Int64, rng: inout SplitMix64) async throws {
            let nexusParent = blocks[LevelWorld.nexus]![references[LevelWorld.nexus]!.head]!
            let alphaParent = blocks[LevelWorld.alpha]![references[LevelWorld.alpha]!.head]!
            let carrierPrev = nexusParent.block.postState.rawCID
            let twin = try await build(on: alphaParent, carrierPrevState: carrierPrev, timestamp: time + 200, nonce: 0xBAD)
            let forged = twin.block.with(postState: LatticeStateHeader(rawCID: geneses[LevelWorld.nexus]!.cid))
            let bad = try await store(forged, releaseAt: time + 200, anchor: twin.anchor)
            let template = try await build(on: twin, carrierPrevState: carrierPrev, timestamp: time + 400, nonce: 0xBAD)
            let onBad = try await store(template.block.with(
                parent: try BlockHeader(node: bad.block).removingNode(),
                prevState: bad.block.postState,
                postState: bad.block.postState
            ), releaseAt: time + 400, anchor: template.anchor)
            avoided.formUnion([bad.cid, onBad.cid])
            invalid[LevelWorld.alpha, default: []].insert(bad.cid)
            _ = try await grind(on: nexusParent, carrying: [(LevelWorld.alpha, bad)], at: time + 200, outcome: .share)
            _ = try await grind(on: nexusParent, carrying: [(LevelWorld.alpha, onBad)], at: time + 400, outcome: .share)
        }

        /// The withholder's two-block Alpha side branch: its headers show at
        /// once, its proofs only `delay` later.
        mutating func withheldBranch(at time: Int64, delay: Int64) async throws {
            let nexusParent = blocks[LevelWorld.nexus]![references[LevelWorld.nexus]!.head]!
            var tip = blocks[LevelWorld.alpha]![references[LevelWorld.alpha]!.head]!
            let carrierPrev = nexusParent.block.postState.rawCID
            for step in 1...2 {
                let at = time + 300 + Int64(step)
                let block = try await build(on: tip, carrierPrevState: carrierPrev, timestamp: at, nonce: 0x5EED)
                avoided.insert(block.cid)
                _ = try await grind(
                    on: nexusParent, carrying: [(LevelWorld.alpha, block)], at: at, outcome: .share,
                    proofsAt: at + delay, withheld: true
                )
                tip = block
            }
        }

        /// A header with a proof that carries no work, and one off the
        /// timestamp schedule with a proof that weighs.
        mutating func lies(at time: Int64) async throws {
            let nexusParent = blocks[LevelWorld.nexus]![references[LevelWorld.nexus]!.head]!
            let alphaParent = blocks[LevelWorld.alpha]![references[LevelWorld.alpha]!.head]!
            let carrierPrev = nexusParent.block.postState.rawCID
            let empty = try await build(on: alphaParent, carrierPrevState: carrierPrev, timestamp: time + 500, nonce: 0xF00)
            let fabricated = try await grind(
                on: nexusParent, carrying: [(LevelWorld.alpha, empty)], at: time + 500, outcome: .zeroWork
            )
            zeroWork = LevelHeader(path: LevelWorld.alpha, block: empty, proof: fabricated.proofs[0].1.proof, releaseAt: time + 500)
            let late = try await build(
                on: alphaParent, carrierPrevState: carrierPrev,
                timestamp: alphaParent.block.timestamp, nonce: 0x0FF
            )
            let offGrind = try await grind(
                on: nexusParent, carrying: [(LevelWorld.alpha, late)], at: time + 600, outcome: .share, truth: false
            )
            offSchedule = LevelHeader(path: LevelWorld.alpha, block: late, proof: offGrind.proofs[0].1.proof, releaseAt: time + 600)
        }
    }
}

enum WorldCID {
    static func of(_ evidence: VerifiedChildEvidence) -> String {
        CIDIdentity.canonicalString(evidence.childCID) ?? evidence.childCID
    }
}

extension Block {
    /// This block with the given fields replaced.
    func with(
        parent newParent: BlockHeader?? = nil,
        parentState newParentState: LatticeStateHeader? = nil,
        prevState newPrevState: LatticeStateHeader? = nil,
        postState newPostState: LatticeStateHeader? = nil,
        nonce newNonce: UInt64? = nil
    ) -> Block {
        Block(
            version: version,
            parent: newParent ?? parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: newParentState ?? parentState,
            prevState: newPrevState ?? prevState,
            postState: newPostState ?? postState,
            children: children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: newNonce ?? nonce
        )
    }
}
