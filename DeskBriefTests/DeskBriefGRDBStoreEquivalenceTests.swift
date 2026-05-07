import Foundation
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @Test func grdbStoresRunsResultsReportsRulesAndLogsWithExistingSemantics() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let firstRunID = try database.createAnalysisRun(
            modelName: "analysis-model-a",
            totalItems: 2,
            status: "queued"
        )
        let secondRunID = try database.createAnalysisRun(
            modelName: "analysis-model-b",
            totalItems: 3
        )

        try database.updateAnalysisRunTotalItems(id: firstRunID, totalItems: 4)
        try database.finishAnalysisRun(
            id: firstRunID,
            status: "finished",
            successCount: 3,
            failureCount: 1,
            inputMeanTokens: 10.5,
            inputMaxTokens: 20,
            outputMeanTokens: 4.5,
            outputMaxTokens: 9,
            averageItemDurationSeconds: 12.25,
            errorMessage: "one item failed"
        )

        let analysisRuns = try database.fetchAnalysisRuns()
        #expect(Array(analysisRuns.prefix(2).map(\.id)) == [secondRunID, firstRunID])
        let finishedRun = try #require(analysisRuns.first { $0.id == firstRunID })
        #expect(finishedRun.status == "finished")
        #expect(finishedRun.modelName == "analysis-model-a")
        #expect(finishedRun.totalItems == 4)
        #expect(finishedRun.successCount == 3)
        #expect(finishedRun.failureCount == 1)
        #expect(finishedRun.inputMeanTokens == 10.5)
        #expect(finishedRun.inputMaxTokens == 20)
        #expect(finishedRun.outputMeanTokens == 4.5)
        #expect(finishedRun.outputMaxTokens == 9)
        #expect(finishedRun.averageItemDurationSeconds == 12.25)
        #expect(finishedRun.errorMessage == "one item failed")
        #expect(finishedRun.totalTokensAvg == 15.0)
        #expect(finishedRun.totalTokensMax == 29)
        #expect(try database.fetchLatestAnalysisAverageDurationSeconds() == 12.25)

        let summaryRunID = try database.createSummaryRun(
            modelName: "summary-model",
            totalItems: 2,
            analysisRunID: firstRunID
        )
        try database.finishSummaryRun(
            id: summaryRunID,
            status: "failed",
            successCount: 1,
            failureCount: 1,
            inputMeanTokens: nil,
            inputMaxTokens: nil,
            outputMeanTokens: 8,
            outputMaxTokens: 16,
            averageItemDurationSeconds: nil,
            errorMessage: "summary error"
        )
        let summaryRun = try #require(try database.fetchSummaryRuns().first)
        #expect(summaryRun.id == summaryRunID)
        #expect(summaryRun.analysisRunID == firstRunID)
        #expect(summaryRun.status == "failed")
        #expect(summaryRun.inputMeanTokens == nil)
        #expect(summaryRun.outputMeanTokens == 8)
        #expect(summaryRun.totalTokensAvg == nil)
        #expect(summaryRun.errorMessage == "summary error")

        let firstCapture = Date(timeIntervalSince1970: 100)
        let secondCapture = Date(timeIntervalSince1970: 200)
        let firstInsert = try database.insertAnalysisResult(
            capturedAt: firstCapture,
            categoryName: "专注工作",
            summaryText: "实现 GRDB store",
            durationMinutesSnapshot: 15
        )
        let duplicateInsert = try database.insertAnalysisResult(
            capturedAt: firstCapture,
            categoryName: "重复分类",
            summaryText: "不应覆盖旧记录",
            durationMinutesSnapshot: 99
        )
        try database.insertAnalysisResult(
            capturedAt: secondCapture,
            categoryName: "会议沟通",
            summaryText: nil,
            durationMinutesSnapshot: 5
        )
        try database.insertAnalysisResult(
            capturedAt: Date(timeIntervalSince1970: 300),
            categoryName: nil,
            summaryText: "无分类记录不进入报表",
            durationMinutesSnapshot: 10
        )

        #expect(firstInsert == .inserted)
        #expect(duplicateInsert == .duplicate)
        let sourceItems = try database.fetchReportSourceItems()
        #expect(sourceItems.map(\.categoryName) == ["会议沟通", "专注工作"])
        #expect(sourceItems.map(\.durationMinutes) == [5, 15])
        let activityItems = try database.fetchReportActivityItems()
        #expect(activityItems.map(\.categoryName) == ["专注工作", "会议沟通"])
        #expect(activityItems.first?.itemSummaryText == "实现 GRDB store")
        #expect(activityItems.last?.itemSummaryText == nil)

        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "first report",
            categorySummaries: ["b": "B", "a": "A"]
        )
        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "updated report",
            categorySummaries: ["b": "Bee", "a": "Aye"],
            isTemporary: true
        )
        let report = try #require(try database.fetchDailyReport(for: dayStart))
        #expect(report.dailySummaryText == "updated report")
        #expect(report.categorySummaries == ["a": "Aye", "b": "Bee"])
        #expect(report.isTemporary)
        let rawCategoryJSON = try #require(try fetchOptionalString(
            "SELECT category_summaries_json FROM daily_reports LIMIT 1;",
            databaseURL: databaseURL
        ))
        #expect(rawCategoryJSON == #"{"a":"Aye","b":"Bee"}"#)

        let ruleAID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let ruleBID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        try database.replaceCategoryRules([
            CategoryRule(id: ruleAID, name: "专注工作", description: "写代码", colorHex: "123abc"),
            CategoryRule(id: ruleBID, name: "会议沟通", description: "同步事项", colorHex: "#abcdef"),
        ])
        let rules = try database.fetchCategoryRules()
        #expect(rules.map(\.id) == [ruleAID, ruleBID])
        #expect(rules.map(\.name) == ["专注工作", "会议沟通"])
        #expect(rules.map(\.colorHex) == ["#123ABC", "#ABCDEF"])

        let blockStart = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let blockEnd = calendar.date(byAdding: .minute, value: 90, to: blockStart)!
        try database.upsertDailyWorkBlockSummary(
            categoryName: "专注工作",
            startAt: blockStart,
            endAt: blockEnd,
            summaryText: "first block summary"
        )
        try database.upsertDailyWorkBlockSummary(
            categoryName: "深度工作",
            startAt: blockStart,
            endAt: blockEnd,
            summaryText: "updated block summary"
        )
        let blockSummaries = try database.fetchDailyWorkBlockSummaries()
        #expect(blockSummaries.count == 1)
        #expect(blockSummaries.first?.categoryName == "深度工作")
        #expect(blockSummaries.first?.summaryText == "updated block summary")
        #expect(blockSummaries.first?.durationMinutes == 90)
        let intersectingBlocks = try database.fetchDailyWorkBlockSummaries(
            intersecting: DateInterval(
                start: calendar.date(byAdding: .minute, value: 30, to: blockStart)!,
                end: calendar.date(byAdding: .minute, value: 100, to: blockStart)!
            )
        )
        #expect(intersectingBlocks.map(\.id) == blockSummaries.map(\.id))

        let validLogID = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        try database.insertAppLog(AppLogEntry(
            id: validLogID,
            createdAt: Date(timeIntervalSince1970: 50),
            level: .error,
            source: .summary,
            message: "Unicode 日志 ✅"
        ))
        try executeSQLite(
            """
            INSERT INTO app_logs (id, created_at, level, source, message) VALUES
            ('not-a-uuid', 1, 'log', 'app', 'bad id'),
            ('44444444-4444-4444-4444-444444444444', 2, 'invalid', 'app', 'bad level'),
            ('55555555-5555-5555-5555-555555555555', 3, 'log', 'invalid', 'bad source');
            """,
            databaseURL: databaseURL
        )
        let allLogs = try database.fetchAppLogs(limit: nil)
        #expect(allLogs.map(\.id) == [validLogID])
        #expect(allLogs.first?.message == "Unicode 日志 ✅")
        #expect(try database.fetchAppLogs(limit: 0).isEmpty)
        #expect(try database.fetchAppLogs(limit: -1).isEmpty)
        #expect(try database.fetchAppLogs(limit: 1).map(\.id) == [validLogID])
    }

    @Test func grdbDailyReportActivityQueryKeepsPreviousOverlapAndClipsDayEdges() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { removeTemporaryDatabaseFiles(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let calendar = makeTestCalendar()
        let previousDayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!
        let dayStart = calendar.date(byAdding: .day, value: 1, to: previousDayStart)!
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let previousOverlap = calendar.date(byAdding: .minute, value: -30, to: dayStart)!
        let morningWork = calendar.date(byAdding: .hour, value: 9, to: dayStart)!
        let lateWork = calendar.date(byAdding: .minute, value: 23 * 60 + 50, to: dayStart)!
        let nextDayWork = calendar.date(byAdding: .minute, value: 5, to: nextDayStart)!

        _ = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            capturedAt: previousOverlap,
            categoryName: "夜间工作",
            summaryText: "跨日工作",
            durationMinutesSnapshot: 60
        )
        try database.insertAnalysisResult(
            capturedAt: morningWork,
            categoryName: "专注工作",
            summaryText: "上午开发",
            durationMinutesSnapshot: 25
        )
        try database.insertAnalysisResult(
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayStart)!,
            categoryName: nil,
            summaryText: "无分类不进入日报",
            durationMinutesSnapshot: 15
        )
        try database.insertAnalysisResult(
            capturedAt: lateWork,
            categoryName: "收尾工作",
            summaryText: "当天收尾",
            durationMinutesSnapshot: 20
        )
        try database.insertAnalysisResult(
            capturedAt: nextDayWork,
            categoryName: "次日事项",
            summaryText: "不应进入当天日报",
            durationMinutesSnapshot: 15
        )

        let items = try database.fetchDailyReportActivityItems(for: dayStart, calendar: calendar)
        #expect(items.map(\.categoryName) == ["夜间工作", "专注工作", "收尾工作"])
        #expect(items.map(\.capturedAt) == [dayStart, morningWork, lateWork])
        #expect(items.map(\.durationMinutes) == [30, 25, 10])
        #expect(items.map(\.itemSummaryText) == ["跨日工作", "上午开发", "当天收尾"])

        let latestBeforeMorning = try #require(try database.fetchLatestReportActivityItem(before: morningWork))
        #expect(latestBeforeMorning.capturedAt == previousOverlap)
        #expect(latestBeforeMorning.categoryName == "夜间工作")

        try database.upsertDailyReport(
            dayStart: previousDayStart,
            dailySummaryText: "final previous report",
            categorySummaries: ["夜间工作": "done"]
        )
        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "temporary current report",
            categorySummaries: ["专注工作": "pending"],
            isTemporary: true
        )
        let pendingDayStarts = try database.fetchPendingDailyReportDayStarts(
            before: nextDayStart,
            calendar: calendar
        )
        #expect(pendingDayStarts == [dayStart])
    }
}
