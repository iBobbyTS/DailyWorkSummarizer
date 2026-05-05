import Foundation
import UserNotifications

nonisolated struct AppNotificationMessage: Equatable {
    let title: String
    let body: String
}

@MainActor
protocol AppNotificationSending: AnyObject {
    func send(_ message: AppNotificationMessage) async
}

@MainActor
final class NoOpAppNotificationService: AppNotificationSending {
    func send(_: AppNotificationMessage) async {}
}

@MainActor
final class SystemAppNotificationService: NSObject, AppNotificationSending, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private weak var logStore: AppLogStore?
    private var didRequestAuthorization = false

    init(
        center: UNUserNotificationCenter = .current(),
        logStore: AppLogStore?
    ) {
        self.center = center
        self.logStore = logStore
        super.init()
        center.delegate = self
    }

    func send(_ message: AppNotificationMessage) async {
        guard await ensureAuthorization() else {
            logStore?.add(
                level: .log,
                source: .app,
                message: "Notification authorization was not granted."
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "DeskBrief.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            logStore?.addError(source: .app, context: "Failed to send system notification", error: error)
        }
    }

    private func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !didRequestAuthorization else {
                return false
            }
            didRequestAuthorization = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logStore?.addError(source: .app, context: "Failed to request notification authorization", error: error)
                return false
            }
        @unknown default:
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

nonisolated struct AnalysisCompletionNotificationContext: Equatable {
    var trigger: AnalysisTrigger
    var successfulScreenshotCount: Int
    var failedScreenshotCount: Int

    var shouldNotifySuccessfulRunWithoutDailyReport: Bool {
        trigger == .manual
    }

    mutating func merge(_ other: AnalysisCompletionNotificationContext) {
        if other.trigger.priority > trigger.priority {
            trigger = other.trigger
        }
        successfulScreenshotCount += other.successfulScreenshotCount
        failedScreenshotCount += other.failedScreenshotCount
    }
}

nonisolated struct DailyReportSummaryNotificationIntent: Equatable {
    var shouldNotifyBackfillCompletion = false
    var analysisCompletionContext: AnalysisCompletionNotificationContext?

    static let none = DailyReportSummaryNotificationIntent()

    static var backfillCompletion: DailyReportSummaryNotificationIntent {
        DailyReportSummaryNotificationIntent(shouldNotifyBackfillCompletion: true)
    }

    static func analysisCompletion(
        _ context: AnalysisCompletionNotificationContext
    ) -> DailyReportSummaryNotificationIntent {
        DailyReportSummaryNotificationIntent(analysisCompletionContext: context)
    }

    var isEmpty: Bool {
        !shouldNotifyBackfillCompletion && analysisCompletionContext == nil
    }

    mutating func merge(_ other: DailyReportSummaryNotificationIntent) {
        shouldNotifyBackfillCompletion = shouldNotifyBackfillCompletion || other.shouldNotifyBackfillCompletion

        switch (analysisCompletionContext, other.analysisCompletionContext) {
        case (.none, .none):
            break
        case (.none, .some(let otherContext)):
            analysisCompletionContext = otherContext
        case (.some, .none):
            break
        case (.some(var context), .some(let otherContext)):
            context.merge(otherContext)
            analysisCompletionContext = context
        }
    }
}

nonisolated struct RealtimeAnalysisBacklogWarning: Equatable {
    let previousPendingScreenshotCount: Int
    let pendingScreenshotCount: Int

    var increase: Int {
        pendingScreenshotCount - previousPendingScreenshotCount
    }
}

nonisolated struct RealtimeAnalysisBacklogMonitor: Equatable {
    let warningIncreaseThreshold: Int
    private(set) var previousPendingScreenshotCount: Int?

    init(
        warningIncreaseThreshold: Int = AppDefaults.realtimeBacklogWarningIncreaseThreshold,
        previousPendingScreenshotCount: Int? = nil
    ) {
        self.warningIncreaseThreshold = warningIncreaseThreshold
        self.previousPendingScreenshotCount = previousPendingScreenshotCount
    }

    mutating func reset(baselinePendingScreenshotCount: Int? = nil) {
        previousPendingScreenshotCount = baselinePendingScreenshotCount
    }

    mutating func record(pendingScreenshotCount: Int) -> RealtimeAnalysisBacklogWarning? {
        defer {
            previousPendingScreenshotCount = pendingScreenshotCount
        }

        guard let previousPendingScreenshotCount else {
            return nil
        }

        let increase = pendingScreenshotCount - previousPendingScreenshotCount
        guard increase >= warningIncreaseThreshold else {
            return nil
        }

        return RealtimeAnalysisBacklogWarning(
            previousPendingScreenshotCount: previousPendingScreenshotCount,
            pendingScreenshotCount: pendingScreenshotCount
        )
    }
}

