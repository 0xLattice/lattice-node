import XCTest
@testable import LatticeNode

final class NodeShutdownTests: XCTestCase {
    /// The daemon's stop path: a running node that has just committed a
    /// block (so the commit worker and validate walk have work) shuts down,
    /// a second shutdown returns at once, and once the node is dropped
    /// nothing is left holding the process: the same storage directory
    /// reopens, which the exclusive storage lock refuses while any task
    /// still retains the old process.
    func testShutdownJoinsBackgroundWorkAndReleasesTheStore() async throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(prefix: "lattice-node-shutdown"),
            privateKeyHex: String(repeating: "01", count: 32),
            listenPort: NetworkTransportTestPorts.allocate(),
            factListenPort: NetworkTransportTestPorts.allocate(),
            rpcPort: NetworkTransportTestPorts.allocate()
        )
        var node: Node? = try await Node.build(configuration: configuration)
        let template = try await node!.service.miningTemplate(
            MiningTemplateRequest()
        )
        let submitted = try await node!.service.submitWork(SubmitWorkRequest(
            workID: template.workID,
            nonce: solvedNonce(for: template)
        ))
        XCTAssertTrue(submitted.accepted)

        await node!.shutdown()
        await node!.shutdown()
        node = nil

        let reopened = try await ChainProcess.open(configuration: configuration)
        let height = await reopened.canonicalTipHeight()
        XCTAssertEqual(height, 1)
    }
}
