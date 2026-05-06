import Foundation

struct AutomaticScreenshotCleanupResult: Sendable, Equatable {
    let deletedCount: Int
    let failures: [String]
}

@MainActor
protocol AutomaticScreenshotCleanupScheduledTimer: AnyObject {
    func invalidate()
}

@MainActor
protocol AutomaticScreenshotCleanupScheduling: AnyObject {
    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> AutomaticScreenshotCleanupScheduledTimer
}

extension Timer: AutomaticScreenshotCleanupScheduledTimer {}

@MainActor
private final class RunLoopAutomaticScreenshotCleanupScheduler: AutomaticScreenshotCleanupScheduling {
    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> AutomaticScreenshotCleanupScheduledTimer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

@MainActor
final class AutomaticScreenshotCleanupTimer {
    typealias CleanupOperation = @Sendable (
        _ fileURLs: [URL]
    ) throws -> AutomaticScreenshotCleanupResult

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let scheduler: AutomaticScreenshotCleanupScheduling
    private let nowProvider: @Sendable () -> Date
    private let cleanupOperation: CleanupOperation
    private var timer: AutomaticScreenshotCleanupScheduledTimer?
    private var backgroundServicesEnabled: Bool
    private var isCleaningUp = false

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore,
        backgroundServicesEnabled: Bool = true,
        scheduler: AutomaticScreenshotCleanupScheduling? = nil,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cleanupOperation: @escaping CleanupOperation = AutomaticScreenshotCleanupTimer.deleteFiles
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.backgroundServicesEnabled = backgroundServicesEnabled
        self.scheduler = scheduler ?? RunLoopAutomaticScreenshotCleanupScheduler()
        self.nowProvider = nowProvider
        self.cleanupOperation = cleanupOperation
    }

    var isScheduledForTesting: Bool {
        timer != nil
    }

    var isCleaningUpForTesting: Bool {
        isCleaningUp
    }

    func start() {
        guard Self.shouldSchedule(
            backgroundServicesEnabled: backgroundServicesEnabled,
            retention: settingsStore.screenshotAutoDeletionRetention
        ) else {
            stop()
            return
        }
        guard timer == nil else { return }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reschedule() {
        stop()
        start()
    }

    func setBackgroundServicesEnabled(_ isEnabled: Bool) {
        guard backgroundServicesEnabled != isEnabled else { return }
        backgroundServicesEnabled = isEnabled
        if isEnabled {
            reschedule()
        } else {
            stop()
        }
    }

    func performCleanupForTesting(now: Date) async {
        await performCleanupIfNeeded(now: now)
    }

    nonisolated static func shouldSchedule(
        backgroundServicesEnabled: Bool,
        retention: ScreenshotAutoDeletionRetention
    ) -> Bool {
        backgroundServicesEnabled && retention.retentionDays != nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = scheduler.scheduleRepeatingTimer(
            interval: AppDefaults.screenshotAutoDeletionCheckIntervalSeconds
        ) { [weak self] in
            self?.timerFired()
        }
    }

    private func timerFired() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCleanupIfNeeded(now: self.nowProvider())
        }
    }

    private func performCleanupIfNeeded(now: Date) async {
        guard !isCleaningUp else { return }
        guard backgroundServicesEnabled else {
            stop()
            return
        }
        guard let retentionDays = settingsStore.screenshotAutoDeletionRetention.retentionDays else {
            stop()
            return
        }

        isCleaningUp = true
        defer { isCleaningUp = false }

        let defaultDuration = settingsStore.screenshotIntervalMinutes
        let cleanupOperation = cleanupOperation

        do {
            let screenshots = try database.listScreenshotFiles(defaultDurationMinutes: defaultDuration)
            let filesToDelete = Self.filesEligibleForDeletion(
                screenshots: screenshots,
                retentionDays: retentionDays,
                now: now
            )
            guard !filesToDelete.isEmpty else { return }

            let result = try await Task.detached(priority: .utility) {
                try cleanupOperation(filesToDelete)
            }.value

            if !result.failures.isEmpty {
                logStore.add(
                    level: .error,
                    source: .screenshot,
                    message: "Failed to delete some screenshots during automatic cleanup: \(result.failures.joined(separator: "; "))"
                )
            }

            if result.deletedCount > 0 {
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            }
        } catch {
            logStore.addError(source: .screenshot, context: "Automatic screenshot cleanup failed", error: error)
        }
    }

    nonisolated static func filesEligibleForDeletion(
        screenshots: [ScreenshotFileRecord],
        retentionDays: Int,
        now: Date
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        return screenshots
            .filter { $0.capturedAt < cutoff }
            .map(\.url)
    }

    nonisolated static func deleteFiles(_ filesToDelete: [URL]) throws -> AutomaticScreenshotCleanupResult {
        var deletedCount = 0
        var failures: [String] = []
        for fileURL in filesToDelete {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            do {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            } catch {
                failures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return AutomaticScreenshotCleanupResult(deletedCount: deletedCount, failures: failures)
    }
}