nonisolated enum AppNotificationMessageBuilder {
    static func realtimeAnalysisBacklogWarning(
        warning: RealtimeAnalysisBacklogWarning,
        language: AppLanguage
    ) -> AppNotificationMessage {
        AppNotificationMessage(
            title: L10n.string(.notificationRealtimeBacklogTitle, language: language),
            body: L10n.string(
                .notificationRealtimeBacklogBody,
                language: language,
                arguments: [
                    L10n.notificationScreenshotCount(warning.pendingScreenshotCount, language: language),
                    L10n.notificationScreenshotCount(warning.increase, language: language),
                ]
            )
        )
    }

    static func analysisCompletion(
        context: AnalysisCompletionNotificationContext,
        dailyReportDayStarts: [Date],
        summaryFailed: Bool = false,
        language: AppLanguage
    ) -> AppNotificationMessage? {
        let successCount = context.successfulScreenshotCount
        let failureCount = context.failedScreenshotCount
        let sortedDayStarts = dailyReportDayStarts.sorted()

        if successCount == 0, failureCount == 0, sortedDayStarts.isEmpty, !summaryFailed {
            return nil
        }

        if successCount == 0, failureCount > 0, sortedDayStarts.isEmpty {
            return AppNotificationMessage(
                title: L10n.string(.notificationAnalysisFailedTitle, language: language),
                body: L10n.string(
                    .notificationAnalysisFailedBody,
                    language: language,
                    arguments: [L10n.notificationScreenshotCount(failureCount, language: language)]
                )
            )
        }

        if !context.shouldNotifySuccessfulRunWithoutDailyReport,
           failureCount == 0,
           sortedDayStarts.isEmpty,
           !summaryFailed {
            return nil
        }

        let analyzedText = L10n.notificationScreenshotCount(successCount, language: language)
        let failedText = L10n.notificationScreenshotCount(failureCount, language: language)
        let dailyReportText = dailyReportDescription(for: sortedDayStarts, language: language)
        let hasScreenshotFailures = failureCount > 0

        let bodyKey: L10n.Key
        let arguments: [CVarArg]
        switch (dailyReportText, hasScreenshotFailures, summaryFailed) {
        case (.none, false, false):
            bodyKey = .notificationAnalysisCompleteNoReports
            arguments = [analyzedText]
        case (.some(let dailyReportText), false, false):
            bodyKey = .notificationAnalysisCompleteWithReports
            arguments = [analyzedText, dailyReportText]
        case (.none, true, _):
            bodyKey = .notificationAnalysisPartialNoReports
            arguments = [analyzedText, failedText]
        case (.some(let dailyReportText), true, _):
            bodyKey = .notificationAnalysisPartialWithReports
            arguments = [analyzedText, failedText, dailyReportText]
        case (.none, false, true):
            bodyKey = .notificationAnalysisSummaryFailedNoReports
            arguments = [analyzedText]
        case (.some(let dailyReportText), false, true):
            bodyKey = .notificationAnalysisSummaryFailedWithReports
            arguments = [analyzedText, dailyReportText]
        }

        return AppNotificationMessage(
            title: L10n.string(.notificationAnalysisCompleteTitle, language: language),
            body: L10n.string(bodyKey, language: language, arguments: arguments)
        )
    }

    static func backfillCompletion(
        workBlockSummariesCreatedCount: Int,
        dailyReportCount: Int,
        hasFailures: Bool,
        didFailCompletely: Bool,
        language: AppLanguage
    ) -> AppNotificationMessage {
        if didFailCompletely {
            return AppNotificationMessage(
                title: L10n.string(.notificationBackfillFailedTitle, language: language),
                body: L10n.string(.notificationBackfillFailedBody, language: language)
            )
        }

        let bodyKey: L10n.Key = hasFailures
            ? .notificationBackfillPartialBody
            : .notificationBackfillCompleteBody
        return AppNotificationMessage(
            title: L10n.string(.notificationBackfillCompleteTitle, language: language),
            body: L10n.string(
                bodyKey,
                language: language,
                arguments: [
                    L10n.notificationWorkBlockSummaryCount(workBlockSummariesCreatedCount, language: language),
                    L10n.notificationDailyReportCount(dailyReportCount, language: language),
                ]
            )
        )
    }

    static func modelMemoryInsufficient(
        runTypeName: String,
        thresholdGB: Double,
        availableGB: Double,
        language: AppLanguage
    ) -> AppNotificationMessage {
        AppNotificationMessage(
            title: L10n.string(.notificationMemoryInsufficientTitle, language: language),
            body: L10n.string(
                .notificationMemoryInsufficientBody,
                language: language,
                arguments: [
                    runTypeName,
                    String(format: "%.1f", availableGB),
                    String(format: "%.0f", thresholdGB),
                ]
            )
        )
    }

    private static func dailyReportDescription(
        for dayStarts: [Date],
        language: AppLanguage
    ) -> String? {
        switch dayStarts.count {
        case 0:
            return nil
        case 1:
            return L10n.string(
                .notificationDailyReportForDay,
                language: language,
                arguments: [L10n.reportDayDisplayText(for: dayStarts[0], language: language)]
            )
        default:
            return L10n.notificationDailyReportCount(dayStarts.count, language: language)
        }
    }
}
