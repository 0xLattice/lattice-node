import Foundation
@testable import Ivy
import Lattice
import Tally
import XCTest
@testable import LatticeNode

/// A fresh node finds the peers hosting a child level through the level's
/// rendezvous, while Nexus keeps advancing. The host and the follower share
/// only a Nexus-only hub, which cannot sync the child for them. Each node
/// advertises a routable address - a loopback address is never accepted as a
/// referral - and dials to those addresses are rewritten to loopback.
final class PeerSearchRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
    }

    /// Routable stand-in address → loopback port, shared by every node's dialer.
    private static func advertised(_ port: UInt16) -> String { "8.8.\(port >> 8).\(port & 0xFF)" }

    private func start(
        keyByte: UInt8, hosted: [[String]], peers: [PeerEndpoint] = [], interval: TimeInterval = 5,
        storage: URL? = nil, alphaSeeds: [PeerEndpoint] = [], peerTarget: Int = 8
    ) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let host = Self.advertised(port)
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage ?? temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            bootstrapPeers: peers,
            childSeedPeers: alphaSeeds.isEmpty ? [:] : [Self.alpha: alphaSeeds],
            peerTarget: peerTarget,
            externalAddress: host,
            peerSearchInterval: interval,
            hostedChildren: hosted,
            childSpecs: hosted.isEmpty ? [:] : [Self.alpha: Self.spec]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: port,
            bootstrapPeers: peers,
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            // No background routing refresh: only the node's peer search
            // may connect the follower to the host.
            routingRefreshInterval: .seconds(3_600),
            externalAddress: (host, port),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        await runtime.ivy.setDialEndpointRewriteForTesting { endpoint in
            endpoint.host.hasPrefix("8.8.")
                ? PeerEndpoint(publicKey: endpoint.publicKey, host: "127.0.0.1", port: endpoint.port)
                : endpoint
        }
        addTeardownBlock { await runtime.stop() }
        return Node(
            runtime: runtime,
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    func testAFollowerFindsTheChildsHostWhileNexusAdvances() async throws {
        let hub = try await start(keyByte: 0x61, hosted: [])
        let host = try await start(keyByte: 0x62, hosted: [Self.alpha], peers: [hub.endpoint])
        let follower = try await start(keyByte: 0x63, hosted: [Self.alpha], peers: [hub.endpoint])

        // The host keeps mining Nexus and Alpha, well inside the 5 s search
        // interval, so Nexus never stalls on the follower: only Alpha's own
        // rendezvous can lead it to the host.
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let (miner, alpha) = (host.runtime, Self.alpha)
        let mining = Task { [miner, alpha, recipient] in
            while !Task.isCancelled {
                _ = try? await miner.mineBlock(MiningTemplateRequest(recipients: [
                    MiningRecipient(chainPath: alpha, address: recipient),
                ]))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { mining.cancel() }

        let hostAlpha = try XCTUnwrap(host.runtime.levelReads[Self.alpha])
        let followerAlpha = try XCTUnwrap(follower.runtime.levelReads[Self.alpha])
        let followerNexus = follower.runtime.reads
        try await eventually("the host mines Alpha past genesis") {
            (await hostAlpha.readSnapshot().height ?? 0) >= 2
        }
        try await eventually("the follower follows Nexus through the hub") {
            (await followerNexus.readSnapshot().height ?? 0) >= 2
        }
        // Within the 30 s sync-request deadline: a node that only finds the
        // host after a stalled request has churned its Nexus peers (stalling
        // Nexus, which the Nexus-only search waits for) does not pass.
        try await eventually("the follower finds Alpha's host and syncs Alpha", within: .seconds(20)) {
            (await followerAlpha.readSnapshot().height ?? 0) >= 2
        }
    }

    /// Hosting is learned when a session opens, not an announcement interval
    /// later: a host that joins after the follower is named under Alpha's
    /// rendezvous on the follower as soon as they are connected.
    func testAPeerIsKnownToHostALevelAsSoonAsItsSessionOpens() async throws {
        let hub = try await start(keyByte: 0x67, hosted: [], interval: 3_600)
        let follower = try await start(keyByte: 0x68, hosted: [Self.alpha], peers: [hub.endpoint], interval: 3_600)
        try await eventually("the follower joins through the hub") { follower.runtime.peerCount == 1 }
        let host = try await start(keyByte: 0x69, hosted: [Self.alpha], peers: [hub.endpoint], interval: 3_600)
        let hostID = PeerID(publicKey: host.endpoint.publicKey)
        let (ivy, key) = (follower.runtime.ivy, ChainPeersKey.key(
            nexusGenesisCID: follower.runtime.configuration.nexusGenesisCID, chainPath: Self.alpha
        ))
        try await eventually("the follower knows its new peer hosts Alpha", within: .seconds(20)) {
            guard await ivy.connectedPeers.contains(hostID) else { return false }
            return await ivy.providers(for: key).contains(hostID)
        }
    }

    /// A chain counts its own peers: the follower's one peer, a Nexus-only
    /// hub, is a peer of Nexus and not of Alpha.
    private func assertOnlyNexusHasAPeer(_ follower: Node) async throws {
        try await eventually("the follower joins through the hub") { follower.runtime.peerCount == 1 }
        XCTAssertEqual(follower.runtime.levelReads[Self.alpha]?.peerCount(), 0)
    }

    /// A child with no peer of its own dials the peers it remembers for
    /// itself, however well connected Nexus is. The host is on no rendezvous
    /// the follower can reach (they share no peer) and is not configured:
    /// only Alpha's own book names it. The follower's Nexus has all the
    /// peers it wants, so nothing node-wide would dial anyone.
    func testAChildWithNoPeersDialsItsOwnBookWhileNexusHasEnough() async throws {
        let hub = try await start(keyByte: 0x6a, hosted: [], interval: 3_600)
        let host = try await start(keyByte: 0x6b, hosted: [Self.alpha], interval: 3_600)

        let directory = temporaryDirectory(create: true)
        let entry = PeerBook.Entry(
            publicKey: host.endpoint.publicKey, host: host.endpoint.host, port: host.endpoint.port,
            lastSeen: NodeRuntime.now(), failures: 0
        )
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "chains": ["Nexus/Alpha": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))]],
        ]).write(to: directory.appendingPathComponent(PeerMemory.fileName))

        let follower = try await start(
            keyByte: 0x6c, hosted: [Self.alpha], peers: [hub.endpoint], interval: 3_600,
            storage: directory, peerTarget: 1
        )
        let hostID = PeerID(publicKey: host.endpoint.publicKey)
        let ivy = follower.runtime.ivy
        try await eventually("the follower dials the host Alpha remembers", within: .seconds(20)) {
            await ivy.connectedPeers.contains(hostID)
        }
        // The host's hello names Alpha: it is Alpha's peer, and Nexus's.
        try await eventually("Alpha counts its own peer", within: .seconds(20)) {
            follower.runtime.levelReads[Self.alpha]?.peerCount() == 1 && follower.runtime.peerCount == 2
        }
        // Nexus learns the host because a dial reached it; Alpha keeps it
        // because its session says it hosts Alpha.
        try await eventually("the host is remembered for both chains") {
            let nexus = await follower.runtime.peerMemory?.remembered(for: ["Nexus"]).map(\.publicKey)
            let alpha = await follower.runtime.peerMemory?.remembered(for: Self.alpha).map(\.publicKey)
            return nexus == [host.endpoint.publicKey] && alpha == [host.endpoint.publicKey]
        }
    }

    /// A child's own seeds, given by its operator, are dialled when the
    /// chain is short of peers and nothing else names one: here the host
    /// shares no peer with the follower, and nothing is remembered.
    func testAChildShortOfPeersDialsItsOwnSeeds() async throws {
        let hub = try await start(keyByte: 0x6d, hosted: [], interval: 3_600)
        let host = try await start(keyByte: 0x6e, hosted: [Self.alpha], interval: 3_600)
        let follower = try await start(
            keyByte: 0x6f, hosted: [Self.alpha], peers: [hub.endpoint], interval: 3_600,
            alphaSeeds: [host.endpoint], peerTarget: 1
        )
        try await eventually("Alpha is served by its seed", within: .seconds(20)) {
            follower.runtime.levelReads[Self.alpha]?.peerCount() == 1 && follower.runtime.peerCount == 2
        }
        // A seed that was reached is remembered like any other peer.
        try await eventually("the seed is in Alpha's book") {
            await follower.runtime.peerMemory?.remembered(for: Self.alpha).map(\.publicKey) == [host.endpoint.publicKey]
        }
    }

    /// With no seed and nothing remembered, a child with no host in reach
    /// has no peer, and says so, while Nexus has one.
    func testAChildCountsOnlyThePeersThatHostIt() async throws {
        let hub = try await start(keyByte: 0x70, hosted: [], interval: 3_600)
        let follower = try await start(keyByte: 0x71, hosted: [Self.alpha], peers: [hub.endpoint], interval: 3_600)
        try await assertOnlyNexusHasAPeer(follower)
    }

    /// Seeds for a chain this node does not host are refused.
    func testSeedsForAChainNotHostedAreRefused() throws {
        func configuration(hosted: [[String]], seeds: [[String]: [PeerEndpoint]]) throws -> NodeConfiguration {
            try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: temporaryDirectory(),
                privateKeyHex: String(repeating: "72", count: 32),
                childSeedPeers: seeds, hostedChildren: hosted
            )
        }
        let seed = PeerEndpoint(publicKey: String(repeating: "73", count: 32), host: "198.51.100.1", port: 4001)
        XCTAssertNoThrow(try configuration(hosted: [Self.alpha], seeds: [Self.alpha: [seed]]))
        // The hello names what is hosted, beside what the node speaks.
        XCTAssertEqual(
            try configuration(hosted: [Self.alpha], seeds: [:]).helloCapabilities,
            [ChainHandshake.volumeBundle, "host:Nexus/Alpha"]
        )
        XCTAssertThrowsError(try configuration(hosted: [], seeds: [Self.alpha: [seed]]))
        XCTAssertThrowsError(try configuration(hosted: [Self.alpha], seeds: [["Nexus"]: [seed]]))
    }
}
