import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Lattice
import cashew
@testable import LatticeNode

/// Strictly increasing, slightly-past block timestamps (admission is
/// `timestamp <= now`).
final class TestBlockClock {
    private var current = Int64(Date().timeIntervalSince1970 * 1_000) - 5_000
    func next() -> Int64 {
        current += 100
        return current
    }
}

extension NodeRuntime {
    /// Mine one block through the RPC surface: a template on the act-on tip,
    /// its nonce ground, the work submitted. Returns the mined block.
    func mineBlock(_ request: MiningTemplateRequest = MiningTemplateRequest()) async throws -> Block {
        let template = try await miningTemplate(request)
        var nonce: UInt64 = 0
        // The hardest threshold: the root's own, which every carried
        // child's easier target also meets.
        let target = template.targets.min() ?? template.searchTarget
        while template.block.replacingNonce(nonce).proofOfWorkHash() > target { nonce += 1 }
        _ = try await submitWork(SubmitWorkRequest(workID: template.workID, nonce: nonce))
        return template.block.replacingNonce(nonce)
    }
}

enum NetworkTransportTestPorts {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var allocated = Set<UInt16>()

    /// Test listen ports come from a fixed range below every platform's
    /// ephemeral range (Linux 32768-60999, macOS 49152-65535). A port the
    /// kernel handed out as ephemeral can be taken again as the source port
    /// of a concurrent outbound connection before the test binds it, which
    /// surfaced as `bind: Address already in use`. Probing here, each process
    /// starting at its own offset, keeps listeners out of that pool.
    private static let range: Range<UInt16> = 20_000..<30_000
    private nonisolated(unsafe) static var cursor = UInt16(
        truncatingIfNeeded: Int(getpid()) &* 7_919
    ) % UInt16(range.count)

    static func allocate() -> UInt16 {
        lock.withLock {
            for _ in 0..<range.count {
                let port = range.lowerBound + cursor
                cursor = (cursor + 1) % UInt16(range.count)
                guard !allocated.contains(port), isFree(port) else { continue }
                allocated.insert(port)
                return port
            }
            preconditionFailure("no free test port in \(range)")
        }
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
