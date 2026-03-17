//
//  DailyWorkSummarizerTests.swift
//  DailyWorkSummarizerTests
//
//  Created by iBobby on 2025-12-01.
//

import Foundation
import CoreGraphics
import SQLite3
import Testing
@testable import DailyWorkSummarizer

@MainActor
struct DailyWorkSummarizerTests {
    @Test func openAICompatibleURLNormalization() async throws {
        let url1 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000")
        let url2 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1")
        let url3 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1/chat/completions")

        #expect(url1?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url2?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url3?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
    }

    @Test func lmStudioURLNormalization() async throws {
        let url1 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234")
        let url2 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api")
        let url3 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1")
        let url4 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1/chat")

        #expect(url1?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url2?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url3?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url4?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
    }

    @Test func nextAnalysisDateFallsToTomorrowWhenTodayIsMissed() async throws {
        var calendar = Calendar.reportCalendar
        calendar.timeZone = TimeZone(identifier: "America/Edmonton") ?? .current

        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 20, minute: 10))!
        let snapshot = AppSettingsSnapshot(
            screenshotIntervalMinutes: 5,
            analysisTimeMinutes: 18 * 60 + 30,
            automaticAnalysisEnabled: true,
            autoAnalysisRequiresCharger: false,
            appLanguage: .simplifiedChinese,
            analysisSummaryInstruction: AppDefaults.defaultAnalysisSummaryInstruction(language: .simplifiedChinese),
            provider: .openAI,
            apiBaseURL: "",
            modelName: "",
            apiKey: "",
            lmStudioContextLength: AppDefaults.lmStudioContextLength,
            categoryRules: []
        )

        let next = snapshot.nextAnalysisDate(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)

        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 14)
        #expect(components.hour == 18)
        #expect(components.minute == 30)
    }

    @Test func absenceRequiresSameMouseLocationAndSameFrontmostApp() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.Safari"
        )

        #expect(shouldRecord)
    }

    @Test func absenceDoesNotRecordWhenFrontmostAppChanges() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.dt.Xcode"
        )

        #expect(!shouldRecord)
    }

    @Test func retryPolicyRetriesServerAndInvalidResponseErrorsBeforeMaxAttempts() async throws {
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.httpError(statusCode: 500, body: "server error"),
                attempt: 1
            )
        )
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("no output"),
                attempt: 2
            )
        )
    }

    @Test func retryPolicyDoesNotRetryLengthOrFourthAttempt() async throws {
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.lengthTruncated("truncated"),
                attempt: 1
            )
        )
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("invalid category"),
                attempt: 3
            )
        )
    }

    @Test func pauseAfterFiveConsecutiveFailures() async throws {
        #expect(!AnalysisService.shouldPauseAfterConsecutiveFailures(4))
        #expect(AnalysisService.shouldPauseAfterConsecutiveFailures(5))
    }

    @Test func runtimeErrorRecordingFiltersOutNonAPIErrors() async throws {
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidResponse("empty output")))
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.httpError(statusCode: 500, body: "server error")))
        #expect(!AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidConfiguration("missing url")))
        #expect(!AnalysisService.shouldRecordRuntimeError(CancellationError()))
    }

    @Test func analysisPromptIncludesSummaryInstructionAndJSONContract() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let instruction = "请关注课程名称和项目仓库名"

        let prompt = L10n.analysisPrompt(
            with: rules,
            summaryInstruction: instruction,
            language: .simplifiedChinese
        )

        #expect(prompt.contains("描述要求："))
        #expect(prompt.contains(instruction))
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("专注工作：写代码和做项目"))
    }

    @Test func analysisResponseParsingHandlesThinkAndCodeFenceJSON() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let rawText = """
        <think>先看一下窗口内容</think>
        ```json
        {"category":"专注工作","summary":"开发 DailyWorkSummarizer 菜单栏项目"}
        ```
        """

        let response = AnalysisService.extractAnalysisResponse(from: rawText, validRules: rules)

        #expect(response?.category == "专注工作")
        #expect(response?.summary == "开发 DailyWorkSummarizer 菜单栏项目")
    }

    @Test func analysisResponseParsingRejectsInvalidStructuredPayloads() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
        ]

        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"错误类别","summary":"开发项目"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作","summary":"   "}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: "专注工作",
                validRules: rules
            ) == nil
        )
    }

    @MainActor
    @Test func settingsStorePersistsSummaryInstruction() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let updatedInstruction = "最近在做操作系统课程项目和 DailyWorkSummarizer 重构"

        #expect(
            store.analysisSummaryInstruction == AppDefaults.defaultAnalysisSummaryInstruction(language: .simplifiedChinese)
        )

        store.analysisSummaryInstruction = updatedInstruction

        let reloadedStore = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.snapshot.analysisSummaryInstruction == updatedInstruction)
        #expect(reloadedStore.analysisSummaryInstruction == updatedInstruction)
    }

    @Test func databaseMigratesAnalysisResultsSchemaToSummaryOnly() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let handle = try openSQLite(at: databaseURL)

        try executeSQL("""
            CREATE TABLE analysis_runs (
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
        """, on: handle)
        try executeSQL("""
            INSERT INTO analysis_runs (
                id, scheduled_for, started_at, finished_at, status, provider, base_url, model_name,
                prompt_snapshot, category_snapshot_json, total_items, success_count, failure_count,
                average_item_duration_seconds, error_message, created_at
            )
            VALUES (1, 0, 0, 0, 'succeeded', 'openai', '', '', '', '[]', 1, 1, 0, NULL, NULL, 0);
        """, on: handle)
        try executeSQL("""
            CREATE TABLE analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                raw_response_text TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                duration_minutes_snapshot INTEGER NOT NULL,
                created_at DOUBLE NOT NULL
            );
        """, on: handle)
        try executeSQL("""
            INSERT INTO analysis_results (
                id, run_id, captured_at, category_name, raw_response_text, status, error_message,
                duration_minutes_snapshot, created_at
            )
            VALUES (1, 1, 0, '专注工作', '{"category":"专注工作","summary":"旧数据"}', 'succeeded', NULL, 5, 0);
        """, on: handle)

        sqlite3_close(handle)

        _ = try AppDatabase(databaseURL: databaseURL)

        let columns = try columnNames(in: "analysis_results", databaseURL: databaseURL)
        let summaryText = try fetchOptionalString(
            "SELECT summary_text FROM analysis_results WHERE id = 1;",
            databaseURL: databaseURL
        )

        #expect(columns.contains("summary_text"))
        #expect(!columns.contains("raw_response_text"))
        #expect(summaryText == nil)
    }

    @Test func databaseStoresCategoryAndSummaryWithoutRawResponseText() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let runID = try database.createAnalysisRun(
            scheduledFor: Date(timeIntervalSince1970: 0),
            provider: .openAI,
            baseURL: "http://127.0.0.1:8000",
            modelName: "gpt-test",
            promptSnapshot: "prompt",
            categorySnapshotJSON: "[]",
            totalItems: 1
        )

        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: Date(timeIntervalSince1970: 60),
            categoryName: "专注工作",
            summaryText: "开发 DailyWorkSummarizer 项目",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 5
        )

        let columns = try columnNames(in: "analysis_results", databaseURL: databaseURL)
        let categoryName = try fetchOptionalString(
            "SELECT category_name FROM analysis_results WHERE run_id = \(runID);",
            databaseURL: databaseURL
        )
        let summaryText = try fetchOptionalString(
            "SELECT summary_text FROM analysis_results WHERE run_id = \(runID);",
            databaseURL: databaseURL
        )

        #expect(columns.contains("summary_text"))
        #expect(!columns.contains("raw_response_text"))
        #expect(categoryName == "专注工作")
        #expect(summaryText == "开发 DailyWorkSummarizer 项目")
    }
}

private func makeTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func openSQLite(at url: URL) throws -> OpaquePointer? {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        sqlite3_close(handle)
        throw DatabaseError.openDatabase(message)
    }
    return handle
}

private func executeSQL(_ sql: String, on handle: OpaquePointer?) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.execute(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite exec failed")
    }
}

private func columnNames(in table: String, databaseURL: URL) throws -> [String] {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 1) {
            columns.append(String(cString: text))
        }
    }
    return columns
}

private func fetchOptionalString(_ sql: String, databaseURL: URL) throws -> String? {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        return nil
    }
    guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, 0) else {
        return nil
    }
    return String(cString: text)
}
