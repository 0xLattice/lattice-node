import Foundation
#if canImport(Glibc)
import Glibc
#endif
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

    private final class FakeMining: MiningControl, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [TopologyMine?] = []
        /// Refuses every `mine` section, as a host without its worker does.
        let refusing: Bool

        init(refusing: Bool = false) { self.refusing = refusing }

        var applied: [TopologyMine?] { lock.withLock { list } }
        func check(_ mine: TopologyMine?) throws {
            if refusing { throw OperatorConfigError.invalid("mine.worker is not executable here") }
        }
        func apply(_ mine: TopologyMine?) async { lock.withLock { list.append(mine) } }
    }

    private func make(
        _ json: String = #"{"listen":4001,"rpc":4003,"peers":[]}"#, runtime: FakeRuntime = FakeRuntime(),
        mining: FakeMining = FakeMining(),
        startCheck: @escaping @Sendable (Topology, HostLayout, Topology) throws -> Void = checkStarts
    ) throws -> (OperatorConfig, HostLayout) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operator-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(json.utf8).write(to: root.appendingPathComponent(Topology.fileName))
        let layout = HostLayout(root: root.path)
        let config = OperatorConfig(
            layout: layout, started: try Topology.load(root: root).validated(), runtime: runtime, mining: mining,
            startCheck: startCheck
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

    private let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
        targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
    )

    /// What the node would not start from is not kept, so a restart cannot
    /// take the node (and its remote control) down.
    func testAChangeTheNodeWouldNotStartFromIsRefused() async throws {
        let (config, layout) = try make()
        let before = try Data(contentsOf: layout.root.appendingPathComponent(Topology.fileName))
        // A port another process holds.
        #if canImport(Darwin)
        let held = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let held = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        defer { close(held) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Self.bindSocket(held, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = Self.listenSocket(held, 1)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(held, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        for refused in [
            #"{"peers":{"Nexus":["garbage"]}}"#, #"{"peers":{"Nexus":["key@host"]}}"#,
            #"{"rpc":\#(port)}"#, #"{"operatorListen":"127.0.0.1:\#(port)","operatorTokens":"t.json"}"#,
            #"{"stateWindows":{"Nexus":0}}"#,
        ] {
            do {
                _ = try await config.patch(patch(refused), remote: false)
                XCTFail("\(refused) was accepted")
            } catch OperatorConfigError.invalid {}
        }
        XCTAssertEqual(try Data(contentsOf: layout.root.appendingPathComponent(Topology.fileName)), before)
    }

    #if canImport(Darwin)
    private static let bindSocket = Darwin.bind
    private static let listenSocket = Darwin.listen
    #else
    private static let bindSocket = Glibc.bind
    private static let listenSocket = Glibc.listen
    #endif

    /// A restart reads the file afresh: one that would not start is refused.
    func testARestartIntoAConfigurationThatWouldNotStartIsRefused() async throws {
        let (config, layout) = try make()
        try await config.checkRestart()
        try Data(#"{"listen":4001,"rpc":4003,"peers":["garbage"]}"#.utf8)
            .write(to: layout.root.appendingPathComponent(Topology.fileName))
        do {
            try await config.checkRestart()
            XCTFail("a restart into a bad file was allowed")
        } catch OperatorConfigError.conflict {}
        let (checked, _) = try make(startCheck: { _, _, _ in throw CtlError("would not start") })
        do {
            try await checked.checkRestart()
            XCTFail("a restart that would not start was allowed")
        } catch OperatorConfigError.conflict {}
    }

    /// A refused request leaves no files, so the path stays free.
    func testARefusedCreationLeavesNoSpec() async throws {
        let (config, layout) = try make(startCheck: { _, _, _ in throw CtlError("would not start") })
        do {
            _ = try await config.host(HostedChain(path: "Nexus/A", spec: spec))
            XCTFail("accepted")
        } catch OperatorConfigError.invalid {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
        // Nor a request the hand-edited file refuses.
        let (edited, editedLayout) = try make()
        try Data(#"{"listen":4001,"rpc":4003,"peers":[],"minRelayFee":9}"#.utf8)
            .write(to: editedLayout.root.appendingPathComponent(Topology.fileName))
        do {
            _ = try await edited.host(HostedChain(path: "Nexus/A", spec: spec))
            XCTFail("accepted")
        } catch OperatorConfigError.conflict {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: editedLayout.childSpec(for: "Nexus/A").path))
    }

    /// A chain that did not start keeps no spec: it can be sent again, with
    /// another spec if need be.
    func testAChainThatDidNotStartKeepsNoSpec() async throws {
        let (config, layout) = try make(runtime: FakeRuntime(failing: ["Nexus/A"]))
        let response = try await config.host(HostedChain(path: "Nexus/A", spec: spec, premineTo: nil))
        XCTAssertEqual(response.failed.map(\.chain), ["Nexus/A"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.childSpec(for: "Nexus/A").path))
    }

    /// The same spec with another premine recipient is another chain.
    func testTheSameSpecWithAnotherPremineIsRefused() async throws {
        let premined = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 10,
            targetBlockTime: 1_000, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
        let (config, _) = try make()
        let first = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let second = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        _ = try await config.host(HostedChain(path: "Nexus/A", spec: premined, premineTo: first))
        let again = try await config.host(HostedChain(path: "Nexus/A", spec: premined, premineTo: first))
        XCTAssertEqual(again.applied, [])
        do {
            _ = try await config.host(HostedChain(path: "Nexus/A", spec: premined, premineTo: second))
            XCTFail("another premine recipient was accepted")
        } catch OperatorConfigError.conflict {}
    }

    /// Mining is checked when `mine` changes, not on every change: a host
    /// whose worker went missing still takes other keys.
    func testMiningIsCheckedOnlyWhenItChanges() async throws {
        let (config, _) = try make(
            #"{"listen":4001,"rpc":4003,"peers":[],"mine":{"enabled":true}}"#, mining: FakeMining(refusing: true)
        )
        _ = try await config.patch(patch(#"{"minRelayFee":3}"#), remote: false)
        do {
            _ = try await config.patch(patch(#"{"mine":{"workers":2}}"#), remote: false)
            XCTFail("a mine change was not checked")
        } catch OperatorConfigError.invalid {}
    }
}
