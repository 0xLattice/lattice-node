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
package struct Row: Sendable {
    /// Label for errors: the table read, or for a join the tables joined
    /// (`issued_child_proofs⋈issued_child_edges`).
    package let table: String
    private let values: [String: NodeSQLiteValue]

    package init(table: String, values: [String: NodeSQLiteValue]) {
        self.table = table
        self.values = values
    }

    package func text(_ column: String) throws -> String {
        guard let value = values[column]?.textValue else {
            throw malformed(column)
        }
        return value
    }

    package func nonEmptyText(_ column: String) throws -> String {
        let value = try text(column)
        guard !value.isEmpty else { throw malformed(column) }
        return value
    }

    /// NULL reads as nil; text reads as its value; anything else is malformed.
    package func optionalText(_ column: String) throws -> String? {
        switch values[column] {
        case .null?: return nil
        case .text(let value)?: return value
        default: throw malformed(column)
        }
    }

    /// Text that is a canonical CID.
    package func cid(_ column: String) throws -> String {
        let value = try text(column)
        guard CIDIdentity.isCanonical(value) else { throw malformed(column) }
        return value
    }

    package func int(_ column: String) throws -> Int64 {
        guard let value = values[column]?.intValue else {
            throw malformed(column)
        }
        return value
    }

    package func positiveInt(_ column: String) throws -> Int64 {
        let value = try int(column)
        guard value > 0 else { throw malformed(column) }
        return value
    }

    package func nonNegativeInt(_ column: String) throws -> Int64 {
        let value = try int(column)
        guard value >= 0 else { throw malformed(column) }
        return value
    }

    package func uint64(_ column: String) throws -> UInt64 {
        guard let value = UInt64(exactly: try int(column)) else {
            throw malformed(column)
        }
        return value
    }

    package func blob(_ column: String) throws -> Data {
        guard let value = values[column]?.blobValue else {
            throw malformed(column)
        }
        return value
    }

    private func malformed(_ column: String) -> NodeStoreError {
        .malformedRow(table: table, column: column)
    }
}

/// A typed view over one row of one table (or one fixed join): the only
/// place that spells that table's column names. A record either reads its
/// columns lazily (so a statement projecting a subset still reads through
/// it) or validates them all in `init` and throws.
package protocol NodeStoreRecord {
    /// The `Row.table` label every statement over this table uses.
    static var table: String { get }
    init(_ row: Row) throws
}

extension NodeSQLite {
    package func rows(
        from table: String,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> [Row] {
        try query(sql, params: params).map { Row(table: table, values: $0) }
    }

    package func row(
        from table: String,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> Row? {
        try rows(from: table, sql, params: params).first
    }

    package func rows<Record: NodeStoreRecord>(
        _ type: Record.Type,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> [Record] {
        try rows(from: Record.table, sql, params: params).map(Record.init)
    }

    package func row<Record: NodeStoreRecord>(
        _ type: Record.Type,
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> Record? {
        try rows(type, sql, params: params).first
    }
}
