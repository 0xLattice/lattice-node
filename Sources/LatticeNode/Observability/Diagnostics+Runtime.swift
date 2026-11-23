import LatticeNodeSupport

extension NodeRuntime.RuntimeJob {
    /// This job, its reads counted under `label` while the tally is on.
    func reading(_ label: String) -> Self {
        guard ReadTally.enabled else { return self }
        let run = self.run
        return Self(path: path, tipCID: tipCID, kind: kind, queued: queued) {
            await ReadTally.reading(label) { await run() }
        }
    }
}
