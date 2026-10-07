import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import LatticeCtlCore
import LatticeNode
@testable import LatticeNodeDaemon

final class LatticeCtlTopologyTests: XCTestCase {
    private func topology(
        hostedChains: [String]? = nil,
        mine: TopologyMine? = nil
    ) -> Topology {
        Topology(
            listen: 4001,
            rpc: 4003,
            hostedChains: hostedChains,
            mine: mine
        )
    }

    func testValidationRequiresParentFirstNexusRootedHostedPaths() {
        XCTAssertThrowsError(try topology(hostedChains: ["Payments"]).validated())
        XCTAssertThrowsError(try topology(hostedChains: ["Nexus/"]).validated())
        XCTAssertThrowsError(try topology(hostedChains: ["Nexus/Alpha/Beta"]).validated())
        XCTAssertThrowsError(try topology(hostedChains: [
            "Nexus/Alpha", "Nexus/Alpha",
        ]).validated())
        XCTAssertNoThrow(try topology(hostedChains: [
            "Nexus/Alpha", "Nexus/Alpha/Beta",
        ]).validated())
    }

    /// The process has one listener set for the whole hosted tree.
    func testFlatPortsRoundTripAndRejectCollisions() throws {
        var configured = topology(hostedChains: ["Nexus/Payments"])
        configured.publicRead = 8081
        configured.externalAddress = "node.example.org"
        let encoded = try JSONEncoder().encode(configured)
        let decoded = try JSONDecoder().decode(Topology.self, from: encoded)
        XCTAssertEqual(decoded.listen, 4001)
        XCTAssertEqual(decoded.publicRead, 8081)
        XCTAssertEqual(decoded.externalAddress, "node.example.org")
        XCTAssertEqual(decoded.hostedChains, ["Nexus/Payments"])
        XCTAssertNoThrow(try decoded.validated())

        var collision = configured
        collision.publicRead = collision.listen
        XCTAssertThrowsError(try collision.validated())

        let legacy = Data(#"{"chains":{"Nexus":{"listen":4001,"rpc":4003}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Topology.self, from: legacy))
    }

    /// Round-deadline headroom belongs to the operator, and a bad value is a
    /// named refusal rather than a precondition trap.
    func testRoundDeadlineMultiplierIsOperatorSettableAndRefusesNonpositive() throws {
        XCTAssertEqual(
            try topology(mine: TopologyMine(roundDeadlineMultiplier: 3))
                .validated().mine?.roundDeadlineMultiplier,
            3
        )
        XCTAssertThrowsError(try topology(
            mine: TopologyMine(roundDeadlineMultiplier: 0)
        ).validated())
        XCTAssertThrowsError(try topology(
            mine: TopologyMine(roundDeadlineMultiplier: -1)
        ).validated())
        XCTAssertNil(try topology(mine: TopologyMine()).validated()
            .mine?.roundDeadlineMultiplier)
    }

    func testRoundTripThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = topology(
            hostedChains: ["Nexus/Payments"],
            mine: TopologyMine(
                worker: "cpu", workers: 2, batchSize: 1_000,
                recipients: ["Nexus": "addr-nexus"],
                minWork: ["Nexus": "2^32"]
            )
        )
        try configured.save(root: root)
        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.rpc, 4003)
        XCTAssertEqual(loaded.hostedChains, ["Nexus/Payments"])
        XCTAssertEqual(loaded.mine?.batchSize, 1_000)
        XCTAssertEqual(loaded.mine?.minWork, ["Nexus": "2^32"])
        XCTAssertEqual(loaded.mine?.recipients, ["Nexus": "addr-nexus"])
        XCTAssertEqual(
            loaded.mine?.coordinatorRecipientArguments,
            ["--recipient", "Nexus=addr-nexus"]
        )
    }

    func testValidationRejectsInvalidOperationalValues() {
        XCTAssertThrowsError(try topology(mine: TopologyMine(
            recipients: ["Nexus/Unknown": "address"]
        )).validated())
        XCTAssertThrowsError(try topology(mine: TopologyMine(workers: 0)).validated())
        XCTAssertThrowsError(try topology(mine: TopologyMine(batchSize: 0)).validated())

        var negativeRate = topology()
        negativeRate.publicReadRate = -1
        XCTAssertThrowsError(try negativeRate.validated())
        var infiniteRate = topology()
        infiniteRate.publicReadMaxRate = .infinity
        XCTAssertThrowsError(try infiniteRate.validated())
        var negativeSubmitRate = topology()
        negativeSubmitRate.publicSubmitRate = -1
        XCTAssertThrowsError(try negativeSubmitRate.validated())
        var submitWithoutPublicRead = topology()
        submitWithoutPublicRead.publicRead = nil
        submitWithoutPublicRead.publicSubmit = true
        XCTAssertThrowsError(try submitWithoutPublicRead.validated(), "public submit rides the public read port")
    }

    func testContentServingLimitsLoadFromConfigAndProduceNodeFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-serving-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = #"{"listen":4001,"rpc":4003,"servingMaxConcurrent":200,"servingMaxConcurrentPerPeer":20,"servingMaxQueuedPerPeer":500,"servingMaxInFlightVolumeBytes":536870912}"#
        try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))

        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.contentServingArguments, [
            "--serving-max-concurrent", "200",
            "--serving-max-concurrent-per-peer", "20",
            "--serving-max-queued-per-peer", "500",
            "--serving-max-in-flight-volume-bytes", "536870912",
        ])

        let empty = #"{"listen":4001,"rpc":4003}"#
        try Data(empty.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertEqual(try Topology.load(root: root).contentServingArguments, [])
    }

    func testResourceBudgetsLoadFromConfigAndProduceNodeFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-resource-budgets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = #"{"listen":4001,"rpc":4003,"overlayMaxConnections":512,"syncMaxUnverifiedBytesPerPeer":2097152,"syncMaxPendingBytes":33554432,"mempoolMaxBytes":134217728,"syncMaxQueuedBytesPerSession":4194304}"#
        try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))

        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.resourceBudgetArguments, [
            "--overlay-max-connections", "512",
            "--sync-max-unverified-bytes-per-peer", "2097152",
            "--sync-max-pending-bytes", "33554432",
            "--mempool-max-bytes", "134217728",
            "--sync-max-queued-bytes-per-session", "4194304",
        ])

        let empty = #"{"listen":4001,"rpc":4003}"#
        try Data(empty.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertEqual(try Topology.load(root: root).validated().resourceBudgetArguments, [])

        for key in [
            "overlayMaxConnections", "syncMaxUnverifiedBytesPerPeer", "syncMaxPendingBytes",
            "mempoolMaxBytes", "syncMaxQueuedBytesPerSession",
        ] {
            for value in ["0", "-1"] {
                let invalid = #"{"listen":4001,"rpc":4003,"\#(key)":\#(value)}"#
                try Data(invalid.utf8).write(to: root.appendingPathComponent(Topology.fileName))
                XCTAssertThrowsError(try Topology.load(root: root).validated(), "\(key) = \(value)")
            }
            let fractional = #"{"listen":4001,"rpc":4003,"\#(key)":1.5}"#
            try Data(fractional.utf8).write(to: root.appendingPathComponent(Topology.fileName))
            XCTAssertThrowsError(try Topology.load(root: root), "\(key) is an integer")
        }
    }

    func testPublicSubmitPolicyLoadsFromConfigAndProducesNodeFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-submit-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = #"{"listen":4001,"rpc":4003,"publicRead":8081,"publicSubmit":true,"publicSubmitRate":2,"minRelayFee":1}"#
        try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))

        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.publicSubmitRate, 2)
        XCTAssertEqual(loaded.publicSubmissionArguments, [
            "--public-submit",
            "--public-submit-rate", "2.0",
            "--min-relay-fee", "1",
        ])

        let misspelled = #"{"listen":4001,"rpc":4003,"publicSubmitRtae":2}"#
        try Data(misspelled.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertThrowsError(try Topology.load(root: root)) { error in
            XCTAssertTrue(String(describing: error).contains("publicSubmitRtae"))
        }
    }

    /// `mine.minWork` reaches the coordinator as a search plan. There is no
    /// companion setting that commits it: blocks still commit their schedule.
    func testMinimumWorkPassesThroughAsASearchPlan() throws {
        let mine = TopologyMine(
            minWork: ["Nexus/Payments": "2^20", "Nexus": "2^32"]
        )
        XCTAssertEqual(
            try topology(
                hostedChains: ["Nexus/Payments"], mine: mine
            ).validated()
                .mine?.coordinatorMinimumWorkArguments,
            [
                "--min-work", "Nexus=2^32",
                "--min-work", "Nexus/Payments=2^20",
            ]
        )
    }

    /// The cadence is a floor on block spacing, not a fixed block time.
    func testPacingIsAFloorThatReleasesItself() {
        let paced = TopologyMine(minBlockIntervalSeconds: 600)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .zero), .seconds(600))
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(100)), .seconds(500))
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(600)), .zero)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(9_000)), .zero)
        XCTAssertEqual(TopologyMine().pacingHold(afterRoundOf: .zero), .zero)
    }

    func testPacingRoundTripsAndIsOptional() throws {
        let encoded = try JSONEncoder().encode(
            TopologyMine(minBlockIntervalSeconds: 3_300)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(TopologyMine.self, from: encoded)
                .minBlockIntervalSeconds,
            3_300
        )
        XCTAssertNil(try JSONDecoder().decode(
            TopologyMine.self, from: Data("{}".utf8)
        ).minBlockIntervalSeconds)
    }

    func testRetiredMiningTopologyKeysAreRefused() {
        for body in [#"{"chain":"Nexus"}"#, #"{"rewards":{}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                TopologyMine.self, from: Data(body.utf8)
            ))
        }
    }

    func testPacingIsNotACoordinatorArgument() {
        XCTAssertEqual(
            TopologyMine(
                minWork: ["Nexus": "2^40"],
                minBlockIntervalSeconds: 600
            ).coordinatorMinimumWorkArguments,
            ["--min-work", "Nexus=2^40"]
        )
    }

    func testTemplateTimeoutIsOperatorSettable() throws {
        XCTAssertEqual(
            TopologyMine().resolvedTemplateTimeoutSeconds,
            TopologyMine.defaultTemplateTimeoutSeconds
        )
        XCTAssertEqual(
            TopologyMine(templateTimeoutSeconds: 60).resolvedTemplateTimeoutSeconds,
            60
        )
        XCTAssertThrowsError(try topology(
            mine: TopologyMine(templateTimeoutSeconds: 0)
        ).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "mine.templateTimeoutSeconds must be at least 1; a zero timeout can never observe a template expiry, so no round deadline could be derived and the miner would never mine"
            )
        }
    }

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

    func testTemplateTimeoutAboveTheCoordinatorsLimitIsRefused() {
        XCTAssertThrowsError(try topology(mine: TopologyMine(
            templateTimeoutSeconds: TopologyMine.maximumTemplateTimeoutSeconds + 1
        )).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "mine.templateTimeoutSeconds must be at most \(TopologyMine.maximumTemplateTimeoutSeconds); the coordinator's own template fetch is fixed at that, so a longer probe would observe expiries for rounds that then die fetching the same template"
            )
        }
        XCTAssertNoThrow(try topology(mine: TopologyMine(
            templateTimeoutSeconds: TopologyMine.maximumTemplateTimeoutSeconds
        )).validated())
    }

    func testLayoutSeparatesIdentityFromWipeableChainTree() {
        let layout = HostLayout(root: "/var/lib/lattice")
        XCTAssertTrue(layout.identityKey(for: "Nexus").path
            .hasSuffix("identity/Nexus.key"))
        XCTAssertTrue(layout.chainDirectory(for: "Nexus/Payments").path
            .hasSuffix("chains/Nexus/Payments"))
        XCTAssertFalse(layout.identityKey(for: "Nexus").path.contains("/chains/"))
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
}
