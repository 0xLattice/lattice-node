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

    private static let nexus = ["Nexus"]
    private static let alpha = ["Nexus", "Alpha"]

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-peers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testTheFileSurvivesARestartAndABadOneIsAnEmptyBookNotAFailure() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent(PeerMemory.fileName)
        let nexus = Self.nexus

        let first = PeerMemory(directory: directory, chains: [nexus], excluding: [key(9)], now: 1_000)
        let empty = await first.remembered(for: nexus).isEmpty
        XCTAssertTrue(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing to remember writes nothing")
        for reached in [endpoint(1), endpoint(2), endpoint(9)] { await first.reached(reached, chains: [nexus], now: 1_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "written with the pass, not with each dial")
        await first.stillOpen(byChain: [nexus: [key(1), key(2), key(9)]], now: 1_000)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        // A new process: the same peers, minus what has aged out since, and never an excluded one.
        let second = PeerMemory(directory: directory, chains: [nexus], excluding: [key(2)], now: 2_000)
        let remembered = await second.remembered(for: nexus)
        XCTAssertEqual(Set(remembered), [endpoint(1), endpoint(2)])
        let offered = await second.candidates(for: nexus, excluding: [], count: 10)
        XCTAssertEqual(offered, [endpoint(1)], "a peer now configured is not also dialled from memory")
        let later = PeerMemory(directory: directory, chains: [nexus], excluding: [], now: 1_000 + PeerBook.horizon + 1)
        let stale = await later.remembered(for: nexus).isEmpty
        XCTAssertTrue(stale)

        // Garbage, a future format, entries that could not be dialled, or a file far too large.
        for contents in [
            Data("not json".utf8),
            Data(#"{"version":3,"chains":{}}"#.utf8),
            Data(#"{"version":2,"peers":[]}"#.utf8),
            Data(#"{"version":1,"peers":[{"publicKey":"zz","host":"198.51.100.1","port":4001,"lastSeen":1,"failures":0}]}"#.utf8),
            Data(count: PeerMemory.maxFileBytes + 1),
        ] {
            try contents.write(to: file)
            let reopened = PeerMemory(directory: directory, chains: [nexus], excluding: [], now: 1_000)
            let nothing = await reopened.remembered(for: nexus).isEmpty
            XCTAssertTrue(nothing)
        }
    }

    /// Every hosted chain has a book of its own, under the same limits. A
    /// peer is in the book of each chain it said it hosts, and only once a
    /// dial of this node reached it.
    func testEachChainHasItsOwnBookUnderTheSameLimits() async throws {
        let directory = try scratch()
        let (nexus, alpha) = (Self.nexus, Self.alpha)
        let memory = PeerMemory(directory: directory, chains: [nexus, alpha], excluding: [], now: 1_000)

        // Reached for Nexus alone: Alpha's book is not touched.
        await memory.reached(endpoint(1), chains: [nexus], now: 1_000)
        // Reached for Alpha: it hosts Alpha and so Nexus.
        await memory.reached(endpoint(2), chains: [nexus, alpha], now: 1_000)
        var inAlpha = await memory.remembered(for: alpha)
        XCTAssertEqual(inAlpha, [endpoint(2)])
        var inNexus = await memory.remembered(for: nexus)
        XCTAssertEqual(Set(inNexus), [endpoint(1), endpoint(2)])

        // Peer 1's session then says it hosts Alpha: the address this node
        // dialled enters Alpha's book. Peer 3 says so too, but connected to
        // us: no address of ours reached it, so no book holds it.
        await memory.stillOpen(byChain: [nexus: [key(1), key(2), key(3)], alpha: [key(1), key(2), key(3)]], now: 2_000)
        inAlpha = await memory.remembered(for: alpha)
        XCTAssertEqual(Set(inAlpha), [endpoint(1), endpoint(2)])
        inNexus = await memory.remembered(for: nexus)
        XCTAssertEqual(Set(inNexus), [endpoint(1), endpoint(2)])

        // Candidates are drawn from the chain's own book.
        await memory.reached(endpoint(4), chains: [nexus], now: 2_000)
        let forAlpha = await memory.candidates(for: alpha, excluding: [key(1)], count: 10)
        XCTAssertEqual(forAlpha, [endpoint(2)])
        let forUnhosted = await memory.candidates(for: ["Nexus", "Beta"], excluding: [], count: 10)
        XCTAssertTrue(forUnhosted.isEmpty)

        // The limits count per chain: one network group fills its share of
        // each book, not one share between them.
        for index in 0..<(PeerBook.capacityPerGroup + 4) {
            await memory.reached(
                endpoint(UInt8(100 + index), host: "203.0.113.\(index + 1)"), chains: [nexus, alpha], now: 3_000
            )
        }
        await memory.stillOpen(byChain: [:], now: 3_000)
        for chain in [nexus, alpha] {
            let group = await memory.remembered(for: chain).filter { $0.host.hasPrefix("203.0.") }
            XCTAssertEqual(group.count, PeerBook.capacityPerGroup, "\(chain)")
        }
    }

    /// A dial that fails counts against the peer in every book holding it.
    func testAFailedDialCountsInEveryBookHoldingThePeer() async throws {
        let (nexus, alpha) = (Self.nexus, Self.alpha)
        let memory = PeerMemory(directory: try scratch(), chains: [nexus, alpha], excluding: [], now: 1_000)
        await memory.reached(endpoint(1), chains: [nexus, alpha], now: 1_000)
        await memory.reached(endpoint(2), chains: [nexus], now: 1_000)
        for _ in 0..<PeerBook.maxFailures { await memory.failed(key(1)) }
        let inNexus = await memory.remembered(for: nexus)
        XCTAssertEqual(inNexus, [endpoint(2)])
        let inAlpha = await memory.remembered(for: alpha)
        XCTAssertTrue(inAlpha.isEmpty)
    }

    /// A peer that is connected and no longer serves a chain is not refreshed
    /// in that chain's book, and ages out of it; it is never struck from it
    /// for not saying so, since a peer on an older build says nothing.
    func testAPeerThatStoppedHostingAChainAgesOutOfThatChainsBook() async throws {
        let (nexus, alpha) = (Self.nexus, Self.alpha)
        let memory = PeerMemory(directory: try scratch(), chains: [nexus, alpha], excluding: [], now: 1_000)
        await memory.reached(endpoint(1), chains: [nexus, alpha], now: 1_000)
        await memory.reached(endpoint(2), chains: [nexus, alpha], now: 1_000)
        // Peer 1 is open and serves only Nexus; peer 2 still serves Alpha.
        for _ in 0..<(PeerBook.maxFailures * 2) {
            await memory.stillOpen(byChain: [nexus: [key(1), key(2)], alpha: [key(2)]], now: 2_000)
        }
        var inAlpha = await memory.remembered(for: alpha)
        XCTAssertEqual(Set(inAlpha), [endpoint(1), endpoint(2)])
        let later = 1_000 + PeerBook.horizon + 1
        await memory.stillOpen(byChain: [nexus: [key(1), key(2)], alpha: [key(2)]], now: later)
        inAlpha = await memory.remembered(for: alpha)
        XCTAssertEqual(inAlpha, [endpoint(2)])
        let inNexus = await memory.remembered(for: nexus)
        XCTAssertEqual(Set(inNexus), [endpoint(1), endpoint(2)])
    }

    /// The file holds a book per chain. One written before chains had their
    /// own is Nexus's book, and a book for a chain no longer hosted is dropped.
    func testTheFileHoldsABookPerChainAndAnOlderFileIsTheNexusBook() async throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent(PeerMemory.fileName)
        let (nexus, alpha) = (Self.nexus, Self.alpha)

        let entry = #"{"publicKey":"\#(key(1))","host":"198.51.1.7","port":4001,"lastSeen":1000,"failures":0}"#
        try Data(#"{"version":1,"peers":[\#(entry)]}"#.utf8).write(to: file)
        let upgraded = PeerMemory(directory: directory, chains: [nexus, alpha], excluding: [], now: 1_000)
        var inNexus = await upgraded.remembered(for: nexus)
        XCTAssertEqual(inNexus, [endpoint(1)])
        var inAlpha = await upgraded.remembered(for: alpha)
        XCTAssertTrue(inAlpha.isEmpty)

        await upgraded.reached(endpoint(2), chains: [nexus, alpha], now: 2_000)
        await upgraded.stillOpen(byChain: [nexus: [key(2)], alpha: [key(2)]], now: 2_000)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["version"] as? Int, 2)
        let chains = try XCTUnwrap(written["chains"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(chains.keys), ["Nexus", "Nexus/Alpha"])
        XCTAssertEqual(chains["Nexus"]?.count, 2)
        XCTAssertEqual(chains["Nexus/Alpha"]?.compactMap { $0["publicKey"] as? String }, [key(2)])

        // Restarted hosting both: each book as it was.
        let again = PeerMemory(directory: directory, chains: [nexus, alpha], excluding: [], now: 3_000)
        inAlpha = await again.remembered(for: alpha)
        XCTAssertEqual(inAlpha, [endpoint(2)])
        // Restarted without Alpha: its book is gone, at once and on disk.
        let without = PeerMemory(directory: directory, chains: [nexus], excluding: [], now: 3_000)
        inAlpha = await without.remembered(for: alpha)
        XCTAssertTrue(inAlpha.isEmpty)
        await without.reached(endpoint(3), chains: [nexus], now: 3_000)
        await without.stillOpen(byChain: [nexus: [key(3)]], now: 3_000)
        let back = PeerMemory(directory: directory, chains: [nexus, alpha], excluding: [], now: 4_000)
        inAlpha = await back.remembered(for: alpha)
        XCTAssertTrue(inAlpha.isEmpty)
        inNexus = await back.remembered(for: nexus)
        XCTAssertEqual(Set(inNexus), [endpoint(1), endpoint(2), endpoint(3)])
    }

    /// End to end, three real runtimes over loopback: a node that has been on
    /// the network finds it again through a peer it remembers when its only
    /// bootstrap peer is gone, and a node told to connect to no one neither
    /// remembers nor redials anyone.
    func testANodeRejoinsThroughAPeerItRemembersWhenItsBootstrapPeerIsGone() async throws {
        let (seedConfiguration, seedOverlay, seedEndpoint) = try loopbackHost("71", peers: [])
        let seed = try await startLoopbackHost(seedConfiguration, seedOverlay)
        let (otherConfiguration, otherOverlay, otherEndpoint) = try loopbackHost("72", peers: [seedEndpoint])
        let other = try await startLoopbackHost(otherConfiguration, otherOverlay)
        addTeardownBlock { await other.stop() }

        // Each run of the node is a scope: its store is released when the
        // runtime goes, as a process exiting would release it.
        let (nodeConfiguration, nodeOverlay, _) = try loopbackHost("73", peers: [seedEndpoint], seeds: [otherEndpoint])
        let book = nodeConfiguration.storagePath.appendingPathComponent(PeerMemory.fileName)
        func firstRun() async throws {
            // The node joins through its configured peer and, short of peers,
            // dials another itself: an address it reached, so one it keeps.
            let node = try await startLoopbackHost(nodeConfiguration, nodeOverlay)
            // By identity: the address kept is the one the overlay accepted
            // for it, which the next run then has to be able to dial.
            try await eventually("the node remembers the peer it met") {
                await node.peerMemory?.remembered(for: ["Nexus"]).map(\.publicKey) == [otherEndpoint.publicKey]
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
            let (configuration, overlay, _) = try loopbackHost("73", directory: nodeConfiguration.storagePath, peers: [seedEndpoint])
            let again = try await startLoopbackHost(configuration, overlay)
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
        let (aloneConfiguration, aloneOverlay, _) = try loopbackHost("73", directory: nodeConfiguration.storagePath, peers: [])
        let alone = try await startLoopbackHost(aloneConfiguration, aloneOverlay)
        let memory = alone.peerMemory == nil
        XCTAssertTrue(memory)
        try await alwaysDuring("a node told to connect to no one dials no one it remembers", .milliseconds(2_500)) {
            await sessions(alone).isEmpty
        }
        await alone.stop()
    }

    /// End to end, real runtimes over loopback. A seed is an introduction:
    /// a new node meets the network through it, a node that already knows the
    /// network rejoins without asking one, and a node whose memory fails it
    /// falls back to one.
    func testANodeAsksASeedOnlyWhenWhatItRemembersIsNotEnough() async throws {
        // Four standing peers: the seed a new node is given, two ordinary
        // peers, and a second seed the node has never met.
        let (firstSeedConfiguration, firstSeedOverlay, firstSeed) = try loopbackHost("81")
        let firstSeedRuntime = try await startLoopbackHost(firstSeedConfiguration, firstSeedOverlay)
        let (oneConfiguration, oneOverlay, one) = try loopbackHost("82")
        let oneRuntime = try await startLoopbackHost(oneConfiguration, oneOverlay)
        let (twoConfiguration, twoOverlay, two) = try loopbackHost("83")
        let twoRuntime = try await startLoopbackHost(twoConfiguration, twoOverlay)
        let (otherSeedConfiguration, otherSeedOverlay, otherSeed) = try loopbackHost("84")
        let otherSeedRuntime = try await startLoopbackHost(otherSeedConfiguration, otherSeedOverlay)
        addTeardownBlock { await otherSeedRuntime.stop() }

        let (nodeConfiguration, nodeOverlay, _) = try loopbackHost("85", seeds: [firstSeed, one, two])
        let store = nodeConfiguration.storagePath

        // A new node: nothing remembered, so it meets the network through its
        // seeds, with no one configured for the overlay to dial. It remembers
        // each address its dial reached: a seed is a peer like any other.
        func firstRun() async throws {
            let node = try await startLoopbackHost(nodeConfiguration, nodeOverlay)
            try await eventually("a new node reaches its seeds") {
                await sessions(node) == [firstSeed.publicKey, one.publicKey, two.publicKey]
            }
            try await eventually("the node remembers the three peers it met") {
                Set(await node.peerMemory?.remembered(for: ["Nexus"]).map(\.publicKey) ?? [])
                    == [firstSeed.publicKey, one.publicKey, two.publicKey]
            }
            await node.stop()
        }
        try await firstRun()

        // Restarted and offered a seed it has never met: it knows the
        // network, rejoins through the peers it remembers, and asks the seed
        // nothing.
        func secondRun() async throws {
            let (configuration, overlay, _) = try loopbackHost("85", directory: store, seeds: [otherSeed])
            let node = try await startLoopbackHost(configuration, overlay)
            try await eventually("the node rejoins through the peers it remembers") {
                await sessions(node).count >= SeedPolicy.peersBeforeSeeds
            }
            // Through several maintenance passes, no word to the seed.
            try await alwaysDuring("a node that knows the network does not ask a seed", .seconds(3)) {
                let asked = await sessions(node).contains(otherSeed.publicKey)
                let heard = await !sessions(otherSeedRuntime).isEmpty
                return !asked && !heard
            }
            await node.stop()
        }
        try await secondRun()

        // Everyone it remembers is gone. Its memory cannot bring it back, so
        // now, and only now, it asks the seed.
        await firstSeedRuntime.stop()
        await oneRuntime.stop()
        await twoRuntime.stop()
        func thirdRun() async throws {
            let (configuration, overlay, _) = try loopbackHost("85", directory: store, seeds: [otherSeed])
            let node = try await startLoopbackHost(configuration, overlay)
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
        let (oneConfiguration, oneOverlay, one) = try loopbackHost("91")
        let oneRuntime = try await startLoopbackHost(oneConfiguration, oneOverlay)
        addTeardownBlock { await oneRuntime.stop() }
        let (twoConfiguration, twoOverlay, two) = try loopbackHost("92")
        let twoRuntime = try await startLoopbackHost(twoConfiguration, twoOverlay)
        addTeardownBlock { await twoRuntime.stop() }
        let (fixedConfiguration, fixedOverlay, fixed) = try loopbackHost("93")
        let fixedRuntime = try await startLoopbackHost(fixedConfiguration, fixedOverlay)
        addTeardownBlock { await fixedRuntime.stop() }

        // The names answer: two seeds are enough, and the fixed address hears nothing.
        let (namedConfiguration, namedOverlay, _) = try loopbackHost("94", seeds: [one, two], fixed: [fixed])
        let named = try await startLoopbackHost(namedConfiguration, namedOverlay)
        try await eventually("a new node reaches both named seeds") {
            await sessions(named) == [one.publicKey, two.publicKey]
        }
        try await alwaysDuring("with enough peers by name, the fixed address is not asked", .seconds(3)) {
            await sessions(fixedRuntime).isEmpty
        }
        await named.stop()

        // The names cannot be resolved (`.invalid` never resolves): the same
        // identities are still reachable at their fixed addresses.
        let unresolvable = [one, two].map {
            PeerEndpoint(publicKey: $0.publicKey, host: "seed.invalid", port: $0.port)
        }
        let (outageConfiguration, outageOverlay, _) = try loopbackHost("95", seeds: unresolvable, fixed: [one, two])
        let outage = try await startLoopbackHost(outageConfiguration, outageOverlay)
        try await eventually("with its seeds' names unresolvable, a new node reaches them by address") {
            await sessions(outage) == [one.publicKey, two.publicKey]
        }
        await outage.stop()
    }
}
