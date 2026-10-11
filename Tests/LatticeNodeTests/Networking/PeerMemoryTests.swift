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
        book.saw([endpoint(1), endpoint(2), endpoint(3)], excluding: [key(3)], now: 1_000)
        XCTAssertEqual(Set(book.entries.keys), [key(1), key(2)])
        // Seen again, perhaps somewhere else: one address per identity, the latest.
        book.saw([endpoint(1, host: "203.0.113.9", port: 5001)], excluding: [], now: 2_000)
        XCTAssertEqual(book.entries[key(1)]?.endpoint, endpoint(1, host: "203.0.113.9", port: 5001))
        XCTAssertEqual(book.entries[key(1)]?.lastSeen, 2_000)
        XCTAssertEqual(book.entries.count, 2)
    }

    func testAnAddressThatCouldNotBeDialledIsNotRemembered() {
        var book = PeerBook()
        book.saw([
            PeerEndpoint(publicKey: "not a key", host: "198.51.100.1", port: 4001),
            PeerEndpoint(publicKey: key(1), host: "", port: 4001),
            PeerEndpoint(publicKey: key(2), host: "unknown", port: 4001),
            PeerEndpoint(publicKey: key(3), host: "198.51.100.3", port: 0),
            PeerEndpoint(publicKey: key(4), host: "host with space", port: 4001),
            PeerEndpoint(publicKey: key(5), host: String(repeating: "a", count: 254), port: 4001),
        ], excluding: [], now: 1)
        XCTAssertTrue(book.entries.isEmpty)
    }

    func testAPeerNotSeenWithinTheHorizonIsForgotten() {
        var book = PeerBook()
        book.saw([endpoint(1)], excluding: [], now: 0)
        book.saw([endpoint(2)], excluding: [], now: PeerBook.horizon)
        XCTAssertEqual(Set(book.entries.keys), [key(1), key(2)], "exactly at the horizon it is still remembered")
        book.prune(now: PeerBook.horizon + 1)
        XCTAssertEqual(Set(book.entries.keys), [key(2)])
    }

    func testOneNetworkCannotBecomeTheWholeMemory() {
        var book = PeerBook()
        // Twenty peers in one /16, seen in order; one elsewhere, seen first.
        book.saw([endpoint(200, host: "203.0.113.1")], excluding: [], now: 1)
        for index in UInt8(1)...20 {
            book.saw([endpoint(index, host: "198.51.100.\(index)")], excluding: [], now: Int64(10 + index))
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
            book.saw(
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
        book.saw([endpoint(1), endpoint(2)], excluding: [], now: 1)
        for _ in 1..<PeerBook.maxFailures { book.failed(key(1)); book.failed(key(2)) }
        XCTAssertEqual(book.entries.count, 2)
        // Seen again: its failures are behind it.
        book.saw([endpoint(2)], excluding: [], now: 2)
        book.failed(key(1))
        book.failed(key(2))
        XCTAssertEqual(Set(book.entries.keys), [key(2)])
        book.failed(key(9)) // a stranger's failure is nothing to the book
    }

    func testCandidatesAreABoundedDrawThatSkipsPeersAlreadyConnected() {
        var book = PeerBook()
        book.saw((1...10).map { endpoint(UInt8($0), host: "peer\($0).example") }, excluding: [], now: 1)
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
        await first.saw([endpoint(1), endpoint(2), endpoint(9)], now: 1_000)
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
        func host(_ keyByte: String, directory: URL? = nil, peers: [PeerEndpoint]) throws -> (NodeConfiguration, IvyConfig, PeerEndpoint) {
            let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "lattice-remember-\(UUID().uuidString)", isDirectory: true
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let port = NetworkTransportTestPorts.allocate()
            let configuration = try NodeConfiguration(
                chainPath: ["Nexus"], storagePath: directory, privateKeyHex: String(repeating: keyByte, count: 32),
                listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
                // A maintenance pass every second, where the book is kept.
                peerSearchInterval: 1
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
        let (nodeConfiguration, nodeOverlay, _) = try host("73", peers: [seedEndpoint])
        let book = nodeConfiguration.storagePath.appendingPathComponent(PeerMemory.fileName)
        func firstRun() async throws {
            // The node joins through its bootstrap peer and, as discovery
            // would have it do, comes to hold a session with another peer too.
            let node = try await start(nodeConfiguration, nodeOverlay)
            try await node.ivy.connect(to: otherEndpoint)
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
}
