import Foundation
import SQLite3

enum DatabaseError: Error {
    case openDatabase(String)
    case prepareStatement(String)
    case execute(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AppDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DailyWorkSummarizer.Database")
    private var handle: OpaquePointer?
    let databaseURL: URL

    convenience init() throws {
        let supportURL = try Self.applicationSupportDirectory()
        try self.init(
            databaseURL: supportURL.appendingPathComponent("daily-work-summarizer.sqlite", isDirectory: false)
        )
    }

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL

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
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DailyWorkSummarizer"
        let directory = base.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func screenshotsDirectory() throws -> URL {
        let directory = try Self.applicationSupportDirectory().appendingPathComponent("screenshots", isDirectory: true)
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
                ORDER BY sort_order ASC, created_at ASC;
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
                    INSERT INTO category_rules (id, name, description, sort_order, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(statement) }

                let now = Date().timeIntervalSince1970
                for (index, rule) in rules.enumerated() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)

                    bind(rule.id.uuidString, at: 1, to: statement)
                    bind(rule.name, at: 2, to: statement)
                    bind(rule.description, at: 3, to: statement)
                    sqlite3_bind_int64(statement, 4, Int64(index))
                    sqlite3_bind_double(statement, 5, now)
                    sqlite3_bind_double(statement, 6, now)

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
        scheduledFor: Date,
        provider: ModelProvider,
        baseURL: String,
        modelName: String,
        promptSnapshot: String,
        categorySnapshotJSON: String,
        totalItems: Int,
        status: String = "running"
    ) throws -> Int64 {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO analysis_runs (
                    scheduled_for,
                    started_at,
                    status,
                    provider,
                    base_url,
                    model_name,
                    prompt_snapshot,
                    category_snapshot_json,
                    total_items,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(statement, 1, scheduledFor.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, now)
            bind(status, at: 3, to: statement)
            bind(provider.rawValue, at: 4, to: statement)
            bind(baseURL, at: 5, to: statement)
            bind(modelName, at: 6, to: statement)
            bind(promptSnapshot, at: 7, to: statement)
            bind(categorySnapshotJSON, at: 8, to: statement)
            sqlite3_bind_int64(statement, 9, Int64(totalItems))
            sqlite3_bind_double(statement, 10, now)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            return sqlite3_last_insert_rowid(handle)
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
                SET finished_at = ?, status = ?, success_count = ?, failure_count = ?, average_item_duration_seconds = ?, error_message = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bind(status, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, Int64(successCount))
            sqlite3_bind_int64(statement, 4, Int64(failureCount))
            if let averageItemDurationSeconds {
                sqlite3_bind_double(statement, 5, averageItemDurationSeconds)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            bind(errorMessage, at: 6, to: statement)
            sqlite3_bind_int64(statement, 7, id)

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
                ORDER BY finished_at DESC, id DESC
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

    func recordAbsenceEvent(capturedAt: Date, durationMinutes: Int) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO absence_events (
                    captured_at,
                    duration_minutes,
                    created_at
                )
                VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(statement, 1, capturedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, Int64(durationMinutes))
            sqlite3_bind_double(statement, 3, now)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
            postChangeNotification()
        }
    }

    func insertAnalysisResult(
        runID: Int64,
        capturedAt: Date,
        categoryName: String?,
        summaryText: String?,
        status: String,
        errorMessage: String?,
        durationMinutesSnapshot: Int
    ) throws {
        try queue.sync {
            let statement = try prepareStatement("""
                INSERT INTO analysis_results (
                    run_id,
                    captured_at,
                    category_name,
                    summary_text,
                    status,
                    error_message,
                    duration_minutes_snapshot,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, runID)
            sqlite3_bind_double(statement, 2, capturedAt.timeIntervalSince1970)
            bind(categoryName, at: 3, to: statement)
            bind(summaryText, at: 4, to: statement)
            bind(status, at: 5, to: statement)
            bind(errorMessage, at: 6, to: statement)
            sqlite3_bind_int64(statement, 7, Int64(durationMinutesSnapshot))
            sqlite3_bind_double(statement, 8, Date().timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func fetchReportSourceItems() throws -> [ReportSourceItem] {
        try queue.sync {
            let statement = try prepareStatement("""
                SELECT id, captured_at, category_name, duration_minutes
                FROM (
                    SELECT
                        id,
                        captured_at,
                        category_name,
                        duration_minutes_snapshot AS duration_minutes
                    FROM analysis_results
                    WHERE status = 'succeeded'
                      AND category_name IS NOT NULL

                    UNION ALL

                    SELECT
                        -id AS id,
                        captured_at,
                        '\(AppDefaults.absenceCategoryName)' AS category_name,
                        duration_minutes
                    FROM absence_events
                )
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

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS category_rules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS analysis_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scheduled_for DOUBLE NOT NULL,
                started_at DOUBLE NOT NULL,
                finished_at DOUBLE,
                status TEXT NOT NULL,
                provider TEXT NOT NULL,
                base_url TEXT NOT NULL,
                model_name TEXT NOT NULL,
                prompt_snapshot TEXT NOT NULL,
                category_snapshot_json TEXT NOT NULL,
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
                run_id INTEGER NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                summary_text TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                duration_minutes_snapshot INTEGER NOT NULL,
                created_at DOUBLE NOT NULL
            );
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS absence_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at DOUBLE NOT NULL,
                duration_minutes INTEGER NOT NULL,
                created_at DOUBLE NOT NULL
            );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_analysis_results_captured_at ON analysis_results (captured_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_analysis_results_category_name ON analysis_results (category_name, captured_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_absence_events_captured_at ON absence_events (captured_at DESC);")
        try migrateAnalysisRunsIfNeeded()
        try migrateAnalysisResultsIfNeeded()
        try dropCaptureEventsTableIfNeeded()
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

    private func migrateAnalysisResultsIfNeeded() throws {
        let columns = try columnNames(in: "analysis_results")
        let expectedColumns = [
            "id",
            "run_id",
            "captured_at",
            "category_name",
            "summary_text",
            "status",
            "error_message",
            "duration_minutes_snapshot",
            "created_at",
        ]
        guard columns != expectedColumns else {
            return
        }

        try executeLocked("ALTER TABLE analysis_results RENAME TO analysis_results_legacy;")
        try executeLocked("""
            CREATE TABLE analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                summary_text TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                duration_minutes_snapshot INTEGER NOT NULL,
                created_at DOUBLE NOT NULL
            );
        """)
        let legacyColumns = Set(columns)
        try executeLocked("""
            INSERT INTO analysis_results (
                id,
                run_id,
                captured_at,
                category_name,
                summary_text,
                status,
                error_message,
                duration_minutes_snapshot,
                created_at
            )
            SELECT
                \(legacyColumns.contains("id") ? "id" : "NULL"),
                \(legacyColumns.contains("run_id") ? "run_id" : "0"),
                \(legacyColumns.contains("captured_at") ? "captured_at" : "0"),
                \(legacyColumns.contains("category_name") ? "category_name" : "NULL"),
                \(legacyColumns.contains("summary_text") ? "summary_text" : "NULL"),
                \(legacyColumns.contains("status") ? "status" : "'failed'"),
                \(legacyColumns.contains("error_message") ? "error_message" : "NULL"),
                \(legacyColumns.contains("duration_minutes_snapshot") ? "duration_minutes_snapshot" : "0"),
                \(legacyColumns.contains("created_at") ? "created_at" : "0")
            FROM analysis_results_legacy;
        """)
        try executeLocked("DROP TABLE analysis_results_legacy;")
        try executeLocked("CREATE INDEX IF NOT EXISTS idx_analysis_results_captured_at ON analysis_results (captured_at DESC);")
        try executeLocked("CREATE INDEX IF NOT EXISTS idx_analysis_results_category_name ON analysis_results (category_name, captured_at DESC);")
    }

    private func migrateAnalysisRunsIfNeeded() throws {
        let columns = try columnNames(in: "analysis_runs")
        guard !columns.contains("average_item_duration_seconds") else {
            return
        }

        try executeLocked("ALTER TABLE analysis_runs ADD COLUMN average_item_duration_seconds DOUBLE;")
    }

    private func dropCaptureEventsTableIfNeeded() throws {
        let tables = try tableNames()
        guard tables.contains("capture_events") else {
            return
        }

        try executeLocked("DROP TABLE capture_events;")
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
}
