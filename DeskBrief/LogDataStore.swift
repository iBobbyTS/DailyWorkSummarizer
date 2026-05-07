import Foundation
import GRDB

final class LogDataStore: @unchecked Sendable {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func fetchAppLogs(limit: Int? = nil) throws -> [AppLogEntry] {
        try connection.read { db in
            guard let limit, limit > 0 else {
                if limit != nil {
                    return []
                }
                return try AppLogRow
                    .order(AppLogRow.Columns.createdAt.desc, AppLogRow.Columns.id.desc)
                    .fetchAll(db)
                    .compactMap(Self.appLogEntry)
            }

            return try AppLogRow
                .order(AppLogRow.Columns.createdAt.desc, AppLogRow.Columns.id.desc)
                .limit(limit)
                .fetchAll(db)
                .compactMap(Self.appLogEntry)
        }
    }

    func insertAppLog(_ entry: AppLogEntry, maxEntries: Int = AppDefaults.maxLogEntries) throws {
        try connection.write { db in
            try AppLogRow(
                id: entry.id.uuidString,
                createdAt: entry.createdAt.timeIntervalSince1970,
                level: entry.level.rawValue,
                source: entry.source.rawValue,
                message: entry.message
            ).insert(db)

            try pruneAppLogsIfNeeded(db: db, maxEntries: maxEntries)
        }
    }

    func deleteAppLog(id: UUID) throws {
        _ = try connection.write { db in
            try AppLogRow.deleteOne(db, key: id.uuidString)
        }
    }

    func deleteAllAppLogs() throws {
        _ = try connection.write { db in
            try AppLogRow.deleteAll(db)
        }
    }

    nonisolated private static func appLogEntry(_ row: AppLogRow) -> AppLogEntry? {
        guard let id = UUID(uuidString: row.id),
              let level = AppLogLevel(rawValue: row.level),
              let source = AppLogSource(rawValue: row.source) else {
            return nil
        }

        return AppLogEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: row.createdAt),
            level: level,
            source: source,
            message: row.message
        )
    }

    private func pruneAppLogsIfNeeded(db: Database, maxEntries: Int) throws {
        guard maxEntries > 0 else {
            try AppLogRow.deleteAll(db)
            return
        }

        let idsToKeep = try AppLogRow
            .select(AppLogRow.Columns.id)
            .order(AppLogRow.Columns.createdAt.desc, AppLogRow.Columns.id.desc)
            .limit(maxEntries)
            .asRequest(of: String.self)
            .fetchAll(db)

        if idsToKeep.isEmpty {
            try AppLogRow.deleteAll(db)
            return
        }

        try AppLogRow
            .filter(!idsToKeep.contains(AppLogRow.Columns.id))
            .deleteAll(db)
    }
}
