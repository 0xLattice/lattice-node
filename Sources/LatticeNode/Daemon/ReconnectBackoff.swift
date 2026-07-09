import Foundation

struct ReconnectBackoff: Sendable, Equatable {
    let baseSeconds: Int64
    let capSeconds: Int64
    let multiplier: Int64

    private var currentSeconds: Int64

    init(baseSeconds: Int64 = 30, multiplier: Int64 = 2, capSeconds: Int64 = 300) {
        precondition(baseSeconds > 0, "baseSeconds must be positive")
        precondition(multiplier > 1, "multiplier must be greater than one")
        precondition(capSeconds >= baseSeconds, "capSeconds must be at least baseSeconds")
        self.baseSeconds = baseSeconds
        self.capSeconds = capSeconds
        self.multiplier = multiplier
        self.currentSeconds = baseSeconds
    }

    mutating func nextDelay() -> Duration {
        let delay = currentSeconds
        if currentSeconds < capSeconds {
            let (product, overflow) = currentSeconds.multipliedReportingOverflow(by: multiplier)
            currentSeconds = overflow ? capSeconds : min(product, capSeconds)
        }
        return .seconds(delay)
    }

    mutating func reset() {
        currentSeconds = baseSeconds
    }
}

enum ParentSubscriptionReconnectAction: Equatable {
    case exit
    case wait(Duration)
    case reconnectAfter(Duration)
}

enum ParentSubscriptionReconnectLoop {
    static func nextAction(
        isCancelled: Bool,
        peerConnectionCount: Int,
        backoff: inout ReconnectBackoff
    ) -> ParentSubscriptionReconnectAction {
        guard !isCancelled else { return .exit }

        if peerConnectionCount > 0 {
            backoff.reset()
            return .wait(.seconds(backoff.baseSeconds))
        }

        return .reconnectAfter(backoff.nextDelay())
    }

    /// Run one reconnect attempt and surface its outcome.
    ///
    /// On a successful `connect` the backoff is reset to base cadence. On a
    /// thrown connect error the backoff is LEFT INTACT (so the next delay keeps
    /// growing) and the error is handed to `onFailure` — it is surfaced, never
    /// swallowed. This is the single choke point the parent-reconnect loop drives
    /// so the connect-failure path is observable from a behavioral test instead of
    /// a source grep.
    static func performReconnect(
        backoff: inout ReconnectBackoff,
        connect: () async throws -> Void,
        onFailure: (any Error) -> Void
    ) async {
        do {
            try await connect()
            backoff.reset()
        } catch {
            onFailure(error)
        }
    }
}
