import XCTest
import LatticeCtlCore

final class LatticeCtlTopologyTests: XCTestCase {
    private func chain(
        _ base: UInt16
    ) -> TopologyChain {
        TopologyChain(listen: base, fact: base + 1, rpc: base + 2)
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

    func testValidationRejectsPortCollisions() {
        XCTAssertThrowsError(try Topology(chains: [
            "Nexus": chain(4001),
            "Nexus/Payments": chain(4002),
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
                batchSize: 1_000, rewards: "rewards.jsonl"
            )
        )
        try topology.save(root: root)
        let loaded = try Topology.load(root: root).validated()
        XCTAssertEqual(loaded.chains["Nexus"]?.listen, 4001)
        XCTAssertEqual(loaded.mine?.batchSize, 1_000)
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
