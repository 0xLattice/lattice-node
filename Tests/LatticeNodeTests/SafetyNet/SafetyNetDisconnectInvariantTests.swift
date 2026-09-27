import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: after a network session ends, no per-peer record and no
/// pending request in `NodeNetworkRuntime` still holds that peer's key — on
/// the overlay plane and on the hierarchy plane alike — and no session-keyed
/// serve or lease outlives its session.
///
/// The runtime keeps ~30 per-peer maps and pending-request tables (sessions,
/// hello deadlines, announced tips, range sync, frontier pulls, inventory and
/// read-endpoint requests, evidence waiters, candidate offers, pushed context
/// sequences, candidate providers, evidence-flow sessions…) plus six tables
/// keyed by session ID (in-flight serves and content leases).
/// `NodeNetworkRuntime.debugSnapshot()`'s `heldPeerKeys` / `heldSessionIDs`
/// (DEBUG-only) union them, so the assertion here is one
/// line and the refactor cannot drop a map from the audit by moving it.
///
/// Non-vacuous by construction, in this order:
/// - the overlay peer completes its hello (checked through the snapshot's
///   accepted-hello flag: a session and a hello deadline hold the key from connect, so the
///   key appearing is not proof of the hello);
/// - it advertises a transaction volume it then never serves, so the
///   runtime's fetch — and the `activeTransactionVolumes` lease on this
///   session — stays in flight (a session ID appears);
/// - it announces a deep tip, which starts a range sync against it;
/// - the hierarchy peer completes a child hello and is checked to hold the
///   `.child(["Nexus", "Payments"])` role (a hello deadline alone is set
///   before any hello, so the key appearing is not proof of the role);
/// - only then must both disconnects clear everything.
///
/// `overlayRuntime` / `connectAndHello` and the keys come from
/// `NetworkTrustTestCase`, the base the NetworkTrust suites share.
final class SafetyNetDisconnectInvariantTests: NetworkTrustTestCase {

