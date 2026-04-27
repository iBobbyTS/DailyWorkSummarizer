import Foundation
import SQLite3

enum DatabaseError: Error {
    case openDatabase(String)
    case prepareStatement(String)
    case execute(String)
}

enum AnalysisResultInsertOutcome: Equatable {
    case inserted
    case duplicate
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AppDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeskBrief.Database")
    private var handle: OpaquePointer?
    private let applicationSupportDirectoryOverride: URL?
    let databaseURL: URL

    convenience init() throws {
        let supportURL = try Self.applicationSupportDirectory()
        try self.init(
            databaseURL: supportURL.appendingPathComponent("desk-brief.sqlite", isDirectory: false)
        )
    }

    init(databaseURL: URL, applicationSupportDirectory: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.applicationSupportDirectoryOverride = applicationSupportDirectory

        if sqlite3_open(databaseURL.path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.openDatabase(message)
        }

        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        queue.sync {
            sqlite3_close(handle)
            handle = nil
        }
    }

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DeskBrief"
        let directory = base.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func screenshotsDirectory() throws -> URL {
        let supportDirectory: URL
        if let applicationSupportDirectoryOverride {
            supportDirectory = applicationSupportDirectoryOverride
        } else {
            supportDirectory = try Self.applicationSupportDirectory()
        }
        let directory = supportDirectory.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func listScreenshotFiles(defaultDurationMinutes: Int) throws -> [ScreenshotFileRecord] {
        let directory = try screenshotsDirectory()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return fileURLs
            .filter { $0.pathExtension.lowercased() == AppDefaults.screenshotFileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { screenshotRecord(for: $0, defaultDurationMinutes: defaultDurationMinutes) }
    }

    func fetchCategoryRules() throws -> [CategoryRule] {
        try queue.sync {
            let statement = try prepareStatement("""
                SELECT id, name, description
                FROM category_rules
                ORDER BY sort_order ASC;
            """)
            defer { sqlite3_finalize(statement) }

            var result: [CategoryRule] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let idString = string(at: 0, from: statement)
                let name = string(at: 1, from: statement)
                let description = string(at: 2, from: statement)
                result.append(CategoryRule(id: UUID(uuidString: idString) ?? UUID(), name: name, description: description))
            }
            return result
        }
    }

    func replaceCategoryRules(_ rules: [CategoryRule]) throws {
        try queue.sync {
            try beginTransaction()
            do {
                try executeLocked("DELETE FROM category_rules;")
                let statement = try prepareStatement("""
                    INSERT INTO category_rules (id, name, description, sort_order)
                    VALUES (?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(statement) }

                for (index, rule) in rules.enumerated() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)

                    bind(rule.id.uuidString, at: 1, to: statement)
                    bind(rule.name, at: 2, to: statement)
                    bind(rule.description, at: 3, to: statement)
                    sqlite3_bind_int64(statement, 4, Int64(index))

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
                    }
                }

                try commitTransaction()
                postChangeNotification()
            } catch {
                try? rollbackTransaction()
                throw error
            }
        }
    }

    func createAnalysisRun(
        modelName: String,
        totalItems: Int,
        status: String = "running"
    ) throws -> Int64 {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO analysis_runs (
                    status,
                    model_name,
                    total_items,
                    created_at
                )
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            let now = Date().timeIntervalSince1970
            bind(status, at: 1, to: statement)
            bind(modelName, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, Int64(totalItems))
            sqlite3_bind_double(statement, 4, now)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    func updateAnalysisRunTotalItems(id: Int64, totalItems: Int) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                UPDATE analysis_runs
                SET total_items = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, Int64(totalItems))
            sqlite3_bind_int64(statement, 2, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            postChangeNotification()
        }
    }

    func finishAnalysisRun(
        id: Int64,
        status: String,
        successCount: Int,
        failureCount: Int,
        averageItemDurationSeconds: Double? = nil,
        errorMessage: String? = nil
    ) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                UPDATE analysis_runs
                SET status = ?, success_count = ?, failure_count = ?, average_item_duration_seconds = ?, error_message = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }

            bind(status, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, Int64(successCount))
            sqlite3_bind_int64(statement, 3, Int64(failureCount))
            if let averageItemDurationSeconds {
                sqlite3_bind_double(statement, 4, averageItemDurationSeconds)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            bind(errorMessage, at: 5, to: statement)
            sqlite3_bind_int64(statement, 6, id)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            postChangeNotification()
        }
    }

    func fetchLatestAnalysisAverageDurationSeconds() throws -> Double? {
        try queue.sync {
            let statement = try prepareStatement("""
                SELECT average_item_duration_seconds
                FROM analysis_runs
                WHERE average_item_duration_seconds IS NOT NULL
                ORDER BY id DESC
                LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return nil
            }

            return sqlite3_column_double(statement, 0)
        }
    }

    func fetchAppLogs(limit: Int? = nil) throws -> [AppLogEntry] {
        try queue.sync {
            let limitClause = if let limit {
                "LIMIT \(limit)"
            } else {
                ""
            }
            let statement = try prepareStatement("""
                SELECT id, created_at, level, source, message
                FROM app_logs
                ORDER BY created_at DESC, id DESC
                \(limitClause);
            """)
            defer { sqlite3_finalize(statement) }

            var entries: [AppLogEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let idString = string(at: 0, from: statement)
                let createdAt = sqlite3_column_double(statement, 1)
                let levelString = string(at: 2, from: statement)
                let sourceString = string(at: 3, from: statement)
                let message = string(at: 4, from: statement)

                guard let id = UUID(uuidString: idString),
                      let level = AppLogLevel(rawValue: levelString),
                      let source = AppLogSource(rawValue: sourceString) else {
                    continue
                }

                entries.append(
                    AppLogEntry(
                        id: id,
                        createdAt: Date(timeIntervalSince1970: createdAt),
                        level: level,
                        source: source,
                        message: message
                    )
                )
            }
            return entries
        }
    }

    func insertAppLog(_ entry: AppLogEntry, maxEntries: Int = AppDefaults.maxLogEntries) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO app_logs (
                    id,
                    created_at,
                    level,
                    source,
                    message
                )
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            bind(entry.id.uuidString, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, entry.createdAt.timeIntervalSince1970)
            bind(entry.level.rawValue, at: 3, to: statement)
            bind(entry.source.rawValue, at: 4, to: statement)
            bind(entry.message, at: 5, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }

            try pruneAppLogsIfNeeded(maxEntries: maxEntries)
        }
    }

