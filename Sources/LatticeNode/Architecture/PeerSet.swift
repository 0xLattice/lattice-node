import Foundation
import Ivy

/// Everything one plane holds for one peer key, as one value.
protocol PeerRecord {
    /// A record with every field unset.
    init()
    /// True when every field is unset; such a record is never stored.
    var isEmpty: Bool { get }
    /// The session the record is bound to now, if any.
    var liveSessionID: Data? { get }
}

/// The per-peer state of one network plane, keyed by `PeerKey`.
///
/// A key is present exactly while its record holds something: `update`
/// prunes a record that ends up empty, so the key set is the union of the
/// keys the separate per-field maps would hold. `remove` is the one place a
/// disconnect drops a peer; `removeAll` hands every record back so the
/// caller can cancel tasks and resume waiters it owns.
///
/// Only a session's establishment (connect, hello) creates a record, with
/// `update`. Every other write goes through `update(session:)`, which
/// touches only the record still bound to that session, or through
/// `updateExisting`: neither creates one, so work that resumes after its
/// session ended cannot bring the peer's key back. Removal is the same:
/// only a connect replacing the key's old session (and teardown, with
/// `removeAll`) removes by key; a session's end removes with
/// `remove(_:ifBoundTo:)`, which leaves a record a newer session holds.
struct PeerSet<Record: PeerRecord> {
    /// Dictionary-backed: iteration is hash order, as the per-field maps
    /// were; nothing sorts it.
    private(set) var records: [PeerKey: Record] = [:]

    subscript(_ key: PeerKey) -> Record? {
        records[key]
    }

    var keys: Dictionary<PeerKey, Record>.Keys {
        records.keys
    }

    /// Mutates the key's record in place, creating an empty one first when
    /// the key has none, and prunes the record if it is empty afterwards.
    @discardableResult
    mutating func update<T>(
        _ key: PeerKey,
        _ body: (inout Record) throws -> T
    ) rethrows -> T {
        let result = try body(&records[key, default: Record()])
        if records[key]?.isEmpty == true {
            records.removeValue(forKey: key)
        }
        return result
    }

    /// Mutates the record only while it is bound to `peer`'s session; nil
    /// (and no record created) otherwise.
    @discardableResult
    mutating func update<T>(
        session peer: AuthenticatedPeer,
        _ body: (inout Record) throws -> T
    ) rethrows -> T? {
        guard records[peer.key]?.liveSessionID == peer.sessionID else {
            return nil
        }
        return try update(peer.key, body)
    }

    /// Mutates the key's record if it has one; nil (and no record
    /// created) otherwise.
    @discardableResult
    mutating func updateExisting<T>(
        _ key: PeerKey,
        _ body: (inout Record) throws -> T
    ) rethrows -> T? {
        guard records[key] != nil else { return nil }
        return try update(key, body)
    }

    @discardableResult
    mutating func remove(_ key: PeerKey) -> Record? {
        records.removeValue(forKey: key)
    }

    /// Removes the key's record only while it is still bound to
    /// `sessionID` (nil: bound to no session), the binding the caller
    /// sampled for the session that ended; nil otherwise.
    @discardableResult
    mutating func remove(_ key: PeerKey, ifBoundTo sessionID: Data?) -> Record? {
        guard let record = records[key], record.liveSessionID == sessionID else {
            return nil
        }
        records.removeValue(forKey: key)
        return record
    }

    mutating func removeAll() -> [Record] {
        let removed = Array(records.values)
        records.removeAll()
        return removed
    }
}
