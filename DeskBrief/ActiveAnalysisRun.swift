import Foundation

enum AnalysisRunDailyReportStrategy: Equatable {
    // Manual and scheduled runs can consider every report day covered by this run.
    case boundedRunDays
    // Realtime runs only generate candidates after observed results cross a day boundary.
    case realtimeBoundary

    init(trigger: AnalysisTrigger) {
        switch trigger {
        case .manual, .scheduled:
            self = .boundedRunDays
        case .realtime:
            self = .realtimeBoundary
        }
    }
}

@MainActor
final class ActiveAnalysisRun {
    let id: Int64
    let settings: AppSettingsSnapshot
    let prompt: String
    var screenshots: [ScreenshotFileRecord]
    var screenshotPaths: Set<String>
    var currentIndex = 0
    var successCount = 0
    var failureCount = 0
    var completedCount = 0
    var consecutiveFailureCount = 0
    var measuredDurationTotal: TimeInterval = 0
    var measuredItemCount = 0
    var wasCancelled = false
    var wasPausedAfterFailures = false
    var didLogLMStudioCancellationObservation = false
    var isAcceptingAppends = true
    private(set) var dailyReportStrategy: AnalysisRunDailyReportStrategy
    private(set) var previousAnalysisResultDayStarts: Set<Date>
    private(set) var processedAnalysisDayStarts: Set<Date> = []

    init(
        id: Int64,
        settings: AppSettingsSnapshot,
        prompt: String,
        screenshots: [ScreenshotFileRecord],
        trigger: AnalysisTrigger,
        previousAnalysisResultDayStarts: Set<Date>
    ) {
        self.id = id
        self.settings = settings
        self.prompt = prompt
        self.screenshots = screenshots
        self.screenshotPaths = Set(screenshots.map { $0.url.path })
        self.dailyReportStrategy = AnalysisRunDailyReportStrategy(trigger: trigger)
        self.previousAnalysisResultDayStarts = previousAnalysisResultDayStarts
    }

    var startedAt: Date? {
        screenshots.first?.capturedAt
    }

    var totalCount: Int {
        screenshots.count
    }

    var hasRemainingScreenshots: Bool {
        currentIndex < screenshots.count
    }

    func nextScreenshot() -> ScreenshotFileRecord? {
        guard currentIndex < screenshots.count else {
            return nil
        }
        defer { currentIndex += 1 }
        return screenshots[currentIndex]
    }

    @discardableResult
    func appendMissingScreenshots(_ pendingScreenshots: [ScreenshotFileRecord]) -> Int {
        let newScreenshots = pendingScreenshots.filter { screenshotPaths.insert($0.url.path).inserted }
        guard !newScreenshots.isEmpty else {
            return 0
        }
        screenshots.append(contentsOf: newScreenshots)
        return newScreenshots.count
    }

    func updateDailyReportStrategyForMergedTrigger(_ trigger: AnalysisTrigger) {
        guard trigger != .realtime else {
            return
        }
        dailyReportStrategy = .boundedRunDays
    }

    func recordProcessedAnalysisResult(for screenshot: ScreenshotFileRecord, calendar: Calendar) {
        processedAnalysisDayStarts.formUnion(
            Self.dayStarts(from: screenshot.capturedAt, endAt: screenshot.endAt, calendar: calendar)
        )
    }

    func dailyReportCandidateDayStarts(calendar: Calendar) -> Set<Date> {
        switch dailyReportStrategy {
        case .boundedRunDays:
            return Self.continuousDayStarts(from: processedAnalysisDayStarts, calendar: calendar)
        case .realtimeBoundary:
            let comparedDayStarts = previousAnalysisResultDayStarts.union(processedAnalysisDayStarts)
            guard let latestDayStart = comparedDayStarts.max() else {
                return []
            }
            return Set(comparedDayStarts.filter { $0 < latestDayStart })
        }
    }

    nonisolated static func dayStarts(from start: Date, endAt end: Date, calendar: Calendar) -> Set<Date> {
        var dayStarts = Set<Date>()
        let lastInstant = end > start ? end.addingTimeInterval(-0.001) : start
        let firstDayStart = calendar.startOfDay(for: start)
        let lastDayStart = calendar.startOfDay(for: lastInstant)

        var currentDayStart = firstDayStart
        while currentDayStart <= lastDayStart {
            dayStarts.insert(currentDayStart)
            guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: currentDayStart) else {
                break
            }
            currentDayStart = nextDayStart
        }

        return dayStarts
    }

    private nonisolated static func continuousDayStarts(from dayStarts: Set<Date>, calendar: Calendar) -> Set<Date> {
        guard let firstDayStart = dayStarts.min(),
              let lastDayStart = dayStarts.max() else {
            return []
        }

        var result = Set<Date>()
        var currentDayStart = firstDayStart
        while currentDayStart <= lastDayStart {
            result.insert(currentDayStart)
            guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: currentDayStart) else {
                break
            }
            currentDayStart = nextDayStart
        }
        return result
    }
}
