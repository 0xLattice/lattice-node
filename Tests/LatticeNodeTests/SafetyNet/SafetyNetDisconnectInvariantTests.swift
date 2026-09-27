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
/// `NodeNetworkRuntime.heldPeerKeysForTesting()` / `heldSessionIDsForTesting()`
/// (DEBUG-only, added for this test) union them, so the assertion here is one
/// line and the refactor cannot drop a map from the audit by moving it.
///
/// Non-vacuous by construction, in this order:
/// - the overlay peer completes its hello (checked through the accepted-hello
///   seam: a session and a hello deadline hold the key from connect, so the
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
/// `overlayRuntime` / `connectAndHello` are copies of the private helpers in
/// `NetworkTrustTests`; `NetworkTransportTestPorts` is shared with that file.
final class SafetyNetDisconnectInvariantTests: XCTestCase {

    func testDisconnectedPeersLeaveNoPerPeerRecordOnEitherPlane() async throws {
        // Long enough that neither the withheld volume fetch nor the range
        // sync can time out on its own during the test: every release below
        // must be attributable to the disconnect, not to a timer.
        let target = try await overlayRuntime(keyByte: 0xd1, requestTimeout: .seconds(60))
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
            handlers: NodeNetworkHandlers(
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
                await target.runtime.overlayHelloCompletedForTesting(overlayPeerKey)
            }
            // A transaction advertisement whose volume is never served: the
            // runtime's lease on this session stays held while it fetches.
            try await send(
                overlayPeer, to: target.peerID,
                topic: NodeNetworkTopic.transactionAvailable,
                payload: try TransactionAvailableMessage(volumeRootCID: withheldRoot).encoded()
            )
            try await waitUntil("withheld volume fetch holds a session lease") {
                !(await target.runtime.heldSessionIDsForTesting()).isEmpty
            }
            await withholding.waitForBlockedRequest()
            let heldBefore = await target.runtime.heldSessionIDsForTesting()
            let liveBefore = await target.runtime.liveSessionIDsForTesting()
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
                await target.runtime.rangeSyncAnchorForTesting() != nil
            }

            // Hierarchy: an immediate-child hello must earn the child role.
            try await childPeer.start()
            try await childPeer.connect(to: target.hierarchyEndpoint)
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
                await target.runtime.hierarchyPeerRoleForTesting(childPeerKey)
                    == .child(["Nexus", "Payments"])
            }

            // Everything the disconnect must clear is in place right now.
            let anchorBeforeStop = await target.runtime.rangeSyncAnchorForTesting()
            XCTAssertNotNil(anchorBeforeStop, "range sync must be live immediately before the disconnect")
            let heldKeysBefore = await target.runtime.heldPeerKeysForTesting()
            XCTAssertTrue(heldKeysBefore.contains(overlayPeerKey), "overlay key held before disconnect")
            XCTAssertTrue(heldKeysBefore.contains(childPeerKey), "child key held before disconnect")

            // Both sessions end.
            await overlayPeer.stop()
            await childPeer.stop()
            try await waitUntil("per-peer records cleared after disconnect") {
                await target.runtime.heldPeerKeysForTesting()
                    .isDisjoint(with: [overlayPeerKey, childPeerKey])
            }
            try await waitUntil("session-keyed state released after disconnect") {
                await target.runtime.heldSessionIDsForTesting()
                    .isSubset(of: await target.runtime.liveSessionIDsForTesting())
            }
        } catch {
            await overlayPeer.stop()
            await childPeer.stop()
            await withholding.release()
            throw error
        }

        let held = await target.runtime.heldPeerKeysForTesting()
        XCTAssertFalse(
            held.contains(overlayPeerKey),
            "overlay peer \(overlayPeerKey.hex.prefix(8)) still held after disconnect"
        )
        XCTAssertFalse(
            held.contains(childPeerKey),
            "hierarchy child peer \(childPeerKey.hex.prefix(8)) still held after disconnect"
        )
        let heldSessions = await target.runtime.heldSessionIDsForTesting()
        let liveSessions = await target.runtime.liveSessionIDsForTesting()
        XCTAssertTrue(
            heldSessions.isSubset(of: liveSessions),
            "session-keyed state outlives its session: "
                + "\(heldSessions.subtracting(liveSessions).map { $0.map { String(format: "%02x", $0) }.joined().prefix(8) })"
        )
        let rangeSyncAnchor = await target.runtime.rangeSyncAnchorForTesting()
        XCTAssertNil(
            rangeSyncAnchor,
            "range sync must not survive its source peer's disconnect"
        )
        await withholding.release()
    }

    // MARK: - Helpers (copied from NetworkTrustTests, which keeps them private)

    private func testCID(_ seed: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
    }

    private func signingKey(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func peerKey(_ key: Curve25519.Signing.PrivateKey) -> PeerKey {
        try! PeerKey(rawRepresentation: key.publicKey.rawRepresentation)
    }

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

    private func overlayRuntime(
        keyByte: UInt8,
        requestTimeout: Duration
    ) async throws -> (
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hierarchyEndpoint: PeerEndpoint,
        hello: Data
    ) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-safety-net-disconnect-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let overlayPort = NetworkTransportTestPorts.allocate()
        let hierarchyPort = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(
                repeating: String(format: "%02x", keyByte),
                count: 32
            ),
            listenPort: overlayPort,
            factListenPort: hierarchyPort,
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        let runtime = try NodeNetworkRuntime(
            configuration: configuration,
            planeConfigurations: try NodeNetworkPlaneConfigurations(
                overlay: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: overlayPort,
                    requestTimeout: requestTimeout,
                    stunServers: [],
                    healthConfig: PeerHealthConfig(enabled: false),
                    mode: .overlay
                ),
                hierarchy: IvyConfig(
                    signingKey: configuration.signingKey,
                    listenPort: hierarchyPort,
                    stunServers: [],
                    maxConnections: IvyConfig.defaultMaxConnections,
                    maxConnectionsPerNetgroup: IvyConfig.defaultMaxConnections,
                    relayEnabled: false,
                    carriers: [],
                    mode: .privateNetwork
                )
            )
        )
        let process = try await ChainProcess.open(configuration: configuration)
        return (
            runtime,
            process,
            PeerID(publicKey: configuration.processPublicKey),
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: overlayPort
            ),
            PeerEndpoint(
                publicKey: configuration.processPublicKey,
                host: "127.0.0.1",
                port: hierarchyPort
            ),
            try ChainHello(
                nexusGenesisCID: configuration.nexusGenesisCID,
                chainPath: configuration.chainPath
            ).encode()
        )
    }

    private func connectAndHello(
        _ peer: Ivy,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data
    ) async throws {
        try await peer.start()
        try await peer.connect(to: endpoint)
        try await waitUntil("overlay peer connected") {
            (await peer.connectedPeers).contains(peerID)
        }
        try await send(peer, to: peerID, topic: NodeNetworkTopic.overlayHello, payload: hello)
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
    private var blockedRequestStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
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
        let pendingStarts = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStarts { waiter.resume() }
        if !released {
            await withCheckedContinuation { blockedWaiters.append($0) }
        }
        return []
    }

    func waitForBlockedRequest() async {
        guard !blockedRequestStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
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
