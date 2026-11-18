import Foundation
import Lattice
import cashew
import Synchronization

/// One connect job's run (`ChainEffect.connect`): its blocks executed in
/// order, each reading the post-state the previous one produced from memory,
/// since nothing of the job is stored until its verdicts are applied in one
/// step (Bitcoin's `ActivateBestChainStep` connects its blocks over an
/// in-memory coins view, flushed after; geth's `insertChain` writes one
/// batch). The run stops after the first block without a valid verdict: the
/// blocks after it would read a state that was not produced.
public enum ConnectRun {
    /// Run `jobs` over `fetcher` (the job's reads), asking `parentFacts` a
    /// child level's facts. Returns the verdicts, and the reads the run
    /// went through (its produced states, then `fetcher`), for what the
    /// caller reads of the valid blocks after.
    public static func run(
        _ jobs: [ConnectJob],
        fetcher: any Fetcher,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: @Sendable () -> ValidationContext
    ) async -> (verdicts: [ConnectVerdict], reads: any Fetcher) {
        let reads = ProducedStates(fetcher)
        var verdicts: [ConnectVerdict] = []
        for job in jobs {
            let verdict = await ChainTree.connect(
                job, fetcher: reads, parentFacts: parentFacts, validationContext: validationContext()
            )
            verdicts.append(verdict)
            guard verdict.isValid else { break }
            if let state = verdict.materializedPostState {
                guard (try? await reads.add(state)) != nil else { break }
            }
        }
        return (verdicts, reads)
    }
}

extension ConnectVerdict {
    /// Whether execution found the block valid.
    public var isValid: Bool { retryFailure == nil && !provesInvalid }
}

/// A job's reads: the states its earlier blocks produced, held in memory,
/// then `fetcher`.
final class ProducedStates: Fetcher, Sendable {
    private let fetcher: any Fetcher
    private let produced = Mutex<[String: Data]>([:])

    init(_ fetcher: any Fetcher) {
        self.fetcher = fetcher
    }

    /// Hold every node `state` materialized: what a later execution reads
    /// of it and the store does not hold yet.
    func add(_ state: LatticeState) async throws {
        let collected = Collected()
        try await Self.store(LatticeStateHeader(node: state), in: collected)
        let entries = collected.entries
        produced.withLock { $0.merge(entries) { held, _ in held } }
    }

    func fetch(rawCid: String) async throws -> Data {
        if let data = produced.withLock({ $0[rawCid] }) { return data }
        return try await fetcher.fetch(rawCid: rawCid)
    }

    /// Each loaded node under `header`, `header` included.
    private static func store(_ header: any Header, in storer: Collected) async throws {
        guard let node = loadedNode(of: header) else { return }
        try await header.store(storer: storer)
        var children: [any Header] = node.properties().sorted().compactMap { node.get(property: $0) }
        if let radix = node as? any RadixNode, let value = radix.value as? any Header {
            children.append(value)
        }
        for child in children { try await store(child, in: storer) }
    }

    private static func loadedNode<H: Header>(of header: H) -> (any cashew.Node)? {
        header.node
    }

    private final class Collected: Storer, Sendable {
        private let held = Mutex<[String: Data]>([:])

        func store(entries: [String: Data]) async throws {
            held.withLock { $0.merge(entries) { held, _ in held } }
        }

        var entries: [String: Data] { held.withLock { $0 } }
    }
}
