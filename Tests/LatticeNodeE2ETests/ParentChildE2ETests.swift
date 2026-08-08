import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Lattice
import LatticeMinerCore
import LatticeNode
import Ivy
import UInt256
import XCTest
import cashew

/// Slow shared CI runners set E2E_TIME_SCALE above 1. Every wait in this
/// harness polls and returns as soon as its condition holds, so scaling
/// lengthens only genuinely failing runs, never passing ones.
let e2eTimeScale: Int = ProcessInfo.processInfo
    .environment["E2E_TIME_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

func e2eScaled(_ timeout: Duration) -> Duration {
    timeout * e2eTimeScale
}

@MainActor
final class ParentChildE2ETests: XCTestCase {

    /// A fresh node must cold-sync a chain far deeper than any fixed working-set
    /// bound. The previous backward-gather sync retained every disconnected
    /// block until the whole chain connected to genesis and capped that
    /// retention at 64, so it stalled and crashed cold-syncing anything much
    /// deeper (~122 blocks observed). Forward-apply pulls the ordered ancestor
    /// range and applies genesis-ward with a bounded look-ahead, so there is no
    /// chain-depth ceiling. This mines a Nexus chain past that old cap and past
    /// one full ancestor-range page (256), then joins a brand-new node over the
    /// real overlay and requires it to reach the exact tip.
    func testFreshNodeColdSyncsDeepNexusChainOverOverlay() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let sourceIdentity = try workspace.makeIdentity(named: "source")
        let joinerIdentity = try workspace.makeIdentity(named: "joiner")
        let ports = try E2EPorts.allocate(count: 6)
        let source = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "source",
            identity: sourceIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let joiner = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "joiner",
            identity: joinerIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        joiner.setOverlayPeers([
            try overlayPeer(identity: sourceIdentity, port: ports[0])
        ])
        cluster.add(source)
        cluster.add(joiner)

        // Build a Nexus chain past the old retained-candidate cap (64): the
        // previous backward-gather sync could not hold more than 64 disconnected
        // blocks, so it never connected — height stayed 0 — for any chain deeper
        // than that. Depth stays inside the first difficulty-retarget window
        // (120) so mining does not become a retarget benchmark, and keeps the
        // per-run mining cost bounded on slow CI. With a 64-CID forward page this
        // depth still spans multiple pages, exercising the receiver's page-pump
        // and the responder's hasMore across pages.
        let depth: UInt64 = 70
        try source.start()
        _ = try await waitForNexus(source)
        for _ in 0..<depth {
            let work = try await mine(source)
            XCTAssertTrue(work.accepted)
        }
        let sourceTip = try await source.waitForStatus {
            ($0.height ?? 0) == depth
        }
        let tipCID = try XCTUnwrap(sourceTip.tipCID)

        // A brand-new node joins and must forward-apply the whole chain to tip.
        // The deadline is generous: on a slow, CPU-contended runner a content
        // fetch can wedge mid-apply and the range-sync watchdog re-drives it,
        // which adds bounded recovery pauses. The wait returns the instant the
        // tip matches, so headroom costs a passing run nothing.
        try joiner.start()
        let synced = try await joiner.waitForStatus(
            timeout: e2eScaled(.seconds(420))
        ) { $0.phase == .active && $0.tipCID == tipCID }
        XCTAssertEqual(synced.height, depth)
        XCTAssertEqual(synced.tipCID, tipCID)

        try await cluster.stopAll()
        passed = true
    }

    func testSamePathReplicaReorgsTieFromLosingSegmentBase() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let aIdentity = try workspace.makeIdentity(named: "a")
        let bIdentity = try workspace.makeIdentity(named: "b")
        let cIdentity = try workspace.makeIdentity(named: "c")
        let dIdentity = try workspace.makeIdentity(named: "d")
        let ports = try E2EPorts.allocate(count: 13)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[0])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[3])
        let cPeer = try overlayPeer(identity: cIdentity, port: ports[6])
        let dPeer = try overlayPeer(identity: dIdentity, port: ports[9])

        let a = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "a",
            identity: aIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let b = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "b",
            identity: bIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let c = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "c",
            identity: cIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let d = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "d",
            identity: dIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        cluster.add(a)
        cluster.add(b)
        cluster.add(c)
        cluster.add(d)

        try a.start()
        try b.start()
        _ = try await waitForNexus(a)
        _ = try await waitForNexus(b)

        // Distinct signed transactions make the sibling segment bases distinct
        // without relying on wall-clock timing.
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let a1 = try await mineBlock(a)
        let b1 = try await mineBlock(b)
        XCTAssertTrue(a1.response.accepted)
        XCTAssertTrue(b1.response.accepted)
        XCTAssertEqual(a1.response.tipCID, a1.blockCID)
        XCTAssertEqual(b1.response.tipCID, b1.blockCID)
        XCTAssertEqual(a1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertNotEqual(a1.blockCID, b1.blockCID)
        XCTAssertEqual(a1.template.block.target, b1.template.block.target)
        XCTAssertEqual(
            WorkSum(workForTarget(a1.template.block.target)),
            WorkSum(workForTarget(b1.template.block.target))
        )

        // These one-block sibling CIDs are segment bases. The oracle is the
        // Lattice comparator itself, never textual CID ordering.
        let winnerCID = forkChoicePrefersSegmentBase(
            a1.blockCID,
            over: b1.blockCID
        ) ? a1.blockCID : b1.blockCID
        let loserCID = winnerCID == a1.blockCID ? b1.blockCID : a1.blockCID
        let winnerPeer = winnerCID == a1.blockCID ? aPeer : bPeer
        let loserPeer = loserCID == a1.blockCID ? aPeer : bPeer
        let winner = winnerCID == a1.blockCID ? a : b
        let loser = loserCID == a1.blockCID ? a : b

        // D seals the winner before it has any route to the loser. It stays
        // offline while C exercises the opposite arrival order below.
        d.setOverlayPeers([winnerPeer])
        try d.start()
        _ = try await waitForTip(d, winnerCID)
        try await d.stop()

        // C sees the losing branch first, then proves that its recovered
        // accepted loser survives after disconnecting from that source. The
        // winner can therefore be admitted into a live process that already
        // has the competing branch, without contaminating the loser source.
        c.setOverlayPeers([loserPeer])
        try c.start()
        _ = try await waitForTip(c, loserCID)
        try await c.stop()
        c.setOverlayPeers([])
        try c.start()
        _ = try await waitForTip(c, loserCID)
        try await winner.stop()
        winner.setOverlayPeers([cPeer])
        try winner.start()
        _ = try await waitForTip(c, winnerCID)

        // Stop every source that could now relay the loser through C. D opens
        // only its durable winner; its observer is ready before the original
        // loser comes back and initiates the sole new connection.
        try await winner.stop()
        try await loser.stop()
        d.setOverlayPeers([])
        try d.start()
        _ = try await waitForTip(d, winnerCID)
        let liveObserver = try E2EOverlayObserver(
            port: ports[12],
            bootstrapPeer: dPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"]
            )
        )
        addTeardownBlock { await liveObserver.stop() }
        try await liveObserver.start()
        try await liveObserver.waitForConnection(to: dPeer.publicKey)
        try await liveObserver.waitForAnnouncement(of: winnerCID)

        // This is now D's first possible route to the loser. A fresh
        // D-originated announcement is emitted only after durable admission.
        let loserAnnouncements = await liveObserver.announcementCount(of: loserCID)
        XCTAssertEqual(loserAnnouncements, 0)
        loser.setOverlayPeers([dPeer])
        try loser.start()
        try await liveObserver.waitForAnnouncement(
            of: loserCID,
            after: loserAnnouncements
        )
        let reverseArrival = try await d.waitForStatus { _ in true }
        XCTAssertEqual(reverseArrival.tipCID, winnerCID)
        await liveObserver.stop()

        // Once both sources are gone, C and D must recover the selected
        // canonical projection from disk without any bootstrap source.
        try await loser.stop()
        c.forceTerminate()
        d.forceTerminate()
        c.setOverlayPeers([])
        d.setOverlayPeers([])
        try c.start()
        try d.start()
        _ = try await waitForTip(c, winnerCID)
        _ = try await waitForTip(d, winnerCID)

        try await cluster.stopAll()
        passed = true
    }

    func testSamePathReplicaRelaysHigherWorkAcrossRestartAndLateJoin() async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        defer {
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let aIdentity = try workspace.makeIdentity(named: "a")
        let bIdentity = try workspace.makeIdentity(named: "b")
        let cIdentity = try workspace.makeIdentity(named: "c")
        let dIdentity = try workspace.makeIdentity(named: "d")
        let ports = try E2EPorts.allocate(count: 12)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[0])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[3])
        let cPeer = try overlayPeer(identity: cIdentity, port: ports[6])

        let a = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "a",
            identity: aIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let b = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "b",
            identity: bIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let c = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "c",
            identity: cIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let d = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "d",
            identity: dIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        cluster.add(a)
        cluster.add(b)
        cluster.add(c)
        cluster.add(d)

        try a.start()
        try b.start()
        _ = try await waitForNexus(a)
        _ = try await waitForNexus(b)

        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus"])
            )
        )
        let a1 = try await mineBlock(a)
        let b1 = try await mineBlock(b)
        let b2 = try await mineBlock(b)
        XCTAssertTrue(a1.response.accepted)
        XCTAssertTrue(b1.response.accepted)
        XCTAssertTrue(b2.response.accepted)
        XCTAssertEqual(a1.response.tipCID, a1.blockCID)
        XCTAssertEqual(b2.response.tipCID, b2.blockCID)
        XCTAssertEqual(a1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b1.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(b2.template.block.parent?.rawCID, b1.blockCID)
        XCTAssertNotEqual(a1.blockCID, b1.blockCID)
        XCTAssertNotEqual(b1.blockCID, b2.blockCID)

        // This is the exact root-only case: each distinct accepted root block
        // contributes workForTarget(target) under its own block-CID grind.
        let aWork = WorkSum(workForTarget(a1.template.block.target))
        let bWork = WorkSum(workForTarget(b1.template.block.target))
            + WorkSum(workForTarget(b2.template.block.target))
        XCTAssertGreaterThan(workForTarget(b2.template.block.target), .zero)
        XCTAssertGreaterThan(bWork, aWork)

        // C learns B's previously withheld branch while A has no peer edge to
        // either B or C. Kill all three, then recover A without a peer: it
        // must first restore its divergent branch from disk.
        c.setOverlayPeers([bPeer])
        try c.start()
        _ = try await waitForTip(c, b2.blockCID)
        b.forceTerminate()
        c.forceTerminate()
        a.forceTerminate()
        a.setOverlayPeers([])
        try a.start()
        _ = try await waitForTip(a, a1.blockCID)
        try await a.stop()

        // C reopens its durable branch with no bootstrap peers. Start C before
        // A attaches its only peer so this test isolates node-level durable
        // relay and reorg behavior from Ivy's independently tested retry
        // schedule. A can only learn B's branch through C's overlay content.
        c.setOverlayPeers([])
        try c.start()
        _ = try await waitForTip(c, b2.blockCID)
        a.setOverlayPeers([cPeer])
        try a.start()
        _ = try await waitForTip(a, b2.blockCID)

        // Remove the bridge as well. A must recover the learned branch from
        // disk after a crash before fresh D can obtain it only from A.
        a.forceTerminate()
        c.forceTerminate()
        try a.start()
        _ = try await waitForTip(a, b2.blockCID)
        d.setOverlayPeers([aPeer])
        try d.start()
        _ = try await waitForTip(d, b2.blockCID)

        try await cluster.stopAll()
        passed = true
    }

    private func nexusNode(
        binary: URL,
        workspace: E2EWorkspace,
        name: String,
        identity: E2EIdentity,
        overlayPort: UInt16,
        factPort: UInt16,
        rpcPort: UInt16
    ) -> E2ENode {
        E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: name,
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent(name, isDirectory: true),
                identity: identity,
                overlayPort: overlayPort,
                factPort: factPort,
                rpcPort: rpcPort
            ),
            logDirectory: workspace.logs
        )
    }

    private func childNode(
        binary: URL,
        workspace: E2EWorkspace,
        name: String,
        directory: String,
        identity: E2EIdentity,
        parentPublicKey: String,
        parentFactPort: UInt16,
        overlayPort: UInt16,
        factPort: UInt16,
        rpcPort: UInt16,
        overlayPeers: [E2ENode.OverlayPeer] = []
    ) -> E2ENode {
        E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: name,
                chainPath: "Nexus/\(directory)",
                storage: workspace.url.appendingPathComponent(name, isDirectory: true),
                identity: identity,
                overlayPort: overlayPort,
                factPort: factPort,
                rpcPort: rpcPort,
                overlayPeers: overlayPeers,
                parent: .init(publicKey: parentPublicKey, factPort: parentFactPort)
            ),
            logDirectory: workspace.logs
        )
    }

    private func overlayPeer(
        identity: E2EIdentity,
        port: UInt16
    ) throws -> E2ENode.OverlayPeer {
        E2ENode.OverlayPeer(
            publicKey: try PeerKey(identity.publicKey).hex,
            port: port
        )
    }

    private func waitForNexus(
        _ node: E2ENode
    ) async throws -> ChainServiceStatusResponse {
        try await node.waitForStatus { status in
            status.phase == .active
                && status.chainPath == ["Nexus"]
                && status.tipCID == NexusGenesis.expectedBlockHash
        }
    }

    private func waitForTip(
        _ node: E2ENode,
        _ tipCID: String
    ) async throws -> ChainServiceStatusResponse {
        try await node.waitForStatus { status in
            status.phase == .active && status.tipCID == tipCID
        }
    }

    private func mine(
        _ parent: E2ENode,
        rewards: [MiningReward] = []
    ) async throws -> SubmitWorkResponse {
        try await mineBlock(parent, rewards: rewards).response
    }

    private func mineBlock(
        _ parent: E2ENode,
        rewards: [MiningReward] = [],
        requestTimeout: TimeInterval? = nil
    ) async throws -> E2EMinedBlock {
        // Child candidate collection is protocol-bounded at 15 seconds.
        let template: MiningTemplateResponse = try await parent.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(rewards: rewards),
            timeout: requestTimeout ?? 20
        )
        let midstate = ProofOfWork.midstate(for: template.block)
        var nonce: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: nonce)
            > template.searchTarget
        {
            nonce += 1
        }
        let directChildCount: Int
        if let children = template.block.children.node,
           let entries = try? children.allKeysAndValues() {
            directChildCount = entries.count
        } else {
            directChildCount = 0
        }
        // Submission validates the parent plus one proof route per direct
        // child. Give each chain one bounded CI-safe unit instead of turning
        // this correctness suite into an accidental latency benchmark.
        let submitTimeout = requestTimeout
            ?? TimeInterval((directChildCount + 1) * 10)
        let response: SubmitWorkResponse = try await parent.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: nonce),
            timeout: submitTimeout
        )
        return E2EMinedBlock(
            template: template,
            response: response,
            blockCID: try BlockHeader(
                node: ProofOfWork.withNonce(template.block, nonce: nonce)
            ).rawCID
        )
    }

    private func submitTemplate(
        _ template: MiningTemplateResponse,
        to node: E2ENode
    ) async throws -> SubmitWorkResponse {
        let midstate = ProofOfWork.midstate(for: template.block)
        var nonce: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: nonce)
            > template.searchTarget
        {
            nonce += 1
        }
        return try await node.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
        )
    }

    private func waitForReplicaConvergence(
        _ first: E2ENode,
        _ second: E2ENode,
        excluding excludedCID: String
    ) async throws -> String {
        let status = try await waitForReplicaConvergenceStatus(
            first,
            second,
            excluding: excludedCID
        )
        return try XCTUnwrap(status.tipCID)
    }

    private func waitForReplicaConvergenceStatus(
        _ first: E2ENode,
        _ second: E2ENode,
        excluding excludedCID: String,
        minimumHeight: UInt64 = 0
    ) async throws -> ChainServiceStatusResponse {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(.seconds(30))
        while clock.now < deadline {
            let firstStatus = try? await first.waitForStatus(
                timeout: .seconds(1),
                where: { $0.phase == .active }
            )
            let secondStatus = try? await second.waitForStatus(
                timeout: .seconds(1),
                where: { $0.phase == .active }
            )
            if let firstStatus,
               let firstTip = firstStatus.tipCID,
               firstTip != excludedCID,
               firstTip == secondStatus?.tipCID,
               firstStatus.height ?? 0 >= minimumHeight,
               secondStatus?.height ?? 0 >= minimumHeight {
                return firstStatus
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "same-path replicas did not converge"
        )
    }

    private func mineWithCoordinator(
        _ parent: E2ENode,
        coordinator: URL,
        miner: URL
    ) async throws -> E2ECoordinatorResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = coordinator
        process.arguments = [
            "--node", parent.rpcURL.absoluteString,
            "--worker-executable", miner.path,
            "--workers", "1",
            "--once",
            "--batch-size", "1",
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(.seconds(20))
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = clock.now + e2eScaled(.seconds(5))
            while process.isRunning && clock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw E2EHTTPError(
                status: 0,
                body: "mining coordinator did not finish within 20 seconds"
            )
        }

        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw E2EHTTPError(
                status: Int(process.terminationStatus),
                body: "mining coordinator failed: \(String(decoding: stderr, as: UTF8.self))"
            )
        }
        do {
            return try JSONDecoder().decode(E2ECoordinatorResult.self, from: stdout)
        } catch {
            throw E2EHTTPError(
                status: 0,
                body: "invalid mining coordinator output: \(String(decoding: stdout, as: UTF8.self)); stderr: \(String(decoding: stderr, as: UTF8.self)); error: \(error)"
            )
        }
    }

    private func mineWithWorker(
        _ parent: E2ENode,
        template: MiningTemplateResponse,
        nonce: UInt64,
        miner: URL
    ) async throws -> SubmitWorkResponse {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = miner
        process.arguments = [
            "--work-id", template.workID,
            "--block-hex", try XCTUnwrap(template.block.toData()).map {
                String(format: "%02x", $0)
            }.joined(),
            "--target", template.searchTarget.toHexString(),
            "--start-nonce", String(nonce),
            "--count", "1",
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(.seconds(20))
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw E2EHTTPError(status: 0, body: "miner did not finish within 20 seconds")
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw E2EHTTPError(
                status: Int(process.terminationStatus),
                body: "miner failed: \(String(decoding: stderr, as: UTF8.self))"
            )
        }
        let result = try JSONDecoder().decode(E2EWorkerResult.self, from: stdout)
        guard result.workId == template.workID,
              result.status == "found",
              result.nonce == nonce else {
            throw E2EHTTPError(
                status: 0,
                body: "miner did not solve exact work: \(String(decoding: stdout, as: UTF8.self))"
            )
        }
        return try await parent.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
        )
    }

    private func signedTransaction(
        key: (privateKey: String, publicKey: String),
        chainPath: [String],
        accountActions: [AccountAction] = [],
        depositActions: [DepositAction] = [],
        genesisActions: [GenesisAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = [],
        fee: UInt64 = 0,
        nonce: UInt64
    ) throws -> Transaction {
        try signedTransaction(
            keys: [key],
            chainPath: chainPath,
            accountActions: accountActions,
            depositActions: depositActions,
            genesisActions: genesisActions,
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            fee: fee,
            nonce: nonce
        )
    }

    private func signedTransaction(
        keys: [(privateKey: String, publicKey: String)],
        chainPath: [String],
        accountActions: [AccountAction] = [],
        depositActions: [DepositAction] = [],
        genesisActions: [GenesisAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = [],
        fee: UInt64 = 0,
        nonce: UInt64
    ) throws -> Transaction {
        let body = TransactionBody(
            accountActions: accountActions,
            actions: [],
            depositActions: depositActions,
            genesisActions: genesisActions,
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: keys.map { CryptoUtils.createAddress(from: $0.publicKey) },
            fee: fee,
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        let signatures = try Dictionary(uniqueKeysWithValues: keys.map { key in
            let signature = try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: key.privateKey
            ))
            return (key.publicKey, signature)
        })
        return Transaction(signatures: signatures, body: header)
    }

    private func legacySignedTransaction(
        chainPath: [String],
        genesisActions: [GenesisAction] = [],
        keySeed: UInt8? = nil
    ) throws -> Transaction {
        let key: (privateKey: String, publicKey: String)
        if let keySeed {
            let raw = Data(repeating: keySeed, count: 32)
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: raw
            )
            key = (
                raw.map { String(format: "%02x", $0) }.joined(),
                "ed01" + privateKey.publicKey.rawRepresentation.map {
                    String(format: "%02x", $0)
                }.joined()
            )
        } else {
            key = CryptoUtils.generateKeyPair()
        }
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: genesisActions,
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        let header = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(
            CryptoUtils.sign(message: header.rawCID, privateKeyHex: key.privateKey)
        )
        return Transaction(signatures: [key.publicKey: signature], body: header)
    }
}

