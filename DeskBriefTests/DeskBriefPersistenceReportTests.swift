import CoreGraphics
import Foundation
import FoundationModels
import SQLite3
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @MainActor
    @Test func settingsStoreKeepsPreservedOtherLastAndRejectsReservedPrefixNames() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        try database.replaceCategoryRules([
            CategoryRule(name: "专注工作", description: "写代码"),
        ])

        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let editableRuleID = try #require(store.categoryRules.first?.id)
        let preservedRule = try #require(store.categoryRules.last)

        #expect(store.categoryRules.count == 2)
        #expect(preservedRule.name == AppDefaults.preservedOtherCategoryName)

        store.updateCategoryRuleName(id: editableRuleID, name: "PRESERVED_TEST")

        #expect(store.categoryRules.first?.name == "专注工作")
        #expect(
            store.categoryRulesValidationMessage
            == L10n.string(.settingsAnalysisReservedPrefixError, language: .simplifiedChinese)
        )

        store.addCategoryRule()
        let newlyAddedRule = try #require(store.categoryRules.dropLast().last)
        #expect(newlyAddedRule.colorHex == AppDefaults.categoryColorPreset(at: 1))
        store.updateCategoryRuleName(id: newlyAddedRule.id, name: "课程学习")
        store.updateCategoryRuleColor(id: newlyAddedRule.id, colorHex: "123abc")

        let preservedRuleID = try #require(store.categoryRules.last?.id)
        store.updateCategoryRuleDescription(id: preservedRuleID, description: "用户自定义的其他内容描述")

        #expect(store.categoryRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(store.categoryRules.dropLast().last?.name == "课程学习")
        #expect(store.categoryRules.dropLast().last?.colorHex == "#123ABC")
        #expect(store.categoryRules.last?.description == "用户自定义的其他内容描述")

        let persistedRules = try database.fetchCategoryRules()
        #expect(persistedRules.dropLast().last?.colorHex == "#123ABC")
    }

    @MainActor
    @Test func settingsStoreCanCopyModelConfigurationBetweenTabs() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        store.provider = .anthropic
        store.apiBaseURL = "https://screenshot.example.com"
        store.modelName = "claude-screenshot"
        store.apiKey = "screenshot-key"
        store.lmStudioContextLength = 8192
        store.screenshotAnalysisLMStudioAutoLoadUnloadModel = false
        store.imageAnalysisMethod = .multimodal
        store.copyScreenshotAnalysisModelToWorkContentSummary()

        #expect(store.workContentSummaryProvider == .anthropic)
        #expect(store.workContentSummaryAPIBaseURL == "https://screenshot.example.com")
        #expect(store.workContentSummaryModelName == "claude-screenshot")
        #expect(store.workContentSummaryAPIKey == "screenshot-key")
        #expect(!store.workContentSummaryLMStudioAutoLoadUnloadModel)

        store.workContentSummaryProvider = .lmStudio
        store.workContentSummaryAPIBaseURL = "http://127.0.0.1:1234"
        store.workContentSummaryModelName = "work-content-model"
        store.workContentSummaryAPIKey = "work-content-key"
        store.workContentSummaryLMStudioContextLength = 12000
        store.workContentSummaryLMStudioAutoLoadUnloadModel = true
        store.imageAnalysisMethod = .multimodal

        store.copyWorkContentSummaryModelToScreenshotAnalysis()

        #expect(store.provider == .lmStudio)
        #expect(store.apiBaseURL == "http://127.0.0.1:1234")
        #expect(store.modelName == "work-content-model")
        #expect(store.apiKey == "work-content-key")
        #expect(store.lmStudioContextLength == 12000)
        #expect(store.screenshotAnalysisLMStudioAutoLoadUnloadModel)
        #expect(store.imageAnalysisMethod == .multimodal)
    }

    @MainActor
    @Test func settingsStorePersistsLMStudioLifecycleTogglePerProfile() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.screenshotAnalysisLMStudioAutoLoadUnloadModel == AppDefaults.lmStudioAutoLoadUnloadModel)
        #expect(store.workContentSummaryLMStudioAutoLoadUnloadModel == AppDefaults.lmStudioAutoLoadUnloadModel)

        store.screenshotAnalysisLMStudioAutoLoadUnloadModel = false
        store.workContentSummaryLMStudioAutoLoadUnloadModel = false

        let reloadedStore = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(!reloadedStore.screenshotAnalysisLMStudioAutoLoadUnloadModel)
        #expect(!reloadedStore.workContentSummaryLMStudioAutoLoadUnloadModel)
        #expect(!reloadedStore.snapshot.screenshotAnalysisModelProfile.automaticallyLoadAndUnloadModel)
        #expect(!reloadedStore.snapshot.workContentSummaryModelProfile.automaticallyLoadAndUnloadModel)
    }

    @MainActor
    @Test func settingsStoreLogsCategoryRulePersistenceFailures() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let logStore = AppLogStore(database: database)
        try executeSQLite("DROP TABLE category_rules;", databaseURL: databaseURL)

        _ = SettingsStore(
            database: database,
            userDefaults: userDefaults,
            keychain: keychain,
            logStore: logStore
        )

        let messages = try database.fetchAppLogs().map(\.message)
        #expect(messages.contains { $0.contains("Failed to load category rules") })
        #expect(messages.contains { $0.contains("Failed to initialize category rules") })
    }

    @Test func databaseStoresSuccessfulAnalysisResultOnlyFields() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        _ = try database.createAnalysisRun(
            modelName: "gpt-test",
            totalItems: 1
        )

        let firstOutcome = try database.insertAnalysisResult(
            capturedAt: Date(timeIntervalSince1970: 60),
            categoryName: "专注工作",
            summaryText: "开发 DeskBrief 项目",
            durationMinutesSnapshot: 5
        )
        let duplicateOutcome = try database.insertAnalysisResult(
            capturedAt: Date(timeIntervalSince1970: 60),
            categoryName: "重复分类",
            summaryText: "不应覆盖",
            durationMinutesSnapshot: 10
        )

        let columns = try columnNames(in: "analysis_results", databaseURL: databaseURL)
        let rowCount = try fetchInt(
            "SELECT COUNT(*) FROM analysis_results;",
            databaseURL: databaseURL
        )
        let categoryName = try fetchOptionalString(
            "SELECT category_name FROM analysis_results WHERE captured_at = 60;",
            databaseURL: databaseURL
        )
        let summaryText = try fetchOptionalString(
            "SELECT summary_text FROM analysis_results WHERE captured_at = 60;",
            databaseURL: databaseURL
        )

        #expect(columns == ["id", "captured_at", "category_name", "summary_text", "duration_minutes_snapshot"])
        #expect(columns.contains("summary_text"))
        #expect(!columns.contains("raw_response_text"))
        #expect(!columns.contains("run_id"))
        #expect(!columns.contains("status"))
        #expect(!columns.contains("error_message"))
        #expect(!columns.contains("created_at"))
        #expect(firstOutcome == .inserted)
        #expect(duplicateOutcome == .duplicate)
        #expect(rowCount == 1)
        #expect(categoryName == "专注工作")
        #expect(summaryText == "开发 DeskBrief 项目")
    }

    @Test func dailyReportPromptIncludesActivitiesAndJSONContract() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let prompt = L10n.dailyReportSummaryPrompt(
            for: dayStart,
            categories: ["专注工作", "会议沟通"],
            activityLines: [
                "09:00 | 30分钟 | 专注工作 | 开发 DeskBrief 报告页",
                "10:00 | 5分钟 | 会议沟通 | 同步日报边界规则"
            ],
            summaryInstruction: "请突出项目名和课程名",
            language: .simplifiedChinese
        )

        #expect(prompt.contains("请突出项目名和课程名"))
        #expect(prompt.contains("\"dailySummary\""))
        #expect(prompt.contains("\"categorySummaries\""))
        #expect(prompt.contains("专注工作"))
        #expect(prompt.contains("10:00 | 5分钟 | 会议沟通 | 同步日报边界规则"))
    }

    @Test func dailyReportResponseParsingHandlesThinkAndCodeFenceJSON() async throws {
        let rawText = """
        <think>先整理一下当天内容</think>
        ```json
        {"dailySummary":"推进了 DeskBrief 的日报总结功能","categorySummaries":{"专注工作":"完成日报总结链路开发","会议沟通":"同步了日报边界规则"}}
        ```
        """

        let response = DailyReportSummaryService.extractDailyReportResponse(
            from: rawText,
            categories: ["专注工作", "会议沟通"]
        )

        #expect(response?.dailySummary == "推进了 DeskBrief 的日报总结功能")
        #expect(response?.categorySummaries["专注工作"] == "完成日报总结链路开发")
        #expect(response?.categorySummaries["会议沟通"] == "同步了日报边界规则")
    }

    @Test func dailyReportResponseParsingRejectsInvalidCategorySummaryShape() async throws {
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"日报","categorySummaries":{"专注工作":"工作总结"}}"#,
                categories: ["专注工作", "会议沟通"]
            ) == nil
        )
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"日报","categorySummaries":{"专注工作":"工作总结","会议沟通":"沟通总结","额外分类":"无效"}}"#,
                categories: ["专注工作", "会议沟通"]
            ) == nil
        )
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"  ","categorySummaries":{"专注工作":"工作总结","会议沟通":"沟通总结"}}"#,
                categories: ["专注工作", "会议沟通"]
            ) == nil
        )
    }

    @Test func databaseCreatesAndUpsertsDailyReports() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!

        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "第一次日报",
            categorySummaries: ["专注工作": "第一次分类总结"]
        )
        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "第二次日报",
            categorySummaries: ["专注工作": "第二次分类总结"]
        )

        let columns = try columnNames(in: "daily_reports", databaseURL: databaseURL)
        let fetchedReport = try database.fetchDailyReport(for: dayStart)
        let report = try #require(fetchedReport)

        #expect(columns == ["id", "day_start", "daily_summary_text", "category_summaries_json", "is_temporary"])
        #expect(report.dailySummaryText == "第二次日报")
        #expect(report.categorySummaries["专注工作"] == "第二次分类总结")
        #expect(!report.isTemporary)
    }

    @Test func databaseCreatesAndFetchesAppLogs() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let entry = AppLogEntry(
            createdAt: Date(timeIntervalSince1970: 120),
            level: .error,
            source: .analysis,
            message: "模型返回格式错误"
        )

        try database.insertAppLog(entry)

        let columns = try columnNames(in: "app_logs", databaseURL: databaseURL)
        let logs = try database.fetchAppLogs()

        #expect(columns == ["id", "created_at", "level", "source", "message"])
        #expect(logs.count == 1)
        #expect(logs.first?.id == entry.id)
        #expect(logs.first?.level == .error)
        #expect(logs.first?.source == .analysis)
        #expect(logs.first?.message == "模型返回格式错误")
    }

    @Test func appLogStorePersistsAcrossReloadAndPrunesOldEntries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = AppLogStore(database: database, maxEntries: 3)

        store.add(level: .error, source: .analysis, message: "first", createdAt: Date(timeIntervalSince1970: 1))
        store.add(level: .log, source: .analysis, message: "second", createdAt: Date(timeIntervalSince1970: 2))
        store.add(level: .error, source: .analysis, message: "third", createdAt: Date(timeIntervalSince1970: 3))
        store.add(level: .log, source: .analysis, message: "fourth", createdAt: Date(timeIntervalSince1970: 4))

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.message) == ["fourth", "third", "second"])

        let reloadedStore = AppLogStore(database: database, maxEntries: 3)
        #expect(reloadedStore.entries.count == 3)
        #expect(reloadedStore.entries.map(\.message) == ["fourth", "third", "second"])
    }

    @Test func appLogStoreRemoveAndClearPersistToDatabase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = AppLogStore(database: database)

        store.add(level: .error, source: .analysis, message: "first", createdAt: Date(timeIntervalSince1970: 1))
        store.add(level: .log, source: .analysis, message: "second", createdAt: Date(timeIntervalSince1970: 2))

        let removedID = try #require(store.entries.last?.id)
        store.remove(id: removedID)

        let remainingAfterRemove = try database.fetchAppLogs()
        #expect(remainingAfterRemove.count == 1)
        #expect(remainingAfterRemove.first?.message == "second")

        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(try database.fetchAppLogs().isEmpty)
    }

    @MainActor
    @Test func reportsViewModelLogsSourceLoadFailures() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let logStore = AppLogStore(database: database)
        let settingsStore = SettingsStore(
            database: database,
            userDefaults: userDefaults,
            keychain: keychain,
            logStore: logStore
        )
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: settingsStore,
            logStore: logStore,
            session: makeMockSession { request in
                try makeHTTPResponse(url: try #require(request.url), body: "{}")
            }
        )

        try executeSQLite("DROP TABLE analysis_results;", databaseURL: databaseURL)

        _ = ReportsViewModel(
            database: database,
            settingsStore: settingsStore,
            dailyReportSummaryService: summaryService,
            logStore: logStore
        )

        let logs = try database.fetchAppLogs()
        let log = try #require(logs.first)
        #expect(log.level == .error)
        #expect(log.source == .reports)
        #expect(log.message.contains("Failed to load report source items"))
    }

    @Test func appLogFilterAndMenuLocalizationReflectLogUI() async throws {
        #expect(AppLogFilter.all.includes(level: .error))
        #expect(AppLogFilter.all.includes(level: .log))
        #expect(AppLogFilter.error.includes(level: .error))
        #expect(!AppLogFilter.error.includes(level: .log))
        #expect(AppLogFilter.log.includes(level: .log))
        #expect(!AppLogFilter.log.includes(level: .error))

        #expect(L10n.string(.menuShowLogs, language: .simplifiedChinese) == "显示日志")
        #expect(L10n.string(.menuShowLogs, language: .english) == "Show Logs")
        #expect(L10n.string(.logsEmptyTitle, language: .simplifiedChinese) == "当前没有日志")
        #expect(L10n.string(.logsCopyAll, language: .simplifiedChinese) == "全部复制")
        #expect(L10n.string(.logsClearAll, language: .english) == "Clear All Logs")
        #expect(AppLogFilter.all.title(in: .simplifiedChinese) == "全部")
        #expect(AppLogFilter.error.title(in: .simplifiedChinese) == "错误")
        #expect(AppLogFilter.log.title(in: .simplifiedChinese) == "日志")
        #expect(AppLogFilter.error.title(in: .english) == "Error")
        #expect(AppLogFilter.log.title(in: .english) == "Log")
    }

    @Test func appLogExportTextIncludesMillisecondsAndLocalizedLevel() async throws {
        let entry = AppLogEntry(
            createdAt: Date(timeIntervalSince1970: 1_744_257_296.123),
            level: .error,
            source: .lmStudio,
            message: "LM Studio unload 成功"
        )

        let chineseText = entry.exportText(in: .simplifiedChinese)
        let englishText = entry.exportText(in: .english)

        #expect(chineseText.contains("[错误]"))
        #expect(chineseText.contains("LM Studio unload 成功"))
        #expect(chineseText.contains(".123"))
        #expect(englishText.contains("[Error]"))
        #expect(englishText.contains(".123"))
    }

    @Test func reportItemsDeriveAbsenceBetweenRecordedEvents() async throws {
        let calendar = makeTestCalendar()
        let firstStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 14, minute: 0))!
        let secondStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 14, minute: 20))!
        let items = [
            ReportSourceItem(id: 2, capturedAt: secondStart, categoryName: "会议沟通", durationMinutes: 5),
            ReportSourceItem(id: 1, capturedAt: firstStart, categoryName: "专注工作", durationMinutes: 4),
        ]

        let result = ReportsViewModel.itemsIncludingDerivedAbsences(from: items, calendar: calendar)
        let absence = try #require(result.first { $0.categoryName == AppDefaults.absenceCategoryName })

        #expect(absence.capturedAt == calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 14, minute: 4)))
        #expect(absence.durationMinutes == 16)
    }

    @Test func reportItemsDoNotDeriveTrailingAbsenceAfterLatestRecord() async throws {
        let calendar = makeTestCalendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 14, minute: 0))!
        let items = [
            ReportSourceItem(id: 1, capturedAt: start, categoryName: "专注工作", durationMinutes: 4),
        ]

        let result = ReportsViewModel.itemsIncludingDerivedAbsences(from: items, calendar: calendar)

        #expect(!result.contains { $0.categoryName == AppDefaults.absenceCategoryName })
    }

    @Test func reportItemsSplitDerivedAbsenceAcrossDays() async throws {
        let calendar = makeTestCalendar()
        let firstStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 23, minute: 50))!
        let secondStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 0, minute: 20))!
        let items = [
            ReportSourceItem(id: 2, capturedAt: secondStart, categoryName: "会议沟通", durationMinutes: 5),
            ReportSourceItem(id: 1, capturedAt: firstStart, categoryName: "专注工作", durationMinutes: 5),
        ]

        let result = ReportsViewModel.itemsIncludingDerivedAbsences(from: items, calendar: calendar)
        let absences = result
            .filter { $0.categoryName == AppDefaults.absenceCategoryName }
            .sorted { $0.capturedAt < $1.capturedAt }
        let firstAbsence = try #require(absences.first)
        let secondAbsence = try #require(absences.dropFirst().first)

        #expect(absences.count == 2)
        #expect(firstAbsence.capturedAt == calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 23, minute: 55)))
        #expect(firstAbsence.durationMinutes == 5)
        #expect(secondAbsence.capturedAt == calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 0, minute: 0)))
        #expect(secondAbsence.durationMinutes == 20)
    }

    @MainActor
    @Test func dailyReportSummaryServiceUsesWorkContentSummaryModelAndMarksIncompleteDayTemporary() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let screenshotTime = calendar.date(byAdding: .hour, value: 9, to: dayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .anthropic
        store.apiBaseURL = "https://screenshot.invalid"
        store.modelName = "screenshot-model"
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "work-content-model"
        store.summaryInstruction = "请突出项目名"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: screenshotTime,
            categoryName: "专注工作",
            summaryText: "开发 DeskBrief 日报功能",
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            MockURLProtocol.lastRequestedModel = body["model"] as? String

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了 DeskBrief 日报总结开发\\",\\"categorySummaries\\":{\\"专注工作\\":\\"实现了日报总结服务与报告页展示\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let report = try await service.summarizeDay(dayStart)
        let fetchedStoredReport = try database.fetchDailyReport(for: dayStart)
        let storedReport = try #require(fetchedStoredReport)

        #expect(MockURLProtocol.lastRequestedModel == "work-content-model")
        #expect(report.isTemporary)
        #expect(storedReport.isTemporary)
        #expect(storedReport.displayDailySummaryText == "完成了 DeskBrief 日报总结开发")
        #expect(storedReport.displayCategorySummary(for: "专注工作") == "实现了日报总结服务与报告页展示")
    }

    @MainActor
    @Test func dailyReportSummaryServiceUsesOnlyAnalysisResultsInPromptAndCategorySummaries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let workTime = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let meetingTime = calendar.date(byAdding: .hour, value: 10, to: dayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "daily-report-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: workTime,
            categoryName: "专注工作",
            summaryText: "实现日报过滤逻辑",
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            capturedAt: meetingTime,
            categoryName: "会议沟通",
            summaryText: "同步日报边界规则",
            durationMinutesSnapshot: 15
        )

        let absenceCategoryName = AppDefaults.absenceCategoryName
        let session = makeMockSession { request in
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let prompt = try #require(messages.first?["content"] as? String)

            #expect(prompt.contains("专注工作"))
            #expect(prompt.contains("实现日报过滤逻辑"))
            #expect(prompt.contains("会议沟通"))
            #expect(prompt.contains("同步日报边界规则"))
            #expect(!prompt.contains(absenceCategoryName))
            #expect(!prompt.contains("该时间段没有截屏"))

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了日报过滤逻辑\\",\\"categorySummaries\\":{\\"专注工作\\":\\"实现了日报过滤逻辑\\",\\"会议沟通\\":\\"完成了同步沟通\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let report = try await service.summarizeDay(dayStart)

        #expect(report.isTemporary)
        #expect(report.categorySummaries["专注工作"] == "实现了日报过滤逻辑")
        #expect(report.categorySummaries["会议沟通"] == "完成了同步沟通")
        #expect(report.categorySummaries[AppDefaults.absenceCategoryName] == nil)
    }

    @MainActor
    @Test func dailyReportSummaryServiceClipsCrossDayActivityItemsInPrompt() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let previousDayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!
        let dayStart = calendar.date(byAdding: .day, value: 1, to: previousDayStart)!
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let previousNight = calendar.date(byAdding: .minute, value: 23 * 60 + 53, to: previousDayStart)!
        let workTime = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let lateWorkTime = calendar.date(byAdding: .minute, value: 23 * 60 + 50, to: dayStart)!
        let nextDayTime = calendar.date(byAdding: .minute, value: 1, to: nextDayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "daily-report-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: previousNight,
            categoryName: "娱乐",
            summaryText: "观看Bilibili视频",
            durationMinutesSnapshot: 10
        )
        try database.insertAnalysisResult(
            capturedAt: workTime,
            categoryName: "专注工作",
            summaryText: "开发日报跨日裁剪逻辑",
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            capturedAt: lateWorkTime,
            categoryName: "收尾工作",
            summaryText: "整理当天事项",
            durationMinutesSnapshot: 20
        )
        try database.insertAnalysisResult(
            capturedAt: nextDayTime,
            categoryName: "次日事项",
            summaryText: "不应进入当天日报",
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let prompt = try #require(messages.first?["content"] as? String)

            #expect(prompt.contains("00:00 | 3 分钟 | 娱乐 | 观看Bilibili视频"))
            #expect(prompt.contains("09:00 | 30 分钟 | 专注工作 | 开发日报跨日裁剪逻辑"))
            #expect(prompt.contains("23:50 | 10 分钟 | 收尾工作 | 整理当天事项"))
            #expect(!prompt.contains("23:53 | 10 分钟 | 娱乐"))
            #expect(!prompt.contains("次日事项"))
            #expect(!prompt.contains("不应进入当天日报"))

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了跨日活动的日报总结\\",\\"categorySummaries\\":{\\"娱乐\\":\\"记录了跨日延续的视频观看时间\\",\\"专注工作\\":\\"开发了日报跨日裁剪逻辑\\",\\"收尾工作\\":\\"整理了当天事项\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let report = try await service.summarizeDay(dayStart)

        #expect(report.categorySummaries["娱乐"] == "记录了跨日延续的视频观看时间")
        #expect(report.categorySummaries["专注工作"] == "开发了日报跨日裁剪逻辑")
        #expect(report.categorySummaries["收尾工作"] == "整理了当天事项")
        #expect(report.categorySummaries["次日事项"] == nil)
    }

    @MainActor
    @Test func dailyReportSummaryServiceSkipsDaysWithoutAnalysisResults() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "daily-report-model"

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}"#
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        var didSkipForNoActivity = false
        do {
            _ = try await service.summarizeDay(dayStart)
        } catch DailyReportSummaryServiceError.noActivity(_) {
            didSkipForNoActivity = true
        } catch {
            #expect(Bool(false), "Expected noActivity, got \(error)")
        }

        #expect(didSkipForNoActivity)
        #expect(MockURLProtocol.requestCount == 0)
        let storedReport = try database.fetchDailyReport(for: dayStart)
        #expect(storedReport == nil)
    }

    @MainActor
    @Test func dailyReportSummaryServiceSkipsRowsWithoutAnalysisSummaries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let workTime = calendar.date(byAdding: .hour, value: 9, to: dayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "daily-report-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: workTime,
            categoryName: "专注工作",
            summaryText: "   ",
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}"#
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        var didSkipForNoActivity = false
        do {
            _ = try await service.summarizeDay(dayStart)
        } catch DailyReportSummaryServiceError.noActivity(_) {
            didSkipForNoActivity = true
        } catch {
            #expect(Bool(false), "Expected noActivity, got \(error)")
        }

        #expect(didSkipForNoActivity)
        #expect(MockURLProtocol.requestCount == 0)
        #expect(try database.fetchDailyReport(for: dayStart) == nil)
    }

    @MainActor
    @Test func dailyReportSummaryServiceSummarizesOnlyPendingDaysBeforeLatestActivityDay() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "daily-report-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayOne)!,
            categoryName: "专注工作",
            summaryText: "整理日报需求",
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayTwo)!,
            categoryName: "专注工作",
            summaryText: "继续开发第二天功能",
            durationMinutesSnapshot: 30
        )
        try database.upsertDailyReport(
            dayStart: dayOne,
            dailySummaryText: "旧的临时日报",
            categorySummaries: ["专注工作": "旧的临时分类总结"],
            isTemporary: true
        )

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了第一天的最终日报总结\\",\\"categorySummaries\\":{\\"专注工作\\":\\"完成了第一天的最终分类总结\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        await service.summarizeMissingDailyReportsIfNeeded()

        let fetchedFirstDayReport = try database.fetchDailyReport(for: dayOne)
        let firstDayReport = try #require(fetchedFirstDayReport)
        let secondDayReport = try database.fetchDailyReport(for: dayTwo)

        #expect(MockURLProtocol.requestCount == 1)
        #expect(!firstDayReport.isTemporary)
        #expect(firstDayReport.dailySummaryText == "完成了第一天的最终日报总结")
        #expect(firstDayReport.categorySummaries["专注工作"] == "完成了第一天的最终分类总结")
        #expect(secondDayReport == nil)
    }
}
