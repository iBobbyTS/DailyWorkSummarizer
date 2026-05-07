import Foundation
import SQLCipher
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
        #expect(DatabaseError.missingPassphrase(URL(fileURLWithPath: "/tmp/a.sqlite")) == DatabaseError.missingPassphrase(URL(fileURLWithPath: "/tmp/a.sqlite")))
        #expect(DatabaseError.invalidPassphrase("err") == DatabaseError.invalidPassphrase("err"))
        #expect(DatabaseError.keychainReadFailed(.failure(account: "a", status: -1)) == DatabaseError.keychainReadFailed(.failure(account: "a", status: -1)))
        #expect(DatabaseError.keychainReadFailed(.failure(account: "a", status: -1)) != DatabaseError.keychainReadFailed(.failure(account: "a", status: -2)))
        #expect(DatabaseError.keychainWriteFailed(.failure(account: "a", operation: .update, status: -1)) == DatabaseError.keychainWriteFailed(.failure(account: "a", operation: .update, status: -1)))
        #expect(DatabaseError.prepareStatement("err") == DatabaseError.prepareStatement("err"))
        #expect(DatabaseError.execute("err") == DatabaseError.execute("err"))
        #expect(DatabaseError.openDatabase("err") != DatabaseError.execute("err"))
    }

    @Test func databaseDefaultsToPlaintextWithoutKeychainPassphrase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let keychain = FakeKeychainStore()
        let database = try AppDatabase(databaseURL: databaseURL, keychain: keychain)
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "default plain"))

        let handle = try openSQLite(at: databaseURL, passphrase: nil)
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT message FROM app_logs LIMIT 1;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(statement.flatMap { sqlite3_column_text($0, 0) }.map { String(cString: $0) } == "default plain")
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount).isEmpty)
    }

    @Test func databaseSchemaInitializesCurrentVersionForNewDatabase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        _ = try AppDatabase(databaseURL: databaseURL)

        #expect(try columnNames(in: "summary_runs", databaseURL: databaseURL).contains("analysis_run_id"))
    }

    @Test func encryptedDatabaseCreatesAndReopensWithStoredPassphrase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let keychain = FakeKeychainStore()
        let firstDatabase = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)
        try firstDatabase.insertAppLog(AppLogEntry(level: .log, source: .app, message: "encrypted"))

        let secondDatabase = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)
        let logs = try secondDatabase.fetchAppLogs(limit: nil)

        #expect(logs.map(\.message) == ["encrypted"])
        let generatedPassphrase = keychain.string(for: AppDefaults.databasePassphraseAccount)
        #expect(generatedPassphrase.count == 16)
        #expect(generatedPassphrase.contains { $0.isUppercase })
        #expect(generatedPassphrase.contains { $0.isLowercase })
        #expect(generatedPassphrase.contains { $0.isNumber })
        #expect(generatedPassphrase.contains { !$0.isLetter && !$0.isNumber })
    }

    @Test func plaintextDatabaseOpensWithoutPassphraseWhenEncryptionDisabled() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let keychain = FakeKeychainStore(values: [
            AppDefaults.databasePassphraseAccount: "existing-key"
        ])
        let database = try AppDatabase(
            databaseURL: databaseURL,
            keychain: keychain,
            encryptionEnabled: false
        )
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "plain"))

        let handle = try openSQLite(at: databaseURL, passphrase: nil)
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT message FROM app_logs LIMIT 1;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(statement.flatMap { sqlite3_column_text($0, 0) }.map { String(cString: $0) } == "plain")
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount) == "existing-key")
    }

    @MainActor
    @Test func settingsStoreDefaultsMissingEncryptionPreferenceToOffAndPersistsIt() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let key = "com.deskbrief.settings.databaseEncryptionEnabled"
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            removeTemporaryDatabaseFiles(at: databaseURL)
        }

        let keychain = FakeKeychainStore()
        let database = try AppDatabase(databaseURL: databaseURL, keychain: keychain)
        #expect(userDefaults.object(forKey: key) == nil)

        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(!store.databaseEncryptionEnabled)
        #expect(userDefaults.object(forKey: key) as? Bool == false)
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount).isEmpty)
    }

    @MainActor
    @Test func settingsStoreDisablesEncryptionByDecryptingDatabaseAndDeletingKey() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            removeTemporaryDatabaseFiles(at: databaseURL)
        }

        let keychain = FakeKeychainStore()
        let database = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "decrypt"))
        userDefaults.set(true, forKey: "com.deskbrief.settings.databaseEncryptionEnabled")
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        try store.disableDatabaseEncryption()

        let handle = try openSQLite(at: databaseURL, passphrase: nil)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT message FROM app_logs LIMIT 1;", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(statement.flatMap { sqlite3_column_text($0, 0) }.map { String(cString: $0) } == "decrypt")
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount).isEmpty)
        #expect(!store.databaseEncryptionEnabled)
        #expect(userDefaults.bool(forKey: "com.deskbrief.settings.databaseEncryptionEnabled") == false)
    }

    @MainActor
    @Test func settingsStoreEncryptsPlaintextDatabaseWithNewKey() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            removeTemporaryDatabaseFiles(at: databaseURL)
        }

        userDefaults.set(false, forKey: "com.deskbrief.settings.databaseEncryptionEnabled")
        let keychain = FakeKeychainStore()
        let database = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: false)
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "encrypt"))
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let passphrase = try DatabasePassphrase("Aa1!Bb2@Cc3#Dd4$")

        try store.enableDatabaseEncryption(with: passphrase)

        let encryptedDatabase = try AppDatabase(databaseURL: databaseURL, passphrase: passphrase)
        let logs = try encryptedDatabase.fetchAppLogs(limit: nil)
        #expect(logs.map(\.message) == ["encrypt"])
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount) == passphrase.value)
        #expect(store.databaseEncryptionEnabled)

        let plaintextHandle = try openSQLite(at: databaseURL, passphrase: nil)
        defer { sqlite3_close(plaintextHandle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(plaintextHandle, "SELECT count(*) FROM sqlite_master;", -1, &statement, nil) != SQLITE_OK)
        sqlite3_finalize(statement)
    }

    @MainActor
    @Test func settingsStoreChangesEncryptedDatabasePassphrase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            removeTemporaryDatabaseFiles(at: databaseURL)
        }

        let oldPassphrase = try DatabasePassphrase("Aa1!old-pass")
        let newPassphrase = try DatabasePassphrase("Bb2@new-pass")
        let keychain = FakeKeychainStore(values: [
            AppDefaults.databasePassphraseAccount: oldPassphrase.value
        ])
        let database = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)
        try database.insertAppLog(AppLogEntry(level: .log, source: .app, message: "rekey"))
        userDefaults.set(true, forKey: "com.deskbrief.settings.databaseEncryptionEnabled")
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        try store.updateDatabasePassphrase(to: newPassphrase)

        do {
            _ = try AppDatabase(databaseURL: databaseURL, passphrase: oldPassphrase)
            Issue.record("Expected old database passphrase to fail")
        } catch DatabaseError.invalidPassphrase {
        }

        let reloaded = try AppDatabase(databaseURL: databaseURL, passphrase: newPassphrase)
        #expect(try reloaded.fetchAppLogs(limit: nil).map(\.message) == ["rekey"])
        #expect(keychain.string(for: AppDefaults.databasePassphraseAccount) == newPassphrase.value)
    }

    @Test func encryptedDatabaseRequiresStoredPassphraseForExistingFile() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let keychain = FakeKeychainStore()
        _ = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)

        do {
            _ = try AppDatabase(databaseURL: databaseURL, keychain: FakeKeychainStore(), encryptionEnabled: true)
            Issue.record("Expected missing database passphrase")
        } catch DatabaseError.missingPassphrase(let url) {
            #expect(url == databaseURL)
        }
    }

    @Test func encryptedDatabasePropagatesKeychainReadFailureForExistingFile() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let keychain = FakeKeychainStore()
        _ = try AppDatabase(databaseURL: databaseURL, keychain: keychain, encryptionEnabled: true)
        let readStatus = OSStatus(-25308)
        let failingKeychain = FakeKeychainStore(queuedReadResults: [
            .failure(account: AppDefaults.databasePassphraseAccount, status: readStatus)
        ])

        do {
            _ = try AppDatabase(databaseURL: databaseURL, keychain: failingKeychain, encryptionEnabled: true)
            Issue.record("Expected keychain read failure")
        } catch DatabaseError.keychainReadFailed(let result) {
            #expect(result == .failure(account: AppDefaults.databasePassphraseAccount, status: readStatus))
        } catch {
            Issue.record("Expected keychain read failure, got \(error)")
        }
    }

    @Test func encryptedDatabaseRejectsWrongPassphrase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        _ = try AppDatabase(
            databaseURL: databaseURL,
            passphrase: try DatabasePassphrase("correct-passphrase")
        )

        do {
            _ = try AppDatabase(
                databaseURL: databaseURL,
                passphrase: try DatabasePassphrase("wrong-passphrase")
            )
            Issue.record("Expected invalid database passphrase")
        } catch DatabaseError.invalidPassphrase {
        }
    }

    @Test func removeDatabaseFilesDeletesDatabaseAndSidecarsOnly() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        let screenshotsURL = databaseURL.deletingLastPathComponent().appendingPathComponent("screenshots", isDirectory: true)
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }
        defer { try? FileManager.default.removeItem(at: screenshotsURL) }

        try "db".write(to: databaseURL, atomically: true, encoding: .utf8)
        try "wal".write(to: walURL, atomically: true, encoding: .utf8)
        try "shm".write(to: shmURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)

        try AppDatabase.removeDatabaseFiles(at: databaseURL)

        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))
        #expect(FileManager.default.fileExists(atPath: screenshotsURL.path))
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

    @MainActor
    @Test func settingsStoreWritesToNamespacedKey() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let newKey = "com.deskbrief.settings.analysisStartupMode"

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
    }
}
