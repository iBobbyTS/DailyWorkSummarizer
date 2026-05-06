import Foundation
import SQLite3

enum DatabaseError: Error, Equatable {
    case openDatabase(String)
    case prepareStatement(String)
    case execute(String)
}

enum AnalysisResultInsertOutcome: Equatable {
    case inserted
    case duplicate
}

final class AppDatabase: @unchecked Sendable {
    let databaseURL: URL
    let connection: DatabaseConnection
    let analysisStore: AnalysisDataStore
    let reportStore: ReportDataStore
    let logStore: LogDataStore
    let screenshotStore: ScreenshotFileStore

    convenience init() throws {
        let supportURL = try ScreenshotFileStore.applicationSupportDirectory()
        try self.init(
            databaseURL: supportURL.appendingPathComponent("desk-brief.sqlite", isDirectory: false)
        )
    }

    init(databaseURL: URL, applicationSupportDirectory: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.connection = try DatabaseConnection(databaseURL: databaseURL)
        self.analysisStore = AnalysisDataStore(connection: connection)
        self.reportStore = ReportDataStore(connection: connection)
        self.logStore = LogDataStore(connection: connection)
        self.screenshotStore = ScreenshotFileStore(applicationSupportDirectory: applicationSupportDirectory)
        try DatabaseSchema.create(connection: connection)
    }

    // MARK: - Analysis Runs

    func createAnalysisRun(modelName: String, totalItems: Int, status: String = "running") throws -> Int64 {
        try analysisStore.createAnalysisRun(modelName: modelName, totalItems: totalItems, status: status)
    }

    func updateAnalysisRunTotalItems(id: Int64, totalItems: Int) throws {
        try analysisStore.updateAnalysisRunTotalItems(id: id, totalItems: totalItems)
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
        try analysisStore.finishAnalysisRun(
            id: id, status: status,
            successCount: successCount, failureCount: failureCount,
            inputMeanTokens: inputMeanTokens, inputMaxTokens: inputMaxTokens,
            outputMeanTokens: outputMeanTokens, outputMaxTokens: outputMaxTokens,
            averageItemDurationSeconds: averageItemDurationSeconds,
            errorMessage: errorMessage
        )
    }

    func fetchAnalysisRuns() throws -> [AnalysisRunRecord] {
        try analysisStore.fetchAnalysisRuns()
    }

    func fetchLatestAnalysisAverageDurationSeconds() throws -> Double? {
        try analysisStore.fetchLatestAnalysisAverageDurationSeconds()
    }

    // MARK: - Summary Runs

    func createSummaryRun(
        modelName: String,
        totalItems: Int,
        analysisRunID: Int64? = nil,
        status: String = "running"
    ) throws -> Int64 {
        try analysisStore.createSummaryRun(
            modelName: modelName,
            totalItems: totalItems,
            analysisRunID: analysisRunID,
            status: status
        )
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
        try analysisStore.finishSummaryRun(
            id: id, status: status,
            successCount: successCount, failureCount: failureCount,
            inputMeanTokens: inputMeanTokens, inputMaxTokens: inputMaxTokens,
            outputMeanTokens: outputMeanTokens, outputMaxTokens: outputMaxTokens,
            averageItemDurationSeconds: averageItemDurationSeconds,
            errorMessage: errorMessage
        )
    }

    func fetchSummaryRuns() throws -> [SummaryRunRecord] {
        try analysisStore.fetchSummaryRuns()
    }

    // MARK: - Analysis Results

    @discardableResult
    func insertAnalysisResult(
        capturedAt: Date,
        categoryName: String?,
        summaryText: String?,
        durationMinutesSnapshot: Int
    ) throws -> AnalysisResultInsertOutcome {
        try analysisStore.insertAnalysisResult(
            capturedAt: capturedAt,
            categoryName: categoryName,
            summaryText: summaryText,
            durationMinutesSnapshot: durationMinutesSnapshot
        )
    }

    func fetchReportSourceItems() throws -> [ReportSourceItem] {
        try analysisStore.fetchReportSourceItems()
    }

