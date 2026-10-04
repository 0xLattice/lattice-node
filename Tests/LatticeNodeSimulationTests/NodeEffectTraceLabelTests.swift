import Lattice
import LatticeNodeCore
@testable import LatticeNodeSim
import XCTest

/// The sync trace labels every effect of every step. A child connect carries
/// its parent level's whole tree as parent facts, so a label that reflected
/// them would cost O(parent chain) per child block (measured: a 16 MB string
/// per Nexus/testnet block at Nexus height ~4400). The label stays bounded
/// by the effect's own fields as the parent grows.
final class NodeEffectTraceLabelTests: XCTestCase {
    func testAChildConnectLabelDoesNotGrowWithItsParentChain() async throws {
        var rng = SplitMix64(state: 0x7ace)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 24, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        let now = World.genesisTime + 1_000_000
        var host = NodeCore(root: world.rootBootstrap.tree, hosted: world.hosted)
        // (full reflection length, label length) of each child connect.
        var childConnects: [(reflected: Int, label: Int)] = []
        for grind in world.grinds {
            var queue: [NodeEvent] = [.mined(grind.mined)]
            while !queue.isEmpty {
                for effect in host.step(queue.removeFirst(), now: now) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job, let facts):
                        if facts != nil {
                            childConnects.append((String(describing: effect).count, effect.traceLabel.count))
                        }
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        let first = try XCTUnwrap(childConnects.first)
        let last = try XCTUnwrap(childConnects.last)
        XCTAssertGreaterThan(childConnects.count, 4)
        // The hazard is real: reflection grows with the parent chain.
        XCTAssertGreaterThan(last.reflected, first.reflected)
        // The label does not.
        XCTAssertEqual(Set(childConnects.map(\.label)).count, 1)
        XCTAssertLessThan(last.label, 200)
    }
}
