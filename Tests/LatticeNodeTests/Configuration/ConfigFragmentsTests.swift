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
            {"hostedChains":["Nexus/testnet/blog","Nexus/testnet/shop"]}
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
        XCTAssertEqual(merged.tree["Nexus/testnet/shop"]?.listedBy, ["hostmarket"])
        XCTAssertEqual(merged.tree.children, topology.hostedChains)
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
            layer("lattice", #"{"listen":4001,"rpc":8080,"hostedChains":["Nexus/A"],"peers":["aa@a.example:1"],"rpcAllowedOrigins":["https://a"],"state":"recent","stateWindows":{"Nexus":10,"Nexus/A":20}}"#),
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

    /// A chain is a path: what creates one is POST /chains, not a layer.
    func testAHostedChainIsAPath() throws {
        let base = try layer("lattice", #"{"listen":4001,"rpc":8080}"#)
        XCTAssertThrowsError(try MergedConfig.merge([base, layer("operator", #"{"hostedChains":[{"path":"Nexus/A"}]}"#)])) {
            XCTAssertTrue("\($0)".contains("POST /chains"), "\($0)")
        }
        let merged = try MergedConfig.merge([base, layer("hostmarket", #"{"hostedChains":["Nexus/A"]}"#), layer("operator", #"{"hostedChains":["Nexus/A"]}"#)])
        XCTAssertEqual(merged.topology.hostedChains, ["Nexus/A"])
        XCTAssertEqual(merged.tree["Nexus/A"]?.listedBy, ["hostmarket", "operator"])
    }

    /// A key set to null is as if the layer did not set it.
    func testANullIsNoValue() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"minRelayFee":2}"#),
            layer("operator", #"{"minRelayFee":null}"#),
        ])
        XCTAssertEqual(merged.topology.minRelayFee, 2)
    }

    /// Settings for a chain not in the hosted tree wait, inert, until it is;
    /// so does a state window while state is not recent.
    func testInertSettingsAreLeftOutAndReported() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"hostedChains":["Nexus/A/B"],"stateWindow":5}"#),
            layer("operator", #"{"peers":{"Nexus/A/B":["aa@a.example:1"],"Nexus/C":["aa@a.example:1"]},"finalityWindows":{"Nexus/C":4}}"#),
        ])
        XCTAssertEqual(merged.topology.hostedChains, ["Nexus/A", "Nexus/A/B"])
        XCTAssertEqual(merged.topology.peers?.byChain, ["Nexus/A/B": ["aa@a.example:1"]])
        XCTAssertNil(merged.topology.finalityWindows)
        XCTAssertNil(merged.topology.stateWindow)
        XCTAssertEqual(merged.inert.count, 3, "\(merged.inert)")
    }

    /// A child runs only under its parent: a layer that lists Nexus/A/B
    /// alone hosts Nexus/A too, implied by it.
    func testAListedChainHostsItsAncestorsImplied() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080}"#),
            layer("operator", #"{"hostedChains":["Nexus/A/B/C"]}"#),
        ])
        XCTAssertEqual(merged.topology.hostedChains, ["Nexus/A", "Nexus/A/B", "Nexus/A/B/C"])
        XCTAssertEqual(merged.tree["Nexus/A"]?.listedBy, [])
        XCTAssertEqual(merged.tree["Nexus/A"]?.impliedBy, ["Nexus/A/B/C"])
        XCTAssertEqual(merged.tree["Nexus/A/B/C"]?.listedBy, ["operator"])
        XCTAssertEqual(merged.tree["Nexus/A/B/C"]?.impliedBy, [])
        // Listed by one layer and needed by another's: listed.
        let both = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"hostedChains":["Nexus/A"]}"#),
            layer("operator", #"{"hostedChains":["Nexus/A/B"]}"#),
        ])
        XCTAssertEqual(both.topology.hostedChains, ["Nexus/A", "Nexus/A/B"])
        XCTAssertEqual(both.tree["Nexus/A"]?.listedBy, ["lattice"])
        XCTAssertEqual(both.tree["Nexus/A"]?.impliedBy, [])
    }

    /// Status shows each chain as listed, by its layers, or implied, by the
    /// listed chains under it.
    func testStatusShowsListedAndImplied() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080}"#),
            layer("deploy", #"{"hostedChains":["Nexus/A/B"]}"#),
            layer("operator", #"{"hostedChains":["Nexus/A/C","Nexus/A/B"]}"#),
        ])
        let status = merged.tree.status(running: ["Nexus/A", "Nexus/A/B", "Nexus/Old"], errors: ["Nexus/A/C": "did not start"])
        XCTAssertEqual(status.map(\.path), ["Nexus/A", "Nexus/A/B", "Nexus/A/C", "Nexus/Old"])
        XCTAssertEqual(status[0].from, [])
        XCTAssertEqual(status[0].impliedBy, ["Nexus/A/B", "Nexus/A/C"])
        XCTAssertEqual(status[0].actual, "hosted")
        XCTAssertEqual(status[1].from, ["deploy", "operator"])
        XCTAssertNil(status[1].impliedBy)
        XCTAssertEqual(status[2].actual, "notHosted")
        XCTAssertEqual(status[2].error, "did not start")
        XCTAssertNotNil(status[3].error, "running, though the tree no longer holds it")
    }

    /// A chain's settings apply wherever it is in the tree, an implied
    /// ancestor's too.
    func testSettingsOfAnImpliedChainApply() throws {
        let merged = try MergedConfig.merge([
            layer("lattice", #"{"listen":4001,"rpc":8080,"state":"recent"}"#),
            layer("operator", #"{"hostedChains":["Nexus/A/B"],"peers":{"Nexus/A":["aa@a.example:1"]},"stateWindows":{"Nexus/A":7},"finalityWindows":{"Nexus/A":3}}"#),
        ])
        XCTAssertEqual(merged.tree["Nexus/A"]?.settings, ChainSettings(peers: ["aa@a.example:1"], stateWindow: 7, finalityWindow: 3))
        XCTAssertEqual(merged.topology.peers?.byChain["Nexus/A"], ["aa@a.example:1"])
        XCTAssertEqual(merged.topology.stateWindows, ["Nexus/A": 7])
        XCTAssertEqual(merged.topology.finalityWindows, ["Nexus/A": 3])
        XCTAssertEqual(merged.inert, [])
    }

    /// What is wrong with the whole configuration names the file it is in.
    func testAStructuralErrorNamesItsLayer() throws {
        let base = try layer("lattice", #"{"listen":4001,"rpc":8080}"#)
        for (json, mention) in [
            (#"{"unknown":1}"#, "config.d/deploy.json"), (#"{"minRelayFee":"x"}"#, "config.d/deploy.json"),
            (#"{"hostedChains":[3]}"#, "config.d/deploy.json"), (#"{"hostedChains":["Nexus"]}"#, "config.d/deploy.json"),
            (#"{"peers":{"Alpha":[]}}"#, "config.d/deploy.json"), (#"{"finalityWindows":{"Nexus/":5}}"#, "config.d/deploy.json"),
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
        XCTAssertEqual(merged.inert.count, 2, "the files not read are reported: \(merged.inert)")
        XCTAssertEqual(merged.topology.minRelayFee, 3)
        // lattice.json is optional when a fragment sets the ports.
        try FileManager.default.removeItem(at: root.appendingPathComponent(Topology.fileName))
        try Data(#"{"listen":4001,"rpc":8080}"#.utf8).write(to: ConfigFragments.file(root: root, name: "deploy"))
        XCTAssertEqual(try MergedConfig.load(root: root).topology.rpc, 8080)
    }
}
