import Foundation
import Ivy
import Lattice
@testable import LatticeNodeCore
import LatticeNodeAPI
import XCTest
@testable import LatticeNode

/// The runtime's wiring of `ChainCore.holdsBacklog`, through the real worker
/// pool with a level's connects held (`NodeRuntime.start`'s `observeJob`): a
/// synced root executing one arriving block keeps answering templates, a
/// root holding a backlog refuses them (503 "executing"), and a child
/// holding one is left out of the root's template and of its own build.
final class HeldLevelTemplateTests: XCTestCase {
    private static let nexus: ChainPath = ["Nexus"]
    private static let alpha: ChainPath = ["Nexus", "Alpha"]

    /// Connects at one level, held while `holding`.
    private actor Gate {
        private(set) var holding = false
        private(set) var held = 0

        func hold() { holding = true }
        func release() { holding = false }
        /// Awaited on the connect's worker: waits while held.
        func pass() async {
            guard holding else { return }
            held += 1
            while holding { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    /// The observer that holds `path`'s connects at `gate`.
    private static func holding(_ path: ChainPath, at gate: Gate) -> NodeRuntime.JobObserver {
        { kind, at, _ in if kind == .connect, at == path { await gate.pass() } }
    }

    private func node(
        keyByte: UInt8,
        peers: [PeerEndpoint] = [],
        hosting alpha: Bool = false,
        creator: Bool = true,
        observe: NodeRuntime.JobObserver? = nil
    ) async throws -> (runtime: NodeRuntime, endpoint: PeerEndpoint) {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: Self.nexus, storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: alpha ? [Self.alpha] : [],
            childSpecs: alpha && creator ? [Self.alpha: MergedMiningTests.alphaSpec] : [:]
        )
        let runtime = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            ),
            workers: 2,
            observeJob: observe
        )
        addTeardownBlock { await runtime.stop() }
        return (runtime, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
    }

    /// Whether `path` on `runtime` has the body of the best chain's block at
    /// `height` and has weighed headers up to `best`.
    private static func holds(
        _ runtime: NodeRuntime, _ path: ChainPath, height: UInt64, best: UInt64
    ) async -> Bool {
        await LiveLevels(inputs: runtime.inputs).read { levels -> Bool in
            guard let level = levels[path], level.snapshot.bestHeaderHeight == best,
                  let cid = level.tree.canonicalBlockHash(atHeight: height) else { return false }
            return level.bodies.arrived.contains(cid)
        } == true
    }

    /// A synced node receives one block and executes it: its root stays
    /// mined. A request made during the connect is answered on the tip it
    /// is leaving, as the status names it, and a miner following the node's
    /// pushes is never refused and is then given the new tip's template.
    func testASyncedRootExecutingOneArrivingBlockKeepsAnsweringTemplates() async throws {
        let miner = try await node(keyByte: 0x81)
        for _ in 0..<2 { _ = try await miner.runtime.mineBlock() }
        let gate = Gate()
        let follower = try await node(keyByte: 0x82, peers: [miner.endpoint], observe: Self.holding(Self.nexus, at: gate))
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 2 }

        // A miner following pushes: each digest is fetched at once.
        actor Seen {
            var templates: [MiningTemplateResponse] = []
            var refusals: [String] = []
            func add(_ template: MiningTemplateResponse) { templates.append(template) }
            func refuse(_ error: any Error) { refusals.append("\(error)") }
        }
        let seen = Seen()
        let events = follower.runtime.miningEvents()
        let following = Task {
            for await _ in events {
                do { await seen.add(try await follower.runtime.miningTemplate(MiningTemplateRequest())) }
                catch { await seen.refuse(error) }
            }
        }
        defer { following.cancel() }

        await gate.hold()
        _ = try await miner.runtime.mineBlock()
        try await eventually("the follower executes block 3 (held)") { await gate.held == 1 }
        let during = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(during.block.height, 3, "built on the tip it is leaving, as main does")
        let status = await follower.runtime.status().templateDigest
        XCTAssertEqual(during.templateDigest, status, "the answer is the status's template")
        await gate.release()

        try await eventually("the follower fetched the new tip's template") {
            await seen.templates.last?.block.height == 4
        }
        let refusals = await seen.refusals
        XCTAssertEqual(refusals, [], "a miner following pushes is never refused")
    }

    /// A syncing root holds a backlog (the next two blocks' bodies): it
    /// refuses templates (503 "executing") until it has executed it.
    func testASyncingRootHoldingABacklogRefusesTemplates() async throws {
        let miner = try await node(keyByte: 0x83)
        for _ in 0..<4 { _ = try await miner.runtime.mineBlock() }
        let gate = Gate()
        await gate.hold()
        let follower = try await node(keyByte: 0x84, peers: [miner.endpoint], observe: Self.holding(Self.nexus, at: gate))
        try await eventually("block 1's connect is held with block 2's body here") {
            guard await gate.held == 1 else { return false }
            return await Self.holds(follower.runtime, Self.nexus, height: 2, best: 4)
        }
        do {
            _ = try await follower.runtime.miningTemplate(MiningTemplateRequest())
            XCTFail("a root holding a backlog has no template")
        } catch {
            XCTAssertEqual(error as? TemplateError, .executing)
        }
        await gate.release()
        try await eventually("the follower is synced") { follower.runtime.published.value?.actOnHeight == 4 }
        let template = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.height, 5)
    }

    /// A child holding a backlog is left out of the root's template, which
    /// the status names, and its own build is refused, until it has
    /// executed it.
    func testAChildHoldingABacklogIsLeftOutOfTheRootTemplateAndItsBuild() async throws {
        let miner = try await node(keyByte: 0x85, hosting: true)
        let minerAlpha = try XCTUnwrap(miner.runtime.levelReads[Self.alpha])
        // Nexus blocks 1-3 carry Alpha's genesis and blocks 1 and 2.
        for height in 0..<3 {
            _ = try await miner.runtime.mineBlock()
            try await eventually("Alpha executes its block \(height)") {
                await minerAlpha.readSnapshot().height == UInt64(height)
            }
        }
        let gate = Gate()
        await gate.hold()
        let follower = try await node(
            keyByte: 0x86, peers: [miner.endpoint], hosting: true, creator: false,
            observe: Self.holding(Self.alpha, at: gate)
        )
        try await eventually("the follower's Nexus is synced, Alpha's genesis held with block 1's body here") {
            guard follower.runtime.published.value?.actOnHeight == 3, await gate.held == 1 else { return false }
            return await Self.holds(follower.runtime, Self.alpha, height: 1, best: 2)
        }
        let template = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertEqual(template.block.height, 4, "the root is mined")
        XCTAssertNil(template.block.children.node?.entries["Alpha"], "Alpha is left out while it holds a backlog")
        let status = await follower.runtime.status().templateDigest
        XCTAssertEqual(template.templateDigest, status)
        do {
            _ = try await follower.runtime.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: nil))
            XCTFail("a child holding a backlog has no block to build")
        } catch {
            XCTAssertEqual(error as? TemplateError, .executing)
        }

        await gate.release()
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        try await eventually("Alpha executes its backlog") { await followerAlpha.readSnapshot().height == 2 }
        let carrying = try await follower.runtime.miningTemplate(MiningTemplateRequest())
        XCTAssertNotNil(carrying.block.children.node?.entries["Alpha"], "Alpha is carried again")
        _ = try await follower.runtime.buildChildBlock(BuildChildBlockRequest(chainPath: Self.alpha, recipient: nil))
    }
}
