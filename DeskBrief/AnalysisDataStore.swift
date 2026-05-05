import Foundation
import SQLite3

final class AnalysisDataStore: @unchecked Sendable {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func createAnalysisRun(
        modelName: String,
        totalItems: Int,
        status: String = "running"
    ) throws -> Int64 {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT INTO analysis_runs (status, model_name, total_items, created_at)
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            let now = Date().timeIntervalSince1970
            lock.bind(status, at: 1, to: stmt)
            lock.bind(modelName, at: 2, to: stmt)
            sqlite3_bind_int64(stmt, 3, Int64(totalItems))
            sqlite3_bind_double(stmt, 4, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("insert analysis_run failed")
            }
            return lock.lastInsertRowid()
        }
    }

    func updateAnalysisRunTotalItems(id: Int64, totalItems: Int) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("UPDATE analysis_runs SET total_items = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(totalItems))
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("update analysis_run total_items failed")
            }
            postChangeNotification()
        }
    }

    func finishAnalysisRun(
        id: Int64,
        status: String,
        successCount: Int,
        failureCount: Int,
        inputMeanTokens: Double? = nil,
        inputMaxTokens: Int? = nil,
        outputMeanTokens: Double? = nil,
        outputMaxTokens: Int? = nil,
        averageItemDurationSeconds: Double? = nil,
        errorMessage: String? = nil
    ) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                UPDATE analysis_runs
                SET status = ?, success_count = ?, failure_count = ?,
                    input_mean_tokens = ?, input_max_tokens = ?,
                    output_mean_tokens = ?, output_max_tokens = ?,
                    average_item_duration_seconds = ?, error_message = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            lock.bind(status, at: 1, to: stmt)
            sqlite3_bind_int64(stmt, 2, Int64(successCount))
            sqlite3_bind_int64(stmt, 3, Int64(failureCount))
            if let inputMeanTokens { sqlite3_bind_double(stmt, 4, inputMeanTokens) } else { sqlite3_bind_null(stmt, 4) }
            if let inputMaxTokens { sqlite3_bind_int64(stmt, 5, Int64(inputMaxTokens)) } else { sqlite3_bind_null(stmt, 5) }
            if let outputMeanTokens { sqlite3_bind_double(stmt, 6, outputMeanTokens) } else { sqlite3_bind_null(stmt, 6) }
            if let outputMaxTokens { sqlite3_bind_int64(stmt, 7, Int64(outputMaxTokens)) } else { sqlite3_bind_null(stmt, 7) }
            if let averageItemDurationSeconds { sqlite3_bind_double(stmt, 8, averageItemDurationSeconds) } else { sqlite3_bind_null(stmt, 8) }
            lock.bind(errorMessage, at: 9, to: stmt)
            sqlite3_bind_int64(stmt, 10, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("update analysis_run finish failed")
            }
            postChangeNotification()
        }
    }

    func fetchAnalysisRuns() throws -> [AnalysisRunRecord] {
        try connection.withLock { lock in
            try lock.ensureTableExists("analysis_runs")
            let stmt = try lock.prepareStatement("""
                SELECT id, status, model_name, total_items,
                       success_count, failure_count,
                       input_mean_tokens, input_max_tokens,
                       output_mean_tokens, output_max_tokens,
                       average_item_duration_seconds, error_message, created_at
                FROM analysis_runs ORDER BY id DESC LIMIT 200;
            """)
            defer { sqlite3_finalize(stmt) }

            var records: [AnalysisRunRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                records.append(AnalysisRunRecord(
                    id: id,
                    status: lock.string(at: 1, from: stmt),
                    modelName: lock.string(at: 2, from: stmt),
                    totalItems: Int(sqlite3_column_int64(stmt, 3)),
                    successCount: Int(sqlite3_column_int64(stmt, 4)),
                    failureCount: Int(sqlite3_column_int64(stmt, 5)),
                    inputMeanTokens: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                    inputMaxTokens: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7)),
                    outputMeanTokens: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8),
                    outputMaxTokens: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9)),
                    averageItemDurationSeconds: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10),
                    errorMessage: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : lock.string(at: 11, from: stmt),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                ))
            }
            return records
        }
    }

    func fetchLatestAnalysisAverageDurationSeconds() throws -> Double? {
        try connection.withLock { lock in
            try lock.ensureTableExists("analysis_runs")
            let stmt = try lock.prepareStatement("""
                SELECT average_item_duration_seconds FROM analysis_runs
                WHERE average_item_duration_seconds IS NOT NULL
                ORDER BY id DESC LIMIT 1;
            """)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_double(stmt, 0)
        }
    }

    func createSummaryRun(
        modelName: String,
        totalItems: Int,
        analysisRunID: Int64? = nil,
        status: String = "running"
    ) throws -> Int64 {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT INTO summary_runs (analysis_run_id, status, model_name, total_items, created_at)
                VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            let now = Date().timeIntervalSince1970
            if let analysisRunID { sqlite3_bind_int64(stmt, 1, analysisRunID) } else { sqlite3_bind_null(stmt, 1) }
            lock.bind(status, at: 2, to: stmt)
            lock.bind(modelName, at: 3, to: stmt)
            sqlite3_bind_int64(stmt, 4, Int64(totalItems))
            sqlite3_bind_double(stmt, 5, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("insert summary_run failed")
            }
            return lock.lastInsertRowid()
        }
    }

    func finishSummaryRun(
        id: Int64,
        status: String,
        successCount: Int,
        failureCount: Int,
        inputMeanTokens: Double? = nil,
        inputMaxTokens: Int? = nil,
        outputMeanTokens: Double? = nil,
        outputMaxTokens: Int? = nil,
        averageItemDurationSeconds: Double? = nil,
        errorMessage: String? = nil
    ) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                UPDATE summary_runs
                SET status = ?, success_count = ?, failure_count = ?,
                    input_mean_tokens = ?, input_max_tokens = ?,
                    output_mean_tokens = ?, output_max_tokens = ?,
                    average_item_duration_seconds = ?, error_message = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(stmt) }

            lock.bind(status, at: 1, to: stmt)
            sqlite3_bind_int64(stmt, 2, Int64(successCount))
            sqlite3_bind_int64(stmt, 3, Int64(failureCount))
            if let inputMeanTokens { sqlite3_bind_double(stmt, 4, inputMeanTokens) } else { sqlite3_bind_null(stmt, 4) }
            if let inputMaxTokens { sqlite3_bind_int64(stmt, 5, Int64(inputMaxTokens)) } else { sqlite3_bind_null(stmt, 5) }
            if let outputMeanTokens { sqlite3_bind_double(stmt, 6, outputMeanTokens) } else { sqlite3_bind_null(stmt, 6) }
            if let outputMaxTokens { sqlite3_bind_int64(stmt, 7, Int64(outputMaxTokens)) } else { sqlite3_bind_null(stmt, 7) }
            if let averageItemDurationSeconds { sqlite3_bind_double(stmt, 8, averageItemDurationSeconds) } else { sqlite3_bind_null(stmt, 8) }
            lock.bind(errorMessage, at: 9, to: stmt)
            sqlite3_bind_int64(stmt, 10, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("update summary_run finish failed")
            }
            postChangeNotification()
        }
    }

    func fetchSummaryRuns() throws -> [SummaryRunRecord] {
        try connection.withLock { lock in
            try lock.ensureTableExists("summary_runs")
            let stmt = try lock.prepareStatement("""
                SELECT id, analysis_run_id, status, model_name, total_items,
                       success_count, failure_count,
                       input_mean_tokens, input_max_tokens,
                       output_mean_tokens, output_max_tokens,
                       average_item_duration_seconds, error_message, created_at
                FROM summary_runs ORDER BY id DESC LIMIT 200;
            """)
            defer { sqlite3_finalize(stmt) }

            var records: [SummaryRunRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                records.append(SummaryRunRecord(
                    id: id,
                    analysisRunID: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1),
                    status: lock.string(at: 2, from: stmt),
                    modelName: lock.string(at: 3, from: stmt),
                    totalItems: Int(sqlite3_column_int64(stmt, 4)),
                    successCount: Int(sqlite3_column_int64(stmt, 5)),
                    failureCount: Int(sqlite3_column_int64(stmt, 6)),
                    inputMeanTokens: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                    inputMaxTokens: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 8)),
                    outputMeanTokens: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9),
                    outputMaxTokens: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 10)),
                    averageItemDurationSeconds: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11),
                    errorMessage: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : lock.string(at: 12, from: stmt),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
                ))
            }
            return records
        }
    }

    func insertAnalysisResult(
        capturedAt: Date,
        categoryName: String?,
        summaryText: String?,
        durationMinutesSnapshot: Int
    ) throws -> AnalysisResultInsertOutcome {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT OR IGNORE INTO analysis_results (captured_at, category_name, summary_text, duration_minutes_snapshot)
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, capturedAt.timeIntervalSince1970)
            lock.bind(categoryName, at: 2, to: stmt)
            lock.bind(summaryText, at: 3, to: stmt)
            sqlite3_bind_int64(stmt, 4, Int64(durationMinutesSnapshot))

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("insert analysis_result failed")
            }
            return lock.changes() > 0 ? .inserted : .duplicate
        }
    }

    func fetchReportSourceItems() throws -> [ReportSourceItem] {
        try connection.withLock { lock in
            try lock.ensureTableExists("analysis_results")
            let stmt = try lock.prepareStatement("""
                SELECT id, captured_at, category_name, duration_minutes_snapshot AS duration_minutes
                FROM analysis_results
                WHERE category_name IS NOT NULL
                ORDER BY captured_at DESC, id DESC;
            """)
            defer { sqlite3_finalize(stmt) }

            var items: [ReportSourceItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(ReportSourceItem(
                    id: sqlite3_column_int64(stmt, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    categoryName: lock.string(at: 2, from: stmt),
                    durationMinutes: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            return items
        }
    }

    func fetchReportActivityItems() throws -> [DailyReportActivityItem] {
        try connection.withLock { lock in
            try lock.ensureTableExists("analysis_results")
            let stmt = try lock.prepareStatement("""
                SELECT id, captured_at, category_name, duration_minutes_snapshot AS duration_minutes, summary_text AS item_summary_text
                FROM analysis_results
                WHERE category_name IS NOT NULL
                ORDER BY captured_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            var items: [DailyReportActivityItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let itemSummaryText = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : lock.string(at: 4, from: stmt)
                items.append(DailyReportActivityItem(
                    id: sqlite3_column_int64(stmt, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    categoryName: lock.string(at: 2, from: stmt),
                    durationMinutes: Int(sqlite3_column_int64(stmt, 3)),
                    itemSummaryText: itemSummaryText
                ))
            }
            return items
        }
    }

    func fetchLatestReportActivityItem(before date: Date) throws -> DailyReportActivityItem? {
        try connection.withLock { lock in
            try lock.ensureTableExists("analysis_results")
            let stmt = try lock.prepareStatement("""
                SELECT id, captured_at, category_name, duration_minutes_snapshot AS duration_minutes, summary_text AS item_summary_text
                FROM analysis_results
                WHERE category_name IS NOT NULL AND captured_at < ?
                ORDER BY captured_at DESC, id DESC LIMIT 1;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let itemSummaryText = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : lock.string(at: 4, from: stmt)
            return DailyReportActivityItem(
                id: sqlite3_column_int64(stmt, 0),
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                categoryName: lock.string(at: 2, from: stmt),
                durationMinutes: Int(sqlite3_column_int64(stmt, 3)),
                itemSummaryText: itemSummaryText
            )
        }
    }

    func fetchDailyReportActivityItems(
        for dayStart: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [DailyReportActivityItem] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return try connection.withLock { lock in
            try lock.ensureTableExists("analysis_results")
            let stmt = try lock.prepareStatement("""
                SELECT id, captured_at, category_name, duration_minutes_snapshot AS duration_minutes, summary_text AS item_summary_text
                FROM analysis_results
                WHERE category_name IS NOT NULL
                  AND (
                    (captured_at >= ? AND captured_at < ?)
                    OR id = (
                        SELECT id FROM analysis_results
                        WHERE category_name IS NOT NULL AND captured_at < ?
                        ORDER BY captured_at DESC, id DESC LIMIT 1
                    )
                  )
                ORDER BY captured_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, dayStart.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, dayEnd.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, dayStart.timeIntervalSince1970)

            var items: [DailyReportActivityItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let itemSummaryText = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil : lock.string(at: 4, from: stmt)
                guard let item = Self.clippedDailyReportActivityItem(
                    id: sqlite3_column_int64(stmt, 0),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    categoryName: lock.string(at: 2, from: stmt),
                    durationMinutes: Int(sqlite3_column_int64(stmt, 3)),
                    itemSummaryText: itemSummaryText,
                    intervalStart: dayStart,
                    intervalEnd: dayEnd
                ) else { continue }
                items.append(item)
            }
            return items
        }
    }

    func fetchActivityDayStarts(calendar: Calendar = .reportCalendar) throws -> [Date] {
        let sourceItems = try fetchReportSourceItems()
        return Array(Set(sourceItems.map { calendar.startOfDay(for: $0.capturedAt) })).sorted()
    }

    func fetchLatestActivityDayStart(calendar: Calendar = .reportCalendar) throws -> Date? {
        try fetchActivityDayStarts(calendar: calendar).last
    }

    func fetchPendingDailyReportDayStarts(
        before dayStartExclusive: Date,
        calendar: Calendar = .reportCalendar,
        reportStore: ReportDataStore
    ) throws -> [Date] {
        let activityDays = try fetchActivityDayStarts(calendar: calendar)
            .filter { $0 < dayStartExclusive }
        return try activityDays.filter { dayStart in
            guard let report = try reportStore.fetchDailyReport(for: dayStart) else { return true }
            return report.isTemporary
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
        guard clippedEnd > clippedStart else { return nil }
        return DailyReportActivityItem(
            id: id,
            capturedAt: clippedStart,
            categoryName: categoryName,
            durationMinutes: max(Int((clippedEnd.timeIntervalSince(clippedStart) / 60.0).rounded()), 1),
            itemSummaryText: itemSummaryText
        )
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        }
    }
}
