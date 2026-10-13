import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    static func int(_ value: Int?) -> SQLiteValue { value.map { .int(Int64($0)) } ?? .null }
    static func double(_ value: Double?) -> SQLiteValue { value.map { .double($0) } ?? .null }
}

/// One result row; valid only inside the `query` callback that produced it.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    func int(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

/// A small synchronous SQLite wrapper with cached prepared statements.
/// Not thread-safe: the owner confines it to one serial queue.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens (creating if needed) the database at `path`; `":memory:"` opens a private in-memory one.
    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open \(path)"
            sqlite3_close(db)
            throw SQLiteError(description: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    /// Runs one or more statements without bindings or results.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? lastError
            sqlite3_free(message)
            throw SQLiteError(description: text)
        }
    }

    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepared(sql, bindings)
        defer { sqlite3_reset(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw SQLiteError(description: lastError) }
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepared(sql, bindings)
        defer { sqlite3_reset(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw SQLiteError(description: lastError) }
            try row(SQLiteRow(statement: statement))
        }
    }

    /// Runs `body` atomically, rolling back if it throws.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get {
            var version = 0
            try? query("PRAGMA user_version") { version = Int($0.int(0) ?? 0) }
            return version
        }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepared(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &created, nil) == SQLITE_OK, let created else {
                throw SQLiteError(description: "\(lastError) in: \(sql)")
            }
            statements[sql] = created
            statement = created
        }
        sqlite3_clear_bindings(statement)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .int(number): status = sqlite3_bind_int64(statement, index, number)
            case let .double(number): status = sqlite3_bind_double(statement, index, number)
            case let .text(string): status = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw SQLiteError(description: lastError) }
        }
        return statement
    }

    /// Tells SQLite to copy bound strings, which Swift only keeps alive for the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
