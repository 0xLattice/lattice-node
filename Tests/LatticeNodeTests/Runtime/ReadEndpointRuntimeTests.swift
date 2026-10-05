import Foundation
import Hummingbird
import HummingbirdTesting
import Ivy
import Lattice
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

/// Declared read URLs across three levels, Nexus → Alpha → Beta, on
/// loopback Ivy. One host runs the whole tree and declares a URL; the others
/// find it only through what they host: Beta's URL only through a node that
/// hosts Alpha, Alpha's through any Nexus node, and never a URL from a node
/// that does not host the chain.
final class ReadEndpointRuntimeTests: XCTestCase {
    static let alpha = ["Nexus", "Alpha"]
    static let beta = alpha + ["Beta"]
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private struct Node {
        let runtime: NodeRuntime
        let endpoint: PeerEndpoint
    }

    private func start(
        keyByte: UInt8,
        hosted: [[String]],
        specs: [[String]: ChainSpec] = [:],
        url: String? = nil,
        publicSubmit: Bool = false,
        peers: [PeerEndpoint] = []
    ) async throws -> Node {
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(),
            privateKeyHex: String(repeating: String(format: "%02x", keyByte), count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            bootstrapPeers: peers,
            externalAddress: "127.0.0.1",
            hostedChildren: hosted,
            childSpecs: specs,
            publicReadURL: url,
            publicSubmit: publicSubmit
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey,
            listenPort: port,
            bootstrapPeers: peers,
            requestTimeout: .seconds(5),
            stunServers: [],
            healthConfig: PeerHealthConfig(enabled: false),
            externalAddress: ("127.0.0.1", port),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
        addTeardownBlock { await runtime.stop() }
        return Node(
            runtime: runtime,
            endpoint: PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port)
        )
    }

