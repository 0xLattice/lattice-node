import Foundation
import XCTest

/// Slow shared CI runners set E2E_TIME_SCALE above 1. Every bounded wait in
/// this target is multiplied by it.
let testTimeScale: Int = ProcessInfo.processInfo
    .environment["E2E_TIME_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

/// `duration` scaled by `testTimeScale`, as nanoseconds for `Task.sleep`.
func scaledNanoseconds(_ duration: Duration) -> UInt64 {
    nanoseconds(duration * testTimeScale)
}

private func nanoseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
}

enum TestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case .timedOut(let phase): return "timed out waiting for: \(phase)"
        }
    }
}

/// Polls `condition` every `poll` until it holds; throws once `within`
/// (scaled) has elapsed. The one poller for every POSITIVE wait.
func eventually(
    _ phase: String,
    within: Duration = .seconds(30),
    poll: Duration = .milliseconds(10),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + within * testTimeScale
    while true {
        if try await condition() { return }
        guard ContinuousClock.now < deadline else {
            throw TestWaitError.timedOut(phase)
        }
        try await Task.sleep(nanoseconds: nanoseconds(poll))
    }
}

/// Holds `invariant` for the whole (scaled) `window`, polling every `poll`:
/// the settle wait for a NEGATIVE assertion ("nothing more happened"). A
/// break is reported at the call site; the caller's own assertions follow.
func alwaysDuring(
    _ phase: String,
    _ window: Duration,
    poll: Duration = .milliseconds(10),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ invariant: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + window * testTimeScale
    repeat {
        guard try await invariant() else {
            XCTFail("broken inside the settle window: \(phase)", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: nanoseconds(poll))
    } while ContinuousClock.now < deadline
}
