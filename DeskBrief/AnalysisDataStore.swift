import Foundation
import GRDB

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
        try connection.write { db in
            let row = AnalysisRunRow(
                id: nil,
                status: status,
                modelName: modelName,
                totalItems: totalItems,
                successCount: 0,
                failureCount: 0,
                inputMeanTokens: nil,
                inputMaxTokens: nil,
                outputMeanTokens: nil,
                outputMaxTokens: nil,
                averageItemDurationSeconds: nil,
                errorMessage: nil,
                createdAt: Date().timeIntervalSince1970
            )
            try row.insert(db)
            return db.lastInsertedRowID
        }
    }

    func updateAnalysisRunTotalItems(id: Int64, totalItems: Int) throws {
        try connection.write { db in
            try AnalysisRunRow
                .filter(AnalysisRunRow.Columns.id == id)
                .updateAll(db, AnalysisRunRow.Columns.totalItems.set(to: totalItems))
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
        try connection.write { db in
            try AnalysisRunRow
                .filter(AnalysisRunRow.Columns.id == id)
                .updateAll(db, [
                    AnalysisRunRow.Columns.status.set(to: status),
                    AnalysisRunRow.Columns.successCount.set(to: successCount),
                    AnalysisRunRow.Columns.failureCount.set(to: failureCount),
                    AnalysisRunRow.Columns.inputMeanTokens.set(to: inputMeanTokens),
                    AnalysisRunRow.Columns.inputMaxTokens.set(to: inputMaxTokens),
                    AnalysisRunRow.Columns.outputMeanTokens.set(to: outputMeanTokens),
                    AnalysisRunRow.Columns.outputMaxTokens.set(to: outputMaxTokens),
                    AnalysisRunRow.Columns.averageItemDurationSeconds.set(to: averageItemDurationSeconds),
                    AnalysisRunRow.Columns.errorMessage.set(to: errorMessage),
                ])
            postChangeNotification()
        }
    }

    func fetchAnalysisRuns() throws -> [AnalysisRunRecord] {
        try connection.read { db in
            try ensureTableExists(AnalysisRunRow.databaseTableName, db: db)
            return try AnalysisRunRow
                .order(AnalysisRunRow.Columns.id.desc)
                .limit(200)
                .fetchAll(db)
                .map(Self.analysisRunRecord)
        }
    }

    func fetchLatestAnalysisAverageDurationSeconds() throws -> Double? {
        try connection.read { db in
            try ensureTableExists(AnalysisRunRow.databaseTableName, db: db)
            return try AnalysisRunRow
                .filter(AnalysisRunRow.Columns.averageItemDurationSeconds != nil)
                .order(AnalysisRunRow.Columns.id.desc)
                .limit(1)
                .fetchOne(db)?
                .averageItemDurationSeconds
        }
    }

    func createSummaryRun(
        modelName: String,
        totalItems: Int,
        analysisRunID: Int64? = nil,
        status: String = "running"
    ) throws -> Int64 {
        try connection.write { db in
            let row = SummaryRunRow(
                id: nil,
                analysisRunID: analysisRunID,
                status: status,
                modelName: modelName,
                totalItems: totalItems,
                successCount: 0,
                failureCount: 0,
                inputMeanTokens: nil,
                inputMaxTokens: nil,
                outputMeanTokens: nil,
                outputMaxTokens: nil,
                averageItemDurationSeconds: nil,
                errorMessage: nil,
                createdAt: Date().timeIntervalSince1970
            )
            try row.insert(db)
            return db.lastInsertedRowID
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
        try connection.write { db in
            try SummaryRunRow
                .filter(SummaryRunRow.Columns.id == id)
                .updateAll(db, [
                    SummaryRunRow.Columns.status.set(to: status),
                    SummaryRunRow.Columns.successCount.set(to: successCount),
                    SummaryRunRow.Columns.failureCount.set(to: failureCount),
                    SummaryRunRow.Columns.inputMeanTokens.set(to: inputMeanTokens),
                    SummaryRunRow.Columns.inputMaxTokens.set(to: inputMaxTokens),
                    SummaryRunRow.Columns.outputMeanTokens.set(to: outputMeanTokens),
                    SummaryRunRow.Columns.outputMaxTokens.set(to: outputMaxTokens),
                    SummaryRunRow.Columns.averageItemDurationSeconds.set(to: averageItemDurationSeconds),
                    SummaryRunRow.Columns.errorMessage.set(to: errorMessage),
                ])
            postChangeNotification()
        }
    }

    func fetchSummaryRuns() throws -> [SummaryRunRecord] {
        try connection.read { db in
            try ensureTableExists(SummaryRunRow.databaseTableName, db: db)
            return try SummaryRunRow
                .order(SummaryRunRow.Columns.id.desc)
                .limit(200)
                .fetchAll(db)
                .map(Self.summaryRunRecord)
        }
    }

    func insertAnalysisResult(
        capturedAt: Date,
        categoryName: String?,
        summaryText: String?,
        durationMinutesSnapshot: Int
    ) throws -> AnalysisResultInsertOutcome {
        try connection.write { db in
            let row = AnalysisResultRow(
                id: nil,
                capturedAt: capturedAt.timeIntervalSince1970,
                categoryName: categoryName,
                summaryText: summaryText,
                durationMinutesSnapshot: durationMinutesSnapshot
            )
            try row.insert(db, onConflict: .ignore)
            return db.changesCount > 0 ? .inserted : .duplicate
        }
    }

    func fetchReportSourceItems() throws -> [ReportSourceItem] {
        try connection.read { db in
            try ensureTableExists(AnalysisResultRow.databaseTableName, db: db)
            return try AnalysisResultRow
                .filter(AnalysisResultRow.Columns.categoryName != nil)
                .order(AnalysisResultRow.Columns.capturedAt.desc, AnalysisResultRow.Columns.id.desc)
                .fetchAll(db)
                .compactMap(Self.reportSourceItem)
        }
    }

    func fetchReportActivityItems() throws -> [DailyReportActivityItem] {
        try connection.read { db in
            try ensureTableExists(AnalysisResultRow.databaseTableName, db: db)
            return try AnalysisResultRow
                .filter(AnalysisResultRow.Columns.categoryName != nil)
                .order(AnalysisResultRow.Columns.capturedAt, AnalysisResultRow.Columns.id)
                .fetchAll(db)
                .compactMap(Self.dailyReportActivityItem)
        }
    }

    func fetchLatestReportActivityItem(before date: Date) throws -> DailyReportActivityItem? {
        try connection.read { db in
            try ensureTableExists(AnalysisResultRow.databaseTableName, db: db)
            return try AnalysisResultRow
                .filter(AnalysisResultRow.Columns.categoryName != nil)
                .filter(AnalysisResultRow.Columns.capturedAt < date.timeIntervalSince1970)
                .order(AnalysisResultRow.Columns.capturedAt.desc, AnalysisResultRow.Columns.id.desc)
                .limit(1)
                .fetchOne(db)
                .flatMap(Self.dailyReportActivityItem)
        }
    }

    func fetchDailyReportActivityItems(
        for dayStart: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [DailyReportActivityItem] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return try connection.read { db in
            try ensureTableExists(AnalysisResultRow.databaseTableName, db: db)
            let request = SQLRequest<AnalysisResultRow>(
                sql: """
                    SELECT id, captured_at, category_name, summary_text, duration_minutes_snapshot
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
                    """,
                arguments: [
                    dayStart.timeIntervalSince1970,
                    dayEnd.timeIntervalSince1970,
                    dayStart.timeIntervalSince1970,
                ]
            )
            return try request
                .fetchAll(db)
                .compactMap { row in
                    guard let item = Self.dailyReportActivityItem(row) else { return nil }
                    return Self.clippedDailyReportActivityItem(
                        id: item.id,
                        capturedAt: item.capturedAt,
                        categoryName: item.categoryName,
                        durationMinutes: item.durationMinutes,
                        itemSummaryText: item.itemSummaryText,
                        intervalStart: dayStart,
                        intervalEnd: dayEnd
                    )
                }
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

    nonisolated private static func analysisRunRecord(_ row: AnalysisRunRow) -> AnalysisRunRecord {
        AnalysisRunRecord(
            id: row.id ?? 0,
            status: row.status,
            modelName: row.modelName,
            totalItems: row.totalItems,
            successCount: row.successCount,
            failureCount: row.failureCount,
            inputMeanTokens: row.inputMeanTokens,
            inputMaxTokens: row.inputMaxTokens,
            outputMeanTokens: row.outputMeanTokens,
            outputMaxTokens: row.outputMaxTokens,
            averageItemDurationSeconds: row.averageItemDurationSeconds,
            errorMessage: row.errorMessage,
            createdAt: Date(timeIntervalSince1970: row.createdAt)
        )
    }

    nonisolated private static func summaryRunRecord(_ row: SummaryRunRow) -> SummaryRunRecord {
        SummaryRunRecord(
            id: row.id ?? 0,
            analysisRunID: row.analysisRunID,
            status: row.status,
            modelName: row.modelName,
            totalItems: row.totalItems,
            successCount: row.successCount,
            failureCount: row.failureCount,
            inputMeanTokens: row.inputMeanTokens,
            inputMaxTokens: row.inputMaxTokens,
            outputMeanTokens: row.outputMeanTokens,
            outputMaxTokens: row.outputMaxTokens,
            averageItemDurationSeconds: row.averageItemDurationSeconds,
            errorMessage: row.errorMessage,
            createdAt: Date(timeIntervalSince1970: row.createdAt)
        )
    }

    nonisolated private static func reportSourceItem(_ row: AnalysisResultRow) -> ReportSourceItem? {
        guard let categoryName = row.categoryName else { return nil }
        return ReportSourceItem(
            id: row.id ?? 0,
            capturedAt: Date(timeIntervalSince1970: row.capturedAt),
            categoryName: categoryName,
            durationMinutes: row.durationMinutesSnapshot
        )
    }

    nonisolated private static func dailyReportActivityItem(_ row: AnalysisResultRow) -> DailyReportActivityItem? {
        guard let categoryName = row.categoryName else { return nil }
        return DailyReportActivityItem(
            id: row.id ?? 0,
            capturedAt: Date(timeIntervalSince1970: row.capturedAt),
            categoryName: categoryName,
            durationMinutes: row.durationMinutesSnapshot,
            itemSummaryText: row.summaryText
        )
    }

    nonisolated private static func clippedDailyReportActivityItem(
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

    private func ensureTableExists(_ tableName: String, db: Database) throws {
        guard try db.tableExists(tableName) else {
            throw DatabaseError.prepareStatement("missing table \(tableName)")
        }
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        }
    }
}
