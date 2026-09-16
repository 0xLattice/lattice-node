import XCTest
import LatticeCtlCore

final class LatticeCtlTopologyTests: XCTestCase {
    private func chain(
        _ base: UInt16
    ) -> TopologyChain {
        TopologyChain(listen: base, fact: base + 1, rpc: base + 2)
    }

    /// A pending deploy is keyed by chain path, and `-` is a legal directory
    /// atom: flattening `/` to `-` would let `Nexus/A/B` and `Nexus/A-B` share
    /// one file, so one deploy's genesis seed could overwrite the other's.
    func testPendingDeployPathsDoNotCollide() {
        let layout = HostLayout(root: "/tmp/lattice-collision")
        XCTAssertNotEqual(
            layout.pendingDeploy(for: "Nexus/A/B"),
            layout.pendingDeploy(for: "Nexus/A-B")
        )
        // The name operators are told to look for in docs/operator-cli.md.
        XCTAssertEqual(
            layout.pendingDeploy(for: "Nexus/Market").lastPathComponent,
            "Nexus%2FMarket.json"
        )
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

    func testValidationRequiresLocalImmediateParent() {
        XCTAssertThrowsError(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments/Receipts": chain(4101),
        ]).validated())
        XCTAssertNoThrow(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments": chain(4101),
            "Nexus/Payments/Receipts": chain(4201),
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
        XCTAssertThrowsError(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments": chain(4002),
        ]).validated())
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
        var colliding = chain(4101)
        colliding.publicRead = 4001
        XCTAssertThrowsError(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments": colliding,
        ]).validated())
    }

    func testValidationRejectsMiningUnknownChain() {
        XCTAssertThrowsError(try Topology(
            chains: ["Nexus": chain(4001)],
            mine: TopologyMine(chain: "Nexus/Payments")
        ).validated())
    }

    func testOrderedPathsAreParentBeforeChild() {
        let topology = Topology(chains: [
            "Nexus/Payments/Receipts": chain(4201),
            "Nexus": chain(4001),
            "Nexus/Payments": chain(4101),
            "Nexus/Assets": chain(4301),
        ])
        let ordered = topology.orderedPaths()
        XCTAssertEqual(ordered.first, "Nexus")
        XCTAssertLessThan(
            ordered.firstIndex(of: "Nexus/Payments")!,
            ordered.firstIndex(of: "Nexus/Payments/Receipts")!
        )
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
                batchSize: 1_000, rewards: "rewards.jsonl",
                minWork: ["Nexus": "2^32"],
                commitMinWorkTarget: true
            )
        )
        try topology.save(root: root)
        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.chains["Nexus"]?.listen, 4001)
        XCTAssertEqual(loaded.mine?.batchSize, 1_000)
        XCTAssertEqual(loaded.mine?.minWork, ["Nexus": "2^32"])
        XCTAssertEqual(loaded.mine?.commitMinWorkTarget, true)
        // Absent is the default: blocks commit the schedule.
        let legacy = try JSONDecoder().decode(
            TopologyMine.self,
            from: Data(#"{"chain":"Nexus","minWork":{"Nexus":"2^32"}}"#.utf8)
        )
        XCTAssertNil(legacy.commitMinWorkTarget)
        XCTAssertEqual(
            legacy.coordinatorMinimumWorkArguments,
            ["--min-work", "Nexus=2^32"]
        )
    }

    /// `mine.commitMinWorkTarget` reaches the coordinator as its flag, and
    /// without any `mine.minWork` it would commit nothing, so the file is
    /// refused by name.
    func testCommitMinWorkTargetPassesThroughAndNeedsMinimumWork() throws {
        func topology(_ mine: TopologyMine) -> Topology {
            Topology(chains: ["Nexus": chain(4001)], mine: mine)
        }
        let optedIn = TopologyMine(
            chain: "Nexus",
            minWork: ["Nexus/Payments": "2^20", "Nexus": "2^32"],
            commitMinWorkTarget: true
        )
        XCTAssertEqual(
            try topology(optedIn).validated().mine?
                .coordinatorMinimumWorkArguments,
            [
                "--min-work", "Nexus=2^32",
                "--min-work", "Nexus/Payments=2^20",
                "--commit-min-work-target",
            ]
        )
        for minWork in [nil, [String: String]()] {
            XCTAssertThrowsError(try topology(TopologyMine(
                chain: "Nexus",
                minWork: minWork,
                commitMinWorkTarget: true
            )).validated()) { error in
                XCTAssertEqual(
                    (error as? CtlError)?.description,
                    "mine.commitMinWorkTarget commits the mine.minWork targets and needs at least one mine.minWork entry"
                )
            }
        }
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

    func testLayoutSeparatesIdentityFromWipeableChains() {
        let layout = HostLayout(root: "/var/lib/lattice")
        XCTAssertTrue(layout.identityKey(for: "Nexus/Payments").path
            .hasSuffix("identity/Nexus-Payments.key"))
        XCTAssertTrue(layout.chainDirectory(for: "Nexus/Payments").path
            .hasSuffix("chains/Nexus/Payments"))
        XCTAssertFalse(layout.identityKey(for: "Nexus").path
            .contains("/chains/"))
    }
}
