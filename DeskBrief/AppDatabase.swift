import Foundation
import Security
import SQLCipher

enum DatabaseError: LocalizedError, Equatable {
    case openDatabase(String)
    case missingPassphrase(URL)
    case invalidPassphrase(String)
    case keychainWriteFailed(KeychainWriteResult)
    case prepareStatement(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let message):
            return message
        case .missingPassphrase(let url):
            return "Missing database passphrase for \(url.path)"
        case .invalidPassphrase(let message):
            return message
        case .keychainWriteFailed(let result):
            return KeychainWriteError(result: result).localizedDescription
        case .prepareStatement(let message), .execute(let message):
            return message
        }
    }

    var isDatabaseRecoveryCandidate: Bool {
        switch self {
        case .missingPassphrase, .invalidPassphrase:
            return true
        case .openDatabase, .keychainWriteFailed, .prepareStatement, .execute:
            return false
        }
    }
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

    /// Unified pending screenshot store that combines disk and memory screenshots.
    lazy var pendingScreenshotStore = PendingScreenshotStore(database: self)

    convenience init(keychain: KeychainStoring) throws {
        let supportURL = try ScreenshotFileStore.applicationSupportDirectory()
        try self.init(
            databaseURL: supportURL.appendingPathComponent("desk-brief.sqlite", isDirectory: false),
            keychain: keychain
        )
    }

    init(
        databaseURL: URL,
        applicationSupportDirectory: URL? = nil,
        keychain: KeychainStoring? = nil,
        passphrase: DatabasePassphrase? = nil
    ) throws {
        self.databaseURL = databaseURL
        let resolvedPassphrase = try Self.resolvePassphrase(
            databaseURL: databaseURL,
            keychain: keychain,
            passphrase: passphrase
        )
        self.connection = try DatabaseConnection(databaseURL: databaseURL, passphrase: resolvedPassphrase.passphrase)
        self.analysisStore = AnalysisDataStore(connection: connection)
        self.reportStore = ReportDataStore(connection: connection)
        self.logStore = LogDataStore(connection: connection)
        self.screenshotStore = ScreenshotFileStore(applicationSupportDirectory: applicationSupportDirectory)
        try DatabaseSchema.create(connection: connection)
        try Self.finishPassphraseImportIfNeeded(resolvedPassphrase, databaseURL: databaseURL, keychain: keychain)
    }

    // MARK: - Analysis Runs

    private static func resolvePassphrase(
        databaseURL: URL,
        keychain: KeychainStoring?,
        passphrase: DatabasePassphrase?
    ) throws -> ResolvedDatabasePassphrase {
        if let passphrase {
            return ResolvedDatabasePassphrase(passphrase: passphrase)
        }

        guard let keychain else {
            return try ResolvedDatabasePassphrase(passphrase: DatabasePassphrase("DeskBrief.TestDatabase.Passphrase"))
        }

        let store = DatabasePassphraseStore(keychain: keychain)
        let fileExists = FileManager.default.fileExists(atPath: databaseURL.path)
        if fileExists {
            if let importedPassphrase = try DatabasePassphraseImportFile.load(for: databaseURL) {
                return ResolvedDatabasePassphrase(
                    passphrase: importedPassphrase,
                    pendingImportURL: DatabasePassphraseImportFile.url(for: databaseURL)
                )
            }
            if let storedPassphrase = store.load() {
                return ResolvedDatabasePassphrase(passphrase: storedPassphrase)
            }

            throw DatabaseError.missingPassphrase(databaseURL)
        }

        return try ResolvedDatabasePassphrase(passphrase: store.loadOrCreate())
    }

    private static func finishPassphraseImportIfNeeded(
        _ resolvedPassphrase: ResolvedDatabasePassphrase,
        databaseURL: URL,
        keychain: KeychainStoring?
    ) throws {
        guard let pendingImportURL = resolvedPassphrase.pendingImportURL,
              let keychain else {
            return
        }

        try DatabasePassphraseStore(keychain: keychain).save(resolvedPassphrase.passphrase)
        try FileManager.default.removeItem(at: pendingImportURL)
    }

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

    static func applicationSupportDirectory() throws -> URL {
        try ScreenshotFileStore.applicationSupportDirectory()
    }

    func screenshotsDirectory() throws -> URL {
        try screenshotStore.screenshotsDirectory()
    }

    func listScreenshotFiles(defaultDurationMinutes: Int) throws -> [ScreenshotFileRecord] {
        try screenshotStore.listScreenshotFiles(defaultDurationMinutes: defaultDurationMinutes)
    }

    nonisolated static func databaseSidecarURLs(for databaseURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    nonisolated static func databasePassphraseImportURL(for databaseURL: URL) -> URL {
        DatabasePassphraseImportFile.url(for: databaseURL)
    }

    nonisolated static func removeDatabaseFiles(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        let urls = [databaseURL, databasePassphraseImportURL(for: databaseURL)] + databaseSidecarURLs(for: databaseURL)
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private struct ResolvedDatabasePassphrase {
    let passphrase: DatabasePassphrase
    let pendingImportURL: URL?

    init(passphrase: DatabasePassphrase, pendingImportURL: URL? = nil) {
        self.passphrase = passphrase
        self.pendingImportURL = pendingImportURL
    }
}

nonisolated struct DatabasePassphrase: Equatable {
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty else {
            throw DatabaseError.invalidPassphrase("Database passphrase must not be empty")
        }
        self.value = value
    }

    static func generate() throws -> DatabasePassphrase {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DatabaseError.execute("failed to generate database passphrase: \(status)")
        }
        return try DatabasePassphrase(Data(bytes).base64EncodedString())
    }
}

struct DatabasePassphraseStore {
    static let account = AppDefaults.databasePassphraseAccount

    private let keychain: KeychainStoring

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    func load() -> DatabasePassphrase? {
        try? DatabasePassphrase(keychain.string(for: Self.account))
    }

    func save(_ passphrase: DatabasePassphrase) throws {
        let result = keychain.set(passphrase.value, for: Self.account)
        guard result.isSuccess else {
            throw DatabaseError.keychainWriteFailed(result)
        }
    }

    func loadOrCreate() throws -> DatabasePassphrase {
        if let passphrase = load() {
            return passphrase
        }
        let passphrase = try DatabasePassphrase.generate()
        try save(passphrase)
        return passphrase
    }
}

nonisolated enum DatabasePassphraseImportFile {
    static func url(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(AppDefaults.databasePassphraseImportFilename, isDirectory: false)
    }

    static func load(for databaseURL: URL) throws -> DatabasePassphrase? {
        let importURL = url(for: databaseURL)
        guard FileManager.default.fileExists(atPath: importURL.path) else {
            return nil
        }

        let rawValue = try String(contentsOf: importURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try DatabasePassphrase(rawValue)
    }
}