    func fetchReportActivityItems() throws -> [DailyReportActivityItem] {
        try analysisStore.fetchReportActivityItems()
    }

    func fetchLatestReportActivityItem(before date: Date) throws -> DailyReportActivityItem? {
        try analysisStore.fetchLatestReportActivityItem(before: date)
    }

    func fetchDailyReportActivityItems(
        for dayStart: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [DailyReportActivityItem] {
        try analysisStore.fetchDailyReportActivityItems(for: dayStart, calendar: calendar)
    }

    func fetchActivityDayStarts(calendar: Calendar = .reportCalendar) throws -> [Date] {
        try analysisStore.fetchActivityDayStarts(calendar: calendar)
    }

    func fetchLatestActivityDayStart(calendar: Calendar = .reportCalendar) throws -> Date? {
        try analysisStore.fetchLatestActivityDayStart(calendar: calendar)
    }

    func fetchPendingDailyReportDayStarts(
        before dayStartExclusive: Date,
        calendar: Calendar = .reportCalendar
    ) throws -> [Date] {
        try analysisStore.fetchPendingDailyReportDayStarts(
            before: dayStartExclusive,
            calendar: calendar,
            reportStore: reportStore
        )
    }

    // MARK: - Daily Reports

    func fetchDailyReport(for dayStart: Date) throws -> DailyReportRecord? {
        try reportStore.fetchDailyReport(for: dayStart)
    }

    func upsertDailyReport(
        dayStart: Date,
        dailySummaryText: String,
        categorySummaries: [String: String],
        isTemporary: Bool = false
    ) throws {
        try reportStore.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: dailySummaryText,
            categorySummaries: categorySummaries,
            isTemporary: isTemporary
        )
    }

    // MARK: - Work Block Summaries

    func fetchDailyWorkBlockSummaries() throws -> [DailyWorkBlockSummaryRecord] {
        try reportStore.fetchDailyWorkBlockSummaries()
    }

    func fetchDailyWorkBlockSummaries(intersecting interval: DateInterval) throws -> [DailyWorkBlockSummaryRecord] {
        try reportStore.fetchDailyWorkBlockSummaries(intersecting: interval)
    }

    func upsertDailyWorkBlockSummary(
        categoryName: String,
        startAt: Date,
        endAt: Date,
        summaryText: String
    ) throws {
        try reportStore.upsertDailyWorkBlockSummary(
            categoryName: categoryName,
            startAt: startAt,
            endAt: endAt,
            summaryText: summaryText
        )
    }

    func deleteDailyWorkBlockSummaries(ids: [Int64]) throws {
        try reportStore.deleteDailyWorkBlockSummaries(ids: ids)
    }

    // MARK: - Category Rules

    func fetchCategoryRules() throws -> [CategoryRule] {
        try reportStore.fetchCategoryRules()
    }

    func replaceCategoryRules(_ rules: [CategoryRule]) throws {
        try reportStore.replaceCategoryRules(rules)
    }

    // MARK: - App Logs

    func fetchAppLogs(limit: Int? = nil) throws -> [AppLogEntry] {
        try logStore.fetchAppLogs(limit: limit)
    }

    func insertAppLog(_ entry: AppLogEntry, maxEntries: Int = AppDefaults.maxLogEntries) throws {
        try logStore.insertAppLog(entry, maxEntries: maxEntries)
    }

    func deleteAppLog(id: UUID) throws {
        try logStore.deleteAppLog(id: id)
    }

    func deleteAllAppLogs() throws {
        try logStore.deleteAllAppLogs()
    }

    // MARK: - Screenshot Files

    nonisolated static func applicationSupportDirectory() throws -> URL {
        try ScreenshotFileStore.applicationSupportDirectory()
    }

    func screenshotsDirectory() throws -> URL {
        try screenshotStore.screenshotsDirectory()
    }

    func listScreenshotFiles(defaultDurationMinutes: Int) throws -> [ScreenshotFileRecord] {
        try screenshotStore.listScreenshotFiles(defaultDurationMinutes: defaultDurationMinutes)
    }
}
