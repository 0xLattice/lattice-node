import Foundation
import Ivy

/// Delivers each session's sync messages in order without holding up the
/// runtime. A send the transport refuses as backpressured - its buffer is
/// still draining an earlier message, such as a large headers page - waits
/// until the session drains and is sent again, rather than being lost. A lost
/// reply left the requester waiting until its deadline disconnected a peer
/// that had answered.
actor SessionOutbox {
    /// Messages, and bytes, one session may have queued. Past either, a send
    /// is dropped as before rather than queued behind a peer that never drains:
    /// such a peer can pin at most this much memory. The byte bound holds
    /// several full headers pages.
    static let maximumQueuedPerSession = 1_024
    static let maximumQueuedBytesPerSession = 8 * 1_024 * 1_024

    private struct Lane {
        var tail: Task<Bool, Never>
        var queued: Int
        var bytes: Int
    }

    typealias Send = @Sendable (AuthenticatedPeer, String, Data) async -> SendMessageResult
    typealias WaitUntilWritable = @Sendable (AuthenticatedPeer) async -> Bool

    private let transmit: Send
    private let waitUntilWritable: WaitUntilWritable
    private var lanes: [String: Lane] = [:]

    init(ivy: Ivy) {
        self.init(
            send: { peer, topic, payload in await ivy.sendMessage(to: peer, topic: topic, payload: payload) },
            waitUntilWritable: { peer in await ivy.waitUntilWritable(to: peer) }
        )
    }

    init(send: @escaping Send, waitUntilWritable: @escaping WaitUntilWritable) {
        self.transmit = send
        self.waitUntilWritable = waitUntilWritable
    }

    /// Queues `payload` for `peer` behind its earlier messages. The returned
    /// task finishes true once the message is handed to the transport, false
    /// if the session ended or refused it.
    @discardableResult
    func send(to peer: AuthenticatedPeer, topic: String, payload: Data) -> Task<Bool, Never> {
        let lane = Self.laneKey(peer)
        let previous = lanes[lane]
        guard (previous?.queued ?? 0) < Self.maximumQueuedPerSession,
              (previous?.bytes ?? 0) + payload.count <= Self.maximumQueuedBytesPerSession else {
            return Task { false }
        }
        let (transmit, waitUntilWritable) = (transmit, waitUntilWritable)
        let task = Task<Bool, Never> {
            _ = await previous?.tail.value
            while true {
                switch await transmit(peer, topic, payload) {
                case .enqueued:
                    return true
                case .backpressured:
                    guard await waitUntilWritable(peer) else { return false }
                case .notConnected, .locallyRejected:
                    return false
                }
            }
        }
        lanes[lane] = Lane(
            tail: task,
            queued: (previous?.queued ?? 0) + 1,
            bytes: (previous?.bytes ?? 0) + payload.count
        )
        let size = payload.count
        Task { [weak self] in
            _ = await task.value
            await self?.finished(lane, bytes: size)
        }
        return task
    }

    private func finished(_ lane: String, bytes: Int) {
        guard var current = lanes[lane] else { return }
        current.queued -= 1
        current.bytes -= bytes
        lanes[lane] = current.queued > 0 ? current : nil
    }

    private static func laneKey(_ peer: AuthenticatedPeer) -> String {
        peer.key.hex + "#" + peer.sessionID.map { String(format: "%02x", $0) }.joined()
    }
}
