import XCTest
import Ivy
@testable import LatticeNode

/// The peer book: what a node remembers of the network across restarts, and
/// the limits that keep that memory from being filled or steered.
final class PeerMemoryTests: XCTestCase {
    private func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func endpoint(_ byte: UInt8, host: String? = nil, port: UInt16 = 4001) -> PeerEndpoint {
        PeerEndpoint(publicKey: key(byte), host: host ?? "198.51.\(byte).7", port: port)
    }

    private let day: Int64 = 24 * 60 * 60 * 1_000

    func testItRemembersThePeersItHoldsSessionsWithAndNotItsOwnOrConfiguredOnes() {
        var book = PeerBook()
        book.reached([endpoint(1), endpoint(2), endpoint(3)], excluding: [key(3)], now: 1_000)
        XCTAssertEqual(Set(book.entries.keys), [key(1), key(2)])
        // Seen again, perhaps somewhere else: one address per identity, the latest.
        book.reached([endpoint(1, host: "203.0.113.9", port: 5001)], excluding: [], now: 2_000)
        XCTAssertEqual(book.entries[key(1)]?.endpoint, endpoint(1, host: "203.0.113.9", port: 5001))
        XCTAssertEqual(book.entries[key(1)]?.lastSeen, 2_000)
        XCTAssertEqual(book.entries.count, 2)
    }

    func testAnAddressThatCouldNotBeDialledIsNotRemembered() {
        var book = PeerBook()
        book.reached([
            PeerEndpoint(publicKey: "not a key", host: "198.51.100.1", port: 4001),
            PeerEndpoint(publicKey: key(1), host: "", port: 4001),
            PeerEndpoint(publicKey: key(2), host: "unknown", port: 4001),
            PeerEndpoint(publicKey: key(3), host: "198.51.100.3", port: 0),
            PeerEndpoint(publicKey: key(4), host: "host with space", port: 4001),
            PeerEndpoint(publicKey: key(5), host: String(repeating: "a", count: 254), port: 4001),
        ], excluding: [], now: 1)
        XCTAssertTrue(book.entries.isEmpty)
    }

    func testASessionStillOpenKeepsItsPeerFromAgeingAndAStrangerIsNotAdded() {
        var book = PeerBook()
        book.reached([endpoint(1), endpoint(2)], excluding: [], now: 0)
        book.failed(key(1))
        book.stillOpen([key(1), key(7)], now: PeerBook.horizon + 5)
        // Still in session: fresh, and its earlier failure forgotten. Not in
        // session since: aged out. Never dialled by this node: not remembered,
        // whatever session it holds.
        XCTAssertEqual(Set(book.entries.keys), [key(1)])
        XCTAssertEqual(book.entries[key(1)]?.lastSeen, PeerBook.horizon + 5)
        XCTAssertEqual(book.entries[key(1)]?.failures, 0)
    }

    func testAPeerNotSeenWithinTheHorizonIsForgotten() {
        var book = PeerBook()
        book.reached([endpoint(1)], excluding: [], now: 0)
        book.reached([endpoint(2)], excluding: [], now: PeerBook.horizon)
        XCTAssertEqual(Set(book.entries.keys), [key(1), key(2)], "exactly at the horizon it is still remembered")
        book.prune(now: PeerBook.horizon + 1)
        XCTAssertEqual(Set(book.entries.keys), [key(2)])
    }

    func testOneNetworkCannotBecomeTheWholeMemory() {
        var book = PeerBook()
        // Twenty peers in one /16, seen in order; one elsewhere, seen first.
        book.reached([endpoint(200, host: "203.0.113.1")], excluding: [], now: 1)
        for index in UInt8(1)...20 {
            book.reached([endpoint(index, host: "198.51.100.\(index)")], excluding: [], now: Int64(10 + index))
        }
        let sameGroup = book.entries.values.filter { PeerBook.group($0.host) == "198.51" }
        XCTAssertEqual(sameGroup.count, PeerBook.capacityPerGroup)
        // The most recently seen of the group are the ones kept.
        XCTAssertEqual(Set(sameGroup.map(\.publicKey)), Set((13...20).map { key(UInt8($0)) }))
        XCTAssertNotNil(book.entries[key(200)], "a peer elsewhere is not crowded out by them")
        // A hostname is its own group; addresses group by /16.
        XCTAssertEqual(PeerBook.group("Seed1.Lattice.Build"), "seed1.lattice.build")
        XCTAssertEqual(PeerBook.group("137.66.36.149"), PeerBook.group("137.66.14.188"))
        XCTAssertNotEqual(PeerBook.group("137.66.36.149"), PeerBook.group("66.241.125.189"))
    }

