import Foundation
import Ivy
import Tally

/// Each peer's standing, in bytes, kept across restarts in a file beside the
/// node's store. Standing does not decay, so every positive one is kept.
///
/// Tally holds the live standings: it raises them for verified content a peer
/// served this node and lowers them by the Volume bytes served to it. This
/// restores them at start and writes them back after each operator credit, on
/// every maintenance pass and at a clean stop. A crash loses only the changes
/// since the last write, never an operator credit: a credit is written before
/// it is applied.
public actor ServingLedger {
    static let fileName = "serving.json"

    /// Fields it does not name (an older file's credited payments) are
    /// ignored.
    private struct File: Codable {
        var version: Int
        /// Peer key (raw hex) to bytes of standing.
        var standings: [String: Int]

        enum CodingKeys: String, CodingKey {
            case version
            case standings = "balances"
        }
    }

    private let file: URL
    private let tally: Tally
    private var written: [String: Int]

    /// Restores the standings on file into `tally`. A file that is there but
    /// cannot be read fails the start: starting without it would lose the
    /// standings it holds.
    init(directory: URL, tally: Tally) throws {
        file = directory.appendingPathComponent(Self.fileName)
        self.tally = tally
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
        for (key, bytes) in saved.standings {
            guard let peer = Self.peer(key) else { throw ServingLedgerError.unreadable(file.path) }
            tally.creditStanding(peer: peer, bytes: bytes)
        }
        written = Self.standings(of: tally)
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

    public func standing(peer key: String) throws -> Int {
        guard let peer = Self.peer(key) else { throw ServingLedgerError.invalidPeer }
        return tally.standing(for: peer)
    }

    /// Credits `bytes` to the peer's standing and answers the standing.
    public func credit(peer key: String, bytes: Int) throws -> Int {
        guard let peer = Self.peer(key) else { throw ServingLedgerError.invalidPeer }
        guard bytes > 0 else { throw ServingLedgerError.invalidBytes }
        try apply(peer: peer, bytes: bytes)
        return tally.standing(for: peer)
    }

    /// Writes the standings as Tally holds them now, when they changed.
    /// Unwritten, they are written next time.
    public func save() {
        let standings = Self.standings(of: tally)
        guard standings != written else { return }
        try? write(standings)
    }

    /// The credit written first, then applied: one that cannot be written
    /// is not applied.
    private func apply(peer: PeerID, bytes: Int) throws {
        var standings = Self.standings(of: tally)
        let (sum, overflow) = standings[peer.publicKey, default: 0].addingReportingOverflow(bytes)
        standings[peer.publicKey] = overflow ? .max : sum
        do {
            try write(standings)
        } catch {
            throw ServingLedgerError.notSaved
        }
        tally.creditStanding(peer: peer, bytes: bytes)
        // What serving changed between the read and the credit.
        save()
    }

    /// Replaced atomically and synced, with its directory, to stable
    /// storage: a credit must not be lost after a power loss.
    private func write(_ standings: [String: Int]) throws {
        let data = try JSONEncoder().encode(File(version: 1, standings: standings))
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for path in [file.path, file.deletingLastPathComponent().path] {
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else { throw ServingLedgerError.notSaved }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw ServingLedgerError.notSaved }
        }
        written = standings
    }

    private static func standings(of tally: Tally) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: tally.standings().map { ($0.key.publicKey, $0.value) })
    }
}

public enum ServingLedgerError: Error, Equatable, CustomStringConvertible {
    case invalidPeer
    case invalidBytes
    case notSaved
    case unreadable(String)

    public var description: String {
        switch self {
        case .invalidPeer: "invalidPeer"
        case .invalidBytes: "invalidBytes"
        case .notSaved: "notSaved"
        case .unreadable(let path):
            "\(path) cannot be read: it holds the peers' serving standings, and starting without it would lose them; restore it"
        }
    }
}
