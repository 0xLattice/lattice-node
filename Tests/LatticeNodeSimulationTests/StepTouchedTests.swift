import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// `NodeCore.touched` names every level a step can have changed: a level it
/// leaves out keeps its snapshot, its body pipeline and the window the
/// shell derives from its tree. The shell recomputes only the levels named.
final class StepTouchedTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000

    private struct Derived: Equatable {
        let snapshot: ChainSnapshot
        let bodies: BodyPipeline
        let window: [String]
        let next: [String]
        let distances: [String: Int]

        init(_ level: ChainCore) {
            snapshot = level.snapshot
            bodies = level.bodies
            window = level.bodyWindow
            next = level.nextToConnect
            distances = level.connectDistances
        }
    }

    /// Grinds mined at three levels, fetched and executed one step at a
    /// time: after every step, each level not touched is as it was, and a
    /// child level's own body arrival touches only that level and the
    /// levels below it (one its execution wakes), never an ancestor.
    func testAStepChangesOnlyTheLevelsItTouched() async throws {
        var rng = SplitMix64(state: 0x70C4)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 3, grinds: 40, forkProbability: 0.2, shareProbability: 0.2,
            doubleProbability: 0, withholdDelay: 1_000
        )
        var host = NodeCore(root: world.rootBootstrap.tree.detached(), hosted: world.hosted)
        var steps = 0
        var childArrivals = 0
        for grind in world.grinds {
            var queue: [NodeEvent] = [.mined(grind.mined)]
            while !queue.isEmpty {
                let event = queue.removeFirst()
                let before = host.levels.mapValues(Derived.init)
                let effects = host.step(event, now: Self.now)
                steps += 1
                for (path, was) in before where !host.touched.contains(path) {
                    XCTAssertEqual(host.levels[path].map(Derived.init), was, "\(path) changed untouched by \(event)")
                }
                if case .level(let path, .bodyFetched) = event, path.count > 1 {
                    childArrivals += 1
                    XCTAssertTrue(host.touched.allSatisfy { $0.starts(with: path) }, "\(host.touched)")
                }
                for effect in effects {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job):
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: host.parentFacts(for: path),
                            validationContext: ValidationContext(nowMilliseconds: Self.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThan(steps, 100)
        XCTAssertGreaterThan(childArrivals, 10)
    }
}
