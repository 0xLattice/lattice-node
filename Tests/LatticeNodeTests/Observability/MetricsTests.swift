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
            reads: service.reads,
            writes: service,
            status: { await service.status() },
            metrics: { service.metricsExposition(peers: $0, processStartTime: $1) },
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
                uri: "/mining/templates",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
            )
            let template = try JSONDecoder().decode(
                MiningTemplateResponse.self,
                from: Data(templateResponse.body.readableBytesView)
            )
            let workResponse = try await client.execute(
                uri: "/mining/work",
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
                receiptActions: [],
                withdrawalActions: [],
                signers: [CryptoUtils.createAddress(from: key.publicKey)],
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
                uri: "/transactions",
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

    func testMetricsExposeExecutionWalkCounters() throws {
        let rendered = renderNodeMetrics(NodeMetricsSample(
            chainPath: ["Nexus", "Payments"],
            validatedTipHeight: 1,
            weighedTipHeight: 1,
            overlayPeers: 0,
            mempoolTransactions: 0,
            processStartTime: Date(timeIntervalSince1970: 0),
            executionWalkParked: 4,
            candidateSessionReads: 5
        ))
        let samples = try parseExposition(rendered)
        let chain = "chain=\"Nexus/Payments\""
        XCTAssertEqual(samples["lattice_validate_walk_parked_total{\(chain)}"], "4")
        XCTAssertEqual(samples["lattice_candidate_session_reads_total{\(chain)}"], "5")
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

    private func openStorage(chainPath: [String]) async throws -> NodeStorage {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-metrics-test-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        return try await NodeStorage.open(configuration: NodeConfiguration(
            chainPath: chainPath,
            storagePath: storageDirectory,
            privateKeyHex: String(repeating: "01", count: 32)
        ))
    }

    private func openService(chainPath: [String]) async throws -> NodeRuntime {
        try await startRuntime(try await openStorage(chainPath: chainPath))
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
