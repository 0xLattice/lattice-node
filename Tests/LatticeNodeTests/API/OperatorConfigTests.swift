import Foundation
import Ivy
import Lattice
import LatticeNode
import LatticeNodeAPI
import XCTest
@testable import LatticeNodeDaemon

/// The node's configuration under `--root`: fragments replaced one at a
/// time, the merged result checked before anything is written, and the
/// running node converged to it, with what did not start reported.
final class OperatorConfigTests: XCTestCase {
    /// Hosts what it is told, except `failing`, one call at a time or not.
    private final class FakeRuntime: HostingRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var hosted: [[String]] = []
        private var peers: [[String]: [PeerEndpoint]] = [:]
        private var inFlight = 0
        private var most = 0
        private var count = 0
        let failing: Set<String>

        var mostAtOnce: Int { lock.withLock { most } }
        var calls: Int { lock.withLock { count } }

        init(failing: Set<String> = []) { self.failing = failing }

        var hostedChildren: [[String]] { lock.withLock { hosted } }
        var running: Set<String> { Set(hostedChildren.map { $0.joined(separator: "/") }) }
        /// The child chains it was last told to host, started or not.
        var told: [[String]] { lock.withLock { lastTold } }
        private var lastTold: [[String]] = []
        /// The child chains' peers it was last given.
        var seedPeers: [[String]: [PeerEndpoint]] { lock.withLock { peers } }

