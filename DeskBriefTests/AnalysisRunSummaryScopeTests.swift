import Foundation
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @Test func realtimeAnalysisRunSummarizesPreviousDayOnlyAfterCrossingDayBoundary() {
        let calendar = makeTestCalendar()
        let previousDayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27))!
        let currentDayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 30))!
        let currentScreenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260430-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: currentDayStart)!,
            durationMinutes: 10
        )
        let run = ActiveAnalysisRun(
            id: 1,
            settings: makeTestSettingsSnapshot(),
            prompt: "prompt",
            screenshots: [currentScreenshot],
            trigger: .realtime,
            previousAnalysisResultDayStarts: [previousDayStart]
        )

        run.recordProcessedAnalysisResult(for: currentScreenshot, calendar: calendar)

        #expect(run.dailyReportCandidateDayStarts(calendar: calendar) == Set([previousDayStart]))
    }

    @Test func realtimeAnalysisRunDoesNotSummarizeWhenPreviousAndProcessedResultsAreSameDay() {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27))!
        let screenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260427-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayStart)!,
            durationMinutes: 10
        )
        let run = ActiveAnalysisRun(
            id: 1,
            settings: makeTestSettingsSnapshot(),
            prompt: "prompt",
            screenshots: [screenshot],
            trigger: .realtime,
            previousAnalysisResultDayStarts: [dayStart]
        )

        run.recordProcessedAnalysisResult(for: screenshot, calendar: calendar)

        #expect(run.dailyReportCandidateDayStarts(calendar: calendar).isEmpty)
    }

    @Test func manualAnalysisRunUsesContinuousProcessedDayRangeForDailyReportCandidates() {
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let dayThree = calendar.date(byAdding: .day, value: 1, to: dayTwo)!
        let dayFour = calendar.date(byAdding: .day, value: 1, to: dayThree)!
        let firstScreenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260427-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayOne)!,
            durationMinutes: 10
        )
        let secondScreenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260430-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayFour)!,
            durationMinutes: 10
        )
        let run = ActiveAnalysisRun(
            id: 1,
            settings: makeTestSettingsSnapshot(),
            prompt: "prompt",
            screenshots: [firstScreenshot, secondScreenshot],
            trigger: .manual,
            previousAnalysisResultDayStarts: []
        )

        run.recordProcessedAnalysisResult(for: firstScreenshot, calendar: calendar)
        run.recordProcessedAnalysisResult(for: secondScreenshot, calendar: calendar)

        #expect(run.dailyReportCandidateDayStarts(calendar: calendar) == Set([dayOne, dayTwo, dayThree, dayFour]))
    }

    @Test func realtimeAnalysisRunUpgradesToBoundedRangeWhenManualTriggerMerges() {
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let dayThree = calendar.date(byAdding: .day, value: 1, to: dayTwo)!
        let firstScreenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260427-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayOne)!,
            durationMinutes: 10
        )
        let secondScreenshot = ScreenshotFileRecord(
            url: URL(fileURLWithPath: "/tmp/20260429-1000-i10.jpg"),
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayThree)!,
            durationMinutes: 10
        )
        let run = ActiveAnalysisRun(
            id: 1,
            settings: makeTestSettingsSnapshot(),
            prompt: "prompt",
            screenshots: [firstScreenshot, secondScreenshot],
            trigger: .realtime,
            previousAnalysisResultDayStarts: []
        )

        run.recordProcessedAnalysisResult(for: firstScreenshot, calendar: calendar)
        run.recordProcessedAnalysisResult(for: secondScreenshot, calendar: calendar)
        run.updateDailyReportStrategyForMergedTrigger(.manual)

        #expect(run.dailyReportStrategy == .boundedRunDays)
        #expect(run.dailyReportCandidateDayStarts(calendar: calendar) == Set([dayOne, dayTwo, dayThree]))
    }
}
