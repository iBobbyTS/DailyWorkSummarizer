import Foundation
import Testing
@testable import DeskBrief

private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    var prompts: [String] {
        lock.withLock {
            values
        }
    }
}

@MainActor
extension DeskBriefTests {
    @Test func dailyWorkBlockSummaryTableUsesMinimalSchemaAndSupportsCrossDayFetch() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let startAt = calendar.date(byAdding: .minute, value: -30, to: dayStart)!
        let endAt = calendar.date(byAdding: .minute, value: 30, to: dayStart)!

        try database.upsertDailyWorkBlockSummary(
            categoryName: "专注工作",
            startAt: startAt,
            endAt: endAt,
            summaryText: "完成跨天工作块总结"
        )
        try database.upsertDailyWorkBlockSummary(
            categoryName: "会议沟通",
            startAt: startAt,
            endAt: endAt,
            summaryText: "同一时间段更新为最新总结"
        )

        let columns = try columnNames(in: "daily_work_block_summaries", databaseURL: databaseURL)
        let intersecting = try database.fetchDailyWorkBlockSummaries(
            intersecting: DateInterval(start: dayStart, end: calendar.date(byAdding: .hour, value: 1, to: dayStart)!)
        )
        let stored = try #require(intersecting.first)

        #expect(columns == ["id", "category_name", "start_at", "end_at", "summary_text"])
        #expect(intersecting.count == 1)
        #expect(stored.categoryName == "会议沟通")
        #expect(stored.startAt == startAt)
        #expect(stored.endAt == endAt)
        #expect(stored.summaryText == "同一时间段更新为最新总结")
    }

    @Test func dailyWorkBlocksKeepCrossDayContiguousItemsTogether() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let previousNight = calendar.date(byAdding: .minute, value: -10, to: dayStart)!
        let midnightTen = calendar.date(byAdding: .minute, value: 10, to: dayStart)!
        let midnightTwenty = calendar.date(byAdding: .minute, value: 20, to: dayStart)!

        let blocks = DailyWorkBlockComposer.groupBlocks(from: [
            DailyReportActivityItem(id: 1, capturedAt: previousNight, categoryName: "专注工作", durationMinutes: 20, itemSummaryText: "实现跨天块一"),
            DailyReportActivityItem(id: 2, capturedAt: midnightTen, categoryName: "专注工作", durationMinutes: 10, itemSummaryText: "实现跨天块二"),
            DailyReportActivityItem(id: 3, capturedAt: midnightTwenty, categoryName: "会议沟通", durationMinutes: 5, itemSummaryText: "次块用于闭合"),
        ])

        let firstBlock = try #require(blocks.first)

        #expect(firstBlock.categoryName == "专注工作")
        #expect(firstBlock.startAt == previousNight)
        #expect(firstBlock.endAt == midnightTwenty)
        #expect(firstBlock.sourceItems.map(\.id) == [1, 2])
        #expect(firstBlock.isClosed)
    }

    @Test func dailyHeatmapCompositionUsesBlockSummariesAndKeepsNonOverlappingFallback() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let range = DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart)!)
        let workStart = calendar.date(byAdding: .minute, value: 8 * 60 + 30, to: dayStart)!
        let summaryStart = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let summaryEnd = calendar.date(byAdding: .hour, value: 10, to: dayStart)!
        let meetingStart = calendar.date(byAdding: .hour, value: 10, to: dayStart)!

        let events = DailyWorkBlockComposer.composeDailyHeatmapEvents(
            rawItems: [
                DailyReportActivityItem(id: 1, capturedAt: workStart, categoryName: "专注工作", durationMinutes: 60, itemSummaryText: "原始工作一"),
                DailyReportActivityItem(id: 2, capturedAt: calendar.date(byAdding: .minute, value: 9 * 60 + 30, to: dayStart)!, categoryName: "专注工作", durationMinutes: 30, itemSummaryText: "原始工作二"),
                DailyReportActivityItem(id: 3, capturedAt: meetingStart, categoryName: "会议沟通", durationMinutes: 30, itemSummaryText: "同步热力图设计"),
            ],
            blockSummaries: [
                DailyWorkBlockSummaryRecord(
                    id: 10,
                    categoryName: "专注工作",
                    startAt: summaryStart,
                    endAt: summaryEnd,
                    summaryText: "合并后的连续工作总结"
                )
            ],
            range: range,
            selectedCategories: ["专注工作", "会议沟通"]
        )

        let workEvents = events.filter { $0.category == "专注工作" }
        let fallback = try #require(workEvents.first { $0.start == workStart && $0.end == summaryStart })
        let summary = try #require(workEvents.first { $0.summaryText == "合并后的连续工作总结" })
        let meeting = try #require(events.first { $0.category == "会议沟通" })

        #expect(fallback.start == workStart)
        #expect(fallback.end == summaryStart)
        #expect(fallback.summaryText == nil)
        #expect(fallback.summaryStart == nil)
        #expect(fallback.summaryEnd == nil)
        #expect(summary.start == summaryStart)
        #expect(summary.end == summaryEnd)
        #expect(summary.summaryStart == summaryStart)
        #expect(summary.summaryEnd == summaryEnd)
        #expect(meeting.start == meetingStart)
        #expect(meeting.summaryText == nil)
        #expect(events.allSatisfy { event in
            event.category != "专注工作" || event.end <= summaryStart || event.start >= summaryStart
        })
    }

    @Test func dailyHeatmapCompositionDoesNotUseRawAnalysisSummariesForHoverText() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let firstStart = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let secondStart = calendar.date(byAdding: .minute, value: 10, to: firstStart)!
        let thirdStart = calendar.date(byAdding: .minute, value: 20, to: firstStart)!
        let range = DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart)!)

        let events = DailyWorkBlockComposer.composeDailyHeatmapEvents(
            rawItems: [
                DailyReportActivityItem(id: 1, capturedAt: firstStart, categoryName: "专注工作", durationMinutes: 10, itemSummaryText: "实现热力图一"),
                DailyReportActivityItem(id: 2, capturedAt: secondStart, categoryName: "专注工作", durationMinutes: 10, itemSummaryText: "实现热力图二"),
                DailyReportActivityItem(id: 3, capturedAt: thirdStart, categoryName: "专注工作", durationMinutes: 10, itemSummaryText: "实现热力图三"),
            ],
            blockSummaries: [],
            range: range,
            selectedCategories: ["专注工作"]
        )

        let event = try #require(events.first)

        #expect(events.count == 1)
        #expect(event.start == firstStart)
        #expect(event.end == calendar.date(byAdding: .minute, value: 30, to: firstStart)!)
        #expect(event.summaryText == nil)
        #expect(event.summaryStart == nil)
        #expect(event.summaryEnd == nil)
    }

    @Test func dailyWorkBlockPromptAndParserUseSingleSummaryPayload() async throws {
        let prompt = L10n.dailyWorkBlockSummaryPrompt(
            category: "专注工作",
            sourceSummaries: ["完成热力图分类筛选", "修复 hover 弹窗位置"],
            summaryInstruction: "保持具体",
            language: .simplifiedChinese
        )
        let parsed = DailyReportSummaryService.extractDailyWorkBlockResponse(
            from: """
            ```json
            {"summary":"完成热力图筛选与 hover 体验调整"}
            ```
            """
        )

        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("完成热力图分类筛选"))
        #expect(prompt.contains("修复 hover 弹窗位置"))
        #expect(prompt.contains("保持具体"))
        #expect(!prompt.contains("<index>"))
        #expect(!prompt.contains("09:"))
        #expect(!prompt.contains("分钟"))
        #expect(parsed == "完成热力图筛选与 hover 体验调整")
        #expect(DailyReportSummaryService.extractDailyWorkBlockResponse(from: #"{"summary":"   "}"#) == nil)
    }

    @MainActor
    @Test func affectedSummaryBackfillMergesOnlyBlocksWithAtLeastTwoSourceSummaries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let workAStart = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let workBStart = calendar.date(byAdding: .hour, value: 10, to: dayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let logStore = AppLogStore(database: database)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain, logStore: logStore)
        store.workContentSummaryProvider = .openAI
        store.workContentSummaryAPIBaseURL = "https://work-content.example.com"
        store.workContentSummaryModelName = "work-block-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(capturedAt: workAStart, categoryName: "专注工作", summaryText: "只有一条可用总结", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .minute, value: 10, to: workAStart)!, categoryName: "专注工作", summaryText: "   ", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .minute, value: 20, to: workAStart)!, categoryName: "会议沟通", summaryText: "同步工作块规则", durationMinutesSnapshot: 5)
        try database.insertAnalysisResult(capturedAt: workBStart, categoryName: "专注工作", summaryText: "实现日报热力图合并", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .minute, value: 10, to: workBStart)!, categoryName: "专注工作", summaryText: "修复日报 hover 闪烁", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .minute, value: 20, to: workBStart)!, categoryName: "会议沟通", summaryText: "最后一个未闭合块", durationMinutesSnapshot: 5)

        let promptRecorder = PromptRecorder()
        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            promptRecorder.append(try #require(messages.first?["content"] as? String))
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: """
                {
                  "choices": [
                    {
                      "message": {
                        "content": "{\\"summary\\":\\"合并后的工作块总结\\"}"
                      },
                      "finish_reason": "stop"
                    }
                  ]
                }
                """
            )
        }

        let service = DailyReportSummaryService(
            database: database,
            settingsStore: store,
            logStore: logStore,
            session: session
        )
        await service.summarizeAffectedSummaries(for: [dayStart])

        let summaries = try database.fetchDailyWorkBlockSummaries()
        let workASummary = summaries.first { $0.startAt == workAStart }
        let singleSourceMeetingSummary = summaries.first {
            $0.startAt == calendar.date(byAdding: .minute, value: 20, to: workAStart)!
        }
        let workBSummary = summaries.first { $0.startAt == workBStart }
        let prompts = promptRecorder.prompts
        let prompt = try #require(prompts.first)

        #expect(MockURLProtocol.requestCount == 1)
        #expect(prompts.count == 1)
        #expect(workASummary == nil)
        #expect(singleSourceMeetingSummary?.summaryText == "同步工作块规则")
        #expect(workBSummary?.summaryText == "合并后的工作块总结")
        #expect(prompt.contains("实现日报热力图合并"))
        #expect(prompt.contains("修复日报 hover 闪烁"))
        #expect(!prompt.contains("10:"))
        #expect(!prompt.contains("<index>"))
    }

    @MainActor
    @Test func backfillMissingSummariesCreatesDailyReportsAndWorkBlockSummaries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let workStart = calendar.date(byAdding: .hour, value: 9, to: dayOne)!
        let meetingStart = calendar.date(byAdding: .minute, value: 20, to: workStart)!
        let latestDayWorkStart = calendar.date(byAdding: .hour, value: 10, to: dayTwo)!

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
        store.workContentSummaryModelName = "backfill-model"

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(capturedAt: workStart, categoryName: "专注工作", summaryText: "实现补漏入口", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .minute, value: 10, to: workStart)!, categoryName: "专注工作", summaryText: "接入工作块补漏", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: meetingStart, categoryName: "会议沟通", summaryText: "同步补漏入口", durationMinutesSnapshot: 10)
        try database.insertAnalysisResult(capturedAt: latestDayWorkStart, categoryName: "专注工作", summaryText: "最新活动日不自动生成完整日报", durationMinutesSnapshot: 10)

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let prompt = try #require(messages.first?["content"] as? String)
            let content = if prompt.contains("dailySummary") {
                #"{"dailySummary":"补齐了遗漏的日报","categorySummaries":{"专注工作":"补齐了专注工作日报","会议沟通":"补齐了会议沟通日报"}}"#
            } else {
                #"{"summary":"合并后的工作块补漏总结"}"#
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
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: responseBody
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        await service.backfillMissingSummaries()

        let dayOneReport = try #require(try database.fetchDailyReport(for: dayOne))
        let dayTwoReport = try database.fetchDailyReport(for: dayTwo)
        let summaries = try database.fetchDailyWorkBlockSummaries()
        let workSummary = summaries.first { $0.startAt == workStart }
        let meetingSummary = summaries.first { $0.startAt == meetingStart }
        let latestDaySummary = summaries.first { $0.startAt == latestDayWorkStart }

        #expect(MockURLProtocol.requestCount == 2)
        #expect(dayOneReport.dailySummaryText == "补齐了遗漏的日报")
        #expect(dayOneReport.categorySummaries["专注工作"] == "补齐了专注工作日报")
        #expect(dayTwoReport == nil)
        #expect(workSummary?.summaryText == "合并后的工作块补漏总结")
        #expect(meetingSummary?.summaryText == "同步补漏入口")
        #expect(latestDaySummary == nil)
    }

    @Test func weeklyHeatmapOpacityNormalizesNonAbsenceTogetherAndAbsenceSeparately() async throws {
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let samples = [
            WeeklyHeatmapOpacitySample(category: "专注工作", dayStart: dayOne, durationSeconds: 3_600),
            WeeklyHeatmapOpacitySample(category: "会议沟通", dayStart: dayOne, durationSeconds: 3_600),
            WeeklyHeatmapOpacitySample(category: "专注工作", dayStart: dayTwo, durationSeconds: 1_800),
            WeeklyHeatmapOpacitySample(category: AppDefaults.absenceCategoryName, dayStart: dayOne, durationSeconds: 600),
            WeeklyHeatmapOpacitySample(category: AppDefaults.absenceCategoryName, dayStart: dayTwo, durationSeconds: 1_200),
        ]

        let dayOneWork = try #require(samples.first { $0.category == "专注工作" && $0.dayStart == dayOne })
        let dayTwoWork = try #require(samples.first { $0.category == "专注工作" && $0.dayStart == dayTwo })
        let dayOneAbsence = try #require(samples.first { $0.category == AppDefaults.absenceCategoryName && $0.dayStart == dayOne })
        let dayTwoAbsence = try #require(samples.first { $0.category == AppDefaults.absenceCategoryName && $0.dayStart == dayTwo })

        #expect(abs(WeeklyHeatmapOpacity.opacity(for: dayOneWork, among: samples) - 0.88) < 0.001)
        #expect(abs(WeeklyHeatmapOpacity.opacity(for: dayTwoWork, among: samples) - 0.355) < 0.001)
        #expect(abs(WeeklyHeatmapOpacity.opacity(for: dayOneAbsence, among: samples) - 0.53) < 0.001)
        #expect(abs(WeeklyHeatmapOpacity.opacity(for: dayTwoAbsence, among: samples) - 0.88) < 0.001)
    }

    @Test func heatmapSummaryTitleUsesFullCrossDayTimeSpanWithHyphen() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let startAt = calendar.date(byAdding: .minute, value: 23 * 60 + 50, to: dayStart)!
        let endAt = calendar.date(byAdding: .minute, value: 20, to: calendar.date(byAdding: .day, value: 1, to: dayStart)!)!
        let event = HeatmapEvent(
            id: "cross-day",
            category: "专注工作",
            start: startAt,
            end: calendar.date(byAdding: .day, value: 1, to: dayStart)!,
            durationMinutes: 10,
            summaryText: "跨天工作块总结",
            summaryStart: startAt,
            summaryEnd: endAt
        )

        let title = ReportHeatmapFormatting.title(
            for: event,
            in: DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart)!),
            language: .simplifiedChinese
        )

        #expect(title.contains("23:50-明天 00:20"))
        #expect(title.contains(" - 专注工作"))
        #expect(!title.contains("·"))
    }

    @MainActor
    @Test func reportsViewModelKeepsOtherAndAbsenceLastAndAllowsHeatmapCategoryToggle() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DeskBriefTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let summaryService = DailyReportSummaryService(database: database, settingsStore: store)

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayStart)!, categoryName: AppDefaults.preservedOtherCategoryName, summaryText: "大量其他活动", durationMinutesSnapshot: 300)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .hour, value: 14, to: dayStart)!, categoryName: AppDefaults.absenceCategoryName, summaryText: "离开", durationMinutesSnapshot: 200)
        try database.insertAnalysisResult(capturedAt: calendar.date(byAdding: .hour, value: 18, to: dayStart)!, categoryName: "专注工作", summaryText: "短时间工作", durationMinutesSnapshot: 10)

        let viewModel = ReportsViewModel(
            database: database,
            settingsStore: store,
            dailyReportSummaryService: summaryService
        )

        #expect(viewModel.chartItems.map(\.category) == ["专注工作", AppDefaults.preservedOtherCategoryName, AppDefaults.absenceCategoryName])
        #expect(Set(viewModel.heatmapCategories) == Set(viewModel.chartItems.map(\.category)))
        viewModel.toggleHeatmapCategory(AppDefaults.preservedOtherCategoryName)
        #expect(!viewModel.isHeatmapCategorySelected(AppDefaults.preservedOtherCategoryName))
        #expect(!viewModel.heatmapCategories.contains(AppDefaults.preservedOtherCategoryName))
        viewModel.toggleHeatmapCategory(AppDefaults.preservedOtherCategoryName)
        #expect(viewModel.isHeatmapCategorySelected(AppDefaults.preservedOtherCategoryName))
    }

    @MainActor
    @Test func reportsViewModelSkipsAllAwayDayRangesGeneratedBetweenActivity() async throws {
        let fixture = try makeReportsViewModelFixture(
            activityDates: [
                makeScreenshotDate(year: 2026, month: 4, day: 27, hour: 9, minute: 0),
                makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 9, minute: 0),
            ]
        )
        defer { fixture.cleanup() }

        let calendar = Calendar.reportCalendar
        let displayedDayStarts = Set(fixture.viewModel.allRanges.map { calendar.startOfDay(for: $0.interval.start) })

        #expect(displayedDayStarts.contains(calendar.startOfDay(for: makeScreenshotDate(year: 2026, month: 4, day: 27, hour: 0, minute: 0))))
        #expect(displayedDayStarts.contains(calendar.startOfDay(for: makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 0, minute: 0))))
        #expect(!displayedDayStarts.contains(calendar.startOfDay(for: makeScreenshotDate(year: 2026, month: 4, day: 28, hour: 0, minute: 0))))
        #expect(!displayedDayStarts.contains(calendar.startOfDay(for: makeScreenshotDate(year: 2026, month: 4, day: 29, hour: 0, minute: 0))))
    }

    @MainActor
    @Test func reportsViewModelSkipsAllAwayWeekRangesGeneratedBetweenActivity() async throws {
        let fixture = try makeReportsViewModelFixture(
            activityDates: [
                makeScreenshotDate(year: 2026, month: 4, day: 20, hour: 9, minute: 0),
                makeScreenshotDate(year: 2026, month: 5, day: 4, hour: 9, minute: 0),
            ],
            weekStart: .monday
        )
        defer { fixture.cleanup() }

        fixture.viewModel.selectedKind = .week

        let calendar = Calendar.reportCalendar(firstWeekday: ReportWeekStart.monday.calendarFirstWeekday)
        let displayedWeekStarts = Set(fixture.viewModel.allRanges.map { $0.interval.start })

        #expect(displayedWeekStarts.contains(makeScreenshotDate(year: 2026, month: 4, day: 20, hour: 9, minute: 0).startOfWeek(calendar: calendar)))
        #expect(displayedWeekStarts.contains(makeScreenshotDate(year: 2026, month: 5, day: 4, hour: 9, minute: 0).startOfWeek(calendar: calendar)))
        #expect(!displayedWeekStarts.contains(makeScreenshotDate(year: 2026, month: 4, day: 27, hour: 9, minute: 0).startOfWeek(calendar: calendar)))
    }

    @MainActor
    @Test func reportsViewModelSkipsAllAwayMonthRangesGeneratedBetweenActivity() async throws {
        let fixture = try makeReportsViewModelFixture(
            activityDates: [
                makeScreenshotDate(year: 2026, month: 3, day: 31, hour: 9, minute: 0),
                makeScreenshotDate(year: 2026, month: 5, day: 1, hour: 9, minute: 0),
            ]
        )
        defer { fixture.cleanup() }

        fixture.viewModel.selectedKind = .month

        let calendar = Calendar.reportCalendar
        let displayedMonthStarts = Set(fixture.viewModel.allRanges.map { $0.interval.start })

        #expect(displayedMonthStarts.contains(makeScreenshotDate(year: 2026, month: 3, day: 31, hour: 9, minute: 0).monthStart(calendar: calendar)))
        #expect(displayedMonthStarts.contains(makeScreenshotDate(year: 2026, month: 5, day: 1, hour: 9, minute: 0).monthStart(calendar: calendar)))
        #expect(!displayedMonthStarts.contains(makeScreenshotDate(year: 2026, month: 4, day: 15, hour: 9, minute: 0).monthStart(calendar: calendar)))
    }

    @MainActor
    @Test func reportsViewModelSkipsAllAwayYearRangesGeneratedBetweenActivity() async throws {
        let fixture = try makeReportsViewModelFixture(
            activityDates: [
                makeScreenshotDate(year: 2025, month: 12, day: 31, hour: 9, minute: 0),
                makeScreenshotDate(year: 2027, month: 1, day: 1, hour: 9, minute: 0),
            ]
        )
        defer { fixture.cleanup() }

        fixture.viewModel.selectedKind = .year

        let calendar = Calendar.reportCalendar
        let displayedYearStarts = Set(fixture.viewModel.allRanges.map { $0.interval.start })

        #expect(displayedYearStarts.contains(makeScreenshotDate(year: 2025, month: 12, day: 31, hour: 9, minute: 0).yearStart(calendar: calendar)))
        #expect(displayedYearStarts.contains(makeScreenshotDate(year: 2027, month: 1, day: 1, hour: 9, minute: 0).yearStart(calendar: calendar)))
        #expect(!displayedYearStarts.contains(makeScreenshotDate(year: 2026, month: 6, day: 1, hour: 9, minute: 0).yearStart(calendar: calendar)))
    }
}