    func testTheBookIsBoundedAndKeepsTheMostRecentlySeen() {
        var book = PeerBook()
        let total = PeerBook.capacity + 40
        // Distinct identities, each a host of its own (so no group limit applies), seen in order.
        for index in 1...total {
            book.reached(
                [PeerEndpoint(publicKey: String(format: "%064x", index), host: "peer\(index).example", port: 4001)],
                excluding: [], now: Int64(index)
            )
        }
        XCTAssertEqual(book.entries.count, PeerBook.capacity)
        XCTAssertNil(book.entries[String(format: "%064x", 1)], "the oldest is the one dropped")
        XCTAssertNotNil(book.entries[String(format: "%064x", total)])
    }

    func testAPeerThatKeepsRefusingIsForgottenAndOneSeenAgainIsNot() {
        var book = PeerBook()
        book.reached([endpoint(1), endpoint(2)], excluding: [], now: 1)
        for _ in 1..<PeerBook.maxFailures { book.failed(key(1)); book.failed(key(2)) }
        XCTAssertEqual(book.entries.count, 2)
        // Seen again: its failures are behind it.
        book.reached([endpoint(2)], excluding: [], now: 2)
        book.failed(key(1))
        book.failed(key(2))
        XCTAssertEqual(Set(book.entries.keys), [key(2)])
        book.failed(key(9)) // a stranger's failure is nothing to the book
    }

    func testCandidatesAreABoundedDrawThatSkipsPeersAlreadyConnected() {
        var book = PeerBook()
        book.reached((1...10).map { endpoint(UInt8($0), host: "peer\($0).example") }, excluding: [], now: 1)
        var generator = SystemRandomNumberGenerator()
        let connected: Set<String> = [key(1), key(2)]
        let drawn = book.candidates(excluding: connected, count: 4, using: &generator)
        XCTAssertEqual(drawn.count, 4)
        XCTAssertEqual(Set(drawn.map(\.publicKey)).count, 4)
        XCTAssertTrue(connected.isDisjoint(with: drawn.map(\.publicKey)))
        XCTAssertEqual(book.candidates(excluding: [], count: 100, using: &generator).count, 10)
        XCTAssertTrue(book.candidates(excluding: [], count: 0, using: &generator).isEmpty)
        // Not always the same four: the order is not something a peer chooses.
        var seen: Set<String> = []
        for _ in 0..<50 { seen.formUnion(book.candidates(excluding: [], count: 2, using: &generator).map(\.publicKey)) }
        XCTAssertGreaterThan(seen.count, 2)
    }

    func testTheFileSurvivesARestartAndABadOneIsAnEmptyBookNotAFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-peers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(PeerMemory.fileName)

