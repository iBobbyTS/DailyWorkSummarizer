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
        store.workContentSummaryLMStudioAutoLoadUnloadModel = false

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
        store.screenshotAnalysisLMStudioAutoLoadUnloadModel = analysisLifecycleEnabled
        store.imageAnalysisMethod = .multimodal
        store.analysisStartupMode = .manual

        store.workContentSummaryProvider = summaryProvider
        store.workContentSummaryAPIBaseURL = summaryProvider == .lmStudio
            ? "http://127.0.0.1:1234"
            : "https://summary.example.com"
        store.workContentSummaryModelName = summaryMatchesAnalysis ? "analysis-model" : "summary-model"
        store.workContentSummaryLMStudioContextLength = summaryMatchesAnalysis ? 6000 : 12000
        store.workContentSummaryLMStudioAutoLoadUnloadModel = summaryLifecycleEnabled

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayOne)!,
            categoryName: "专注工作",
            summaryText: "实现前一天功能",
            durationMinutesSnapshot: 30
        )

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

        #expect(didFinish)
        #expect(try database.fetchDailyReport(for: dayOne) != nil)
        return MockURLProtocol.requestPaths
    }

}
