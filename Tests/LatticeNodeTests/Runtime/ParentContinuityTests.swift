import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest
@testable import LatticeNode

/// A child connect's parent question is answered from the live parent level
/// (`ParentContinuity`): whatever link Lattice asks, the node answers it
/// with one read of the levels the loop holds, so it reaches the verdict the
/// parent's own facts do. A loop that has stopped answers nothing, and the
/// block then awaits its parent, never valid on it.
final class ParentContinuityTests: XCTestCase {
    func testAConnectIsAnsweredFromTheLiveParent() async throws {
        var rng = SplitMix64(state: 0x11c4)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        let context = ValidationContext(nowMilliseconds: now)
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
                        let levels = host.levels
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: ParentContinuity(levels: LiveLevels { $0(levels) }),
                            validationContext: context
                        )
                        if path.count > 1, !verdict.provesInvalid {
                            let expected = await ChainTree.connect(
                                job, fetcher: world.cas, parentFacts: host.parentFacts(for: path),
                                validationContext: context
                            )
                            XCTAssertEqual(verdict.retryFailure, expected.retryFailure, job.blockHash)
                            XCTAssertEqual(verdict.provesInvalid, expected.provesInvalid, job.blockHash)
                            let stopped = await ChainTree.connect(
                                job, fetcher: world.cas, parentFacts: ParentContinuity(levels: .none),
                                validationContext: context
                            )
                            guard case .crossChainEvidenceRequired(.parentStateContinuity)? = stopped.retryFailure else {
                                return XCTFail("\(job.blockHash): \(String(describing: stopped.retryFailure))")
                            }
                            if verdict.retryFailure == nil {
                                let block = try await BlockHeader(rawCID: job.blockHash).resolve(fetcher: world.cas).node
                                if block?.parent == nil { checked.genesis += 1 } else { checked.later += 1 }
                            }
                        }
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked.genesis, 0, "a child genesis connected from the live parent")
        XCTAssertGreaterThan(checked.later, 0, "a later child block connected from the live parent")
    }
}
