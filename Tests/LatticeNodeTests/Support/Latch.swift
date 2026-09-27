/// A one-shot signal: `wait()` suspends until `open()` is called, whether
/// that happens before or after the wait.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Someone is parked on the latch right now.
    var isHeld: Bool { !waiters.isEmpty }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A turnstile: each `enter()` takes the next index and parks until that
/// index is released, so a test can hold the Nth build while letting others
/// through.
actor CandidateBuildGate {
    private var next = 0
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func enter() async -> Int {
        next += 1
        let index = next
        guard !released.contains(index) else { return index }
        await withCheckedContinuation { waiters[index] = $0 }
        return index
    }

    func enteredCount() -> Int { next }

    func release(_ index: Int) {
        released.insert(index)
        waiters.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        for index in Array(waiters.keys) { release(index) }
    }
}
