import AppKit
import Foundation

@MainActor
final class AnalysisScheduler {
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let notificationSender: AppNotificationSending
    private var timer: Timer?
    private var realtimeAnalysisTimer: Timer?
    private var realtimeBacklogTimer: Timer?
    private var realtimeBacklogMonitor = RealtimeAnalysisBacklogMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var screenshotSavedObserver: NSObjectProtocol?

    var onTrigger: ((AnalysisTrigger) -> Void)?

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore,
        notificationSender: AppNotificationSending
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.notificationSender = notificationSender
    }

    deinit {
        timer?.invalidate()
        realtimeAnalysisTimer?.invalidate()
        realtimeBacklogTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let screenshotSavedObserver {
            NotificationCenter.default.removeObserver(screenshotSavedObserver)
        }
    }

    func start() {
        scheduleNextRun()
        configureRealtimeBacklogMonitoring()
        screenshotSavedObserver = NotificationCenter.default.addObserver(
            forName: .screenshotFileSaved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is URL else { return }
            Task { @MainActor [weak self] in
                self?.scheduleRealtimeAnalysisAfterCapture()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNextRun()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        realtimeAnalysisTimer?.invalidate()
        realtimeAnalysisTimer = nil
        stopRealtimeBacklogMonitoring()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screenshotSavedObserver {
            NotificationCenter.default.removeObserver(screenshotSavedObserver)
            self.screenshotSavedObserver = nil
        }
    }

    func reschedule() {
        scheduleNextRun()
        configureRealtimeBacklogMonitoring()
        if settingsStore.snapshot.analysisStartupMode != .realtime {
            realtimeAnalysisTimer?.invalidate()
            realtimeAnalysisTimer = nil
        }
    }

    private func scheduleNextRun() {
        timer?.invalidate()
        guard settingsStore.snapshot.analysisStartupMode == .scheduled else { return }
        let nextDate = settingsStore.snapshot.nextAnalysisDate(after: Date())
        timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onTrigger?(.scheduled)
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func scheduleRealtimeAnalysisAfterCapture() {
        guard settingsStore.snapshot.analysisStartupMode == .realtime else { return }
        realtimeAnalysisTimer?.invalidate()
        let fireDate = Date().addingTimeInterval(1)
        realtimeAnalysisTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onTrigger?(.realtime)
            }
        }
        if let realtimeAnalysisTimer {
            RunLoop.main.add(realtimeAnalysisTimer, forMode: .common)
        }
    }

    func checkRealtimeAnalysisBacklogNow() async {
        guard settingsStore.snapshot.analysisStartupMode == .realtime else {
            stopRealtimeBacklogMonitoring()
            return
        }
        guard let pendingCount = pendingScreenshotCountForRealtimeBacklogMonitor() else { return }
        guard let warning = realtimeBacklogMonitor.record(pendingScreenshotCount: pendingCount) else { return }
        let message = AppNotificationMessageBuilder.realtimeAnalysisBacklogWarning(
            warning: warning,
            language: settingsStore.appLanguage
        )
        await notificationSender.send(message)
    }

    private func configureRealtimeBacklogMonitoring() {
        if settingsStore.snapshot.analysisStartupMode == .realtime {
            startRealtimeBacklogMonitoringIfNeeded()
        } else {
            stopRealtimeBacklogMonitoring()
        }
    }

    private func startRealtimeBacklogMonitoringIfNeeded() {
        guard realtimeBacklogTimer == nil else { return }
        realtimeBacklogMonitor.reset(
            baselinePendingScreenshotCount: pendingScreenshotCountForRealtimeBacklogMonitor()
        )
        let t = Timer(
            timeInterval: AppDefaults.realtimeBacklogCheckIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkRealtimeAnalysisBacklogNow()
            }
        }
        realtimeBacklogTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopRealtimeBacklogMonitoring() {
        realtimeBacklogTimer?.invalidate()
        realtimeBacklogTimer = nil
        realtimeBacklogMonitor.reset()
    }

    private func pendingScreenshotCountForRealtimeBacklogMonitor() -> Int? {
        do {
            return try database.listScreenshotFiles(
                defaultDurationMinutes: settingsStore.snapshot.screenshotIntervalMinutes
            ).count
        } catch {
            logStore.addError(source: .analysis, context: "Failed to check realtime analysis backlog", error: error)
            return nil
        }
    }
}
