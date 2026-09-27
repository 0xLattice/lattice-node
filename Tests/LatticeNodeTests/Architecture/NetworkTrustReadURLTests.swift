import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

final class NetworkTrustReadURLTests: NetworkTrustTestCase {
    func testChainHelloCarriesDeclaredReadURLTolerantly() throws {
        // Declared: survives the round-trip.
        let declared = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"],
            publicReadURL: "https://nexus.example"
        )
        let decoded = try ChainHello.decode(try declared.encode())
        XCTAssertEqual(decoded.publicReadURL, "https://nexus.example")
        XCTAssertNoThrow(try decoded.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))

        // Undeclared: byte-identical to the legacy wire (a nil optional emits
        // no key), so legacy peers see exactly the hello they always did.
        let undeclared = ChainHello(
            nexusGenesisCID: nexusCID,
            chainPath: ["Nexus"]
        )
        XCTAssertFalse(String(
            decoding: try undeclared.encode(),
            as: UTF8.self
        ).contains("publicReadURL"))

        // Legacy payload without the field decodes to nil.
        let legacy = try ChainHello.decode(try JSONSerialization.data(
            withJSONObject: [
                "version": ChainHello.protocolVersion,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
            ]
        ))
        XCTAssertNil(legacy.publicReadURL)

        // A non-browsable declared value never costs the session: the hello
        // still decodes and authorizes; ingest just drops the URL.
        let hostile = try ChainHello.decode(try JSONSerialization.data(
            withJSONObject: [
                "version": ChainHello.protocolVersion,
                "nexusGenesisCID": nexusCID,
                "chainPath": ["Nexus"],
                "publicReadURL": "javascript:alert(1)",
            ]
        ))
        XCTAssertNoThrow(try hostile.validateCompatibility(
            expectedNexusGenesisCID: nexusCID,
            expectedChainPath: ["Nexus"]
        ))
        XCTAssertNil(normalizedPublicReadURL(hostile.publicReadURL))
    }

    func testDeclaredReadURLNormalizationAdmitsOnlyBrowsableBases() {
        XCTAssertEqual(
            normalizedPublicReadURL(" https://toy.example/ "),
            "https://toy.example"
        )
        XCTAssertEqual(
            normalizedPublicReadURL("http://198.51.100.7:8081"),
            "http://198.51.100.7:8081"
        )
        XCTAssertEqual(
            normalizedPublicReadURL("https://toy.example/read/"),
            "https://toy.example/read"
        )
        XCTAssertNil(normalizedPublicReadURL(nil))
        XCTAssertNil(normalizedPublicReadURL(""))
        XCTAssertNil(normalizedPublicReadURL("toy.example"))
        XCTAssertNil(normalizedPublicReadURL("ftp://toy.example"))
        XCTAssertNil(normalizedPublicReadURL("https://user:pw@toy.example"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example?x=1"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example#frag"))
        XCTAssertNil(normalizedPublicReadURL("https://"))
        XCTAssertNil(normalizedPublicReadURL(
            "https://toy.example/" + String(
                repeating: "a",
                count: maximumPublicReadURLBytes
            )
        ))
        // Case variants fold to one base so dedup is real; markup
        // metacharacters never survive into explorer-facing JSON.
        XCTAssertEqual(
            normalizedPublicReadURL("HTTPS://Toy.Example/Read"),
            "https://toy.example/Read"
        )
        XCTAssertNil(normalizedPublicReadURL("https://toy.example/\"><script>"))
        XCTAssertNil(normalizedPublicReadURL("https://toy.example/'x"))
        // Every accepted output is a fixed point, so an honestly-normalized
        // URL can never fail the response wire's round-trip validation.
        for candidate in [
            "https://toy.example", " https://toy.example/ ",
            "HTTPS://Toy.Example/Read", "http://198.51.100.7:8081",
            "https://[::1]:8081", "https://%74oy.example",
        ] {
            guard let normalized = normalizedPublicReadURL(candidate) else {
                continue
            }
            XCTAssertEqual(normalizedPublicReadURL(normalized), normalized)
        }
    }

    func testReadEndpointMessagesAreCanonicalAndBounded() throws {
        let genesis = testCID("read-endpoint")
        let request = ReadEndpointRequestMessage(
            requestID: 7,
            genesisCID: genesis
        )
        let decodedRequest = try ReadEndpointRequestMessage.decoded(
            try request.encoded()
        )
        XCTAssertEqual(decodedRequest, request)
        XCTAssertThrowsError(try ReadEndpointRequestMessage(
            requestID: 0,
            genesisCID: genesis
        ).encoded())
        XCTAssertThrowsError(try ReadEndpointRequestMessage(
            requestID: 7,
            genesisCID: "not-a-cid"
        ).encoded())

        let response = ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: ["https://toy.example"]
        )
        let decodedResponse = try ReadEndpointResponseMessage.decoded(
            try response.encoded()
        )
        XCTAssertEqual(decodedResponse, response)
        // Empty answers are valid wire: a fast negative beats a timeout.
        XCTAssertNoThrow(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: []
        ).encoded())
        // Only normalized browsable bases; count bounded.
        XCTAssertThrowsError(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: ["https://toy.example/"]
        ).encoded())
        XCTAssertThrowsError(try ReadEndpointResponseMessage(
            requestID: 7,
            genesisCID: genesis,
            readURLs: (0...ReadEndpointResponseMessage.maximumURLs).map {
                "https://node\($0).example"
            }
        ).encoded())
        // Non-canonical bytes are rejected wholesale.
        XCTAssertThrowsError(try ReadEndpointResponseMessage.decoded(
            try response.encoded() + Data(" ".utf8)
        ))
    }

    func testReadEndpointRequestAnsweredFromSelfDescriptionOnly() async throws {
        let target = try await overlayRuntime(
            keyByte: 0xc1,
            requestTimeout: .seconds(2),
            publicReadURL: "https://nexus.example"
        )
        let service = networkService(
            process: target.process,
            runtime: target.runtime
        )
        let handlers = transactionServiceHandlers(service)
        let recorder = PayloadRecorder()
        let observer = Ivy(config: IvyConfig(
            signingKey: signingKey(0xc2),
            listenPort: 0,
            stunServers: [],
            mode: .overlay
        ))
        let observerDelegate = PayloadRecordingPeer(recorder: recorder)
        await observer.installTestDelegate(observerDelegate)
        do {
            try await target.runtime.start(
                process: target.process,
                chain: handlers
            )
            try await connectAndHello(
                observer,
                peerID: target.peerID,
                endpoint: target.endpoint,
                hello: target.hello
            )
            // Every overlay topic is gated on a completed hello; the runtime
            // announces its tip back in the same handling branch, so seeing it
            // proves the observer's hello landed.
            for _ in 0..<200 {
                if await !recorder.payloads(
                    topic: NodeNetworkTopic.blockAnnouncement
                ).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let maybeOwnGenesis = await target.process.canonicalBlockCID(
                atHeight: 0
            )
            let ownGenesis = try XCTUnwrap(maybeOwnGenesis)
            // The node's own genesis: answered with its configured URL.
            let askOwn = try ReadEndpointRequestMessage(
                requestID: 7,
                genesisCID: ownGenesis
            ).encoded()
            _ = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.readEndpointRequest,
                payload: askOwn
            )
            let own = try await waitForReadEndpointResponse(
                requestID: 7,
                in: recorder
            )
            XCTAssertEqual(own.genesisCID, ownGenesis)
            XCTAssertEqual(own.readURLs, ["https://nexus.example"])

            // A genesis this node knows nothing about: a fast empty negative,
            // never an invented URL.
            let askUnknown = try ReadEndpointRequestMessage(
                requestID: 8,
                genesisCID: testCID("unknown-chain")
            ).encoded()
            _ = await observer.sendMessage(
                to: target.peerID,
                topic: NodeNetworkTopic.readEndpointRequest,
                payload: askUnknown
            )
            let unknown = try await waitForReadEndpointResponse(
                requestID: 8,
                in: recorder
            )
            XCTAssertEqual(unknown.readURLs, [])
            await observer.stop()
            await target.runtime.stop()
        } catch {
            await observer.stop()
            await target.runtime.stop()
            throw error
        }
    }

    func testReadURLDiscoveryListsOwnDeclarationWithoutOwnProviderRecord()
        async throws {
        // The node declares a read URL for its own genesis but advertises no
        // P2P address (no external address, no STUN), so Ivy never stores a
        // provider record under its own key. Its own declaration must still
        // lead the answer: the node best placed to answer must not omit the
        // one endpoint it knows first-hand, leaving only other providers.
        let target = try await overlayRuntime(
            keyByte: 0xc3,
            requestTimeout: .seconds(2),
            publicReadURL: "https://nexus.example"
        )
        let maybeOwnGenesis = await target.process.canonicalBlockCID(
            atHeight: 0
        )
        let ownGenesis = try XCTUnwrap(maybeOwnGenesis)
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: ownGenesis,
            providers: [ReadURLProvider(
                keyByte: 0xc4,
                answers: [["https://remote.example"]]
            )]
        )
        // The remote provider was discovered and asked, and its declaration
        // flows through; the node's own declaration comes first.
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(
            discovery.urls,
            ["https://nexus.example", "https://remote.example"]
        )
    }

    func testReadURLDiscoveryInventsNoURLForUndeclaredProvider() async throws {
        // A provider that answers the ask declaring no read surface has no
        // browsable endpoint; its P2P host is an IP literal, not a read URL.
        // Neither it nor this undeclared node may appear as https://<host>.
        let target = try await overlayRuntime(
            keyByte: 0xc5,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("undeclared-child"),
            providers: [ReadURLProvider(keyByte: 0xc6, answers: [[]])]
        )
        // Not vacuous: the provider was found and asked, and still no URL.
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(discovery.urls, [])
    }

    func testReadURLDiscoveryAsksEveryProviderSharingAHost() async throws {
        // Two provider identities behind one IP (one host running several
        // nodes, or one NAT). The first recorded declares nothing; the
        // second declares a URL. Sharing a host must not hide the declarer.
        let target = try await overlayRuntime(
            keyByte: 0xc7,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("shared-host-child"),
            providers: [
                ReadURLProvider(keyByte: 0xc8, answers: [[]]),
                ReadURLProvider(
                    keyByte: 0xc9,
                    answers: [["https://declared.example"]]
                ),
            ]
        )
        XCTAssertEqual(discovery.asks, [1, 1])
        XCTAssertEqual(discovery.urls, ["https://declared.example"])
    }

    func testReadURLDiscoveryAsksEachProviderIdentityOnce() async throws {
        // One identity announced under two hosts holds two provider routes.
        // It is one responder: one ask slot, one per-responder URL cap —
        // never a second ask it can answer with a fresh pair of URLs.
        let target = try await overlayRuntime(
            keyByte: 0xca,
            requestTimeout: .seconds(2)
        )
        let discovery = try await discoverReadURLs(
            runtime: target.runtime,
            process: target.process,
            peerID: target.peerID,
            endpoint: target.endpoint,
            hello: target.hello,
            genesisCID: testCID("multi-route-child"),
            providers: [ReadURLProvider(
                keyByte: 0xcb,
                routes: ["11.0.0.1", "11.0.0.2"],
                answers: [
                    ["https://first.example", "https://second.example"],
                    ["https://third.example", "https://fourth.example"],
                ]
            )]
        )
        XCTAssertEqual(discovery.asks, [1])
        XCTAssertEqual(
            discovery.urls,
            ["https://first.example", "https://second.example"]
        )
    }

    /// One provider identity for `discoverReadURLs`. It opens one session per
    /// entry in `routes`, in order, each advertising that host (nil: its
    /// loopback listen address) and announcing the genesis; only the last
    /// session stays up. Its n-th ask is answered with `answers[n]`, the last
    /// answer repeating.
    private struct ReadURLProvider {
        let keyByte: UInt8
        var routes: [String?] = [nil]
        let answers: [[String]]
    }

    /// Starts `runtime`, lets each provider (in order) announce itself as a
    /// provider of `genesisCID`, then runs the runtime's read-URL discovery
    /// while the providers answer its asks. Returns the URLs and how many
    /// asks for `genesisCID` each provider received, so an empty result can
    /// never pass for a missed discovery. Stops everything before returning.
    private func discoverReadURLs(
        runtime: NodeNetworkRuntime,
        process: ChainProcess,
        peerID: PeerID,
        endpoint: PeerEndpoint,
        hello: Data,
        genesisCID: String,
        providers: [ReadURLProvider]
    ) async throws -> (urls: [String], asks: [Int]) {
        let service = networkService(process: process, runtime: runtime)
        var instances: [Ivy] = []
        var delegates: [PayloadRecordingPeer] = []
        var liveProviders: [Ivy] = []
        var liveRecorders: [PayloadRecorder] = []
        do {
            try await runtime.start(
                process: process,
                chain: transactionServiceHandlers(service)
            )
            for provider in providers {
                var session: (Ivy, PayloadRecorder)?
                for route in provider.routes {
                    await session?.0.stop()
                    let port = NetworkTransportTestPorts.allocate()
                    let ivy = Ivy(config: IvyConfig(
                        signingKey: signingKey(provider.keyByte),
                        listenPort: port,
                        stunServers: [],
                        externalAddress: route.map { (host: $0, port: port) },
                        mode: .overlay
                    ))
                    let recorder = PayloadRecorder()
                    let delegate = PayloadRecordingPeer(recorder: recorder)
                    await ivy.installTestDelegate(delegate)
                    instances.append(ivy)
                    delegates.append(delegate)
                    try await connectAndHello(
                        ivy,
                        peerID: peerID,
                        endpoint: endpoint,
                        hello: hello
                    )
                    await ivy.announceProvider(
                        rootCID: genesisCID,
                        expiresAt: UInt64(Date().timeIntervalSince1970) + 600
                    )
                    // Frames on one session are handled in order, so an
                    // answered probe sent after the announce proves the
                    // hello landed and the record was stored.
                    _ = await ivy.sendMessage(
                        to: peerID,
                        topic: NodeNetworkTopic.readEndpointRequest,
                        payload: try ReadEndpointRequestMessage(
                            requestID: 1,
                            genesisCID: testCID("probe")
                        ).encoded()
                    )
                    _ = try await waitForReadEndpointResponse(
                        requestID: 1,
                        in: recorder
                    )
                    session = (ivy, recorder)
                }
                if let (ivy, recorder) = session {
                    liveProviders.append(ivy)
                    liveRecorders.append(recorder)
                }
            }

            let urls = await Self.discoverAnsweringAsks(
                runtime: runtime,
                genesisCID: genesisCID,
                providers: liveProviders,
                recorders: liveRecorders,
                answers: providers.map(\.answers),
                to: peerID
            )
            var asks: [Int] = []
            for recorder in liveRecorders {
                asks.append(await Self.readEndpointAsks(
                    for: genesisCID,
                    in: recorder
                ).count)
            }
            for ivy in instances { await ivy.stop() }
            await runtime.stop()
            withExtendedLifetime((service, delegates)) {}
            return (urls, asks)
        } catch {
            for ivy in instances { await ivy.stop() }
            await runtime.stop()
            throw error
        }
    }

    /// `runtime`'s read-URL discovery for `genesisCID`, run while the
    /// providers answer its asks; the responder stops once discovery returns.
    private static func discoverAnsweringAsks(
        runtime: NodeNetworkRuntime,
        genesisCID: String,
        providers: [Ivy],
        recorders: [PayloadRecorder],
        answers: [[[String]]],
        to peerID: PeerID
    ) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                await answerReadEndpointAsks(
                    for: genesisCID,
                    providers: providers,
                    recorders: recorders,
                    answers: answers,
                    to: peerID
                )
                return nil
            }
            group.addTask {
                await runtime.discoverProviderReadURLs(genesisCID: genesisCID)
            }
            var urls: [String] = []
            for await result in group {
                guard let result else { continue }
                urls = result
                group.cancelAll()
            }
            return urls
        }
    }

    /// Until cancelled, answers every ask for `genesisCID` each provider
    /// receives: the n-th with `answers[provider][n]`, the last repeating.
    private static func answerReadEndpointAsks(
        for genesisCID: String,
        providers: [Ivy],
        recorders: [PayloadRecorder],
        answers: [[[String]]],
        to peerID: PeerID
    ) async {
        var answered = [Set<UInt64>](repeating: [], count: providers.count)
        while !Task.isCancelled {
            for index in providers.indices {
                let asks = await readEndpointAsks(
                    for: genesisCID,
                    in: recorders[index]
                )
                for ask in asks {
                    guard answered[index].insert(ask.requestID).inserted
                    else { continue }
                    let slot = min(answered[index].count, answers[index].count)
                    guard let payload = try? ReadEndpointResponseMessage(
                        requestID: ask.requestID,
                        genesisCID: genesisCID,
                        readURLs: answers[index][slot - 1]
                    ).encoded() else { continue }
                    _ = await providers[index].sendMessage(
                        to: peerID,
                        topic: NodeNetworkTopic.readEndpointResponse,
                        payload: payload
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func readEndpointAsks(
        for genesisCID: String,
        in recorder: PayloadRecorder
    ) async -> [ReadEndpointRequestMessage] {
        await recorder.payloads(topic: NodeNetworkTopic.readEndpointRequest)
            .compactMap { try? ReadEndpointRequestMessage.decoded($0) }
            .filter { $0.genesisCID == genesisCID }
    }

    private func waitForReadEndpointResponse(
        requestID: UInt64,
        in recorder: PayloadRecorder
    ) async throws -> ReadEndpointResponseMessage {
        var found: ReadEndpointResponseMessage?
        do {
            try await eventually("read endpoint response") {
                for payload in await recorder.payloads(
                    topic: NodeNetworkTopic.readEndpointResponse
                ) {
                    if let response = try? ReadEndpointResponseMessage.decoded(
                        payload
                    ), response.requestID == requestID {
                        found = response
                        return true
                    }
                }
                return false
            }
        } catch is TestWaitError {
            let seen = await recorder.topics()
            throw NetworkTestError.failedPhase("read endpoint response; saw \(seen)")
        }
        return try XCTUnwrap(found)
    }
}
