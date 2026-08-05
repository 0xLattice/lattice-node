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
    func testChildBootstrapsFromRestartedParentAndAdvancesInLiveRound() async throws {
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
        let coordinator = try E2EBinary.latticeMiningCoordinator()
        let miner = try E2EBinary.latticeMiner()
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let childIdentity = try workspace.makeIdentity(named: "child")
        let ports = try E2EPorts.allocate(count: 6)

        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "nexus",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("nexus", isDirectory: true),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "child",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("child", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(
                    publicKey: parentPeerKey.hex,
                    factPort: ports[1]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(child)

        // A child may start before either its parent or its directory exists.
        // It owns no local genesis and remains awaiting its direct parent.
        try child.start()
        let awaitingGenesis = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingGenesis.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(awaitingGenesis.nexusGenesisCID, NexusGenesis.expectedBlockHash)

        try parent.start()
        let initialParent = try await parent.waitForStatus { status in
            status.phase == .active && status.chainPath == ["Nexus"]
        }
        XCTAssertEqual(initialParent.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(initialParent.tipCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(initialParent.height, 0)

        // The child is already connected or retrying its configured parent,
        // but an unissued directory grants it no hierarchy role or genesis.
        let awaitingDirectory = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingDirectory.chainPath, ["Nexus", "Payments"])

        let intent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        XCTAssertEqual(intent.chainPath, ["Nexus", "Payments"])

        try await submitLegacyGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )

        // Intent and anchor are not a child carrier. The child must still
        // await the separately accepted parent block and its direct proof.
        let awaitingCarrier = try await child.waitForStatus { status in
            status.phase == .awaitingGenesis && status.tipCID == nil
        }
        XCTAssertEqual(awaitingCarrier.chainPath, ["Nexus", "Payments"])

        let firstWork = try await mine(parent, mode: .deployment)
        XCTAssertTrue(firstWork.accepted)

        let activated = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(activated.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(activated.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(activated.height, 0)

        // This exercises the public child ingress → child mempool → parent
        // template → proof → child admission path with the legacy body-CID
        // signature format still accepted by the node.
        let childTransaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments"]
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: childTransaction)
        )
        let queued = try await child.waitForStatus { $0.mempoolCount == 1 }
        XCTAssertEqual(queued.mempoolCount, 1)

        // Abandon more than one full candidate window through the public RPC.
        // Distinct parent carriers must replace old local availability rather
        // than permanently exhausting the child. The latest real work remains
        // valid across a child restart before parent submission.
        var parentCarrierCIDs: Set<String> = []
        var latestTemplate: MiningTemplateResponse?
        let emptyChildrenCID =
            try HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Block>>()
            ).rawCID
        for _ in 0...16 {
            let template: MiningTemplateResponse = try await parent.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest()
            )
            XCTAssertNotEqual(template.block.children.rawCID, emptyChildrenCID)
            parentCarrierCIDs.insert(
                try BlockHeader(node: template.block).rawCID
            )
            latestTemplate = template
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(parentCarrierCIDs.count, 17)
        let retainedTemplate = try XCTUnwrap(latestTemplate)
        let retainedMidstate = ProofOfWork.midstate(for: retainedTemplate.block)
        var retainedNonce: UInt64 = 0
        while ProofOfWork.hash(
            midstate: retainedMidstate,
            nonce: retainedNonce
        ) > retainedTemplate.searchTarget {
            retainedNonce += 1
        }
        child.forceTerminate()
        let retainedWork: SubmitWorkResponse = try await parent.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(
                workID: retainedTemplate.workID,
                nonce: retainedNonce
            )
        )
        XCTAssertTrue(retainedWork.accepted)
        let progressedParentTip = try XCTUnwrap(retainedWork.tipCID)

        // Crash both processes in the exact handoff window: the child has
        // durably ACKed the candidate, but has not received the parent's proof.
        // Restart must recover that reservation through ordinary daemon state.
        parent.forceTerminate()

        try parent.start()
        _ = try await parent.waitForStatus { status in
            status.phase == .active && status.tipCID == progressedParentTip
        }
        try child.start()
        let progressed = try await child.waitForStatus { status in
            status.phase == .active
                && status.tipCID != intent.genesisCID
                && (status.height ?? 0) > (activated.height ?? 0)
                && status.mempoolCount == 0
        }
        XCTAssertNotEqual(progressed.tipCID, intent.genesisCID)
        let progressedTip = try XCTUnwrap(progressed.tipCID)
        let progressedHeight = try XCTUnwrap(progressed.height)

        // A further round through the shipped coordinator and worker verifies
        // the same recursive path through the production mining binaries.
        let coordinatorWork = try await mineWithCoordinator(
            parent,
            coordinator: coordinator,
            miner: miner
        )
        XCTAssertEqual(coordinatorWork.result, "submitted")
        XCTAssertTrue(coordinatorWork.accepted)
        XCTAssertEqual(coordinatorWork.disposition, "canonicalized")
        let finalParentTip = try XCTUnwrap(coordinatorWork.tipCID)
        let coordinatorChild = try await child.waitForStatus { status in
            status.phase == .active
                && (status.height ?? 0) > progressedHeight
        }
        let finalChildTip = try XCTUnwrap(coordinatorChild.tipCID)
        let finalChildHeight = try XCTUnwrap(coordinatorChild.height)

        // The accepted parent carrier and direct proof survive a parent
        // process restart while the live child retains its own projection.
        try await parent.stop()
        try parent.start()
        let restoredParent = try await parent.waitForStatus { status in
            status.phase == .active && status.tipCID == finalParentTip
        }
        XCTAssertEqual(restoredParent.tipCID, finalParentTip)
        let preservedChild = try await child.waitForStatus { status in
            status.phase == .active
                && status.tipCID == finalChildTip
                && status.height == finalChildHeight
        }
        XCTAssertEqual(preservedChild.height, finalChildHeight)

        // A child restores its own accepted forest; it does not need the
        // parent to re-bootstrap its genesis after a local process restart.
        try await child.stop()
        try child.start()
        let restoredChild = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == finalChildTip
        }
        XCTAssertEqual(restoredChild.height, finalChildHeight)

        // Parent and child reconnect independently after their process
        // restarts, so allow bounded physical root rounds for the next live
        // child candidate rather than assuming one scheduler turn.
        var reprogressed: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            guard let status = try? await child.waitForStatus(
                timeout: .seconds(2),
                where: { status in
                    status.phase == .active && (status.height ?? 0) > finalChildHeight
                }
            ) else { continue }
            reprogressed = status
            break
        }
        let finalChild = try XCTUnwrap(reprogressed)
        XCTAssertNotEqual(finalChild.tipCID, progressedTip)

        try await cluster.stopAll()
        passed = true
    }

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

    func testNestedHardGenesisConstrainsRootSearchAndActivates() async throws {
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
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let paymentsIdentity = try workspace.makeIdentity(named: "payments")
        let receiptsIdentity = try workspace.makeIdentity(named: "receipts")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let paymentsKey = try PeerKey(paymentsIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let payments = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: paymentsIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let receipts = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: receiptsIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(
                    publicKey: paymentsKey.hex,
                    factPort: ports[4]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(payments)
        cluster.add(receipts)

        try nexus.start()
        try payments.start()
        _ = try await waitForNexus(nexus)
        let paymentsIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: paymentsIntent,
            chainPath: ["Nexus"]
        )
        let paymentsWork = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(paymentsWork.accepted)
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.tipCID == paymentsIntent.genesisCID
        }

        try receipts.start()
        let hardTarget = UInt256.max / UInt256(16)
        let receiptsIntent = try await childIntent(
            on: payments,
            directory: "Receipts",
            timestamp: 2,
            target: hardTarget
        )
        try await submitGenesisAnchor(
            on: payments,
            intent: receiptsIntent,
            chainPath: ["Nexus", "Payments"]
        )

        var template: MiningTemplateResponse?
        for _ in 0..<20 {
            let next: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest(mode: .deployment)
            )
            if next.searchTarget == hardTarget {
                template = next
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let constrained = try XCTUnwrap(template)
        XCTAssertEqual(constrained.searchTarget, hardTarget)
        let rootBeforeMiss = try await nexus.waitForStatus { _ in true }
        let midstate = ProofOfWork.midstate(for: constrained.block)

        var miss: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: miss) <= hardTarget {
            miss += 1
        }
        do {
            let _: SubmitWorkResponse = try await nexus.post(
                "/v1/mining/work",
                body: SubmitWorkRequest(
                    workID: constrained.workID,
                    nonce: miss
                )
            )
            XCTFail("work missing a pending genesis target was accepted")
        } catch let error as E2EHTTPError {
            XCTAssertNotEqual(error.status, 0)
        }
        let unchanged = try await nexus.waitForStatus { _ in true }
        XCTAssertEqual(unchanged.tipCID, rootBeforeMiss.tipCID)
        XCTAssertEqual(unchanged.height, rootBeforeMiss.height)
        let stillPending = try await payments.waitForStatus { $0.mempoolCount == 1 }
        XCTAssertEqual(stillPending.mempoolCount, 1)

        var hit: UInt64 = 0
        while ProofOfWork.hash(midstate: midstate, nonce: hit) > hardTarget {
            hit += 1
        }
        let accepted: SubmitWorkResponse = try await nexus.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(workID: constrained.workID, nonce: hit)
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.durableChildProofs.map(\.directory), ["Payments"])
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0 && ($0.height ?? 0) > 0
        }
        let activated = try await receipts.waitForStatus {
            $0.phase == .active && $0.tipCID == receiptsIntent.genesisCID
        }
        XCTAssertEqual(activated.height, 0)

        try await cluster.stopAll()
        passed = true
    }

    func testIntermediateTargetMissStillCarriesGrandchildWork() async throws {
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
        let miner = try E2EBinary.latticeMiner()
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let paymentsIdentity = try workspace.makeIdentity(named: "payments")
        let receiptsIdentity = try workspace.makeIdentity(named: "receipts")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let paymentsKey = try PeerKey(paymentsIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let payments = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: paymentsIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let receipts = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: receiptsIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(
                    publicKey: paymentsKey.hex,
                    factPort: ports[4]
                )
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(payments)
        cluster.add(receipts)

        try nexus.start()
        try payments.start()
        try receipts.start()
        _ = try await waitForNexus(nexus)

        let genesisTimestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let hardTarget = UInt256.max / UInt256(16)
        let paymentsIntent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: genesisTimestamp,
            target: hardTarget
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: paymentsIntent,
            chainPath: ["Nexus"]
        )
        let paymentsTemplate: MiningTemplateResponse = try await nexus.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(mode: .deployment)
        )
        XCTAssertEqual(paymentsTemplate.searchTarget, hardTarget)
        let paymentsMidstate = ProofOfWork.midstate(for: paymentsTemplate.block)
        var paymentsNonce: UInt64 = 0
        while ProofOfWork.hash(midstate: paymentsMidstate, nonce: paymentsNonce)
                > hardTarget {
            paymentsNonce += 1
        }
        let paymentsDeployment: SubmitWorkResponse = try await nexus.post(
            "/v1/mining/work",
            body: SubmitWorkRequest(
                workID: paymentsTemplate.workID,
                nonce: paymentsNonce
            )
        )
        XCTAssertTrue(paymentsDeployment.accepted)
        _ = try await payments.waitForStatus {
            $0.phase == .active && $0.tipCID == paymentsIntent.genesisCID
        }

        let receiptsIntent = try await childIntent(
            on: payments,
            directory: "Receipts",
            timestamp: genesisTimestamp + 1
        )
        try await submitGenesisAnchor(
            on: payments,
            intent: receiptsIntent,
            chainPath: ["Nexus", "Payments"]
        )
        var receiptsDeployment: SubmitWorkResponse?
        for _ in 0..<20 {
            let template: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest(mode: .deployment)
            )
            guard template.searchTarget == hardTarget else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let midstate = ProofOfWork.midstate(for: template.block)
            var nonce: UInt64 = 0
            while ProofOfWork.hash(midstate: midstate, nonce: nonce) > hardTarget {
                nonce += 1
            }
            receiptsDeployment = try await nexus.post(
                "/v1/mining/work",
                body: SubmitWorkRequest(workID: template.workID, nonce: nonce)
            )
            break
        }
        let deployment = try XCTUnwrap(receiptsDeployment)
        XCTAssertTrue(deployment.accepted)
        XCTAssertEqual(deployment.durableChildProofs.map(\.directory), ["Payments"])
        let deployedPaymentsCID = try XCTUnwrap(
            deployment.durableChildProofs.first?.childCID
        )
        let receiptsBeforeCarrier = try await receipts.waitForStatus {
            $0.phase == .active && $0.tipCID == receiptsIntent.genesisCID
        }
        let paymentsBeforeCarrier = try await payments.waitForStatus {
            $0.phase == .active
                && $0.tipCID == deployedPaymentsCID
                && $0.mempoolCount == 0
        }
        let paymentsTip = try XCTUnwrap(paymentsBeforeCarrier.tipCID)
        let paymentsHeight = try XCTUnwrap(paymentsBeforeCarrier.height)

        let transaction = try legacySignedTransaction(
            chainPath: ["Nexus", "Payments", "Receipts"]
        )
        let _: SubmitTransactionResponse = try await receipts.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transaction)
        )
        _ = try await receipts.waitForStatus { $0.mempoolCount == 1 }

        // Descendant blocks are content-addressed volumes, so the public root
        // template commits to them without expanding their private bytes. The
        // configured targets give this round an observable black-box result:
        // the shared hash misses Payments but is accepted by Receipts.
        let selectedTemplate: MiningTemplateResponse = try await nexus.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest()
        )
        let maximumPaymentsTarget = hardTarget
            * UInt256(UInt64(ChainSpec.defaultMaxTargetChange))
        let carrierMidstate = ProofOfWork.midstate(for: selectedTemplate.block)
        var carrierNonce: UInt64 = 0
        var rootHash = ProofOfWork.hash(
            midstate: carrierMidstate,
            nonce: carrierNonce
        )
        while rootHash <= maximumPaymentsTarget {
            carrierNonce += 1
            rootHash = ProofOfWork.hash(
                midstate: carrierMidstate,
                nonce: carrierNonce
            )
        }
        XCTAssertEqual(selectedTemplate.searchTarget, .max)
        XCTAssertLessThan(hardTarget, .max)
        XCTAssertGreaterThan(rootHash, maximumPaymentsTarget)

        // Search the exact public template through the shipped worker, then
        // submit that worker's nonce through the public node RPC.
        let carrierWork = try await mineWithWorker(
            nexus,
            template: selectedTemplate,
            nonce: carrierNonce,
            miner: miner
        )
        XCTAssertTrue(carrierWork.accepted)
        XCTAssertEqual(carrierWork.disposition, .canonicalized)
        XCTAssertEqual(carrierWork.durableChildProofs.map(\.directory), ["Payments"])
        let receiptsAfterCarrier = try await receipts.waitForStatus {
            $0.phase == .active
                && $0.tipCID != receiptsBeforeCarrier.tipCID
                && $0.height == receiptsBeforeCarrier.height.map { $0 + 1 }
                && $0.mempoolCount == 0
        }
        XCTAssertNotEqual(receiptsAfterCarrier.tipCID, receiptsBeforeCarrier.tipCID)
        let unchangedPayments = try await payments.waitForStatus {
            $0.tipCID == paymentsTip && $0.height == paymentsHeight
        }
        XCTAssertEqual(unchangedPayments.tipCID, paymentsTip)
        XCTAssertEqual(unchangedPayments.height, paymentsHeight)

        try await cluster.stopAll()
        passed = true
    }

    func testSameChildPathReplicasFailOverAndConverge() async throws {
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
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let aIdentity = try workspace.makeIdentity(named: "payments-a")
        let bIdentity = try workspace.makeIdentity(named: "payments-b")
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let a = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-a",
            directory: "Payments",
            identity: aIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let b = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-b",
            directory: "Payments",
            identity: bIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        a.setOverlayPeers([try overlayPeer(identity: bIdentity, port: ports[6])])
        b.setOverlayPeers([try overlayPeer(identity: aIdentity, port: ports[3])])
        cluster.add(nexus)
        cluster.add(a)
        cluster.add(b)

        try nexus.start()
        try a.start()
        try b.start()
        _ = try await waitForNexus(nexus)
        let intent = try await childIntent(
            on: nexus,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        let aGenesis = try await a.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        let bGenesis = try await b.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        XCTAssertEqual(aGenesis.tipCID, bGenesis.tipCID)

        try await a.stop()
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments"]
            ))
        )
        var bProgress: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await b.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > (bGenesis.height ?? 0)
                }
            ) {
                bProgress = status
                break
            }
        }
        _ = try XCTUnwrap(bProgress)

        try a.start()
        let firstTip = try await waitForReplicaConvergenceStatus(
            a,
            b,
            excluding: intent.genesisCID
        )
        let firstTipCID = try XCTUnwrap(firstTip.tipCID)

        try await b.stop()
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: try legacySignedTransaction(
                chainPath: ["Nexus", "Payments"]
            ))
        )
        var aProgress: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await a.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > (firstTip.height ?? 0)
                }
            ) {
                aProgress = status
                break
            }
        }
        _ = try XCTUnwrap(aProgress)

        try b.start()
        let secondTipCID = try await waitForReplicaConvergence(
            a,
            b,
            excluding: firstTipCID
        )
        XCTAssertNotEqual(secondTipCID, firstTipCID)

        try await cluster.stopAll()
        passed = true
    }

    func testPartitionedChildReplicasCreateSiblingBranchesAndColdJoin()
        async throws
    {
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
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let aIdentity = try workspace.makeIdentity(named: "payments-a")
        let bIdentity = try workspace.makeIdentity(named: "payments-b")
        let coldIdentity = try workspace.makeIdentity(named: "payments-cold")
        let ownerA = CryptoUtils.generateKeyPair()
        let ownerB = CryptoUtils.generateKeyPair()
        let outputA = CryptoUtils.generateKeyPair()
        let outputB = CryptoUtils.generateKeyPair()
        let sink = CryptoUtils.generateKeyPair()
        let ownerAAddress = CryptoUtils.createAddress(from: ownerA.publicKey)
        let ownerBAddress = CryptoUtils.createAddress(from: ownerB.publicKey)
        let outputAAddress = CryptoUtils.createAddress(from: outputA.publicKey)
        let outputBAddress = CryptoUtils.createAddress(from: outputB.publicKey)
        let sinkAddress = CryptoUtils.createAddress(from: sink.publicKey)
        let childPath = ["Nexus", "Payments"]
        let nexusKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 12)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[3])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[6])
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let a = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-a",
            directory: "Payments",
            identity: aIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let b = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-b",
            directory: "Payments",
            identity: bIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let cold = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-cold",
            directory: "Payments",
            identity: coldIdentity,
            parentPublicKey: nexusKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        cold.setOverlayPeers([aPeer, bPeer])
        cluster.add(nexus)
        cluster.add(a)
        cluster.add(b)
        cluster.add(cold)

        try nexus.start()
        try a.start()
        try b.start()
        _ = try await waitForNexus(nexus)
        let genesisTransaction = try unsignedGenesisTransaction(
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: ownerAAddress, delta: 10),
                AccountAction(owner: ownerBAddress, delta: 10),
            ]
        )
        let intent: ChildDeployIntentResponse = try await nexus.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: "Payments",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 20,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [genesisTransaction],
                target: .max,
                timestamp: 1
            )
        )
        try await submitGenesisAnchor(
            on: nexus,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        _ = try await a.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }
        _ = try await b.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let transactionA = try signedTransaction(
            key: ownerA,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: ownerAAddress, delta: -1),
                AccountAction(owner: outputAAddress, delta: 1),
            ],
            nonce: 0
        )
        let transactionB = try signedTransaction(
            key: ownerB,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: ownerBAddress, delta: -1),
                AccountAction(owner: outputBAddress, delta: 1),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transactionA)
        )
        let _: SubmitTransactionResponse = try await b.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transactionB)
        )
        _ = try await a.waitForStatus { $0.mempoolCount == 1 }
        _ = try await b.waitForStatus { $0.mempoolCount == 1 }

        // Two miners obtain competing parent templates before either submits
        // work. Make the responding replica explicit through ordinary
        // stop/start operations; distinct timestamped candidates from one
        // replica are not evidence that both replicas answered.
        let emptyChildrenCID =
            try HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Block>>()
            ).rawCID
        try await b.stop()
        var firstTemplateResponse: MiningTemplateResponse?
        for _ in 0..<20 {
            let template: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest()
            )
            if template.block.children.rawCID != emptyChildrenCID {
                firstTemplateResponse = template
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let firstTemplate = try XCTUnwrap(firstTemplateResponse)

        try await a.stop()
        try b.start()
        _ = try await b.waitForStatus {
            $0.phase == .active
                && $0.tipCID == intent.genesisCID
                && $0.mempoolCount == 1
        }
        var secondTemplateResponse: MiningTemplateResponse?
        for _ in 0..<20 {
            let template: MiningTemplateResponse = try await nexus.post(
                "/v1/mining/templates",
                body: MiningTemplateRequest()
            )
            if template.block.children.rawCID != emptyChildrenCID {
                secondTemplateResponse = template
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let secondTemplate = try XCTUnwrap(secondTemplateResponse)
        XCTAssertNotEqual(
            firstTemplate.block.children.rawCID,
            secondTemplate.block.children.rawCID
        )

        try a.start()
        _ = try await a.waitForStatus {
            $0.phase == .active
                && $0.tipCID == intent.genesisCID
                && $0.mempoolCount == 1
        }

        let firstWork: SubmitWorkResponse
        do {
            firstWork = try await submitTemplate(firstTemplate, to: nexus)
        } catch {
            XCTFail("first sibling template submission failed: \(error)")
            throw error
        }
        XCTAssertTrue(firstWork.accepted)
        XCTAssertEqual(firstWork.durableChildProofs.count, 1)
        let firstProof = try XCTUnwrap(firstWork.durableChildProofs.first)
        XCTAssertEqual(firstProof.directory, "Payments")

        let secondWork: SubmitWorkResponse
        do {
            secondWork = try await submitTemplate(secondTemplate, to: nexus)
        } catch {
            XCTFail("second sibling template submission failed: \(error)")
            throw error
        }
        XCTAssertTrue(secondWork.accepted)
        XCTAssertEqual(secondWork.durableChildProofs.count, 1)
        let secondProof = try XCTUnwrap(secondWork.durableChildProofs.first)
        XCTAssertEqual(secondProof.directory, "Payments")
        XCTAssertNotEqual(firstProof.childCID, secondProof.childCID)

        let isolatedBranchCIDs = Set([
            firstProof.childCID,
            secondProof.childCID,
        ])
        let isolatedA = try await a.waitForStatus {
            $0.phase == .active
                && $0.tipCID.map(isolatedBranchCIDs.contains) == true
                && $0.mempoolCount == 0
        }
        let isolatedB = try await b.waitForStatus {
            $0.phase == .active
                && $0.tipCID.map(isolatedBranchCIDs.contains) == true
                && $0.mempoolCount == 0
        }
        XCTAssertEqual(
            Set([try XCTUnwrap(isolatedA.tipCID), try XCTUnwrap(isolatedB.tipCID)]),
            isolatedBranchCIDs
        )

        a.forceTerminate()
        b.forceTerminate()
        a.setOverlayPeers([bPeer])
        b.setOverlayPeers([aPeer])
        try a.start()
        try b.start()
        let convergedTip = try await waitForReplicaConvergence(
            a,
            b,
            excluding: intent.genesisCID
        )
        XCTAssertTrue(
            [firstProof.childCID, secondProof.childCID].contains(convergedTip)
        )

        // The losing branch's still-valid transaction returns to the pool.
        // Both peers must observe it before a normal parent round consumes it.
        _ = try await a.waitForStatus {
            $0.phase == .active && $0.tipCID == convergedTip
                && $0.mempoolCount == 1
        }
        _ = try await b.waitForStatus {
            $0.phase == .active && $0.tipCID == convergedTip
                && $0.mempoolCount == 1
        }
        var settledTip: String?
        for _ in 0..<5 {
            let settlement: SubmitWorkResponse
            do {
                settlement = try await mine(nexus)
            } catch {
                XCTFail("post-reorg settlement mining failed: \(error)")
                throw error
            }
            XCTAssertTrue(settlement.accepted)
            guard let next = try? await waitForReplicaConvergence(
                a,
                b,
                excluding: convergedTip
            ), let aStatus = try? await a.waitForStatus(
                timeout: .seconds(2),
                where: { $0.tipCID == next && $0.mempoolCount == 0 }
            ), let bStatus = try? await b.waitForStatus(
                timeout: .seconds(2),
                where: { $0.tipCID == next && $0.mempoolCount == 0 }
            ), aStatus.height == bStatus.height else { continue }
            settledTip = next
            break
        }
        let committedTip = try XCTUnwrap(
            settledTip,
            "losing child transaction was not requeued and committed"
        )

        // This transaction is valid only if both branch outputs survived the
        // reorg and settlement. Its inclusion proves state convergence, not
        // merely matching tip strings and empty pools.
        let spendBothOutputs = try signedTransaction(
            keys: [outputA, outputB],
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: outputAAddress, delta: -1),
                AccountAction(owner: outputBAddress, delta: -1),
                AccountAction(owner: sinkAddress, delta: 2),
            ],
            nonce: 0
        )
        do {
            let _: SubmitTransactionResponse = try await a.post(
                "/v1/transactions",
                body: SubmitTransactionRequest(transaction: spendBothOutputs)
            )
        } catch {
            XCTFail("dependent branch-state transaction failed: \(error)")
            throw error
        }
        _ = try await a.waitForStatus { $0.mempoolCount == 1 }
        var stateProvenStatus: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work: SubmitWorkResponse
            do {
                work = try await mine(nexus)
            } catch {
                XCTFail("dependent-state mining failed: \(error)")
                throw error
            }
            XCTAssertTrue(work.accepted)
            guard let next = try? await waitForReplicaConvergence(
                a,
                b,
                excluding: committedTip
            ), let status = try? await a.waitForStatus(
                timeout: .seconds(2),
                where: { $0.tipCID == next && $0.mempoolCount == 0 }
            ), status.phase == .active else { continue }
            stateProvenStatus = status
            break
        }
        let durableState = try XCTUnwrap(
            stateProvenStatus,
            "dependent spend did not prove both branch effects"
        )
        let durableHeight = try XCTUnwrap(durableState.height)

        a.forceTerminate()
        b.forceTerminate()
        try a.start()
        try b.start()
        let recovered = try await waitForReplicaConvergenceStatus(
            a,
            b,
            excluding: intent.genesisCID,
            minimumHeight: durableHeight
        )
        let recoveredTip = try XCTUnwrap(recovered.tipCID)

        // Spending the pre-restart output proves durable state recovery even
        // when queued parent evidence advances a replica past the observed CID.
        let spendRecoveredState = try signedTransaction(
            key: sink,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: sinkAddress, delta: -2),
                AccountAction(owner: ownerAAddress, delta: 2),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: spendRecoveredState)
        )
        _ = try await a.waitForStatus { $0.mempoolCount == 1 }
        var finalTip: String?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            guard let next = try? await waitForReplicaConvergence(
                a,
                b,
                excluding: recoveredTip
            ), let aStatus = try? await a.waitForStatus(
                timeout: .seconds(2),
                where: { $0.tipCID == next && $0.mempoolCount == 0 }
            ), let bStatus = try? await b.waitForStatus(
                timeout: .seconds(2),
                where: { $0.tipCID == next && $0.mempoolCount == 0 }
            ), aStatus.height == bStatus.height else { continue }
            finalTip = next
            break
        }
        let coldJoinTip = try XCTUnwrap(
            finalTip,
            "recovered branch state was not spendable"
        )

        try cold.start()
        let coldStatus = try await cold.waitForStatus(
            timeout: .seconds(60),
            where: { $0.phase == .active && $0.tipCID == coldJoinTip }
        )
        XCTAssertEqual(coldStatus.tipCID, coldJoinTip)

        try await cluster.stopAll()
        passed = true
    }

    func testParentDescendantsDoNotFlowThroughAncestorCarrierAfterPartitionHeal()
        async throws
    {
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
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let forkIdentity = try workspace.makeIdentity(named: "canonical-fork")
        let sideIdentity = try workspace.makeIdentity(named: "side-fork")
        let childIdentity = try workspace.makeIdentity(named: "payments")
        let laggingIdentity = try workspace.makeIdentity(named: "payments-lagging")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 16)
        let parentPeer = try overlayPeer(identity: parentIdentity, port: ports[0])
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "canonical-fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let side = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "side-fork",
            identity: sideIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let child = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: childIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let lagging = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-lagging",
            directory: "Payments",
            identity: laggingIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[12],
            factPort: ports[13],
            rpcPort: ports[14]
        )
        cluster.add(parent)
        cluster.add(fork)
        cluster.add(side)
        cluster.add(child)
        cluster.add(lagging)

        try parent.start()
        try fork.start()
        try child.start()
        try lagging.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)
        _ = try await child.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }
        _ = try await lagging.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }

        // Q is a three-grind Nexus branch prepared behind a real partition.
        // None of its prefix work covers a Payments block.
        let q1 = try await mineBlock(fork)
        let q2 = try await mineBlock(fork)
        let q3 = try await mineBlock(fork)
        XCTAssertEqual(
            q1.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )
        XCTAssertEqual(q2.template.block.parent?.rawCID, q1.blockCID)
        XCTAssertEqual(q3.template.block.parent?.rawCID, q2.blockCID)

        // P1 introduces child genesis A on the competing Nexus branch. The
        // child activates from accepted evidence, not a parent tip command.
        let aIntent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: aIntent,
            chainPath: ["Nexus"]
        )
        let p1 = try await mineBlock(parent, mode: .deployment)
        XCTAssertTrue(p1.response.accepted)
        XCTAssertEqual(
            p1.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )
        _ = try await child.waitForStatus {
            $0.phase == .active && $0.tipCID == aIntent.genesisCID
        }
        _ = try await waitForTip(lagging, aIntent.genesisCID)

        // S retains the exact P1 branch before Q is revealed. It later adds
        // work below P1 while that Nexus branch is noncanonical.
        side.setOverlayPeers([
            try overlayPeer(identity: parentIdentity, port: ports[0])
        ])
        try side.start()
        _ = try await waitForTip(side, p1.blockCID)
        try await side.stop()
        side.setOverlayPeers([])

        // Healing Q changes only Nexus canonicity. The sole Payments root A
        // remains canonical because parent canonicity is not child weight.
        try await fork.stop()
        fork.setOverlayPeers([
            try overlayPeer(identity: parentIdentity, port: ports[0])
        ])
        try fork.start()
        _ = try await waitForTip(parent, q3.blockCID)
        _ = try await waitForTip(child, aIntent.genesisCID)
        _ = try await waitForTip(lagging, aIntent.genesisCID)
        try await fork.stop()

        // Q has no Payments entry, so it can introduce a distinct genesis B
        // for the same absolute child path. Freeze the live child only across
        // the parent candidate deadline so Q4 cannot also include A. The
        // process itself never restarts: its later A -> B move must come from
        // the live parent-work delta. Keep the lagging replica offline for the
        // independent reconnect/full-snapshot assertion.
        try child.suspend()
        try await lagging.stop()
        let bIntent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 2,
            target: UInt256.max / UInt256(2)
        )
        XCTAssertNotEqual(aIntent.genesisCID, bIntent.genesisCID)
        try await submitGenesisAnchor(
            on: parent,
            intent: bIntent,
            chainPath: ["Nexus"]
        )
        let q4 = try await mineBlock(
            parent,
            mode: .deployment,
            requestTimeout: 60
        )
        XCTAssertEqual(q4.template.block.parent?.rawCID, q3.blockCID)
        try child.resume()

        let aInitialWork = WorkSum(max(
            workForTarget(p1.template.block.target),
            workForTarget(aIntent.genesisBlock.target)
        ))
        let bWork = WorkSum(max(
            workForTarget(q4.template.block.target),
            workForTarget(bIntent.genesisBlock.target)
        ))
        XCTAssertGreaterThan(bWork, aInitialWork)

        _ = try await waitForTip(child, bIntent.genesisCID)
        try lagging.start()
        _ = try await waitForTip(lagging, bIntent.genesisCID)
        try await lagging.stop()

        // P2 and P3 descend from A's carrier but do not directly commit to a
        // Payments block. Accepting them must not assign their grinds to A.
        try side.start()
        _ = try await waitForTip(side, p1.blockCID)
        let p2 = try await mineBlock(side)
        let p3 = try await mineBlock(side)
        XCTAssertEqual(p2.template.block.parent?.rawCID, p1.blockCID)
        XCTAssertEqual(p3.template.block.parent?.rawCID, p2.blockCID)
        try await side.stop()
        let observer = try E2EOverlayObserver(
            port: ports[15],
            bootstrapPeer: parentPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"]
            )
        )
        addTeardownBlock { await observer.stop() }
        try await observer.start()
        try await observer.waitForConnection(to: parentPeer.publicKey)
        let p3Announcements = await observer.announcementCount(of: p3.blockCID)
        side.setOverlayPeers([
            parentPeer
        ])
        try side.start()
        try await observer.waitForAnnouncement(
            of: p3.blockCID,
            after: p3Announcements
        )
        XCTAssertGreaterThan(bWork, aInitialWork)
        let pRootWork = WorkSum(workForTarget(p1.template.block.target))
            + WorkSum(workForTarget(p2.template.block.target))
            + WorkSum(workForTarget(p3.template.block.target))
        let qRootWork = WorkSum(workForTarget(q1.template.block.target))
            + WorkSum(workForTarget(q2.template.block.target))
            + WorkSum(workForTarget(q3.template.block.target))
            + WorkSum(workForTarget(q4.template.block.target))
        XCTAssertGreaterThan(qRootWork, pRootWork)

        _ = try await waitForTip(child, bIntent.genesisCID)
        try lagging.start()
        _ = try await waitForTip(lagging, bIntent.genesisCID)
        let unchangedParent = try await parent.waitForStatus { _ in true }
        XCTAssertEqual(unchangedParent.tipCID, q4.blockCID)
        XCTAssertNotEqual(unchangedParent.tipCID, p3.blockCID)
        await observer.stop()
        try await lagging.stop()

        // Recovery owns the same projection without either branch source.
        try await side.stop()
        child.forceTerminate()
        parent.forceTerminate()
        try parent.start()
        try child.start()
        _ = try await waitForTip(parent, q4.blockCID)
        _ = try await waitForTip(child, bIntent.genesisCID)

        try await cluster.stopAll()
        passed = true
    }

    func testAncestorDescendantsWithoutDirectCommitmentsDoNotReweightNestedChildren()
        async throws
    {
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
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let forkIdentity = try workspace.makeIdentity(named: "canonical-fork")
        let sideIdentity = try workspace.makeIdentity(named: "side-fork")
        let middleIdentity = try workspace.makeIdentity(named: "payments")
        let leafIdentity = try workspace.makeIdentity(named: "receipts")
        let lateLeafIdentity = try workspace.makeIdentity(named: "receipts-late")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let middleKey = try PeerKey(middleIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 19)
        let parentPeer = try overlayPeer(identity: parentIdentity, port: ports[0])
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "canonical-fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let side = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "side-fork",
            identity: sideIdentity,
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        let middle = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments",
            directory: "Payments",
            identity: middleIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let leaf = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                identity: leafIdentity,
                overlayPort: ports[12],
                factPort: ports[13],
                rpcPort: ports[14],
                parent: .init(publicKey: middleKey.hex, factPort: ports[10])
            ),
            logDirectory: workspace.logs
        )
        let lateLeaf = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "receipts-late",
                chainPath: "Nexus/Payments/Receipts",
                storage: workspace.url.appendingPathComponent(
                    "receipts-late",
                    isDirectory: true
                ),
                identity: lateLeafIdentity,
                overlayPort: ports[15],
                factPort: ports[16],
                rpcPort: ports[17],
                parent: .init(publicKey: middleKey.hex, factPort: ports[10])
            ),
            logDirectory: workspace.logs
        )
        for node in [parent, fork, side, middle, leaf, lateLeaf] {
            cluster.add(node)
        }

        try parent.start()
        try fork.start()
        try middle.start()
        try leaf.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)
        _ = try await middle.waitForStatus { $0.phase == .awaitingGenesis }
        _ = try await leaf.waitForStatus { $0.phase == .awaitingGenesis }

        // Five ordinary blocks give Q enough root-only work to remain Nexus'
        // canonical branch after all four later P-side grinds arrive.
        var qTip = NexusGenesis.expectedBlockHash
        for _ in 0..<5 {
            let block = try await mineBlock(fork)
            XCTAssertEqual(block.template.block.parent?.rawCID, qTip)
            qTip = block.blockCID
        }

        // On P, Payments A contributes two work per physical root. Receipts A
        // contributes two on the second root while its middle branch starts
        // at four. (Work uses the inclusive chainwork formula: workForTarget(max/3)
        // is floor(2^256/(target+1)) == 2, not the old exclusive 3.)
        let middleATarget = UInt256.max / UInt256(2)
        let leafATarget = UInt256.max / UInt256(3)
        XCTAssertEqual(workForTarget(middleATarget), UInt256(2))
        XCTAssertEqual(workForTarget(leafATarget), UInt256(2))
        let middleA = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1,
            target: middleATarget
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: middleA,
            chainPath: ["Nexus"]
        )
        let p1 = try await mineBlock(parent, mode: .deployment)
        _ = try await waitForTip(middle, middleA.genesisCID)

        let leafA = try await childIntent(
            on: middle,
            directory: "Receipts",
            timestamp: 2,
            target: leafATarget
        )
        try await submitGenesisAnchor(
            on: middle,
            intent: leafA,
            chainPath: ["Nexus", "Payments"]
        )
        let p2 = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(p2.template.block.parent?.rawCID, p1.blockCID)
        _ = try await waitForTip(leaf, leafA.genesisCID)

        // Preserve P behind a real partition before Q is revealed.
        side.setOverlayPeers([parentPeer])
        try side.start()
        _ = try await waitForTip(side, p2.blockCID)
        try await side.stop()
        side.setOverlayPeers([])

        try await fork.stop()
        fork.setOverlayPeers([parentPeer])
        try fork.start()
        _ = try await waitForTip(parent, qTip)
        try await fork.stop()

        // Payments B contributes four on both of its physical roots. It
        // therefore becomes the middle tip with weight eight. Its Receipts base
        // sees only the second root and starts at five, ahead of Receipts A's
        // two. (Inclusive chainwork: workForTarget(max/5) == 4.)
        try await leaf.stop()
        try await middle.stop()
        let middleBTarget = UInt256.max / UInt256(5)
        XCTAssertEqual(workForTarget(middleBTarget), UInt256(4))
        let middleB = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 3,
            target: middleBTarget
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: middleB,
            chainPath: ["Nexus"]
        )
        let qCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(qCarrier.template.block.parent?.rawCID, qTip)

        try middle.start()
        _ = try await waitForTip(middle, middleB.genesisCID)
        try leaf.start()
        _ = try await waitForTip(leaf, leafA.genesisCID)
        let leafBTarget = UInt256.max / UInt256(6)
        XCTAssertEqual(workForTarget(leafBTarget), UInt256(5))
        let leafB = try await childIntent(
            on: middle,
            directory: "Receipts",
            timestamp: 4,
            target: leafBTarget
        )
        try await submitGenesisAnchor(
            on: middle,
            intent: leafB,
            chainPath: ["Nexus", "Payments"]
        )
        let qLeafCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertEqual(qLeafCarrier.template.block.parent?.rawCID, qCarrier.blockCID)
        let middleBStatus = try await middle.waitForStatus {
            $0.tipCID != middleB.genesisCID && $0.height == 1
        }
        let middleBTip = try XCTUnwrap(middleBStatus.tipCID)
        _ = try await waitForTip(leaf, leafB.genesisCID)

        // Four pure Nexus descendants extend P but contain no direct Payments
        // or Receipts commitments. They must reweight neither descendant.
        try side.start()
        _ = try await waitForTip(side, p2.blockCID)
        var pTip = p2.blockCID
        for _ in 0..<4 {
            let block = try await mineBlock(side)
            XCTAssertEqual(block.template.block.parent?.rawCID, pTip)
            pTip = block.blockCID
        }
        try await side.stop()
        let observer = try E2EOverlayObserver(
            port: ports[18],
            bootstrapPeer: parentPeer,
            hello: ChainHello(
                nexusGenesisCID: NexusGenesis.expectedBlockHash,
                chainPath: ["Nexus"]
            )
        )
        addTeardownBlock { await observer.stop() }
        try await observer.start()
        try await observer.waitForConnection(to: parentPeer.publicKey)
        let pTipAnnouncements = await observer.announcementCount(of: pTip)
        side.setOverlayPeers([parentPeer])
        try side.start()
        try await observer.waitForAnnouncement(
            of: pTip,
            after: pTipAnnouncements
        )
        _ = try await waitForTip(leaf, leafB.genesisCID)
        let unchangedMiddle = try await middle.waitForStatus { _ in true }
        XCTAssertEqual(unchangedMiddle.tipCID, middleBTip)
        let unchangedParent = try await parent.waitForStatus { _ in true }
        XCTAssertEqual(unchangedParent.tipCID, qLeafCarrier.blockCID)
        XCTAssertNotEqual(unchangedParent.tipCID, pTip)
        await observer.stop()

        // A fresh leaf and crash-restarted hierarchy must independently derive
        // the same split decision from durable parent facts.
        try lateLeaf.start()
        _ = try await waitForTip(lateLeaf, leafB.genesisCID)
        try await side.stop()
        lateLeaf.forceTerminate()
        leaf.forceTerminate()
        middle.forceTerminate()
        parent.forceTerminate()
        try parent.start()
        try middle.start()
        try leaf.start()
        try lateLeaf.start()
        _ = try await waitForTip(parent, qLeafCarrier.blockCID)
        _ = try await waitForTip(middle, middleBTip)
        _ = try await waitForTip(leaf, leafB.genesisCID)
        _ = try await waitForTip(lateLeaf, leafB.genesisCID)

        try await cluster.stopAll()
        passed = true
    }

    func testStoppedDirectChildDoesNotBlockHealthySiblingRound() async throws {
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
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let nexusPeerKey = try PeerKey(nexusIdentity.publicKey)
        let healthyIdentity = try workspace.makeIdentity(named: "healthy")
        let stoppedIdentity = try workspace.makeIdentity(named: "stopped")
        let ports = try E2EPorts.allocate(count: 9)

        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let healthy = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "healthy",
                chainPath: "Nexus/Healthy",
                storage: workspace.url.appendingPathComponent(
                    "healthy",
                    isDirectory: true
                ),
                identity: healthyIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: nexusPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let stopped = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "stopped",
                chainPath: "Nexus/Stopped",
                storage: workspace.url.appendingPathComponent(
                    "stopped",
                    isDirectory: true
                ),
                identity: stoppedIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: nexusPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(nexus)
        cluster.add(healthy)
        cluster.add(stopped)

        try nexus.start()
        _ = try await waitForNexus(nexus)

        let healthyIntent = try await childIntent(
            on: nexus,
            directory: "Healthy",
            timestamp: 1
        )
        let stoppedIntent = try await childIntent(
            on: nexus,
            directory: "Stopped",
            timestamp: 2
        )
        let anchor = try legacySignedTransaction(
            chainPath: ["Nexus"],
            genesisActions: [
                GenesisAction(
                    directory: healthyIntent.directory,
                    blockCID: healthyIntent.genesisCID
                ),
                GenesisAction(
                    directory: stoppedIntent.directory,
                    blockCID: stoppedIntent.genesisCID
                ),
            ]
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
        let deployment = try await mine(nexus, mode: .deployment)
        XCTAssertTrue(deployment.accepted)

        try healthy.start()
        try stopped.start()
        let healthyGenesis = try await healthy.waitForStatus { status in
            status.phase == .active && status.tipCID == healthyIntent.genesisCID
        }
        let stoppedGenesis = try await stopped.waitForStatus { status in
            status.phase == .active && status.tipCID == stoppedIntent.genesisCID
        }
        XCTAssertEqual(healthyGenesis.height, 0)
        XCTAssertEqual(stoppedGenesis.height, 0)

        // Both real child daemons must first answer a live contextual request.
        // That distinguishes the later SIGSTOP from an unissued or merely
        // configured sibling.
        let _: SubmitTransactionResponse = try await healthy.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus", "Healthy"])
            )
        )
        var warmedHealthy: ChainServiceStatusResponse?
        var warmedStopped: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            guard
                let healthyStatus = try? await healthy.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active
                            && (status.height ?? 0) > 0
                            && status.mempoolCount == 0
                    }
                ),
                let stoppedStatus = try? await stopped.waitForStatus(
                    timeout: .seconds(2),
                    where: { status in
                        status.phase == .active && (status.height ?? 0) > 0
                    }
                )
            else { continue }
            warmedHealthy = healthyStatus
            warmedStopped = stoppedStatus
            break
        }
        let healthyBeforeStop = try XCTUnwrap(warmedHealthy)
        let stoppedBeforeStop = try XCTUnwrap(warmedStopped)
        let healthyHeight = try XCTUnwrap(healthyBeforeStop.height)
        let stoppedTip = try XCTUnwrap(stoppedBeforeStop.tipCID)
        let stoppedHeight = try XCTUnwrap(stoppedBeforeStop.height)

        // SIGSTOP preserves the authenticated private-Ivy session but prevents
        // this direct child from replying. Every Nexus round remains bounded,
        // and repeated real rounds must still carry the healthy sibling.
        try stopped.suspend()
        let _: SubmitTransactionResponse = try await healthy.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(
                transaction: try legacySignedTransaction(chainPath: ["Nexus", "Healthy"])
            )
        )
        _ = try await healthy.waitForStatus { $0.mempoolCount == 1 }
        var healthyAfterStop: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            if let status = try? await healthy.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.phase == .active
                        && ($0.height ?? 0) > healthyHeight
                        && $0.mempoolCount == 0
                }
            ) {
                healthyAfterStop = status
                break
            }
        }
        XCTAssertNotEqual(
            try XCTUnwrap(healthyAfterStop).tipCID,
            healthyBeforeStop.tipCID
        )

        // The stopped child reopens its pre-stop durable projection. Its
        // hierarchy recovery remains independent from healthy sibling progress.
        stopped.forceTerminate()
        try stopped.start()
        let recoveredStopped = try await stopped.waitForStatus { status in
            status.phase == .active && status.tipCID == stoppedTip
        }
        XCTAssertEqual(recoveredStopped.height, stoppedHeight)

        try await cluster.stopAll()
        passed = true
    }

    func testFreshChildBootstrapsFromDurableParentSideBranchAfterReorg() async throws {
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
        let parentIdentity = try workspace.makeIdentity(named: "parent")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let forkIdentity = try workspace.makeIdentity(named: "fork")
        let childIdentity = try workspace.makeIdentity(named: "child")
        let ports = try E2EPorts.allocate(count: 9)
        let forkPeer = try overlayPeer(identity: forkIdentity, port: ports[3])

        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "parent",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "fork",
            identity: forkIdentity,
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "child",
                chainPath: "Nexus/Payments",
                storage: workspace.url.appendingPathComponent("child", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(fork)
        cluster.add(child)

        try parent.start()
        try fork.start()
        _ = try await waitForNexus(parent)
        _ = try await waitForNexus(fork)

        let intent = try await childIntent(
            on: parent,
            directory: "Payments",
            timestamp: 1
        )
        try await submitLegacyGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let parentCarrier = try await mineBlock(parent, mode: .deployment)
        XCTAssertTrue(parentCarrier.response.accepted)
        XCTAssertEqual(parentCarrier.response.tipCID, parentCarrier.blockCID)
        XCTAssertEqual(
            parentCarrier.template.block.parent?.rawCID,
            NexusGenesis.expectedBlockHash
        )

        // The fork is created independently before either process has an
        // overlay edge, so it has no route to a Payments candidate.
        let forkOne = try await mineBlock(fork)
        let forkTwo = try await mineBlock(fork)
        XCTAssertTrue(forkOne.response.accepted)
        XCTAssertTrue(forkTwo.response.accepted)
        XCTAssertEqual(forkOne.template.block.parent?.rawCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(forkTwo.template.block.parent?.rawCID, forkOne.blockCID)
        _ = try await waitForTip(fork, forkTwo.blockCID)
        let parentWork = WorkSum(workForTarget(parentCarrier.template.block.target))
        let forkWork = WorkSum(workForTarget(forkOne.template.block.target))
            + WorkSum(workForTarget(forkTwo.template.block.target))
        XCTAssertGreaterThan(forkWork, parentWork)

        // The direct parent retains the accepted Payments proof even after its
        // canonical pointer moves to the independently mined fork.
        try await parent.stop()
        parent.setOverlayPeers([forkPeer])
        try parent.start()
        _ = try await waitForTip(parent, forkTwo.blockCID)
        try await fork.stop()
        parent.forceTerminate()
        parent.setOverlayPeers([])
        try parent.start()
        _ = try await waitForTip(parent, forkTwo.blockCID)

        // A new child has no overlay peer and the parent's canonical fork has
        // no Payments block. Activation can therefore only use the parent's
        // durable proof and genesis link for the accepted side branch above.
        try child.start()
        let activated = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(activated.chainPath, ["Nexus", "Payments"])
        XCTAssertEqual(activated.nexusGenesisCID, NexusGenesis.expectedBlockHash)
        XCTAssertEqual(activated.height, 0)
        _ = try await waitForTip(parent, forkTwo.blockCID)

        try await parent.stop()
        child.forceTerminate()
        try child.start()
        let offlineRecoveredChild = try await child.waitForStatus { status in
            status.phase == .active
                && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(offlineRecoveredChild.height, 0)
        try parent.start()
        _ = try await parent.waitForStatus { $0.phase == .active }
        let recoveredChild = try await child.waitForStatus { status in
            status.phase == .active && status.tipCID == intent.genesisCID
        }
        XCTAssertEqual(recoveredChild.height, 0)

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

    func testVariableRateExchangeSurvivesAdversarialChildPool() async throws {
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
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let childIdentity = try workspace.makeIdentity(named: "market")
        let lateIdentity = try workspace.makeIdentity(named: "market-late")
        let parentPeerKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 9)
        let parent = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "nexus",
                chainPath: "Nexus",
                storage: workspace.url.appendingPathComponent("nexus", isDirectory: true),
                identity: parentIdentity,
                overlayPort: ports[0],
                factPort: ports[1],
                rpcPort: ports[2]
            ),
            logDirectory: workspace.logs
        )
        let child = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "market",
                chainPath: "Nexus/Market",
                storage: workspace.url.appendingPathComponent("market", isDirectory: true),
                identity: childIdentity,
                overlayPort: ports[3],
                factPort: ports[4],
                rpcPort: ports[5],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        let late = E2ENode(
            binary: binary,
            configuration: E2ENode.Configuration(
                name: "market-late",
                chainPath: "Nexus/Market",
                storage: workspace.url.appendingPathComponent("market-late", isDirectory: true),
                identity: lateIdentity,
                overlayPort: ports[6],
                factPort: ports[7],
                rpcPort: ports[8],
                overlayPeers: [try overlayPeer(identity: childIdentity, port: ports[3])],
                parent: .init(publicKey: parentPeerKey.hex, factPort: ports[1])
            ),
            logDirectory: workspace.logs
        )
        cluster.add(parent)
        cluster.add(child)
        cluster.add(late)

        try parent.start()
        try child.start()
        _ = try await waitForNexus(parent)
        _ = try await child.waitForStatus {
            $0.phase == .awaitingGenesis && $0.tipCID == nil
        }

        let seller = CryptoUtils.generateKeyPair()
        let buyer = CryptoUtils.generateKeyPair()
        let attacker = CryptoUtils.generateKeyPair()
        let witness = CryptoUtils.generateKeyPair()
        let sink = CryptoUtils.generateKeyPair()
        let sellerAddress = CryptoUtils.createAddress(from: seller.publicKey)
        let buyerAddress = CryptoUtils.createAddress(from: buyer.publicKey)
        let attackerAddress = CryptoUtils.createAddress(from: attacker.publicKey)
        let witnessAddress = CryptoUtils.createAddress(from: witness.publicKey)
        let sinkAddress = CryptoUtils.createAddress(from: sink.publicKey)
        let childPath = ["Nexus", "Market"]
        let depositA: UInt64 = 100
        let demandA: UInt64 = 250
        let nonceA: UInt128 = 7
        let depositB: UInt64 = 50
        let demandB: UInt64 = 125
        let nonceB: UInt128 = 8

        let childGenesisTransaction = try unsignedGenesisTransaction(
            chainPath: childPath,
            accountActions: [AccountAction(owner: sellerAddress, delta: 1_000)]
        )
        let intent: ChildDeployIntentResponse = try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: "Market",
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 1_000,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [childGenesisTransaction],
                target: .max,
                timestamp: 1
            )
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let buyerReward = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(demandA + demandB)
            )],
            nonce: 0
        )
        let deployment = try await mineBlock(
            parent,
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: buyerReward)],
            mode: .deployment
        )
        XCTAssertTrue(deployment.response.accepted)
        _ = try await child.waitForStatus {
            $0.phase == .active && $0.tipCID == intent.genesisCID
        }

        let deposit = try signedTransaction(
            key: seller,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: sellerAddress,
                delta: -Int64(depositA + depositB)
            )],
            depositActions: [
                DepositAction(
                    nonce: nonceA,
                    demander: sellerAddress,
                    amountDemanded: demandA,
                    amountDeposited: depositA
                ),
                DepositAction(
                    nonce: nonceB,
                    demander: sellerAddress,
                    amountDemanded: demandB,
                    amountDeposited: depositB
                ),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: deposit)
        )
        _ = try await child.waitForStatus { $0.mempoolCount == 1 }
        var depositedStatus: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            if let status = try? await child.waitForStatus(
                timeout: .seconds(2),
                where: { $0.phase == .active && $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            ) {
                depositedStatus = status
                break
            }
        }
        let childAfterDeposit = try XCTUnwrap(
            depositedStatus,
            "child deposit did not enter a parent-carried block"
        )

        let receipt = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            receiptActions: [
                ReceiptAction(
                    withdrawer: buyerAddress,
                    nonce: nonceA,
                    demander: sellerAddress,
                    amountDemanded: demandA,
                    directory: "Market"
                ),
                ReceiptAction(
                    withdrawer: buyerAddress,
                    nonce: nonceB,
                    demander: sellerAddress,
                    amountDemanded: demandB,
                    directory: "Market"
                ),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: receipt)
        )

        let wrongWithdrawer = try signedTransaction(
            key: attacker,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: attackerAddress,
                delta: Int64(depositA)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: attackerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            nonce: 0
        )
        let replay = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(depositA)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            nonce: 0
        )
        let overclaim = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [AccountAction(
                owner: buyerAddress,
                delta: Int64(depositB + 1)
            )],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceB,
                demander: sellerAddress,
                amountDemanded: demandB,
                amountWithdrawn: depositB + 1
            )],
            nonce: 1
        )
        let desired = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: buyerAddress, delta: Int64(depositA - 3)),
                AccountAction(owner: witnessAddress, delta: 1),
            ],
            withdrawalActions: [WithdrawalAction(
                withdrawer: buyerAddress,
                nonce: nonceA,
                demander: sellerAddress,
                amountDemanded: demandA,
                amountWithdrawn: depositA
            )],
            fee: 2,
            nonce: 0
        )
        for transaction in [wrongWithdrawer, replay, overclaim, desired] {
            let _: SubmitTransactionResponse = try await child.post(
                "/v1/transactions",
                body: SubmitTransactionRequest(transaction: transaction)
            )
        }
        // The higher-fee desired claim replaces the same-signer/same-nonce
        // replay; the two independently invalid claims remain queued.
        _ = try await child.waitForStatus { $0.mempoolCount == 3 }

        // These claims arrive before the carrier commits its receipts. The
        // child must still publish an empty candidate and retain all three.
        let receiptWork = try await mine(parent)
        XCTAssertTrue(receiptWork.accepted)
        XCTAssertEqual(receiptWork.durableChildProofs.map(\.directory), ["Market"])
        _ = try await parent.waitForStatus { $0.mempoolCount == 0 }
        let delayed = try await child.waitForStatus {
            $0.mempoolCount == 3
                && $0.tipCID != childAfterDeposit.tipCID
                && $0.height == childAfterDeposit.height.map { $0 + 1 }
        }

        // The fee-ranked desired claim must replace the replay and survive the
        // two other non-cooperative alternatives submitted first.
        let withdrawalWork = try await mine(parent)
        XCTAssertTrue(withdrawalWork.accepted)
        XCTAssertEqual(withdrawalWork.durableChildProofs.map(\.directory), ["Market"])
        let withdrawn = try await child.waitForStatus {
            $0.mempoolCount == 2
                && $0.tipCID != delayed.tipCID
                && $0.height == delayed.height.map { $0 + 1 }
        }

        // Spending the one-unit witness output proves the exact fee-ranked
        // claim committed, rather than the competing replay of the same deposit.
        let witnessSpend = try signedTransaction(
            key: witness,
            chainPath: childPath,
            accountActions: [
                AccountAction(owner: witnessAddress, delta: -1),
                AccountAction(owner: sinkAddress, delta: 1),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: witnessSpend)
        )

        // The parent-side spend independently proves both receipts paid the
        // seller their full variable-rate demand.
        let spendNexusProceeds = try signedTransaction(
            key: seller,
            chainPath: ["Nexus"],
            accountActions: [
                AccountAction(owner: sellerAddress, delta: -Int64(demandA + demandB)),
                AccountAction(owner: sinkAddress, delta: Int64(demandA + demandB)),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: spendNexusProceeds)
        )
        let spendWork = try await mine(parent)
        XCTAssertTrue(spendWork.accepted)
        XCTAssertEqual(spendWork.durableChildProofs.map(\.directory), ["Market"])
        _ = try await parent.waitForStatus { $0.mempoolCount == 0 }
        let spent = try await child.waitForStatus {
            $0.mempoolCount == 2
                && $0.height == withdrawn.height.map { $0 + 1 }
        }

        // Persistent contextual junk neither becomes valid nor suppresses the
        // next empty child block.
        let livenessWork = try await mine(parent)
        XCTAssertTrue(livenessWork.accepted)
        XCTAssertEqual(livenessWork.durableChildProofs.map(\.directory), ["Market"])
        _ = try await child.waitForStatus {
            $0.mempoolCount == 2
                && $0.height == spent.height.map { $0 + 1 }
        }

        // A cold peer has no child-chain state except what the exact Market
        // advertiser serves over Ivy. In particular, validating the historic
        // withdrawal requires the parent receipt-state witness committed by
        // that child block; neither availability nor weight is trusted from
        // the peer.
        let settledStatus = try await child.waitForStatus { $0.phase == .active }
        let settledTip = try XCTUnwrap(settledStatus.tipCID)
        try late.start()
        let joined = try await waitForTip(late, settledTip)

        // Reopen the accepted chain with the advertiser offline and no overlay
        // peers. The parent remains live so consensus may resume, while the
        // exact tip and height must come entirely from late's durable stores.
        try await late.stop()
        try await child.stop()
        late.setOverlayPeers([])
        try late.start()
        let reopened = try await waitForTip(late, settledTip)
        XCTAssertEqual(reopened.height, joined.height)

        try await cluster.stopAll()
        passed = true
    }

    func testSidewaysParentForkStateDoesNotAdmitChildWithdrawals() async throws {
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
        let nexusIdentity = try workspace.makeIdentity(named: "nexus")
        let forkIdentity = try workspace.makeIdentity(named: "fork")
        let childAIdentity = try workspace.makeIdentity(named: "child-a")
        let childBIdentity = try workspace.makeIdentity(named: "child-b")
        let nexusPeerKey = try PeerKey(nexusIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 12)
        let nexusPeer = try overlayPeer(identity: nexusIdentity, port: ports[0])
        let nexus = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: nexusIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let fork = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "fork",
            identity: forkIdentity,
            overlayPort: ports[9],
            factPort: ports[10],
            rpcPort: ports[11]
        )
        let childA = childNode(
            binary: binary,
            workspace: workspace,
            name: "child-a",
            directory: "ChildA",
            identity: childAIdentity,
            parentPublicKey: nexusPeerKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        let childB = childNode(
            binary: binary,
            workspace: workspace,
            name: "child-b",
            directory: "ChildB",
            identity: childBIdentity,
            parentPublicKey: nexusPeerKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8]
        )
        cluster.add(nexus)
        cluster.add(fork)
        cluster.add(childA)
        cluster.add(childB)

        try nexus.start()
        try childA.start()
        try childB.start()
        _ = try await waitForNexus(nexus)
        _ = try await childA.waitForStatus { $0.phase == .awaitingGenesis }
        _ = try await childB.waitForStatus { $0.phase == .awaitingGenesis }

        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let sink = CryptoUtils.generateKeyPair()
        let aliceAddress = CryptoUtils.createAddress(from: alice.publicKey)
        let bobAddress = CryptoUtils.createAddress(from: bob.publicKey)
        let sinkAddress = CryptoUtils.createAddress(from: sink.publicKey)
        let childAPath = ["Nexus", "ChildA"]
        let childBPath = ["Nexus", "ChildB"]
        let aliceDeposit: UInt64 = 100
        let bobDeposit: UInt64 = 200
        let aliceDemand: UInt64 = 200
        let bobDemand: UInt64 = 100
        let aliceExchangeNonce: UInt128 = 11
        let bobExchangeNonce: UInt128 = 22

        let childAIntent = try await fundedChildIntent(
            on: nexus,
            directory: "ChildA",
            owner: alice,
            premine: 1_000,
            timestamp: 1
        )
        let childBIntent = try await fundedChildIntent(
            on: nexus,
            directory: "ChildB",
            owner: bob,
            premine: 1_000,
            timestamp: 1
        )
        let siblingAnchor = try legacySignedTransaction(
            chainPath: ["Nexus"],
            genesisActions: [
                GenesisAction(
                    directory: childAIntent.directory,
                    blockCID: childAIntent.genesisCID
                ),
                GenesisAction(
                    directory: childBIntent.directory,
                    blockCID: childBIntent.genesisCID
                ),
            ]
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: siblingAnchor)
        )

        // Give both settlement signers nonce zero in the deployment block.
        // Bob receives only the net Nexus amount needed by the co-signed swap.
        let aliceNonce = try signedTransaction(
            key: alice,
            chainPath: ["Nexus"],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceNonce)
        )
        let bobFunding = try signedTransaction(
            key: bob,
            chainPath: ["Nexus"],
            accountActions: [AccountAction(owner: bobAddress, delta: 100)],
            nonce: 0
        )
        let deployment = try await mineBlock(
            nexus,
            rewards: [MiningReward(chainPath: ["Nexus"], transaction: bobFunding)],
            mode: .deployment
        )
        XCTAssertTrue(deployment.response.accepted)
        _ = try await childA.waitForStatus {
            $0.phase == .active && $0.tipCID == childAIntent.genesisCID
        }
        _ = try await childB.waitForStatus {
            $0.phase == .active && $0.tipCID == childBIntent.genesisCID
        }

        let aliceLocksA = try signedTransaction(
            key: alice,
            chainPath: childAPath,
            accountActions: [AccountAction(owner: aliceAddress, delta: -Int64(aliceDeposit))],
            depositActions: [DepositAction(
                nonce: aliceExchangeNonce,
                demander: aliceAddress,
                amountDemanded: aliceDemand,
                amountDeposited: aliceDeposit
            )],
            nonce: 0
        )
        let bobLocksB = try signedTransaction(
            key: bob,
            chainPath: childBPath,
            accountActions: [AccountAction(owner: bobAddress, delta: -Int64(bobDeposit))],
            depositActions: [DepositAction(
                nonce: bobExchangeNonce,
                demander: bobAddress,
                amountDemanded: bobDemand,
                amountDeposited: bobDeposit
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceLocksA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobLocksB)
        )
        var depositedA: ChainServiceStatusResponse?
        var depositedB: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(nexus)
            XCTAssertTrue(work.accepted)
            let a = try? await childA.waitForStatus(
                timeout: .seconds(2),
                where: { $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            )
            let b = try? await childB.waitForStatus(
                timeout: .seconds(2),
                where: { $0.mempoolCount == 0 && ($0.height ?? 0) > 0 }
            )
            if a != nil && b != nil {
                depositedA = a
                depositedB = b
                break
            }
        }
        let depositedAStatus = try XCTUnwrap(depositedA)
        let depositedBStatus = try XCTUnwrap(depositedB)
        let confirmedWithdrawalHeightA =
            try XCTUnwrap(depositedAStatus.height) + 2
        let confirmedWithdrawalHeightB =
            try XCTUnwrap(depositedBStatus.height) + 2
        let branchStatus = try await nexus.waitForStatus { $0.mempoolCount == 0 }
        let branchPoint = try XCTUnwrap(branchStatus.tipCID)

        // Fork from the last parent state shared by both deposits, then remove
        // every network edge before either branch commits settlement state.
        fork.setOverlayPeers([nexusPeer])
        try fork.start()
        _ = try await waitForTip(fork, branchPoint)
        try await fork.stop()
        fork.setOverlayPeers([])
        try fork.start()
        _ = try await waitForTip(fork, branchPoint)

        let settlement = try signedTransaction(
            keys: [alice, bob],
            chainPath: ["Nexus"],
            receiptActions: [
                ReceiptAction(
                    withdrawer: bobAddress,
                    nonce: aliceExchangeNonce,
                    demander: aliceAddress,
                    amountDemanded: aliceDemand,
                    directory: "ChildA"
                ),
                ReceiptAction(
                    withdrawer: aliceAddress,
                    nonce: bobExchangeNonce,
                    demander: bobAddress,
                    amountDemanded: bobDemand,
                    directory: "ChildB"
                ),
            ],
            nonce: 1
        )
        let bobClaimsA = try signedTransaction(
            key: bob,
            chainPath: childAPath,
            accountActions: [AccountAction(owner: bobAddress, delta: Int64(aliceDeposit))],
            withdrawalActions: [WithdrawalAction(
                withdrawer: bobAddress,
                nonce: aliceExchangeNonce,
                demander: aliceAddress,
                amountDemanded: aliceDemand,
                amountWithdrawn: aliceDeposit
            )],
            nonce: 0
        )
        let aliceClaimsB = try signedTransaction(
            key: alice,
            chainPath: childBPath,
            accountActions: [AccountAction(owner: aliceAddress, delta: Int64(bobDeposit))],
            withdrawalActions: [WithdrawalAction(
                withdrawer: aliceAddress,
                nonce: bobExchangeNonce,
                demander: bobAddress,
                amountDemanded: bobDemand,
                amountWithdrawn: bobDeposit
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await nexus.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: settlement)
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobClaimsA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceClaimsB)
        )

        // A child binds to the carrier's entering parent state, so any child
        // carried by the receipt block leaves its premature withdrawal queued.
        // A temporarily omitted child joins from the committed receipt state
        // in a later ordinary round.
        let settlementBlock = try await mineBlock(nexus)
        XCTAssertTrue(settlementBlock.response.accepted)
        _ = try await nexus.waitForStatus { $0.mempoolCount == 0 }
        // Child selection and proof delivery are intentionally asynchronous.
        // Mine bounded ordinary rounds until each child independently consumes
        // its withdrawal and then receives one confirming child block.
        var settledBranchWork = WorkSum(
            workForTarget(settlementBlock.template.block.target)
        )
        var observedWithdrawalA: ChainServiceStatusResponse?
        var observedWithdrawalB: ChainServiceStatusResponse?
        for _ in 0..<20 {
            let withdrawalBlock: E2EMinedBlock
            do {
                withdrawalBlock = try await mineBlock(nexus)
            } catch let error as E2EHTTPError where error.status != 0 {
                try await Task.sleep(for: .milliseconds(100))
                continue
            } catch {
                throw error
            }
            XCTAssertTrue(withdrawalBlock.response.accepted)
            settledBranchWork = settledBranchWork
                + WorkSum(workForTarget(withdrawalBlock.template.block.target))
            let proofs = Dictionary(
                uniqueKeysWithValues: withdrawalBlock.response
                    .durableChildProofs.map { ($0.directory, $0.childCID) }
            )
            if proofs["ChildA"] != nil, observedWithdrawalA == nil {
                observedWithdrawalA = try? await childA.waitForStatus(
                    timeout: .seconds(5),
                    where: {
                        $0.phase == .active
                            && ($0.height ?? 0) >= confirmedWithdrawalHeightA
                            && $0.mempoolCount == 0
                    }
                )
            }
            if proofs["ChildB"] != nil, observedWithdrawalB == nil {
                observedWithdrawalB = try? await childB.waitForStatus(
                    timeout: .seconds(5),
                    where: {
                        $0.phase == .active
                            && ($0.height ?? 0) >= confirmedWithdrawalHeightB
                            && $0.mempoolCount == 0
                    }
                )
            }
            if observedWithdrawalA != nil, observedWithdrawalB != nil { break }
        }
        let withdrawnA = try XCTUnwrap(observedWithdrawalA)
        let withdrawnB = try XCTUnwrap(observedWithdrawalB)

        // The isolated branch consumes the same two signer nonces without the
        // receipts, so reconciliation cannot simply replay the settlement.
        let conflictingNonce = try signedTransaction(
            keys: [alice, bob],
            chainPath: ["Nexus"],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await fork.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: conflictingNonce)
        )
        _ = try await fork.waitForStatus { $0.mempoolCount == 1 }
        var forkTip = try await mineBlock(fork)
        XCTAssertTrue(forkTip.response.accepted)
        XCTAssertEqual(forkTip.template.block.parent?.rawCID, branchPoint)
        _ = try await fork.waitForStatus { $0.mempoolCount == 0 }

        var forkWork = WorkSum(workForTarget(forkTip.template.block.target))
        while forkWork <= settledBranchWork {
            let extensionBlock = try await mineBlock(fork)
            XCTAssertTrue(extensionBlock.response.accepted)
            XCTAssertEqual(extensionBlock.template.block.parent?.rawCID, forkTip.blockCID)
            forkTip = extensionBlock
            forkWork = forkWork
                + WorkSum(workForTarget(extensionBlock.template.block.target))
        }
        XCTAssertGreaterThan(forkWork, settledBranchWork)

        // Healing changes only the Nexus canonical pointer. Both child blocks
        // already proved the receipt state on the now-side settlement branch.
        try await fork.stop()
        fork.setOverlayPeers([nexusPeer])
        try fork.start()
        _ = try await waitForTip(nexus, forkTip.blockCID)
        let preservedA = try await childA.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
                && ($0.height ?? 0) >= (withdrawnA.height ?? 0)
        }
        let preservedB = try await childB.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
                && ($0.height ?? 0) >= (withdrawnB.height ?? 0)
        }
        try await fork.stop()

        // Recovery must preserve child state proved by a now-noncanonical
        // parent branch. Canonical parent pointers are not proof inputs.
        try await childB.stop()
        try await childA.stop()
        try await nexus.stop()
        try nexus.start()
        try childA.start()
        try childB.start()
        _ = try await waitForTip(nexus, forkTip.blockCID)
        let recoveredA = try await childA.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
                && ($0.height ?? 0) >= (preservedA.height ?? 0)
        }
        let recoveredB = try await childB.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
                && ($0.height ?? 0) >= (preservedB.height ?? 0)
        }
        let bobSpendsA = try signedTransaction(
            key: bob,
            chainPath: childAPath,
            accountActions: [
                AccountAction(owner: bobAddress, delta: -Int64(aliceDeposit)),
                AccountAction(owner: sinkAddress, delta: Int64(aliceDeposit)),
            ],
            nonce: 1
        )
        let aliceSpendsB = try signedTransaction(
            key: alice,
            chainPath: childBPath,
            accountActions: [
                AccountAction(owner: aliceAddress, delta: -Int64(bobDeposit)),
                AccountAction(owner: sinkAddress, delta: Int64(bobDeposit)),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await childA.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: bobSpendsA)
        )
        let _: SubmitTransactionResponse = try await childB.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: aliceSpendsB)
        )
        var expectedParent = forkTip.blockCID
        var strandedCandidates: [String: String] = [:]
        for _ in 0..<5 {
            let work = try await mineBlock(nexus)
            XCTAssertTrue(work.response.accepted)
            XCTAssertEqual(work.template.block.parent?.rawCID, expectedParent)
            strandedCandidates = Dictionary(
                uniqueKeysWithValues: work.response.durableChildProofs.map {
                    ($0.directory, $0.childCID)
                }
            )
            expectedParent = work.blockCID
            if Set(strandedCandidates.keys) == Set(["ChildA", "ChildB"]) { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(Set(strandedCandidates.keys), Set(["ChildA", "ChildB"]))
        try await Task.sleep(for: .seconds(1))
        let strandedA = try await childA.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 1
                && ($0.height ?? 0) >= (recoveredA.height ?? 0)
        }
        let strandedB = try await childB.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 1
                && ($0.height ?? 0) >= (recoveredB.height ?? 0)
        }
        XCTAssertNotEqual(strandedA.tipCID, strandedCandidates["ChildA"])
        XCTAssertNotEqual(strandedB.tipCID, strandedCandidates["ChildB"])

        try await cluster.stopAll()
        passed = true
    }

    func testTransitiveParentContinuityAdmitsWithdrawal() async throws {
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
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let childIdentity = try workspace.makeIdentity(named: "market")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let ports = try E2EPorts.allocate(count: 6)
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let child = childNode(
            binary: binary,
            workspace: workspace,
            name: "market",
            directory: "Market",
            identity: childIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5]
        )
        cluster.add(parent)
        cluster.add(child)

        try parent.start()
        try child.start()
        _ = try await waitForNexus(parent)
        _ = try await child.waitForStatus { $0.phase == .awaitingGenesis }

        let seller = CryptoUtils.generateKeyPair()
        let buyer = CryptoUtils.generateKeyPair()
        let sellerAddress = CryptoUtils.createAddress(from: seller.publicKey)
        let buyerAddress = CryptoUtils.createAddress(from: buyer.publicKey)
        let childPath = ["Nexus", "Market"]
        let depositAmount: UInt64 = 100
        let demandAmount: UInt64 = 250
        let exchangeNonce: UInt128 = 7
        let intent = try await fundedChildIntent(
            on: parent,
            directory: "Market",
            owner: seller,
            premine: 1_000,
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let buyerFunding = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            accountActions: [
                AccountAction(owner: buyerAddress, delta: Int64(demandAmount)),
            ],
            nonce: 0
        )
        let deployment = try await mineBlock(
            parent,
            rewards: [
                MiningReward(
                    chainPath: ["Nexus"],
                    transaction: buyerFunding
                ),
            ],
            mode: .deployment
        )
        XCTAssertTrue(deployment.response.accepted)
        _ = try await waitForTip(child, intent.genesisCID)

        let deposit = try signedTransaction(
            key: seller,
            chainPath: childPath,
            accountActions: [
                AccountAction(
                    owner: sellerAddress,
                    delta: -Int64(depositAmount)
                ),
            ],
            depositActions: [
                DepositAction(
                    nonce: exchangeNonce,
                    demander: sellerAddress,
                    amountDemanded: demandAmount,
                    amountDeposited: depositAmount
                ),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: deposit)
        )
        var deposited: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            deposited = try? await child.waitForStatus(
                timeout: .seconds(2),
                where: {
                    $0.mempoolCount == 0 && ($0.height ?? 0) > 0
                }
            )
            if deposited != nil { break }
        }
        let depositedStatus = try XCTUnwrap(deposited)
        let depositedTip = try XCTUnwrap(depositedStatus.tipCID)
        let depositedHeight = try XCTUnwrap(depositedStatus.height)
        let parentBeforeAdvance = try await parent.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
        }
        let parentHeightBeforeAdvance = try XCTUnwrap(parentBeforeAdvance.height)

        let receipt = try signedTransaction(
            key: buyer,
            chainPath: ["Nexus"],
            receiptActions: [
                ReceiptAction(
                    withdrawer: buyerAddress,
                    nonce: exchangeNonce,
                    demander: sellerAddress,
                    amountDemanded: demandAmount,
                    directory: "Market"
                ),
            ],
            nonce: 1
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: receipt)
        )

        // Keep the child idle while the receipt and two further parent blocks
        // commit. Its next block must prove a multi-edge parent-state path.
        try await child.stop()
        for _ in 0..<3 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
        }
        let advancedParent = try await parent.waitForStatus {
            $0.phase == .active && $0.mempoolCount == 0
        }
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(advancedParent.height),
            parentHeightBeforeAdvance + 3
        )

        try child.start()
        _ = try await waitForTip(child, depositedTip)
        let withdrawal = try signedTransaction(
            key: buyer,
            chainPath: childPath,
            accountActions: [
                AccountAction(
                    owner: buyerAddress,
                    delta: Int64(depositAmount)
                ),
            ],
            withdrawalActions: [
                WithdrawalAction(
                    withdrawer: buyerAddress,
                    nonce: exchangeNonce,
                    demander: sellerAddress,
                    amountDemanded: demandAmount,
                    amountWithdrawn: depositAmount
                ),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await child.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: withdrawal)
        )
        var withdrawn: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            withdrawn = try? await child.waitForStatus(
                timeout: .seconds(3),
                where: {
                    $0.mempoolCount == 0
                        && ($0.height ?? 0) > depositedHeight
                }
            )
            if withdrawn != nil { break }
        }
        XCTAssertNotEqual(try XCTUnwrap(withdrawn).tipCID, depositedTip)

        try await cluster.stopAll()
        passed = true
    }

    func testParentOfflineContinuityDefersAndRequeuesReplicaCandidate()
        async throws {
        let workspace = try E2EWorkspace()
        let cluster = E2ECluster()
        var passed = false
        let ports = try E2EPorts.allocate(count: 10)
        E2EPorts.release([ports[9]])
        let parentProxy = LoopbackTCPFaultProxy(
            listenPort: ports[9],
            targetPort: ports[1]
        )
        defer {
            parentProxy.stop()
            try? E2EPorts.reserve([ports[9]])
            cluster.forceTerminateAll()
            if passed {
                try? workspace.remove()
            } else {
                print("lattice-node E2E artifacts retained at \(workspace.url.path)")
            }
        }

        let binary = try E2EBinary.latticeNode()
        let parentIdentity = try workspace.makeIdentity(named: "nexus")
        let aIdentity = try workspace.makeIdentity(named: "payments-a")
        let bIdentity = try workspace.makeIdentity(named: "payments-b")
        let parentKey = try PeerKey(parentIdentity.publicKey)
        let aPeer = try overlayPeer(identity: aIdentity, port: ports[3])
        let bPeer = try overlayPeer(identity: bIdentity, port: ports[6])
        let parent = nexusNode(
            binary: binary,
            workspace: workspace,
            name: "nexus",
            identity: parentIdentity,
            overlayPort: ports[0],
            factPort: ports[1],
            rpcPort: ports[2]
        )
        let a = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-a",
            directory: "Payments",
            identity: aIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[1],
            overlayPort: ports[3],
            factPort: ports[4],
            rpcPort: ports[5],
            overlayPeers: [bPeer]
        )
        let b = childNode(
            binary: binary,
            workspace: workspace,
            name: "payments-b",
            directory: "Payments",
            identity: bIdentity,
            parentPublicKey: parentKey.hex,
            parentFactPort: ports[9],
            overlayPort: ports[6],
            factPort: ports[7],
            rpcPort: ports[8],
            overlayPeers: [aPeer]
        )
        cluster.add(parent)
        cluster.add(a)
        cluster.add(b)

        try parentProxy.start()
        try parent.start()
        try a.start()
        try b.start()
        _ = try await waitForNexus(parent)
        try await parentProxy.waitForConnections(1)
        let owner = CryptoUtils.generateKeyPair()
        let ownerAddress = CryptoUtils.createAddress(from: owner.publicKey)
        let sinkAddress = CryptoUtils.createAddress(
            from: CryptoUtils.generateKeyPair().publicKey
        )
        let intent = try await fundedChildIntent(
            on: parent,
            directory: "Payments",
            owner: owner,
            premine: 1_000,
            timestamp: 1
        )
        try await submitGenesisAnchor(
            on: parent,
            intent: intent,
            chainPath: ["Nexus"]
        )
        let deployment = try await mine(parent, mode: .deployment)
        XCTAssertTrue(deployment.accepted)
        _ = try await waitForTip(a, intent.genesisCID)
        _ = try await waitForTip(b, intent.genesisCID)

        try await b.stop()
        try await a.stop()
        for _ in 0..<3 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
        }
        try a.start()
        try b.start()
        _ = try await waitForTip(a, intent.genesisCID)
        _ = try await waitForTip(b, intent.genesisCID)
        try await parentProxy.waitForConnections(2)

        let transfer = try signedTransaction(
            key: owner,
            chainPath: ["Nexus", "Payments"],
            accountActions: [
                AccountAction(owner: ownerAddress, delta: -1),
                AccountAction(owner: sinkAddress, delta: 1),
            ],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await a.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: transfer)
        )
        _ = try await a.waitForStatus { $0.mempoolCount == 1 }
        _ = try await b.waitForStatus { $0.mempoolCount == 1 }

        parentProxy.cut()
        try await parentProxy.waitForNoActiveConnections()
        var admittedByA: ChainServiceStatusResponse?
        for _ in 0..<5 {
            let work = try await mine(parent)
            XCTAssertTrue(work.accepted)
            admittedByA = try? await a.waitForStatus(
                timeout: .seconds(3),
                where: {
                    $0.tipCID != intent.genesisCID
                        && $0.mempoolCount == 0
                }
            )
            if admittedByA != nil { break }
        }
        let admitted = try XCTUnwrap(admittedByA)
        let deferred = try await b.waitForStatus {
            $0.tipCID == intent.genesisCID && $0.mempoolCount == 1
        }
        XCTAssertEqual(deferred.height, 0)

        parentProxy.heal()
        try await parentProxy.waitForConnections(3)
        let admittedHeight = try XCTUnwrap(admitted.height)
        let replayed = try await b.waitForStatus {
            $0.tipCID != intent.genesisCID && $0.mempoolCount == 0
                && ($0.height ?? 0) >= admittedHeight
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(replayed.height), admittedHeight)

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
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal
    ) async throws -> SubmitWorkResponse {
        try await mineBlock(parent, rewards: rewards, mode: mode).response
    }

    private func mineBlock(
        _ parent: E2ENode,
        rewards: [MiningReward] = [],
        mode: MiningMode = .normal,
        requestTimeout: TimeInterval? = nil
    ) async throws -> E2EMinedBlock {
        // Child candidate collection is protocol-bounded at 15 seconds.
        let template: MiningTemplateResponse = try await parent.post(
            "/v1/mining/templates",
            body: MiningTemplateRequest(rewards: rewards, mode: mode),
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

    private func childIntent(
        on parent: E2ENode,
        directory: String,
        timestamp: Int64,
        target: UInt256 = .max
    ) async throws -> ChildDeployIntentResponse {
        try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: directory,
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: 0,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [],
                target: target,
                timestamp: timestamp
            )
        )
    }

    private func fundedChildIntent(
        on parent: E2ENode,
        directory: String,
        owner: (privateKey: String, publicKey: String),
        premine: UInt64,
        timestamp: Int64
    ) async throws -> ChildDeployIntentResponse {
        let path = ["Nexus", directory]
        let ownerAddress = CryptoUtils.createAddress(from: owner.publicKey)
        let premineTransaction = try unsignedGenesisTransaction(
            chainPath: path,
            accountActions: [AccountAction(owner: ownerAddress, delta: Int64(premine))]
        )
        return try await parent.post(
            "/v1/children/intents",
            body: ChildDeployIntentRequest(
                directory: directory,
                spec: ChainSpec(
                    maxNumberOfTransactionsPerBlock: 100,
                    maxStateGrowth: 100_000,
                    premine: premine,
                    targetBlockTime: 1_000,
                    initialReward: 10,
                    halvingInterval: 100
                ),
                genesisTransactions: [premineTransaction],
                target: .max,
                timestamp: timestamp
            )
        )
    }

    private func submitLegacyGenesisAnchor(
        on parent: E2ENode,
        intent: ChildDeployIntentResponse,
        chainPath: [String]
    ) async throws {
        let anchor = try legacySignedTransaction(
            chainPath: chainPath,
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID
            )]
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
    }

    private func submitGenesisAnchor(
        on parent: E2ENode,
        intent: ChildDeployIntentResponse,
        chainPath: [String]
    ) async throws {
        let anchor = try signedTransaction(
            key: CryptoUtils.generateKeyPair(),
            chainPath: chainPath,
            genesisActions: [GenesisAction(
                directory: intent.directory,
                blockCID: intent.genesisCID
            )],
            nonce: 0
        )
        let _: SubmitTransactionResponse = try await parent.post(
            "/v1/transactions",
            body: SubmitTransactionRequest(transaction: anchor)
        )
    }

    private func unsignedGenesisTransaction(
        chainPath: [String],
        accountActions: [AccountAction]
    ) throws -> Transaction {
        Transaction(
            signatures: [:],
            body: try HeaderImpl(node: TransactionBody(
                accountActions: accountActions,
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0,
                chainPath: chainPath
            ))
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
