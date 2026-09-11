import Foundation
import Hummingbird
import HummingbirdTesting
import Lattice
import XCTest
import cashew
@testable import LatticeNode
@testable import LatticeNodeDaemon

final class MetricsTests: XCTestCase {
    func testMetricsScrapeIsParseableExposition() async throws {
        let service = try await openService(chainPath: ["Nexus"])
        let app = makeApplication(
            service: service,
            host: "127.0.0.1",
            port: 8080,
            peers: { ExplorerPeersResponse(count: 3, peers: []) },
            processStartTime: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
        try await app.test(.router) { client in
            let response = try await client.execute(uri: "/metrics", method: .get)
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.headers[.contentType], "text/plain; version=0.0.4")
            let samples = try parseExposition(
                String(decoding: response.body.readableBytesView, as: UTF8.self)
            )
            XCTAssertEqual(samples[#"lattice_chain_tip_height{chain="Nexus",tier="validated"}"#], "0")
            XCTAssertEqual(samples[#"lattice_chain_tip_height{chain="Nexus",tier="weighed"}"#], "0")
            XCTAssertEqual(samples[#"lattice_overlay_peers{chain="Nexus"}"#], "3")
            XCTAssertEqual(samples[#"lattice_mempool_transactions{chain="Nexus"}"#], "0")
            XCTAssertEqual(samples[#"process_start_time_seconds{chain="Nexus"}"#], "1700000000.5")
        }
    }

    func testMetricsReflectAcceptedBlockAndMempool() async throws {
        let service = try await openService(chainPath: ["Nexus"])
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        let validated = #"lattice_chain_tip_height{chain="Nexus",tier="validated"}"#
        let weighed = #"lattice_chain_tip_height{chain="Nexus",tier="weighed"}"#
        let mempool = #"lattice_mempool_transactions{chain="Nexus"}"#

        try await app.test(.router) { client in
            var samples = try await scrape(client)
            XCTAssertEqual(samples[validated], "0")
            XCTAssertEqual(samples[weighed], "0")
            XCTAssertEqual(samples[mempool], "0")

            let templateResponse = try await client.execute(
                uri: "/v1/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
            )
            let template = try JSONDecoder().decode(
                MiningTemplateResponse.self,
                from: Data(templateResponse.body.readableBytesView)
            )
            let workResponse = try await client.execute(
                uri: "/v1/mining/work",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitWorkRequest(workID: template.workID, nonce: 0)
                ))
            )
            XCTAssertTrue(try JSONDecoder().decode(
                SubmitWorkResponse.self,
                from: Data(workResponse.body.readableBytesView)
            ).accepted)

            samples = try await scrape(client)
            XCTAssertEqual(samples[validated], "1")
            XCTAssertEqual(samples[weighed], "1")

            let key = CryptoUtils.generateKeyPair()
            let bodyHeader = try HeaderImpl(node: TransactionBody(
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
            ))
            let transaction = Transaction(
                signatures: [key.publicKey: try XCTUnwrap(TransactionSigning.sign(
                    bodyHeader: bodyHeader,
                    privateKeyHex: key.privateKey
                ))],
                body: bodyHeader
            )
            let submitted = try await client.execute(
                uri: "/v1/transactions",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(
                    SubmitTransactionRequest(transaction: transaction)
                ))
            )
            XCTAssertEqual(submitted.status, .ok)

            samples = try await scrape(client)
            XCTAssertEqual(samples[mempool], "1")
        }
    }

    func testMetricsEscapeOperatorSuppliedChainPath() async throws {
        // Renderer: every escape the format defines, plus a CRLF, whose line
        // feed must not survive as a raw newline inside a label value.
        let rendered = renderNodeMetrics(NodeMetricsSample(
            chainPath: ["Nexus", "a\"b\\c\nd\r\ne"],
            validatedTipHeight: 7,
            weighedTipHeight: 8,
            overlayPeers: 0,
            mempoolTransactions: 0,
            processStartTime: Date(timeIntervalSince1970: 0)
        ))
        let samples = try parseExposition(rendered)
        let chain = #"chain="Nexus/a\"b\\c\nd"# + "\r" + #"\ne""#
        XCTAssertEqual(samples["lattice_overlay_peers{\(chain)}"], "0")
        // The tiers are distinct series: validated 7, weighed 8.
        XCTAssertEqual(samples["lattice_chain_tip_height{\(chain),tier=\"validated\"}"], "7")
        XCTAssertEqual(samples["lattice_chain_tip_height{\(chain),tier=\"weighed\"}"], "8")

        // Daemon: `"` and `\` are valid chain directory atoms, so a configured
        // chain path reaches the label as-is (newline is not a valid atom).
        let service = try await openService(chainPath: ["Nexus", #"q"b\s"#])
        let app = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        try await app.test(.router) { client in
            let samples = try await scrape(client)
            XCTAssertEqual(samples[#"lattice_overlay_peers{chain="Nexus/q\"b\\s"}"#], "0")
            // An unbootstrapped child has no tip: the height samples are absent.
            XCTAssertFalse(samples.keys.contains { $0.hasPrefix("lattice_chain_tip_height") })
        }
    }

    func testMetricsSeparateWeighedTierFromValidated() async throws {
        // A block admitted on the weighed tier leads fork choice before it
        // executes: the weighed tier reads 1 while the validated tier stays at
        // genesis, so each tier is wired to its own read.
        let producer = try await openProcess(chainPath: ["Nexus"])
        let template = try await service(for: producer)
            .miningTemplate(MiningTemplateRequest())
        let produced = try await producer.admit(BlockHeader(node: template.block))
        XCTAssertTrue(produced.decision.isAccepted)

        let consumer = try await openProcess(chainPath: ["Nexus"])
        let weighed = try await consumer.admit(
            BlockHeader(node: template.block),
            remoteSource: FetcherContentSource(producer),
            mode: .weighed
        )
        XCTAssertTrue(weighed.decision.isAccepted)

        let samples = try parseExposition(
            await service(for: consumer).metricsExposition(peers: 0, processStartTime: Date())
        )
        XCTAssertEqual(samples[#"lattice_chain_tip_height{chain="Nexus",tier="validated"}"#], "0")
        XCTAssertEqual(samples[#"lattice_chain_tip_height{chain="Nexus",tier="weighed"}"#], "1")
    }

    func testMetricsAbsentOnPublicReadApplication() async throws {
        let service = try await openService(chainPath: ["Nexus"])
        let publicApp = makePublicReadApplication(service: service, host: "127.0.0.1", port: 8081)
        try await publicApp.test(.router) { client in
            let response = try await client.execute(uri: "/metrics", method: .get)
            XCTAssertEqual(response.status, .notFound)
        }
        let loopback = makeApplication(service: service, host: "127.0.0.1", port: 8080)
        try await loopback.test(.router) { client in
            let response = try await client.execute(uri: "/metrics", method: .get)
            XCTAssertEqual(response.status, .ok)
        }
    }

    private func openProcess(chainPath: [String]) async throws -> ChainProcess {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-metrics-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let parentEndpoint = try chainPath.count == 1 ? nil : ParentEndpoint(
            publicKey: NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: storage,
                privateKeyHex: String(repeating: "02", count: 32)
            ).processPublicKey,
            host: "127.0.0.1",
            port: 4002
        )
        return try await ChainProcess.open(configuration: NodeConfiguration(
            chainPath: chainPath,
            storagePath: storage,
            privateKeyHex: String(repeating: "01", count: 32),
            parentEndpoint: parentEndpoint
        ))
    }

    private func openService(chainPath: [String]) async throws -> ChainService {
        service(for: try await openProcess(chainPath: chainPath))
    }

    private func service(for process: ChainProcess) -> ChainService {
        ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
        )
    }
}

private func scrape(_ client: some TestClientProtocol) async throws -> [String: String] {
    let response = try await client.execute(uri: "/metrics", method: .get)
    XCTAssertEqual(response.status, .ok)
    return try parseExposition(String(decoding: response.body.readableBytesView, as: UTF8.self))
}

private struct ExpositionError: Error, CustomStringConvertible {
    let description: String
}

/// Parses text exposition format 0.0.4 strictly: every line is a HELP, TYPE or
/// sample line, every sample's family has HELP and TYPE declared before it,
/// and no HELP, TYPE or series repeats. Returns `series -> value`, the series
/// spelled exactly as exposed.
private func parseExposition(_ text: String) throws -> [String: String] {
    let name = "[a-zA-Z_:][a-zA-Z0-9_:]*"
    let label = #"[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\\n]|\\[\\"n])*""#
    let value = #"-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|NaN|[+-]Inf"#
    let comment = try NSRegularExpression(
        pattern: "^# (HELP|TYPE) (\(name)) (.+)$"
    )
    let sample = try NSRegularExpression(
        pattern: "^(\(name))(\\{\(label)(?:,\(label))*\\})? (\(value))$"
    )
    guard text.hasSuffix("\n") else {
        throw ExpositionError(description: "exposition must end with a line feed")
    }
    var helped: Set<String> = []
    var typed: Set<String> = []
    var samples: [String: String] = [:]
    for line in text.dropLast().split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(line)
        let range = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        if let match = comment.firstMatch(in: line, range: range), match.range == range {
            if group(match, 1) == "HELP" {
                guard helped.insert(group(match, 2)).inserted else {
                    throw ExpositionError(description: "duplicate HELP: \(line)")
                }
            } else {
                guard ["counter", "gauge", "histogram", "summary", "untyped"]
                    .contains(group(match, 3)) else {
                    throw ExpositionError(description: "bad TYPE line: \(line)")
                }
                guard typed.insert(group(match, 2)).inserted else {
                    throw ExpositionError(description: "duplicate TYPE: \(line)")
                }
            }
        } else if let match = sample.firstMatch(in: line, range: range), match.range == range {
            let family = group(match, 1)
            guard helped.contains(family), typed.contains(family) else {
                throw ExpositionError(description: "sample before HELP/TYPE: \(line)")
            }
            guard samples.updateValue(group(match, 3), forKey: family + group(match, 2)) == nil else {
                throw ExpositionError(description: "duplicate series: \(line)")
            }
        } else {
            throw ExpositionError(description: "line violates the exposition grammar: \(line)")
        }
    }
    guard !samples.isEmpty else {
        throw ExpositionError(description: "no samples")
    }
    return samples
}
