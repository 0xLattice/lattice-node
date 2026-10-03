import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

enum NodeSQLiteError: Error {
    case open(String)
    case prepare(String)
    case execute(String)
}

enum NodeSQLiteValue {
    case text(String)
    case int(Int64)
    case blob(Data)
    case null

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var blobValue: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}

/// The small SQLite surface needed by the immutable node store.
final class NodeSQLite: @unchecked Sendable {
    private let handle: OpaquePointer

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database { sqlite3_close(database) }
            throw NodeSQLiteError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close(handle)
    }

    func configureDurability() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
    }

    @discardableResult
    func execute(_ sql: String, params: [NodeSQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, params: params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw NodeSQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    func query(
        _ sql: String,
        params: [NodeSQLiteValue] = []
    ) throws -> [[String: NodeSQLiteValue]] {
        let statement = try prepare(sql, params: params)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: NodeSQLiteValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: NodeSQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER:
                        row[name] = .int(sqlite3_column_int64(statement, index))
                    case SQLITE_TEXT:
                        row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        if let bytes = sqlite3_column_blob(statement, index) {
                            row[name] = .blob(Data(bytes: bytes, count: count))
                        } else {
                            row[name] = .blob(Data())
                        }
                    default:
                        row[name] = .null
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw NodeSQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(
        _ sql: String,
        params: [NodeSQLiteValue]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NodeSQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        do {
            for (offset, value) in params.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text):
                    result = sqlite3_bind_text(
                        statement,
                        index,
                        text,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                case .int(let integer):
                    result = sqlite3_bind_int64(statement, index, integer)
                case .blob(let data):
                    result = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement,
                            index,
                            bytes.baseAddress,
                            Int32(data.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                        )
                    }
                case .null:
                    result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else {
                    throw NodeSQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }
}
