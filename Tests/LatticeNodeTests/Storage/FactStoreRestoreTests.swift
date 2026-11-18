import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
@testable import LatticeNode

/// state.db keeps each fact once, by id, at the staged batch that first held
/// it. A host's every step written through it and read back restores the
/// trees the host built and its weigh logs entry for entry: a peer's stream
/// cursor resumes at the same position after a restart. Every credited
/// proof, kept as the CIDs of its entries, reads back byte for byte.
final class FactStoreRestoreTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000

    func testARestoreFromTheFactStoreKeepsEveryTreeAndLogPosition() async throws {
        for seed: UInt64 in [0x1_0A61, 0x5EED, 0xFAC7] {
            var rng = SplitMix64(state: seed)
            let world = try await LevelWorld.generate(
                rng: &rng, levels: 3, grinds: 60, forkProbability: 0.3, shareProbability: 0.2,
                doubleProbability: 0.3, withholdDelay: 1_000
            )
            let path = temporaryDirectory(create: true).appendingPathComponent("state.db")
            let store = try NodeStore(databasePath: path, nexusGenesisCID: "sim")
            try await store.stageChainFacts([world.rootBootstrap.facts], logID: "log", at: LevelWorld.nexus)
            var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)
            var specs: [ChainPath: [ChainSpec]] = [:]
            var proofs: [ChainPath: [StoredProof]] = [:]
            var staged: [ChainPath: Int] = [LevelWorld.nexus: world.rootBootstrap.facts.facts.count]
            for grind in world.grinds {
                for batch in try await run(&host, .mined(grind.mined), world) {
                    try await store.stageNodeFacts(batch.levels.map { level in
                        NodeFactBatch(
                            path: level.path, facts: level.batch.facts, headers: level.batch.headers,
                            proofs: level.batch.proofs, cursors: level.batch.cursors
                        )
                    }, logID: "log")
                    for level in batch.levels {
                        specs[level.path, default: []] += level.batch.headers.compactMap(\.spec)
                        proofs[level.path, default: []] += level.batch.proofs
                        staged[level.path, default: 0] += level.batch.facts.flatMap(\.facts).count
                    }
                }
            }

            let reopened = try NodeStore(databasePath: path, nexusGenesisCID: "sim")
            var stored: [ChainPath: StoredFacts] = [:]
            for level in world.paths {
                stored[level] = try await reopened.storedFacts(at: level)
            }
            let restored = try NodeCore.restore(
                root: try ChainCore.restore(
                    stored[LevelWorld.nexus] ?? .empty, context: try XCTUnwrap(world.rootBootstrap.tree.context),
                    specs: [try XCTUnwrap(world.specs[LevelWorld.nexus])]
                ),
                facts: stored, specs: specs, hosted: world.hosted
            )
            XCTAssertEqual(Set(restored.levels.keys), Set(host.levels.keys), "seed \(seed)")
            for (level, live) in host.levels {
                let rebuilt = try XCTUnwrap(restored.levels[level])
                XCTAssertEqual(rebuilt.sync.log.entries, live.sync.log.entries, "seed \(seed) \(level): log positions")
                XCTAssertEqual(TreeDigest(rebuilt.tree), TreeDigest(live.tree), "seed \(seed) \(level): tree")
                XCTAssertGreaterThanOrEqual(
                    rebuilt.tree.currentRevision(), live.tree.currentRevision(), "seed \(seed) \(level): the revision never moves back"
                )
                let facts = try XCTUnwrap(stored[level])
                XCTAssertEqual(Set(facts.facts.map(\.id)).count, facts.facts.count, "seed \(seed) \(level): each fact once")
                // Fixture guard: executions re-stated facts, which the store
                // keeps once.
                XCTAssertLessThan(facts.facts.count, staged[level] ?? 0, "seed \(seed) \(level)")
            }
            XCTAssertTrue(
                host.levels[LevelWorld.alpha]?.sync.log.entries.contains { $0.kind == .proof } ?? false,
                "fixture guard: the child level logged proofs"
            )

            var entries = Set<String>()
            for (level, written) in proofs {
                let read = try reopened.savedProofs(at: level, for: written.map(\.childCID))
                for stored in written {
                    let served = try XCTUnwrap(
                        read[stored.childCID]?.first { $0.rootCID == stored.proof.rootCID },
                        "seed \(seed) \(level): \(stored.childCID) by \(stored.proof.rootCID)"
                    )
                    XCTAssertEqual(try served.serialize(), try stored.proof.serialize(), "seed \(seed) \(level): the proof's bytes")
                    entries.formUnion(stored.proof.entries.map(\.cid))
                }
            }
            XCTAssertTrue(proofs[LevelWorld.beta]?.isEmpty == false, "fixture guard: a grandchild's proofs are composed")
            let kept = try await reopened.database.rows(from: "proof_entries", "SELECT cid FROM proof_entries").count
            XCTAssertLessThan(kept, entries.count, "seed \(seed): entries the header tables hold are not kept again")
        }
    }

    /// Step `event` and everything it leads to: bodies are all held, and
    /// every connect runs. Returns the batches the steps persisted, in order.
    private func run(_ host: inout NodeCore, _ event: NodeEvent, _ world: LevelWorld) async throws -> [NodeBatch] {
        var persisted: [NodeBatch] = []
        var queue = [event]
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: Self.now) {
                switch effect {
                case .persist(let batch):
                    persisted.append(batch)
                case .level(let path, .fetchBody(let cid)):
                    queue.append(.level(path, .bodyFetched(cid: cid)))
                case .connect(let path, let jobs):
                    queue.append(.level(path, await ConnectRun.connected(
                        jobs, fetcher: world.cas, parentFacts: host.parentFacts(for: path), now: Self.now
                    )))
                default:
                    break
                }
            }
        }
        return persisted
    }
}
