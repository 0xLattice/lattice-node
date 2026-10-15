import Foundation
import Ivy
import LatticeNodeCore

/// The peers this node has held an authenticated session with, kept across
/// restarts so that a node which has been on the network finds it again
/// without its bootstrap peers.
///
/// The bootstrap list (built in, or the operator's) is how a node meets the
/// network the first time. Without this it is also how the node meets it
/// every time, because the overlay's routing table lives in memory: every
/// restart of every node leans on the same few hosts, and a node whose
/// bootstrap peers are all unreachable is cut off however long it had run.
///
/// What is remembered is deliberately narrow:
///
/// - Only an address this node dialled itself and reached the peer at. Never
///   one merely heard about, so a peer cannot plant third parties in the
///   book by gossip; and never the address a peer advertises for itself,
///   which is a claim, and is wrong for any host whose outbound address is
///   not the one it listens on. An address is in the book because a dial to
///   it worked.
/// - One address per identity, so an identity cannot fill the book.
/// - A bounded number, a bounded number per network group, and none older
///   than the horizon, so the book cannot grow without limit or be filled
///   from one network.
///
/// A remembered peer gets nothing a stranger does not. It is dialled like any
/// discovered peer, accepted only by its key, subject to the overlay's own
/// admission limits, and never treated as configured: it is not redialled
/// forever and holds no connection slot by right. Nothing here is consensus.
struct PeerBook: Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var publicKey: String
        var host: String
        var port: UInt16
        /// When a session with this peer was last seen open, Unix milliseconds.
        var lastSeen: Int64
        /// Dials that failed since then.
        var failures: Int

        var endpoint: PeerEndpoint { PeerEndpoint(publicKey: publicKey, host: host, port: port) }
    }

    /// The most peers remembered.
    static let capacity = 256
    /// The most remembered from one network group, so one network cannot
    /// become the node's whole memory.
    static let capacityPerGroup = 8
    /// A peer not seen for this long is forgotten: its address is stale.
    static let horizon: Int64 = 30 * 24 * 60 * 60 * 1_000
    /// A peer that refused this many dials in a row since it was last seen is
    /// forgotten.
    static let maxFailures = 10

    private(set) var entries: [String: Entry] = [:]

    init(entries: [Entry] = []) {
        for entry in entries where Self.acceptable(entry) { self.entries[entry.publicKey] = entry }
    }

    /// Record that a dial to each of `endpoints` reached its peer at `now`.
    /// `excluded` are identities never remembered: this node's own and its
    /// configured peers, which it dials anyway.
    mutating func reached(_ endpoints: [PeerEndpoint], excluding excluded: Set<String>, now: Int64) {
        for endpoint in endpoints where !excluded.contains(endpoint.publicKey) {
            let entry = Entry(
                publicKey: endpoint.publicKey, host: endpoint.host, port: endpoint.port,
                lastSeen: now, failures: 0
            )
            guard Self.acceptable(entry) else { continue }
            entries[endpoint.publicKey] = entry
        }
        prune(now: now)
    }

    /// Record that sessions with `publicKeys` are still open at `now`: a
    /// remembered peer that is still here is not ageing.
    mutating func stillOpen(_ publicKeys: Set<String>, now: Int64) {
        for key in publicKeys {
            guard var entry = entries[key] else { continue }
            entry.lastSeen = now
            entry.failures = 0
            entries[key] = entry
        }
        prune(now: now)
    }

    /// Record that a dial to `publicKey` failed.
    mutating func failed(_ publicKey: String) {
        guard var entry = entries[publicKey] else { return }
        entry.failures += 1
        entries[publicKey] = entry.failures >= Self.maxFailures ? nil : entry
    }

    /// Drop what is stale, then what exceeds a group's share, then the
    /// oldest beyond capacity. Within a limit the most recently seen stay.
    mutating func prune(now: Int64) {
        entries = entries.filter { now - $0.value.lastSeen <= Self.horizon }
        let newestFirst = entries.values.sorted {
            ($0.lastSeen, $0.publicKey) > ($1.lastSeen, $1.publicKey)
        }
        var kept: [String: Entry] = [:]
        var perGroup: [String: Int] = [:]
        for entry in newestFirst where kept.count < Self.capacity {
            let group = Self.group(entry.host)
            guard perGroup[group, default: 0] < Self.capacityPerGroup else { continue }
            perGroup[group, default: 0] += 1
            kept[entry.publicKey] = entry
        }
        entries = kept
    }

    /// Up to `count` remembered peers to dial, none of them `connected`. A
    /// random draw, so that no peer chooses the order it is tried in.
    func candidates(
        excluding connected: Set<String>, count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> [PeerEndpoint] {
        entries.values
            .filter { !connected.contains($0.publicKey) }
            .sorted { $0.publicKey < $1.publicKey }
            .shuffled(using: &generator)
            .prefix(max(0, count))
            .map(\.endpoint)
    }

    /// The network group of a host: an IPv4 address's /16, as the overlay's
    /// own connection limit groups them; any other host is its own group.
    static func group(_ host: String) -> String {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            return "\(octets[0]).\(octets[1])"
        }
        return host.lowercased()
    }

    /// Whether an entry could be dialled at all: a well-formed identity, a
    /// plausible host, a port.
    static func acceptable(_ entry: Entry) -> Bool {
        (try? PeerKey(entry.publicKey)) != nil
            && entry.port != 0
            && !entry.host.isEmpty && entry.host.utf8.count <= 253
            && entry.host != "unknown"
            && entry.host.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value != 0x7F }
            && entry.failures >= 0 && entry.failures < maxFailures
    }
}

