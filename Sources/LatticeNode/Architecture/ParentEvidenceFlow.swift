import Foundation

/// Session-scoped ordering and flow control for evidence from the configured
/// parent. The network runtime performs I/O; this reducer owns only the small
    /// state machine that keeps evidence, reservations, and backpressure ordered.
struct ParentEvidenceFlow {
    struct Session: Hashable {
        let peerID: String
        let sessionID: Data
    }

    enum Result: Equatable, Sendable {
        case handled
        /// Advertised content was absent or incomplete. Absence carries no
        /// blame: the sequence stops here and the next scan retries, without
        /// recycling the session or flagging backpressure.
        case unavailable
        case backpressured
        case failed
    }

    struct Append {
        let token: UInt64
        let predecessor: Task<Result, Never>?
    }

    struct Reservation {
        let evidenceTail: Task<Result, Never>?
    }

    private struct Tail {
        let token: UInt64
        let task: Task<Result, Never>
    }

    private var tails: [Session: Tail] = [:]
    private var failed: Set<Session> = []
    private var backpressured: Set<Session> = []
    private var activeReservations: Set<Session> = []
    private var operationCount = 0
    private var nextToken: UInt64 = 0

    var activeOperationCount: Int { operationCount }

    mutating func beginAppend(
        for session: Session,
        competingOperationCount: Int,
        capacity: Int
    ) -> Append? {
        guard !failed.contains(session) else { return nil }
        guard operationCount + competingOperationCount < capacity else {
            failed.insert(session)
            return nil
        }
        nextToken &+= 1
        operationCount += 1
        return Append(
            token: nextToken,
            predecessor: tails[session]?.task
        )
    }

    mutating func install(
        _ task: Task<Result, Never>,
        token: UInt64,
        for session: Session
    ) {
        tails[session] = Tail(token: token, task: task)
    }

    /// Returns whether the session must be recycled.
    mutating func finish(
        token: UInt64,
        result: Result,
        for session: Session
    ) -> Bool {
        precondition(operationCount > 0)
        operationCount -= 1
        if tails[session]?.token == token {
            tails.removeValue(forKey: session)
        }
        switch result {
        case .handled:
            backpressured.remove(session)
        case .unavailable:
            break
        case .backpressured:
            backpressured.insert(session)
        case .failed:
            failed.insert(session)
        }
        return result == .failed
    }

    mutating func beginReservation(
        for session: Session
    ) -> Reservation? {
        guard !failed.contains(session),
              activeReservations.insert(session).inserted else {
            return nil
        }
        return Reservation(evidenceTail: tails[session]?.task)
    }

    mutating func finishReservation(for session: Session) {
        activeReservations.remove(session)
    }

    func allowsReservation(
        for session: Session,
        after result: Result
    ) -> Bool {
        result == .handled
            && !failed.contains(session)
            && !backpressured.contains(session)
    }

    mutating func capacityBecameAvailable(for session: Session) {
        backpressured.remove(session)
    }

    func isFailed(_ session: Session) -> Bool {
        failed.contains(session)
    }

    func tail(for session: Session) -> Task<Result, Never>? {
        tails[session]?.task
    }

    mutating func cancel(peerID: String) {
        let sessions = tails.keys.filter { $0.peerID == peerID }
        for session in sessions {
            tails.removeValue(forKey: session)?.task.cancel()
        }
        failed = failed.filter { $0.peerID != peerID }
        backpressured = backpressured.filter { $0.peerID != peerID }
        activeReservations = activeReservations.filter {
            $0.peerID != peerID
        }
    }

    mutating func reset() {
        for tail in tails.values { tail.task.cancel() }
        self = ParentEvidenceFlow()
    }
}
