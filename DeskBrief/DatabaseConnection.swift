import Foundation
import SQLCipher

enum DatabaseOpenMode: Equatable {
    case plaintext
    case encrypted(DatabasePassphrase)
}

final class DatabaseConnection: @unchecked Sendable {
    let databaseURL: URL
    private let queue = DispatchQueue(label: "DeskBrief.Database")
    private(set) var handle: OpaquePointer?
    private var openMode: DatabaseOpenMode

    init(databaseURL: URL, mode: DatabaseOpenMode) throws {
        self.databaseURL = databaseURL
        self.openMode = mode
        self.handle = try Self.openHandle(databaseURL: databaseURL, mode: mode)
    }

    deinit {
        queue.sync {
            closeLocked()
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

    func rekey(to passphrase: DatabasePassphrase) throws {
        try queue.sync {
            try executeLocked("PRAGMA rekey = \(Self.sqlLiteral(passphrase.value));")
            openMode = .encrypted(passphrase)
            try validateReadableLocked()
        }
    }

    func exportDatabase(to targetURL: URL, mode targetMode: DatabaseOpenMode) throws {
        try queue.sync {
            try exportDatabaseLocked(to: targetURL, mode: targetMode)
        }
    }

    func replaceDatabaseFile(with sourceURL: URL, reopenMode: DatabaseOpenMode) throws {
        try queue.sync {
            closeLocked()
            let fileManager = FileManager.default
            let backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("\(databaseURL.lastPathComponent).replace-backup-\(UUID().uuidString)")

            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.moveItem(at: databaseURL, to: backupURL)
            }
            for sidecarURL in AppDatabase.databaseSidecarURLs(for: databaseURL)
                where fileManager.fileExists(atPath: sidecarURL.path) {
                try fileManager.removeItem(at: sidecarURL)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: databaseURL)
                handle = try Self.openHandle(databaseURL: databaseURL, mode: reopenMode)
                openMode = reopenMode
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
            } catch {
                if fileManager.fileExists(atPath: databaseURL.path) {
                    try? fileManager.removeItem(at: databaseURL)
                }
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: databaseURL)
                }
                handle = try? Self.openHandle(databaseURL: databaseURL, mode: openMode)
                throw error
            }
        }
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

    func int64ValueLocked(_ sql: String) throws -> Int64 {
        let stmt = try prepareStatementLocked(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.execute("expected row for \(sql)")
        }
        return sqlite3_column_int64(stmt, 0)
    }

    func stringValueLocked(_ sql: String) throws -> String {
        let stmt = try prepareStatementLocked(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.execute("expected row for \(sql)")
        }
        guard let text = sqlite3_column_text(stmt, 0) else {
            return ""
        }
        return String(cString: text)
    }

    private static func openHandle(databaseURL: URL, mode: DatabaseOpenMode) throws -> OpaquePointer? {
        var opened: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &opened) == SQLITE_OK else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(opened)
            throw DatabaseError.openDatabase(message)
        }

        do {
            if case .encrypted(let passphrase) = mode {
                try applyPassphrase(passphrase, to: opened)
            }
            try execute("PRAGMA foreign_keys = ON;", handle: opened)
            try validateReadable(handle: opened)
            return opened
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    private static func applyPassphrase(_ passphrase: DatabasePassphrase, to handle: OpaquePointer?) throws {
        let bytes = Array(passphrase.value.utf8)
        let rc = bytes.withUnsafeBufferPointer { buffer in
            sqlite3_key(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite key failed"
            throw DatabaseError.invalidPassphrase(message)
        }
    }

    private static func execute(_ sql: String, handle: OpaquePointer?) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
            throw DatabaseError.execute(message)
        }
    }

    private static func validateReadable(handle: OpaquePointer?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master;", -1, &statement, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
            throw DatabaseError.invalidPassphrase(message)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database not readable"
            throw DatabaseError.invalidPassphrase(message)
        }
    }

    private func validateReadableLocked() throws {
        try Self.validateReadable(handle: handle)
    }

    private func exportDatabaseLocked(to targetURL: URL, mode targetMode: DatabaseOpenMode) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }

        let targetKey: String
        switch targetMode {
        case .plaintext:
            targetKey = ""
        case .encrypted(let passphrase):
            targetKey = passphrase.value
        }

        let currentUserVersion = try int64ValueLocked("PRAGMA user_version;")
        let schemaCounts = try schemaCountsLocked()
        let targetPath = Self.sqlLiteral(targetURL.path)
        let targetKeyLiteral = Self.sqlLiteral(targetKey)
        try executeLocked("ATTACH DATABASE \(targetPath) AS converted KEY \(targetKeyLiteral);")
        do {
            try executeLocked("SELECT sqlcipher_export('converted');")
            try executeLocked("PRAGMA converted.user_version = \(currentUserVersion);")
            try executeLocked("DETACH DATABASE converted;")
        } catch {
            try? executeLocked("DETACH DATABASE converted;")
            throw error
        }

        try Self.validateDatabase(
            at: targetURL,
            mode: targetMode,
            expectedUserVersion: currentUserVersion,
            expectedSchemaCounts: schemaCounts
        )
    }

    private func schemaCountsLocked() throws -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for tableName in Self.validationTableNames {
            let exists = try int64ValueLocked(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = \(Self.sqlLiteral(tableName));"
            )
            guard exists > 0 else {
                continue
            }
            counts[tableName] = try int64ValueLocked("SELECT count(*) FROM \(Self.quotedIdentifier(tableName));")
        }
        return counts
    }

    private static func validateDatabase(
        at url: URL,
        mode: DatabaseOpenMode,
        expectedUserVersion: Int64,
        expectedSchemaCounts: [String: Int64]
    ) throws {
        let validationHandle = try openHandle(databaseURL: url, mode: mode)
        defer { sqlite3_close(validationHandle) }

        let integrity = try stringValue("PRAGMA integrity_check;", handle: validationHandle)
        guard integrity == "ok" else {
            throw DatabaseError.execute("converted database integrity_check failed: \(integrity)")
        }

        let userVersion = try int64Value("PRAGMA user_version;", handle: validationHandle)
        guard userVersion == expectedUserVersion else {
            throw DatabaseError.execute("converted database user_version mismatch: \(userVersion) != \(expectedUserVersion)")
        }

        for (tableName, expectedCount) in expectedSchemaCounts {
            let actualCount = try int64Value(
                "SELECT count(*) FROM \(quotedIdentifier(tableName));",
                handle: validationHandle
            )
            guard actualCount == expectedCount else {
                throw DatabaseError.execute("converted database row count mismatch for \(tableName): \(actualCount) != \(expectedCount)")
            }
        }
    }

    private static func int64Value(_ sql: String, handle: OpaquePointer?) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
            throw DatabaseError.prepareStatement(message)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.execute("expected row for \(sql)")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func stringValue(_ sql: String, handle: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
            throw DatabaseError.prepareStatement(message)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.execute("expected row for \(sql)")
        }
        guard let text = sqlite3_column_text(statement, 0) else {
            return ""
        }
        return String(cString: text)
    }

    private func closeLocked() {
        sqlite3_close(handle)
        handle = nil
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let validationTableNames = [
        "category_rules",
        "analysis_runs",
        "summary_runs",
        "analysis_results",
        "daily_reports",
        "daily_work_block_summaries",
        "app_logs",
    ]

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw DatabaseError.execute("failed to bind null at index \(index)")
            }
            return
        }

        let utf8 = value.utf8CString
        let byteCount = utf8.count * MemoryLayout<CChar>.stride
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            throw DatabaseError.execute("failed to allocate memory for text binding at index \(index)")
        }

        let dest = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: CChar.self)
        utf8.withUnsafeBufferPointer { src in
            dest.initialize(from: src.baseAddress!, count: utf8.count)
        }

        let rc = sqlite3_bind_text(statement, index, dest, -1, sqlite3_free)
        guard rc == SQLITE_OK else {
            sqlite3_free(buffer)
            throw DatabaseError.execute("failed to bind text at index \(index): \(rc)")
        }
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
        try bind(tableName, at: 1, to: stmt)
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

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) throws {
        try connection.bind(value, at: index, to: statement)
    }

    func string(at index: Int32, from statement: OpaquePointer?) -> String {
        connection.string(at: index, from: statement)
    }

    func ensureTableExists(_ tableName: String) throws {
        try connection.ensureTableExistsLocked(tableName)
    }

    func int64Value(_ sql: String) throws -> Int64 {
        try connection.int64ValueLocked(sql)
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
