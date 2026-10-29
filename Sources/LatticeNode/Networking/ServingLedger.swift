import Foundation
import Ivy
import Tally

/// Each peer's prepaid serving balance, in bytes, and the payments already
/// credited, kept across restarts in a file beside the node's store.
///
/// Tally holds the live balances and spends them on contended serving; this
/// restores them at start and writes them back after each credit, on every
/// maintenance pass and at a clean stop. A crash loses the spending since the
/// last write, never a credit: a credit is written before it is applied, and
/// a payment is never credited twice.
public actor ServingLedger {
    static let fileName = "serving.json"

    private struct File: Codable {
        var version: Int
        /// Peer key (raw hex) to bytes.
        var balances: [String: Int]
        /// Transaction CIDs whose payments were credited.
        var credited: [String]
    }

    private let file: URL
    private let tally: Tally
    private var credited: Set<String>
    private var written: [String: Int]

    /// Restores the balances on file into `tally`. A file that is there but
    /// cannot be read fails the start: it holds the payments already
    /// credited, and starting without them would credit them again.
    init(directory: URL, tally: Tally) throws {
        file = directory.appendingPathComponent(Self.fileName)
        self.tally = tally
        guard FileManager.default.fileExists(atPath: file.path) else {
            credited = []
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
        credited = Set(saved.credited)
        written = Self.balances(of: tally)
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
        try apply(peer: peer, bytes: bytes, payment: nil)
        return tally.servingBalance(for: peer)
    }

    /// Credits a payment's `bytes` to the peer once: a payment credited
    /// before is refused.
    public func credit(peer key: String, bytes: Int, payment: String) throws -> Int {
        guard let peer = Self.peer(key) else { throw ServingLedgerError.invalidPeer }
        guard !credited.contains(payment) else { throw ServingLedgerError.alreadyCredited }
        try apply(peer: peer, bytes: bytes, payment: payment)
        return tally.servingBalance(for: peer)
    }

    /// Writes the balances as Tally holds them now, when they changed.
    /// Unwritten, they are written next time.
    public func save() {
        let balances = Self.balances(of: tally)
        guard balances != written else { return }
        try? write(balances, credited: credited)
    }

    /// The credit written first, then applied: one that cannot be written
    /// is not applied.
    private func apply(peer: PeerID, bytes: Int, payment: String?) throws {
        var balances = Self.balances(of: tally)
        let (sum, overflow) = balances[peer.publicKey, default: 0].addingReportingOverflow(bytes)
        balances[peer.publicKey] = overflow ? .max : sum
        var credited = credited
        if let payment { credited.insert(payment) }
        do {
            try write(balances, credited: credited)
        } catch {
            throw ServingLedgerError.notSaved
        }
        self.credited = credited
        tally.creditServingBalance(peer: peer, bytes: bytes)
    }

    private func write(_ balances: [String: Int], credited: Set<String>) throws {
        let data = try JSONEncoder().encode(File(version: 1, balances: balances, credited: credited.sorted()))
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        written = balances
    }

    private static func balances(of tally: Tally) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: tally.servingBalances().map { ($0.key.publicKey, $0.value) })
    }
}

public enum ServingLedgerError: Error, Equatable, CustomStringConvertible {
    case invalidPeer
    case invalidBytes
    case alreadyCredited
    case notSaved
    case unreadable(String)

    public var description: String {
        switch self {
        case .invalidPeer: "invalidPeer"
        case .invalidBytes: "invalidBytes"
        case .alreadyCredited: "alreadyCredited"
        case .notSaved: "notSaved"
        case .unreadable(let path):
            "\(path) cannot be read: it holds the serving payments already credited; restore it or remove it to forget them"
        }
    }
}
