import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

enum SQLValue {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

/// One result row, read by column index while its statement is stepped.
struct SQLRow {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// The small SQLite surface the store needs: one connection, cached
/// statements, and `BEGIN IMMEDIATE` transactions. Not thread-safe: `Store`
/// serializes every call.
final class SQLite {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            throw StoreError.sqlite(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// Run one or more statements without parameters (DDL, pragmas).
    func script(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw StoreError.sqlite(text)
        }
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try each(sql, params) { _ in }
    }

    /// Step `sql` to completion, handing every row to `body`.
    func each(_ sql: String, _ params: [SQLValue] = [], _ body: (SQLRow) throws -> Void) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(params, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(SQLRow(statement: statement))
            case SQLITE_DONE: return
            default: throw StoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func first<T>(_ sql: String, _ params: [SQLValue] = [], _ read: (SQLRow) throws -> T) throws -> T? {
        var value: T?
        try each(sql, params) { row in
            if value == nil { value = try read(row) }
        }
        return value
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try run("COMMIT")
            return value
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ params: [SQLValue], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .int(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .blob(let data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(data.count), transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(handle))) }
        }
    }
}
