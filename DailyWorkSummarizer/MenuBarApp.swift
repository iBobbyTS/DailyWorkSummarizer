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
    private var errorsWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?
    private var databaseObserver: NSObjectProtocol?
    private var screenshotObserver: NSObjectProtocol?
    private var analysisObserver: NSObjectProtocol?
    private var errorsObserver: NSObjectProtocol?

    private var database: AppDatabase?
    private var settingsStore: SettingsStore?
    private var screenshotService: ScreenshotService?
    private var analysisService: AnalysisService?
    private var reportsViewModel: ReportsViewModel?
    private var errorStore: AnalysisErrorStore?
    private let statusSummaryItem = NSMenuItem(title: "当前没有待分析的截图", action: nil, keyEquivalent: "")
    private let statusAverageDurationItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openScreenshotsItem = NSMenuItem(title: "打开截图文件夹", action: #selector(openScreenshotsFolder), keyEquivalent: "")
    private let viewErrorsItem = NSMenuItem(title: "显示0个错误", action: #selector(openErrors), keyEquivalent: "")
    private let automaticAnalysisToggleItem = NSMenuItem(title: "关闭定时分析", action: #selector(toggleAutomaticAnalysis), keyEquivalent: "")
    private let analyzeNowItem = NSMenuItem(title: "立即分析", action: #selector(runAnalysisNow), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherRunningInstances()

        do {
            let database = try AppDatabase()
            let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "DailyWorkSummarizer")
            let settingsStore = SettingsStore(database: database, keychain: keychain)
            let errorStore = AnalysisErrorStore()

            self.database = database
            self.settingsStore = settingsStore
            self.errorStore = errorStore
            self.screenshotService = ScreenshotService(database: database, settingsStore: settingsStore)
            self.analysisService = AnalysisService(database: database, settingsStore: settingsStore, errorStore: errorStore)
            self.reportsViewModel = ReportsViewModel(database: database)
        } catch {
            presentFatalAlert(message: "初始化数据库失败", detail: error.localizedDescription)
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
        if let errorsObserver {
            NotificationCenter.default.removeObserver(errorsObserver)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow {
            settingsWindow = nil
        } else if window == reportsWindow {
            reportsWindow = nil
        } else if window == errorsWindow {
            errorsWindow = nil
        }
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: "每日工作总结")
        }
        statusItem.menu = menu
        self.statusItem = statusItem
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

        errorsObserver = NotificationCenter.default.addObserver(
            forName: .analysisErrorsDidChange,
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
        viewErrorsItem.target = self
        viewErrorsItem.isEnabled = false
        automaticAnalysisToggleItem.target = self
        analyzeNowItem.target = self

        let statusSubmenu = NSMenu()
        statusSubmenu.addItem(statusSummaryItem)
        statusSubmenu.addItem(statusAverageDurationItem)
        statusSubmenu.addItem(.separator())
        statusSubmenu.addItem(openScreenshotsItem)
        statusSubmenu.addItem(viewErrorsItem)
        statusSubmenu.addItem(automaticAnalysisToggleItem)
        statusSubmenu.addItem(analyzeNowItem)

        let statusItem = NSMenuItem(title: "当前状态", action: nil, keyEquivalent: "")
        menu.addItem(statusItem)
        menu.setSubmenu(statusSubmenu, for: statusItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "查看报告", action: #selector(openReports), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
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
        window.title = "设置"
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
        window.title = "查看报告"
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

    @objc private func openErrors() {
        guard let errorStore, errorStore.count > 0 else { return }
        if let window = errorsWindow {
            activateAndShow(window)
            return
        }

        let controller = NSHostingController(rootView: AnalysisErrorsView(errorStore: errorStore))
        let window = NSWindow(contentViewController: controller)
        window.delegate = self
        window.title = "查看错误"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 500))
        window.center()
        errorsWindow = window
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
        let errorCount = errorStore?.count ?? 0
        let automaticAnalysisEnabled = settingsStore?.automaticAnalysisEnabled ?? AppDefaults.automaticAnalysisEnabled

        viewErrorsItem.title = "显示\(errorCount)个错误"
        viewErrorsItem.isEnabled = errorCount > 0
        automaticAnalysisToggleItem.title = automaticAnalysisEnabled ? "关闭定时分析" : "开启定时分析"
        automaticAnalysisToggleItem.isEnabled = true

        if let lastAverageDuration {
            statusAverageDurationItem.title = "上次分析平均每张耗时\(Self.averageDurationFormatter.string(from: NSNumber(value: lastAverageDuration)) ?? String(format: "%.1f", lastAverageDuration))秒"
            statusAverageDurationItem.isHidden = false
        } else {
            statusAverageDurationItem.title = ""
            statusAverageDurationItem.isHidden = true
        }

        if analysisState.isRunning {
            let startedAt = analysisState.startedAt ?? pendingScreenshots.first?.capturedAt ?? Date()
            if analysisState.isStopping {
                statusSummaryItem.title = "正在暂停从 \(Self.statusDateFormatter.string(from: startedAt)) 开始的截屏分析（\(analysisState.completedCount)/\(analysisState.totalCount)）"
                analyzeNowItem.title = "正在暂停"
                analyzeNowItem.isEnabled = false
            } else {
                statusSummaryItem.title = "正在分析从 \(Self.statusDateFormatter.string(from: startedAt)) 开始的截屏（\(analysisState.completedCount)/\(analysisState.totalCount)）"
                analyzeNowItem.title = "暂停分析"
                analyzeNowItem.isEnabled = true
            }
            return
        }

        if let earliestCapture = pendingScreenshots.first?.capturedAt {
            statusSummaryItem.title = "当前截图从 \(Self.statusDateFormatter.string(from: earliestCapture)) 开始，共 \(pendingScreenshots.count) 张"
            analyzeNowItem.title = "开始分析"
            analyzeNowItem.isEnabled = true
            return
        }

        if let nextCaptureDate = screenshotService?.nextCaptureDate {
            statusSummaryItem.title = "下一次会在\(Self.statusDateFormatter.string(from: nextCaptureDate))进行截图"
        } else {
            statusSummaryItem.title = "当前没有待分析的截图"
        }
        analyzeNowItem.title = "开始分析"
        analyzeNowItem.isEnabled = false
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

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy.M.d HH:mm"
        return formatter
    }()

    private static let averageDurationFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}
