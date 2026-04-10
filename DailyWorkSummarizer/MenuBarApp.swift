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
    private let automaticAnalysisToggleItem = NSMenuItem(title: "", action: #selector(toggleAutomaticAnalysis), keyEquivalent: "")
    private let analyzeNowItem = NSMenuItem(title: "", action: #selector(runAnalysisNow), keyEquivalent: "")
    private let currentStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
    private let reportsMenuItem = NSMenuItem(title: "", action: #selector(openReports), keyEquivalent: "r")
    private let quitMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherRunningInstances()

        do {
            let database = try AppDatabase()
            let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "DailyWorkSummarizer")
            let settingsStore = SettingsStore(database: database, keychain: keychain)
            let logStore = AppLogStore(database: database)

            self.database = database
            self.settingsStore = settingsStore
            self.logStore = logStore
            self.screenshotService = ScreenshotService(database: database, settingsStore: settingsStore)
            let dailyReportSummaryService = DailyReportSummaryService(database: database, settingsStore: settingsStore)
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
                dailyReportSummaryService: dailyReportSummaryService
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
        automaticAnalysisToggleItem.target = self
        analyzeNowItem.target = self

        let statusSubmenu = NSMenu()
        statusSubmenu.addItem(statusSummaryItem)
        statusSubmenu.addItem(statusAverageDurationItem)
        statusSubmenu.addItem(.separator())
        statusSubmenu.addItem(openScreenshotsItem)
        statusSubmenu.addItem(viewLogsItem)
        statusSubmenu.addItem(automaticAnalysisToggleItem)
        statusSubmenu.addItem(analyzeNowItem)

        menu.addItem(currentStatusMenuItem)
        menu.setSubmenu(statusSubmenu, for: currentStatusMenuItem)
        menu.addItem(.separator())
        menu.addItem(settingsMenuItem)
        menu.addItem(reportsMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
        menu.items.forEach { $0.target = self }
        return menu
    }()

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            self?.refreshStatusMenu()
        }
    }

    @objc private func openSettings() {
        guard let settingsStore, let screenshotService, let analysisService else { return }
        if let window = settingsWindow {
            activateAndShow(window)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView(
                settingsStore: settingsStore,
                screenshotService: screenshotService,
                analysisService: analysisService
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

    @objc private func toggleAutomaticAnalysis() {
        guard let settingsStore else { return }
        settingsStore.automaticAnalysisEnabled.toggle()
    }

    @objc private func runAnalysisNow() {
        guard let analysisService else { return }
        if analysisService.currentState.isRunning {
            analysisService.cancelCurrentRun()
        } else {
            analysisService.runNow()
        }
    }

    private func activateAndShow(_ window: NSWindow) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshStatusMenu() {
        guard let database else { return }

        let defaultDuration = settingsStore?.screenshotIntervalMinutes ?? AppDefaults.screenshotIntervalMinutes
        let pendingScreenshots = (try? database.listScreenshotFiles(defaultDurationMinutes: defaultDuration)) ?? []
        let analysisState = analysisService?.currentState ?? .idle
        let lastAverageDuration = try? database.fetchLatestAnalysisAverageDurationSeconds()
        let automaticAnalysisEnabled = settingsStore?.automaticAnalysisEnabled ?? AppDefaults.automaticAnalysisEnabled
        let language = settingsStore?.appLanguage ?? .current

        viewLogsItem.title = text(.menuShowLogs, language: language)
        viewLogsItem.isEnabled = true
        automaticAnalysisToggleItem.title = automaticAnalysisEnabled
            ? text(.menuTurnOffAutoAnalysis, language: language)
            : text(.menuTurnOnAutoAnalysis, language: language)
        automaticAnalysisToggleItem.isEnabled = true

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
                statusSummaryItem.title = text(
                    .menuSummaryPausing,
                    arguments: [
                        statusDateFormatter(language: language).string(from: startedAt),
                        analysisState.completedCount,
                        analysisState.totalCount,
                    ],
                    language: language
                )
                analyzeNowItem.title = text(.menuAnalyzeNowPausing, language: language)
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

        if let earliestCapture = pendingScreenshots.first?.capturedAt {
            statusSummaryItem.title = text(
                .menuSummaryPending,
                arguments: [
                    statusDateFormatter(language: language).string(from: earliestCapture),
                    pendingScreenshots.count,
                ],
                language: language
            )
            analyzeNowItem.title = text(.menuAnalyzeNowStart, language: language)
            analyzeNowItem.isEnabled = true
            return
        }

        if let nextCaptureDate = screenshotService?.nextCaptureDate {
            statusSummaryItem.title = text(
                .menuNextCaptureAt,
                arguments: [statusDateFormatter(language: language).string(from: nextCaptureDate)],
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
        quitMenuItem.title = text(.menuQuit, language: language)

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
