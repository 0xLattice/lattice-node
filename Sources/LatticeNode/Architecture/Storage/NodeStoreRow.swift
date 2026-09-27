import Foundation
import Lattice

/// One result row of a `NodeSQLite` query, read through typed accessors.
///
/// This is the ONLY file besides `NodeSQLite.swift` that names
/// `NodeSQLiteValue.textValue` / `intValue` / `blobValue`; every other reader
/// goes through a per-table record built from a `Row`. A column that is
/// missing, NULL where a value is required, of the wrong storage class, or
/// outside the accessor's domain is reported as
/// `NodeStoreError.malformedRow(table:column:)`.
struct Row: Sendable {
    /// Label for errors: the table read, or for a join the tables joined
    /// (`issued_child_proofs⋈issued_child_edges`).
    let table: String
    private let values: [String: NodeSQLiteValue]

    init(table: String, values: [String: NodeSQLiteValue]) {
        self.table = table
        self.values = values
    }

    func text(_ column: String) throws -> String {
        guard let value = values[column]?.textValue else {
            throw malformed(column)
        }
        return value
    }

    func nonEmptyText(_ column: String) throws -> String {
        let value = try text(column)
        guard !value.isEmpty else { throw malformed(column) }
        return value
    }

    /// NULL reads as nil; text reads as its value; anything else is malformed.
    func optionalText(_ column: String) throws -> String? {
        switch values[column] {
        case .null?: return nil
        case .text(let value)?: return value
        default: throw malformed(column)
        }
    }

    /// Text that is a canonical CID.
    func cid(_ column: String) throws -> String {
        let value = try text(column)
        guard CIDIdentity.isCanonical(value) else { throw malformed(column) }
        return value
    }

    /// Text that parses as a UUID.
    func uuid(_ column: String) throws -> String {
        let value = try text(column)
        guard UUID(uuidString: value) != nil else { throw malformed(column) }
        return value
    }

    func int(_ column: String) throws -> Int64 {
        guard let value = values[column]?.intValue else {
            throw malformed(column)
        }
        return value
    }

    /// NULL reads as nil; an integer reads as its value; anything else is
    /// malformed.
    func optionalInt(_ column: String) throws -> Int64? {
        switch values[column] {
        case .null?: return nil
        case .int(let value)?: return value
        default: throw malformed(column)
        }
    }

    func positiveInt(_ column: String) throws -> Int64 {
        let value = try int(column)
        guard value > 0 else { throw malformed(column) }
        return value
    }

    func uint64(_ column: String) throws -> UInt64 {
        guard let value = UInt64(exactly: try int(column)) else {
            throw malformed(column)
        }
        return value
    }

    /// An integer in {0, 1}.
    func bool(_ column: String) throws -> Bool {
        switch try int(column) {
        case 0: return false
        case 1: return true
        default: throw malformed(column)
        }
    }

    func blob(_ column: String) throws -> Data {
        guard let value = values[column]?.blobValue else {
            throw malformed(column)
        }
        return value
    }

    /// A blob decoded as JSON. A decode failure is semantic corruption and
    /// stays `NodeStoreError.corrupt` (via `NodeStore.decode`).
    func decoded<T: Decodable>(_ type: T.Type, _ column: String) throws -> T {
        try NodeStore.decode(type, from: try blob(column))
    }

    private func malformed(_ column: String) -> NodeStoreError {
        .malformedRow(table: table, column: column)
    }
}

/// A typed view over one row of one table (or one fixed join): the only
/// place that spells that table's column names. Accessors are lazy so a
/// statement projecting a subset of the columns still reads through the
/// record.
protocol NodeStoreRecord {
    /// The `Row.table` label every statement over this table uses.
    static var table: String { get }
    init(_ row: Row)
}

extension NodeSQLite {
    func rows(
        from table: String,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> [Row] {
        try query(sql, params: params).map { Row(table: table, values: $0) }
    }

    func row(
        from table: String,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> Row? {
        try rows(from: table, sql, params: params).first
    }

    func rows<Record: NodeStoreRecord>(
        _ type: Record.Type,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> [Record] {
        try rows(from: Record.table, sql, params: params).map(Record.init)
    }

    func row<Record: NodeStoreRecord>(
        _ type: Record.Type,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> Record? {
        try rows(type, sql, params: params).first
    }
}
