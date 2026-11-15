import Foundation
import Lattice
import LatticeNode
import LatticeNodeAPI
import XCTest

/// lattice.json and the fragments of config.d, merged in name order: a value
/// from the later layer, sets as unions, per-chain maps per chain.
final class ConfigFragmentsTests: XCTestCase {
    private func layer(_ name: String, _ json: String) throws -> ConfigLayer {
        ConfigLayer(name: name, object: try ConfigFragments.object(Data(json.utf8), named: name))
    }

    private let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func created(_ path: String, targetBlockTime: UInt64 = 1_000) throws -> String {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: targetBlockTime, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        return String(decoding: try JSONEncoder().encode(HostedChain(path: path, spec: spec)), as: UTF8.self)
    }

    /// Three writers, each with its own fragment: a deploy script, a hosting
    /// seller and the operator.
    func testThreeWritersMerge() throws {
        let merged = try MergedConfig.merge([
            layer("deploy", """
            {"listen":4001,"rpc":8080,"publicRead":8081,"externalAddress":"137.66.36.149",
             "peers":{"Nexus":["aa@ams.example:4001"]},
             "hostedChains":["Nexus/testnet","Nexus/testnet/names"],"state":"recent","stateWindow":64}
            """),
            layer("hostmarket", """
            {"hostedChains":["Nexus/testnet/blog",\(try created("Nexus/testnet/shop"))]}
            """),
            layer("operator", """
            {"stateWindow":128,"hostedChains":["Nexus/testnet/turnup"],
             "peers":{"Nexus/testnet/turnup":["bb@10.0.0.7:4001"]},
             "stateWindows":{"Nexus/testnet/blog":500}}
            """),
        ])
        let topology = merged.topology
        XCTAssertEqual(merged.layers, ["deploy", "hostmarket", "operator"])
        XCTAssertEqual(topology.listen, 4001)
        XCTAssertEqual(topology.stateWindow, 128, "the later layer's value")
        XCTAssertEqual(topology.hostedChains, [
            "Nexus/testnet", "Nexus/testnet/blog", "Nexus/testnet/names", "Nexus/testnet/shop", "Nexus/testnet/turnup",
        ], "the union, parent first")
        XCTAssertEqual(topology.peers?.byChain, [
            "Nexus": ["aa@ams.example:4001"], "Nexus/testnet/turnup": ["bb@10.0.0.7:4001"],
        ])
        XCTAssertEqual(topology.stateWindows, ["Nexus/testnet/blog": 500])
        XCTAssertEqual(merged.declaredBy["Nexus/testnet/shop"], ["hostmarket"])
        XCTAssertEqual(merged.creates["Nexus/testnet/shop"]?.spec?.targetBlockTime, 1_000)
        XCTAssertEqual(merged.chainErrors, [:])
    }

