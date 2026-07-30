import Crypto
import Hummingbird
import HummingbirdTesting
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon

final class DaemonHTTPTests: XCTestCase {
    func testVolumeMaintenanceInvokesEviction() async {
        let invoked = expectation(description: "volume eviction invoked")
        let counter = MaintenanceInvocationCounter()
        let task = Task {
            await runVolumeMaintenance(everyNanoseconds: 1_000_000) {
                if await counter.record() == 1 {
                    invoked.fulfill()
                }
            }
        }

        await fulfillment(of: [invoked], timeout: 1)
        task.cancel()
        await task.value

        let invocationCount = await counter.value
        XCTAssertGreaterThanOrEqual(invocationCount, 1)
    }

    func testVolumeMaintenanceCancellationStopsBeforeEviction() async {
        let counter = MaintenanceInvocationCounter()
        let task = Task {
            await runVolumeMaintenance(everyNanoseconds: 60_000_000_000) {
                _ = await counter.record()
            }
        }

        await Task.yield()
        task.cancel()
        await task.value

        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 0)
    }

    func testNexusTemplateDoesNotRequireParentReadiness() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-parent-unavailable-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let process = try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
        )
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let body = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testMiningTemplateRequestJSONDefaultsAndDeploymentMode() throws {
        let legacy = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(legacy.rewards.isEmpty)
        XCTAssertEqual(legacy.mode, .normal)

        let deployment = MiningTemplateRequest(mode: .deployment)
        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: JSONEncoder().encode(deployment)
        )
        XCTAssertTrue(decoded.rewards.isEmpty)
        XCTAssertEqual(decoded.mode, .deployment)
    }

    func testMiningTemplateAndWorkRoutesRoundTrip() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-mining-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
        )
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080
        )
        let templateRequest = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            var template: MiningTemplateResponse?
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: templateRequest)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                template = try JSONDecoder().decode(
                    MiningTemplateResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }

            let issued = try XCTUnwrap(template)
            XCTAssertEqual(issued.chainPath, ["Nexus"])
            XCTAssertEqual(issued.block.nonce, 0)
            let workRequest = try JSONEncoder().encode(SubmitWorkRequest(
                workID: issued.workID,
                nonce: 0
            ))
            try await client.execute(
                uri: "/v1/mining/work",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: workRequest)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let submitted = try JSONDecoder().decode(
                    SubmitWorkResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertTrue(submitted.accepted)
                XCTAssertEqual(submitted.disposition, .canonicalized)
                XCTAssertNotNil(submitted.tipCID)
            }

            let deploymentRequest = try JSONEncoder().encode(
                MiningTemplateRequest(mode: .deployment)
            )
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: deploymentRequest)
            ) { response in
                XCTAssertEqual(response.status, .conflict)
            }
        }
    }

    func testTransactionRoutePreservesConcreteBody() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
        )
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080
        )
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: bodyHeader,
            privateKeyHex: key.privateKey
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: signature],
            body: bodyHeader
        )
        let requestData = try JSONEncoder().encode(
            SubmitTransactionRequest(transaction: transaction)
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: requestData)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let submitted = try JSONDecoder().decode(
                    SubmitTransactionResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(
                    submitted.transactionCID,
                    try VolumeImpl<Transaction>(node: transaction).rawCID
                )
            }
        }
    }
}

private actor MaintenanceInvocationCounter {
    private var count = 0

    var value: Int { count }

    func record() -> Int {
        count += 1
        return count
    }
}
