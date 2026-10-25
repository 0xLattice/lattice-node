import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest
@testable import LatticeNode

/// A child connect reads its parent's continuity for the one link the node
/// derives (`ParentContinuity.read`). That restates Lattice's link rule, so
/// it must name exactly the link Lattice asks for: otherwise a child block
/// would wait on its parent forever, reconnecting each time the parent
/// executes. Lattice names the link it lacks when it knows nothing of the
/// parent; this pins the node's derivation to it, for a child genesis and a
/// child block after it.
final class ParentContinuityLinkTests: XCTestCase {
    func testTheLinkReadIsTheLinkLatticeAsksFor() async throws {
        var rng = SplitMix64(state: 0x11c4)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)
        var checked = (genesis: 0, later: 0)
        for grind in world.grinds {
            var queue: [NodeEvent] = [.mined(grind.mined)]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job):
                        // A block that executes invalid never reaches its
                        // parent facts.
                        if path.count > 1, await !Self.provesInvalid(job, world, now) {
                            let asked = await ChainTree.connect(
                                job, fetcher: world.cas, parentFacts: nil,
                                validationContext: ValidationContext(nowMilliseconds: now)
                            )
                            guard case .crossChainEvidenceRequired(
                                .parentStateContinuity(let parentPath, let from, let to)
                            )? = asked.retryFailure else {
                                return XCTFail("\(job.blockHash): \(String(describing: asked.retryFailure))")
                            }
                            let levels = host.levels
                            let read = await ParentContinuity.read(
                                of: job.blockHash, at: path, levels: LiveLevels { $0(levels) }, fetcher: world.cas
                            )
                            XCTAssertEqual(
                                read?.link,
                                ParentStateContinuityLink(parentPath: parentPath, fromStateCID: from, toStateCID: to)
                            )
                            let block = try await BlockHeader(rawCID: job.blockHash).resolve(fetcher: world.cas).node
                            if block?.parent == nil { checked.genesis += 1 } else { checked.later += 1 }
                        }
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: host.parentFacts(for: path),
                            validationContext: ValidationContext(nowMilliseconds: now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked.genesis, 0, "a child genesis was checked")
        XCTAssertGreaterThan(checked.later, 0, "a later child block was checked")
    }

    /// Whether the block executes invalid whatever its parent holds.
    private static func provesInvalid(_ job: ConnectJob, _ world: LevelWorld, _ now: Int64) async -> Bool {
        await ChainTree.connect(
            job, fetcher: world.cas, parentFacts: Everything(),
            validationContext: ValidationContext(nowMilliseconds: now)
        ).provesInvalid
    }

    /// A parent that holds every link.
    private struct Everything: ParentChainFacts {
        func hasContinuity(_ link: ParentStateContinuityLink) -> Bool { true }
    }
}
