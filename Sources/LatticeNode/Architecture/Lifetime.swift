import Foundation

/// A token no one else in this process holds.
///
/// Drawn from one counter that only moves forward and has no reset, so a
/// token is never handed out twice: not across a stop and restart, not
/// across runtimes. Whatever a token keys (a stored task handle, a guard
/// slot, a pending-request entry) can only be released, cleared or
/// answered by the holder that took it. Work that suspends and resumes
/// after its generation or session ended still holds its old token, which
/// matches nothing the new generation took.
struct LifetimeToken: Hashable, Sendable {
    let rawValue: UInt64

    private static let source = RuntimeCallbackEpoch()

    static func next() -> LifetimeToken {
        LifetimeToken(rawValue: source.advance())
    }
}

/// One stored task handle, with the token it was started under.
///
/// A task that empties its own handle when it ends does it with `clear`,
/// which compares tokens first: a task that outlived a stop, while a
/// restart filled the slot again, cannot empty the newer task's handle.
/// `holds` is the task's own fence: it turns false once teardown emptied
/// the slot or a newer task owns it, so a loop that re-checks it after
/// each suspension stops touching state that is no longer its own.
struct TaskSlot {
    private var current: (token: LifetimeToken, task: Task<Void, Never>)?

    var isEmpty: Bool { current == nil }

    func holds(_ token: LifetimeToken) -> Bool {
        current?.token == token
    }

    /// Fills an empty slot with the task `start` makes, which is handed the
    /// token it will clear with. An occupied slot is left alone (nil).
    @discardableResult
    mutating func start(
        _ start: (LifetimeToken) -> Task<Void, Never>
    ) -> LifetimeToken? {
        guard current == nil else { return nil }
        let token = LifetimeToken.next()
        current = (token, start(token))
        return token
    }

    /// Empties the slot iff it still holds the task started under `token`.
    @discardableResult
    mutating func clear(_ token: LifetimeToken) -> Bool {
        guard holds(token) else { return false }
        current = nil
        return true
    }

    /// Teardown: empties the slot, whoever holds it, and hands back the
    /// task (uncancelled) for the caller to cancel or join.
    mutating func take() -> Task<Void, Never>? {
        defer { current = nil }
        return current?.task
    }

    /// Teardown: cancels the held task and empties the slot.
    mutating func cancel() {
        take()?.cancel()
    }
}