    func deleteAppLog(id: UUID) throws {
        try queue.sync {
            let statement = try prepareStatement("DELETE FROM app_logs WHERE id = ?;")
            defer { sqlite3_finalize(statement) }

            bind(id.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func deleteAllAppLogs() throws {
        try queue.sync {
            try executeLocked("DELETE FROM app_logs;")
        }
    }

    @discardableResult
    func insertAnalysisResult(
        capturedAt: Date,
        categoryName: String?,
        summaryText: String?,
        durationMinutesSnapshot: Int
    ) throws -> AnalysisResultInsertOutcome {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT OR IGNORE INTO analysis_results (
                    captured_at,
                    category_name,
                    summary_text,
                    duration_minutes_snapshot
                )
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, capturedAt.timeIntervalSince1970)
            bind(categoryName, at: 2, to: statement)
            bind(summaryText, at: 3, to: statement)
            sqlite3_bind_int64(statement, 4, Int64(durationMinutesSnapshot))

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            return sqlite3_changes(handle) > 0 ? .inserted : .duplicate
        }
    }

    func fetchReportSourceItems() throws -> [ReportSourceItem] {
        try queue.sync {
            let statement = try prepareStatement("""
                SELECT
                    id,
                    captured_at,
                    category_name,
                    duration_minutes_snapshot AS duration_minutes
                FROM analysis_results
                WHERE category_name IS NOT NULL
                ORDER BY captured_at DESC, id DESC;
            """)
            defer { sqlite3_finalize(statement) }

            var items: [ReportSourceItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(
                    ReportSourceItem(
                        id: sqlite3_column_int64(statement, 0),
                        capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        categoryName: string(at: 2, from: statement),
                        durationMinutes: Int(sqlite3_column_int64(statement, 3))
                    )
                )
            }
            return items
        }
    }

    func fetchActivityDayStarts(calendar: Calendar = .reportCalendar) throws -> [Date] {
        let sourceItems = try fetchReportSourceItems()
        return Array(Set(sourceItems.map { calendar.startOfDay(for: $0.capturedAt) }))
            .sorted()
    }

    func fetchLatestActivityDayStart(calendar: Calendar = .reportCalendar) throws -> Date? {
        try fetchActivityDayStarts(calendar: calendar).last
    }

    func fetchPendingDailyReportDayStarts(
        before dayStartExclusive: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [Date] {
        let activityDays = try fetchActivityDayStarts(calendar: calendar)
            .filter { $0 < dayStartExclusive }

        return try activityDays.filter { dayStart in
            guard let report = try fetchDailyReport(for: dayStart) else {
                return true
            }
            return report.isTemporary
        }
    }

    func fetchDailyReportActivityItems(
        for dayStart: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [DailyReportActivityItem] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        return try queue.sync {
            let statement = try prepareStatement("""
                SELECT
                    id,
                    captured_at,
                    category_name,
                    duration_minutes_snapshot AS duration_minutes,
                    summary_text AS item_summary_text
                FROM analysis_results
                WHERE category_name IS NOT NULL
                  AND (
                    (captured_at >= ? AND captured_at < ?)
                    OR id = (
                        SELECT id
                        FROM analysis_results
                        WHERE category_name IS NOT NULL
                          AND captured_at < ?
                        ORDER BY captured_at DESC, id DESC
                        LIMIT 1
                    )
                  )
                ORDER BY captured_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, dayStart.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, dayEnd.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, dayStart.timeIntervalSince1970)

            var items: [DailyReportActivityItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let itemSummaryText = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : string(at: 4, from: statement)
                guard let item = Self.clippedDailyReportActivityItem(
                    id: sqlite3_column_int64(statement, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    categoryName: string(at: 2, from: statement),
                    durationMinutes: Int(sqlite3_column_int64(statement, 3)),
                    itemSummaryText: itemSummaryText,
                    intervalStart: dayStart,
                    intervalEnd: dayEnd
                ) else {
                    continue
                }
                items.append(item)
            }
            return items
        }
    }

    private static func clippedDailyReportActivityItem(
        id: Int64,
        capturedAt: Date,
        categoryName: String,
        durationMinutes: Int,
        itemSummaryText: String?,
        intervalStart: Date,
        intervalEnd: Date
    ) -> DailyReportActivityItem? {
        let itemEnd = capturedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let clippedStart = max(capturedAt, intervalStart)
        let clippedEnd = min(itemEnd, intervalEnd)
        guard clippedEnd > clippedStart else {
            return nil
        }

        return DailyReportActivityItem(
            id: id,
            capturedAt: clippedStart,
            categoryName: categoryName,
            durationMinutes: max(Int((clippedEnd.timeIntervalSince(clippedStart) / 60.0).rounded()), 1),
            itemSummaryText: itemSummaryText
        )
    }

    func fetchDailyReport(for dayStart: Date) throws -> DailyReportRecord? {
        try queue.sync {
            let statement = try prepareStatement("""
                SELECT day_start, daily_summary_text, category_summaries_json
                FROM daily_reports
                WHERE day_start = ?
                LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, dayStart.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            let dayStart = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let dailySummaryText = string(at: 1, from: statement)
            let categorySummaries = decodeCategorySummaries(from: string(at: 2, from: statement))
            return DailyReportRecord(
                dayStart: dayStart,
                dailySummaryText: dailySummaryText,
                categorySummaries: categorySummaries
            )
        }
    }

    func upsertDailyReport(
        dayStart: Date,
        dailySummaryText: String,
        categorySummaries: [String: String]
    ) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO daily_reports (
                    day_start,
                    daily_summary_text,
                    category_summaries_json
                )
                VALUES (?, ?, ?)
                ON CONFLICT(day_start) DO UPDATE SET
                    daily_summary_text = excluded.daily_summary_text,
                    category_summaries_json = excluded.category_summaries_json;
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, dayStart.timeIntervalSince1970)
            bind(dailySummaryText, at: 2, to: statement)
            bind(encodeCategorySummaries(categorySummaries), at: 3, to: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            postChangeNotification()
        }
    }

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS category_rules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                sort_order INTEGER NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS analysis_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                status TEXT NOT NULL,
                model_name TEXT NOT NULL,
                total_items INTEGER NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                average_item_duration_seconds DOUBLE,
                error_message TEXT,
                created_at DOUBLE NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                summary_text TEXT,
                duration_minutes_snapshot INTEGER NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS daily_reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day_start DOUBLE NOT NULL UNIQUE,
                daily_summary_text TEXT NOT NULL,
                category_summaries_json TEXT NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS app_logs (
                id TEXT PRIMARY KEY,
                created_at DOUBLE NOT NULL,
                level TEXT NOT NULL,
                source TEXT NOT NULL,
                message TEXT NOT NULL
            );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_analysis_results_category_name ON analysis_results (category_name, captured_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_daily_reports_day_start ON daily_reports (day_start DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_app_logs_created_at ON app_logs (created_at DESC);")
        try migrateCategoryRulesIfNeeded()
        try migrateAnalysisResultsIfNeeded()
        try ensureAnalysisResultsCapturedAtUniqueIndex()
        try migrateAnalysisRunsIfNeeded()
        try migrateDailyReportsIfNeeded()
        try dropCaptureEventsTableIfNeeded()
        try dropAbsenceEventsTableIfNeeded()
    }

    private func execute(_ sql: String) throws {
        try queue.sync {
            try executeLocked(sql)
        }
    }

    private func prepareStatement(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareStatement(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func beginTransaction() throws {
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func commitTransaction() throws {
        guard sqlite3_exec(handle, "COMMIT TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func rollbackTransaction() throws {
        guard sqlite3_exec(handle, "ROLLBACK TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func executeLocked(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func string(at index: Int32, from statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: value)
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        }
    }

    private func migrateCategoryRulesIfNeeded() throws {
        let columns = try columnNames(in: "category_rules")
        let expectedColumns = [
            "id",
            "name",
            "description",
            "sort_order",
        ]
        guard columns != expectedColumns else {
            return
        }

        try executeLocked("ALTER TABLE category_rules RENAME TO category_rules_legacy;")
        try executeLocked("""
            CREATE TABLE category_rules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                sort_order INTEGER NOT NULL
            );
        """)
        let legacyColumns = Set(columns)
        try executeLocked("""
            INSERT INTO category_rules (
                id,
                name,
                description,
                sort_order
            )
            SELECT
                \(legacyColumns.contains("id") ? "id" : "lower(hex(randomblob(16)))"),
                \(legacyColumns.contains("name") ? "name" : "''"),
                \(legacyColumns.contains("description") ? "description" : "''"),
                \(legacyColumns.contains("sort_order") ? "sort_order" : "0")
            FROM category_rules_legacy;
        """)
        try executeLocked("DROP TABLE category_rules_legacy;")
    }

    private func migrateAnalysisResultsIfNeeded() throws {
        let columns = try columnNames(in: "analysis_results")
        let expectedColumns = [
            "id",
            "captured_at",
            "category_name",
            "summary_text",
            "duration_minutes_snapshot",
        ]
        guard columns != expectedColumns else {
            return
        }

        try executeLocked("ALTER TABLE analysis_results RENAME TO analysis_results_legacy;")
        try executeLocked("""
            CREATE TABLE analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                summary_text TEXT,
                duration_minutes_snapshot INTEGER NOT NULL
            );
        """)
        let legacyColumns = Set(columns)
        let succeededFilter = legacyColumns.contains("status") ? "WHERE status = 'succeeded'" : ""
        let legacyOrder = legacyColumns.contains("id") ? "ORDER BY id ASC" : ""
        try executeLocked("""
            INSERT OR IGNORE INTO analysis_results (
                id,
                captured_at,
                category_name,
                summary_text,
                duration_minutes_snapshot
            )
            SELECT
                \(legacyColumns.contains("id") ? "id" : "NULL"),
                \(legacyColumns.contains("captured_at") ? "captured_at" : "0"),
                \(legacyColumns.contains("category_name") ? "category_name" : "NULL"),
                \(legacyColumns.contains("summary_text") ? "summary_text" : "NULL"),
                \(legacyColumns.contains("duration_minutes_snapshot") ? "duration_minutes_snapshot" : "0")
            FROM analysis_results_legacy
            \(succeededFilter)
            \(legacyOrder);
        """)
        try executeLocked("DROP TABLE analysis_results_legacy;")
        try executeLocked("CREATE INDEX IF NOT EXISTS idx_analysis_results_category_name ON analysis_results (category_name, captured_at DESC);")
    }

    private func ensureAnalysisResultsCapturedAtUniqueIndex() throws {
        try executeLocked("""
            DELETE FROM analysis_results
            WHERE id NOT IN (
                SELECT MIN(id)
                FROM analysis_results
                GROUP BY captured_at
            );
        """)
        try executeLocked("DROP INDEX IF EXISTS idx_analysis_results_captured_at;")
        try executeLocked("CREATE UNIQUE INDEX IF NOT EXISTS idx_analysis_results_captured_at_unique ON analysis_results (captured_at);")
    }

    private func migrateAnalysisRunsIfNeeded() throws {
        let columns = try columnNames(in: "analysis_runs")
        let expectedColumns = [
            "id",
            "status",
            "model_name",
            "total_items",
            "success_count",
            "failure_count",
            "average_item_duration_seconds",
            "error_message",
            "created_at",
        ]
        guard columns != expectedColumns else {
            return
        }

        try executeLocked("ALTER TABLE analysis_runs RENAME TO analysis_runs_legacy;")
        try executeLocked("""
            CREATE TABLE analysis_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                status TEXT NOT NULL,
                model_name TEXT NOT NULL,
                total_items INTEGER NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                average_item_duration_seconds DOUBLE,
                error_message TEXT,
                created_at DOUBLE NOT NULL
            );
        """)
        let legacyColumns = Set(columns)
        try executeLocked("""
            INSERT INTO analysis_runs (
                id,
                status,
                model_name,
                total_items,
                success_count,
                failure_count,
                average_item_duration_seconds,
                error_message,
                created_at
            )
            SELECT
                \(legacyColumns.contains("id") ? "id" : "NULL"),
                \(legacyColumns.contains("status") ? "status" : "'running'"),
                \(legacyColumns.contains("model_name") ? "model_name" : "''"),
                \(legacyColumns.contains("total_items") ? "total_items" : "0"),
                \(legacyColumns.contains("success_count") ? "success_count" : "0"),
                \(legacyColumns.contains("failure_count") ? "failure_count" : "0"),
                \(legacyColumns.contains("average_item_duration_seconds") ? "average_item_duration_seconds" : "NULL"),
                \(legacyColumns.contains("error_message") ? "error_message" : "NULL"),
                \(legacyColumns.contains("created_at") ? "created_at" : "0")
            FROM analysis_runs_legacy;
        """)
        try executeLocked("DROP TABLE analysis_runs_legacy;")
    }

    private func migrateDailyReportsIfNeeded() throws {
        let tables = try tableNames()
        guard tables.contains("daily_reports") else {
            return
        }

        let columns = try columnNames(in: "daily_reports")
        let expectedColumns = [
            "id",
            "day_start",
            "daily_summary_text",
            "category_summaries_json",
        ]
        guard columns != expectedColumns else {
            return
        }

        try executeLocked("ALTER TABLE daily_reports RENAME TO daily_reports_legacy;")
        try executeLocked("""
            CREATE TABLE daily_reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day_start DOUBLE NOT NULL UNIQUE,
                daily_summary_text TEXT NOT NULL,
                category_summaries_json TEXT NOT NULL
            );
        """)
        let legacyColumns = Set(columns)
        try executeLocked("""
            INSERT INTO daily_reports (
                id,
                day_start,
                daily_summary_text,
                category_summaries_json
            )
            SELECT
                \(legacyColumns.contains("id") ? "id" : "NULL"),
                \(legacyColumns.contains("day_start") ? "day_start" : "0"),
                \(legacyColumns.contains("daily_summary_text") ? "daily_summary_text" : "''"),
                \(legacyColumns.contains("category_summaries_json") ? "category_summaries_json" : "'{}'")
            FROM daily_reports_legacy;
        """)
        try executeLocked("DROP TABLE daily_reports_legacy;")
        try executeLocked("CREATE INDEX IF NOT EXISTS idx_daily_reports_day_start ON daily_reports (day_start DESC);")
    }

    private func dropCaptureEventsTableIfNeeded() throws {
        let tables = try tableNames()
        guard tables.contains("capture_events") else {
            return
        }

        try executeLocked("DROP TABLE capture_events;")
    }

    private func dropAbsenceEventsTableIfNeeded() throws {
        let tables = try tableNames()
        guard tables.contains("absence_events") else {
            return
        }

        try executeLocked("DROP INDEX IF EXISTS idx_absence_events_captured_at;")
        try executeLocked("DROP TABLE absence_events;")
    }

    private func columnNames(in table: String) throws -> [String] {
        let statement = try prepareStatement("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.append(string(at: 1, from: statement))
        }
        return columns
    }

    private func tableNames() throws -> [String] {
        let statement = try prepareStatement("SELECT name FROM sqlite_master WHERE type = 'table';")
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(string(at: 0, from: statement))
        }
        return names
    }

    private func screenshotRecord(for url: URL, defaultDurationMinutes: Int) -> ScreenshotFileRecord? {
        let baseName = url.deletingPathExtension().lastPathComponent
        guard let capturedAt = parseScreenshotDate(from: baseName) else {
            return nil
        }

        return ScreenshotFileRecord(
            url: url,
            capturedAt: capturedAt,
            durationMinutes: parseScreenshotIntervalMinutes(from: baseName) ?? defaultDurationMinutes
        )
    }

    private func parseScreenshotDate(from baseName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.date(from: String(baseName.prefix(13)))
    }

    private func parseScreenshotIntervalMinutes(from baseName: String) -> Int? {
        guard let markerRange = baseName.range(of: "-i", options: .backwards) else {
            return nil
        }

        let value = baseName[markerRange.upperBound...]
        return Int(value)
    }

    private func encodeCategorySummaries(_ value: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeCategorySummaries(from rawValue: String) -> [String: String] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func pruneAppLogsIfNeeded(maxEntries: Int) throws {
        guard maxEntries > 0 else {
            try executeLocked("DELETE FROM app_logs;")
            return
        }

        try executeLocked("""
            DELETE FROM app_logs
            WHERE id NOT IN (
                SELECT id
                FROM app_logs
                ORDER BY created_at DESC, id DESC
                LIMIT \(maxEntries)
            );
        """)
    }
}
