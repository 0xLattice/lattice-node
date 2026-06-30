// lattice-mining-coordinator: node-facing mining coordinator.
//
// The coordinator fetches node work, allocates nonce ranges to workers,
// handles stale work/result races, and submits workId+nonce+hash to the node.
// Workers run in-process by default, or as LatticeMiner subprocesses when
// --worker-executable is supplied (the process-backed E2E mining gate).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeMiningCoordinator

@available(macOS 15.0, *)
@main
struct LatticeMiningCoordinatorTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-mining-coordinator",
        abstract: "Coordinate proof-of-work nonce search for lattice-node."
    )

    @Option(name: .long, help: "RPC base URL of the node (e.g. http://127.0.0.1:8000/api)")
    var node: String

    @Option(name: .long, parsing: .upToNextOption, help: "Full chain path to mine. Omit to use the queried node's current path.")
    var chainPath: [String] = []

    @Option(name: .long, help: "RPC base URL of a child chain node (repeatable)")
    var childNode: [String] = []

    @Option(name: .customLong("child-rpc-cookie-file"), help: "Path to a child node RPC .cookie file, aligned with --child-node order (repeatable)")
    var childRPCCookieFile: [String] = []

    @Option(name: .customLong("child-rpc-token"), help: "Bearer token for a child node RPC, aligned with --child-node order (repeatable)")
    var childRPCToken: [String] = []

    @Option(name: .long, help: "Parallel worker count (default: CPU count - 1)")
    var workers: Int = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)

    @Option(name: .long, help: "Nonce batch size per worker per coordinator iteration. Each batch (re)launches the worker, so a GPU/external worker wants a LARGE value (≈1e9+) or the run is dominated by worker startup, not hashing. Defaults: 10000 for the in-process CPU worker, 2000000000 when --worker-executable is set.")
    var batchSize: UInt64?

    @Option(name: .long, help: "Path to the LatticeMiner worker executable. When set, nonce search runs in worker subprocesses instead of in-process.")
    var workerExecutable: String?

    @Option(name: .long, help: "Path to the miner identity JSON used only to select a reward payout address.")
    var identityFile: String?

    @Option(name: .long, help: "Path to the node RPC .cookie file for privileged template/work requests")
    var rpcCookieFile: String?

    @Option(name: .long, help: "Bearer token for privileged node RPC requests")
    var rpcToken: String?

    @Flag(name: .long, help: "Run exactly one coordinator batch (emitting a JSON result) and exit.")
    var once = false

    @Flag(name: .long, help: "Disable the best-effort freshness probe for this run.")
    var noStaleProbe = false

    @Option(name: .long, help: "Minimum milliseconds between accepted blocks (paces production for realistic block time; 0 = unthrottled).")
    var minBlockIntervalMs: UInt64 = 0

    func run() async throws {
        // NOTE: stdout block-buffers to a non-TTY, so a running miner can look hung in
        // container/journald logs (output only flushes on clean exit, lost on SIGKILL).
        // Run under `stdbuf -oL -eL` (the GPU image entrypoint does) for live progress.
        guard let apiBaseURL = URL(string: node) else {
            throw ValidationError("Invalid --node URL: \(node)")
        }
        let workerCount = max(workers, 1)
        // Per-batch the worker process is (re)launched, so a tiny batch on an external
        // worker spends all its time on startup. Default large for external workers,
        // small for the in-process CPU worker; an explicit --batch-size always wins.
        let resolvedBatchSize = batchSize ?? (workerExecutable != nil ? 2_000_000_000 : 10_000)
        // Validate auth config once at startup (fail fast on a missing/unreadable/empty
        // cookie), then re-read it on EVERY request via providers below — so a node that
        // regenerates its RPC cookie on restart is picked up automatically, instead of the
        // coordinator spinning forever on a stale token.
        _ = try Self.resolveAuthToken(token: rpcToken, cookieFile: rpcCookieFile, flag: "--rpc-cookie-file")
        _ = try Self.resolveChildAuth(childNodes: childNode, tokens: childRPCToken, cookieFiles: childRPCCookieFile)
        let rpcTokenValue = rpcToken
        let rpcCookieFileValue = rpcCookieFile
        let childNodeValue = childNode
        let childRPCTokenValue = childRPCToken
        let childRPCCookieFileValue = childRPCCookieFile
        let authTokenProvider: @Sendable () -> String? = {
            Self.currentAuthToken(token: rpcTokenValue, cookieFile: rpcCookieFileValue)
        }
        let childNodeAuthProvider: @Sendable () -> [String: String] = {
            Self.currentChildAuth(childNodes: childNodeValue, tokens: childRPCTokenValue, cookieFiles: childRPCCookieFileValue)
        }
        let rewardIdentity = try identityFile.map(Self.loadRewardIdentity(path:))
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: apiBaseURL,
            chainPath: chainPath.isEmpty ? nil : chainPath,
            childNodes: childNode,
            childNodeAuthProvider: childNodeAuthProvider,
            rewardIdentity: rewardIdentity,
            authTokenProvider: authTokenProvider
        )

        let coordinatorWorkers = try makeWorkers(count: workerCount)
        // In --once mode --batch-size is the total nonce span fanned across all
        // workers; the steady-state loop keeps the per-worker semantics.
        let totalBatchSize = once ? resolvedBatchSize : resolvedBatchSize &* UInt64(workerCount)
        let coordinator = MiningCoordinator(
            nodeClient: client,
            workers: coordinatorWorkers,
            totalBatchSize: totalBatchSize,
            staleProbeEnabled: !noStaleProbe
        )

        if once {
            let result = await coordinator.runBatch()
            try failClosedIfNeeded(result)
            try printJSONResult(result)
            return
        }

        print("lattice-mining-coordinator starting - node=\(node) workers=\(workerCount) batchSize=\(resolvedBatchSize)")
        while !Task.isCancelled {
            let result = await coordinator.runBatch()
            try failClosedIfNeeded(result)
            switch result {
            case .backoff, .nodeFailed:
                try? await Task.sleep(for: .milliseconds(250))
            case .noSolution(let workId):
                print("No nonce in batch work=\(String(workId.prefix(16)))...")
            case .workerFailed(let workId, let workerId, let error):
                print("Worker \(workerId) failed work=\(String(workId.prefix(16)))... error=\(error)")
            case .stale(let workId):
                print("Stale work=\(String(workId.prefix(16)))...")
            case .submitted(let workId, let nonce, let submission):
                print(
                    "Submitted work=\(String(workId.prefix(16)))... nonce=\(nonce) " +
                    "status=\(submission.status) accepted=\(submission.accepted)"
                )
                if !submission.accepted {
                    try? await Task.sleep(for: .milliseconds(250))
                } else if minBlockIntervalMs > 0 {
                    // Pace accepted block production for a realistic block time
                    // (both merge-mined chains advance together per accepted PoW),
                    // so a joining node can ride the live tip incrementally instead
                    // of racing a debug-speed source it can never catch.
                    try? await Task.sleep(for: .milliseconds(Int(minBlockIntervalMs)))
                }
            }
        }
    }

    private func makeWorkers(count: Int) throws -> [MiningCoordinatorWorker] {
        guard let workerExecutable, !workerExecutable.isEmpty else {
            return (0..<count).map { MiningCoordinatorWorker.local(id: "local-\($0)") }
        }
        let workerURL = URL(fileURLWithPath: workerExecutable)
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw ValidationError("--worker-executable is not executable: \(workerExecutable)")
        }
        return (0..<count).map {
            MiningCoordinatorWorker.process(id: "worker-\($0)", executableURL: workerURL)
        }
    }

    private func failClosedIfNeeded(_ result: MiningCoordinatorCycleResult) throws {
        switch result {
        case .nodeFailed(let error):
            throw ValidationError("node RPC failed: \(error)")
        case .workerFailed(_, let workerId, let error):
            throw ValidationError("worker \(workerId) failed: \(error)")
        default:
            return
        }
    }

    private static func loadRewardIdentity(path: String) throws -> MiningRewardIdentity {
        struct IdentityFile: Decodable {
            let rewardAddress: String?
            let coinbaseAddress: String?
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let identity = try JSONDecoder().decode(IdentityFile.self, from: data)
        let rewardAddress = identity.rewardAddress ?? identity.coinbaseAddress
        guard rewardAddress?.isEmpty != true else {
            throw ValidationError("--identity-file rewardAddress/coinbaseAddress must not be empty")
        }
        return MiningRewardIdentity(rewardAddress: rewardAddress)
    }

    private func printJSONResult(_ result: MiningCoordinatorCycleResult) throws {
        let output: [String: Any?]
        switch result {
        case .backoff:
            output = ["result": "backoff"]
        case .nodeFailed(let error):
            output = ["result": "nodeFailed", "error": error]
        case .noSolution(let workId):
            output = ["result": "noSolution", "workId": workId]
        case .stale(let workId):
            output = ["result": "stale", "workId": workId]
        case .workerFailed(let workId, let workerId, let error):
            output = [
                "result": "workerFailed",
                "workId": workId,
                "workerId": workerId,
                "error": error,
            ]
        case .submitted(let workId, let nonce, let submission):
            output = [
                "result": "submitted",
                "workId": workId,
                "nonce": nonce,
                "accepted": submission.accepted,
                "status": submission.status,
                "blockHash": submission.blockHash,
                "height": submission.height,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: output.compactMapValues { $0 })
        if let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }

    private static func resolveAuthToken(token: String?, cookieFile: String?, flag: String) throws -> String? {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        guard let cookieFile, !cookieFile.isEmpty else { return nil }
        guard let data = try? String(contentsOfFile: cookieFile, encoding: .utf8) else {
            throw ValidationError("\(flag) is not readable: \(cookieFile)")
        }
        let cookie = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            throw ValidationError("\(flag) is empty: \(cookieFile)")
        }
        return cookie
    }

    private static func resolveChildAuth(childNodes: [String], tokens: [String], cookieFiles: [String]) throws -> [String: String] {
        var auth: [String: String] = [:]
        for (idx, childNode) in childNodes.enumerated() {
            let token = idx < tokens.count ? tokens[idx] : nil
            let cookieFile = idx < cookieFiles.count ? cookieFiles[idx] : nil
            if let resolved = try resolveAuthToken(token: token, cookieFile: cookieFile, flag: "--child-rpc-cookie-file") {
                auth[childNode] = resolved
            }
        }
        return auth
    }

    /// Non-throwing re-read for the runtime auth providers: returns the current
    /// token (static token, else the cookie file's current contents), or nil.
    static func currentAuthToken(token: String?, cookieFile: String?) -> String? {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty { return token }
        guard let cookieFile, !cookieFile.isEmpty,
              let data = try? String(contentsOfFile: cookieFile, encoding: .utf8) else { return nil }
        let cookie = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return cookie.isEmpty ? nil : cookie
    }

    static func currentChildAuth(childNodes: [String], tokens: [String], cookieFiles: [String]) -> [String: String] {
        var auth: [String: String] = [:]
        for (idx, childNode) in childNodes.enumerated() {
            let token = idx < tokens.count ? tokens[idx] : nil
            let cookieFile = idx < cookieFiles.count ? cookieFiles[idx] : nil
            if let resolved = currentAuthToken(token: token, cookieFile: cookieFile) { auth[childNode] = resolved }
        }
        return auth
    }
}
