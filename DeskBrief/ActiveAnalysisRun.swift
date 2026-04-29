import Foundation

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

    init(id: Int64, settings: AppSettingsSnapshot, prompt: String, screenshots: [ScreenshotFileRecord]) {
        self.id = id
        self.settings = settings
        self.prompt = prompt
        self.screenshots = screenshots
        self.screenshotPaths = Set(screenshots.map { $0.url.path })
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
}
