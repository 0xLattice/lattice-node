import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Lattice
import LatticeNodeAPI
import UInt256
@testable import LatticeNode

/// Slow hosts set E2E_TIME_SCALE above 1. Every bounded wait is multiplied by it.
private let timeScale: Int = ProcessInfo.processInfo
    .environment["E2E_TIME_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1

struct TimedOut: Error, CustomStringConvertible {
    let phase: String
    var description: String { "timed out waiting for: \(phase)" }
}

/// Polls `condition` every `poll` until it holds; throws once `within`
/// (scaled) has elapsed.
func eventually(
    _ phase: String,
    within: Duration = .seconds(30),
    poll: Duration = .milliseconds(10),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + within * timeScale
    let (seconds, attoseconds) = poll.components
    let pollNanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    while true {
        if try await condition() { return }
        guard ContinuousClock.now < deadline else { throw TimedOut(phase: phase) }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
}

/// Listen ports from a fixed range below every platform's ephemeral range
/// (Linux 32768-60999, macOS 49152-65535), so a port is never taken again as
/// the source port of an outbound connection before the node binds it. Each
/// process starts at its own offset.
struct Ports {
    private static let range: Range<UInt16> = 20_000..<30_000
    private var cursor = UInt16(truncatingIfNeeded: Int(getpid()) &* 7_919) % UInt16(range.count)

    mutating func allocate() -> UInt16 {
        for _ in 0..<Self.range.count {
            let port = Self.range.lowerBound + cursor
            cursor = (cursor + 1) % UInt16(Self.range.count)
            if Self.isFree(port) { return port }
        }
        preconditionFailure("no free port in \(Self.range)")
    }

    private static func isFree(_ port: UInt16) -> Bool {
        #if canImport(Darwin)
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        precondition(descriptor >= 0)
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

extension NodeRuntime {
    /// Mine one block through the RPC surface: a template on the act-on tip,
    /// its nonce ground against the hardest target it carries, the work
    /// submitted.
    func mineBlock(_ request: MiningTemplateRequest) async throws {
        let template = try await miningTemplate(request)
        let target = min(Self.hardestTarget(template.block), template.targets.min() ?? template.searchTarget)
        var nonce: UInt64 = 0
        while template.block.replacingNonce(nonce).proofOfWorkHash() > target { nonce += 1 }
        _ = try await submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
    }

    private static func hardestTarget(_ block: Block) -> UInt256 {
        let children = block.children.node?.entries.values.compactMap(\.node) ?? []
        return children.map(hardestTarget).reduce(block.target, min)
    }
}
