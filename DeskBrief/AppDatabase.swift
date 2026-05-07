import Foundation
import Security
import SQLCipher

enum DatabaseError: LocalizedError, Equatable {
    case openDatabase(String)
    case missingPassphrase(URL)
    case invalidPassphrase(String)
    case keychainReadFailed(KeychainReadResult)
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
        case .keychainReadFailed(let result):
            return KeychainReadError(result: result).localizedDescription
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
        case .openDatabase, .keychainReadFailed, .keychainWriteFailed, .prepareStatement, .execute:
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
            keychain: keychain,
            encryptionEnabled: AppDefaults.databaseEncryptionEnabled
        )
    }

    init(
        databaseURL: URL,
        applicationSupportDirectory: URL? = nil,
        keychain: KeychainStoring? = nil,
        passphrase: DatabasePassphrase? = nil,
        encryptionEnabled: Bool = AppDefaults.databaseEncryptionEnabled
    ) throws {
        self.databaseURL = databaseURL
        let resolvedPassphrase = try Self.resolvePassphrase(
            databaseURL: databaseURL,
            keychain: keychain,
            passphrase: passphrase,
            encryptionEnabled: encryptionEnabled
        )
        self.connection = try DatabaseConnection(databaseURL: databaseURL, mode: resolvedPassphrase.openMode)
        self.analysisStore = AnalysisDataStore(connection: connection)
        self.reportStore = ReportDataStore(connection: connection)
        self.logStore = LogDataStore(connection: connection)
        self.screenshotStore = ScreenshotFileStore(applicationSupportDirectory: applicationSupportDirectory)
        try DatabaseSchema.create(connection: connection)
    }

    // MARK: - Analysis Runs

    private static func resolvePassphrase(
        databaseURL: URL,
        keychain: KeychainStoring?,
        passphrase: DatabasePassphrase?,
        encryptionEnabled: Bool
    ) throws -> ResolvedDatabasePassphrase {
        if let passphrase {
            return ResolvedDatabasePassphrase(openMode: .encrypted(passphrase), passphrase: passphrase)
        }

        guard encryptionEnabled else {
            return ResolvedDatabasePassphrase(openMode: .plaintext)
        }

        guard let keychain else {
            let passphrase = try DatabasePassphrase("DeskBrief.TestDatabase.Passphrase")
            return ResolvedDatabasePassphrase(openMode: .encrypted(passphrase), passphrase: passphrase)
        }

        let store = DatabasePassphraseStore(keychain: keychain)
        let fileExists = FileManager.default.fileExists(atPath: databaseURL.path)
        if fileExists {
            if let storedPassphrase = try store.load() {
                return ResolvedDatabasePassphrase(openMode: .encrypted(storedPassphrase), passphrase: storedPassphrase)
            }

            throw DatabaseError.missingPassphrase(databaseURL)
        }

        let passphrase = try store.loadOrCreate()
        return ResolvedDatabasePassphrase(openMode: .encrypted(passphrase), passphrase: passphrase)
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

    nonisolated func fetchReportActivityItems() throws -> [DailyReportActivityItem] {
        try analysisStore.fetchReportActivityItems()
    }

    func fetchLatestReportActivityItem(before date: Date) throws -> DailyReportActivityItem? {
        try analysisStore.fetchLatestReportActivityItem(before: date)
    }

    nonisolated func fetchDailyReportActivityItems(
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

    nonisolated func fetchDailyReport(for dayStart: Date) throws -> DailyReportRecord? {
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

    // MARK: - Database Encryption

    func decryptDatabase() throws {
        let tempURL = conversionTemporaryURL()
        do {
            try connection.exportDatabase(to: tempURL, mode: .plaintext)
            try connection.replaceDatabaseFile(with: tempURL, reopenMode: .plaintext)
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    func encryptDatabase(passphrase: DatabasePassphrase) throws {
        let tempURL = conversionTemporaryURL()
        do {
            try connection.exportDatabase(to: tempURL, mode: .encrypted(passphrase))
            try connection.replaceDatabaseFile(with: tempURL, reopenMode: .encrypted(passphrase))
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    func changeDatabasePassphrase(to passphrase: DatabasePassphrase) throws {
        try connection.rekey(to: passphrase)
        NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
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

    private func conversionTemporaryURL() -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("\(databaseURL.lastPathComponent).conversion-\(UUID().uuidString)", isDirectory: false)
    }

    nonisolated static func databaseSidecarURLs(for databaseURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    nonisolated static func removeDatabaseFiles(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        let urls = [databaseURL] + databaseSidecarURLs(for: databaseURL)
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private struct ResolvedDatabasePassphrase {
    let openMode: DatabaseOpenMode
    let passphrase: DatabasePassphrase?

    init(openMode: DatabaseOpenMode, passphrase: DatabasePassphrase? = nil) {
        self.openMode = openMode
        self.passphrase = passphrase
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
        let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
        let digits = Array("0123456789")
        let symbols = Array("!#$%&*+-=?@^_")
        let groups = [uppercase, lowercase, digits, symbols]
        let allCharacters = Array(groups.joined())
        var characters = try groups.map { try randomElement(in: $0) }
        for _ in characters.count..<16 {
            characters.append(try randomElement(in: allCharacters))
        }
        try shuffle(&characters)
        return try DatabasePassphrase(String(characters))
    }

    private static func randomElement(in characters: [Character]) throws -> Character {
        var byte = UInt8.zero
        let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
        guard status == errSecSuccess else {
            throw DatabaseError.execute("failed to generate database passphrase: \(status)")
        }
        return characters[Int(byte) % characters.count]
    }

    private static func shuffle(_ characters: inout [Character]) throws {
        guard characters.count > 1 else { return }
        for index in stride(from: characters.count - 1, through: 1, by: -1) {
            var byte = UInt8.zero
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                throw DatabaseError.execute("failed to shuffle database passphrase: \(status)")
            }
            characters.swapAt(index, Int(byte) % (index + 1))
        }
    }
}

struct DatabasePassphraseStore {
    static let account = AppDefaults.databasePassphraseAccount

    private let keychain: KeychainStoring

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    func load() throws -> DatabasePassphrase? {
        switch keychain.readString(for: Self.account) {
        case .success(_, let value):
            return try? DatabasePassphrase(value)
        case .notFound:
            return nil
        case .failure(let account, let status):
            throw DatabaseError.keychainReadFailed(.failure(account: account, status: status))
        }
    }

    func save(_ passphrase: DatabasePassphrase) throws {
        let result = keychain.set(passphrase.value, for: Self.account)
        guard result.isSuccess else {
            throw DatabaseError.keychainWriteFailed(result)
        }
    }

    func loadOrCreate() throws -> DatabasePassphrase {
        if let passphrase = try load() {
            return passphrase
        }
        let passphrase = try DatabasePassphrase.generate()
        try save(passphrase)
        return passphrase
    }
}