    func testAValueFromTheLaterLayerWins() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"minRelayFee":1}"#),
            layer("10-deploy", #"{"minRelayFee":2}"#),
            layer("deploy", #"{"minRelayFee":3,"announceLifetime":600}"#),
        ])
        XCTAssertEqual(merged.topology.minRelayFee, 3)
        XCTAssertEqual(merged.topology.announceLifetime, 600)
    }

    func testListsAreUnionsAndMapsMergePerKey() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"peers":["aa@a.example:1"],"rpcAllowedOrigins":["https://a"],"state":"recent","stateWindows":{"Nexus":10,"Nexus/A":20}}"#),
            layer("operator", #"{"peers":{"Nexus":["aa@a.example:1","bb@b.example:2"]},"rpcAllowedOrigins":["https://b"],"stateWindows":{"Nexus/A":30}}"#),
        ])
        XCTAssertEqual(merged.topology.peers?.byChain["Nexus"], ["aa@a.example:1", "bb@b.example:2"])
        XCTAssertEqual(merged.topology.rpcAllowedOrigins, ["https://a", "https://b"])
        XCTAssertEqual(merged.topology.stateWindows, ["Nexus": 10, "Nexus/A": 30])
    }

    /// An empty Nexus list in one layer still means no built-in peers when no
    /// other layer lists any.
    func testAnEmptyPeerListStaysEmpty() throws {
        let merged = try MergedConfig.merge([layer("lattice", #"{"listen":4001,"rpc":8080,"peers":[]}"#)])
        XCTAssertEqual(merged.topology.peers?.byChain["Nexus"], [])
    }

    func testTwoLayersCreatingAChainDifferentlyLeaveItUnhosted() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080}"#),
            layer("hostmarket", #"{"hostedChains":[\#(try created("Nexus/A"))]}"#),
            layer("operator", #"{"hostedChains":[\#(try created("Nexus/A", targetBlockTime: 2_000)),"Nexus/A/B","Nexus/C"],"peers":{"Nexus/A":["aa@a.example:1"]}}"#),
        ])
        XCTAssertEqual(merged.topology.hostedChains, ["Nexus/C"])
        XCTAssertTrue(merged.chainErrors["Nexus/A"]?.contains("hostmarket and operator") == true)
        XCTAssertTrue(merged.chainErrors["Nexus/A/B"]?.contains("waiting for Nexus/A") == true)
        XCTAssertNil(merged.topology.peers?.byChain["Nexus/A"], "an unhosted chain's peers go with it")
    }

    func testTheSameCreationFromTwoLayersIsOneChain() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080}"#),
            layer("hostmarket", #"{"hostedChains":[\#(try created("Nexus/A"))]}"#),
            layer("operator", #"{"hostedChains":[\#(try created("Nexus/A")),"Nexus/A"]}"#),
        ])
        XCTAssertEqual(merged.topology.hostedChains, ["Nexus/A"])
        XCTAssertEqual(merged.declaredBy["Nexus/A"], ["hostmarket", "operator"])
        XCTAssertEqual(merged.chainErrors, [:])
    }

    func testAChainWhoseParentNoLayerHostsWaits() throws {
        let merged = try MergedConfig.merge([layer("lattice", #"{"listen":4001,"rpc":8080,"hostedChains":["Nexus/A/B"]}"#)])
        XCTAssertEqual(merged.topology.hostedChains, [])
        XCTAssertNotNil(merged.chainErrors["Nexus/A/B"])
    }

    /// What is wrong with the whole configuration names the file it is in.
    func testAStructuralErrorNamesItsLayer() throws {
        let base = try layer("lattice", #"{"listen":4001,"rpc":8080}"#)
        for (json, mention) in [
            (#"{"unknown":1}"#, "config.d/deploy.json"), (#"{"minRelayFee":"x"}"#, "config.d/deploy.json"),
            (#"{"hostedChains":[3]}"#, "config.d/deploy.json"), (#"{"hostedChains":["Nexus"]}"#, "config.d/deploy.json"),
            (#"{"rpc":4001}"#, "does not check"),
        ] {
            XCTAssertThrowsError(try MergedConfig.merge([base, layer("deploy", json)]), json) {
                XCTAssertTrue("\($0)".contains(mention), "\(json): \($0)")
            }
        }
        XCTAssertThrowsError(try MergedConfig.merge([layer("deploy", #"{"listen":4001}"#)])) {
            XCTAssertTrue("\($0)".contains("rpc"))
        }
    }

    func testFragmentsAreReadInNameOrderAndOthersIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fragments-\(UUID().uuidString)")
        let directory = ConfigFragments.directory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"listen":4001,"rpc":8080}"#.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        for (name, fee) in [("operator", 3), ("deploy", 1), ("50-hostmarket", 2)] {
            try Data(#"{"minRelayFee":\#(fee)}"#.utf8).write(to: ConfigFragments.file(root: root, name: name))
        }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("operator.json.bak"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Upper.json"))
        let merged = try MergedConfig.load(root: root)
        XCTAssertEqual(merged.layers, ["lattice", "50-hostmarket", "deploy", "operator"])
        XCTAssertEqual(merged.topology.minRelayFee, 3)
        // lattice.json is optional when a fragment sets the ports.
        try FileManager.default.removeItem(at: root.appendingPathComponent(Topology.fileName))
        try Data(#"{"listen":4001,"rpc":8080}"#.utf8).write(to: ConfigFragments.file(root: root, name: "deploy"))
        XCTAssertEqual(try MergedConfig.load(root: root).topology.rpc, 8080)
    }
}
