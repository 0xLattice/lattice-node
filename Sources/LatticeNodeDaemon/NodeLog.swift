import Foundation

/// The node's recent output, for `GET /logs`. Everything the process writes
/// to its standard output and standard error goes on to its standard error,
/// where whatever runs the node collects it (journald, launchd, Docker, Fly),
/// and its last lines are kept here, in memory: the node keeps no log file.
final class NodeLog: @unchecked Sendable {
    /// At most this many lines are kept, and at most `maximumBytes` of them.
    static let maximumLines = 10_000
    static let maximumBytes = 4 << 20
    /// A longer line is kept in parts of this many bytes.
    static let maximumLineBytes = 16 << 10

    private let lock = NSLock()
    private var lines: [String] = []
    private var first = 0
    private var bytes = 0
    private var partial = Data()

    init() {}

    /// Keeps `data`'s complete lines; a line's end waits for its newline.
    func append(_ data: Data) {
        lock.withLock {
            partial.append(data)
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                keep(partial[partial.startIndex..<newline])
                partial.removeSubrange(partial.startIndex...newline)
            }
            while partial.count >= Self.maximumLineBytes {
                let end = partial.startIndex + Self.maximumLineBytes
                keep(partial[partial.startIndex..<end])
                partial.removeSubrange(partial.startIndex..<end)
            }
        }
    }

    private func keep(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        lines.append(text)
        bytes += text.utf8.count
        while lines.count - first > Self.maximumLines || (bytes > Self.maximumBytes && lines.count - first > 1) {
            bytes -= lines[first].utf8.count
            first += 1
        }
        // Dropped lines are let go in batches, not one at a time.
        if first >= 1_024, first * 2 >= lines.count {
            lines.removeFirst(first)
            first = 0
        }
    }

    /// The last `count` lines kept, each ending in a newline.
    func tail(_ count: Int) -> String {
        lock.withLock {
            let kept = lines[first...]
            return kept.suffix(max(0, count)).map { $0 + "\n" }.joined()
        }
    }

    private var original: Int32 = -1
    private let drained = DispatchSemaphore(value: 0)

    /// Sends this process's standard output and standard error through a
    /// pipe that a thread of its own reads: each read goes on to the
    /// standard error the process started with, then into this log.
    func capture() throws {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw CaptureError(errno) }
        let original = dup(STDERR_FILENO)
        guard original >= 0 else { throw CaptureError(errno) }
        // Nothing the node starts later inherits these.
        _ = fcntl(original, F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        // Whatever is buffered for the old destinations goes there first.
        fflush(nil)
        guard dup2(ends[1], STDOUT_FILENO) >= 0, dup2(ends[1], STDERR_FILENO) >= 0 else {
            throw CaptureError(errno)
        }
        close(ends[1])
        lock.withLock { self.original = original }
        let reader = ends[0]
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(reader, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < count {
                        let written = write(original, raw.baseAddress! + offset, count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { break }
                        offset += written
                    }
                }
                append(Data(buffer[0..<count]))
            }
            close(reader)
            drained.signal()
        }
    }

    /// Puts the process's standard output and error back where they were and
    /// waits (briefly) until what was written before is passed on, so the
    /// last lines before an exit are not lost.
    func finish() {
        let original = lock.withLock { () -> Int32 in
            defer { self.original = -1 }
            return self.original
        }
        guard original >= 0 else { return }
        fflush(nil)
        _ = dup2(original, STDOUT_FILENO)
        _ = dup2(original, STDERR_FILENO)
        _ = drained.wait(timeout: .now() + 2)
    }

    struct CaptureError: Error, CustomStringConvertible {
        let code: Int32
        init(_ code: Int32) { self.code = code }
        var description: String { "could not capture the node's output: \(String(cString: strerror(code)))" }
    }
}

/// One line of the node's log, on its standard error.
func logLine(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
