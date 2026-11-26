import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeNodeAPI
import UInt256

/// Mines a node as an external miner (lattice-miner) does, through its
/// mining routes alone: a template per round (`POST /mining/templates`), a
/// CPU nonce search to its `searchTarget`, and every hit submitted
/// (`POST /mining/work`); a hit that cleared only child targets keeps
/// searching the same work. It reads only the fields of the mining routes'
/// wire format that every release serves, so it mines older releases too.
/// The authorization is read again for every request, since a restarted
/// node writes a new cookie.
final class TestMiner: @unchecked Sendable {
    private let node: String
    private let authorization: @Sendable () -> String?
    private let lock = NSLock()
    private var payTo: [String: String]
    private var task: Task<Void, Never>?

    /// Mines through the node's loopback API with the cookie at `cookieFile`.
    convenience init(rpc: UInt16, cookieFile: URL, recipients: [String: String] = [:]) {
        self.init(node: "http://127.0.0.1:\(rpc)", recipients: recipients) {
            rpcCookieAuthorization(file: cookieFile)
        }
    }

    /// Mines through a node's operator listener with the token at `tokenFile`.
    convenience init(node: String, tokenFile: URL, recipients: [String: String] = [:]) {
        self.init(node: node, recipients: recipients) {
            (try? String(contentsOf: tokenFile, encoding: .utf8))
                .map { "Bearer " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    init(node: String, recipients: [String: String], authorization: @escaping @Sendable () -> String?) {
        self.node = node
        self.payTo = recipients
        self.authorization = authorization
    }

    /// Where each chain's reward goes, by chain path, from the next round;
    /// a chain left out burns it.
    var recipients: [String: String] {
        get { lock.withLock { payTo } }
        set { lock.withLock { payTo = newValue } }
    }

    func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [self] in
                while !Task.isCancelled {
                    if (try? await round()) != true {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        }
    }

    func stop() async {
        let running = lock.withLock { () -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        running?.cancel()
        await running?.value
    }

    /// One template searched; true when the node answered it.
    private func round() async throws -> Bool {
        let request = MiningTemplateRequest(recipients: recipients.sorted { $0.key < $1.key }.map {
            MiningRecipient(chainPath: $0.key.components(separatedBy: "/"), address: $0.value)
        })
        guard let template: Work = try await post("mining/templates", request) else { return false }
        let midstate = ProofOfWorkMidstate(block: template.block)
        var nonce = UInt64.random(in: 0...(UInt64.max / 2))
        for _ in 0..<Self.batchSize {
            if nonce & 0x3FF == 0 {
                if Task.isCancelled { return true }
                await Task.yield()
            }
            if midstate.hash(nonce: nonce) <= template.searchTarget {
                let submitted: Submitted? = try await post(
                    "mining/work", SubmitWorkRequest(workID: template.workID, nonce: nonce)
                )
                guard submitted?.disposition == WorkDisposition.childOnly.rawValue else { return true }
            }
            nonce &+= 1
        }
        return true
    }

    private static let batchSize: UInt64 = 100_000

    private struct Work: Decodable {
        let workID: String
        let block: Block
        let searchTarget: UInt256
    }

    private struct Submitted: Decodable {
        let disposition: String
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body) async throws -> Response? {
        var request = URLRequest(url: URL(string: "\(node)/\(path)")!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization = authorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
