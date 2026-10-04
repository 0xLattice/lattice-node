import Crypto
import Foundation
import Ivy
import XCTest
@testable import LatticeNode

/// The read-endpoint directory's bounds, over a scripted transport: who is
/// asked, what is counted, when a lookup ends, and what is reused.
final class ReadEndpointTests: XCTestCase {
    private static let path = ["Nexus", "Alpha", "Beta"]

    private static func key(_ seed: Int) -> String {
        let signing = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: UInt8(seed % 256), count: 31) + [UInt8(seed / 256)]
        )
        return try! PeerKey(rawRepresentation: signing.publicKey.rawRepresentation).hex
    }

    private static func endpoint(_ seed: Int) -> PeerEndpoint {
        PeerEndpoint(publicKey: key(seed), host: "127.0.0.1", port: UInt16(20_000 + seed))
    }

    /// Records what the directory did; `respond` answers each ask.
    private actor Script {
        var directory: ReadEndpointDirectory?
        var lookups = 0
        var asked: [String] = []
        var released: [String] = []
        var discoveryDelay: UInt64 = 0
        let providers: [PeerEndpoint]
        let respond: @Sendable (PeerEndpoint, ReadEndpointRequestMessage) -> [(String, ReadEndpointResponseMessage)]

        init(
            providers: [PeerEndpoint],
            respond: @escaping @Sendable (PeerEndpoint, ReadEndpointRequestMessage)
                -> [(String, ReadEndpointResponseMessage)]
        ) {
            self.providers = providers
            self.respond = respond
        }

        func set(_ directory: ReadEndpointDirectory) { self.directory = directory }

        func slowDiscovery(_ nanoseconds: UInt64) { discoveryDelay = nanoseconds }

        func lookup() async -> [PeerEndpoint] {
            lookups += 1
            if discoveryDelay > 0 { try? await Task.sleep(nanoseconds: discoveryDelay) }
            return providers
        }

        /// Every ask "dials": a session the directory must release.
        func ask(_ provider: PeerEndpoint, _ request: ReadEndpointRequestMessage) async -> Bool {
            asked.append(provider.publicKey)
            for (from, response) in respond(provider, request) {
                await directory?.receive(response, from: from)
            }
            return true
        }

        func release(_ provider: PeerEndpoint) { released.append(provider.publicKey) }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 1_000.0
        func now() -> Double { lock.withLock { seconds } }
        func advance(_ by: Double) { lock.withLock { seconds += by } }
    }

    private func directory(
        _ script: Script,
        deadline: Duration = .seconds(2),
        clock: Clock = Clock(),
        ownKey: String = ReadEndpointTests.key(999)
    ) async -> ReadEndpointDirectory {
        let directory = ReadEndpointDirectory(
            transport: ReadEndpointTransport(
                providers: { _ in await script.lookup() },
                ask: { await script.ask($0, $1) },
                release: { await script.release($0) }
            ),
            nexusGenesisCID: NexusGenesis.expectedBlockHash,
            ownKey: ownKey,
            deadline: deadline,
            clock: { clock.now() }
        )
        await script.set(directory)
        return directory
    }

    private static func answer(
        _ provider: PeerEndpoint, _ request: ReadEndpointRequestMessage, url: String
    ) -> (String, ReadEndpointResponseMessage) {
        (provider.publicKey, ReadEndpointResponseMessage(chainPath: request.chainPath, requestID: request.requestID, url: url))
    }

    /// A crowd of announcers, each answering many times with many URLs,
    /// gets at most `maximumAsked` providers asked and at most
    /// `perResponderCap` URLs from any one of them.
    func testASybilFloodOfProvidersIsBoundedByTheAskedCountAndThePerResponderCap() async throws {
        let crowd = (0..<200).map(Self.endpoint)
        let script = Script(providers: crowd) { provider, request in
            (0..<5).map { Self.answer(provider, request, url: "https://\(provider.publicKey.prefix(16))-\($0).example") }
        }
        let directory = await directory(script)
        let urls = await directory.lookup(Self.path)

        let asked = await script.asked
        XCTAssertEqual(asked.count, ReadEndpointDirectory.maximumAsked)
        XCTAssertEqual(Set(asked).count, asked.count, "no provider is asked twice")
        XCTAssertLessThanOrEqual(urls.count, ReadEndpointDirectory.maximumAsked * ReadEndpointDirectory.perResponderCap)
        for key in Set(asked) {
            let fromKey = urls.filter { $0.hasPrefix("https://\(key.prefix(16))-") }
            XCTAssertLessThanOrEqual(fromKey.count, ReadEndpointDirectory.perResponderCap)
        }
        for url in urls {
            XCTAssertTrue(asked.contains { url.hasPrefix("https://\($0.prefix(16))-") }, "only asked providers count")
        }
    }

    /// Providers that never answer cost one shared deadline, not one each.
    func testSilentProvidersEndTheLookupAtOneSharedDeadline() async throws {
        let talker = Self.endpoint(1)
        let script = Script(providers: [talker] + (2..<8).map(Self.endpoint)) { provider, request in
            provider == talker ? [Self.answer(provider, request, url: "https://talker.example")] : []
        }
        let directory = await directory(script, deadline: .milliseconds(300))
        let start = ContinuousClock.now
        let urls = await directory.lookup(Self.path)
        XCTAssertEqual(urls, ["https://talker.example"])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    /// A provider lookup that never returns is inside the deadline too.
    func testTheDeadlineCoversProviderDiscovery() async throws {
        let script = Script(providers: [Self.endpoint(1)]) { provider, request in
            [Self.answer(provider, request, url: "https://late.example")]
        }
        await script.slowDiscovery(5_000_000_000)
        let directory = await directory(script, deadline: .milliseconds(200))
        let start = ContinuousClock.now
        let urls = await directory.lookup(Self.path)
        XCTAssertEqual(urls, [])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    /// Sessions dialed only to ask are closed when the lookup ends.
    func testSessionsDialedForALookupAreReleasedWhenItEnds() async throws {
        let providers = (1...3).map(Self.endpoint)
        let script = Script(providers: providers) { provider, request in
            [Self.answer(provider, request, url: "https://\(provider.port).example")]
        }
        let directory = await directory(script, deadline: .milliseconds(300))
        let urls = await directory.lookup(Self.path)
        XCTAssertEqual(Set(urls).count, 3)
        try await eventually("every dialed session is released") {
            Set(await script.released) == Set(providers.map(\.publicKey))
        }
    }

    /// An answer counts only from the peer the request went to, for the
    /// path it asked; this node's own key is never asked.
    func testAnswersFromOtherPeersOrForOtherPathsAreIgnored() async throws {
        let own = Self.key(7)
        let asked = Self.endpoint(1)
        let script = Script(providers: [asked, Self.endpoint(7)]) { provider, request in
            [
                (Self.key(2), ReadEndpointResponseMessage(
                    chainPath: request.chainPath, requestID: request.requestID, url: "https://impostor.example"
                )),
                (provider.publicKey, ReadEndpointResponseMessage(
                    chainPath: ["Nexus", "Other"], requestID: request.requestID, url: "https://other.example"
                )),
            ]
        }
        let directory = await directory(script, deadline: .milliseconds(200), ownKey: own)
        let urls = await directory.lookup(Self.path)
        XCTAssertEqual(urls, [])
        let askedKeys = await script.asked
        XCTAssertEqual(askedKeys, [asked.publicKey])
    }

    /// Identical lookups in flight share one fan-out, and a result is reused
    /// until it is `cacheSeconds` old.
    func testIdenticalConcurrentLookupsCoalesceAndResultsAreCached() async throws {
        let clock = Clock()
        let script = Script(providers: [Self.endpoint(1)]) { provider, request in
            [Self.answer(provider, request, url: "https://one.example")]
        }
        let directory = await directory(script, clock: clock)
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<10 { group.addTask { await directory.lookup(Self.path) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: ["https://one.example"], count: 10))
        let coalesced = await script.lookups
        XCTAssertEqual(coalesced, 1)

        _ = await directory.lookup(Self.path)
        let cached = await script.lookups
        XCTAssertEqual(cached, 1)

        clock.advance(31)
        _ = await directory.lookup(Self.path)
        let expired = await script.lookups
        XCTAssertEqual(expired, 2)
    }

    /// Nothing found is remembered only briefly: a host that just announced
    /// is found on a lookup soon after.
    func testAnEmptyResultIsCachedOnlyBriefly() async throws {
        let clock = Clock()
        let script = Script(providers: []) { _, _ in [] }
        let directory = await directory(script, clock: clock)
        _ = await directory.lookup(Self.path)
        _ = await directory.lookup(Self.path)
        let cached = await script.lookups
        XCTAssertEqual(cached, 1)
        clock.advance(ReadEndpointDirectory.emptyCacheSeconds + 1)
        _ = await directory.lookup(Self.path)
        let expired = await script.lookups
        XCTAssertEqual(expired, 2)
    }

    /// A node answers only for a level it hosts, and only with a declared URL.
    func testOnlyAHostedLevelWithADeclaredURLIsAnswered() {
        let hosted: Set<[String]> = [["Nexus"], ["Nexus", "Alpha"]]
        let request = ReadEndpointRequestMessage(chainPath: ["Nexus", "Alpha"], requestID: 9)
        XCTAssertEqual(
            ReadEndpointDirectory.answer(request, hosted: hosted, url: "https://a.example"),
            ReadEndpointResponseMessage(chainPath: ["Nexus", "Alpha"], requestID: 9, url: "https://a.example")
        )
        XCTAssertNil(ReadEndpointDirectory.answer(
            ReadEndpointRequestMessage(chainPath: Self.path, requestID: 9), hosted: hosted, url: "https://a.example"
        ))
        XCTAssertNil(ReadEndpointDirectory.answer(request, hosted: hosted, url: nil))
    }

    func testWireMessagesAreCanonicalAndRejectABadURL() throws {
        let request = ReadEndpointRequestMessage(chainPath: Self.path, requestID: 3)
        XCTAssertEqual(try ReadEndpointRequestMessage.decoded(request.encoded()), request)
        let response = ReadEndpointResponseMessage(chainPath: Self.path, requestID: 3, url: "https://b.example/reads")
        XCTAssertEqual(try ReadEndpointResponseMessage.decoded(response.encoded()), response)

        for url in ["ftp://b.example", "https://", "b.example", "https://u:p@b.example", "https://b.example/?q=1",
                    "https://b.example/#f", "https://b.example/ space", "https://" + String(repeating: "a", count: 600)] {
            XCTAssertThrowsError(
                try ReadEndpointResponseMessage(chainPath: Self.path, requestID: 3, url: url).encoded(), url
            )
        }
        XCTAssertThrowsError(try ReadEndpointRequestMessage(chainPath: ["Other"], requestID: 1).encoded())
    }

    func testTheConfigurationAcceptsOnlyAnAbsoluteHTTPURL() throws {
        let directory = temporaryDirectory()
        let key = String(repeating: "01", count: 32)
        XCTAssertEqual(try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: key,
            publicReadURL: "https://lattice-mainnet-testnet.fly.dev"
        ).publicReadURL, "https://lattice-mainnet-testnet.fly.dev")
        XCTAssertNotNil(try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: directory, privateKeyHex: key, publicReadURL: "http://10.0.0.1:8081"
        ).publicReadURL)
        for bad in ["lattice.example", "/reads", "javascript:alert(1)", "https://a.example?x=1"] {
            XCTAssertThrowsError(try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: key, publicReadURL: bad
            ), bad) { error in
                XCTAssertEqual(error as? NodeConfigurationError, .invalidPublicReadURL)
            }
        }
    }
}
