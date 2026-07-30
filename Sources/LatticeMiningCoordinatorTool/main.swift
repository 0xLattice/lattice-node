// lattice-mining-coordinator: node-facing mining coordinator.
//
// The coordinator fetches node work, allocates nonce ranges to workers,
// handles stale work/result races, and submits workID+nonce to the node.
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

    @Option(name: .long, help: "RPC base URL of the Nexus node (e.g. http://127.0.0.1:8080)")
    var node: String

    @Option(name: .long, help: "Parallel worker count (default: CPU count - 1)")
    var workers: Int = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)

    @Option(
        name: .long,
        help: "Nonce batch size per worker per coordinator iteration"
    )
    var batchSize: UInt64?

    @Option(name: .long, help: "Path to the LatticeMiner worker executable. When set, nonce search runs in worker subprocesses instead of in-process.")
    var workerExecutable: String?

    @Option(name: .long, help: "JSON file containing the externally signed {\"rewards\":[...]} template request.")
    var rewardsFile: String?

    @Flag(name: .long, help: "Run exactly one coordinator batch (emitting a JSON result) and exit.")
    var once = false

    @Flag(name: .long, help: "Disable the best-effort freshness probe for this run.")
    var noStaleProbe = false

    @Flag(name: .long, help: "Mine one pending child deployment subtree instead of normal work.")
    var deployment = false

    func run() async throws {
        guard let apiBaseURL = URL(string: node) else {
            throw ValidationError("Invalid --node URL: \(node)")
        }
        let workerCount = max(workers, 1)
        let resolvedBatchSize = batchSize
            ?? (workerExecutable == nil ? 10_000 : 2_000_000_000)
        let client = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: apiBaseURL,
            templateRequestBody: try Self.loadTemplateRequest(
                path: rewardsFile,
                deployment: deployment
            )
        )

        let coordinatorWorkers = try makeWorkers(count: workerCount)
        // In --once mode --batch-size is the total nonce span fanned across all
        // workers; the steady-state loop keeps the per-worker semantics.
        let totalBatchSize = once
            ? resolvedBatchSize
            : resolvedBatchSize &* UInt64(workerCount)
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

        print(
            "lattice-mining-coordinator starting - node=\(node) " +
            "workers=\(workerCount) batchSize=\(resolvedBatchSize)"
        )
        while !Task.isCancelled {
            let result = await coordinator.runBatch()
            try failClosedIfNeeded(result)
            switch result {
            case .backoff, .nodeFailed:
                try? await Task.sleep(nanoseconds: 250_000_000)
            case .noSolution(let workId):
                print("No nonce in batch work=\(String(workId.prefix(16)))...")
            case .workerFailed(let workId, let workerId, let error):
                print("Worker \(workerId) failed work=\(String(workId.prefix(16)))... error=\(error)")
            case .stale(let workId):
                print("Stale work=\(String(workId.prefix(16)))...")
            case .submitted(let workId, let nonce, let submission):
                print(
                    "Submitted work=\(String(workId.prefix(16)))... nonce=\(nonce) " +
                    "disposition=\(submission.disposition) accepted=\(submission.accepted)"
                )
                if !submission.accepted {
                    try? await Task.sleep(nanoseconds: 250_000_000)
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
                "disposition": submission.disposition,
                "tipCID": submission.tipCID,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: output.compactMapValues { $0 })
        if let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }

    private static func loadTemplateRequest(
        path: String?,
        deployment: Bool
    ) throws -> Data {
        let data: Data
        if let path {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = Data(#"{"rewards":[]}"#.utf8)
        }
        guard data.count <= 1 << 20,
              var object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["rewards"] is [Any] else {
            throw ValidationError(
                "--rewards-file must be a JSON {\"rewards\":[...]} request no larger than 1 MiB"
            )
        }
        if deployment { object["mode"] = "deployment" }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
