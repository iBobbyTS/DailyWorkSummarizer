import Foundation
import SQLite3
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    // MARK: - F9: SQL LIMIT parameter binding

    @Test func fetchAppLogsWithPositiveLimitReturnsCorrectCount() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        for i in 0..<5 {
            try database.insertAppLog(AppLogEntry(
                level: .log, source: .app, message: "log \(i)"
            ), maxEntries: 100)
        }

        let allLogs = try database.fetchAppLogs(limit: nil)
        #expect(allLogs.count == 5)

        let limitedLogs = try database.fetchAppLogs(limit: 3)
        #expect(limitedLogs.count == 3)
    }

    @Test func fetchAppLogsWithZeroOrNegativeLimitReturnsEmpty() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "test"), maxEntries: 100)

        let zeroLogs = try database.fetchAppLogs(limit: 0)
        #expect(zeroLogs.isEmpty)

        let negativeLogs = try database.fetchAppLogs(limit: -1)
        #expect(negativeLogs.isEmpty)
    }

    @Test func fetchAppLogsWithNilLimitReturnsAllEntries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        for i in 0..<10 {
            try database.insertAppLog(AppLogEntry(
                level: .log, source: .app, message: "log \(i)"
            ), maxEntries: 100)
        }

        let logs = try database.fetchAppLogs(limit: nil)
        #expect(logs.count == 10)
    }

    // MARK: - Log pruning with maxEntries

    @Test func pruneAppLogsKeepsOnlyLatestEntries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let logStore = LogDataStore(connection: database.connection)

        for i in 0..<5 {
            try logStore.insertAppLog(AppLogEntry(
                level: .log, source: .app, message: "log \(i)"
            ), maxEntries: 3)
        }

        let remaining = try database.fetchAppLogs(limit: nil)
        #expect(remaining.count == 3)
    }

    // MARK: - Unicode text roundtrip through SQLite binding

    @Test func logMessageRoundtripsChineseCharacters() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let chineseMessage = "截屏分析完成：今日专注工作 2.5 小时"
        try database.insertAppLog(AppLogEntry(
            level: .log, source: .analysis, message: chineseMessage
        ))

        let logs = try database.fetchAppLogs(limit: 1)
        #expect(logs.first?.message == chineseMessage)
    }

    @Test func logMessageRoundtripsEmoji() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let emojiMessage = "Analysis ✅ completed 🎉 with 5 screenshots"
        try database.insertAppLog(AppLogEntry(
            level: .log, source: .analysis, message: emojiMessage
        ))

        let logs = try database.fetchAppLogs(limit: 1)
        #expect(logs.first?.message == emojiMessage)
    }

    @Test func logMessageRoundtripsQuotesAndNewlines() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let message = "He said \"hello\"\nand then\nleft."
        try database.insertAppLog(AppLogEntry(
            level: .log, source: .app, message: message
        ))

        let logs = try database.fetchAppLogs(limit: 1)
        #expect(logs.first?.message == message)
    }

    @Test func logMessageRoundtripsEmptyString() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        try database.insertAppLog(AppLogEntry(
            level: .log, source: .app, message: ""
        ))

        let logs = try database.fetchAppLogs(limit: 1)
        #expect(logs.first?.message == "")
    }

    // MARK: - F16: Error enum Equatable conformance

    @Test func databaseErrorEquatable() async throws {
        #expect(DatabaseError.openDatabase("err") == DatabaseError.openDatabase("err"))
        #expect(DatabaseError.openDatabase("a") != DatabaseError.openDatabase("b"))
        #expect(DatabaseError.prepareStatement("err") == DatabaseError.prepareStatement("err"))
        #expect(DatabaseError.execute("err") == DatabaseError.execute("err"))
        #expect(DatabaseError.openDatabase("err") != DatabaseError.execute("err"))
    }

    @Test func analysisServiceErrorEquatable() async throws {
        #expect(AnalysisServiceError.invalidConfiguration("msg") == AnalysisServiceError.invalidConfiguration("msg"))
        #expect(AnalysisServiceError.invalidConfiguration("a") != AnalysisServiceError.invalidConfiguration("b"))
        #expect(AnalysisServiceError.httpError(statusCode: 500, body: "err") == AnalysisServiceError.httpError(statusCode: 500, body: "err"))
        #expect(AnalysisServiceError.httpError(statusCode: 500, body: "err") != AnalysisServiceError.httpError(statusCode: 500, body: "other"))
        #expect(AnalysisServiceError.httpError(statusCode: 500, body: "err") != AnalysisServiceError.httpError(statusCode: 404, body: "err"))
        #expect(AnalysisServiceError.lengthTruncated("truncated") == AnalysisServiceError.lengthTruncated("truncated"))
        #expect(AnalysisServiceError.invalidImageData("bad") == AnalysisServiceError.invalidImageData("bad"))
        #expect(AnalysisServiceError.invalidConfiguration("msg") != AnalysisServiceError.invalidResponse("msg"))
    }

    @Test func dailyReportSummaryServiceErrorEquatable() async throws {
        #expect(DailyReportSummaryServiceError.invalidConfiguration("msg") == DailyReportSummaryServiceError.invalidConfiguration("msg"))
        #expect(DailyReportSummaryServiceError.invalidConfiguration("a") != DailyReportSummaryServiceError.invalidConfiguration("b"))
        #expect(DailyReportSummaryServiceError.httpError(statusCode: 500, body: "err") == DailyReportSummaryServiceError.httpError(statusCode: 500, body: "err"))
        #expect(DailyReportSummaryServiceError.noActivity("none") == DailyReportSummaryServiceError.noActivity("none"))
        #expect(DailyReportSummaryServiceError.invalidResponse("msg") == DailyReportSummaryServiceError.invalidResponse("msg"))
        #expect(DailyReportSummaryServiceError.invalidConfiguration("msg") != DailyReportSummaryServiceError.noActivity("none"))
    }

    @Test func modelMemoryErrorEquatable() async throws {
        #expect(ModelMemoryError.insufficientMemory(thresholdGB: 4.0, availableGB: 2.5) == ModelMemoryError.insufficientMemory(thresholdGB: 4.0, availableGB: 2.5))
        #expect(ModelMemoryError.insufficientMemory(thresholdGB: 4.0, availableGB: 2.5) != ModelMemoryError.insufficientMemory(thresholdGB: 4.0, availableGB: 3.0))
        #expect(ModelMemoryError.insufficientMemory(thresholdGB: 4.0, availableGB: 2.5) != ModelMemoryError.insufficientMemory(thresholdGB: 8.0, availableGB: 2.5))
    }

    @Test func lmStudioModelLifecycleErrorEquatable() async throws {
        #expect(LMStudioModelLifecycleError.invalidRemoteConfiguration == LMStudioModelLifecycleError.invalidRemoteConfiguration)
        #expect(LMStudioModelLifecycleError.invalidHTTPResponse == LMStudioModelLifecycleError.invalidHTTPResponse)
        #expect(LMStudioModelLifecycleError.missingResponseData == LMStudioModelLifecycleError.missingResponseData)
        #expect(LMStudioModelLifecycleError.httpError(statusCode: 500, body: "err") == LMStudioModelLifecycleError.httpError(statusCode: 500, body: "err"))
        #expect(LMStudioModelLifecycleError.httpError(statusCode: 500, body: "err") != LMStudioModelLifecycleError.httpError(statusCode: 500, body: "other"))
        #expect(LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: "test") == LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: "test"))
        #expect(LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: "a") != LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: "b"))
        #expect(LMStudioModelLifecycleError.invalidRemoteConfiguration != LMStudioModelLifecycleError.invalidHTTPResponse)
    }

    @Test func llmServiceErrorEquatable() async throws {
        #expect(LLMServiceError.invalidRemoteConfiguration == LLMServiceError.invalidRemoteConfiguration)
        #expect(LLMServiceError.invalidHTTPResponse == LLMServiceError.invalidHTTPResponse)
        #expect(LLMServiceError.missingResponseData == LLMServiceError.missingResponseData)
        #expect(LLMServiceError.httpError(statusCode: 500, body: "err") == LLMServiceError.httpError(statusCode: 500, body: "err"))
        #expect(LLMServiceError.httpError(statusCode: 500, body: "err") != LLMServiceError.httpError(statusCode: 500, body: "other"))
        #expect(LLMServiceError.invalidResponseFormat(.openAI) == LLMServiceError.invalidResponseFormat(.openAI))
        #expect(LLMServiceError.invalidResponseFormat(.openAI) != LLMServiceError.invalidResponseFormat(.anthropic))
        #expect(LLMServiceError.missingText(.openAI) == LLMServiceError.missingText(.openAI))
        #expect(LLMServiceError.missingText(.openAI) != LLMServiceError.missingText(.anthropic))
        #expect(LLMServiceError.appleStructuredDecodingFailure(details: "err", rawText: "raw") == LLMServiceError.appleStructuredDecodingFailure(details: "err", rawText: "raw"))
        #expect(LLMServiceError.appleStructuredDecodingFailure(details: "err", rawText: "raw") != LLMServiceError.appleStructuredDecodingFailure(details: "err2", rawText: "raw"))
        #expect(LLMServiceError.invalidRemoteConfiguration != LLMServiceError.invalidHTTPResponse)
    }

    @Test func analysisServiceErrorLocalizedDescriptionUnchangedByEquatable() async throws {
        let language = AppLanguage.simplifiedChinese
        let error = AnalysisServiceError.invalidConfiguration(L10n.string(.analysisNeedsBaseURL, language: language))
        #expect(error.errorDescription == L10n.string(.analysisNeedsBaseURL, language: language))
    }

    // MARK: - UserDefaults key migration

    @MainActor
    @Test func settingsStoreReadsFromLegacyKeyWhenNewKeyAbsent() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let newKey = "com.deskbrief.settings.analysisStartupMode"
        let oldKey = "settings.analysisStartupMode"

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        userDefaults.set(AnalysisStartupMode.scheduled.rawValue, forKey: oldKey)
        #expect(userDefaults.object(forKey: newKey) == nil)

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.analysisStartupMode == .scheduled)

        let migratedValue = userDefaults.string(forKey: newKey)
        #expect(migratedValue == AnalysisStartupMode.scheduled.rawValue)
    }

    @MainActor
    @Test func settingsStorePrefersNewKeyWhenBothExist() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let newKey = "com.deskbrief.settings.analysisStartupMode"
        let oldKey = "settings.analysisStartupMode"

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        userDefaults.set(AnalysisStartupMode.scheduled.rawValue, forKey: oldKey)
        userDefaults.set(AnalysisStartupMode.realtime.rawValue, forKey: newKey)

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.analysisStartupMode == .realtime)
    }

    @MainActor
    @Test func settingsStoreWritesOnlyToNewKey() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let newKey = "com.deskbrief.settings.analysisStartupMode"
        let oldKey = "settings.analysisStartupMode"

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        store.analysisStartupMode = .realtime

        #expect(userDefaults.string(forKey: newKey) == AnalysisStartupMode.realtime.rawValue)
        #expect(userDefaults.object(forKey: oldKey) == nil)
    }
}
