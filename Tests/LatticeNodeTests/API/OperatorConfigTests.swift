import Foundation
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
        private var inFlight = 0
        private var most = 0
        private var count = 0
        let failing: Set<String>

        var mostAtOnce: Int { lock.withLock { most } }
        var calls: Int { lock.withLock { count } }

        init(failing: Set<String> = []) { self.failing = failing }

        var hostedChildren: [[String]] { lock.withLock { hosted } }

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

    private func entry(_ path: String, _ spec: ChainSpec, premineTo: String? = nil) throws -> String {
        String(decoding: try JSONEncoder().encode(HostedChain(path: path, spec: spec, premineTo: premineTo)), as: UTF8.self)
    }

    func testConcurrentChangesApplyOneAtATimeAndAllAreKept() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let (a, b, c) = (data(#"{"hostedChains":["Nexus/A"]}"#), data(#"{"hostedChains":["Nexus/B"]}"#), data(#"{"minRelayFee":5}"#))
        async let first = config.put("deploy", a, remote: false)
        async let second = config.put("hostmarket", b, remote: false)
        async let third = config.put("operator", c, remote: false)
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
        let response = try await config.put("operator", data(#"{"hostedChains":["Nexus/A","Nexus/B"]}"#), remote: false)
        XCTAssertEqual(response.spec.hostedChains, ["Nexus/A", "Nexus/B"])
        let b = try XCTUnwrap(response.status.chains.first { $0.path == "Nexus/B" })
        XCTAssertEqual(b.actual, "notHosted")
        XCTAssertNotNil(b.error)
        XCTAssertEqual(response.status.chains.first { $0.path == "Nexus/A" }?.actual, "hosted")
        let file = try ConfigFragments.object(at: ConfigFragments.file(root: layout.root, name: "operator"))
        XCTAssertEqual(file["hostedChains"] as? [String], ["Nexus/A", "Nexus/B"], "the fragment is kept as sent")
    }

    func testAnInvalidFragmentWritesNothing() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        for refused in [
            #"{"state":"some"}"#, #"{"unknown":1}"#, #"[1]"#, #"{"rpc":4001}"#,
            #"{"peers":{"Nexus":["garbage"]}}"#, #"{"stateWindows":{"Nexus":0}}"#,
            #"{"hostedChains":["Nexus"]}"#, #"{"hostedChains":[{"path":"Nexus/A","premineTo":"x"}]}"#,
        ] {
            do {
                _ = try await config.put("operator", data(refused), remote: false)
                XCTFail("\(refused) was accepted")
            } catch OperatorConfigError.invalid {}
        }
        XCTAssertEqual(runtime.calls, 0)
        XCTAssertEqual(ConfigFragments.names(root: layout.root), [])
        for name in ["lattice", "Ops", "../x", ""] {
            do {
                _ = try await config.put(name, data("{}"), remote: false)
                XCTFail("\(name) was accepted as a name")
            } catch OperatorConfigError.invalid {}
        }
    }

    func testKeysTakingARestartAreReported() async throws {
        let (config, _) = try make()
        let response = try await config.put("deploy", data(#"{"listen":5001,"hostedChains":["Nexus/A"]}"#), remote: false)
        XCTAssertEqual(response.status.pendingRestart, ["listen"])
        XCTAssertEqual(response.spec.listen, 5001)
        // Deleting the fragment takes it back.
        let deleted = try await config.delete("deploy", remote: false)
        XCTAssertEqual(deleted.status.pendingRestart, [])
        XCTAssertEqual(deleted.spec.hostedChains, nil)
    }

    func testTheRemoteListenerNamesNoFiles() async throws {
        let (config, _) = try make()
        do {
            _ = try await config.put(
                "operator", data(#"{"operatorListen":"0.0.0.0:9000","operatorTokens":"/etc/t.json"}"#), remote: true
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

    /// A chain sent with its spec is kept under specs/ as `child create`
    /// keeps one; another layer creating it differently leaves it unhosted.
    func testChainsAreCreatedOnceAndConflictsAreTheChainsAlone() async throws {
        let (config, layout) = try make()
        _ = try await config.put("hostmarket", data(#"{"hostedChains":[\#(try entry("Nexus/A", spec))]}"#), remote: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
        // The same creation from another layer is the same chain.
        let same = try await config.put("operator", data(#"{"hostedChains":[\#(try entry("Nexus/A", spec))]}"#), remote: false)
        XCTAssertNil(same.status.chains.first { $0.path == "Nexus/A" }?.error)
        let other = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 2_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let conflict = try await config.put(
            "operator", data(#"{"hostedChains":[\#(try entry("Nexus/A", other)),"Nexus/A/B"],"minRelayFee":3}"#),
            remote: false
        )
        let a = try XCTUnwrap(conflict.status.chains.first { $0.path == "Nexus/A" })
        XCTAssertEqual(a.from, ["hostmarket", "operator"])
        XCTAssertTrue(a.error?.contains("differently") == true, "\(String(describing: a.error))")
        XCTAssertNotNil(conflict.status.chains.first { $0.path == "Nexus/A/B" }?.error, "its child waits")
        XCTAssertEqual(conflict.spec.minRelayFee, 3, "the rest of the fragment holds")
    }

    /// A chain that did not start keeps no spec: it can be sent again, with
    /// another spec if need be.
    func testAChainThatDidNotStartKeepsNoSpec() async throws {
        let (config, layout) = try make(runtime: FakeRuntime(failing: ["Nexus/A"]))
        let response = try await config.put(
            "operator", data(#"{"hostedChains":[\#(try entry("Nexus/A", spec))]}"#), remote: false
        )
        XCTAssertNotNil(response.status.chains.first { $0.path == "Nexus/A" }?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
    }

    /// A chain created once refuses another spec or premine recipient.
    func testACreatedChainRefusesAnotherCreation() async throws {
        let premined = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 10,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let (config, _) = try make()
        let first = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let second = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let created = #"{"hostedChains":[\#(try entry("Nexus/A", premined, premineTo: first))]}"#
        _ = try await config.put("operator", data(created), remote: false)
        let again = try await config.put("operator", data(created), remote: false)
        XCTAssertNil(again.status.chains.first { $0.path == "Nexus/A" }?.error)
        let refused = try await config.put(
            "operator", data(#"{"hostedChains":[\#(try entry("Nexus/A", premined, premineTo: second))]}"#), remote: false
        )
        XCTAssertTrue(refused.status.chains.first { $0.path == "Nexus/A" }?.error?.contains("created once") == true)
    }

    /// A chain hosted by path (synced from its peers) takes no spec later:
    /// one would mine a rival genesis at the next start.
    func testASpecForAChainHostedWithoutOneIsRefused() async throws {
        let (config, layout) = try make()
        _ = try await config.put("operator", data(#"{"hostedChains":["Nexus/A"]}"#), remote: false)
        let response = try await config.put(
            "hostmarket", data(#"{"hostedChains":[\#(try entry("Nexus/A", spec))]}"#), remote: false
        )
        XCTAssertNotNil(response.status.chains.first { $0.path == "Nexus/A" }?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
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
        _ = try await config.put("operator", data(#"{"minRelayFee":2}"#), remote: false)
        let fragment = try await config.fragment("operator")
        XCTAssertEqual(String(decoding: fragment, as: UTF8.self), #"{"minRelayFee":2}"#)
        let base = try await config.fragment("lattice")
        XCTAssertTrue(String(decoding: base, as: UTF8.self).contains("4003"))
        do {
            _ = try await config.fragment("nothing")
            XCTFail("found")
        } catch OperatorConfigError.notFound {}
    }
}
