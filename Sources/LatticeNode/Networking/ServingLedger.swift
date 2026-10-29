import Foundation
import Ivy
import Tally

/// Each peer's prepaid serving balance, in bytes, kept across restarts in a
/// file beside the node's store.
///
/// Tally holds the live balances and spends them on contended serving; this
/// restores them at start and writes them back after each credit, on every
/// maintenance pass and at a clean stop. A crash loses the spending since the
/// last write, never a credit: a credit is written before it is applied.
public actor ServingLedger {
    static let fileName = "serving.json"

    /// Fields it does not name (an older file's credited payments) are
    /// ignored.
    private struct File: Codable {
        var version: Int
        /// Peer key (raw hex) to bytes.
        var balances: [String: Int]
    }

    private let file: URL
    private let tally: Tally
    /// The most balances Tally keeps. Past it Tally drops the smallest to
    /// make room, so a flood of fresh peers cannot erase larger balances; a
    /// new peer's credit no larger than the smallest is refused instead of
    /// being dropped as soon as it is granted.
    private let capacity: Int
    private var written: [String: Int]

    /// Restores the balances on file into `tally`. A file that is there but
    /// cannot be read fails the start: starting without it would lose the
    /// balances it holds.
    init(directory: URL, tally: Tally, config: TallyConfig = .default) throws {
        file = directory.appendingPathComponent(Self.fileName)
        self.tally = tally
        capacity = Self.capacity(config)
        guard FileManager.default.fileExists(atPath: file.path) else {
            written = [:]
            return
        }
        let saved: File
        do {
            saved = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
        } catch {
            throw ServingLedgerError.unreadable(file.path)
        }
        guard saved.version == 1 else { throw ServingLedgerError.unreadable(file.path) }
        for (key, bytes) in saved.balances {
            guard let peer = Self.peer(key) else { throw ServingLedgerError.unreadable(file.path) }
            tally.creditServingBalance(peer: peer, bytes: bytes)
        }
        written = Self.balances(of: tally)
    }

    /// Tally's own bound on the peers it keeps state for, which it does not
    /// export: four per `maxPeers`, or 4096.
    static func capacity(_ config: TallyConfig) -> Int {
        guard let maxPeers = config.maxPeers else { return 4096 }
        return max(maxPeers, 1) <= Int.max / 4 ? max(maxPeers, 1) * 4 : .max
    }

    /// A peer as Ivy and the node print it: its Ed25519 public key, 64
    /// lowercase hex characters. Any other spelling is nil.
    static func peer(_ key: String) -> PeerID? {
        guard isPeer(key) else { return nil }
        return PeerID(publicKey: key)
    }

    public static func isPeer(_ key: String) -> Bool {
        (try? PeerKey(key))?.hex == key
    }

    public func balance(peer key: String) throws -> Int {
        guard let peer = Self.peer(key) else { throw ServingLedgerError.invalidPeer }
        return tally.servingBalance(for: peer)
    }

    /// Credits `bytes` to the peer and answers its balance.
    public func credit(peer key: String, bytes: Int) throws -> Int {
        guard let peer = Self.peer(key) else { throw ServingLedgerError.invalidPeer }
        guard bytes > 0 else { throw ServingLedgerError.invalidBytes }
        try apply(peer: peer, bytes: bytes)
        return tally.servingBalance(for: peer)
    }

    /// Writes the balances as Tally holds them now, when they changed.
    /// Unwritten, they are written next time.
    public func save() {
        let balances = Self.balances(of: tally)
        guard balances != written else { return }
        try? write(balances)
    }

    /// The credit written first, then applied: one that cannot be written
    /// is not applied.
    private func apply(peer: PeerID, bytes: Int) throws {
        var balances = Self.balances(of: tally)
        if balances[peer.publicKey] == nil, balances.count >= capacity {
            guard let smallest = balances.min(by: { $0.value < $1.value }), bytes > smallest.value else {
                throw ServingLedgerError.balancesFull
            }
            balances[smallest.key] = nil
        }
        let (sum, overflow) = balances[peer.publicKey, default: 0].addingReportingOverflow(bytes)
        balances[peer.publicKey] = overflow ? .max : sum
        do {
            try write(balances)
        } catch {
            throw ServingLedgerError.notSaved
        }
        tally.creditServingBalance(peer: peer, bytes: bytes)
        // What Tally made room with, should it differ from what was written.
        save()
    }

    /// Replaced atomically and synced, with its directory, to stable
    /// storage: a credit must not be lost after a power loss.
    private func write(_ balances: [String: Int]) throws {
        let data = try JSONEncoder().encode(File(version: 1, balances: balances))
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for path in [file.path, file.deletingLastPathComponent().path] {
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else { throw ServingLedgerError.notSaved }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw ServingLedgerError.notSaved }
        }
        written = balances
    }

    private static func balances(of tally: Tally) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: tally.servingBalances().map { ($0.key.publicKey, $0.value) })
    }
}

public enum ServingLedgerError: Error, Equatable, CustomStringConvertible {
    case invalidPeer
    case invalidBytes
    case balancesFull
    case notSaved
    case unreadable(String)

    public var description: String {
        switch self {
        case .invalidPeer: "invalidPeer"
        case .invalidBytes: "invalidBytes"
        case .balancesFull: "balancesFull"
        case .notSaved: "notSaved"
        case .unreadable(let path):
            "\(path) cannot be read: it holds the peers' prepaid serving balances, and starting without it would lose them; restore it"
        }
    }
}
