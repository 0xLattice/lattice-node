import Ivy

/// Everything one plane holds for one peer key, as one value.
protocol PeerRecord {
    /// A record with every field unset.
    init()
    /// True when every field is unset; such a record is never stored.
    var isEmpty: Bool { get }
}

/// The per-peer state of one network plane, keyed by `PeerKey`.
///
/// A key is present exactly while its record holds something: `update`
/// prunes a record that ends up empty, so the key set is the union of the
/// keys the separate per-field maps would hold. `remove` is the one place a
/// disconnect drops a peer; `removeAll` hands every record back so the
/// caller can cancel tasks and resume waiters it owns.
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

    @discardableResult
    mutating func remove(_ key: PeerKey) -> Record? {
        records.removeValue(forKey: key)
    }

    mutating func removeAll() -> [Record] {
        let removed = Array(records.values)
        records.removeAll()
        return removed
    }
}