    func testDisconnectedPeersLeaveNoPerPeerRecordOnEitherPlane() async throws {
        // Long enough that neither the withheld volume fetch nor the range
        // sync can time out on its own during the test: every release below
        // must be attributable to the disconnect, not to a timer.
        let target = try await overlayRuntime(keyByte: 0xd1, requestTimeout: .seconds(60))
        let hierarchyEndpoint = PeerEndpoint(
            publicKey: target.process.configuration.processPublicKey,
            host: "127.0.0.1",
            port: target.process.configuration.factListenPort
        )
        let overlayKey = signingKey(0xd2)
        let overlayPeer = Ivy(config: IvyConfig(
            signingKey: overlayKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        ))
        let withheldRoot = testCID("safety-net-withheld-transaction")
        let withholding = SafetyNetWithholdingContentSource(blockedRoot: withheldRoot)
        let overlayStub = SafetyNetSilentPeer()
        await overlayPeer.installSafetyNetDelegate(overlayStub, contentSource: withholding)
        let childKey = signingKey(0xd3)
        let childPeer = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
        let childStub = SafetyNetSilentPeer()
        await childPeer.installSafetyNetDelegate(childStub, contentSource: nil)
        let overlayPeerKey = peerKey(overlayKey)
        let childPeerKey = peerKey(childKey)

        try await target.runtime.start(
            process: target.process,
            chain: ClosureChainInterface(
                admission: { _ in throw CancellationError() },
                // Present so an advertised transaction volume is fetched;
                // never reached, because the volume is withheld.
                transaction: { _ in false }
            )
        )
        defer { Task { await target.runtime.stop() } }
        do {
            // Overlay: hello.
            try await connectAndHello(
                overlayPeer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            // The key alone is held from connect (session + hello deadline),
            // so wait for the hello itself to be accepted.
            try await waitUntil("overlay hello accepted") {
                await target.runtime.debugSnapshot().overlay[overlayPeerKey]?.helloAccepted == true
            }
            // A transaction advertisement whose volume is never served: the
            // runtime's lease on this session stays held while it fetches.
            try await send(
                overlayPeer, to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(volumeRootCID: withheldRoot).encoded()
            )
            try await waitUntil("withheld volume fetch holds a session lease") {
                !(await target.runtime.debugSnapshot().heldSessionIDs).isEmpty
            }
            try await waitUntil("withheld request reached the peer") {
                await withholding.blockedRequestStarted
            }
            let heldBefore = await target.runtime.debugSnapshot().heldSessionIDs
            let liveBefore = await target.runtime.debugSnapshot().liveSessionIDs
            XCTAssertFalse(heldBefore.isEmpty, "a session lease must exist before disconnect")
            XCTAssertTrue(
                heldBefore.isSubset(of: liveBefore),
                "a held session must be a live one before disconnect"
            )
            // A deep tip announcement: recorded as a candidate provider and
            // starts a range sync against this peer.
            try await send(
                overlayPeer, to: target.peerID,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: try BlockAnnouncementMessage(
                    blockCID: testCID("safety-net-deep-tip"), height: 40
                ).encoded()
            )
            try await waitUntil("deep tip announcement started a range sync") {
                await target.runtime.debugSnapshot().rangeSyncAnchor != nil
            }

            // Hierarchy: an immediate-child hello must earn the child role.
            try await childPeer.start()
            try await childPeer.connect(to: hierarchyEndpoint)
            try await waitUntil("child peer connected on the hierarchy plane") {
                (await childPeer.connectedPeers).contains(target.peerID)
            }
            try await send(
                childPeer, to: target.peerID,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: try ChainHello(
                    nexusGenesisCID: target.process.configuration.nexusGenesisCID,
                    chainPath: ["Nexus", "Payments"]
                ).encode()
            )
            try await waitUntil("child peer granted the child role") {
                await target.runtime.debugSnapshot().hierarchy[childPeerKey]?.role
                    == .child(["Nexus", "Payments"])
            }

            // Everything the disconnect must clear is in place right now.
            let anchorBeforeStop = await target.runtime.debugSnapshot().rangeSyncAnchor
            XCTAssertNotNil(anchorBeforeStop, "range sync must be live immediately before the disconnect")
            let heldKeysBefore = await target.runtime.debugSnapshot().heldPeerKeys
            XCTAssertTrue(heldKeysBefore.contains(overlayPeerKey), "overlay key held before disconnect")
            XCTAssertTrue(heldKeysBefore.contains(childPeerKey), "child key held before disconnect")

            // Both sessions end.
            await overlayPeer.stop()
            await childPeer.stop()
            try await waitUntil("per-peer records cleared after disconnect") {
                await target.runtime.debugSnapshot().heldPeerKeys
                    .isDisjoint(with: [overlayPeerKey, childPeerKey])
            }
            try await waitUntil("session-keyed state released after disconnect") {
                await target.runtime.debugSnapshot().heldSessionIDs
                    .isSubset(of: await target.runtime.debugSnapshot().liveSessionIDs)
            }
        } catch {
            await overlayPeer.stop()
            await childPeer.stop()
            await withholding.release()
            throw error
        }

        let held = await target.runtime.debugSnapshot().heldPeerKeys
        XCTAssertFalse(
            held.contains(overlayPeerKey),
            "overlay peer \(overlayPeerKey.hex.prefix(8)) still held after disconnect"
        )
        XCTAssertFalse(
            held.contains(childPeerKey),
            "hierarchy child peer \(childPeerKey.hex.prefix(8)) still held after disconnect"
        )
        let heldSessions = await target.runtime.debugSnapshot().heldSessionIDs
        let liveSessions = await target.runtime.debugSnapshot().liveSessionIDs
        XCTAssertTrue(
            heldSessions.isSubset(of: liveSessions),
            "session-keyed state outlives its session: "
                + "\(heldSessions.subtracting(liveSessions).map { $0.map { String(format: "%02x", $0) }.joined().prefix(8) })"
        )
        let rangeSyncAnchor = await target.runtime.debugSnapshot().rangeSyncAnchor
        XCTAssertNil(
            rangeSyncAnchor,
            "range sync must not survive its source peer's disconnect"
        )
        await withholding.release()
    }

    /// #193: the parent's tip-context push records what it sent after the
    /// send returns. An evidence-ready child that disconnects while that
    /// send is suspended must not get its key back from the late write:
    /// the write lands only on the record of the session it was sent on.
    func testAPushThatReturnsAfterTheChildDisconnectedLeavesNoRecord() async throws {
        let target = try await overlayRuntime(keyByte: 0xd4, requestTimeout: .seconds(60))
        let childKey = signingKey(0xd5)
        let childPeerKey = peerKey(childKey)
        let child = Ivy(config: IvyConfig(
            signingKey: childKey,
            listenPort: 0,
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            mode: .privateNetwork
        ))
        let script = SafetyNetScriptedChild(
            hello: try ChainHello(
                nexusGenesisCID: target.process.configuration.nexusGenesisCID,
                chainPath: ["Nexus", "Payments"]
            ).encode(),
            childPath: ["Nexus", "Payments"]
        )
        await child.installSafetyNetDelegate(script, contentSource: nil)
        let hierarchyEndpoint = PeerEndpoint(
            publicKey: target.process.configuration.processPublicKey,
            host: "127.0.0.1",
            port: target.process.configuration.factListenPort
        )
        let runtime = target.runtime
        let race = SafetyNetPushRace()
        // Runs after the push's send returned and before its write: the
        // child's session ends in between, and the runtime has dropped the
        // child's record before the push resumes.
        await runtime.setHierarchySendReturnedForTesting { topic, sent in
            guard topic == NodeNetworkTopic.parentTipAvailable,
                  await race.begin(enqueued: {
                      if case .enqueued = sent { return true }
                      return false
                  }()) else { return }
            await child.stop()
            for _ in 0..<500 {
                if await runtime.debugSnapshot().hierarchy[childPeerKey] == nil { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await race.finish(
                recordGone: await runtime.debugSnapshot().hierarchy[childPeerKey] == nil
            )
        }

        try await runtime.start(
            process: target.process,
            chain: inertNetworkHandlers()
        )
        do {
            try await child.start()
            try await child.connect(to: hierarchyEndpoint)
            try await waitUntil("the push to the ready child returned") {
                await race.finished
            }
            let enqueued = await race.enqueued
            let recordGone = await race.recordGone
            XCTAssertTrue(enqueued, "the push reached the child's session before it ended")
            XCTAssertTrue(recordGone, "the disconnect dropped the child's record mid-push")
            try await waitUntil("the push task finished its write") {
                await runtime.debugParentTipPushIdle()
            }
        } catch {
            await child.stop()
            await runtime.stop()
            throw error
        }
        let held = await runtime.debugSnapshot().heldPeerKeys
        XCTAssertFalse(
            held.contains(childPeerKey),
            "a push recorded after the disconnect re-created the child's record"
        )
        await runtime.stop()
    }

    /// A child session S1 parks in its hello follow-up waiting for evidence
    /// readiness; the child reconnects as S2, whose connect ends S1's wait.
    /// S1's follow-up then resumes and gives up: it must end S1 only, not
    /// remove S2's record and hello deadline, or S2's hello is dropped and
    /// the link wedges until the transport drops.
    func testAStaleHelloFollowUpCannotEndTheReconnectedSession() async throws {
        let target = try await overlayRuntime(keyByte: 0xd6, requestTimeout: .seconds(60))
        let childKey = signingKey(0xd7)
        let childPeerKey = peerKey(childKey)
        let hello = try ChainHello(
            nexusGenesisCID: target.process.configuration.nexusGenesisCID,
            chainPath: ["Nexus", "Payments"]
        ).encode()
        func childIvy() -> Ivy {
            Ivy(config: IvyConfig(
                signingKey: childKey,
                listenPort: 0,
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .privateNetwork
            ))
        }
        // Ivy holds its delegate weakly: the scripts live as long as the test.
        let firstScript = SafetyNetScriptedChild(
            hello: hello, childPath: ["Nexus", "Payments"], pullsIndex: false
        )
        let secondScript = SafetyNetScriptedChild(
            hello: hello, childPath: ["Nexus", "Payments"]
        )
        let first = childIvy()
        await first.installSafetyNetDelegate(firstScript, contentSource: nil)
        var second: Ivy?
        let hierarchyEndpoint = PeerEndpoint(
            publicKey: target.process.configuration.processPublicKey,
            host: "127.0.0.1",
            port: target.process.configuration.factListenPort
        )
        let runtime = target.runtime
        try await runtime.start(process: target.process, chain: inertNetworkHandlers())
        do {
            try await first.start()
            try await first.connect(to: hierarchyEndpoint)
            try await waitUntil("S1's hello follow-up waits for readiness") {
                await runtime.debugEvidenceWaiterCount(childPeerKey) == 1
            }
            let s1 = await runtime.debugSnapshot().liveSessionIDs

            // Ivy keeps the preferred of two sessions for one key (a
            // tie-break on the session IDs), so a reconnect replaces S1 only
            // when its ID wins: dial fresh identities-alike until one does.
            for _ in 0..<32 where second == nil {
                let candidate = childIvy()
                await candidate.installSafetyNetDelegate(secondScript, contentSource: nil)
                try await candidate.start()
                if (try? await candidate.connect(to: hierarchyEndpoint)) != nil,
                   (await candidate.connectedPeers).contains(target.peerID) {
                    second = candidate
                } else {
                    await candidate.stop()
                }
            }
            XCTAssertNotNil(second, "no reconnect replaced S1")
            try await waitUntil("S2's hello is accepted and S2 becomes ready") {
                let snapshot = await runtime.debugSnapshot()
                let ready = await runtime.isChildEvidenceReady(childPeerKey)
                return snapshot.hierarchy[childPeerKey]?.role == .child(["Nexus", "Payments"])
                    && !snapshot.liveSessionIDs.isEmpty
                    && snapshot.liveSessionIDs.isDisjoint(with: s1)
                    && ready
            }
        } catch {
            await first.stop()
            await second?.stop()
            await runtime.stop()
            throw error
        }
        await first.stop()
        await second?.stop()
        await runtime.stop()
        withExtendedLifetime((firstScript, secondScript)) {}
    }

    // MARK: - Helpers (the runtime, keys and hello come from NetworkTrustTestCase)

    private func send(
        _ peer: Ivy, to peerID: PeerID, topic: String, payload: Data
    ) async throws {
        guard case .enqueued = await peer.sendMessage(
            to: peerID, topic: topic, payload: payload
        ) else {
            throw SafetyNetNetworkError.failedSend(topic)
        }
    }

    /// Bounded poll; never a fixed settle sleep for a positive assertion.
    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
        throw SafetyNetNetworkError.failedPhase(what)
    }

}

private enum SafetyNetNetworkError: Error {
    case failedSend(String)
    case failedPhase(String)
}

/// A delegate that records nothing: the test reads the runtime's side only.
private final class SafetyNetSilentPeer: IvyDelegate, Sendable {}

/// A direct child: answers the parent's hello with its own and pulls its
/// (empty) evidence index, which makes it evidence-ready at the parent.
private final class SafetyNetScriptedChild: IvyDelegate, Sendable {
    private let hello: Data
    private let childPath: [String]
    /// False: the child never pulls its index, so it never becomes ready.
    private let pullsIndex: Bool

    init(hello: Data, childPath: [String], pullsIndex: Bool = true) {
        self.hello = hello
        self.childPath = childPath
        self.pullsIndex = pullsIndex
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.hierarchyHello,
              case .enqueued = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.hierarchyHello,
                payload: hello
              ),
              pullsIndex,
              let request = try? ChildEvidenceIndexRequestMessage(
                requestID: 1,
                childPath: childPath,
                sourceID: nil,
                cursor: 0,
                through: nil
              ).encoded() else { return }
        _ = await ivy.sendMessage(
            to: peer,
            topic: NodeNetworkTopic.childEvidenceIndexRequest,
            payload: request
        )
    }
}

/// The one push the race test interrupts, and what it saw.
private actor SafetyNetPushRace {
    private var begun = false
    private(set) var enqueued = false
    private(set) var recordGone = false
    private(set) var finished = false

    /// True for the first push only.
    func begin(enqueued: Bool) -> Bool {
        guard !begun else { return false }
        begun = true
        self.enqueued = enqueued
        return true
    }

    func finish(recordGone: Bool) {
        self.recordGone = recordGone
        finished = true
    }
}

extension NodeNetworkRuntime {
    /// Evidence-readiness waiters parked on the key's record.
    func debugEvidenceWaiterCount(_ key: PeerKey) -> Int {
        hierarchyState.hierarchyRecords[key]?.evidence.waiters.count ?? 0
    }

