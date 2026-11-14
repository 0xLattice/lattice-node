import Foundation
import Lattice
import LatticeCtlCore
import LatticeNodeAPI
import XCTest
@testable import LatticeNodeDaemon

/// The node's own configuration (`--root`): changes applied one at a time,
/// checked before anything is applied or written, and written as what took
/// effect.
final class OperatorConfigTests: XCTestCase {
    /// Hosts what it is told, except `failing`, one call at a time or not.
    private final class FakeRuntime: HostingRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var hosted: [[String]] = []
        private var inFlight = 0
        private(set) var mostAtOnce = 0
        private(set) var calls = 0
        let failing: Set<String>

        init(failing: Set<String> = []) { self.failing = failing }

        var hostedChildren: [[String]] { lock.withLock { hosted } }

        func host(_ next: HostedChildren) async throws {
            lock.withLock {
                inFlight += 1
                calls += 1
                mostAtOnce = max(mostAtOnce, inFlight)
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

    private final class FakeMining: MiningControl, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var applied: [TopologyMine?] = []
        func check(_ mine: TopologyMine?) throws {}
        func apply(_ mine: TopologyMine?) async { lock.withLock { applied.append(mine) } }
    }

    private func make(
        _ json: String = #"{"listen":4001,"rpc":4003,"peers":[]}"#, runtime: FakeRuntime = FakeRuntime(),
        mining: FakeMining = FakeMining()
    ) throws -> (OperatorConfig, HostLayout) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(json.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        let layout = HostLayout(root: root.path)
        let config = OperatorConfig(
            layout: layout, started: try Topology.load(root: root).validated(), runtime: runtime, mining: mining
        )
        return (config, layout)
    }

    private func patch(_ json: String) -> Data { Data(json.utf8) }

    func testConcurrentChangesApplyOneAtATimeAndAllAreKept() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let c = patch(#"{"stateWindow":null,"minRelayFee":5}"#)
        async let first = config.host(HostedChain(path: "Nexus/A"))
        async let second = config.host(HostedChain(path: "Nexus/B"))
        async let third = config.patch(c, remote: false)
        _ = try await (first, second, third)
        XCTAssertEqual(runtime.mostAtOnce, 1, "no two changes were applied at once")
        let kept = try Topology.load(root: layout.root)
        XCTAssertEqual(Set(kept.hostedChains ?? []), ["Nexus/A", "Nexus/B"])
        XCTAssertEqual(kept.minRelayFee, 5)
        XCTAssertEqual(Set(runtime.hostedChildren.map { $0.joined(separator: "/") }), ["Nexus/A", "Nexus/B"])
    }

    func testAPartlyAppliedChangeIsKeptAsApplied() async throws {
        let runtime = FakeRuntime(failing: ["Nexus/B"])
        let (config, layout) = try make(runtime: runtime)
        let response = try await config.patch(
            patch(#"{"hostedChains":["Nexus/A","Nexus/B"],"mine":{"recipients":{"Nexus/B":"x"}}}"#), remote: false
        )
        XCTAssertEqual(response.failed.map(\.chain), ["Nexus/B"])
        XCTAssertEqual(response.config.hostedChains, ["Nexus/A"])
        let kept = try Topology.load(root: layout.root)
        XCTAssertEqual(kept.hostedChains, ["Nexus/A"], "what runs is what a restart hosts")
        XCTAssertEqual(kept.mine?.recipients, [:], "nothing names the chain that did not start")
        XCTAssertNoThrow(try kept.validated())
    }

    func testAnInvalidChangeAppliesAndWritesNothing() async throws {
        let runtime = FakeRuntime()
        let (config, layout) = try make(runtime: runtime)
        let before = try Data(contentsOf: layout.root.appendingPathComponent(Topology.fileName))
        for refused in [
            #"{"mine":{"recipients":{"Nexus/Unhosted":"x"}}}"#, #"{"state":"some"}"#, #"{"unknown":1}"#,
            #"{"hostedChains":["Nexus/A/B"]}"#, #"{"rpc":4001}"#,
        ] {
            do {
                _ = try await config.patch(patch(refused), remote: false)
                XCTFail("\(refused) was accepted")
            } catch OperatorConfigError.invalid {}
        }
        XCTAssertEqual(runtime.calls, 0)
        XCTAssertEqual(try Data(contentsOf: layout.root.appendingPathComponent(Topology.fileName)), before)
    }

    func testKeysTakingARestartAreKeptAndReported() async throws {
        let mining = FakeMining()
        let (config, layout) = try make(mining: mining)
        let response = try await config.patch(patch(#"{"listen":5001,"mine":{"enabled":true}}"#), remote: false)
        XCTAssertEqual(response.applied, ["mine"])
        XCTAssertEqual(response.restartRequired, ["listen"])
        XCTAssertEqual(mining.applied.last??.enabled, true)
        XCTAssertEqual(try Topology.load(root: layout.root).listen, 5001)
        let current = try await config.current()
        XCTAssertEqual(current.restartRequired, ["listen"])
    }

    func testTheRemoteListenerNamesNoFiles() async throws {
        let (config, _) = try make()
        for refused in [#"{"mine":{"worker":"/bin/sh"}}"#, #"{"operatorListen":"0.0.0.0:9000","operatorTokens":"/etc/t.json"}"#] {
            do {
                _ = try await config.patch(patch(refused), remote: true)
                XCTFail("\(refused) was accepted")
            } catch OperatorConfigError.invalid {}
        }
    }

    func testAHandEditWhileRunningIsNotOverwritten() async throws {
        let (config, layout) = try make()
        try Data(#"{"listen":4001,"rpc":4003,"peers":[],"minRelayFee":9}"#.utf8)
            .write(to: layout.root.appendingPathComponent(Topology.fileName))
        do {
            _ = try await config.patch(patch(#"{"minRelayFee":2}"#), remote: false)
            XCTFail("the edit was overwritten")
        } catch OperatorConfigError.conflict {}
        XCTAssertEqual(try Topology.load(root: layout.root).minRelayFee, 9)
    }

    /// A chain sent with its spec is kept under specs/ as `child create`
    /// keeps one; the same request again changes nothing, another spec is
    /// refused; unhosting drops what names it, children first.
    func testChainsAreCreatedOnceAndUnhosted() async throws {
        let (config, layout) = try make()
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        _ = try await config.host(HostedChain(path: "Nexus/A", spec: spec))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
        let again = try await config.host(HostedChain(path: "Nexus/A", spec: spec))
        XCTAssertEqual(again.applied, [])
        let other = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: 2_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        do {
            _ = try await config.host(HostedChain(path: "Nexus/A", spec: other))
            XCTFail("a second spec was accepted")
        } catch OperatorConfigError.conflict {}
        _ = try await config.host(HostedChain(path: "Nexus/A/B"))
        _ = try await config.patch(patch(#"{"mine":{"recipients":{"Nexus/A/B":"x"}}}"#), remote: false)
        do {
            _ = try await config.unhost("Nexus/A")
            XCTFail("a parent was unhosted under its child")
        } catch OperatorConfigError.conflict {}
        _ = try await config.unhost("Nexus/A/B")
        let kept = try Topology.load(root: layout.root)
        XCTAssertEqual(kept.hostedChains, ["Nexus/A"])
        XCTAssertEqual(kept.mine?.recipients, [:])
    }
}
