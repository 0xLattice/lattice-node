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
    func testNexusTemplateDoesNotRequireParentReadiness() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-parent-unavailable-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let body = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    /// A web page can send a cross-origin "simple" POST (no preflight) or
    /// reach the loopback listener under a rebound hostname: the operator
    /// write routes refuse both before touching the service.
    func testOperatorWritesRefuseNonJSONBodiesAndForeignHosts() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-csrf-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let storage = try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let body = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            for contentType in ["text/plain", "application/x-www-form-urlencoded"] {
                try await client.execute(
                    uri: "/mining/templates",
                    method: .post,
                    headers: [.contentType: contentType],
                    body: ByteBuffer(bytes: body)
                ) { response in
                    XCTAssertEqual(response.status, .unsupportedMediaType)
                }
            }
            var foreign = HTTPFields()
            foreign[.contentType] = "application/json"
            foreign.append(.init(name: .init("Host")!, value: "rebound.example:8080"))
            try await client.execute(
                uri: "/mining/templates",
                method: .post,
                headers: foreign,
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .forbidden)
            }
            try await client.execute(
                uri: "/mining/templates",
                method: .post,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: ByteBuffer(bytes: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testMiningTemplateRequestJSONDefaults() throws {
        let empty = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data("{}".utf8)
        )
        XCTAssertTrue(empty.recipients.isEmpty)

        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: JSONEncoder().encode(MiningTemplateRequest())
        )
        XCTAssertTrue(decoded.recipients.isEmpty)

        XCTAssertThrowsError(try JSONDecoder().decode(
            MiningTemplateRequest.self,
            from: Data(#"{"mode":"deployment"}"#.utf8)
        ))
    }

    func testMiningTemplateAndWorkRoutesRoundTrip() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-mining-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080
        )
        let templateRequest = try JSONEncoder().encode(MiningTemplateRequest())

        try await app.test(.router) { client in
            var template: MiningTemplateResponse?
            try await client.execute(
                uri: "/mining/templates",
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
                uri: "/mining/work",
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

    func testPublicReadApplicationServesOnlyTheReadSurface() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-public-read-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)

        let publicApp = makePublicReadApplication(
            service: service,
            host: "127.0.0.1",
            port: 8081
        )
        try await publicApp.test(.router) { client in
            // The bounded read surface is served.
            for uri in [
                "/health", "/api/chain/info", "/api/chain/spec",
                "/api/block/latest", "/api/blocks", "/api/peers", "/api/mempool"
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok, uri)
                }
            }
            // The operator surface does not exist here — not merely forbidden.
            try await client.execute(uri: "/status", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
            // Nor do the removed block routes: blocks are read through /api/block.
            for uri in ["/blocks", "/blocks/\(configuration.nexusGenesisCID)"] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .notFound, uri)
                }
            }
            for uri in ["/transactions", "/mining/templates", "/mining/work"] {
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
            try await client.execute(uri: "/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
            try await client.execute(uri: "/v1/status", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
            try await client.execute(
                uri: "/mining/templates",
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
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-transactions-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let key = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
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
                uri: "/transactions",
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
            // A different body at the same (signer, nonce) that nets the
            // miner nothing more: its debit is returned to the signer.
            let signer = CryptoUtils.createAddress(from: key.publicKey)
            let rival = TransactionBody(
                accountActions: [
                    AccountAction(owner: signer, delta: -1),
                    AccountAction(owner: signer, delta: 1),
                ],
                actions: [],
                depositActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: key.publicKey)],
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
                uri: "/transactions",
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
                uri: "/transactions/\(transactionCID)",
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
                uri: "/transactions/\(configuration.nexusGenesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testTransactionForAnUnhostedChainReturns404AndDoesNotEnterNexusPool() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-unknown-chain-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let key = CryptoUtils.generateKeyPair()
        let body = try HeaderImpl(node: TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
            nonce: 0,
            chainPath: ["Nexus", "NotHosted"]
        ))
        let transaction = Transaction(
            signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                bodyHeader: body,
                privateKeyHex: key.privateKey
            ))],
            body: body
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitTransactionRequest(transaction: transaction)
                ))
            ) { response in
                XCTAssertEqual(response.status, .notFound)
                XCTAssertTrue(
                    String(decoding: response.body.readableBytesView, as: UTF8.self)
                        .contains("unknownChain")
                )
            }
        }

        let status = await service.status()
        XCTAssertEqual(status.mempoolCount, 0)
    }

    func testMalformedCIDPathParameterIsRejectedBeforeAnyLookup() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-malformed-cid-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/transactions/not-a-real-cid",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testAccountsRouteReturnsBalanceAndNonceForKnownFundedAccountAndValidatesInputs() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-accounts-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
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
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                nonce: 98,
                chainPath: ["Nexus"]
            ))
        )).rawCID

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/accounts/\(owner)?block=\(genesisCID)",
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
            try await client.execute(uri: "/accounts/\(owner)", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }

            // Well-formed CID, never accepted as a block.
            try await client.execute(
                uri: "/accounts/\(owner)?block=\(unknownCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .notFound)
            }

            // Malformed owner / block.
            try await client.execute(
                uri: "/accounts/not-a-real-cid?block=\(genesisCID)",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await client.execute(
                uri: "/accounts/\(owner)?block=not-a-real-cid",
                method: .get
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
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
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-hostile-params-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
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
                "/transactions/\(segment)",
                "/accounts/\(segment)?block=\(genesis)",
            ]
        }
        for value in integerEdges {
            let query = queryValue(value)
            uris += [
                "/api/block/\(genesis)/transactions?offset=\(query)",
                "/api/block/\(genesis)/transactions?limit=\(query)",
                "/api/block/\(genesis)/transactions?offset=\(query)&limit=\(query)",
                "/accounts/\(genesis)?block=\(query)",
                "/api/block/latest?chainPath=\(query)",
                "/api/blocks?before=\(query)",
                "/api/blocks?limit=\(query)",
                "/api/blocks?before=\(query)&limit=\(query)",
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

    func testBlocksRoutePagesSummariesAndValidatesQuery() async throws {
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: temporaryDirectory(prefix: "lattice-http-blocks"),
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        try await app.test(.router) { client in
            _ = try await mineOneBlock(client: client)
            _ = try await mineOneBlock(client: client)
            func page(_ uri: String) async throws -> ExplorerBlocksPage {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok, uri)
                    return try JSONDecoder().decode(
                        ExplorerBlocksPage.self, from: Data(response.body.readableBytesView)
                    )
                }
            }
            let all = try await page("/api/blocks")
            XCTAssertEqual(all.blocks.map(\.height), [2, 1, 0])
            XCTAssertEqual(all.blocks.last?.hash, configuration.nexusGenesisCID)
            let older = try await page("/api/blocks?before=2&limit=1")
            XCTAssertEqual(older.blocks.map(\.height), [1])
            XCTAssertEqual(older.nextBefore, 1)
            let pastTip = try await page("/api/blocks?before=99999&limit=500")
            XCTAssertEqual(pastTip, all)
            let explicit = try await page("/api/blocks?chainPath=Nexus")
            XCTAssertEqual(explicit, all)
            // No `rewardCredited` on the wire: the list reads no body.
            try await client.execute(uri: "/api/blocks", method: .get) { response in
                XCTAssertFalse(String(buffer: response.body).contains("rewardCredited"))
            }
            for uri in [
                "/api/blocks?before=-1", "/api/blocks?before=abc",
                "/api/blocks?limit=0", "/api/blocks?limit=-3",
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .badRequest, uri)
                }
            }
            try await client.execute(uri: "/api/blocks?chainPath=Nexus/Nope", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }
    }

    func testTransactionRoutePreservesConcreteBody() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-http-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        let service = try await startRuntime(storage)
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
            receiptActions: [],
            withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: key.publicKey)],
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
                uri: "/transactions",
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
/// routes, solving the issued template, and returns the new tip's CID.
private func mineOneBlock(client: some TestClientProtocol) async throws -> String {
    var template: MiningTemplateResponse?
    try await client.execute(
        uri: "/mining/templates",
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
        uri: "/mining/work",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(
            SubmitWorkRequest(workID: issued.workID, nonce: solvedNonce(for: issued))
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

private actor CompletionFlag {
    private(set) var isDone = false

    func markDone() { isDone = true }
}