/// Each hosted chain's peer book and the file they are kept in, beside the
/// node's store. Every chain, Nexus included, has a book of its own under
/// the same rules: the peers this node dialled and reached that said they
/// host that chain. A peer hosting several chains is in each of their books.
/// The file is advisory: absent, unreadable or malformed, it is empty books,
/// never a reason not to start.
actor PeerMemory {
    static let fileName = "peers.json"
    /// A file larger than this for each hosted chain is not this node's
    /// doing, and is not read.
    static let maxFileBytes = 256 * 1024

    /// Version 1: one book for the node, read as Nexus's.
    private struct FileV1: Codable {
        var version: Int
        var peers: [PeerBook.Entry]
    }

    /// Version 2: a book per chain, keyed by chain path.
    private struct File: Codable {
        var version: Int
        var chains: [String: [PeerBook.Entry]]
    }

    private let file: URL
    private let excluded: Set<String>
    private var books: [ChainPath: PeerBook]
    private var written: [ChainPath: PeerBook]
    /// Where a dial of this process reached each peer whose session is still
    /// open: what a book remembers once the peer says it hosts its chain.
    private var dialled: [String: PeerEndpoint] = [:]

    /// `chains`: the hosted chains, Nexus first; a book kept for any other
    /// chain is dropped. `excluded`: identities never remembered (this
    /// node's own key and its configured peers).
    init(directory: URL, chains: [ChainPath], excluding excluded: Set<String>, now: Int64) {
        file = directory.appendingPathComponent(Self.fileName)
        self.excluded = excluded
        var loaded = Self.load(file, chains: chains)
        for chain in chains { loaded[chain, default: PeerBook()].prune(now: now) }
        books = loaded
        written = loaded
    }

    /// Keep a book for a chain hosted since start: the one remembered for it,
    /// or a new one.
    func track(_ chain: ChainPath, now: Int64) {
        guard books[chain] == nil else { return }
        let chains = books.keys.sorted { $0.count < $1.count } + [chain]
        var book = Self.load(file, chains: chains)[chain] ?? PeerBook()
        book.prune(now: now)
        books[chain] = book
        written[chain] = book
    }

    func remembered(for chain: ChainPath) -> [PeerEndpoint] {
        books[chain]?.entries.values.map(\.endpoint) ?? []
    }

    /// Peers remembered for `chain` to dial, none of them `connected` or
    /// excluded.
    func candidates(for chain: ChainPath, excluding connected: Set<String>, count: Int) -> [PeerEndpoint] {
        var generator = SystemRandomNumberGenerator()
        return books[chain]?.candidates(
            excluding: connected.union(excluded), count: count, using: &generator
        ) ?? []
    }

    /// A dial to `publicKey` failed: counted in every book that holds it.
    func failed(_ publicKey: String) {
        for chain in books.keys { books[chain]?.failed(publicKey) }
    }

    /// Record that a dial to `endpoint` reached its peer, which hosts
    /// `chains` as far as is known now. What else it hosts is learned from
    /// its session, in `stillOpen`.
    func reached(_ endpoint: PeerEndpoint, chains: [ChainPath], now: Int64) {
        dialled[endpoint.publicKey] = endpoint
        for chain in chains { books[chain]?.reached([endpoint], excluding: excluded, now: now) }
    }

    /// Record each chain's current peers: one a dial of this process reached
    /// enters the chain's book, one already there is not ageing. A peer that
    /// stopped hosting a chain is no longer refreshed in its book, and ages
    /// out of it. Writes the books if they changed.
    func stillOpen(byChain current: [ChainPath: Set<String>], now: Int64) {
        let open = current.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (chain, keys) in current {
            books[chain]?.reached(keys.compactMap { dialled[$0] }, excluding: excluded, now: now)
            books[chain]?.stillOpen(keys, now: now)
        }
        dialled = dialled.filter { open.contains($0.key) }
        save()
    }

    private func save() {
        guard books != written else { return }
        let chains = Dictionary(uniqueKeysWithValues: books.map { chain, book in
            (chain.joined(separator: "/"), book.entries.values.sorted { $0.publicKey < $1.publicKey })
        })
        guard let data = try? JSONEncoder().encode(File(version: 2, chains: chains)) else { return }
        do {
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            written = books
        } catch {
            // Advisory: a book that cannot be written is rebuilt from the
            // network next time. The node does not stop for it.
        }
    }

    static func load(_ file: URL, chains: [ChainPath]) -> [ChainPath: PeerBook] {
        var books = Dictionary(uniqueKeysWithValues: chains.map { ($0, PeerBook()) })
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= maxFileBytes * max(1, chains.count),
              let data = try? Data(contentsOf: file) else {
            return books
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(File.self, from: data), decoded.version == 2 {
            for chain in chains {
                guard let peers = decoded.chains[chain.joined(separator: "/")] else { continue }
                books[chain] = PeerBook(entries: Array(peers.prefix(PeerBook.capacity * 4)))
            }
        } else if let decoded = try? decoder.decode(FileV1.self, from: data), decoded.version == 1,
                  let nexus = chains.first {
            books[nexus] = PeerBook(entries: Array(decoded.peers.prefix(PeerBook.capacity * 4)))
        }
        return books
    }
}

/// When the seeds are asked. A seed is an introduction, not a peer the node
/// depends on: Bitcoin Core asks its seeds only "if address need is acute",
/// below two outbound peers, so that seeds shape the network as little as
/// possible and a node that knows the network stays off them.
enum SeedPolicy {
    /// With fewer peers than this, the node dials its seeds.
    static let peersBeforeSeeds = 2
    /// The least time, in milliseconds, between maintenance passes brought
    /// forward by a lost session.
    static let retryInterval: Int64 = 10_000

    static func needsSeeds(peers: Int, below threshold: Int = peersBeforeSeeds) -> Bool {
        peers < threshold
    }
}