@MainActor
private func makeReportsViewModelFixture(
    activityDates: [Date],
    weekStart: ReportWeekStart = .sunday
) throws -> ReportsViewModelFixture {
    let databaseURL = makeTemporaryDatabaseURL()
    let suiteName = "DeskBriefTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    let keychain = KeychainStore(service: suiteName)
    let database = try AppDatabase(databaseURL: databaseURL)
    let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
    store.reportWeekStart = weekStart
    let summaryService = DailyReportSummaryService(database: database, settingsStore: store)

    _ = try makeAnalysisRun(database: database)
    for date in activityDates {
        try database.insertAnalysisResult(
            capturedAt: date,
            categoryName: "专注工作",
            summaryText: "真实活动",
            durationMinutesSnapshot: 10
        )
    }

    let viewModel = ReportsViewModel(
        database: database,
        settingsStore: store,
        dailyReportSummaryService: summaryService
    )

    return ReportsViewModelFixture(viewModel: viewModel) {
        userDefaults.removePersistentDomain(forName: suiteName)
        keychain.set("", for: AppDefaults.apiKeyAccount)
        keychain.set("", for: AppDefaults.workContentSummaryAPIKeyAccount)
        try? FileManager.default.removeItem(at: databaseURL)
    }
}

private struct ReportsViewModelFixture {
    let viewModel: ReportsViewModel
    let cleanup: () -> Void
}
