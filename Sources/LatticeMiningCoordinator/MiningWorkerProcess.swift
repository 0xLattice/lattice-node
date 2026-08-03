import Foundation
import LatticeMinerCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum MiningWorkerProcessError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingExecutable(String)
    case nonzeroExit(status: Int32, stderr: String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .missingExecutable(let path):
            return "missingExecutable(\(path))"
        case .nonzeroExit(let status, let stderr):
            return "nonzeroExit(status: \(status), stderr: \(stderr))"
        case .invalidOutput(let output):
            return "invalidOutput(\(output))"
        }
    }
}

/// Mirror of the `LatticeMiner` worker's stdout `WorkerResult` JSON contract.
struct MiningWorkerProcessResult: Decodable {
    let workId: String
    let status: String
    let nonce: UInt64?
    let rangeStart: UInt64
    let rangeCount: UInt64
}

/// Spawns the `LatticeMiner` worker process for one immutable nonce-range
/// assignment and parses its `WorkerResult` JSON output. The worker takes its
/// assignment as CLI flags (`--workId/--blockHex/--target/--startNonce/--count`)
/// and prints exactly one `WorkerResult` JSON object to stdout.
public struct MiningWorkerProcessClient: Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func search(workerId: String, work: MiningCoordinatorWork, range: NonceSearchRange) async throws -> MiningWorkerResult? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MiningWorkerProcessError.missingExecutable(executableURL.path)
        }

        let handle = MiningWorkerSubprocess()
        let process = handle.process
        process.executableURL = executableURL
        process.arguments = arguments + [
            "--work-id", work.workId,
            "--block-hex", work.blockHex,
            "--target", work.targetHex,
            "--start-nonce", String(range.startNonce),
            "--count", String(range.count),
        ] + (work.prefixHex.isEmpty ? [] : [
            "--prefix-hex", work.prefixHex,
        ])

        let stdout = Pipe()
        process.standardOutput = stdout

        // stderr goes to a TEMP FILE, never a Pipe. The worker prints one small
        // JSON line to stdout, but on failure can flood stderr (a crash
        // backtrace) past the 64 KB pipe buffer — and a pipe blocks the worker
        // in write() until drained, so it would never exit. Draining it
        // concurrently means a second raw-fd reader racing corelibs' Process fd
        // management, which wedges and throws EBADF under fd pressure on Linux.
        // A regular file never blocks the writer and needs no concurrent reader:
        // the worker runs to completion, and we read the file (capped) after it
        // exits. stdout stays a pipe read once post-exit, like the CLI's
        // spawnCollectingOutput.
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("miner-stderr-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        // A fresh /dev/null per call, never the shared FileHandle.nullDevice
        // singleton, if the temp file can't be opened: corelibs closes a child's
        // standard-handle fd on exit, so reusing the singleton throws EBADF on a
        // later spawn — the very bug this file guards against.
        let stderrWrite = FileHandle(forWritingAtPath: stderrURL.path)
            ?? FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = stderrWrite
        defer {
            try? stderrWrite?.close()
            try? FileManager.default.removeItem(at: stderrURL)
        }

        try await handle.run()

        // On cancellation (e.g. stale work) the worker result is irrelevant.
        // Check before the post-exit read so a cancelled worker that forked a
        // grandchild holding the stdout write-end open can't block us on a read
        // that never reaches EOF; the stdout Pipe cleans up via closeOnDealloc.
        if Task.isCancelled { return nil }

        // stdout: a single post-exit read. The worker's stdout is one small
        // JSON line, so it cannot fill the pipe buffer before the child exits.
        try? stdout.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        try? stdout.fileHandleForReading.close()

        if process.terminationStatus != 0 {
            // Read only the last 4 KB: the stderr file has no pipe backpressure,
            // so a runaway worker could grow it without bound — seek to the tail
            // rather than slurping the whole file to extract the cap.
            let errorData = Self.tail(of: stderrURL, maxBytes: 4096)
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            throw MiningWorkerProcessError.nonzeroExit(status: process.terminationStatus, stderr: errorText)
        }
        guard let result = try? JSONDecoder().decode(MiningWorkerProcessResult.self, from: output) else {
            // Cap the surfaced stdout the same way as stderr: it is forwarded
            // verbatim into the coordinator's single-line stdout that the CLI
            // reads post-exit, so a non-decodable flood must not amplify.
            let capped = output.count > 4096 ? Data(output.suffix(4096)) : output
            throw MiningWorkerProcessError.invalidOutput(String(data: capped, encoding: .utf8) ?? "")
        }
        guard result.status == "found", let nonce = result.nonce else {
            return nil
        }
        return MiningWorkerResult(
            workerId: workerId,
            workId: result.workId,
            nonce: nonce
        )
    }

    /// Reads at most the last `maxBytes` of a file by seeking to its tail, so a
    /// large stderr capture never loads the whole file into memory.
    private static func tail(of url: URL, maxBytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(maxBytes) {
            try? handle.seek(toOffset: size - UInt64(maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        return (try? handle.readToEnd()) ?? Data()
    }

}

private final class MiningWorkerSubprocess: @unchecked Sendable {
    let process = Process()

    /// How long to wait after SIGTERM before escalating to SIGKILL. Some shells
    /// (e.g. dash `sh -c`) don't reliably propagate SIGTERM to their children,
    /// and on swift-corelibs-foundation a bare `terminate()` does not promptly
    /// reap such a child, so we force-kill after a short grace period.
    private static let terminationGraceNanoseconds: UInt64 = 200_000_000

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didFinish = false
    private var cancelRequested = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Runs the process to completion, resuming off `terminationHandler` rather
    /// than parking a thread on the synchronous `waitUntilExit()`. On task
    /// cancellation it sends SIGTERM and escalates to SIGKILL after a short
    /// grace so the child is reaped promptly and reliably across platforms.
    func run() async throws {
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        try process.run()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow = withLock { () -> Bool in
                    if didFinish { return true }
                    continuation = cont
                    return false
                }
                if resumeNow {
                    cont.resume()
                }
            }
        } onCancel: {
            requestTermination()
        }
    }

    private func finish() {
        let cont = withLock { () -> CheckedContinuation<Void, Never>? in
            let pending = continuation
            continuation = nil
            didFinish = true
            return pending
        }
        cont?.resume()
    }

    private func requestTermination() {
        let proceed = withLock { () -> Bool in
            if cancelRequested || didFinish { return false }
            cancelRequested = true
            return true
        }
        guard proceed else { return }

        // SIGTERM first; the terminationHandler will resume the continuation if
        // the child exits in response.
        if process.isRunning {
            process.terminate()
        }

        // Escalate to SIGKILL after a grace period for children that ignore or
        // don't propagate SIGTERM. Detached so the cancel handler returns
        // immediately.
        let pid = process.processIdentifier
        Task.detached { [weak self] in
            try? await Task.sleep(
                nanoseconds: MiningWorkerSubprocess.terminationGraceNanoseconds
            )
            guard let self else { return }
            let finished = self.withLock { self.didFinish }
            if !finished, self.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

extension MiningCoordinatorWorker {
    public static func process(
        id: String,
        executableURL: URL,
        arguments: [String] = []
    ) -> MiningCoordinatorWorker {
        let client = MiningWorkerProcessClient(executableURL: executableURL, arguments: arguments)
        return MiningCoordinatorWorker(id: id) { work, range in
            try await client.search(workerId: id, work: work, range: range)
        }
    }
}
