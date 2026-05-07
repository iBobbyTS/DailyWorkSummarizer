import Foundation
import GRDB
import SQLCipher

enum DatabaseOpenMode: Equatable {
    case plaintext
    case encrypted(DatabasePassphrase)
}

nonisolated final class DatabaseConnection: @unchecked Sendable {
    let databaseURL: URL
    private var dbQueue: DatabaseQueue
    private var openMode: DatabaseOpenMode

    init(databaseURL: URL, mode: DatabaseOpenMode) throws {
        self.databaseURL = databaseURL
        self.openMode = mode
        self.dbQueue = try Self.openQueue(databaseURL: databaseURL, mode: mode)
    }

    deinit {
        try? dbQueue.close()
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    func writeWithoutTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.writeWithoutTransaction(block)
    }

    func rekey(to passphrase: DatabasePassphrase) throws {
        try dbQueue.barrierWriteWithoutTransaction { db in
            try db.changePassphrase(passphrase.value)
            try Self.validateReadable(db)
        }
        openMode = .encrypted(passphrase)
    }

    func exportDatabase(to targetURL: URL, mode targetMode: DatabaseOpenMode) throws {
        try dbQueue.barrierWriteWithoutTransaction { db in
            try exportDatabaseLocked(db: db, to: targetURL, mode: targetMode)
        }
    }

    func replaceDatabaseFile(with sourceURL: URL, reopenMode: DatabaseOpenMode) throws {
        try dbQueue.close()
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
            dbQueue = try Self.openQueue(databaseURL: databaseURL, mode: reopenMode)
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
            dbQueue = try Self.openQueue(databaseURL: databaseURL, mode: openMode)
            throw error
        }
    }

    private static func openQueue(databaseURL: URL, mode: DatabaseOpenMode) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            if case .encrypted(let passphrase) = mode {
                try db.usePassphrase(passphrase.value)
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try validateReadable(db)
        }

        do {
            return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        } catch {
            throw mapOpenError(error, mode: mode)
        }
    }

    private static func mapOpenError(_ error: Error, mode: DatabaseOpenMode) -> Error {
        guard case .encrypted = mode else {
            return DatabaseError.openDatabase(error.localizedDescription)
        }
        return DatabaseError.invalidPassphrase(error.localizedDescription)
    }

    nonisolated private static func validateReadable(_ db: Database) throws {
        _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master;")
    }

    private func exportDatabaseLocked(db: Database, to targetURL: URL, mode targetMode: DatabaseOpenMode) throws {
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

        let schemaCounts = try schemaCounts(db)
        try db.execute(
            sql: "ATTACH DATABASE ? AS converted KEY ?;",
            arguments: [targetURL.path, targetKey]
        )
        do {
            try db.execute(sql: "SELECT sqlcipher_export('converted');")
            try db.execute(sql: "DETACH DATABASE converted;")
        } catch {
            try? db.execute(sql: "DETACH DATABASE converted;")
            throw error
        }

        try Self.validateDatabase(
            at: targetURL,
            mode: targetMode,
            expectedSchemaCounts: schemaCounts
        )
    }

    private func schemaCounts(_ db: Database) throws -> [String: Int64] {
        var counts: [String: Int64] = [:]
        for tableName in Self.validationTableNames where try db.tableExists(tableName) {
            counts[tableName] = try Int64.fetchOne(
                db,
                sql: "SELECT count(*) FROM \(tableName.quotedDatabaseIdentifier);"
            ) ?? 0
        }
        return counts
    }

    private static func validateDatabase(
        at url: URL,
        mode: DatabaseOpenMode,
        expectedSchemaCounts: [String: Int64]
    ) throws {
        let validationQueue = try openQueue(databaseURL: url, mode: mode)
        defer { try? validationQueue.close() }

        try validationQueue.read { db in
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check;") ?? ""
            guard integrity == "ok" else {
                throw DatabaseError.execute("converted database integrity_check failed: \(integrity)")
            }

            for (tableName, expectedCount) in expectedSchemaCounts {
                let actualCount = try Int64.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM \(tableName.quotedDatabaseIdentifier);"
                ) ?? 0
                guard actualCount == expectedCount else {
                    throw DatabaseError.execute("converted database row count mismatch for \(tableName): \(actualCount) != \(expectedCount)")
                }
            }
        }
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
}
