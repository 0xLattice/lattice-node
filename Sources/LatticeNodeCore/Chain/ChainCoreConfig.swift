import Lattice
import UInt256
import cashew

/// Each chain's finality window in blocks: a chain's own, else the default;
/// nil is no window.
public struct FinalityWindows: Sendable, Equatable {
    /// The window of every chain not named in `byChain`.
    public var all: UInt64?
    /// Per chain path; a nil value turns the window off for that chain.
    public var byChain: [[String]: UInt64?]

    public init(all: UInt64? = nil, byChain: [[String]: UInt64?] = [:]) {
        self.all = all
        self.byChain = byChain
    }

    public func window(for path: [String]) -> UInt64? {
        byChain[path] ?? all
    }
}

public struct ChainCoreConfig: Sendable {
    public var maxHeadersPerPage: Int
    /// A served page stops before this many bytes (always at least one
    /// header).
    public var maxPageBytes: Int
    /// How long any request may wait for its answer before its peer is
    /// disconnected as stalled. Each page is its own request, so a stream
    /// that keeps delivering never times out.
    public var headersTimeout: Int64
    /// How long (ms) a server spends gathering one headers answer before it
    /// sends what it has (always at least one header). A requester waits
    /// only `headersTimeout`; an answer bounded by bytes alone outlasts that
    /// on a slow server, and the request is then repeated without end. The
    /// default leaves the rest of the deadline for encoding and the wire.
    public var servingBudget: Int64
    /// A child index larger than this travels by CID instead of inline.
    public var maxInlineChildIndexBytes: Int
    /// The largest child index this node takes from a peer. A larger one is
    /// unavailable here, like content that cannot be fetched: its header is
    /// not taken from that peer, never judged and never blamed.
    public var maxChildIndexBytes: Int
    /// The operator's byte budget for headers not yet connected.
    public var pendingBudget: Int
    /// A header dated more than this beyond now is dropped (never blamed)
    /// instead of held: Bitcoin's two hours.
    public var maxFutureDrift: Int64
    /// A child level's proof bounds.
    public var proofs = ChildProofConfig()
    /// How many weighed-but-unexecuted blocks of the best chain, after its
    /// executed prefix, have their bodies asked for at once. Fork children
    /// are asked for besides and are not counted.
    public var bodyWindow: Int
    /// How many ready blocks of one chain one connect job executes, each
    /// the previous one's child, with one commit for them all (Bitcoin's
    /// `ActivateBestChainStep` connects up to 32 per step). An operator
    /// setting (`connectBatch`, `--connect-batch`); at least 1.
    public var connectBatch: Int
    /// A body the content layer could not obtain, or a connect with no
    /// verdict (its content was not resolvable), waits this long before its
    /// body is asked for again, doubling per attempt up to
    /// `bodyRetryCap`. It ends early when the body may now be had: a block
    /// built on it is weighed or its body arrives, or a peer hosting the
    /// level connects. Ending early keeps the attempt count: a body that
    /// fails again waits as long as it would have.
    public var bodyRetryBase: Int64
    public var bodyRetryCap: Int64

    /// The wait after a body's `attempts`-th failed attempt.
    func bodyRetryWait(afterAttempts attempts: Int) -> Int64 {
        min(bodyRetryCap, bodyRetryBase << Int64(min(attempts - 1, 20)))
    }
    /// The level's mempool and template bounds.
    public var mining = MiningConfig()
    /// Node-local finality (docs/operations.md, "Node-local finality"), per chain, in blocks: a header more
    /// than its chain's window below that chain's best weighed tip, or work
    /// crediting such a block, is declined — never stored, never blamed. The
    /// node then does not follow a reorganization deeper than the window. A
    /// chain with no window keeps everything.
    public var finality = FinalityWindows()

    public init(
        maxHeadersPerPage: Int = 2_000,
        maxPageBytes: Int = 1 << 20,
        headersTimeout: Int64 = 30_000,
        servingBudget: Int64? = nil,
        maxInlineChildIndexBytes: Int = 16 * 1_024,
        maxChildIndexBytes: Int = 1 << 20,
        pendingBudget: Int = 16 * 1_024 * 1_024,
        maxFutureDrift: Int64 = 2 * 60 * 60 * 1_000,
        bodyWindow: Int = 64,
        connectBatch: Int = 32,
        bodyRetryBase: Int64 = 1_000,
        bodyRetryCap: Int64 = 300_000
    ) {
        self.maxFutureDrift = maxFutureDrift
        self.maxHeadersPerPage = maxHeadersPerPage
        self.maxPageBytes = maxPageBytes
        self.headersTimeout = headersTimeout
        self.servingBudget = servingBudget ?? headersTimeout / 6
        self.maxInlineChildIndexBytes = maxInlineChildIndexBytes
        self.maxChildIndexBytes = maxChildIndexBytes
        self.pendingBudget = pendingBudget
        self.bodyWindow = bodyWindow
        self.connectBatch = connectBatch
        self.bodyRetryBase = bodyRetryBase
        self.bodyRetryCap = bodyRetryCap
    }

    /// A header as it travels: its children map inline when it fits, and a
    /// genesis's spec.
    public func entry(
        _ block: Block, children: FlatDictionary<BlockHeader>, proofs: [ChildBlockProof] = [], spec: ChainSpec? = nil
    ) -> HeaderEntry {
        let fits = (children.toData()?.count ?? .max) <= maxInlineChildIndexBytes
        return HeaderEntry(block: block, children: fits ? children : nil, proofs: proofs, spec: spec)
    }

    /// Whether `entry` joins a page holding `bytes` so far, `elapsed` ms into
    /// gathering it: the first always does, a later one while the page stays
    /// within `maxPageBytes` and the server within its `servingBudget`. Adds
    /// the entry's size - everything it puts on the wire - to `bytes`. A
    /// server builds its answer through this, so it stops loading headers
    /// once the page is full or its time is spent, instead of building
    /// everything asked and cutting after.
    public func fits(_ entry: HeaderEntry, first: Bool, bytes: inout Int, elapsed: Int64 = 0) -> Bool {
        bytes += ChainCore.size(of: entry)
        return first || (bytes <= maxPageBytes && elapsed <= servingBudget)
    }

    /// The answer the shell sends: `entries` cut at `maxPageBytes` (at least
    /// one), with `hasMore` set when cut. The requester continues after the
    /// last header it receives.
    public func page(_ entries: [HeaderEntry], hasMore: Bool) -> (entries: [HeaderEntry], hasMore: Bool) {
        var total = 0
        for (index, entry) in entries.enumerated() where !fits(entry, first: index == 0, bytes: &total) {
            return (Array(entries[..<index]), true)
        }
        return (entries, hasMore)
    }
}
