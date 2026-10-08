import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// A step costs in proportion to its event, not to the chain: the host
/// mutates a level as its one owner. A level stepped as a copy read out of
/// the host's map shares every collection with the map's own, so each one
/// the step writes is first copied whole (copy-on-write) — once per event.
///
/// The weigh log is the witness: an array appended in place keeps its
/// buffer until it outgrows it (a doubling, so a handful of times ever),
/// while one copied on write moves on every append.
final class StepInPlaceTests: XCTestCase {
    private static let now = World.genesisTime + 1_000_000

    /// Where a level's weigh log lives, and how long it is.
    private func log(_ host: NodeCore, _ path: ChainPath) -> (address: UnsafeRawPointer?, count: Int) {
        let entries = host.levels[path]?.sync.log.entries ?? []
        return (entries.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }, entries.count)
    }

    /// One host step, counting per level the appends to its log (past a
    /// warm-up, where a small buffer doubles often) and those that moved it.
    private func step(
        _ host: inout NodeCore, _ event: NodeEvent,
        _ counts: inout [ChainPath: (appends: Int, moves: Int)]
    ) -> [NodeEffect] {
        let before = host.ordered.map { ($0, log(host, $0)) }
        let effects = host.step(event, now: Self.now)
        for (path, was) in before where was.count >= 32 {
            let after = log(host, path)
            guard after.count > was.count else { continue }
            counts[path, default: (0, 0)].appends += 1
            if after.address != was.address { counts[path, default: (0, 0)].moves += 1 }
        }
        return effects
    }

    private func assertInPlace(_ counts: [ChainPath: (appends: Int, moves: Int)], levels: Int) {
        XCTAssertEqual(counts.count, levels)
        for (path, count) in counts {
            XCTAssertGreaterThan(count.appends, 60, "\(path)")
            // In place: only the doublings (at most three here). Copied on
            // write: every append.
            XCTAssertLessThan(count.moves * 8, count.appends, "\(path): the level was copied to step it")
        }
    }

    /// Headers a peer streams, weighed one per exchange.
    func testWeighingAReceivedHeaderDoesNotCopyTheLevel() async throws {
        var rng = SplitMix64(state: 0x1_4AC3)
        let world = try await World.generate(rng: &rng, honestBlocks: 100, forkProbability: 0, spamBlocks: 0)
        let path = world.bootstrap.tree.context!.path
        let peer = PeerID(key: "peer", session: 1)
        var host = NodeCore(root: world.bootstrap.tree, hosted: [])
        var counts: [ChainPath: (appends: Int, moves: Int)] = [:]

        var asked: UInt64?
        for effect in step(&host, .peerReady(peer), &counts) {
            if case .level(_, .send(_, .getStream(let id, _, _, _))) = effect { asked = id }
        }
        _ = step(&host, .received(peer, path, .stream(StreamPage(
            requestID: try XCTUnwrap(asked), logID: "peer-log", entries: [], hasMore: false
        ))), &counts)
        for (offset, cid) in world.honest.enumerated() {
            let block = try XCTUnwrap(world.blocks[cid])
            let pushed = step(&host, .received(peer, path, .stream(StreamPage(
                requestID: 0, logID: "peer-log",
                entries: [StreamEntry(position: UInt64(offset + 1), entry: .header(cid))], hasMore: false
            ))), &counts)
            for effect in pushed {
                guard case .level(_, .send(_, .getData(let id, _))) = effect else { continue }
                _ = step(&host, .received(peer, path, .headers(HeadersResponse(
                    requestID: id, entries: [HeaderEntry(block: block.block, children: block.children)], hasMore: false
                ))), &counts)
            }
        }
        XCTAssertEqual(log(host, path).count, world.honest.count)
        assertInPlace(counts, levels: 1)
    }

    /// This host's own grinds, weighed at both levels they reach and
    /// executed, with the child level credited its parent's runs.
    func testWeighingAMinedGrindDoesNotCopyAnyLevel() async throws {
        var rng = SplitMix64(state: 0x1_4AC4)
        let world = try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 100, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
        var host = NodeCore(root: world.rootBootstrap.tree, hosted: world.hosted)
        var counts: [ChainPath: (appends: Int, moves: Int)] = [:]
        for grind in world.grinds {
            var queue: [NodeEvent] = [.mined(grind.mined)]
            while !queue.isEmpty {
                for effect in step(&host, queue.removeFirst(), &counts) {
                    switch effect {
                    case .level(let path, .fetchBody(let cid)):
                        queue.append(.level(path, .bodyFetched(cid: cid)))
                    case .connect(let path, let job, let facts):
                        let verdict = await ChainTree.connect(
                            job, fetcher: world.cas, parentFacts: facts,
                            validationContext: ValidationContext(nowMilliseconds: Self.now)
                        )
                        queue.append(.level(path, .connected(verdict)))
                    default:
                        break
                    }
                }
            }
        }
        assertInPlace(counts, levels: 2)
    }
}
