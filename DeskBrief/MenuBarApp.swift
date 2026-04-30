import AppKit
import SwiftUI

@main
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var reportsWindow: NSWindow?
    private var logsWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?
    private var databaseObserver: NSObjectProtocol?
    private var screenshotObserver: NSObjectProtocol?
    private var analysisObserver: NSObjectProtocol?
    private var logsObserver: NSObjectProtocol?
    private var didLogStatusMenuPendingScreenshotsFailure = false
    private var didLogStatusMenuAverageDurationFailure = false

    private var database: AppDatabase?
    private var settingsStore: SettingsStore?
    private var screenshotService: ScreenshotService?
    private var analysisService: AnalysisService?
    private var dailyReportSummaryService: DailyReportSummaryService?
    private var reportsViewModel: ReportsViewModel?
    private var logStore: AppLogStore?
    private let statusSummaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusAverageDurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openScreenshotsItem = NSMenuItem(title: "", action: #selector(openScreenshotsFolder), keyEquivalent: "")
    private let viewLogsItem = NSMenuItem(title: "", action: #selector(openLogs), keyEquivalent: "")
    private let analysisStartupModeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var analysisStartupModeItems: [AnalysisStartupMode: NSMenuItem] = [:]
    private let analyzeNowItem = NSMenuItem(title: "", action: #selector(runAnalysisNow), keyEquivalent: "")
    private let currentStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
    private let reportsMenuItem = NSMenuItem(title: "", action: #selector(openReports), keyEquivalent: "r")
    private let clearEarlyScreenshotsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let clearEarlyScreenshotsSubmenu = NSMenu()
    private let clearOneDayScreenshotsItem = NSMenuItem(title: "", action: #selector(clearEarlyScreenshots(_:)), keyEquivalent: "")
    private let clearOneWeekScreenshotsItem = NSMenuItem(title: "", action: #selector(clearEarlyScreenshots(_:)), keyEquivalent: "")
    private let earlyScreenshotCleanupCoordinator = EarlyScreenshotCleanupCoordinator()
    private var earlyScreenshotCleanupItems: [EarlyScreenshotCleanupScope: NSMenuItem] = [:]
    private var earlyScreenshotCleanupWaitTask: Task<Void, Never>?
    private let quitMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherRunningInstances()

        do {
            let database = try AppDatabase()
            let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "DeskBrief")
            let logStore = AppLogStore(database: database)
            let settingsStore = SettingsStore(database: database, keychain: keychain, logStore: logStore)

            self.database = database
            self.settingsStore = settingsStore
            self.logStore = logStore
            self.screenshotService = ScreenshotService(database: database, settingsStore: settingsStore, logStore: logStore)
            let dailyReportSummaryService = DailyReportSummaryService(
                database: database,
                settingsStore: settingsStore,
                logStore: logStore
            )
            self.dailyReportSummaryService = dailyReportSummaryService
            self.analysisService = AnalysisService(
                database: database,
                settingsStore: settingsStore,
                logStore: logStore,
                dailyReportSummaryService: dailyReportSummaryService
            )
            self.reportsViewModel = ReportsViewModel(
                database: database,
                settingsStore: settingsStore,
                dailyReportSummaryService: dailyReportSummaryService,
                logStore: logStore
            )
        } catch {
            presentFatalAlert(message: text(.alertDatabaseInitFailed, language: .current), detail: error.localizedDescription)
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        registerObservers()
        screenshotService?.start()
        analysisService?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let databaseObserver {
            NotificationCenter.default.removeObserver(databaseObserver)
        }
        if let screenshotObserver {
            NotificationCenter.default.removeObserver(screenshotObserver)
        }
        if let analysisObserver {
            NotificationCenter.default.removeObserver(analysisObserver)
        }
        if let logsObserver {
            NotificationCenter.default.removeObserver(logsObserver)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow {
            settingsWindow = nil
        } else if window == reportsWindow {
            reportsWindow = nil
        } else if window == logsWindow {
            logsWindow = nil
        }
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: text(.statusAccessibilityDescription, language: .current))
        }
        statusItem.menu = menu
        self.statusItem = statusItem
        refreshLocalizedUI()
        refreshStatusMenu()
    }

    private func registerObservers() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenshotService?.reschedule()
                self?.analysisService?.reschedule()
                self?.refreshLocalizedUI()
                self?.refreshStatusMenu()
            }
        }

        databaseObserver = NotificationCenter.default.addObserver(
            forName: .appDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusMenu()
            }
        }

        screenshotObserver = NotificationCenter.default.addObserver(
            forName: .screenshotFilesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusMenu()
            }
        }

        analysisObserver = NotificationCenter.default.addObserver(
            forName: .analysisStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusMenu()
            }
        }

        logsObserver = NotificationCenter.default.addObserver(
            forName: .appLogsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatusMenu()
            }
        }
    }

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self

        statusSummaryItem.isEnabled = false
        statusAverageDurationItem.isEnabled = false
        statusAverageDurationItem.isHidden = true
        openScreenshotsItem.target = self
        viewLogsItem.target = self
        viewLogsItem.isEnabled = true
        analyzeNowItem.target = self
        clearOneDayScreenshotsItem.target = self
        clearOneDayScreenshotsItem.representedObject = EarlyScreenshotCleanupScope.oneDay.rawValue
        clearOneWeekScreenshotsItem.target = self
        clearOneWeekScreenshotsItem.representedObject = EarlyScreenshotCleanupScope.oneWeek.rawValue
        earlyScreenshotCleanupItems[.oneDay] = clearOneDayScreenshotsItem
        earlyScreenshotCleanupItems[.oneWeek] = clearOneWeekScreenshotsItem

        clearEarlyScreenshotsSubmenu.delegate = self
        clearEarlyScreenshotsSubmenu.addItem(clearOneDayScreenshotsItem)
        clearEarlyScreenshotsSubmenu.addItem(clearOneWeekScreenshotsItem)
        applyEarlyScreenshotCleanupStatus(.calculating)

        let analysisStartupModeSubmenu = NSMenu()
        for mode in AnalysisStartupMode.allCases {
            let item = NSMenuItem(title: "", action: #selector(selectAnalysisStartupMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            analysisStartupModeSubmenu.addItem(item)
            analysisStartupModeItems[mode] = item
        }

        let statusSubmenu = NSMenu()
        statusSubmenu.addItem(statusSummaryItem)
        statusSubmenu.addItem(statusAverageDurationItem)
        statusSubmenu.addItem(.separator())
        statusSubmenu.addItem(openScreenshotsItem)
        statusSubmenu.addItem(analyzeNowItem)

        menu.addItem(currentStatusMenuItem)
        menu.setSubmenu(statusSubmenu, for: currentStatusMenuItem)
        menu.addItem(reportsMenuItem)
        menu.addItem(clearEarlyScreenshotsMenuItem)
        menu.setSubmenu(clearEarlyScreenshotsSubmenu, for: clearEarlyScreenshotsMenuItem)
        menu.addItem(.separator())
        menu.addItem(settingsMenuItem)
        menu.addItem(analysisStartupModeMenuItem)
        menu.setSubmenu(analysisStartupModeSubmenu, for: analysisStartupModeMenuItem)
        menu.addItem(viewLogsItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
        menu.items.forEach { $0.target = self }
        return menu
    }()

    var statusMenuForTesting: NSMenu {
        menu
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        let openedMenuID = ObjectIdentifier(menu)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if openedMenuID == ObjectIdentifier(self.clearEarlyScreenshotsSubmenu) {
                self.openEarlyScreenshotCleanupSubmenu()
            } else {
                self.refreshStatusMenu()
            }
        }
    }

    @objc private func openSettings() {
        guard let settingsStore, let screenshotService, let analysisService, let logStore else { return }
        if let window = settingsWindow {
            activateAndShow(window)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView(
                settingsStore: settingsStore,
                screenshotService: screenshotService,
                analysisService: analysisService,
                logStore: logStore
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.delegate = self
        window.title = text(.windowSettings, language: settingsStore.appLanguage)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.center()
        settingsWindow = window
        activateAndShow(window)
    }

    @objc private func openReports() {
        guard let reportsViewModel else { return }
        reportsViewModel.reload()

        if let window = reportsWindow {
            activateAndShow(window)
            return
        }

        let controller = NSHostingController(rootView: ReportsView(viewModel: reportsViewModel))
        let window = NSWindow(contentViewController: controller)
        window.delegate = self
        window.title = text(.windowReports, language: settingsStore?.appLanguage ?? .current)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.center()
        reportsWindow = window
        activateAndShow(window)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openScreenshotsFolder() {
        screenshotService?.openScreenshotsFolder()
    }

    @objc private func openLogs() {
        guard let logStore, let settingsStore else { return }
        if let window = logsWindow {
            activateAndShow(window)
            return
        }

        let controller = NSHostingController(rootView: AppLogsView(logStore: logStore, settingsStore: settingsStore))
        let window = NSWindow(contentViewController: controller)
        window.delegate = self
        window.title = text(.windowLogs, language: settingsStore.appLanguage)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 500))
        window.center()
        logsWindow = window
        activateAndShow(window)
    }

    @objc private func selectAnalysisStartupMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AnalysisStartupMode(rawValue: rawValue) else {
            return
        }
        settingsStore?.analysisStartupMode = mode
    }

    @objc private func runAnalysisNow() {
        guard let analysisService else { return }
        if analysisService.currentState.isRunning {
            analysisService.cancelCurrentRun()
        } else {
            analysisService.runNow()
        }
    }

    @objc private func clearEarlyScreenshots(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let scope = EarlyScreenshotCleanupScope(rawValue: rawValue) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let fileURLs = await self.earlyScreenshotCleanupCoordinator.cachedFiles(for: scope),
                  !fileURLs.isEmpty else {
                self.applyEarlyScreenshotCleanupStatus(.calculating)
                self.openEarlyScreenshotCleanupSubmenu()
                return
            }

            guard self.confirmEarlyScreenshotCleanup(scope: scope, count: fileURLs.count) else {
                return
            }
            self.deleteEarlyScreenshots(fileURLs)
        }
    }

    private func activateAndShow(_ window: NSWindow) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func openEarlyScreenshotCleanupSubmenu() {
        guard let database else {
            applyEarlyScreenshotCleanupStatus(.failed("database unavailable"))
            return
        }

        let defaultDuration = settingsStore?.screenshotIntervalMinutes ?? AppDefaults.screenshotIntervalMinutes
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.earlyScreenshotCleanupCoordinator.beginCalculationIfNeeded(
                database: database,
                defaultDurationMinutes: defaultDuration
            )
            self.applyEarlyScreenshotCleanupStatus(status)

            guard case .calculating = status else {
                return
            }
            guard self.earlyScreenshotCleanupWaitTask == nil else {
                return
            }

            self.earlyScreenshotCleanupWaitTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let finalStatus = await self.earlyScreenshotCleanupCoordinator.waitForCalculation()
                self.earlyScreenshotCleanupWaitTask = nil
                if case let .failed(message) = finalStatus {
                    self.logStore?.add(
                        level: .error,
                        source: .screenshot,
                        message: "Failed to calculate early screenshot cleanup counts: \(message)"
                    )
                }
                self.applyEarlyScreenshotCleanupStatus(finalStatus)
            }
        }
    }

    private func applyEarlyScreenshotCleanupStatus(_ status: EarlyScreenshotCleanupStatus) {
        let language = settingsStore?.appLanguage ?? .current
        for scope in EarlyScreenshotCleanupScope.allCases {
            guard let item = earlyScreenshotCleanupItems[scope] else { continue }
            let state = EarlyScreenshotCleanupCoordinator.menuItemState(for: status, scope: scope)
            let presentation = EarlyScreenshotCleanupCoordinator.presentation(
                scope: scope,
                state: state,
                language: language
            )
            item.title = presentation.title
            item.isEnabled = presentation.isEnabled
        }
    }

    private func confirmEarlyScreenshotCleanup(scope: EarlyScreenshotCleanupScope, count: Int) -> Bool {
        let language = settingsStore?.appLanguage ?? .current
        let scopeTitle = EarlyScreenshotCleanupCoordinator.title(for: scope, language: language)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text(.menuClearEarlyScreenshotsConfirmTitle, language: language)
        alert.informativeText = text(
            .menuClearEarlyScreenshotsConfirmMessage,
            arguments: [scopeTitle, count],
            language: language
        )
        alert.addButton(withTitle: text(.commonConfirm, language: language))
        alert.addButton(withTitle: text(.commonCancel, language: language))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func deleteEarlyScreenshots(_ fileURLs: [URL]) {
        let coordinator = earlyScreenshotCleanupCoordinator
        Task { [weak self] in
            do {
                _ = try await Task.detached(priority: .utility) {
                    try EarlyScreenshotCleanupCoordinator.deleteFiles(fileURLs)
                }.value
            } catch {
                await MainActor.run { [weak self] in
                    self?.logStore?.add(
                        level: .error,
                        source: .screenshot,
                        message: "Failed to delete early screenshots: \(EarlyScreenshotCleanupCoordinator.describe(error))"
                    )
                }
            }

            await coordinator.invalidateCache()
            await MainActor.run { [weak self] in
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
                self?.applyEarlyScreenshotCleanupStatus(.calculating)
            }
        }
    }

    private func refreshStatusMenu() {
        guard let database else { return }

        let defaultDuration = settingsStore?.screenshotIntervalMinutes ?? AppDefaults.screenshotIntervalMinutes
        let pendingScreenshots: [ScreenshotFileRecord]
        do {
            pendingScreenshots = try database.listScreenshotFiles(defaultDurationMinutes: defaultDuration)
            didLogStatusMenuPendingScreenshotsFailure = false
        } catch {
            pendingScreenshots = []
            if !didLogStatusMenuPendingScreenshotsFailure {
                logStore?.addError(source: .app, context: "Failed to refresh pending screenshot count", error: error)
                didLogStatusMenuPendingScreenshotsFailure = true
            }
        }
        let analysisState = analysisService?.currentState ?? .idle
        let lastAverageDuration: Double?
        do {
            lastAverageDuration = try database.fetchLatestAnalysisAverageDurationSeconds()
            didLogStatusMenuAverageDurationFailure = false
        } catch {
            lastAverageDuration = nil
            if !didLogStatusMenuAverageDurationFailure {
                logStore?.addError(source: .app, context: "Failed to refresh latest analysis duration", error: error)
                didLogStatusMenuAverageDurationFailure = true
            }
        }
        let analysisStartupMode = settingsStore?.analysisStartupMode ?? AppDefaults.analysisStartupMode
        let language = settingsStore?.appLanguage ?? .current

        viewLogsItem.title = text(.menuShowLogs, language: language)
        viewLogsItem.isEnabled = true
        analysisStartupModeMenuItem.title = text(.menuAnalysisStartupMode, language: language)
        for mode in AnalysisStartupMode.allCases {
            guard let item = analysisStartupModeItems[mode] else { continue }
            item.title = mode.title(in: language)
            item.state = mode == analysisStartupMode ? .on : .off
        }

        if let lastAverageDuration {
            let durationText = averageDurationFormatter(language: language).string(from: NSNumber(value: lastAverageDuration))
                ?? String(format: "%.1f", lastAverageDuration)
            statusAverageDurationItem.title = text(.menuLastAverageDuration, arguments: [durationText], language: language)
            statusAverageDurationItem.isHidden = false
        } else {
            statusAverageDurationItem.title = ""
            statusAverageDurationItem.isHidden = true
        }

        if analysisState.isRunning {
            let startedAt = analysisState.startedAt ?? pendingScreenshots.first?.capturedAt ?? Date()
            if analysisState.isStopping {
                let stoppingStage = analysisState.stoppingStage ?? .stoppingGeneration
                statusSummaryItem.title = text(
                    stoppingStage.statusSummaryLocalizationKey,
                    arguments: [
                        statusDateFormatter(language: language).string(from: startedAt),
                        analysisState.completedCount,
                        analysisState.totalCount,
                    ],
                    language: language
                )
                analyzeNowItem.title = text(stoppingStage.analyzeNowLocalizationKey, language: language)
                analyzeNowItem.isEnabled = false
            } else {
                statusSummaryItem.title = text(
                    .menuSummaryAnalyzing,
                    arguments: [
                        statusDateFormatter(language: language).string(from: startedAt),
                        analysisState.completedCount,
                        analysisState.totalCount,
                    ],
                    language: language
                )
                analyzeNowItem.title = text(.menuAnalyzeNowPause, language: language)
                analyzeNowItem.isEnabled = true
            }
            return
        }

        if let earliestScreenshotTime = pendingScreenshots.first?.capturedAt {
            statusSummaryItem.title = text(
                .menuSummaryPending,
                arguments: [
                    statusDateFormatter(language: language).string(from: earliestScreenshotTime),
                    pendingScreenshots.count,
                ],
                language: language
            )
            analyzeNowItem.title = text(.menuAnalyzeNowStart, language: language)
            analyzeNowItem.isEnabled = true
            return
        }

        if let nextScreenshotDate = screenshotService?.nextScreenshotDate {
            statusSummaryItem.title = text(
                .menuNextScreenshotAt,
                arguments: [statusDateFormatter(language: language).string(from: nextScreenshotDate)],
                language: language
            )
        } else {
            statusSummaryItem.title = text(.menuNoPending, language: language)
        }
        analyzeNowItem.title = text(.menuAnalyzeNowStart, language: language)
        analyzeNowItem.isEnabled = false
    }

    private func refreshLocalizedUI() {
        let language = settingsStore?.appLanguage ?? .current

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: text(.statusAccessibilityDescription, language: language))
        }

        currentStatusMenuItem.title = text(.menuCurrentStatus, language: language)
        openScreenshotsItem.title = text(.menuOpenScreenshotsFolder, language: language)
        settingsMenuItem.title = text(.menuSettings, language: language)
        reportsMenuItem.title = text(.menuReports, language: language)
        clearEarlyScreenshotsMenuItem.title = text(.menuClearEarlyScreenshots, language: language)
        quitMenuItem.title = text(.menuQuit, language: language)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.earlyScreenshotCleanupCoordinator.currentStatus()
            self.applyEarlyScreenshotCleanupStatus(status)
        }

        settingsWindow?.title = text(.windowSettings, language: language)
        reportsWindow?.title = text(.windowReports, language: language)
        logsWindow?.title = text(.windowLogs, language: language)
    }

    private func terminateOtherRunningInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        otherInstances.forEach { runningApp in
            runningApp.terminate()
        }
    }

    private func presentFatalAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func text(_ key: L10n.Key, language: AppLanguage) -> String {
        L10n.string(key, language: language)
    }

    private func text(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage) -> String {
        L10n.string(key, language: language, arguments: arguments)
    }

    private func statusDateFormatter(language: AppLanguage) -> DateFormatter {
        L10n.statusDateFormatter(language: language)
    }

    private func averageDurationFormatter(language: AppLanguage) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }
}
