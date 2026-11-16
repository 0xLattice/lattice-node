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
        hostedChains: [String]? = nil
    ) -> Topology {
        Topology(
            listen: 4001,
            rpc: 4003,
            hostedChains: hostedChains
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

        var browsers = configured
        browsers.webSocket = 4002
        let roundTripped = try JSONDecoder().decode(Topology.self, from: JSONEncoder().encode(browsers))
        XCTAssertEqual(roundTripped.webSocket, 4002)
        XCTAssertNoThrow(try roundTripped.validated())
        browsers.webSocket = 0
        XCTAssertNoThrow(try browsers.validated(), "0 turns the browser listener off")
        browsers.webSocket = browsers.rpc
        XCTAssertThrowsError(try browsers.validated())

        let legacy = Data(#"{"chains":{"Nexus":{"listen":4001,"rpc":4003}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Topology.self, from: legacy))
    }

    /// Round-deadline headroom belongs to the operator, and a bad value is a
    /// named refusal rather than a precondition trap.
    func testRoundDeadlineMultiplierIsOperatorSettableAndRefusesNonpositive() throws {
        XCTAssertEqual(
            try MinerConfig(roundDeadlineMultiplier: 3)
                .validated().roundDeadlineMultiplier,
            3
        )
        XCTAssertThrowsError(try MinerConfig(roundDeadlineMultiplier: 0).validated())
        XCTAssertThrowsError(try MinerConfig(roundDeadlineMultiplier: -1).validated())
        XCTAssertNil(try MinerConfig().validated().roundDeadlineMultiplier)
    }

    func testRoundTripThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = topology(hostedChains: ["Nexus/Payments"])
        try configured.save(root: root)
        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.rpc, 4003)
        XCTAssertEqual(loaded.hostedChains, ["Nexus/Payments"])
    }

    /// The miner's settings are its own file, beside the node's lattice.json.
    func testMinerSettingsAreTheirOwnFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-miner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(MinerConfig.fileName)
        try JSONEncoder().encode(MinerConfig(
            worker: "cpu", workers: 2, batchSize: 1_000,
            recipients: ["Nexus": "addr-nexus"],
            minWork: ["Nexus": "2^32"]
        )).write(to: file)
        let loaded = try MinerConfig.load(file: file)
        XCTAssertEqual(loaded.batchSize, 1_000)
        XCTAssertEqual(loaded.minWork, ["Nexus": "2^32"])
        XCTAssertEqual(loaded.recipients, ["Nexus": "addr-nexus"])
        XCTAssertEqual(loaded.coordinatorRecipientArguments, ["--recipient", "Nexus=addr-nexus"])
        // A misspelt key would burn rewards silently: refused.
        try Data(#"{"recipient":{"Nexus":"x"}}"#.utf8).write(to: file)
        XCTAssertThrowsError(try MinerConfig.load(file: file))
    }

    /// A lattice.json from before mining was a process of its own still
    /// starts the node, which ignores its `mine` and never writes it back.
    func testAnOlderLatticeJSONWithMineStillLoads() throws {
        let topology = try Topology.load(data: Data(
            #"{"listen":4001,"rpc":4003,"mine":{"enabled":true,"workers":1,"recipients":{"Nexus":"x"}}}"#.utf8
        )).validated()
        XCTAssertEqual(topology.rpc, 4003)
        XCTAssertFalse(String(decoding: try topology.canonicalData(), as: UTF8.self).contains("mine"))
        XCTAssertThrowsError(try Topology.load(data: Data(#"{"listen":4001,"rpc":4003,"nope":1}"#.utf8)))
    }

    /// While there is no miner.json, the miner reads an older lattice.json's
    /// `mine` (its `enabled` ignored) and copies it there once; miner.json
    /// wins.
    func testTheMinerFallsBackToAnOlderLatticeJSONsMine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-miner-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            #"{"listen":4001,"rpc":4003,"mine":{"enabled":true,"workers":3,"batchSize":10000000000,"recipients":{"Nexus":"old"}}}"#.utf8
        ).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertTrue(Topology.holdsRetiredMining(root: root))
        let (fallback, warning) = try MinerConfig.load(root: root)
        XCTAssertEqual(fallback.workers, 3)
        XCTAssertEqual(fallback.batchSize, 10_000_000_000)
        XCTAssertEqual(fallback.recipients, ["Nexus": "old"])
        XCTAssertTrue(warning?.contains("copied") == true, warning ?? "no warning")
        // Copied once, without `enabled`: a later node rewrite of
        // lattice.json (which drops `mine`) strands nothing.
        let copied = root.appendingPathComponent(MinerConfig.fileName)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: copied)) as? [String: Any])
        XCTAssertNil(object["enabled"])
        XCTAssertEqual(try MinerConfig.load(file: copied).batchSize, 10_000_000_000)
        try Data(#"{"listen":4001,"rpc":4003}"#.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        let (again, said) = try MinerConfig.load(root: root)
        XCTAssertEqual(again.recipients, ["Nexus": "old"])
        XCTAssertNil(said, "said once")
        // miner.json wins, and is never overwritten by the fallback.
        try Data(#"{"listen":4001,"rpc":4003,"mine":{"recipients":{"Nexus":"older"}}}"#.utf8)
            .write(to: root.appendingPathComponent(Topology.fileName))
        try JSONEncoder().encode(MinerConfig(recipients: ["Nexus": "new"])).write(to: copied)
        let (own, none) = try MinerConfig.load(root: root)
        XCTAssertEqual(own.recipients, ["Nexus": "new"])
        XCTAssertNil(own.workers)
        XCTAssertNil(none)
    }

    /// The miner's binaries are found beside the real `lattice`, through a
    /// symlink (as on PATH), not beside argv[0] or lattice-node.
    func testSiblingBinariesResolveBesideTheRealExecutable() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-siblings-\(UUID().uuidString)")
        let real = scratch.appendingPathComponent("opt/lattice/bin")
        let onPath = scratch.appendingPathComponent("home/.local/bin")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: onPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["lattice", "lattice-miner"] {
            let file = real.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try FileManager.default.createSymbolicLink(
            at: onPath.appendingPathComponent("lattice"), withDestinationURL: real.appendingPathComponent("lattice")
        )
        let found = try siblingBinary("lattice-miner", beside: onPath.appendingPathComponent("lattice"))
        XCTAssertEqual(found.resolvingSymlinksInPath().path, real.appendingPathComponent("lattice-miner").resolvingSymlinksInPath().path)
        XCTAssertThrowsError(try siblingBinary("lattice-no-such-binary", beside: onPath.appendingPathComponent("lattice")))
        XCTAssertTrue(currentExecutable.path.hasPrefix("/"), currentExecutable.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: currentExecutable.path))
    }

    func testValidationRejectsInvalidOperationalValues() {
        XCTAssertThrowsError(try MinerConfig(recipients: ["Nexus": ""]).validated())
        XCTAssertThrowsError(try MinerConfig(workers: 0).validated())
        XCTAssertThrowsError(try MinerConfig(batchSize: 0).validated())

        var negativeRate = topology()
        negativeRate.publicReadRate = -1
        XCTAssertThrowsError(try negativeRate.validated())
        var infiniteRate = topology()
        infiniteRate.publicReadMaxRate = .infinity
        XCTAssertThrowsError(try infiniteRate.validated())
        var negativeSubmitRate = topology()
        negativeSubmitRate.publicSubmitRate = -1
        XCTAssertThrowsError(try negativeSubmitRate.validated())
        var negativeFetches = topology()
        negativeFetches.publicReadFetches = -1
        XCTAssertThrowsError(try negativeFetches.validated())
        var submitWithoutPublicRead = topology()
        submitWithoutPublicRead.publicRead = nil
        submitWithoutPublicRead.publicSubmit = true
        XCTAssertThrowsError(try submitWithoutPublicRead.validated(), "public submit rides the public read port")
    }

    func testBlockBodiesLoadsFromConfigAndProducesItsNodeFlag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-bodies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func load(_ body: String) throws -> Topology {
            try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))
            return try Topology.load(root: root).validated()
        }

        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"blockBodies":"none"}"#).contentServingArguments,
            ["--block-bodies", "none"]
        )
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"blockBodies":"all"}"#).contentServingArguments,
            ["--block-bodies", "all"]
        )
        // Unset is the node's default, all: no flag.
        XCTAssertEqual(try load(#"{"listen":4001,"rpc":4003}"#).contentServingArguments, [])
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"blockBodies":"some"}"#))
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"state":"tip"}"#).contentServingArguments, ["--state", "tip"]
        )
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/Alpha"],"state":"recent","stateWindow":32,"stateWindows":{"Nexus/Alpha":500}}"#)
                .contentServingArguments,
            ["--state", "recent", "--state-window", "32", "--state-window", "Nexus/Alpha=500"]
        )
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"state":"recent","stateWindow":0}"#))
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"state":"recent","stateWindows":{"Alpha":5}}"#))
        // A window says how much recent state to keep: on all or none it says
        // nothing, and is left out (inert, reported), as is one for a chain
        // not hosted.
        XCTAssertEqual(try load(#"{"listen":4001,"rpc":4003,"stateWindow":32}"#).contentServingArguments, [])
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/Alpha"],"state":"none","stateWindows":{"Nexus/Alpha":5}}"#)
                .contentServingArguments,
            ["--state", "none"]
        )
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"state":"recent","stateWindows":{"Nexus/Alpha":5}}"#).contentServingArguments,
            ["--state", "recent"]
        )
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"state":"none"}"#).contentServingArguments, ["--state", "none"]
        )
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"state":"some"}"#))
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"announceLifetime":3600}"#).contentServingArguments,
            ["--announce-lifetime", "3600"]
        )
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/Alpha","Nexus/Beta"],"finalityWindow":240,"finalityWindows":{"Nexus/Beta":0,"Nexus/Alpha":500}}"#)
                .contentServingArguments,
            ["--finality-window", "240", "--finality-window", "Nexus/Alpha=500", "--finality-window", "Nexus/Beta=0"]
        )
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"finalityWindows":{"Alpha":500}}"#))
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"announceLifetime":0}"#))
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"announceLifetime":86401}"#))
    }

    func testContentServingLimitsLoadFromConfigAndProduceNodeFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-serving-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = #"{"listen":4001,"rpc":4003,"servingMaxConcurrent":200,"servingMaxInFlightVolumeBytes":536870912,"maxAcquisitionBytes":134217728}"#
        try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))

        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.contentServingArguments, [
            "--serving-max-concurrent", "200",
            "--serving-max-in-flight-volume-bytes", "536870912",
            "--max-acquisition-bytes", "134217728",
        ])
        let zero = #"{"listen":4001,"rpc":4003,"maxAcquisitionBytes":0}"#
        try Data(zero.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertThrowsError(try Topology.load(root: root).validated())

        let empty = #"{"listen":4001,"rpc":4003}"#
        try Data(empty.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        XCTAssertEqual(try Topology.load(root: root).contentServingArguments, [])
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

    /// The sync mining pause is on unless the operator turns it off.
    func testPauseMiningWhileSyncingIsOnUnlessTurnedOff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-sync-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, [String])] = [
            (#"{"listen":4001,"rpc":4003}"#, []),
            (#"{"listen":4001,"rpc":4003,"pauseMiningWhileSyncing":true}"#, []),
            (#"{"listen":4001,"rpc":4003,"pauseMiningWhileSyncing":false}"#, ["--no-pause-mining-while-syncing"]),
        ]
        for (body, flags) in cases {
            try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))
            XCTAssertEqual(try Topology.load(root: root).validated().publicSubmissionArguments, flags, body)
        }
    }

    /// The remote operator listener: both keys or neither, the token file
    /// under the root when relative, a port of its own.
    func testOperatorListenerLoadsFromConfigAndProducesNodeFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-operator-listener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostLayout(root: root.path)
        let file = root.appendingPathComponent(Topology.fileName)
        func flags(_ json: String) throws -> [String] {
            try Data(json.utf8).write(to: file)
            return try Topology.load(root: root).validated().nodeArguments(layout: layout)
        }
        let listening = try flags(#"{"listen":4001,"rpc":4003,"operatorListen":"0.0.0.0:8090","operatorTokens":"tokens.json","operatorAllowedOrigins":["https://d.example"]}"#)
        XCTAssertTrue(listening.joined(separator: " ").contains(
            "--operator-listen 0.0.0.0:8090 --operator-tokens \(root.appendingPathComponent("tokens.json").path) --operator-allowed-origin https://d.example"
        ))
        let absolute = try flags(#"{"listen":4001,"rpc":4003,"operatorListen":"0.0.0.0:8090","operatorTokens":"/etc/lattice/tokens.json"}"#)
        XCTAssertTrue(absolute.contains("/etc/lattice/tokens.json"))
        XCTAssertFalse(try flags(#"{"listen":4001,"rpc":4003}"#).contains("--operator-listen"))

        for refused in [
            #"{"listen":4001,"rpc":4003,"operatorListen":"0.0.0.0:8090"}"#,
            #"{"listen":4001,"rpc":4003,"operatorTokens":"tokens.json"}"#,
            #"{"listen":4001,"rpc":4003,"operatorListen":"0.0.0.0:4003","operatorTokens":"t.json"}"#,
            #"{"listen":4001,"rpc":4003,"webSocket":8090,"operatorListen":"0.0.0.0:8090","operatorTokens":"t.json"}"#,
            #"{"listen":4001,"rpc":4003,"operatorListen":"8090","operatorTokens":"t.json"}"#,
            #"{"listen":4001,"rpc":4003,"operatorListen":"ops.example:8090","operatorTokens":"t.json"}"#,
            #"{"listen":4001,"rpc":4003,"operatorAllowedOrigins":["https://d.example"]}"#,
        ] {
            try Data(refused.utf8).write(to: file)
            XCTAssertThrowsError(try Topology.load(root: root).validated(), refused)
        }
    }

    /// A configuration change is an RFC 7396 merge patch of a fragment:
    /// members replace, null removes.
    func testAMergePatchChangesOnlyWhatItNames() throws {
        let fragment: [String: Any] = [
            "hostedChains": ["Nexus/A"], "peers": ["Nexus": [String](), "Nexus/A": ["k@a.example:4001"]], "minRelayFee": 3,
        ]
        let next = try Topology.applying(
            mergePatch: Data(#"{"peers":{"Nexus":null},"stateWindow":null,"listen":5001}"#.utf8), to: fragment
        )
        XCTAssertEqual(next["listen"] as? Int, 5001)
        XCTAssertEqual(next["minRelayFee"] as? Int, 3)
        XCTAssertEqual(next["peers"] as? [String: [String]], ["Nexus/A": ["k@a.example:4001"]])
        XCTAssertEqual(next["hostedChains"] as? [String], ["Nexus/A"])
        XCTAssertNil(next["stateWindow"])
        XCTAssertThrowsError(try Topology.applying(mergePatch: Data("[1]".utf8), to: fragment))
        let topology = try Topology.load(data: Data(
            #"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/A"],"peers":{"Nexus":[],"Nexus/A":["k@a.example:4001"]}}"#.utf8
        ))
        let changed = try Topology.load(data: Data(
            #"{"listen":5001,"rpc":4003,"hostedChains":["Nexus/A"],"peers":{"Nexus/A":["k@a.example:4001"]}}"#.utf8
        ))
        XCTAssertEqual(try changed.restartRequired(comparedTo: topology), ["listen", "peers"])
        // A chain's removal takes what requires it hosted with it.
        let removed = topology.removingChains(["Nexus/A"])
        XCTAssertEqual(removed.hostedChains, [])
        XCTAssertEqual(removed.peers?.byChain, ["Nexus": []])
        XCTAssertNoThrow(try removed.validated())
    }

    /// `lattice config set a.b=value`: the value is JSON when it parses as
    /// JSON, a string otherwise.
    func testConfigAssignmentsBuildAMergePatch() throws {
        let patch = try ConfigAssignment.patch(setting: [
            "finalityWindows.Nexus/Alpha=abc", "stateWindow=128", "publicSubmit=true", "peers=[]",
        ])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let windows = try XCTUnwrap(object["finalityWindows"] as? [String: Any])
        XCTAssertEqual(windows["Nexus/Alpha"] as? String, "abc")
        XCTAssertEqual(object["publicSubmit"] as? Bool, true)
        XCTAssertEqual(object["stateWindow"] as? Int, 128)
        XCTAssertEqual((object["peers"] as? [Any])?.count, 0)
        let unset = try ConfigAssignment.patch(unsetting: ["peers.Nexus"])
        XCTAssertEqual(String(decoding: unset, as: UTF8.self), #"{"peers":{"Nexus":null}}"#)
        XCTAssertThrowsError(try ConfigAssignment.patch(setting: ["novalue"]))
        XCTAssertThrowsError(try ConfigAssignment.patch(setting: ["a..b=1"]))
    }

    /// `peers` is a list per chain. An array is Nexus's list, as in every
    /// file written before chains had their own; a list for a chain that is
    /// not hosted is refused.
    func testPeersLoadPerChainAndAnArrayIsTheNexusList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-chain-peers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func load(_ body: String) throws -> Topology {
            try Data(body.utf8).write(to: root.appendingPathComponent(Topology.fileName))
            return try Topology.load(root: root).validated()
        }

        let array = try load(#"{"listen":4001,"rpc":4003,"peers":["k@a.example:4001"]}"#)
        XCTAssertEqual(array.peers?.byChain, ["Nexus": ["k@a.example:4001"]])
        XCTAssertEqual(array.peerArguments, ["--peer", "k@a.example:4001"])
        // Written back as it was read.
        try array.save(root: root)
        XCTAssertEqual(try Topology.load(root: root).peers, array.peers)
        XCTAssertTrue(String(decoding: try Data(contentsOf: root.appendingPathComponent(Topology.fileName)), as: UTF8.self)
            .contains("\"peers\" : ["))

        XCTAssertEqual(try load(#"{"listen":4001,"rpc":4003,"peers":[]}"#).peerArguments, ["--no-default-peers"])
        XCTAssertEqual(try load(#"{"listen":4001,"rpc":4003}"#).peerArguments, [])

        let perChain = try load(
            #"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/Alpha","Nexus/Beta"],"peers":{"Nexus/Alpha":["k@a.example:4001","j@b.example:4001"],"Nexus/Beta":[]}}"#
        )
        // Nexus keeps the built-in peers; an empty child list is no list.
        XCTAssertEqual(perChain.peerArguments, [
            "--chain-peer", "Nexus/Alpha=k@a.example:4001",
            "--chain-peer", "Nexus/Alpha=j@b.example:4001",
        ])
        try perChain.save(root: root)
        XCTAssertEqual(try Topology.load(root: root).peers, perChain.peers)
        XCTAssertEqual(
            try load(#"{"listen":4001,"rpc":4003,"hostedChains":["Nexus/Alpha"],"peers":{"Nexus":[],"Nexus/Alpha":["k@a.example:4001"]}}"#).peerArguments,
            ["--no-default-peers", "--chain-peer", "Nexus/Alpha=k@a.example:4001"]
        )

        // Peers for a chain not hosted are inert: left out, not an error.
        XCTAssertNil(try load(#"{"listen":4001,"rpc":4003,"peers":{"Nexus/Alpha":["k@a.example:4001"]}}"#).peers)
        XCTAssertThrowsError(try load(#"{"listen":4001,"rpc":4003,"peers":"k@a.example:4001"}"#))
    }

    /// `minWork` reaches the coordinator as a search plan. There is no
    /// companion setting that commits it: blocks still commit their schedule.
    func testMinimumWorkPassesThroughAsASearchPlan() throws {
        let mine = MinerConfig(
            minWork: ["Nexus/Payments": "2^20", "Nexus": "2^32"]
        )
        XCTAssertEqual(
            try mine.validated().coordinatorMinimumWorkArguments,
            [
                "--min-work", "Nexus=2^32",
                "--min-work", "Nexus/Payments=2^20",
            ]
        )
    }

    /// The cadence is a floor on block spacing, not a fixed block time.
    func testPacingIsAFloorThatReleasesItself() {
        let paced = MinerConfig(minBlockIntervalSeconds: 600)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .zero), .seconds(600))
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(100)), .seconds(500))
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(600)), .zero)
        XCTAssertEqual(paced.pacingHold(afterRoundOf: .seconds(9_000)), .zero)
        XCTAssertEqual(MinerConfig().pacingHold(afterRoundOf: .zero), .zero)
    }

    func testPacingRoundTripsAndIsOptional() throws {
        let encoded = try JSONEncoder().encode(
            MinerConfig(minBlockIntervalSeconds: 3_300)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MinerConfig.self, from: encoded)
                .minBlockIntervalSeconds,
            3_300
        )
        XCTAssertNil(try JSONDecoder().decode(
            MinerConfig.self, from: Data("{}".utf8)
        ).minBlockIntervalSeconds)
    }

    func testRetiredMiningTopologyKeysAreRefused() {
        for body in [#"{"chain":"Nexus"}"#, #"{"rewards":{}}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                MinerConfig.self, from: Data(body.utf8)
            ))
        }
    }

    func testPacingIsNotACoordinatorArgument() {
        XCTAssertEqual(
            MinerConfig(
                minWork: ["Nexus": "2^40"],
                minBlockIntervalSeconds: 600
            ).coordinatorMinimumWorkArguments,
            ["--min-work", "Nexus=2^40"]
        )
    }

    func testTemplateTimeoutIsOperatorSettable() throws {
        XCTAssertEqual(
            MinerConfig().resolvedTemplateTimeoutSeconds,
            MinerConfig.defaultTemplateTimeoutSeconds
        )
        XCTAssertEqual(
            MinerConfig(templateTimeoutSeconds: 60).resolvedTemplateTimeoutSeconds,
            60
        )
        XCTAssertThrowsError(try MinerConfig(templateTimeoutSeconds: 0).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "templateTimeoutSeconds must be at least 1; a zero timeout can never see the node answer a template request, so the miner would never mine"
            )
        }
    }

    func testTemplateTimeoutCeilingDoesNotExceedTheCoordinatorsOwnLimit() {
        let coordinatorLimit = URLRequest(
            url: URL(string: "http://127.0.0.1:8080/mining/templates")!
        ).timeoutInterval
        XCTAssertLessThanOrEqual(
            TimeInterval(MinerConfig.maximumTemplateTimeoutSeconds),
            coordinatorLimit
        )
        XCTAssertLessThanOrEqual(
            TimeInterval(MinerConfig.defaultTemplateTimeoutSeconds),
            coordinatorLimit
        )
    }

    func testTemplateTimeoutAboveTheCoordinatorsLimitIsRefused() {
        XCTAssertThrowsError(try MinerConfig(
            templateTimeoutSeconds: MinerConfig.maximumTemplateTimeoutSeconds + 1
        ).validated()) { error in
            XCTAssertEqual(
                (error as? CtlError)?.description,
                "templateTimeoutSeconds must be at most \(MinerConfig.maximumTemplateTimeoutSeconds); the coordinator's own template fetch is fixed at that, so a longer probe would start rounds that then die fetching the same template"
            )
        }
        XCTAssertNoThrow(try MinerConfig(
            templateTimeoutSeconds: MinerConfig.maximumTemplateTimeoutSeconds
        ).validated())
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
