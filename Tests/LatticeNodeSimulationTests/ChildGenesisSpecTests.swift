import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest

/// A child genesis travels with its spec. A spec that is not the one the
/// genesis names never blocks it: the next announcer's is held. A proof
/// check whose block the shell no longer holds frees its slot, blaming no one.
final class ChildGenesisSpecTests: XCTestCase {
    private let now = World.genesisTime + 10_000
    private let alpha = LevelWorld.alpha

    private func world() async throws -> LevelWorld {
        var rng = SplitMix64(state: 0x5BEC)
        return try await LevelWorld.generate(
            rng: &rng, levels: 2, grinds: 12, forkProbability: 0, shareProbability: 0,
            doubleProbability: 0, withholdDelay: 1_000
        )
    }

    /// `peer` streams the genesis and answers its `getData` with `spec`;
    /// proof checks run to completion. Returns the effects seen.
    private func announce(
        _ world: LevelWorld, to host: inout HostCore, from peer: PeerID, spec: ChainSpec, verify: Bool = true
    ) async throws -> [HostEffect] {
        let genesis = try XCTUnwrap(world.geneses[alpha])
        let proofs = world.publicProofs(alpha, genesis.cid, at: .max)
        var seen: [HostEffect] = []
        var queue: [HostEvent] = [.received(peer, alpha, .stream(StreamPage(
            requestID: 0, logID: "log-\(peer.key)",
            entries: [StreamEntry(position: 1, entry: .header(genesis.cid))], hasMore: false
        )))]
        while !queue.isEmpty {
            for effect in host.step(queue.removeFirst(), now: now) {
                seen.append(effect)
                switch effect {
                case .level(let path, .send(let to, .getData(let id, let cids))) where path == alpha && to == peer:
                    guard cids.contains(genesis.cid) else { continue }
                    queue.append(.received(peer, alpha, .headers(HeadersResponse(requestID: id, entries: [
                        HeaderEntry(block: genesis.block, children: genesis.children, proofs: proofs, spec: spec),
                    ], hasMore: false))))
                case .level(let path, .verifyProof(let job)) where verify:
                    let block = job.block ?? genesis.block
                    queue.append(.level(path, .proofVerified(job, await job.run(block))))
                default:
                    break
                }
            }
        }
        return seen
    }

    func testABadSpecNeverBlocksTheGenesis() async throws {
        let world = try await world()
        var host = HostCore(root: world.rootBootstrap.tree, hosted: world.hosted)
        let liar = PeerID(key: "liar", session: 1)
        let honest = PeerID(key: "honest", session: 1)
        _ = host.step(.peerReady(liar), now: now)
        _ = host.step(.peerReady(honest), now: now)
        let genesis = try XCTUnwrap(world.geneses[alpha]).cid

        _ = try await announce(world, to: &host, from: liar, spec: LevelWorld.specFor(LevelWorld.beta))
        XCTAssertFalse(host.levels[alpha]?.tree.contains(blockHash: genesis) ?? true, "a wrong spec admits nothing")

        _ = try await announce(world, to: &host, from: honest, spec: try XCTUnwrap(world.specs[alpha]))
        XCTAssertTrue(host.levels[alpha]?.tree.contains(blockHash: genesis) ?? false, "the honest spec admits the genesis")
    }

    func testADroppedProofCheckFreesItsSlotWithoutBlame() async throws {
        let world = try await world()
        var host = HostCore(root: world.rootBootstrap.tree, hosted: world.hosted)
        let peer = PeerID(key: "peer", session: 1)
        _ = host.step(.peerReady(peer), now: now)
        let effects = try await announce(
            world, to: &host, from: peer, spec: try XCTUnwrap(world.specs[alpha]), verify: false
        )
        let jobs = effects.compactMap { effect -> ProofJob? in
            if case .level(_, .verifyProof(let job)) = effect { return job }
            return nil
        }
        XCTAssertFalse(jobs.isEmpty)
        var dropped: [HostEffect] = []
        for job in jobs { dropped += host.step(.level(alpha, .proofDropped(job)), now: now) }
        XCTAssertEqual(host.levels[alpha]?.sync.proofs.verifying.count, 0)
        XCTAssertFalse(dropped.contains { if case .disconnect = $0 { true } else { false } })
    }
}
