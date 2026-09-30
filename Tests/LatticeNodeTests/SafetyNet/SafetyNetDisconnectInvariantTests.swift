import Crypto
import Foundation
import Ivy
import Lattice
import Tally
import XCTest
import cashew
@testable import LatticeNode

/// Safety net: after a network session ends, no per-peer record and no
/// pending request in `NodeNetworkRuntime` still holds that peer's key, and
/// no session-keyed serve or lease outlives its session.
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
/// - only then must the disconnect clear everything.
///
/// `overlayRuntime` / `connectAndHello` and the keys come from
/// `NetworkTrustTestCase`, the base the NetworkTrust suites share.
final class SafetyNetDisconnectInvariantTests: NetworkTrustTestCase {

    func testDisconnectedPeersLeaveNoPerPeerRecord() async throws {
        // Long enough that neither the withheld volume fetch nor the range
        // sync can time out on its own during the test: every release below
        // must be attributable to the disconnect, not to a timer.
        let target = try await overlayRuntime(
            keyByte: 0xd1,
            requestTimeout: .seconds(60)
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
        let overlayPeerKey = peerKey(overlayKey)

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

            // Everything the disconnect must clear is in place right now.
            let anchorBeforeStop = await target.runtime.debugSnapshot().rangeSyncAnchor
            XCTAssertNotNil(anchorBeforeStop, "range sync must be live immediately before the disconnect")
            let heldKeysBefore = await target.runtime.debugSnapshot().heldPeerKeys
            XCTAssertTrue(heldKeysBefore.contains(overlayPeerKey), "overlay key held before disconnect")

            // The session ends.
            await overlayPeer.stop()
            try await waitUntil("per-peer records cleared after disconnect") {
                await !target.runtime.debugSnapshot().heldPeerKeys
                    .contains(overlayPeerKey)
            }
            try await waitUntil("session-keyed state released after disconnect") {
                await target.runtime.debugSnapshot().heldSessionIDs
                    .isSubset(of: await target.runtime.debugSnapshot().liveSessionIDs)
            }
        } catch {
            await overlayPeer.stop()
            await withholding.release()
            throw error
        }

        let held = await target.runtime.debugSnapshot().heldPeerKeys
        XCTAssertFalse(
            held.contains(overlayPeerKey),
            "overlay peer \(overlayPeerKey.hex.prefix(8)) still held after disconnect"
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