        func host(_ next: HostedChildren) async throws {
            lock.withLock {
                inFlight += 1
                count += 1
                most = max(most, inFlight)
            }
            try await Task.sleep(for: .milliseconds(50))
            let started = next.children.filter { !failing.contains($0.joined(separator: "/")) }
            lock.withLock {
                hosted = started
                lastTold = next.children
                peers = next.seedPeers
                inFlight -= 1
            }
            if started.count != next.children.count { throw OperatorConfigError.invalid("level failed to start") }
        }
    }

    private func make(
        _ json: String = #"{"listen":4001,"rpc":4003,"peers":[]}"#, runtime: FakeRuntime = FakeRuntime()
    ) throws -> (OperatorConfig, HostLayout) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(json.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        let layout = HostLayout(root: root.path)
        let merged = try MergedConfig.load(root: root)
        let config = OperatorConfig(layout: layout, desired: merged, started: merged.topology, runtime: runtime)
        return (config, layout)
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    private func put(_ config: OperatorConfig, _ name: String, _ json: String, ifMatch: String? = nil) async throws -> ConfigResponse {
        try await config.put(name, data(json), ifMatch: ifMatch, remote: false)
    }

    func testConcurrentChangesApplyOneAtATimeAndAllAreKept() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let (a, b, c) = (data(#"{"hostedChains":["Nexus/A"]}"#), data(#"{"hostedChains":["Nexus/B"]}"#), data(#"{"minRelayFee":5}"#))
        async let first = config.put("deploy", a, ifMatch: nil, remote: false)
        async let second = config.put("hostmarket", b, ifMatch: nil, remote: false)
        async let third = config.put("operator", c, ifMatch: nil, remote: false)
        _ = try await (first, second, third)
        XCTAssertEqual(runtime.mostAtOnce, 1, "no two changes were applied at once")
        let kept = try Topology.load(root: layout.root)
        XCTAssertEqual(kept.hostedChains, ["Nexus/A", "Nexus/B"])
        XCTAssertEqual(kept.minRelayFee, 5)
        XCTAssertEqual(Set(runtime.hostedChildren.map { $0.joined(separator: "/") }), ["Nexus/A", "Nexus/B"])
    }

    /// A chain that does not start stays desired and is reported; the rest
    /// of the change holds.
    func testAChainThatDoesNotStartIsReportedNotDropped() async throws {
        let runtime = FakeRuntime(failing: ["Nexus/B"])
        let (config, layout) = try make(runtime: runtime)
        let response = try await put(config, "operator", #"{"hostedChains":["Nexus/A","Nexus/B"]}"#)
        XCTAssertEqual(response.spec.hostedChains, ["Nexus/A", "Nexus/B"])
        let b = try XCTUnwrap(response.status.chains.first { $0.path == "Nexus/B" })
        XCTAssertEqual(b.actual, "notHosted")
        XCTAssertNotNil(b.error)
        XCTAssertEqual(response.status.chains.first { $0.path == "Nexus/A" }?.actual, "hosted")
        let file = try ConfigFragments.object(at: ConfigFragments.file(root: layout.root, name: "operator"))
        XCTAssertEqual(file["hostedChains"] as? [String], ["Nexus/A", "Nexus/B"], "the fragment is kept as sent")
    }

    /// A chain that did not start and is then no longer listed changes no
    /// running chain, but the node is still told: it lets go of the
    /// chain's data.
    func testAChainThatDidNotStartIsDroppedWhenNoLongerListed() async throws {
        let runtime = FakeRuntime(failing: ["Nexus/B"])
        let (config, _) = try make(runtime: runtime)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A","Nexus/B"]}"#)
        XCTAssertEqual(runtime.told, [["Nexus", "A"], ["Nexus", "B"]])
        let response = try await put(config, "operator", #"{"hostedChains":["Nexus/A"]}"#)
        XCTAssertEqual(runtime.told, [["Nexus", "A"]], "the node is told B is no longer hosted")
        XCTAssertNil(response.status.chains.first { $0.path == "Nexus/B" })
    }

    func testAnInvalidFragmentWritesNothing() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        for refused in [
            #"{"state":"some"}"#, #"{"unknown":1}"#, #"[1]"#, #"{"rpc":4001}"#,
            #"{"peers":{"Nexus":["garbage"]}}"#, #"{"stateWindows":{"Nexus":0}}"#,
            #"{"hostedChains":["Nexus"]}"#, #"{"hostedChains":[{"path":"Nexus/A"}]}"#,
        ] {
            do {
                _ = try await put(config, "operator", refused)
                XCTFail("\(refused) was accepted")
            } catch OperatorConfigError.invalid {}
        }
        XCTAssertEqual(runtime.calls, 0)
        XCTAssertEqual(ConfigFragments.names(root: layout.root), [])
        for name in ["lattice", "Ops", "../x", ""] {
            do {
                _ = try await put(config, name, "{}")
                XCTFail("\(name) was accepted as a name")
            } catch OperatorConfigError.invalid {}
        }
    }

    func testKeysTakingARestartAreReported() async throws {
        let (config, layout) = try make()
        let response = try await put(config, "deploy", #"{"listen":5001,"hostedChains":["Nexus/A"]}"#)
        XCTAssertEqual(response.status.pendingRestart, ["listen"])
        XCTAssertEqual(response.spec.listen, 5001)
        // Deleting the fragment takes it back, and its chain stops.
        let deleted = try await config.delete("deploy", ifMatch: nil, remote: false)
        XCTAssertEqual(deleted.status.pendingRestart, [])
        XCTAssertEqual(deleted.spec.hostedChains, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConfigFragments.file(root: layout.root, name: "deploy").path))
    }

    func testTheRemoteListenerNamesNoFiles() async throws {
        let (config, _) = try make()
        do {
            _ = try await config.put(
                "operator", data(#"{"operatorListen":"0.0.0.0:9000","operatorTokens":"/etc/t.json"}"#),
                ifMatch: nil, remote: true
            )
            XCTFail("accepted")
        } catch OperatorConfigError.invalid {}
    }

    /// A file changed by hand is just another layer: the next change, or a
    /// SIGHUP, reads it.
    func testAHandEditIsReadNotRefused() async throws {
        let (config, layout) = try make()
        try FileManager.default.createDirectory(at: ConfigFragments.directory(root: layout.root), withIntermediateDirectories: true)
        try data(#"{"minRelayFee":9}"#).write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        await config.reload()
        let reloaded = try await config.current()
        XCTAssertEqual(reloaded.spec.minRelayFee, 9)
        XCTAssertEqual(reloaded.fragments, ["lattice", "deploy"])
        // One that does not check is not used, and is reported.
        try data(#"{"minRelayFee":"lots"}"#).write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        await config.reload()
        let kept = try await config.current()
        XCTAssertEqual(kept.spec.minRelayFee, 9)
        XCTAssertTrue(kept.status.errors.contains { $0.hasPrefix("reload:") }, "\(kept.status.errors)")
    }

    /// A chain under a parent keeps the parent hosted: dropping Nexus/A
    /// from deploy, while operator lists Nexus/A/B, stops neither, whether
    /// by PUT, DELETE, a hand edit and SIGHUP, or a restart.
    func testAParentStaysWhileAChainUnderItIsListed() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let both: Set<String> = ["Nexus/A", "Nexus/A/B"]
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/A"]}"#)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        XCTAssertEqual(runtime.running, both)
        // PUT
        let dropped = try await put(config, "deploy", "{}")
        XCTAssertEqual(runtime.running, both)
        let a = try XCTUnwrap(dropped.status.chains.first { $0.path == "Nexus/A" })
        XCTAssertEqual(a.from, [])
        XCTAssertEqual(a.impliedBy, ["Nexus/A/B"])
        XCTAssertEqual(a.actual, "hosted")
        // DELETE
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/A"]}"#)
        _ = try await config.delete("deploy", ifMatch: nil, remote: false)
        XCTAssertEqual(runtime.running, both)
        // A hand edit, read on SIGHUP
        try data(#"{"hostedChains":["Nexus/A"]}"#).write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        await config.reload()
        try data("{}").write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        await config.reload()
        let reloaded = try await config.current()
        XCTAssertEqual(reloaded.status.errors, [])
        XCTAssertEqual(runtime.running, both)
        // A restart: allowed, and the new process hosts both.
        try await config.checkRestart()
        let merged = try MergedConfig.load(root: layout.root)
        let arguments = merged.topology.nodeArguments(layout: layout)
        XCTAssertTrue(zip(arguments, arguments.dropFirst()).contains { $0 == ("--host-chain", "Nexus/A") }, "\(arguments)")
        let restarted = FakeRuntime()
        let fresh = OperatorConfig(layout: layout, desired: merged, started: merged.topology, runtime: restarted)
        await fresh.reload()
        XCTAssertEqual(restarted.running, both)
    }

    /// Once no layer lists a chain or any chain under it, it stops, and so
    /// do the ancestors it alone kept.
    func testRemovingTheLastListingStopsALeafAndTheAncestorsItKept() async throws {
        let runtime = FakeRuntime()
        let (config, _) = try make(runtime: runtime)
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/C"]}"#)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B","Nexus/C/D"]}"#)
        XCTAssertEqual(runtime.running, ["Nexus/A", "Nexus/A/B", "Nexus/C", "Nexus/C/D"])
        let after = try await put(config, "operator", "{}")
        XCTAssertEqual(runtime.running, ["Nexus/C"], "Nexus/C is still listed by deploy")
        XCTAssertEqual(after.status.chains.map(\.path), ["Nexus/C"])
        XCTAssertEqual(after.spec.hostedChains, ["Nexus/C"])
    }

    /// An implied ancestor's settings apply as a listed chain's do.
    func testSettingsOfAnImpliedParentApply() async throws {
        let runtime = FakeRuntime()
        let (config, _) = try make(runtime: runtime)
        let key = String(repeating: "ab", count: 33)
        let response = try await put(
            config, "operator", #"{"hostedChains":["Nexus/A/B"],"peers":{"Nexus/A":["\#(key)@10.0.0.1:4001"]}}"#
        )
        XCTAssertEqual(response.status.inert, [])
        XCTAssertEqual(response.spec.peers?.byChain["Nexus/A"], ["\(key)@10.0.0.1:4001"])
        XCTAssertEqual(runtime.seedPeers[["Nexus", "A"]]?.count, 1)
    }

    /// A setting for a chain not hosted, or a state window without `state:
    /// recent`, is inert: reported, not refused.
    func testInertSettingsAreReportedNotRefused() async throws {
        let (config, _) = try make()
        let response = try await put(
            config, "operator",
            #"{"peers":{"Nexus/Z":["\#(String(repeating: "ab", count: 33))@10.0.0.1:4001"]},"stateWindows":{"Nexus":5},"finalityWindows":{"Nexus/Z":3}}"#
        )
        XCTAssertNil(response.spec.peers?.byChain["Nexus/Z"])
        XCTAssertNil(response.spec.stateWindows)
        XCTAssertNil(response.spec.finalityWindows)
        XCTAssertEqual(response.status.inert.count, 3, "\(response.status.inert)")
        // Hosted, its peers apply.
        let hosted = try await put(config, "deploy", #"{"hostedChains":["Nexus/Z"]}"#)
        XCTAssertNotNil(hosted.spec.peers?.byChain["Nexus/Z"])
    }

    func testFilesThatAreNotFragmentsAreReported() throws {
        let (_, layout) = try make()
        try FileManager.default.createDirectory(at: ConfigFragments.directory(root: layout.root), withIntermediateDirectories: true)
        for name in ["README", "Deploy.json", "deploy.json.bak"] {
            try data("{}").write(to: ConfigFragments.directory(root: layout.root).appendingPathComponent(name))
        }
        let merged = try MergedConfig.load(root: layout.root)
        XCTAssertEqual(merged.layers, ["lattice"])
        XCTAssertEqual(merged.inert.filter { $0.contains("is not read") }.count, 3, "\(merged.inert)")
    }

    /// A chain is created once (`POST /chains`): the same creation again is
    /// no change; another, or one for a chain synced without a spec, is a
    /// conflict. Hosting the path then mines it from its spec.
    func testAChainIsCreatedOnce() async throws {
        let premined = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 10,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let first = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let second = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let created = try await config.create(HostedChain(path: "Nexus/A", spec: premined, premineTo: first))
        XCTAssertTrue(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
        let again = try await config.create(HostedChain(path: "Nexus/A", spec: premined, premineTo: first))
        XCTAssertFalse(again)
        do {
            _ = try await config.create(HostedChain(path: "Nexus/A", spec: premined, premineTo: second))
            XCTFail("created twice")
        } catch OperatorConfigError.conflict {}
        do {
            _ = try await config.create(HostedChain(path: "Nexus/B", spec: premined))
            XCTFail("a premine with no recipient was accepted")
        } catch OperatorConfigError.invalid {}
        // A chain hosted without a spec is synced; it takes none later.
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A","Nexus/S"]}"#)
        do {
            _ = try await config.create(HostedChain(path: "Nexus/S", spec: spec))
            XCTFail("a synced chain took a spec")
        } catch OperatorConfigError.conflict {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/S").path))
        XCTAssertEqual(Set(runtime.hostedChildren.map { $0.joined(separator: "/") }), ["Nexus/A", "Nexus/S"])
    }

    /// A restart reads the files afresh: a configuration that would not
    /// start is refused.
    func testARestartIntoAConfigurationThatWouldNotStartIsRefused() async throws {
        let (config, layout) = try make()
        try await config.checkRestart()
        try data(#"{"listen":4001,"rpc":4003,"peers":["garbage"]}"#)
            .write(to: layout.root.appendingPathComponent(Topology.fileName))
        do {
            try await config.checkRestart()
            XCTFail("a restart into a bad file was allowed")
        } catch OperatorConfigError.invalid {}
    }

    func testAFragmentIsReadAsItIs() async throws {
        let (config, _) = try make()
        _ = try await put(config, "operator", #"{"minRelayFee":2}"#)
        let (fragment, _) = try await config.fragment("operator")
        XCTAssertEqual(String(decoding: fragment, as: UTF8.self), #"{"minRelayFee":2}"#)
        let (base, _) = try await config.fragment("lattice")
        XCTAssertTrue(String(decoding: base, as: UTF8.self).contains("4003"))
        do {
            _ = try await config.fragment("nothing")
            XCTFail("found")
        } catch OperatorConfigError.notFound {}
    }

    /// A chain in the hosted tree takes no spec through the API, running or
    /// not, listed or implied.
    func testALiveCreateOfAChainInTheTreeIsRefused() async throws {
        let runtime = FakeRuntime(failing: ["Nexus/A/B"])
        let (config, layout) = try make(runtime: runtime)
        let listed = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        XCTAssertEqual(listed.status.chains.first { $0.path == "Nexus/A/B" }?.actual, "notHosted")
        for path in ["Nexus/A/B", "Nexus/A"] {
            do {
                _ = try await config.create(HostedChain(path: path, spec: spec))
                XCTFail("\(path) took a spec")
            } catch OperatorConfigError.conflict {}
            XCTAssertFalse(ChainCreation.isCreated(path, layout: layout))
        }
    }

    /// `If-None-Match: *` writes a fragment only while there is none.
    func testACreateOnlyWriteIsRefusedOnceTheFragmentExists() async throws {
        let (config, _) = try make()
        _ = try await config.put("operator", data(#"{"minRelayFee":1}"#), ifMatch: nil, ifNoneMatch: "*", remote: false)
        do {
            _ = try await config.put("operator", data(#"{"minRelayFee":2}"#), ifMatch: nil, ifNoneMatch: "*", remote: false)
            XCTFail("a create-only write replaced a fragment")
        } catch OperatorConfigError.changed {}
    }
}
