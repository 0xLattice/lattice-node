import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

let testEvidenceSourceID = "00000000-0000-4000-8000-000000000001"

enum NetworkTestError: Error {
    case failedStart
    case failedSend
    case failedPhase(String)
}

func inertNetworkHandlers() -> ClosureChainInterface {
    ClosureChainInterface(admission: { _ in throw CancellationError() })
}

func duplicateNetworkHandlers() -> ClosureChainInterface {
    ClosureChainInterface(admission: { _ in
        NodeImportOutcome(
            decision: .duplicate,
            parentCarrierLink: nil,
            sameChainPredecessor: nil
        )
    })
}

func testCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

actor NetworkEventRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

actor TopicRecorder {
    private var topics: [String] = []
    func append(_ topic: String) { topics.append(topic) }
    func contains(_ topic: String) -> Bool { topics.contains(topic) }
    func count(of topic: String) -> Int { topics.filter { $0 == topic }.count }
}

actor PayloadRecorder {
    private var events: [(topic: String, payload: Data)] = []

    func append(topic: String, payload: Data) {
        events.append((topic, payload))
    }
    func payloads(topic: String) -> [Data] {
        events.filter { $0.topic == topic }.map(\.payload)
    }
    func topics() -> [String] { events.map(\.topic) }
}

final class PayloadRecordingPeer: IvyDelegate, Sendable {
    private let recorder: PayloadRecorder

    init(recorder: PayloadRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(topic: message.topic, payload: message.payload)
    }
}

final class TopicRecordingPeer: IvyDelegate, Sendable {
    private let recorder: TopicRecorder

    init(recorder: TopicRecorder) {
        self.recorder = recorder
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        await recorder.append(message.topic)
    }
}

/// A scripted overlay peer that announces its blocks once the runtime has
/// authorized the session. The runtime answers a hello with its own tip
/// announcement — the one wire-visible sign that the hello landed — and
/// each session is served exactly once.
actor OverlayAnnouncingPeer: IvyDelegate {
    private let blocks: [String]
    private var authorizedSessions: [Data] = []

    init(announcing blocks: [String]) {
        self.blocks = blocks
    }

    func ivy(
        _ ivy: Ivy,
        didReceiveMessage message: PeerMessage,
        from peer: AuthenticatedPeer
    ) async {
        guard message.topic == NodeNetworkTopic.blockAnnouncement,
              !authorizedSessions.contains(peer.sessionID) else { return }
        authorizedSessions.append(peer.sessionID)
        for blockCID in blocks {
            guard let payload = try? BlockAnnouncementMessage(
                blockCID: blockCID
            ).encoded() else { continue }
            _ = await ivy.sendMessage(
                to: peer,
                topic: NodeNetworkTopic.blockAnnouncement,
                payload: payload
            )
        }
    }

    func authorizedSessionCount() -> Int { authorizedSessions.count }
}

extension Ivy {
    func installTestDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
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
