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

    func testMiningTemplateRequestJSONDefaults() throws {
        let legacy = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(legacy.rewards.isEmpty)

        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: JSONEncoder().encode(MiningTemplateRequest())
        )
        XCTAssertTrue(decoded.rewards.isEmpty)
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
        }
    }

    func testBlocksRouteReturnsAcceptedBlockAndRejectsUnacceptedCID() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-blocks-test-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        // A syntactically valid CID that was never stored anywhere.
        let unknownCID = try VolumeImpl<Transaction>(node: Transaction(
            signatures: [:],
            body: try HeaderImpl(node: TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 99,
                chainPath: ["Nexus"]
            ))
        )).rawCID

        try await app.test(.router) { client in
            var template: MiningTemplateResponse?
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
            ) { response in
                template = try JSONDecoder().decode(
                    MiningTemplateResponse.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            let issued = try XCTUnwrap(template)

            var tipCID: String?
            try await client.execute(
                uri: "/v1/mining/work",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitWorkRequest(workID: issued.workID, nonce: 0)
                ))
            ) { response in
                let submitted = try JSONDecoder().decode(
                    SubmitWorkResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertTrue(submitted.accepted)
                tipCID = submitted.tipCID
            }
            let blockCID = try XCTUnwrap(tipCID)

            try await client.execute(uri: "/v1/blocks/\(blockCID)", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], immutableCacheControl)
                let decoded = try JSONDecoder().decode(
                    BlockResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(decoded.cid, blockCID)
                XCTAssertEqual(decoded.block.height, 1)
            }

            // Well-formed CID, never accepted as a block.
            try await client.execute(uri: "/v1/blocks/\(unknownCID)", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testPublicReadApplicationServesOnlyTheReadSurface() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-public-read-test-\(UUID().uuidString)"
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

        let publicApp = makePublicReadApplication(
            service: service,
            host: "127.0.0.1",
            port: 8081
        )
        try await publicApp.test(.router) { client in
            // The bounded read surface is served.
            for uri in [
                "/health", "/v1/blocks", "/api/chain/info", "/api/chain/spec",
                "/api/block/latest", "/api/peers", "/api/mempool"
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok, uri)
                }
            }
            // The operator surface does not exist here — not merely forbidden.
            try await client.execute(uri: "/v1/status", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
            for uri in ["/v1/transactions", "/v1/mining/templates", "/v1/mining/work"] {
                try await client.execute(
                    uri: uri,
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(bytes: Data("{}".utf8))
                ) { response in
                    XCTAssertEqual(response.status, .notFound, uri)
                }
            }
        }

        // The loopback application still serves the full operator surface.
        let loopback = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        try await loopback.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
            try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testExplorerBlockIDDispatchPrefersHeightOverAmbiguousCID() {
        // The premise: "161" genuinely round-trips as a canonical CID (base58
        // CIDv0, identity multihash [0x00, 0x01, 0x22]), so CID-first dispatch
        // would 404 heights 161-169, 171-179, 181-189, 191-199, 1111, ... as
        // unknown-CID lookups of their own decimal strings.
        XCTAssertTrue(isPlausibleCID("161"))

        XCTAssertEqual(explorerBlockID("161"), .height(161))
        XCTAssertEqual(explorerBlockID("0"), .height(0))
        XCTAssertEqual(explorerBlockID("18446744073709551615"), .height(UInt64.max))
        XCTAssertEqual(
            explorerBlockID(NexusGenesis.expectedBlockHash),
            .cid(NexusGenesis.expectedBlockHash)
        )
        XCTAssertEqual(explorerBlockID("not a cid"), .invalid)
        XCTAssertEqual(explorerBlockID(""), .invalid)
    }

    func testTransactionsRouteReturnsSubmittedTransactionAndRejectsNonTransactionCID() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-transactions-test-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
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
        let transactionCID = try VolumeImpl<Transaction>(node: transaction).rawCID

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitTransactionRequest(transaction: transaction)
                ))
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }

            // A refusal names itself. The operator surface is loopback-only and
            // the caller holds the signing key, so an unexplained 400 only
            // hides which rule it broke: a second transaction at the same
            // (signer, nonce) bidding no more of a real fee is replace-by-fee
            // refusing, and must say so.
            let rival = TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: key.publicKey)],
                fee: 1,
                nonce: 0,
                chainPath: ["Nexus"]
            )
            let rivalHeader = try HeaderImpl(node: rival)
            let rivalTransaction = Transaction(
                signatures: [key.publicKey: try XCTUnwrap(
                    TransactionSigning.sign(
                        bodyHeader: rivalHeader,
                        privateKeyHex: key.privateKey
                    )
                )],
                body: rivalHeader
            )
            XCTAssertNotEqual(rivalHeader.rawCID, bodyHeader.rawCID)
            try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitTransactionRequest(transaction: rivalTransaction)
                ))
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertTrue(
                    String(
                        decoding: response.body.readableBytesView, as: UTF8.self
                    ).contains("feeTooLow"),
                    "the refusal must name itself, got: \(String(decoding: response.body.readableBytesView, as: UTF8.self))"
                )
            }

            try await client.execute(
                uri: "/v1/transactions/\(transactionCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], immutableCacheControl)
                let decoded = try JSONDecoder().decode(
                    TransactionResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(decoded.cid, transactionCID)
                XCTAssertEqual(decoded.transaction.body.rawCID, transaction.body.rawCID)
            }

            // The Nexus genesis CID resolves to content, but not to a
            // Transaction — the type gate must reject it, not serve it.
            try await client.execute(
                uri: "/v1/transactions/\(configuration.nexusGenesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testMalformedCIDPathParameterIsRejectedBeforeAnyLookup() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-malformed-cid-test-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/blocks/not-a-real-cid", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(
                uri: "/v1/transactions/not-a-real-cid",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testAccountsRouteReturnsBalanceAndNonceForKnownFundedAccountAndValidatesInputs() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-accounts-test-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        // Nexus genesis premines to this fixed owner address — a known funded
        // account at an accepted block (genesis) with no code needed to mine.
        let owner = NexusGenesis.ownerAddress
        let genesisCID = configuration.nexusGenesisCID

        // A syntactically valid CID that was never accepted as a block.
        let unknownCID = try VolumeImpl<Transaction>(node: Transaction(
            signatures: [:],
            body: try HeaderImpl(node: TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 98,
                chainPath: ["Nexus"]
            ))
        )).rawCID

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/accounts/\(owner)?block=\(genesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], immutableCacheControl)
                let decoded = try JSONDecoder().decode(
                    AccountResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(decoded.owner, owner)
                XCTAssertEqual(decoded.block, genesisCID)
                XCTAssertEqual(decoded.balance, NexusGenesis.spec.premineAmount())
                XCTAssertEqual(decoded.nonce, 0)
            }

            // `block` is required.
            try await client.execute(uri: "/v1/accounts/\(owner)", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }

            // Well-formed CID, never accepted as a block.
            try await client.execute(
                uri: "/v1/accounts/\(owner)?block=\(unknownCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }

            // Malformed owner / block.
            try await client.execute(
                uri: "/v1/accounts/not-a-real-cid?block=\(genesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(
                uri: "/v1/accounts/\(owner)?block=not-a-real-cid",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testRecentBlocksRouteWalksFromTipRespectsLimitCapAndBeforeCursorHeadersOnly() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-recent-blocks-test-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let genesisCID = configuration.nexusGenesisCID

        // A syntactically valid CID that was never accepted as a block.
        let unknownCID = try VolumeImpl<Transaction>(node: Transaction(
            signatures: [:],
            body: try HeaderImpl(node: TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 97,
                chainPath: ["Nexus"]
            ))
        )).rawCID

        try await app.test(.router) { client in
            let block1 = try await mineOneBlock(client: client)
            let block2 = try await mineOneBlock(client: client)
            let block3 = try await mineOneBlock(client: client)

            try await client.execute(uri: "/v1/blocks", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], statusCacheControl)
                // Headers only: never the full body's "transactions" dictionary.
                let bodyText = String(decoding: response.body.readableBytesView, as: UTF8.self)
                XCTAssertFalse(bodyText.contains("\"transactions\""))
                let summaries = try JSONDecoder().decode(
                    [BlockSummary].self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(summaries.map(\.cid), [block3, block2, block1, genesisCID])
                XCTAssertEqual(summaries.map(\.height), [3, 2, 1, 0])
                XCTAssertEqual(summaries[0].parentCID, block2)
                XCTAssertNil(summaries[3].parentCID)
            }

            try await client.execute(uri: "/v1/blocks?limit=2", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let summaries = try JSONDecoder().decode(
                    [BlockSummary].self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(summaries.map(\.cid), [block3, block2])
            }

            try await client.execute(
                uri: "/v1/blocks?before=\(block2)&limit=2",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], immutableCacheControl)
                let summaries = try JSONDecoder().decode(
                    [BlockSummary].self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(summaries.map(\.cid), [block2, block1])
            }

            try await client.execute(uri: "/v1/blocks?before=not-a-real-cid", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(
                uri: "/v1/blocks?before=\(unknownCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
            try await client.execute(uri: "/v1/blocks?limit=0", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(uri: "/v1/blocks?limit=-1", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(uri: "/v1/blocks?limit=abc", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            // Above the hard cap: clamped, not rejected.
            try await client.execute(uri: "/v1/blocks?limit=999", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let summaries = try JSONDecoder().decode(
                    [BlockSummary].self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertLessThanOrEqual(summaries.count, 50)
            }
        }
    }

    /// The public read router is the other surface an unauthenticated caller
    /// controls outright: every path segment and query value is theirs. Swift
    /// answers a bad number with a TRAP, which takes the whole node down rather
    /// than refusing one request, and this router has already shipped one — an
    /// `offset` near `Int.max` overflowed an addition. That fix had no test.
    ///
    /// So: every parametered read route, against values chosen for the ways
    /// Swift actually fails — integer edges and one past them, sign flips,
    /// scientific and hex spellings, oversize digit runs, non-CID garbage,
    /// encoded path traversal, and a real CID for contrast — on a chain that
    /// holds real blocks, so handlers get past the cheap 404s and reach the
    /// arithmetic. Surviving is the first assertion; the second is that no
    /// route answers a caller's input with a 5xx, which would be an unhandled
    /// path even where it is not yet a crash.
    func testPublicReadRoutesSurviveHostileParameters() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-hostile-params-\(UUID().uuidString)"
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
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        // Genesis carries the premine transaction, so a transactions page on
        // it has a non-zero total and really reaches the offset arithmetic.
        let genesis = configuration.nexusGenesisCID

        let integerEdges = [
            "0", "-1", "1", "-0",
            "\(Int.max)", "9223372036854775808",
            "\(Int.min)", "-9223372036854775809",
            "\(UInt64.max)", "18446744073709551616",
            String(repeating: "9", count: 400),
            "1e9", "0x10", "+5", " 5", "5 ", "abc", "",
        ]
        let ids = integerEdges + [
            "not-a-cid",
            "bafy" + String(repeating: "z", count: 60),
            String(repeating: "a", count: 1_500),
            "\u{0}", "\u{202E}", "\u{1F4A5}", "a b",
            genesis,
        ]

        // Path parameters are NOT percent-decoded by the router — verified: a
        // real CID with its first byte written as %62 answers 400, not 200. So
        // a segment reaches the handler exactly as sent. Encode only what can
        // never legally appear in a path, so `-1`, `+5`, `1e9` and `0x10`
        // arrive raw; a NUL, a space or an emoji still has to be escaped,
        // because no real client can put one in a path any other way.
        var pathSegmentAllowed = CharacterSet.urlPathAllowed
        pathSegmentAllowed.remove(charactersIn: "/")
        func pathSegment(_ raw: String) -> String {
            raw.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? ""
        }
        // Query values ARE decoded, so escaping everything is what delivers
        // the intended value to the handler there.
        func queryValue(_ raw: String) -> String {
            raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        // The whole point of `pathSegment`: these must reach the handler raw.
        // If they came back escaped the path cases would silently test `%2D1`.
        for raw in ["-1", "+5", "1e9", "0x10", "\(Int.min)", "\(UInt64.max)"] {
            XCTAssertEqual(pathSegment(raw), raw, "\(raw) must be sent unescaped")
        }
        // Already-escaped as an attacker sends them. Re-encoding would turn
        // `%2F` into `%252F` and test a string nobody sends.
        let wireLiteralSegments = [
            "..%2F..%2Fetc%2Fpasswd", "%2e%2e%2f", "%00", "%FF%FE", "..",
        ]

        var uris: [String] = []
        for segment in ids.map(pathSegment) + wireLiteralSegments {
            // An empty segment would route to a different handler entirely,
            // which tests the router, not the parameter.
            guard !segment.isEmpty else { continue }
            uris += [
                "/api/block/\(segment)",
                "/api/block/\(segment)/transactions",
                "/api/block/\(segment)/children",
                "/api/transaction/\(segment)",
                "/api/state/account/\(segment)",
                "/v1/blocks/\(segment)",
                "/v1/transactions/\(segment)",
                "/v1/accounts/\(segment)?block=\(genesis)",
            ]
        }
        for value in integerEdges {
            let query = queryValue(value)
            uris += [
                "/api/block/\(genesis)/transactions?offset=\(query)",
                "/api/block/\(genesis)/transactions?limit=\(query)",
                "/api/block/\(genesis)/transactions?offset=\(query)&limit=\(query)",
                "/v1/blocks?limit=\(query)",
                "/v1/blocks?before=\(query)",
                "/v1/accounts/\(genesis)?block=\(query)",
                "/api/chain/children?limit=\(query)",
                "/api/block/latest?chainPath=\(query)",
            ]
        }

        let matrix = uris
        try await app.test(.router) { client in
            _ = try await mineOneBlock(client: client)
            _ = try await mineOneBlock(client: client)

            // The one this router already shipped: offset near Int.max on a
            // page with real transactions. Named so a regression says so.
            try await client.execute(
                uri: "/api/block/\(genesis)/transactions?offset=\(Int.max)&limit=\(Int.max)",
                method: .get
            ) { response in
                XCTAssertLessThan(
                    response.status.code, 500,
                    "offset=Int.max must be refused or answered empty, never overflow"
                )
            }

            var statuses = Set<Int>()
            for uri in matrix {
                try await client.execute(uri: uri, method: .get) { response in
                    statuses.insert(response.status.code)
                    XCTAssertLessThan(
                        response.status.code, 500,
                        "\(uri) answered \(response.status): a caller's input reached an unhandled path"
                    )
                }
            }
            // Reaching here means no request trapped. That alone would still
            // pass if a routing change sent the whole matrix to 404, so require
            // evidence that it hit real handlers: one that SERVED (the genesis
            // CID is in the matrix) and one that PARSED and REJECTED input.
            XCTAssertTrue(
                statuses.contains(200),
                "nothing was served: the matrix never reached a working handler \(statuses)"
            )
            XCTAssertTrue(
                statuses.contains(400),
                "nothing was rejected as bad input: handlers never parsed the matrix \(statuses)"
            )
        }
    }

    func testReadSnapshotMatchesStatusAndNeverBlocksBehindTheOperationGate() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-readsnapshot-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let providerEntered = AsyncGate()
        let releaseProvider = AsyncGate()
        let service = ChainService(
            process: process,
            // Invoked from inside `buildMiningTemplate()` while `miningTemplate()`
            // still holds the operation gate — parking here lets the test hold
            // that gate open for a controlled duration.
            childCandidateProvider: { _ in
                await providerEntered.open()
                await releaseProvider.wait()
                return []
            },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
        )
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        let blockedTemplate = Task {
            _ = try? await service.miningTemplate(MiningTemplateRequest())
        }
        await providerEntered.wait()

        // A concurrent call to the GATED status() must queue behind the
        // in-flight mining-template build.
        let statusCompleted = CompletionFlag()
        let blockedStatus = Task { () -> ChainServiceStatusResponse in
            let result = await service.status()
            await statusCompleted.markDone()
            return result
        }
        // Give the queued status() call a chance to actually reach (and
        // block on) the gate before we check it hasn't finished.
        try await Task.sleep(nanoseconds: 100_000_000)
        let finishedEarly = await statusCompleted.isDone
        XCTAssertFalse(finishedEarly, "status() must still be queued behind the held operation gate")

        // The UNGATED read must return promptly regardless — over HTTP, the
        // very surface under test — while the gate is still fully held. /health
        // is the public non-mutating status endpoint (readSnapshot); /v1/status
        // stays on the gated, reconciling status().
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], statusCacheControl)
                let snapshot = try JSONDecoder().decode(
                    ChainServiceStatusResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(snapshot.phase, .active)
            }
        }

        let directSnapshot = await service.readSnapshot()
        XCTAssertEqual(directSnapshot.phase, .active)

        // Release the held gate and confirm both blocked operations then
        // complete, proving the earlier non-completion was real contention.
        await releaseProvider.open()
        _ = await blockedTemplate.value
        let gatedStatus = await blockedStatus.value
        XCTAssertEqual(directSnapshot.tipCID, gatedStatus.tipCID)
        XCTAssertEqual(directSnapshot.height, gatedStatus.height)
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

/// Mines exactly one block atop the current tip via the public template/work
/// routes (target is genesis-max, so nonce 0 always satisfies it) and returns
/// the new tip's CID.
private func mineOneBlock(client: some TestClientProtocol) async throws -> String {
    var template: MiningTemplateResponse?
    try await client.execute(
        uri: "/v1/mining/templates",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
    ) { response in
        template = try JSONDecoder().decode(
            MiningTemplateResponse.self,
            from: Data(response.body.readableBytesView)
        )
    }
    let issued = try XCTUnwrap(template)
    var tipCID: String?
    try await client.execute(
        uri: "/v1/mining/work",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(
            SubmitWorkRequest(workID: issued.workID, nonce: 0)
        ))
    ) { response in
        let submitted = try JSONDecoder().decode(
            SubmitWorkResponse.self,
            from: Data(response.body.readableBytesView)
        )
        XCTAssertTrue(submitted.accepted)
        tipCID = submitted.tipCID
    }
    return try XCTUnwrap(tipCID)
}

private actor MaintenanceInvocationCounter {
    private var count = 0

    var value: Int { count }

    func record() -> Int {
        count += 1
        return count
    }
}

/// A one-shot async signal: `wait()` suspends until `open()` is called (from
/// any point, before or after).
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor CompletionFlag {
    private(set) var isDone = false

    func markDone() { isDone = true }
}
