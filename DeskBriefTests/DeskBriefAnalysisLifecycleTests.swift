import CoreGraphics
import Foundation
import FoundationModels
import SQLite3
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @MainActor
    @Test func runNowWithoutPendingScreenshotsDoesNotCreateAnalysisRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(url: try #require(request.url), body: "{}")
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()

        #expect(!service.currentState.isRunning)
        #expect(MockURLProtocol.requestCount == 0)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 0)
    }

    @MainActor
    @Test func analysisRunCreationFailureIsLogged() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(url: try #require(request.url), body: "{}")
        }
        let logStore = AppLogStore(database: database)
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        try executeSQLite("DROP TABLE analysis_runs;", databaseURL: databaseURL)

        service.runNow()

        #expect(!service.currentState.isRunning)
        #expect(MockURLProtocol.requestCount == 0)

        let logs = try database.fetchAppLogs()
        let log = try #require(logs.first)
        #expect(log.level == .error)
        #expect(log.source == .analysis)
        #expect(log.message.contains("Failed to create analysis run"))
    }

    @MainActor
    @Test func manualAnalysisWithoutDailyReportSendsScreenshotCountNotification() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        _ = try makeAnalysisRun(database: database)
        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 255)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"完成通知测试\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let notificationSender = SpyAppNotificationSender()
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            session: session,
            notificationSender: notificationSender
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: summaryService,
            session: session,
            notificationSender: notificationSender
        )

        service.runNow()
        let didNotify = await waitUntil(timeoutSeconds: 5) {
            notificationSender.messages.count == 1
        }

        #expect(didNotify)
        #expect(notificationSender.messages.first?.title == "分析完成")
        #expect(notificationSender.messages.first?.body == "已分析 1 张截屏。")
    }

    @MainActor
    @Test func manualAnalysisWaitsForGeneratedDailyReportBeforeNotification() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 26))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://summary.example.com"
        store.workContentSummaryModelName = "summary-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayTwo)!,
            categoryName: "会议沟通",
            summaryText: "让前一天日报闭合",
            durationMinutesSnapshot: 30
        )

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 255)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let url = try #require(request.url)
            if url.host == "analysis.example.com" {
                let payload = """
                {
                  "choices": [
                    {
                      "message": {
                        "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"分析通知日报测试\\"}"
                      },
                      "finish_reason": "stop"
                    }
                  ]
                }
                """
                return try makeHTTPResponse(url: url, body: payload)
            }

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成日报通知\\",\\"categorySummaries\\":{\\"专注工作\\":\\"整理通知逻辑\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: url, body: payload)
        }
        let notificationSender = SpyAppNotificationSender()
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            session: session,
            notificationSender: notificationSender
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: summaryService,
            session: session,
            notificationSender: notificationSender
        )

        service.runNow()
        let didNotify = await waitUntil(timeoutSeconds: 6) {
            notificationSender.messages.count == 1
        }

        let storedReport = try #require(try database.fetchDailyReport(for: dayOne))
        let message = try #require(notificationSender.messages.first)

        #expect(didNotify)
        #expect(storedReport.dailySummaryText == "完成日报通知")
        #expect(message.body.contains("已分析 1 张截屏"))
        #expect(message.body.contains(L10n.reportDayDisplayText(for: dayOne, language: .simplifiedChinese)))
    }

    @MainActor
    @Test func analysisRequestWaitsForActiveSummaryRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 26))!
        let workStart = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let firstSummaryRequestStarted = DispatchSemaphore(value: 0)
        let releaseFirstSummaryRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://summary.example.com"
        store.workContentSummaryModelName = "summary-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: workStart,
            categoryName: "专注工作",
            summaryText: "实现全局互斥",
            durationMinutesSnapshot: 10
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .minute, value: 10, to: workStart)!,
            categoryName: "专注工作",
            summaryText: "合并总结请求",
            durationMinutesSnapshot: 10
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .minute, value: 20, to: workStart)!,
            categoryName: "会议沟通",
            summaryText: "关闭前一个工作块",
            durationMinutesSnapshot: 10
        )
        let existingRunCount = try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                firstSummaryRequestStarted.signal()
                _ = releaseFirstSummaryRequest.wait(timeout: .now() + 5)
            }

            let content: String
            if MockURLProtocol.requestCount == 2 {
                content = #"{"category":"专注工作","summary":"排队后分析"}"#
            } else {
                let requestBody = requestBodyData(from: request)
                let body = try requestBody.flatMap {
                    try JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                let messages = body["messages"] as? [[String: Any]]
                let prompt = messages?.first?["content"] as? String ?? ""
                content = prompt.contains("dailySummary")
                    ? #"{"dailySummary":"全局互斥后的日报","categorySummaries":{"专注工作":"分析和总结没有重叠","会议沟通":"同步状态"}}"#
                    : #"{"summary":"合并后的工作块总结"}"#
            }
            let responsePayload: [String: Any] = [
                "choices": [
                    [
                        "message": ["content": content],
                        "finish_reason": "stop",
                    ],
                ],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responsePayload)
            let responseBody = try #require(String(data: responseData, encoding: .utf8))
            return try makeHTTPResponse(url: try #require(request.url), body: responseBody)
        }

        let summaryService = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let analysisService = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: summaryService,
            session: session
        )

        let summaryTask = Task { @MainActor in
            await summaryService.backfillMissingSummaries()
        }
        #expect(await waitForSemaphore(firstSummaryRequestStarted, timeoutSeconds: 5))
        #expect(summaryService.currentState.isRunning)

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)
        analysisService.runNow()
        try await Task.sleep(for: .milliseconds(200))

        #expect(summaryService.currentState.isRunning)
        #expect(!analysisService.currentState.isRunning)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == existingRunCount)

        releaseFirstSummaryRequest.signal()
        await summaryTask.value

        let didAnalyze = await waitUntil(timeoutSeconds: 8) {
            (try? fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL)) == existingRunCount + 1
                && !analysisService.currentState.isRunning
                && !summaryService.currentState.isRunning
        }

        #expect(didAnalyze)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results WHERE summary_text = '排队后分析';", databaseURL: databaseURL) == 1)
    }

    @MainActor
    @Test func runningAnalysisAppendsNewScreenshotsToCurrentRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let firstRequestStarted = DispatchSemaphore(value: 0)
        let releaseFirstRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotsDirectory = try database.screenshotsDirectory()
        let firstScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        let secondScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1005-i5.jpg")
        try writeTestScreenshotPlaceholder(to: firstScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                firstRequestStarted.signal()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"处理追加队列\\"}"
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

        let logStore = AppLogStore(database: database)
        let dailyReportSummaryService = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: dailyReportSummaryService,
            session: session
        )

        service.runNow()
        #expect(await waitForSemaphore(firstRequestStarted, timeoutSeconds: 5))

        try writeTestScreenshotPlaceholder(to: secondScreenshot)
        service.runNow()
        #expect(service.currentState.totalCount == 2)

        releaseFirstRequest.signal()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(MockURLProtocol.requestCount == 2)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 2)
    }

    @MainActor
    @Test func realtimeAnalysisAppendsPendingScreenshotsToActiveRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let firstRequestStarted = DispatchSemaphore(value: 0)
        let releaseFirstRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotsDirectory = try database.screenshotsDirectory()
        let firstScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        let unrelatedPendingScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1005-i5.jpg")
        let realtimeScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1010-i5.jpg")
        try writeTestScreenshotPlaceholder(to: firstScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                firstRequestStarted.signal()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"追加 pending 队列\\"}"
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

        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.start()
        service.runNow()
        #expect(await waitForSemaphore(firstRequestStarted, timeoutSeconds: 5))

        store.analysisStartupMode = .realtime
        try writeTestScreenshotPlaceholder(to: unrelatedPendingScreenshot)
        try writeTestScreenshotPlaceholder(to: realtimeScreenshot)
        NotificationCenter.default.post(name: .screenshotFileSaved, object: realtimeScreenshot)

        let didAppendRealtimeScreenshot = await waitUntil(timeoutSeconds: 4) {
            service.currentState.totalCount == 3
        }
        #expect(didAppendRealtimeScreenshot)

        releaseFirstRequest.signal()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 3)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 3)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 3)
        #expect(!FileManager.default.fileExists(atPath: unrelatedPendingScreenshot.path))
        #expect(!FileManager.default.fileExists(atPath: realtimeScreenshot.path))
    }

    @MainActor
    @Test func realtimeAnalysisWithoutActiveRunScansPendingScreenshots() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .realtime

        let screenshotsDirectory = try database.screenshotsDirectory()
        let oldPendingScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        let realtimeScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1005-i5.jpg")
        try writeTestScreenshotPlaceholder(to: oldPendingScreenshot)
        try writeTestScreenshotPlaceholder(to: realtimeScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"扫描 pending 截屏\\"}"
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

        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.start()
        NotificationCenter.default.post(name: .screenshotFileSaved, object: realtimeScreenshot)

        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount >= 2 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 2)
        #expect(!FileManager.default.fileExists(atPath: oldPendingScreenshot.path))
        #expect(!FileManager.default.fileExists(atPath: realtimeScreenshot.path))
    }

    @MainActor
    @Test func realtimeBacklogCheckWarnsWhenPendingScreenshotsGrowByFive() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.analysisStartupMode = .realtime
        let notificationSender = SpyAppNotificationSender()
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store),
            notificationSender: notificationSender
        )

        let screenshotsDirectory = try database.screenshotsDirectory()
        func writePendingScreenshot(at index: Int) throws {
            let minuteOffset = index * 5
            let fileName = String(
                format: "20260426-%02d%02d-i5.jpg",
                10 + minuteOffset / 60,
                minuteOffset % 60
            )
            try writeTestScreenshotPlaceholder(to: screenshotsDirectory.appendingPathComponent(fileName))
        }

        service.start()
        for index in 0..<4 {
            try writePendingScreenshot(at: index)
        }
        await service.checkRealtimeAnalysisBacklogNow()
        #expect(notificationSender.messages.isEmpty)

        for index in 4..<9 {
            try writePendingScreenshot(at: index)
        }
        await service.checkRealtimeAnalysisBacklogNow()
        #expect(notificationSender.messages.count == 1)
        #expect(notificationSender.messages[0].title == "实时分析可能在积压")
        #expect(notificationSender.messages[0].body == "当前有 9 张截屏待分析，比上次检查多 5 张截屏。")

        for index in 9..<14 {
            try writePendingScreenshot(at: index)
        }
        await service.checkRealtimeAnalysisBacklogNow()
        #expect(notificationSender.messages.count == 2)
        #expect(notificationSender.messages[1].body == "当前有 14 张截屏待分析，比上次检查多 5 张截屏。")

        store.analysisStartupMode = .manual
        await service.checkRealtimeAnalysisBacklogNow()
        #expect(notificationSender.messages.count == 2)
    }

    @MainActor
    @Test func cancellingAnalysisStopsAppendingNewScreenshotsToCancelledRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let firstRequestStarted = DispatchSemaphore(value: 0)
        let releaseFirstRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotsDirectory = try database.screenshotsDirectory()
        let firstScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        let secondScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1005-i5.jpg")
        try writeTestScreenshotPlaceholder(to: firstScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                firstRequestStarted.signal()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"取消后重新排队\\"}"
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

        let logStore = AppLogStore(database: database)
        let dailyReportSummaryService = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: dailyReportSummaryService,
            session: session
        )

        service.runNow()
        #expect(await waitForSemaphore(firstRequestStarted, timeoutSeconds: 5))

        try writeTestScreenshotPlaceholder(to: secondScreenshot)
        service.cancelCurrentRun()
        service.runNow()
        #expect(service.currentState.totalCount == 1)

        releaseFirstRequest.signal()
        let didFinishQueuedRun = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount >= 3 && !service.currentState.isRunning
        }

        #expect(didFinishQueuedRun)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs ORDER BY id ASC LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs ORDER BY id DESC LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchOptionalString("SELECT status FROM analysis_runs ORDER BY id ASC LIMIT 1;", databaseURL: databaseURL) == "cancelled")
        #expect(try fetchOptionalString("SELECT status FROM analysis_runs ORDER BY id DESC LIMIT 1;", databaseURL: databaseURL) == "succeeded")
        #expect(!FileManager.default.fileExists(atPath: secondScreenshot.path))
    }

    @MainActor
    @Test func realtimeRequestsDuringCancellationCoalesceIntoPendingScanRun() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let firstRequestStarted = DispatchSemaphore(value: 0)
        let releaseFirstRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .realtime

        let screenshotsDirectory = try database.screenshotsDirectory()
        let firstScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        let secondScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1005-i5.jpg")
        let thirdScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1010-i5.jpg")
        try writeTestScreenshotPlaceholder(to: firstScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            if MockURLProtocol.requestCount == 1 {
                firstRequestStarted.signal()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"合并后续 pending 扫描\\"}"
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

        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.start()
        service.runNow()
        #expect(await waitForSemaphore(firstRequestStarted, timeoutSeconds: 5))

        service.cancelCurrentRun()
        try writeTestScreenshotPlaceholder(to: secondScreenshot)
        try writeTestScreenshotPlaceholder(to: thirdScreenshot)
        NotificationCenter.default.post(name: .screenshotFileSaved, object: secondScreenshot)
        NotificationCenter.default.post(name: .screenshotFileSaved, object: thirdScreenshot)
        try? await Task.sleep(for: .milliseconds(1300))

        releaseFirstRequest.signal()
        let didFinishQueuedRun = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount >= 4 && !service.currentState.isRunning
        }

        #expect(didFinishQueuedRun)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs ORDER BY id ASC LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs ORDER BY id DESC LIMIT 1;", databaseURL: databaseURL) == 3)
        #expect(try fetchOptionalString("SELECT status FROM analysis_runs ORDER BY id ASC LIMIT 1;", databaseURL: databaseURL) == "cancelled")
        #expect(try fetchOptionalString("SELECT status FROM analysis_runs ORDER BY id DESC LIMIT 1;", databaseURL: databaseURL) == "succeeded")
        #expect(!FileManager.default.fileExists(atPath: firstScreenshot.path))
        #expect(!FileManager.default.fileExists(atPath: secondScreenshot.path))
        #expect(!FileManager.default.fileExists(atPath: thirdScreenshot.path))
    }

    @MainActor
    @Test func duplicateCapturedAtResultKeepsExistingRowAndDeletesScreenshot() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal

        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        let firstOutcome = try database.insertAnalysisResult(
            capturedAt: capturedAt,
            categoryName: "已有分类",
            summaryText: "已有分析结果",
            durationMinutesSnapshot: 5
        )
        #expect(firstOutcome == .inserted)

        let screenshotsDirectory = try database.screenshotsDirectory()
        let duplicateScreenshot = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: duplicateScreenshot)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"不应覆盖旧结果\\"}"
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

        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 1 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(!FileManager.default.fileExists(atPath: duplicateScreenshot.path))
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 1)
        #expect(try fetchOptionalString("SELECT category_name FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "已有分类")
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "已有分析结果")
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
    }

    @Test func screenshotBrightnessThresholdTreatsTwoAsInactiveAndThreeAsActive() throws {
        let darkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        let brightURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        defer {
            try? FileManager.default.removeItem(at: darkURL)
            try? FileManager.default.removeItem(at: brightURL)
        }

        try writeSolidTestScreenshot(to: darkURL, gray: 2)
        try writeSolidTestScreenshot(to: brightURL, gray: 3)

        let darkSignal = try #require(AnalysisWorker.brightnessSignal(from: Data(contentsOf: darkURL)))
        let brightSignal = try #require(AnalysisWorker.brightnessSignal(from: Data(contentsOf: brightURL)))

        #expect(abs(darkSignal.averageEightBitPixelValue - 2) < 0.01)
        #expect(!darkSignal.isVisuallyActive)
        #expect(abs(brightSignal.averageEightBitPixelValue - 3) < 0.01)
        #expect(brightSignal.isVisuallyActive)
    }

    @MainActor
    @Test func darkScreenshotIsRecordedAsAwayAndDeletedWithoutModelRequest() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 0)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(url: try #require(request.url), body: "{}")
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            (try? fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL)) == 1
                && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(MockURLProtocol.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: screenshotURL.path))
        #expect(try fetchOptionalString("SELECT category_name FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == AppDefaults.absenceCategoryName)
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == AppDefaults.absenceCategoryName)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
    }

    @MainActor
    @Test func invalidScreenshotImageIsLoggedAsFailureAndDeletedWithoutResult() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: screenshotURL)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(url: try #require(request.url), body: "{}")
        }
        let logStore = AppLogStore(database: database)
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            (try? fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL)) == 1
                && !service.currentState.isRunning
        }
        let logMessage = try #require(try fetchOptionalString("SELECT message FROM app_logs WHERE source = 'analysis' LIMIT 1;", databaseURL: databaseURL))

        #expect(didFinish)
        #expect(MockURLProtocol.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: screenshotURL.path))
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(logMessage.contains("Failed to analyze screenshot"))
        #expect(logMessage.contains(L10n.string(.analysisInvalidImageData, language: store.appLanguage)))
    }

    @MainActor
    @Test func brightScreenshotContinuesToModelAnalysis() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 3)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"继续模型分析\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 1 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(!FileManager.default.fileExists(atPath: screenshotURL.path))
        #expect(try fetchOptionalString("SELECT category_name FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "专注工作")
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "继续模型分析")
    }

    @MainActor
    @Test func diskScreenshotRemovalFailureDoesNotTurnSuccessfulAnalysisIntoFailure() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        var screenshotsDirectoryForCleanup: URL?

        defer {
            if let screenshotsDirectoryForCleanup {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: screenshotsDirectoryForCleanup.path
                )
            }
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotsDirectory = try database.screenshotsDirectory()
        screenshotsDirectoryForCleanup = screenshotsDirectory
        let screenshotURL = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 3)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: screenshotsDirectory.path
        )

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"删除失败仍算成功\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 1 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(FileManager.default.fileExists(atPath: screenshotURL.path))
        #expect(try fetchOptionalString("SELECT status FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == "succeeded")
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "删除失败仍算成功")
        let removalLog = try fetchOptionalString(
            "SELECT message FROM app_logs WHERE source = 'analysis' AND message LIKE '%Failed to remove processed screenshot%' LIMIT 1;",
            databaseURL: databaseURL
        )
        #expect(removalLog?.contains("Failed to remove processed screenshot") == true)
    }

    @MainActor
    @Test func emptyTrimmedAnalysisFieldsRetryBeforeRunFailure() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let content = MockURLProtocol.requestCount == 1
                ? #"{"category":"专注工作","summary":"   "}"#
                : #"{"category":"专注工作","summary":"重试后完成截屏分析"}"#
            let responsePayload: [String: Any] = [
                "choices": [
                    [
                        "message": ["content": content],
                        "finish_reason": "stop",
                    ],
                ],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: responsePayload)
            let responseBody = try #require(String(data: responseData, encoding: .utf8))
            return try makeHTTPResponse(url: try #require(request.url), body: responseBody)
        }

        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 2 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "重试后完成截屏分析")
    }

    @MainActor
    @Test func diskAnalysisRereadsScreenshotFileBetweenRetryAttempts() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .disk

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeSolidTestScreenshot(to: screenshotURL, gray: 3)
        let observedAverages = LockedDoubleRecorder()

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let requestImageData = try openAIImageData(from: request)
            let brightness = try #require(AnalysisWorker.brightnessSignal(from: requestImageData))
            observedAverages.append(brightness.averageEightBitPixelValue)

            if MockURLProtocol.requestCount == 1 {
                try writeSolidTestScreenshot(to: screenshotURL, gray: 240)
                return try makeHTTPResponse(
                    url: try #require(request.url),
                    body: """
                    {
                      "choices": [
                        {
                          "message": {
                            "content": "not json"
                          },
                          "finish_reason": "stop"
                        }
                      ]
                    }
                    """
                )
            }

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: """
                {
                  "choices": [
                    {
                      "message": {
                        "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"硬盘重试重新读取文件\\"}"
                      },
                      "finish_reason": "stop"
                    }
                  ]
                }
                """
            )
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 2 && !service.currentState.isRunning
        }

        #expect(didFinish)
        let averages = observedAverages.snapshot
        #expect(averages.count == 2)
        #expect((averages.first ?? 0) < 30)
        #expect((averages.last ?? 0) > 200)
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "硬盘重试重新读取文件")
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
    }

    @MainActor
    @Test func memoryAnalysisReusesOriginalImageDataBetweenRetryAttempts() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .memory

        let originalData = try makeSolidTestScreenshotData(gray: 3)
        let pending = PendingScreenshot(
            memory: originalData,
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(pending)
        let observedAverages = LockedDoubleRecorder()

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let requestImageData = try openAIImageData(from: request)
            let brightness = try #require(AnalysisWorker.brightnessSignal(from: requestImageData))
            observedAverages.append(brightness.averageEightBitPixelValue)

            let content = MockURLProtocol.requestCount == 1
                ? "not json"
                : #"{\"category\":\"专注工作\",\"summary\":\"内存重试复用原始数据\"}"#
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: """
                {
                  "choices": [
                    {
                      "message": {
                        "content": "\(content)"
                      },
                      "finish_reason": "stop"
                    }
                  ]
                }
                """
            )
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 2 && !service.currentState.isRunning
        }

        #expect(didFinish)
        let averages = observedAverages.snapshot
        #expect(averages.count == 2)
        #expect((averages.first ?? 0) < 30)
        #expect((averages.last ?? 0) < 30)
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "内存重试复用原始数据")
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
    }

    @MainActor
    @Test func manualAnalysisProcessesMemoryPendingScreenshotLikeDisk() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .memory

        let pending = PendingScreenshot(
            memory: try makeSolidTestScreenshotData(gray: 3),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(pending)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"内存截图手动分析\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 1 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
        #expect(try database.listScreenshotFiles(defaultDurationMinutes: 5).isEmpty)
        #expect(try fetchOptionalString("SELECT category_name FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "专注工作")
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "内存截图手动分析")
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
    }

    @MainActor
    @Test func realtimeAnalysisProcessesMemoryPendingScreenshots() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .realtime
        store.screenshotStorageLocation = .memory

        let oldPending = PendingScreenshot(
            memory: try makeSolidTestScreenshotData(gray: 3),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            durationMinutes: 5
        )
        let realtimePending = PendingScreenshot(
            memory: try makeSolidTestScreenshotData(gray: 3),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5),
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(oldPending)
        database.pendingScreenshotStore.addMemoryScreenshot(realtimePending)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"内存截图实时分析\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.start()
        NotificationCenter.default.post(name: .screenshotFileSaved, object: realtimePending)
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 2 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
        #expect(try fetchInt("SELECT total_items FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 2)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 2)
    }

    @MainActor
    @Test func memoryDuplicateCapturedAtKeepsExistingRowAndRemovesPendingScreenshot() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .memory

        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        try database.insertAnalysisResult(
            capturedAt: capturedAt,
            categoryName: "已有分类",
            summaryText: "已有分析结果",
            durationMinutesSnapshot: 5
        )
        let pending = PendingScreenshot(
            memory: try makeSolidTestScreenshotData(gray: 3),
            capturedAt: capturedAt,
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(pending)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"不应覆盖旧结果\\"}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 1 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 1)
        #expect(try fetchOptionalString("SELECT category_name FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "已有分类")
        #expect(try fetchOptionalString("SELECT summary_text FROM analysis_results LIMIT 1;", databaseURL: databaseURL) == "已有分析结果")
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
    }

    @MainActor
    @Test func invalidMemoryScreenshotIsLoggedAsFailureAndRemovedWithoutResult() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .memory

        let pending = PendingScreenshot(
            memory: Data([0x01, 0x02, 0x03, 0x04]),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(pending)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            return try makeHTTPResponse(url: try #require(request.url), body: "{}")
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            (try? fetchInt("SELECT COUNT(*) FROM analysis_runs;", databaseURL: databaseURL)) == 1
                && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(MockURLProtocol.requestCount == 0)
        #expect(try database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: 5).isEmpty)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
    }

    @MainActor
    @Test func retryableMemoryAnalysisFailureRetainsPendingScreenshotForRetry() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .openAI
        store.apiBaseURL = "https://analysis.example.com"
        store.modelName = "screenshot-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.screenshotStorageLocation = .memory

        let pending = PendingScreenshot(
            memory: try makeSolidTestScreenshotData(gray: 3),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            durationMinutes: 5
        )
        database.pendingScreenshotStore.addMemoryScreenshot(pending)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "not json"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return try makeHTTPResponse(url: try #require(request.url), body: payload)
        }
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            dailyReportSummaryService: DailyReportSummaryService(database: database, settingsStore: store, session: session),
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            MockURLProtocol.requestCount == 3 && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(database.pendingScreenshotStore.pendingCount(defaultDurationMinutes: 5) == 1)
        #expect(try fetchInt("SELECT COUNT(*) FROM analysis_results;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT success_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 0)
        #expect(try fetchInt("SELECT failure_count FROM analysis_runs LIMIT 1;", databaseURL: databaseURL) == 1)
    }

    @MainActor
    @Test func lmStudioAnalysisAndSummarySameConfigurationKeepsModelLoaded() async throws {
        let paths = try await runAnalysisLifecycleScenario(
            analysisProvider: .lmStudio,
            summaryProvider: .lmStudio,
            summaryMatchesAnalysis: true
        )

        #expect(paths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/chat"])
    }

    @MainActor
    @Test func lmStudioAnalysisAndSummaryCanSkipExplicitLifecycleWhenDisabled() async throws {
        let paths = try await runAnalysisLifecycleScenario(
            analysisProvider: .lmStudio,
            summaryProvider: .lmStudio,
            summaryMatchesAnalysis: true,
            analysisLifecycleEnabled: false,
            summaryLifecycleEnabled: false
        )

        #expect(paths == ["/api/v1/chat", "/api/v1/chat"])
    }

    @MainActor
    @Test func lmStudioAnalysisAndDifferentLMStudioSummarySwitchesModels() async throws {
        let paths = try await runAnalysisLifecycleScenario(
            analysisProvider: .lmStudio,
            summaryProvider: .lmStudio,
            summaryMatchesAnalysis: false
        )

        #expect(paths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload", "/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload"])
    }

    @MainActor
    @Test func lmStudioAnalysisUnloadsBeforeNonLMStudioSummary() async throws {
        let paths = try await runAnalysisLifecycleScenario(
            analysisProvider: .lmStudio,
            summaryProvider: .openAI
        )

        #expect(paths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload", "/v1/chat/completions"])
    }

    @MainActor
    @Test func nonLMStudioAnalysisLoadsAndUnloadsLMStudioSummary() async throws {
        let paths = try await runAnalysisLifecycleScenario(
            analysisProvider: .openAI,
            summaryProvider: .lmStudio
        )

        #expect(paths == ["/v1/chat/completions", "/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload"])
    }

    @MainActor
    @Test func lmStudioSettingsModelTestLoadsAndUnloadsExplicitly() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .lmStudio
        store.apiBaseURL = "http://127.0.0.1:1234"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal

        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)
        defer { try? FileManager.default.removeItem(at: screenshotURL) }

        let session = makeMockSession { request in
            try lmStudioLifecycleTestResponse(for: request)
        }
        let logStore = AppLogStore(database: database)
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            session: session
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: summaryService,
            session: session
        )

        _ = try await service.testCurrentSettings(with: screenshotURL)

        #expect(MockURLProtocol.requestPaths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload"])
    }

    @MainActor
    @Test func lmStudioSummaryForceUnloadQueriesLoadedModelsListBeforeUnloading() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .lmStudio
        store.workContentSummaryAPIBaseURL = "http://127.0.0.1:1234"
        store.workContentSummaryModelName = "summary-model"
        store.workContentSummaryLMStudioContextLength = 12_000
        store.workContentSummaryLMStudioExplicitLoadUnloadModel = false

        let session = makeMockSession { request in
            try lmStudioLifecycleTestResponse(for: request)
        }
        let service = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            session: session
        )

        let didUnload = try await service.forceUnloadManagedModel()

        #expect(didUnload)
        #expect(MockURLProtocol.requestPaths == ["/api/v1/models", "/api/v1/models/unload"])
    }

    @MainActor
    @Test func lmStudioSummaryCancelUnloadsWhenLifecycleEnabled() async throws {
        let paths = try await runSummaryCancellationLifecycleScenario(lifecycleEnabled: true)

        #expect(paths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload"])
    }

    @MainActor
    @Test func lmStudioSummaryCancelSkipsUnloadWhenLifecycleDisabled() async throws {
        let paths = try await runSummaryCancellationLifecycleScenario(lifecycleEnabled: false)

        #expect(paths == ["/api/v1/chat"])
    }

    @MainActor
    @Test func lmStudioAnalysisShowsLoadingModelWhileLoadRequestIsActive() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .lmStudio
        store.apiBaseURL = "http://127.0.0.1:1234"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://summary.example.com"
        store.workContentSummaryModelName = "summary-model"

        let screenshotURL = try database.screenshotsDirectory().appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)

        let session = makeMockSession { request in
            if request.url?.path == "/api/v1/models/load" {
                loadStarted.signal()
                _ = releaseLoad.wait(timeout: .now() + 5)
            }
            return try lmStudioLifecycleTestResponse(for: request)
        }
        let logStore = AppLogStore(database: database)
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            session: session
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: summaryService,
            session: session
        )

        service.runNow()
        #expect(await waitForSemaphore(loadStarted, timeoutSeconds: 5))
        #expect(service.currentState.isRunning)
        #expect(service.currentState.isLoadingModel)
        #expect(service.currentState.modelName == "analysis-model")

        releaseLoad.signal()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }

        #expect(didFinish)
    }

    @MainActor
    @Test func lmStudioSummaryShowsLoadingModelWhileLoadRequestIsActive() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 26))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let loadStarted = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .lmStudio
        store.workContentSummaryAPIBaseURL = "http://127.0.0.1:1234"
        store.workContentSummaryModelName = "summary-model"
        store.workContentSummaryLMStudioContextLength = 12_000

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayOne)!,
            categoryName: "专注工作",
            summaryText: "准备日报总结",
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayTwo)!,
            categoryName: "专注工作",
            summaryText: "闭合前一天",
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            if request.url?.path == "/api/v1/models/load" {
                loadStarted.signal()
                _ = releaseLoad.wait(timeout: .now() + 5)
            }
            return try lmStudioLifecycleTestResponse(for: request)
        }
        let service = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            session: session
        )

        let task = Task { @MainActor in
            await service.summarizeAfterAnalysis(
                workBlockDayStarts: [],
                dailyReportCandidateDayStarts: [dayOne],
                lmStudioLifecyclePolicy: .loadForSummaryThenUnload
            )
        }
        #expect(await waitForSemaphore(loadStarted, timeoutSeconds: 5))
        #expect(service.currentState.isRunning)
        #expect(service.currentState.isLoadingModel)
        #expect(service.currentState.modelName == "summary-model")

        releaseLoad.signal()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }
        await task.value

        #expect(didFinish)
    }

    @MainActor
    @Test func lmStudioAnalysisWorkerPropagatesModelInstanceIDToCleanupLog() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .lmStudio
        store.apiBaseURL = "http://127.0.0.1:1234"
        store.modelName = "analysis-model"
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://summary.example.com"
        store.workContentSummaryModelName = "summary-model"

        let screenshotsDirectory = try database.screenshotsDirectory()
        let screenshotURL = screenshotsDirectory.appendingPathComponent("20260313-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)

        let session = makeMockSession { request in
            try lmStudioLifecycleTestResponse(for: request)
        }
        let logStore = AppLogStore(database: database)
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            session: session
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: summaryService,
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }
        let logs = try database.fetchAppLogs()

        #expect(didFinish)
        #expect(MockURLProtocol.requestPaths == ["/api/v1/models/load", "/api/v1/chat", "/api/v1/models/unload"])
        #expect(logs.contains { $0.message.contains("analysis-model-instance") })
    }

    // MARK: - PendingScreenshot

    @Test func pendingScreenshotCreatedFromDiskFileRecord() async throws {
        let url = URL(fileURLWithPath: "/tmp/test-screenshot.jpg")
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        let record = ScreenshotFileRecord(url: url, capturedAt: capturedAt, durationMinutes: 5)
        let pending = PendingScreenshot(disk: record)

        #expect(pending.id == "test-screenshot.jpg")
        #expect(pending.capturedAt == capturedAt)
        #expect(pending.durationMinutes == 5)
        #expect(pending.storageLocation == .disk)
        #expect(pending.fileURL == url)
        #expect(pending.imageData == nil)
    }

    @Test func pendingScreenshotCreatedFromMemoryData() async throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header prefix
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        let pending = PendingScreenshot(memory: imageData, capturedAt: capturedAt, durationMinutes: 5)

        #expect(pending.storageLocation == .memory)
        #expect(pending.imageData == imageData)
        #expect(pending.fileURL == nil)
        #expect(pending.capturedAt == capturedAt)
        #expect(pending.durationMinutes == 5)
        #expect(!pending.id.isEmpty) // UUID is non-empty
    }

    @Test func pendingScreenshotDisplayNameShowsAppropriateFormat() async throws {
        let diskPending = PendingScreenshot(disk: ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/photo.jpg"),
            capturedAt: Date(),
            durationMinutes: 5
        ))
        let memoryPending = PendingScreenshot(memory: Data(), capturedAt: Date(), durationMinutes: 5)

        #expect(diskPending.displayName == "photo.jpg")
        #expect(memoryPending.displayName.hasPrefix("[memory] "))
    }

    @Test func pendingScreenshotEqualityAndHashing() async throws {
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        let a = PendingScreenshot(disk: ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            capturedAt: capturedAt,
            durationMinutes: 5
        ))
        let aAgain = PendingScreenshot(disk: ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/a.jpg"),
            capturedAt: capturedAt,
            durationMinutes: 5
        ))
        let b = PendingScreenshot(disk: ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/b.jpg"),
            capturedAt: capturedAt,
            durationMinutes: 5
        ))

        #expect(a == aAgain)
        #expect(a != b)
        #expect(Set([a, aAgain, b]).count == 2)
    }

    @Test func pendingScreenshotEndAtCalculatesCorrectly() async throws {
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0)
        let pending = PendingScreenshot(disk: ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/test.jpg"),
            capturedAt: capturedAt,
            durationMinutes: 10
        ))

        #expect(pending.endAt == capturedAt.addingTimeInterval(10 * 60))
    }

    // MARK: - PendingScreenshotStore

    @MainActor
    @Test func pendingScreenshotStoreListsCombinedDiskAndMemoryScreenshots() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = database.pendingScreenshotStore

        // Add a disk screenshot
        let screenshotsDirectory = try database.screenshotsDirectory()
        let diskScreenshotURL = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: diskScreenshotURL)

        // Add a memory screenshot
        let memoryData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5)
        let memoryPending = PendingScreenshot(memory: memoryData, capturedAt: capturedAt, durationMinutes: 5)
        store.addMemoryScreenshot(memoryPending)

        // List should include both
        let all = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(all.count == 2)

        let diskOnes = all.filter { $0.storageLocation == .disk }
        let memoryOnes = all.filter { $0.storageLocation == .memory }
        #expect(diskOnes.count == 1)
        #expect(memoryOnes.count == 1)
        #expect(memoryOnes[0].imageData == memoryData)
    }

    @MainActor
    @Test func pendingScreenshotStoreSortsDiskAndMemoryByCaptureTime() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = database.pendingScreenshotStore

        let screenshotsDirectory = try database.screenshotsDirectory()
        let diskScreenshotURL = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: diskScreenshotURL)

        let earlierMemory = PendingScreenshot(
            memory: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 9, minute: 55),
            durationMinutes: 5
        )
        let laterMemory = PendingScreenshot(
            memory: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            capturedAt: makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5),
            durationMinutes: 5
        )
        store.addMemoryScreenshot(laterMemory)
        store.addMemoryScreenshot(earlierMemory)

        let all = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(all.map(\.capturedAt) == [
            earlierMemory.capturedAt,
            makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 0),
            laterMemory.capturedAt,
        ])
        #expect(all.map(\.storageLocation) == [.memory, .disk, .memory])
    }

    @MainActor
    @Test func pendingScreenshotStoreRemoveHandlesDiskAndMemory() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = database.pendingScreenshotStore

        // Create disk screenshot
        let screenshotsDirectory = try database.screenshotsDirectory()
        let diskScreenshotURL = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: diskScreenshotURL)

        // Create memory screenshot
        let memoryData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5)
        let memoryPending = PendingScreenshot(memory: memoryData, capturedAt: capturedAt, durationMinutes: 5)
        store.addMemoryScreenshot(memoryPending)

        // Get both screenshots
        let all = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(all.count == 2)

        // Remove disk screenshot - should delete file
        guard let diskPending = all.first(where: { $0.storageLocation == .disk }) else {
            Issue.record("Disk pending screenshot not found")
            return
        }
        try store.remove(diskPending)
        #expect(!FileManager.default.fileExists(atPath: diskScreenshotURL.path))

        // Remove memory screenshot - should remove from array
        guard let memPending = all.first(where: { $0.storageLocation == .memory }) else {
            Issue.record("Memory pending screenshot not found")
            return
        }
        try store.remove(memPending)

        // Only disk should remain (0 since file is deleted, memory is gone)
        let after = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(after.isEmpty)
    }

    @MainActor
    @Test func pendingScreenshotStoreMemoryScreenshotsNotPersistedAfterReset() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = database.pendingScreenshotStore

        // Add a memory screenshot
        let memoryData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5)
        let memoryPending = PendingScreenshot(memory: memoryData, capturedAt: capturedAt, durationMinutes: 5)
        store.addMemoryScreenshot(memoryPending)

        // Verify it's there
        let before = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(before.count == 1)

        // Remove all memory screenshots (simulating app exit)
        store.removeAllMemoryScreenshots()

        // Should be empty now
        let after = try store.listPendingScreenshots(defaultDurationMinutes: 5)
        #expect(after.isEmpty)
    }

    @MainActor
    @Test func pendingScreenshotStorePendingCountReflectsCombinedTotal() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = database.pendingScreenshotStore

        // Initially empty
        #expect(store.pendingCount(defaultDurationMinutes: 5) == 0)

        // Add a disk screenshot
        let screenshotsDirectory = try database.screenshotsDirectory()
        let diskURL = screenshotsDirectory.appendingPathComponent("20260426-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: diskURL)
        #expect(store.pendingCount(defaultDurationMinutes: 5) == 1)

        // Add a memory screenshot
        let memoryData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let capturedAt = makeScreenshotDate(year: 2026, month: 4, day: 26, hour: 10, minute: 5)
        store.addMemoryScreenshot(PendingScreenshot(memory: memoryData, capturedAt: capturedAt, durationMinutes: 5))
        #expect(store.pendingCount(defaultDurationMinutes: 5) == 2)
    }

    private func runSummaryCancellationLifecycleScenario(lifecycleEnabled: Bool) async throws -> [String] {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 26))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let summaryRequestStarted = DispatchSemaphore(value: 0)
        let releaseSummaryRequest = DispatchSemaphore(value: 0)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentSummaryProvider = .lmStudio
        store.workContentSummaryAPIBaseURL = "http://127.0.0.1:1234"
        store.workContentSummaryModelName = "summary-model"
        store.workContentSummaryLMStudioContextLength = 12_000
        store.workContentSummaryLMStudioExplicitLoadUnloadModel = lifecycleEnabled

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayOne)!,
            categoryName: "专注工作",
            summaryText: "准备日报总结",
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayTwo)!,
            categoryName: "专注工作",
            summaryText: "闭合前一天",
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            if request.url?.path == "/api/v1/chat" {
                summaryRequestStarted.signal()
                _ = releaseSummaryRequest.wait(timeout: .now() + 5)
            }
            return try lmStudioLifecycleTestResponse(for: request)
        }
        let service = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: AppLogStore(database: database),
            session: session
        )

        let task = Task { @MainActor in
            await service.summarizeAfterAnalysis(
                workBlockDayStarts: [],
                dailyReportCandidateDayStarts: [dayOne],
                lmStudioLifecyclePolicy: .loadForSummaryThenUnload
            )
        }
        #expect(await waitForSemaphore(summaryRequestStarted, timeoutSeconds: 5))
        #expect(service.currentState.isRunning)

        service.cancelCurrentSummary()
        #expect(service.currentState.stoppingStage == .stoppingGeneration)
        releaseSummaryRequest.signal()

        let didStop = await waitUntil(timeoutSeconds: 8) {
            !service.currentState.isRunning
        }
        await task.value

        #expect(didStop)
        return MockURLProtocol.requestPaths
    }

    private func runAnalysisLifecycleScenario(
        analysisProvider: ModelProvider,
        summaryProvider: ModelProvider,
        summaryMatchesAnalysis: Bool = false,
        analysisLifecycleEnabled: Bool = true,
        summaryLifecycleEnabled: Bool = true
    ) async throws -> [String] {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = analysisProvider
        store.apiBaseURL = analysisProvider == .lmStudio ? "http://127.0.0.1:1234" : "https://analysis.example.com"
        store.modelName = "analysis-model"
        store.lmStudioContextLength = 6000
        store.screenshotAnalysisLMStudioExplicitLoadUnloadModel = analysisLifecycleEnabled
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        store.workContentSummaryProvider = summaryProvider
        store.workContentSummaryAPIBaseURL = summaryProvider == .lmStudio
            ? "http://127.0.0.1:1234"
            : "https://summary.example.com"
        store.workContentSummaryModelName = summaryMatchesAnalysis ? "analysis-model" : "summary-model"
        store.workContentSummaryLMStudioContextLength = summaryMatchesAnalysis ? 6000 : 12000
        store.workContentSummaryLMStudioExplicitLoadUnloadModel = summaryLifecycleEnabled

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayTwo)!,
            categoryName: "专注工作",
            summaryText: "让前一天日报闭合",
            durationMinutesSnapshot: 30
        )

        let screenshotsDirectory = try database.screenshotsDirectory()
        let screenshotURL = screenshotsDirectory.appendingPathComponent("20260312-1000-i5.jpg")
        try writeTestScreenshotPlaceholder(to: screenshotURL)

        let session = makeMockSession { request in
            try lmStudioLifecycleTestResponse(for: request)
        }
        let logStore = AppLogStore(database: database)
        let summaryService = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            session: session
        )
        let service = AnalysisService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            dailyReportSummaryService: summaryService,
            session: session
        )

        service.runNow()
        let didFinish = await waitUntil(timeoutSeconds: 8) {
            (try? database.fetchDailyReport(for: dayOne)) != nil && !service.currentState.isRunning
        }

        #expect(didFinish)
        #expect(try database.fetchDailyReport(for: dayOne) != nil)
        return MockURLProtocol.requestPaths
    }

}