        let first = PeerMemory(directory: directory, excluding: [key(9)], now: 1_000)
        let empty = await first.isEmpty
        XCTAssertTrue(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing to remember writes nothing")
        for reached in [endpoint(1), endpoint(2), endpoint(9)] { await first.reached(reached, now: 1_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "written with the pass, not with each dial")
        await first.stillOpen([key(1), key(2), key(9)], now: 1_000)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        // A new process: the same peers, minus what has aged out since, and never an excluded one.
        let second = PeerMemory(directory: directory, excluding: [key(2)], now: 2_000)
        let remembered = await second.remembered
        XCTAssertEqual(Set(remembered), [endpoint(1), endpoint(2)])
        let offered = await second.candidates(excluding: [], count: 10)
        XCTAssertEqual(offered, [endpoint(1)], "a peer now configured is not also dialled from memory")
        let later = PeerMemory(directory: directory, excluding: [], now: 1_000 + PeerBook.horizon + 1)
        let stale = await later.isEmpty
        XCTAssertTrue(stale)

        // Garbage, a future format, entries that could not be dialled, or a file far too large.
        for contents in [
            Data("not json".utf8),
            Data(#"{"version":2,"peers":[]}"#.utf8),
            Data(#"{"version":1,"peers":[{"publicKey":"zz","host":"198.51.100.1","port":4001,"lastSeen":1,"failures":0}]}"#.utf8),
            Data(count: PeerMemory.maxFileBytes + 1),
        ] {
            try contents.write(to: file)
            let reopened = PeerMemory(directory: directory, excluding: [], now: 1_000)
            let nothing = await reopened.isEmpty
            XCTAssertTrue(nothing)
        }
    }

    /// End to end, three real runtimes over loopback: a node that has been on
    /// the network finds it again through a peer it remembers when its only
    /// bootstrap peer is gone, and a node told to connect to no one neither
    /// remembers nor redials anyone.
    func testANodeRejoinsThroughAPeerItRemembersWhenItsBootstrapPeerIsGone() async throws {
        func host(
            _ keyByte: String, directory: URL? = nil, peers: [PeerEndpoint], seeds: [PeerEndpoint] = []
        ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
            let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-remember-\(UUID().uuidString)", isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let port = NetworkTransportTestPorts.allocate()
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
                listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
                // A maintenance pass every second, where the book is kept.
                seedPeers: seeds, peerSearchInterval: 1
            )
            let overlay = IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: peers,
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
            return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
        }
        func start(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> NodeRuntime {
            try await NodeRuntime.start(
                storage: try await NodeStorage.open(configuration: configuration),
                configuration: configuration, overlay: overlay
            )
        }
        func sessions(_ runtime: NodeRuntime) async -> Set<String> {
            Set(await runtime.ivy.connectedPeers.map(\.publicKey))
        }

        let (seedConfiguration, seedOverlay, seedEndpoint) = try host("71", peers: [])
        let seed = try await start(seedConfiguration, seedOverlay)
        let (otherConfiguration, otherOverlay, otherEndpoint) = try host("72", peers: [seedEndpoint])
        let other = try await start(otherConfiguration, otherOverlay)
        addTeardownBlock { await other.stop() }

        // Each run of the node is a scope: its store is released when the
        // runtime goes, as a process exiting would release it.
        let (nodeConfiguration, nodeOverlay, _) = try host("73", peers: [seedEndpoint], seeds: [otherEndpoint])
        let book = nodeConfiguration.storagePath.appendingPathComponent(PeerMemory.fileName)
        func firstRun() async throws {
            // The node joins through its configured peer and, short of peers,
            // dials another itself: an address it reached, so one it keeps.
            let node = try await start(nodeConfiguration, nodeOverlay)
            // By identity: the address kept is the one the overlay accepted
            // for it, which the next run then has to be able to dial.
            try await eventually("the node remembers the peer it met") {
                await node.peerMemory?.remembered.map(\.publicKey) == [otherEndpoint.publicKey]
            }
            await node.stop()
        }
        try await firstRun()
        // On disk, and without its configured peer: that one is dialled anyway.
        let written = String(decoding: try Data(contentsOf: book), as: UTF8.self)
        XCTAssertTrue(written.contains(otherEndpoint.publicKey))
        XCTAssertFalse(written.contains(seedEndpoint.publicKey))
        // A bootstrap peer that is itself told to connect to no one remembers no one.
        let seedRemembers = seed.peerMemory == nil
        XCTAssertTrue(seedRemembers)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: seedConfiguration.storagePath.appendingPathComponent(PeerMemory.fileName).path
        ))

        // The node's only bootstrap peer stops too.
        await seed.stop()

        // Restarted with the same bootstrap list, which no longer answers, it
        // finds the network again through the peer it remembers.
        func secondRun() async throws {
            let (configuration, overlay, _) = try host("73", directory: nodeConfiguration.storagePath, peers: [seedEndpoint])
            let again = try await start(configuration, overlay)
            try await eventually("the restarted node is back in session with the remembered peer") {
                await sessions(again).contains(otherEndpoint.publicKey)
            }
            let seedGone = await sessions(again).contains(seedEndpoint.publicKey)
            XCTAssertFalse(seedGone)
            await again.stop()
        }
        try await secondRun()

        // The same store, started as a node that connects to no one: the book
        // is there, and it is not used.
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.path))
        let (aloneConfiguration, aloneOverlay, _) = try host("73", directory: nodeConfiguration.storagePath, peers: [])
        let alone = try await start(aloneConfiguration, aloneOverlay)
        let memory = alone.peerMemory == nil
        XCTAssertTrue(memory)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let dialled = await sessions(alone)
        XCTAssertTrue(dialled.isEmpty, "a node told to connect to no one dials no one it remembers")
        await alone.stop()
    }

    func testSeedsAreAskedOnlyWithFewerThanTwoPeers() {
        XCTAssertTrue(SeedPolicy.needsSeeds(peers: 0))
        XCTAssertTrue(SeedPolicy.needsSeeds(peers: 1))
        XCTAssertFalse(SeedPolicy.needsSeeds(peers: 2))
        XCTAssertFalse(SeedPolicy.needsSeeds(peers: 40))
    }

    /// End to end, real runtimes over loopback. A seed is an introduction:
    /// a new node meets the network through it, a node that already knows the
    /// network rejoins without asking one, and a node whose memory fails it
    /// falls back to one.
    func testANodeAsksASeedOnlyWhenWhatItRemembersIsNotEnough() async throws {
        func host(
            _ keyByte: String, directory: URL? = nil, seeds: [PeerEndpoint] = []
        ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
            let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-seeds-\(UUID().uuidString)", isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let port = NetworkTransportTestPorts.allocate()
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
                listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
                // As the daemon starts a node with no peers configured: none
                // for the overlay to dial itself, the seeds for when needed.
                seedPeers: seeds, peerSearchInterval: 1
            )
            // Every peer here is on loopback, one network group: the overlay's
            // per-group connection limit is lifted so that is not what is tested.
            let overlay = IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                maxConnectionsPerNetgroup: 64,
                mode: .overlay
            )
            return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
        }
        func start(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> NodeRuntime {
            try await NodeRuntime.start(
                storage: try await NodeStorage.open(configuration: configuration),
                configuration: configuration, overlay: overlay
            )
        }
        func sessions(_ runtime: NodeRuntime) async -> Set<String> {
            Set(await runtime.ivy.connectedPeers.map(\.publicKey))
        }
        // Four standing peers: the seed a new node is given, two ordinary
        // peers, and a second seed the node has never met.
        let (firstSeedConfiguration, firstSeedOverlay, firstSeed) = try host("81")
        let firstSeedRuntime = try await start(firstSeedConfiguration, firstSeedOverlay)
        let (oneConfiguration, oneOverlay, one) = try host("82")
        let oneRuntime = try await start(oneConfiguration, oneOverlay)
        let (twoConfiguration, twoOverlay, two) = try host("83")
        let twoRuntime = try await start(twoConfiguration, twoOverlay)
        let (otherSeedConfiguration, otherSeedOverlay, otherSeed) = try host("84")
        let otherSeedRuntime = try await start(otherSeedConfiguration, otherSeedOverlay)
        addTeardownBlock { await otherSeedRuntime.stop() }

        let (nodeConfiguration, nodeOverlay, _) = try host("85", seeds: [firstSeed, one, two])
        let store = nodeConfiguration.storagePath

        // A new node: nothing remembered, so it meets the network through its
        // seeds, with no one configured for the overlay to dial. It remembers
        // each address its dial reached: a seed is a peer like any other.
        func firstRun() async throws {
            let node = try await start(nodeConfiguration, nodeOverlay)
            try await eventually("a new node reaches its seeds") {
                await sessions(node) == [firstSeed.publicKey, one.publicKey, two.publicKey]
            }
            try await eventually("the node remembers the three peers it met") {
                Set(await node.peerMemory?.remembered.map(\.publicKey) ?? [])
                    == [firstSeed.publicKey, one.publicKey, two.publicKey]
            }
            await node.stop()
        }
        try await firstRun()

        // Restarted and offered a seed it has never met: it knows the
        // network, rejoins through the peers it remembers, and asks the seed
        // nothing.
        func secondRun() async throws {
            let (configuration, overlay, _) = try host("85", directory: store, seeds: [otherSeed])
            let node = try await start(configuration, overlay)
            try await eventually("the node rejoins through the peers it remembers") {
                await sessions(node).count >= SeedPolicy.peersBeforeSeeds
            }
            // Several maintenance passes later, still no word to the seed.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let asked = await sessions(node).contains(otherSeed.publicKey)
            XCTAssertFalse(asked, "a node that knows the network does not ask a seed")
            let seedSaw = await sessions(otherSeedRuntime).isEmpty
            XCTAssertTrue(seedSaw, "and the seed heard from no one")
            await node.stop()
        }
        try await secondRun()

        // Everyone it remembers is gone. Its memory cannot bring it back, so
        // now, and only now, it asks the seed.
        await firstSeedRuntime.stop()
        await oneRuntime.stop()
        await twoRuntime.stop()
        func thirdRun() async throws {
            let (configuration, overlay, _) = try host("85", directory: store, seeds: [otherSeed])
            let node = try await start(configuration, overlay)
            try await eventually("with no one it remembers answering, the node falls back to the seed") {
                await sessions(node).contains(otherSeed.publicKey)
            }
            await node.stop()
        }
        try await thirdRun()
    }

    /// End to end, real runtimes over loopback. Behind the seeds by name are
    /// the same kind of seed at a fixed address: asked only when the names
    /// leave the node short, which is what a DNS outage does.
    func testFixedAddressesAreAskedOnlyWhenTheNamedSeedsAreNotEnough() async throws {
        func host(
            _ keyByte: String, seeds: [PeerEndpoint] = [], fixed: [PeerEndpoint] = []
        ) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-fixed-\(UUID().uuidString)", isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let port = NetworkTransportTestPorts.allocate()
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
                listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
                seedPeers: seeds, fixedSeedPeers: fixed, peerSearchInterval: 1
            )
            let overlay = IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                maxConnectionsPerNetgroup: 64,
                mode: .overlay
            )
            return (configuration, overlay, PeerEndpoint(publicKey: configuration.processPublicKey, host: "127.0.0.1", port: port))
        }
        func start(_ configuration: NodeConfiguration, _ overlay: IvyConfig) async throws -> NodeRuntime {
            try await NodeRuntime.start(
                storage: try await NodeStorage.open(configuration: configuration),
                configuration: configuration, overlay: overlay
            )
        }
        func sessions(_ runtime: NodeRuntime) async -> Set<String> {
            Set(await runtime.ivy.connectedPeers.map(\.publicKey))
        }
        let (oneConfiguration, oneOverlay, one) = try host("91")
        let oneRuntime = try await start(oneConfiguration, oneOverlay)
        addTeardownBlock { await oneRuntime.stop() }
        let (twoConfiguration, twoOverlay, two) = try host("92")
        let twoRuntime = try await start(twoConfiguration, twoOverlay)
        addTeardownBlock { await twoRuntime.stop() }
        let (fixedConfiguration, fixedOverlay, fixed) = try host("93")
        let fixedRuntime = try await start(fixedConfiguration, fixedOverlay)
        addTeardownBlock { await fixedRuntime.stop() }

        // The names answer: two seeds are enough, and the fixed address hears nothing.
        let (namedConfiguration, namedOverlay, _) = try host("94", seeds: [one, two], fixed: [fixed])
        let named = try await start(namedConfiguration, namedOverlay)
        try await eventually("a new node reaches both named seeds") {
            await sessions(named) == [one.publicKey, two.publicKey]
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let unasked = await sessions(fixedRuntime).isEmpty
        XCTAssertTrue(unasked, "with enough peers by name, the fixed address is not asked")
        await named.stop()

        // The names cannot be resolved (`.invalid` never resolves): the same
        // identities are still reachable at their fixed addresses.
        let unresolvable = [one, two].map {
            PeerEndpoint(publicKey: $0.publicKey, host: "seed.invalid", port: $0.port)
        }
        let (outageConfiguration, outageOverlay, _) = try host("95", seeds: unresolvable, fixed: [one, two])
        let outage = try await start(outageConfiguration, outageOverlay)
        try await eventually("with its seeds' names unresolvable, a new node reaches them by address") {
            await sessions(outage) == [one.publicKey, two.publicKey]
        }
        await outage.stop()
    }
}