    func testAChildsDeclaredURLIsFoundOnlyThroughANodeHostingItsParent() async throws {
        let hostURL = "https://tree-host.example"
        let host = try await start(
            keyByte: 0x51, hosted: [Self.alpha, Self.beta],
            specs: [Self.alpha: Self.spec, Self.beta: Self.spec], url: hostURL, publicSubmit: true
        )
        // Beta's genesis needs an executed Alpha block with a changed state.
        let betaReads = try XCTUnwrap(host.runtime.levelReads[Self.beta])
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        try await eventually("Beta is mined under Alpha") {
            _ = try await host.runtime.mineBlock(MiningTemplateRequest(recipients: [
                MiningRecipient(chainPath: Self.alpha, address: recipient),
            ]))
            return (await betaReads.readSnapshot().height ?? 0) >= 1
        }

        // Alpha's follower (no URL), a Nexus-only node, and a Nexus-only
        // node that declares a URL but hosts no child.
        let alphaFollower = try await start(keyByte: 0x52, hosted: [Self.alpha], peers: [host.endpoint])
        let nexusOnly = try await start(keyByte: 0x53, hosted: [], peers: [host.endpoint])
        let declaresButHostsNoChild = try await start(
            keyByte: 0x54, hosted: [], url: "https://not-a-host.example", peers: [host.endpoint]
        )
        let followerAlpha = try XCTUnwrap(alphaFollower.runtime.levelReads[Self.alpha])
        let hostAlpha = try XCTUnwrap(host.runtime.levelReads[Self.alpha])
        let hostAlphaSnapshot = await hostAlpha.readSnapshot()
        let hostAlphaHeight = try XCTUnwrap(hostAlphaSnapshot.height)
        try await eventually("the follower executes Alpha to the host's tip") {
            (await followerAlpha.readSnapshot().height ?? 0) >= hostAlphaHeight
        }

        // Beta through the node hosting Alpha: the host's URL, beside the
        // Beta block Alpha commits.
        var found: ExplorerChainEndpoints?
        try await eventually("Beta's URL is found through Alpha's follower") {
            for node in [host, alphaFollower, nexusOnly, declaresButHostsNoChild] {
                node.runtime.inputs.yield(.maintenance)
            }
            found = await alphaFollower.runtime.chainEndpoints(Self.beta)
            return found?.endpoints == [hostURL]
        }
        // The host's submit declaration travels with its URL, at every level.
        XCTAssertEqual(found?.submitEndpoints, [hostURL])
        let committed = try XCTUnwrap(found?.committedBlock)
        let hostBetaBlock = await betaReads.explorerBlock(cid: committed)
        XCTAssertNotNil(hostBetaBlock, "the committed block is one the declared host serves on Beta")

        // A node that does not host Alpha has no say over Beta.
        let nexusOnlyBeta = await nexusOnly.runtime.chainEndpoints(Self.beta)
        XCTAssertNil(nexusOnlyBeta)
        // Alpha through any Nexus node; the URL-declaring non-host never
        // appears, at any level.
        try await eventually("Alpha's URL is found through a Nexus-only node") {
            await nexusOnly.runtime.chainEndpoints(Self.alpha)?.endpoints == [hostURL]
        }
        let alphaThroughNexus = await nexusOnly.runtime.chainEndpoints(Self.alpha)
        XCTAssertEqual(alphaThroughNexus?.submitEndpoints, [hostURL])
        for path in [Self.alpha, Self.beta] {
            let listed = await alphaFollower.runtime.chainEndpoints(path)?.endpoints ?? []
            XCTAssertFalse(listed.contains("https://not-a-host.example"), "\(path)")
        }
        // The host lists itself first for a child it hosts.
        let own = await host.runtime.chainEndpoints(Self.beta)
        XCTAssertEqual(own?.endpoints.first, hostURL)
        XCTAssertEqual(own?.submitEndpoints, [hostURL])
        // An uncommitted, unhosted name is not looked up.
        let unknown = await alphaFollower.runtime.chainEndpoints(Self.alpha + ["Gamma"])
        XCTAssertNil(unknown)

        // The public route, and the children listing at a level the node
        // hosts without hosting the child: Beta listed by CID.
        let app = makePublicReadApplication(service: alphaFollower.runtime, host: "127.0.0.1", port: 8081)
        let followerAlphaSnapshot = await followerAlpha.readSnapshot()
        let alphaTip = try XCTUnwrap(followerAlphaSnapshot.tipCID)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/chain/endpoints?chainPath=Nexus/Alpha/Beta", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try JSONDecoder().decode(ExplorerChainEndpoints.self, from: Data(buffer: response.body))
                XCTAssertEqual(body.endpoints, [hostURL])
                XCTAssertEqual(body.submitEndpoints, [hostURL])
                XCTAssertEqual(body.chainPath, Self.beta)
            }
            for (uri, status) in [
                ("/api/chain/endpoints", HTTPResponse.Status.badRequest),
                ("/api/chain/endpoints?chainPath=Nexus", .badRequest),
                ("/api/chain/endpoints?chainPath=Nexus/Alpha/Beta/Delta", .notFound),
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, status, uri)
                }
            }
            try await client.execute(
                uri: "/api/block/\(alphaTip)/children?chainPath=Nexus/Alpha", method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try JSONDecoder().decode(ExplorerBlockChildren.self, from: Data(buffer: response.body))
                XCTAssertEqual(body.children.map(\.directory), ["Beta"])
                XCTAssertNil(body.children.first?.height, "the follower does not hold Beta's block")
            }
            // The block list at a hosted child level: Alpha's own chain.
            try await client.execute(uri: "/api/blocks?chainPath=Nexus/Alpha", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let body = try JSONDecoder().decode(ExplorerBlocksPage.self, from: Data(buffer: response.body))
                XCTAssertEqual(body.blocks.first?.hash, alphaTip)
                XCTAssertEqual(body.blocks.first?.height, followerAlphaSnapshot.height)
                XCTAssertEqual(body.blocks.map(\.height), body.blocks.map(\.height).sorted(by: >))
                for (newer, older) in zip(body.blocks, body.blocks.dropFirst()) {
                    XCTAssertEqual(newer.previousBlock, older.hash)
                }
            }
        }
    }
}