    /// No tip-context push task is running.
    func debugParentTipPushIdle() -> Bool {
        hierarchyState.parentTipPushTask.isEmpty
    }
}

/// Answers every content and volume request empty except `blockedRoot`,
/// which it holds open until released, so the requesting runtime keeps its
/// lease in flight. (Ivy serves a whole-volume fetch through `volume(...)`,
/// not `content(...)`; both withhold so the transport path does not matter.)
private actor SafetyNetWithholdingContentSource: IvyContentSource {
    private let blockedRoot: String
    /// Set once the withheld root has been asked for; polled by the test.
    private(set) var blockedRequestStarted = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedRoot: String) {
        self.blockedRoot = blockedRoot
    }

    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        await withhold(rootCID)
    }

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        await withhold(rootCID)
    }

    private func withhold(_ rootCID: String) async -> [ContentEntry] {
        guard rootCID == blockedRoot else { return [] }
        blockedRequestStarted = true
        if !released {
            await withCheckedContinuation { blockedWaiters.append($0) }
        }
        return []
    }

    func release() {
        released = true
        let pending = blockedWaiters
        blockedWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private extension Ivy {
    func installSafetyNetDelegate(
        _ delegate: IvyDelegate, contentSource: (any IvyContentSource)?
    ) {
        self.delegate = delegate
        setContentSource(contentSource)
    }
}
