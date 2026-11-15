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

    /// A running chain stops only once no layer lists it: a change (or a
    /// re-read) that would stop it otherwise is refused, the chain kept.
    func testARunningChainStopsOnlyWhenNoLayerListsIt() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/A"]}"#)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        do {
            _ = try await config.delete("deploy", ifMatch: nil, remote: false)
            XCTFail("removing Nexus/A would stop Nexus/A/B, which operator lists")
        } catch OperatorConfigError.invalid {}
        // The same rule holds for a re-read: the hand edit is not used.
        try data("{}").write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        await config.reload()
        let kept = try await config.current()
        XCTAssertTrue(kept.status.errors.contains { $0.hasPrefix("reload:") && $0.contains("Nexus/A/B") }, "\(kept.status.errors)")
        XCTAssertEqual(Set(runtime.hostedChildren.map { $0.joined(separator: "/") }), ["Nexus/A", "Nexus/A/B"])
        // Removed from every layer, it stops.
        try data(#"{"hostedChains":["Nexus/A"]}"#).write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        _ = try await config.delete("operator", ifMatch: nil, remote: false)
        XCTAssertEqual(runtime.hostedChildren.map { $0.joined(separator: "/") }, ["Nexus/A"])
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

    /// A fragment is written only as the version a client read (If-Match).
    func testAStaleVersionIsRefused() async throws {
        let (config, _) = try make()
        _ = try await put(config, "operator", #"{"minRelayFee":2}"#)
        let (_, read) = try await config.fragment("operator")
        _ = try await put(config, "operator", #"{"minRelayFee":3}"#, ifMatch: read)
        let (_, now) = try await config.fragment("operator")
        do {
            _ = try await put(config, "operator", #"{"minRelayFee":4}"#, ifMatch: read)
            XCTFail("a stale version was written")
        } catch OperatorConfigError.changed {}
        do {
            _ = try await config.delete("operator", ifMatch: read, remote: false)
            XCTFail("a stale version was removed")
        } catch OperatorConfigError.changed {}
        do {
            _ = try await put(config, "absent", "{}", ifMatch: now)
            XCTFail("If-Match on no fragment was accepted")
        } catch OperatorConfigError.changed {}
        _ = try await config.delete("operator", ifMatch: now, remote: false)
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
        let (fragment, etag) = try await config.fragment("operator")
        XCTAssertEqual(String(decoding: fragment, as: UTF8.self), #"{"minRelayFee":2}"#)
        XCTAssertEqual(etag, OperatorConfig.etag(fragment))
        let (base, _) = try await config.fragment("lattice")
        XCTAssertTrue(String(decoding: base, as: UTF8.self).contains("4003"))
        do {
            _ = try await config.fragment("nothing")
            XCTFail("found")
        } catch OperatorConfigError.notFound {}
    }

    /// A chain listed but not running (its parent waiting) takes no spec
    /// through the API either.
    func testALiveCreateOfAListedChainNotRunningIsRefused() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let listed = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        XCTAssertEqual(listed.status.chains.first { $0.path == "Nexus/A/B" }?.actual, "notHosted")
        do {
            _ = try await config.create(HostedChain(path: "Nexus/A/B", spec: spec))
            XCTFail("a listed chain took a spec")
        } catch OperatorConfigError.conflict {}
        XCTAssertFalse(ChainCreation.isCreated("Nexus/A/B", layout: layout))
    }

    /// Converging applies every layer as it is on disk: a file changed by
    /// hand and not applied yet that would stop a running, listed chain
    /// holds every change back, and the refusal names it. The chain runs on.
    func testAnUnappliedEditThatWouldStopAChainIsNamed() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/A"]}"#)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        // By hand, not read yet: deploy no longer lists Nexus/A.
        try data("{}").write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        do {
            _ = try await put(config, "hostmarket", #"{"minRelayFee":4}"#)
            XCTFail("a change that applies the edit, stopping Nexus/A/B, was accepted")
        } catch OperatorConfigError.invalid(let reason) {
            XCTAssertTrue(reason.contains("config.d/deploy.json (not applied)") && reason.contains("Nexus/A/B"), reason)
        }
        XCTAssertEqual(Set(runtime.hostedChildren.map { $0.joined(separator: "/") }), ["Nexus/A", "Nexus/A/B"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConfigFragments.file(root: layout.root, name: "hostmarket").path))
        // Fixed, the change goes through.
        try data(#"{"hostedChains":["Nexus/A"]}"#).write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        let applied = try await put(config, "hostmarket", #"{"minRelayFee":4}"#)
        XCTAssertEqual(applied.spec.minRelayFee, 4)
        // A change that itself would stop it is refused as such.
        do {
            _ = try await config.delete("deploy", ifMatch: nil, remote: false)
            XCTFail("removing Nexus/A, which Nexus/A/B needs, was accepted")
        } catch OperatorConfigError.invalid(let reason) {
            XCTAssertTrue(reason.hasPrefix("this change would stop Nexus/A/B"), reason)
        }
    }

    /// A restart is held to the same rule: it may not stop a running chain
    /// a layer still lists.
    func testARestartThatWouldStopAListedChainIsRefused() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        _ = try await put(config, "deploy", #"{"hostedChains":["Nexus/A"]}"#)
        _ = try await put(config, "operator", #"{"hostedChains":["Nexus/A/B"]}"#)
        try await config.checkRestart()
        try data("{}").write(to: ConfigFragments.file(root: layout.root, name: "deploy"))
        do {
            try await config.checkRestart()
            XCTFail("a restart that stops Nexus/A/B was allowed")
        } catch OperatorConfigError.invalid {}
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