private struct E2EMinedBlock {
    let template: MiningTemplateResponse
    let response: SubmitWorkResponse
    let blockCID: String
}

private struct E2ECoordinatorResult: Decodable {
    let result: String
    let accepted: Bool
    let disposition: String
    let tipCID: String?
}

private struct E2EWorkerResult: Decodable {
    let workId: String
    let status: String
    let nonce: UInt64?
}

private extension Ivy {
    func installObserver(delegate: IvyDelegate) {
        self.delegate = delegate
    }
}

/// A real Ivy peer used only when an E2E assertion needs a causal wire event.
/// It speaks the normal overlay hello, but deliberately serves no content.
private actor E2EOverlayObserver: IvyDelegate {
    private static let overlayHelloTopic = "lattice.overlay.hello.v1"
    private static let blockAnnouncementTopic = "lattice.overlay.block.v1"

    private struct BlockAnnouncement: Decodable {
        let blockCID: String
    }

    private let ivy: Ivy
    private let hello: Data
    private let port: UInt16
    private let expectedPeerKey: String
    private var connectionCounts: [String: Int] = [:]
    private var announcementCounts: [String: Int] = [:]

    init(port: UInt16, bootstrapPeer: E2ENode.OverlayPeer, hello: ChainHello) throws {
        self.port = port
        expectedPeerKey = bootstrapPeer.publicKey
        self.hello = try hello.encode()
        ivy = Ivy(config: IvyConfig(
            signingKey: Curve25519.Signing.PrivateKey(),
            listenPort: port,
            bootstrapPeers: [PeerEndpoint(
                publicKey: bootstrapPeer.publicKey,
                host: "127.0.0.1",
                port: bootstrapPeer.port
            )],
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
    }

    func start() async throws {
        await MainActor.run { E2EPorts.release([port]) }
        do {
            await ivy.installObserver(delegate: self)
            try await ivy.start()
        } catch {
            try? await MainActor.run { try E2EPorts.reserve([port]) }
            throw error
        }
    }

    func stop() async {
        await ivy.stop()
        await MainActor.run { E2EPorts.release([port]) }
    }

    func waitForConnection(
        to publicKey: String,
        after count: Int = 0,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(timeout)
        while clock.now < deadline {
            if connectionCount(to: publicKey) > count { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for observer connection to \(publicKey)"
        )
    }

    func waitForAnnouncement(
        of blockCID: String,
        after count: Int = 0,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(timeout)
        while clock.now < deadline {
            if announcementCount(of: blockCID) > count { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for observer announcement of \(blockCID)"
        )
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        if peer.key.hex == expectedPeerKey {
            connectionCounts[peer.key.hex, default: 0] += 1
        }
        _ = await ivy.sendMessage(
            to: peer.id,
            topic: Self.overlayHelloTopic,
            payload: hello
        )
    }

    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        if message.topic == Self.overlayHelloTopic {
            let hello = hello
            Task {
                _ = await ivy.sendMessage(
                    to: peer.id,
                    topic: Self.overlayHelloTopic,
                    payload: hello
                )
            }
            return
        }
        guard message.topic == Self.blockAnnouncementTopic,
              peer.key.hex == expectedPeerKey,
              let announcement = try? JSONDecoder().decode(
                BlockAnnouncement.self,
                from: message.payload
              ) else {
            return
        }
        announcementCounts[announcement.blockCID, default: 0] += 1
    }

    func connectionCount(to publicKey: String) -> Int {
        connectionCounts[publicKey, default: 0]
    }

    func announcementCount(of blockCID: String) -> Int {
        announcementCounts[blockCID, default: 0]
    }
}

private struct E2EHTTPError: Error, LocalizedError {
    let status: Int
    let body: String

    var errorDescription: String? {
        "HTTP \(status): \(body)"
    }
}

private final class LoopbackTCPFaultProxy: @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let id = UUID()
        private let client: Int32
        private let upstream: Int32
        private let onClose: @Sendable (UUID) -> Void
        private let lock = NSLock()
        private var closed = false

        init(
            client: Int32,
            upstream: Int32,
            onClose: @escaping @Sendable (UUID) -> Void
        ) {
            self.client = client
            self.upstream = upstream
            self.onClose = onClose
            Self.suppressBrokenPipe(client)
            Self.suppressBrokenPipe(upstream)
        }

        func start() {
            DispatchQueue.global().async { [self] in
                pump(from: client, to: upstream)
            }
            DispatchQueue.global().async { [self] in
                pump(from: upstream, to: client)
            }
        }

        func close() {
            let shouldClose = lock.withLock {
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            Self.close(client)
            Self.close(upstream)
            onClose(id)
        }

        private func pump(from source: Int32, to destination: Int32) {
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let received = buffer.withUnsafeMutableBytes {
                    recv(source, $0.baseAddress, $0.count, 0)
                }
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { break }

                var sent = 0
                while sent < received {
                    let result = buffer.withUnsafeBytes { bytes in
                        let start = bytes.baseAddress!.advanced(by: sent)
                        #if canImport(Darwin)
                        return Darwin.send(
                            destination,
                            start,
                            received - sent,
                            0
                        )
                        #else
                        return Glibc.send(
                            destination,
                            start,
                            received - sent,
                            Int32(MSG_NOSIGNAL)
                        )
                        #endif
                    }
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else {
                        close()
                        return
                    }
                    sent += result
                }
            }
            close()
        }

        private static func suppressBrokenPipe(_ descriptor: Int32) {
            #if canImport(Darwin)
            var enabled: Int32 = 1
            _ = withUnsafePointer(to: &enabled) {
                setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            #endif
        }

        private static func close(_ descriptor: Int32) {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #else
            _ = Glibc.close(descriptor)
            #endif
        }
    }

    private let listenPort: UInt16
    private let targetPort: UInt16
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var running = false
    private var forwarding = true
    private var connectionCount = 0
    private var sessions: [UUID: Session] = [:]

    init(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }

    func start() throws {
        let descriptor = Self.socket()
        guard descriptor >= 0 else {
            throw E2EHTTPError(status: 0, body: "could not create fault proxy")
        }
        do {
            try Self.listen(descriptor, port: listenPort)
        } catch {
            Self.close(descriptor)
            throw error
        }
        lock.withLock {
            listener = descriptor
            running = true
            forwarding = true
        }
        DispatchQueue.global().async { [weak self] in
            self?.acceptConnections(listener: descriptor)
        }
    }

    func cut() {
        let active = lock.withLock {
            forwarding = false
            return Array(sessions.values)
        }
        for session in active { session.close() }
    }

    func heal() {
        lock.withLock {
            if running { forwarding = true }
        }
    }

    func stop() {
        let stopped: (Int32, [Session]) = lock.withLock {
            guard running else { return (-1, []) }
            running = false
            forwarding = false
            let descriptor = listener
            listener = -1
            let active = Array(sessions.values)
            sessions.removeAll()
            return (descriptor, active)
        }
        if stopped.0 >= 0 { Self.close(stopped.0) }
        for session in stopped.1 { session.close() }
    }

    func waitForConnections(
        _ expected: Int,
        timeout: Duration = .seconds(20)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(timeout)
        while clock.now < deadline {
            let connected = lock.withLock {
                connectionCount >= expected && !sessions.isEmpty
            }
            if connected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let observed = lock.withLock {
            "connections=\(connectionCount), active=\(sessions.count)"
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for fault proxy connection; \(observed)"
        )
    }

    func waitForNoActiveConnections(
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(timeout)
        while clock.now < deadline {
            if lock.withLock({ sessions.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw E2EHTTPError(
            status: 0,
            body: "timed out severing fault proxy connection"
        )
    }

    private func acceptConnections(listener: Int32) {
        while lock.withLock({ running }) {
            let client = accept(listener, nil, nil)
            if client < 0 && errno == EINTR { continue }
            guard client >= 0 else { return }
            guard lock.withLock({ running && forwarding }),
                  let upstream = Self.connect(to: targetPort) else {
                Self.close(client)
                continue
            }
            let session = Session(
                client: client,
                upstream: upstream,
                onClose: { [weak self] id in
                    self?.removeSession(id)
                }
            )
            let accepted = lock.withLock {
                guard running && forwarding else { return false }
                connectionCount += 1
                sessions[session.id] = session
                return true
            }
            guard accepted else {
                session.close()
                continue
            }
            session.start()
        }
    }

    private func removeSession(_ id: UUID) {
        _ = lock.withLock {
            sessions.removeValue(forKey: id)
        }
    }

    private static func socket() -> Int32 {
        #if canImport(Darwin)
        Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    private static func listen(_ descriptor: Int32, port: UInt16) throws {
        var reuseAddress: Int32 = 1
        guard withUnsafePointer(to: &reuseAddress, {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }) == 0 else {
            throw E2EHTTPError(status: 0, body: "could not configure fault proxy")
        }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            throw E2EHTTPError(status: 0, body: "could not listen for fault proxy")
        }
        #if canImport(Darwin)
        let listening = Darwin.listen(descriptor, 8)
        #else
        let listening = Glibc.listen(descriptor, 8)
        #endif
        guard listening == 0 else {
            throw E2EHTTPError(status: 0, body: "could not listen for fault proxy")
        }
    }

    private static func connect(to port: UInt16) -> Int32? {
        let descriptor = socket()
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
                #else
                Glibc.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
                #endif
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func close(_ descriptor: Int32) {
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }
}

@MainActor
private final class E2ENode {
    private static let requestTimeout: TimeInterval = 10

    struct Parent {
        let publicKey: String
        let factPort: UInt16
    }

    struct OverlayPeer {
        let publicKey: String
        let port: UInt16
    }

    struct Configuration {
        let name: String
        let chainPath: String
        let storage: URL
        let identity: E2EIdentity
        let overlayPort: UInt16
        let factPort: UInt16
        let rpcPort: UInt16
        let overlayPeers: [OverlayPeer]
        let parent: Parent?

        init(
            name: String,
            chainPath: String,
            storage: URL,
            identity: E2EIdentity,
            overlayPort: UInt16,
            factPort: UInt16,
            rpcPort: UInt16,
            overlayPeers: [OverlayPeer] = [],
            parent: Parent? = nil
        ) {
            self.name = name
            self.chainPath = chainPath
            self.storage = storage
            self.identity = identity
            self.overlayPort = overlayPort
            self.factPort = factPort
            self.rpcPort = rpcPort
            self.overlayPeers = overlayPeers
            self.parent = parent
        }
    }

    private let binary: URL
    private let configuration: Configuration
    private let logDirectory: URL
    private var overlayPeers: [OverlayPeer]
    private var process: Process?
    private var session: URLSession?
    private var logHandles: [FileHandle] = []
    private var launchCount = 0

    init(binary: URL, configuration: Configuration, logDirectory: URL) {
        self.binary = binary
        self.configuration = configuration
        self.logDirectory = logDirectory
        overlayPeers = configuration.overlayPeers
    }

    var storageURL: URL { configuration.storage }

    func setOverlayPeers(_ peers: [OverlayPeer]) {
        precondition(process?.isRunning != true, "stop a node before changing its peers")
        overlayPeers = peers
    }

    func start() throws {
        guard process?.isRunning != true else { return }
        launchCount += 1
        closeSession()
        try FileManager.default.createDirectory(
            at: configuration.storage,
            withIntermediateDirectories: true
        )
        let stdout = try openLog(named: "\(configuration.name)-\(launchCount).stdout.log")
        let stderr = try openLog(named: "\(configuration.name)-\(launchCount).stderr.log")
        let nextSession = URLSession(configuration: .ephemeral)
        let next = Process()
        next.executableURL = binary
        next.arguments = launchArguments()
        next.standardOutput = stdout
        next.standardError = stderr
        do {
            E2EPorts.release(reservedPorts)
            try next.run()
        } catch {
            try? E2EPorts.reserve(reservedPorts)
            nextSession.invalidateAndCancel()
            try? stdout.close()
            try? stderr.close()
            throw error
        }
        process = next
        session = nextSession
        logHandles = [stdout, stderr]
    }

    func stop() async throws {
        guard let process else {
            closeSession()
            return
        }
        var forced = false
        if process.isRunning {
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now + e2eScaled(.seconds(5))
            while process.isRunning && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                forced = true
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let reason = process.terminationReason
        let status = process.terminationStatus
        self.process = nil
        closeSession()
        closeLogs()
        try E2EPorts.reserve(reservedPorts)
        guard !forced, reason == .exit, status == 0 else {
            throw E2EHTTPError(
                status: Int(status),
                body: "node did not shut down cleanly: \(configuration.name)"
            )
        }
    }

    func forceTerminate() {
        guard let process else {
            closeSession()
            closeLogs()
            return
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        self.process = nil
        closeSession()
        closeLogs()
        try? E2EPorts.reserve(reservedPorts)
    }

    func suspend() throws {
        guard let process, process.isRunning else {
            throw E2EHTTPError(
                status: 0,
                body: "cannot suspend a stopped node: \(configuration.name)"
            )
        }
        guard kill(process.processIdentifier, SIGSTOP) == 0 else {
            throw E2EHTTPError(
                status: 0,
                body: "could not suspend node: \(configuration.name)"
            )
        }
    }

    func resume() throws {
        guard let process, process.isRunning else {
            throw E2EHTTPError(
                status: 0,
                body: "cannot resume a stopped node: \(configuration.name)"
            )
        }
        guard kill(process.processIdentifier, SIGCONT) == 0 else {
            throw E2EHTTPError(
                status: 0,
                body: "could not resume node: \(configuration.name)"
            )
        }
    }

    func releaseReservedPorts() {
        E2EPorts.release(reservedPorts)
    }

    func waitForStatus(
        timeout: Duration = .seconds(30),
        where predicate: @escaping (ChainServiceStatusResponse) -> Bool
    ) async throws -> ChainServiceStatusResponse {
        let clock = ContinuousClock()
        let deadline = clock.now + e2eScaled(timeout)
        var lastError: Error?
        var lastStatus: ChainServiceStatusResponse?
        while clock.now < deadline {
            do {
                let status = try await status()
                lastError = nil
                lastStatus = status
                if predicate(status) { return status }
            } catch {
                lastError = error
                if let process, !process.isRunning { break }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let observed = lastStatus.map {
            "phase=\($0.phase.rawValue), tip=\($0.tipCID ?? "nil"), height=\($0.height.map(String.init) ?? "nil"), mempool=\($0.mempoolCount)"
        } ?? "no status response"
        let lastFailure = lastError.map { "; last error: \($0.localizedDescription)" } ?? ""
        let processState: String
        if let process, process.isRunning {
            processState = "pid=\(process.processIdentifier), running"
        } else if let process {
            processState = "pid=\(process.processIdentifier), exited=\(process.terminationStatus) (\(process.terminationReason))"
        } else {
            processState = "no process"
        }
        let logPrefix = logDirectory.appendingPathComponent(
            "\(configuration.name)-\(launchCount)"
        ).path
        throw E2EHTTPError(
            status: 0,
            body: "timed out waiting for \(configuration.name) status; \(observed)\(lastFailure); launch=\(launchCount), \(processState), logs=\(logPrefix).{stdout,stderr}.log"
        )
    }

    func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request,
        timeout: TimeInterval? = nil,
        caller: String = #fileID,
        line: UInt = #line
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(
            request,
            timeout: timeout,
            caller: "\(caller):\(line)"
        )
    }

    var rpcURL: URL {
        baseURL
    }

    private func status() async throws -> ChainServiceStatusResponse {
        var request = URLRequest(url: baseURL.appending(path: "/v1/status"))
        request.httpMethod = "GET"
        return try await send(request)
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(configuration.rpcPort)")!
    }

    private var reservedPorts: [UInt16] {
        [
            configuration.overlayPort,
            configuration.factPort,
            configuration.rpcPort,
        ]
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        timeout: TimeInterval? = nil,
        caller: String? = nil
    ) async throws -> Response {
        var request = request
        request.timeoutInterval = timeout ?? Self.requestTimeout
        guard let session else {
            throw E2EHTTPError(
                status: 0,
                body: "node is not running: \(configuration.name)"
            )
        }
        var endpoint = request.url?.path ?? "<unknown endpoint>"
        if let caller {
            endpoint += " (from \(caller), node \(configuration.name))"
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw E2EHTTPError(
                status: 0,
                body: "\(endpoint): \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseBody = String(decoding: data, as: UTF8.self)
            throw E2EHTTPError(
                status: status,
                body: responseBody.isEmpty
                    ? endpoint
                    : "\(endpoint): \(responseBody)"
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func launchArguments() -> [String] {
        var arguments = [
            "--chain-path", configuration.chainPath,
            "--data-directory", configuration.storage.path,
            "--identity-key", configuration.identity.file.path,
            "--listen-port", String(configuration.overlayPort),
            "--fact-listen-port", String(configuration.factPort),
            "--rpc-port", String(configuration.rpcPort),
        ]
        if let parent = configuration.parent {
            arguments += ["--parent", "\(parent.publicKey)@127.0.0.1:\(parent.factPort)"]
        }
        for peer in overlayPeers {
            arguments += ["--peer", "\(peer.publicKey)@127.0.0.1:\(peer.port)"]
        }
        return arguments
    }

    private func openLog(named name: String) throws -> FileHandle {
        let url = logDirectory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private func closeLogs() {
        for handle in logHandles {
            try? handle.close()
        }
        logHandles.removeAll()
    }

    private func closeSession() {
        session?.invalidateAndCancel()
        session = nil
    }
}

@MainActor
private final class E2ECluster {
    private var nodes: [E2ENode] = []

    func add(_ node: E2ENode) {
        nodes.append(node)
    }

    func stopAll() async throws {
        for node in nodes.reversed() {
            try await node.stop()
            node.releaseReservedPorts()
        }
    }

    func forceTerminateAll() {
        for node in nodes.reversed() {
            node.forceTerminate()
            node.releaseReservedPorts()
        }
    }
}

private struct E2EIdentity {
    let privateKey: String
    let publicKey: String
    let file: URL
}

private final class E2EWorkspace {
    let url: URL
    let logs: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-node-e2e-\(UUID().uuidString)",
            isDirectory: true
        )
        logs = url.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func makeIdentity(named name: String, seed: UInt8? = nil) throws -> E2EIdentity {
        let pair: (privateKey: String, publicKey: String)
        if let seed {
            let raw = Data(repeating: seed, count: 32)
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: raw
            )
            pair = (
                raw.map { String(format: "%02x", $0) }.joined(),
                try PeerKey(
                    rawRepresentation: privateKey.publicKey.rawRepresentation
                ).hex
            )
        } else {
            pair = CryptoUtils.generateKeyPair()
        }
        let file = url.appendingPathComponent("\(name).key")
        try Data((pair.privateKey + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return E2EIdentity(
            privateKey: pair.privateKey,
            publicKey: pair.publicKey,
            file: file
        )
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}

private enum E2EBinary {
    static func latticeNode() throws -> URL {
        try executable(environment: "E2E_NODE_BIN", product: "lattice-node")
    }

    static func latticeMiningCoordinator() throws -> URL {
        try executable(
            environment: "E2E_COORDINATOR_BIN",
            product: "lattice-mining-coordinator"
        )
    }

    static func latticeMiner() throws -> URL {
        try executable(environment: "E2E_MINER_BIN", product: "lattice-miner")
    }

    private static func executable(
        environment variable: String,
        product: String
    ) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[variable], !configured.isEmpty {
            let binary = URL(fileURLWithPath: configured).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw E2EHTTPError(
                    status: 0,
                    body: "\(variable) is not executable: \(binary.path)"
                )
            }
            return binary
        }
        if let node = environment["E2E_NODE_BIN"], !node.isEmpty {
            let binary = URL(fileURLWithPath: node)
                .deletingLastPathComponent()
                .appendingPathComponent(product)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binary = repository.appendingPathComponent(".build/debug/\(product)")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw E2EHTTPError(
                status: 0,
                body: "build \(product) first or set \(variable) (looked for \(binary.path))"
            )
        }
        return binary
    }
}

@MainActor
private enum E2EPorts {
    private static var reservations: [UInt16: Int32] = [:]

    static func allocate(count: Int) throws -> [UInt16] {
        // Probe below the kernel's ephemeral range (32768+ on Linux,
        // 49152+ on macOS). Binding port 0 draws from that range, and in
        // the window between releasing a reservation and its daemon
        // binding it, any concurrent outbound connection on a shared
        // runner can be handed the same port as its source port — the
        // daemon then dies at launch with EADDRINUSE.
        var ports: [UInt16] = []
        var attempts = 0
        while ports.count < count {
            attempts += 1
            guard attempts <= 10_000 else {
                release(ports)
                throw E2EHTTPError(
                    status: 0,
                    body: "could not allocate test ports"
                )
            }
            let candidate = UInt16.random(in: 20_000...29_999)
            guard reservations[candidate] == nil,
                  let reservation = try? reservePort(candidate) else {
                continue
            }
            reservations[reservation.port] = reservation.descriptor
            ports.append(reservation.port)
        }
        return ports.sorted()
    }

    static func reserve(_ ports: [UInt16]) throws {
        var added: [UInt16] = []
        do {
            for port in Set(ports) where reservations[port] == nil {
                let reservation = try reservePort(port)
                reservations[reservation.port] = reservation.descriptor
                added.append(reservation.port)
            }
        } catch {
            release(added)
            throw error
        }
    }

    static func release(_ ports: [UInt16]) {
        for port in Set(ports) {
            guard let descriptor = reservations.removeValue(forKey: port) else {
                continue
            }
            _ = close(descriptor)
        }
    }

    private static func reservePort(
        _ requestedPort: UInt16
    ) throws -> (port: UInt16, descriptor: Int32) {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else {
            throw E2EHTTPError(status: 0, body: "could not allocate test port")
        }
        var reuseAddress: Int32 = 1
        let reuseResult = withUnsafePointer(to: &reuseAddress) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard reuseResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not configure test port")
        }

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not bind test port")
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            _ = close(descriptor)
            throw E2EHTTPError(status: 0, body: "could not read test port")
        }
        return (UInt16(bigEndian: bound.sin_port), descriptor)
    }
}
