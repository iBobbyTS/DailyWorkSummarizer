import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseConnection: @unchecked Sendable {
    let databaseURL: URL
    private let queue = DispatchQueue(label: "DeskBrief.Database")
    private(set) var handle: OpaquePointer?

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        var opened: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &opened) == SQLITE_OK else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(opened)
            throw DatabaseError.openDatabase(message)
        }
        self.handle = opened
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        queue.sync {
            sqlite3_close(handle)
            handle = nil
        }
    }

    func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        try queue.sync {
            try prepareStatementLocked(sql)
        }
    }

    func execute(_ sql: String) throws {
        try queue.sync {
            try executeLocked(sql)
        }
    }

    func withLock<T>(_ block: (DatabaseLock) throws -> T) rethrows -> T {
        try queue.sync {
            try block(DatabaseLock(connection: self))
        }
    }

    func lock() -> DatabaseLock {
        DatabaseLock(connection: self)
    }

    func prepareStatementLocked(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareStatement(errorMessage)
        }
        return statement
    }

    func executeLocked(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(errorMessage)
        }
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    func string(at index: Int32, from statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: value)
    }

    func ensureTableExistsLocked(_ tableName: String) throws {
        let stmt = try prepareStatementLocked(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(stmt) }
        bind(tableName, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.prepareStatement("missing table \(tableName)")
        }
    }

    func changes() -> Int32 {
        guard let handle else { return 0 }
        return sqlite3_changes(handle)
    }

    private var errorMessage: String {
        guard let handle else { return "database not open" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

struct DatabaseLock {
    fileprivate let connection: DatabaseConnection

    func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        try connection.prepareStatementLocked(sql)
    }

    func execute(_ sql: String) throws {
        try connection.executeLocked(sql)
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
        connection.bind(value, at: index, to: statement)
    }

    func string(at index: Int32, from statement: OpaquePointer?) -> String {
        connection.string(at: index, from: statement)
    }

    func ensureTableExists(_ tableName: String) throws {
        try connection.ensureTableExistsLocked(tableName)
    }

    func changes() -> Int32 {
        connection.changes()
    }

    func lastInsertRowid() -> Int64 {
        guard let handle = connection.handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
    }

    func commitTransaction() throws {
        try execute("COMMIT TRANSACTION")
    }

    func rollbackTransaction() throws {
        try execute("ROLLBACK TRANSACTION")
    }
}
