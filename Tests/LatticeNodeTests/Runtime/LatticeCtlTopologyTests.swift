import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import LatticeCtlCore
import LatticeNode
@testable import LatticeNodeDaemon

final class LatticeCtlTopologyTests: XCTestCase {
    private func chain(
        _ base: UInt16
    ) -> TopologyChain {
        TopologyChain(listen: base, rpc: base + 2)
    }

    func testValidationRequiresNexusRootedAbsolutePaths() {
        XCTAssertThrowsError(try Topology(
            chains: ["Payments": chain(4001)]
        ).validated())
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus/": chain(4001)]
        ).validated())
        XCTAssertNoThrow(try Topology(
            chains: ["Nexus": chain(4001)]
        ).validated())
    }

    /// The node hosts only Nexus: a child chain in the tree is refused.
    func testValidationRefusesChildChains() {
        XCTAssertThrowsError(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments": chain(4101),
        ]).validated())
    }

    /// Round-deadline headroom belongs to the operator, and a bad value is a
    /// NAMED refusal rather than a precondition trap: it arrives from an
    /// operator-edited file, so a typo must not crash the process.
    func testRoundDeadlineMultiplierIsOperatorSettableAndRefusesZero() throws {
        let validated = try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus", roundDeadlineMultiplier: 3)
        ).validated()
        XCTAssertEqual(validated.mine?.roundDeadlineMultiplier, 3)

        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus", roundDeadlineMultiplier: 0)
        ).validated())

        // Negative reaches the NAMED refusal now that the field is Int: as
        // UInt64 it surfaced as a raw Codable error at load instead.
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus", roundDeadlineMultiplier: -1)
        ).validated())

        let absent = try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus")
        ).validated()
        XCTAssertNil(absent.mine?.roundDeadlineMultiplier)
    }

    func testValidationRejectsPortCollisions() {
        var colliding = chain(4001)
        colliding.rpc = colliding.listen
        XCTAssertThrowsError(try Topology(chains: ["Nexus": colliding]).validated())
    }

    func testPublicReadPortRoundTripsAndJoinsPortCollisionCheck() throws {
        // Round-trips through lattice.json; absent stays nil (existing hosts
        // are unaffected).
        var withRead = chain(4001)
        withRead.publicRead = 8081
        let encoded = try JSONEncoder().encode(Topology(chains: ["Nexus": withRead]))
        let decoded = try JSONDecoder().decode(Topology.self, from: encoded)
        XCTAssertEqual(decoded.chains["Nexus"]?.publicRead, 8081)
        XCTAssertNoThrow(try decoded.validated())

        let legacy = try JSONDecoder().decode(
            Topology.self,
            from: JSONEncoder().encode(Topology(chains: ["Nexus": chain(4001)]))
        )
        XCTAssertNil(legacy.chains["Nexus"]?.publicRead)
        XCTAssertNil(legacy.chains["Nexus"]?.externalAddress)

        var described = chain(4001)
        described.externalAddress = "node.example.org"
        let redecoded = try JSONDecoder().decode(
            Topology.self,
            from: JSONEncoder().encode(Topology(chains: ["Nexus": described]))
        )
        XCTAssertEqual(redecoded.chains["Nexus"]?.externalAddress, "node.example.org")

        // The public read port participates in the uniqueness check.
        var colliding = chain(4001)
        colliding.publicRead = colliding.listen
        XCTAssertThrowsError(try Topology(chains: ["Nexus": colliding]).validated())
    }

    func testValidationRejectsMiningUnknownChain() {
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus/Payments")
        ).validated())
    }

    func testRoundTripThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let topology = Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(
                chain: "Nexus", worker: "cpu", workers: 2,
                batchSize: 1_000, recipients: ["Nexus": "addr-nexus"],
                minWork: ["Nexus": "2^32"]
            )
        )
        try topology.save(root: root)
        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.chains["Nexus"]?.listen, 4001)
        XCTAssertEqual(loaded.mine?.batchSize, 1_000)
        XCTAssertEqual(loaded.mine?.minWork, ["Nexus": "2^32"])
        XCTAssertEqual(loaded.mine?.recipients, ["Nexus": "addr-nexus"])
        XCTAssertEqual(
            loaded.mine?.coordinatorRecipientArguments,
            ["--recipient", "Nexus=addr-nexus"]
        )
        // The pre-signed reward batch is gone: an old tree fails loudly
        // instead of silently mining to no one.
        XCTAssertThrowsError(try JSONDecoder().decode(
            TopologyMine.self,
            from: Data(#"{"chain":"Nexus","rewards":"rewards.jsonl"}"#.utf8)
        ))
        // Blocks always commit the schedule; the filter is a search plan.
        let legacy = try JSONDecoder().decode(
            TopologyMine.self,
            from: Data(#"{"chain":"Nexus","minWork":{"Nexus":"2^32"}}"#.utf8)
        )
        XCTAssertEqual(
            legacy.coordinatorMinimumWorkArguments,
            ["--min-work", "Nexus=2^32"]
        )
    }

    /// `mine.minWork` reaches the coordinator as a search plan. There is no
    /// companion setting that commits it: a miner's filter shapes that miner's
    /// search and never the blocks it produces.
    func testMinimumWorkPassesThroughAsASearchPlan() throws {
        let mine = TopologyMine(
            chain: "Nexus",
            minWork: ["Nexus/Payments": "2^20", "Nexus": "2^32"]
        )
        let topology = Topology(chains: ["Nexus": chain(4001)], mine: mine)
        XCTAssertEqual(
            try topology.validated().mine?.coordinatorMinimumWorkArguments,
            [
                "--min-work", "Nexus=2^32",
                "--min-work", "Nexus/Payments=2^20",
            ],
            "the plan crosses, and nothing that would commit it"
        )
    }

    /// The cadence is a FLOOR on block spacing, not a fixed block time. A
    /// round that already outran it waits not at all, so the pacing stops
    /// binding by itself once the schedule alone is slower — which is the
    /// whole reason it can be switched on without a second step to switch it
    /// off. A hold that kept growing with the round would instead pin block
    /// time forever and leave the retarget with no feedback, the very failure
    /// `minWork` has.
    func testPacingIsAFloorThatReleasesItself() {
        let paced = TopologyMine(chain: "Nexus", minBlockIntervalSeconds: 600)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .zero), .seconds(600))
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(100)), .seconds(500))
        // Exactly at the cadence, and past it: no wait, and never negative.
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(600)), .zero)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(9_000)), .zero)
        // Unset means unpaced: blocks go out as fast as they solve.
        XCTAssertEqual(
            TopologyMine(chain: "Nexus").pacingHold(afterRoundOf: .zero), .zero
        )
    }

    /// The cadence has to survive a round-trip through `lattice.json`, and an
    /// older file that predates it must still load.
    func testPacingRoundTripsAndIsOptional() throws {
        let encoded = try JSONEncoder().encode(
            TopologyMine(chain: "Nexus", minBlockIntervalSeconds: 3_300)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(TopologyMine.self, from: encoded)
                .minBlockIntervalSeconds,
            3_300
        )
        XCTAssertNil(
            try JSONDecoder().decode(
                TopologyMine.self, from: Data(#"{"chain":"Nexus"}"#.utf8)
            ).minBlockIntervalSeconds
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TopologyMine.self,
                from: Data(#"{"chain":"Nexus","minBlockIntervalSeconds":600}"#.utf8)
            ).minBlockIntervalSeconds,
            600
        )
    }

    /// Pacing is spacing, not work: it must not reach the coordinator, whose
    /// `--min-work` fixes work per block and is what breaks retarget feedback.
    /// Set alongside a real `minWork` so the assertion can only pass by the
    /// cadence being absent — with `minWork` nil the argument list is empty by
    /// construction and the test would prove nothing.
    func testPacingIsNotACoordinatorArgument() {
        XCTAssertEqual(
            TopologyMine(
                chain: "Nexus",
                minWork: ["Nexus": "2^40"],
                minBlockIntervalSeconds: 600
            ).coordinatorMinimumWorkArguments,
            ["--min-work", "Nexus=2^40"]
        )
    }

    /// The compiled-in 15s that wedged #153 is now an operator setting. It has
    /// to survive `lattice.json`, default when absent so existing files keep
    /// working, and refuse a value that would recreate the wedge.
    func testTemplateTimeoutIsOperatorSettable() throws {
        XCTAssertEqual(
            TopologyMine(chain: "Nexus").resolvedTemplateTimeoutSeconds,
            TopologyMine.defaultTemplateTimeoutSeconds
        )
        XCTAssertEqual(
            TopologyMine(chain: "Nexus", templateTimeoutSeconds: 180)
                .resolvedTemplateTimeoutSeconds,
            180
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TopologyMine.self,
                from: Data(#"{"chain":"Nexus","templateTimeoutSeconds":180}"#.utf8)
            ).resolvedTemplateTimeoutSeconds,
            180
        )
        // A file written before this setting existed must still load.
        XCTAssertNil(
            try JSONDecoder().decode(
                TopologyMine.self, from: Data(#"{"chain":"Nexus"}"#.utf8)
            ).templateTimeoutSeconds
        )
        // Zero can never observe an expiry, so it is the wedge by another name.
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus", templateTimeoutSeconds: 0)
        ).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "mine.templateTimeoutSeconds must be at least 1; a zero timeout can never observe a template expiry, so no round deadline could be derived and the miner would never mine"
            )
        }
    }

    /// `HTTPMiningCoordinatorNodeClient.fetchWork()` sets no `timeoutInterval`,
    /// so a round actually runs under the `URLRequest` default. A probe that
    /// tolerated MORE than that would observe an expiry for rounds that then
    /// die fetching the same template, reporting `nodeFailed` and pointing an
    /// operator at the worker instead of at template build time.
    ///
    /// Compared against the live `URLRequest` default rather than a literal,
    /// which would merely restate the constant it tests.
    ///
    /// What this pins is our constants against the framework default — it
    /// catches raising either of them, and a platform whose default is lower.
    /// It CANNOT see a `timeoutInterval` that `fetchWork()` sets of its own:
    /// this target does not depend on LatticeMiningCoordinator, so a fresh
    /// `URLRequest` still reports the framework value and this stays green.
    /// Pinning that properly needs the coordinator's timeout to become an
    /// explicit named constant first — #156.
    func testTemplateTimeoutCeilingDoesNotExceedTheCoordinatorsOwnLimit() {
        let coordinatorLimit = URLRequest(
            url: URL(string: "http://127.0.0.1:8080/mining/templates")!
        ).timeoutInterval
        XCTAssertLessThanOrEqual(
            TimeInterval(TopologyMine.maximumTemplateTimeoutSeconds),
            coordinatorLimit
        )
        XCTAssertLessThanOrEqual(
            TimeInterval(TopologyMine.defaultTemplateTimeoutSeconds),
            coordinatorLimit
        )
    }

    /// Above the coordinator's own limit there is no legal value: every round
    /// would die inside `fetchWork` regardless of what the probe observed. The
    /// docs said so; refusing it means an operator cannot write it down.
    func testTemplateTimeoutAboveTheCoordinatorsLimitIsRefused() {
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(
                chain: "Nexus",
                templateTimeoutSeconds:
                    TopologyMine.maximumTemplateTimeoutSeconds + 1
            )
        ).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "mine.templateTimeoutSeconds must be at most \(TopologyMine.maximumTemplateTimeoutSeconds); the coordinator's own template fetch is fixed at that, so a longer probe would observe expiries for rounds that then die fetching the same template"
            )
        }
        // The ceiling itself is legal.
        XCTAssertNoThrow(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(
                chain: "Nexus",
                templateTimeoutSeconds:
                    TopologyMine.maximumTemplateTimeoutSeconds
            )
        ).validated())
    }

    func testLayoutSeparatesIdentityFromWipeableChains() {
        let layout = HostLayout(root: "/var/lib/lattice")
        XCTAssertTrue(layout.identityKey(for: "Nexus/Payments").path
            .hasSuffix("identity/Nexus%2FPayments.key"))
        XCTAssertNotEqual(
            layout.identityKey(for: "Nexus/A/B"),
            layout.identityKey(for: "Nexus/A-B"),
            "two levels of one host must never share a key"
        )
        XCTAssertTrue(layout.chainDirectory(for: "Nexus/Payments").path
            .hasSuffix("chains/Nexus/Payments"))
        XCTAssertFalse(layout.identityKey(for: "Nexus").path
            .contains("/chains/"))
    }

    /// A stop removes the pidfile only while it names the pid the stop
    /// signalled: a daemon a restart spawned meanwhile keeps its pidfile.
    func testAStopLeavesAPidFileNamingAnotherPid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostLayout(root: root.path)
        let url = layout.pidFile(for: "lattice-node")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("4243 lattice-node".utf8).write(to: url)
        layout.removePidFile(for: "lattice-node", ifNaming: 4242)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        layout.removePidFile(for: "lattice-node", ifNaming: 4243)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacyIdentityKeysMigrateUnlessAmbiguous() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostLayout(root: root.path)
        let identity = root.appendingPathComponent("identity")
        try FileManager.default.createDirectory(
            at: identity, withIntermediateDirectories: true
        )
        try Data("key".utf8).write(to: identity.appendingPathComponent("Nexus-Payments.key"))
        try layout.migrateIdentityKeys(for: ["Nexus", "Nexus/Payments"])
        XCTAssertEqual(
            try Data(contentsOf: layout.identityKey(for: "Nexus/Payments")),
            Data("key".utf8)
        )

        try Data("key".utf8).write(to: identity.appendingPathComponent("Nexus-A-B.key"))
        XCTAssertThrowsError(
            try layout.migrateIdentityKeys(for: ["Nexus", "Nexus/A", "Nexus/A/B", "Nexus/A-B"])
        ) { error in
            XCTAssertEqual(
                error as? HostLayoutError,
                .ambiguousLegacyIdentityKey(
                    file: identity.appendingPathComponent("Nexus-A-B.key").path,
                    paths: ["Nexus/A-B", "Nexus/A/B"]
                )
            )
        }
    }
}
