import Foundation
import SQLite3

final class LogDataStore: @unchecked Sendable {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func fetchAppLogs(limit: Int? = nil) throws -> [AppLogEntry] {
        try connection.withLock { lock in
            guard let limit, limit > 0 else {
                if limit != nil {
                    return []
                }
                let stmt = try lock.prepareStatement("""
                    SELECT id, created_at, level, source, message
                    FROM app_logs
                    ORDER BY created_at DESC, id DESC;
                """)
                defer { sqlite3_finalize(stmt) }
                return try Self.readAppLogEntries(from: stmt, lock: lock)
            }

            let stmt = try lock.prepareStatement("""
                SELECT id, created_at, level, source, message
                FROM app_logs
                ORDER BY created_at DESC, id DESC
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))

            return try Self.readAppLogEntries(from: stmt, lock: lock)
        }
    }

    private static func readAppLogEntries(from stmt: OpaquePointer?, lock: DatabaseLock) throws -> [AppLogEntry] {
        var entries: [AppLogEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idString = lock.string(at: 0, from: stmt)
            let createdAt = sqlite3_column_double(stmt, 1)
            let levelString = lock.string(at: 2, from: stmt)
            let sourceString = lock.string(at: 3, from: stmt)
            let message = lock.string(at: 4, from: stmt)

            guard let id = UUID(uuidString: idString),
                  let level = AppLogLevel(rawValue: levelString),
                  let source = AppLogSource(rawValue: sourceString) else {
                continue
            }

            entries.append(AppLogEntry(
                id: id,
                createdAt: Date(timeIntervalSince1970: createdAt),
                level: level,
                source: source,
                message: message
            ))
        }
        return entries
    }

    func insertAppLog(_ entry: AppLogEntry, maxEntries: Int = AppDefaults.maxLogEntries) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT INTO app_logs (id, created_at, level, source, message)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            try lock.bind(entry.id.uuidString, at: 1, to: stmt)
            sqlite3_bind_double(stmt, 2, entry.createdAt.timeIntervalSince1970)
            try lock.bind(entry.level.rawValue, at: 3, to: stmt)
            try lock.bind(entry.source.rawValue, at: 4, to: stmt)
            try lock.bind(entry.message, at: 5, to: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("insert app_log failed")
            }

            try pruneAppLogsIfNeeded(lock: lock, maxEntries: maxEntries)
        }
    }

    func deleteAppLog(id: UUID) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("DELETE FROM app_logs WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            try lock.bind(id.uuidString, at: 1, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("delete app_log failed")
            }
        }
    }

    func deleteAllAppLogs() throws {
        try connection.withLock { lock in
            try lock.execute("DELETE FROM app_logs;")
        }
    }

    private func pruneAppLogsIfNeeded(lock: DatabaseLock, maxEntries: Int) throws {
        guard maxEntries > 0 else {
            try lock.execute("DELETE FROM app_logs;")
            return
        }

        let stmt = try lock.prepareStatement("""
            DELETE FROM app_logs
            WHERE id NOT IN (
                SELECT id FROM app_logs
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            );
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(maxEntries))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.execute("prune app_logs failed")
        }
    }
}
