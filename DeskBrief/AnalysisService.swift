import AppKit
import Foundation

enum AnalysisServiceError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case lengthTruncated(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .httpError(let statusCode, let body):
            return L10n.string(.analysisHTTPError, arguments: [statusCode, body])
        case .lengthTruncated(let message):
            return message
        }
    }
}

@MainActor
final class AnalysisService {
    enum AnalysisTrigger {
        case manual
        case scheduled
        case realtime
    }


    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let dailyReportSummaryService: DailyReportSummaryService
    private let llmService: LLMService
    private let analysisWorker: AnalysisWorker
    private let lmStudioLifecycle: LMStudioModelLifecycle
    private var timer: Timer?
    private var realtimeAnalysisTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var screenshotSavedObserver: NSObjectProtocol?
    private var runningTask: Task<Void, Never>?
    private var activeAnalysisRun: ActiveAnalysisRun?
    private var pendingRequestAfterCurrentRun: AnalysisTrigger?
    private var activeRunSettings: AppSettingsSnapshot?
    private var lastLMStudioModelInstanceID: String?
    private var runtimeState: AnalysisRuntimeState = .idle {
        didSet {
            NotificationCenter.default.post(name: .analysisStatusDidChange, object: nil)
        }
    }

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore,
        dailyReportSummaryService: DailyReportSummaryService,
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.dailyReportSummaryService = dailyReportSummaryService
        let resolvedSession = session ?? Self.makeIsolatedSession()
        self.llmService = LLMService(session: resolvedSession)
        self.analysisWorker = AnalysisWorker(llmService: self.llmService)
        self.lmStudioLifecycle = LMStudioModelLifecycle(session: resolvedSession) { [weak settingsStore, weak logStore] chinese, english in
            Task { @MainActor in
                guard let logStore else { return }
                let language = settingsStore?.appLanguage ?? .current
                let message = language == .simplifiedChinese ? chinese : english
                logStore.add(level: .log, source: .lmStudio, message: message)
            }
        }
    }

    deinit {
        timer?.invalidate()
        realtimeAnalysisTimer?.invalidate()
        runningTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let screenshotSavedObserver {
            NotificationCenter.default.removeObserver(screenshotSavedObserver)
        }
    }

    func start() {
        scheduleNextRun()
        screenshotSavedObserver = NotificationCenter.default.addObserver(
            forName: .screenshotFileSaved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is URL else {
                return
            }
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

    func reschedule() {
        scheduleNextRun()
        if settingsStore.snapshot.analysisStartupMode != .realtime {
            realtimeAnalysisTimer?.invalidate()
            realtimeAnalysisTimer = nil
        }
    }

    func runNow() {
        triggerAnalysis(scheduledFor: Date(), trigger: .manual)
    }

    func cancelCurrentRun() {
        guard runtimeState.isRunning, !runtimeState.isStopping else { return }
        activeAnalysisRun?.isAcceptingAppends = false
        if activeRunSettings?.provider == .lmStudio {
            recordLMStudioLog(
                chinese: "用户点击了停止本次分析。",
                english: "User requested to stop current analysis."
            )
        }
        updateRuntimeState(
            startedAt: runtimeState.startedAt,
            completedCount: runtimeState.completedCount,
            totalCount: runtimeState.totalCount,
            stoppingStage: .stoppingGeneration
        )
        runningTask?.cancel()
        llmService.cancelActiveRemoteRequest()
        if activeRunSettings?.provider == .lmStudio {
            recordLMStudioLog(
                chinese: "已向当前 LM Studio 请求发送取消。",
                english: "Sent cancellation to the active LM Studio request."
            )
        }
    }

    var currentState: AnalysisRuntimeState {
        runtimeState
    }

    func currentPrompt() -> String {
        let snapshot = settingsStore.snapshot
        return buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.summaryInstruction,
            language: snapshot.appLanguage
        )
    }

    func testCurrentSettings(with imageFileURL: URL) async throws -> ModelTestResult {
        let snapshot = settingsStore.snapshot
        lastLMStudioModelInstanceID = nil

        guard !snapshot.validCategoryRules.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsCategoryRule, language: snapshot.appLanguage))
        }

        if snapshot.provider.requiresRemoteConfiguration {
            guard !snapshot.apiBaseURL.isEmpty else {
                throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsBaseURL, language: snapshot.appLanguage))
            }

            guard !snapshot.modelName.isEmpty else {
                throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsModelName, language: snapshot.appLanguage))
            }
        }

        let prompt = buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.summaryInstruction,
            language: snapshot.appLanguage
        )
        var loadedModel: LMStudioLoadedModel?
        do {
            loadedModel = try await loadScreenshotAnalysisModelIfNeeded(for: snapshot)
            let result = try await analysisWorker.analyzeImageDetailed(
                at: imageFileURL,
                settings: snapshot,
                prompt: prompt
            )
            recordLMStudioModelInstanceIfNeeded(result.modelInstanceID, provider: snapshot.provider)
            if let loadedModel {
                try? await lmStudioLifecycle.unload(
                    settings: snapshot.screenshotAnalysisModelProfile,
                    instanceID: loadedModel.instanceID
                )
            }
            return ModelTestResult(
                provider: snapshot.provider,
                imageAnalysisMethod: snapshot.provider == .appleIntelligence ? .ocr : snapshot.imageAnalysisMethod,
                response: result.response,
                requestTiming: result.requestTiming,
                lmStudioTiming: result.lmStudioTiming,
                ocrText: result.ocrText,
                reasoningText: result.reasoningText
            )
        } catch {
            if let loadedModel {
                try? await lmStudioLifecycle.unload(
                    settings: snapshot.screenshotAnalysisModelProfile,
                    instanceID: loadedModel.instanceID
                )
            }
            if Self.shouldRecordRuntimeError(error) {
                logStore.add(level: .error, source: .analysis, message: error.localizedDescription)
            }
            throw error
        }
    }

    private static func makeIsolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func scheduleNextRun() {
        timer?.invalidate()
        guard settingsStore.snapshot.analysisStartupMode == .scheduled else {
            return
        }
        let nextDate = settingsStore.snapshot.nextAnalysisDate(after: Date())
        timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerAnalysis(scheduledFor: nextDate, trigger: .scheduled)
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func scheduleRealtimeAnalysisAfterCapture() {
        guard settingsStore.snapshot.analysisStartupMode == .realtime else {
            return
        }

        realtimeAnalysisTimer?.invalidate()
        let fireDate = Date().addingTimeInterval(1)
        realtimeAnalysisTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRealtimeAnalysis()
            }
        }

        if let realtimeAnalysisTimer {
            RunLoop.main.add(realtimeAnalysisTimer, forMode: .common)
        }
    }

    private func triggerRealtimeAnalysis() {
        realtimeAnalysisTimer?.invalidate()
        realtimeAnalysisTimer = nil

        guard settingsStore.snapshot.analysisStartupMode == .realtime else {
            return
        }

        triggerAnalysis(scheduledFor: Date(), trigger: .realtime)
    }

    private func triggerAnalysis(scheduledFor _: Date, trigger: AnalysisTrigger) {
        if Self.shouldSkipForChargerRequirement(
            trigger: trigger,
            requiresCharger: settingsStore.snapshot.autoAnalysisRequiresCharger,
            isConnectedToCharger: Self.isConnectedToCharger()
        ) {
            if trigger == .scheduled {
                scheduleNextRun()
            }
            return
        }

        if let activeAnalysisRun {
            if activeAnalysisRun.isAcceptingAppends {
                appendPendingScreenshots(to: activeAnalysisRun)
            } else {
                rememberPendingRequestAfterCurrentRun(trigger)
            }
            return
        }

        let snapshot = settingsStore.snapshot
        let pendingScreenshots = pendingScreenshotFiles(defaultDurationMinutes: snapshot.screenshotIntervalMinutes)
        guard !pendingScreenshots.isEmpty else {
            if trigger == .scheduled {
                scheduleNextRun()
            }
            return
        }

        let prompt = buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.summaryInstruction,
            language: snapshot.appLanguage
        )

        guard let runID = try? database.createAnalysisRun(
            modelName: snapshot.modelName,
            totalItems: pendingScreenshots.count
        ) else {
            return
        }

        let run = ActiveAnalysisRun(
            id: runID,
            settings: snapshot,
            prompt: prompt,
            screenshots: pendingScreenshots
        )
        activeAnalysisRun = run
        updateRuntimeState(
            startedAt: run.startedAt,
            completedCount: run.completedCount,
            totalCount: run.totalCount,
            stoppingStage: nil
        )
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis(for: run)
            await MainActor.run {
                let pendingRequest = self.pendingRequestAfterCurrentRun
                self.pendingRequestAfterCurrentRun = nil
                self.runningTask = nil
                self.scheduleNextRun()
                if let pendingRequest {
                    self.triggerAnalysis(scheduledFor: Date(), trigger: pendingRequest)
                }
            }
        }
    }

    private func runAnalysis(for run: ActiveAnalysisRun) async {
        let snapshot = run.settings
        lastLMStudioModelInstanceID = nil
        activeRunSettings = snapshot
        defer {
            activeRunSettings = nil
            activeAnalysisRun = nil
            runtimeState = .idle
        }

        guard !snapshot.validCategoryRules.isEmpty else {
            try? database.finishAnalysisRun(
                id: run.id,
                status: "failed",
                successCount: 0,
                failureCount: run.totalCount,
                errorMessage: localized(.analysisNeedsCategoryRule, language: snapshot.appLanguage)
            )
            return
        }

        if snapshot.provider.requiresRemoteConfiguration {
            guard !snapshot.apiBaseURL.isEmpty else {
                try? database.finishAnalysisRun(
                    id: run.id,
                    status: "failed",
                    successCount: 0,
                    failureCount: run.totalCount,
                    errorMessage: localized(.analysisNeedsBaseURL, language: snapshot.appLanguage)
                )
                return
            }

            guard !snapshot.modelName.isEmpty else {
                try? database.finishAnalysisRun(
                    id: run.id,
                    status: "failed",
                    successCount: 0,
                    failureCount: run.totalCount,
                    errorMessage: localized(.analysisNeedsModelName, language: snapshot.appLanguage)
                )
                return
            }
        }

        let loadedAnalysisModel: LMStudioLoadedModel?
        do {
            loadedAnalysisModel = try await loadScreenshotAnalysisModelIfNeeded(for: snapshot)
        } catch {
            if Self.shouldRecordRuntimeError(error) {
                logStore.add(level: .error, source: .analysis, message: error.localizedDescription)
            }
            try? database.finishAnalysisRun(
                id: run.id,
                status: "failed",
                successCount: 0,
                failureCount: run.totalCount,
                errorMessage: error.localizedDescription
            )
            return
        }

        func recordLMStudioCancellationObservationIfNeeded() {
            guard snapshot.provider == .lmStudio, !run.didLogLMStudioCancellationObservation else { return }
            run.didLogLMStudioCancellationObservation = true
            recordLMStudioLog(
                chinese: "分析循环检测到取消，准备进入 LM Studio 清理阶段。",
                english: "Analysis loop observed cancellation and is entering LM Studio cleanup."
            )
        }

        while true {
            while let screenshot = run.nextScreenshot() {
                if Task.isCancelled {
                    recordLMStudioCancellationObservationIfNeeded()
                    run.wasCancelled = true
                    break
                }

                let fileURL = screenshot.url
                let capturedAt = screenshot.capturedAt
                let durationMinutes = screenshot.durationMinutes

                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    run.failureCount += 1
                    run.consecutiveFailureCount += 1
                    run.completedCount += 1
                    updateRuntimeState(
                        startedAt: run.startedAt,
                        completedCount: run.completedCount,
                        totalCount: run.totalCount
                    )
                    if Self.shouldPauseAfterConsecutiveFailures(run.consecutiveFailureCount) {
                        run.wasPausedAfterFailures = true
                        break
                    }
                    continue
                }

                let shouldMeasureDuration = run.completedCount > 0
                let itemStartTime = shouldMeasureDuration ? Date() : nil

                do {
                    let result = try await analysisWorker.analyzeImageDetailed(
                        at: fileURL,
                        settings: snapshot,
                        prompt: run.prompt
                    )
                    recordLMStudioModelInstanceIfNeeded(result.modelInstanceID, provider: snapshot.provider)
                    let response = result.response

                    _ = try database.insertAnalysisResult(
                        capturedAt: capturedAt,
                        categoryName: response.category,
                        summaryText: response.summary,
                        durationMinutesSnapshot: durationMinutes
                    )

                    run.successCount += 1
                    run.consecutiveFailureCount = 0
                    try? FileManager.default.removeItem(at: fileURL)
                    NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        recordLMStudioCancellationObservationIfNeeded()
                        run.wasCancelled = true
                        break
                    }

                    let message = error.localizedDescription
                    if Self.shouldRecordRuntimeError(error) {
                        logStore.add(level: .error, source: .analysis, message: message)
                    }
                    run.failureCount += 1
                    run.consecutiveFailureCount += 1
                }

                if let itemStartTime {
                    run.measuredDurationTotal += Date().timeIntervalSince(itemStartTime)
                    run.measuredItemCount += 1
                }

                run.completedCount += 1
                updateRuntimeState(
                    startedAt: run.startedAt,
                    completedCount: run.completedCount,
                    totalCount: run.totalCount
                )

                if Self.shouldPauseAfterConsecutiveFailures(run.consecutiveFailureCount) {
                    run.wasPausedAfterFailures = true
                    break
                }

                await Task.yield()
            }

            if run.wasCancelled || run.wasPausedAfterFailures {
                break
            }

            if await waitForAdditionalScreenshots(to: run) {
                continue
            }

            if Task.isCancelled {
                recordLMStudioCancellationObservationIfNeeded()
                run.wasCancelled = true
                break
            }
            run.isAcceptingAppends = false
            break
        }

        run.isAcceptingAppends = false

        if run.wasCancelled {
            try? database.finishAnalysisRun(
                id: run.id,
                status: "cancelled",
                successCount: run.successCount,
                failureCount: run.failureCount,
                averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                errorMessage: localized(.analysisCancelledByUser, language: snapshot.appLanguage)
            )
            if let unloadingStage = Self.stoppingStageAfterGenerationStops(for: snapshot.provider) {
                updateRuntimeState(
                    startedAt: run.startedAt,
                    completedCount: run.completedCount,
                    totalCount: run.totalCount,
                    stoppingStage: unloadingStage
                )
            }
            await unloadScreenshotAnalysisModelIfNeeded(
                for: snapshot,
                loadedInstanceID: loadedAnalysisModel?.instanceID,
                cancelActiveRequest: true
            )
            return
        }

        if run.wasPausedAfterFailures {
            let message = localized(.analysisPausedAfterFailures, language: snapshot.appLanguage)
            let finalStatus = run.successCount > 0 ? "partial_failed" : "failed"
            try? database.finishAnalysisRun(
                id: run.id,
                status: finalStatus,
                successCount: run.successCount,
                failureCount: run.failureCount,
                averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                errorMessage: message
            )
            await unloadScreenshotAnalysisModelIfNeeded(
                for: snapshot,
                loadedInstanceID: loadedAnalysisModel?.instanceID,
                cancelActiveRequest: true
            )
            return
        }

        let finalStatus: String
        if run.successCount == 0 && run.failureCount > 0 {
            finalStatus = "failed"
        } else if run.failureCount > 0 {
            finalStatus = "partial_failed"
        } else {
            finalStatus = "succeeded"
        }

        try? database.finishAnalysisRun(
            id: run.id,
            status: finalStatus,
            successCount: run.successCount,
            failureCount: run.failureCount,
            averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
            errorMessage: run.failureCount > 0 ? localized(.analysisPartialFailures, language: snapshot.appLanguage) : nil
        )
        await summarizeMissingReportsAfterAnalysis(
            snapshot: snapshot,
            loadedAnalysisModel: loadedAnalysisModel
        )
    }

    private func loadScreenshotAnalysisModelIfNeeded(for snapshot: AppSettingsSnapshot) async throws -> LMStudioLoadedModel? {
        guard snapshot.provider == .lmStudio else {
            return nil
        }

        return try await lmStudioLifecycle.load(settings: snapshot.screenshotAnalysisModelProfile)
    }

    private func summarizeMissingReportsAfterAnalysis(
        snapshot: AppSettingsSnapshot,
        loadedAnalysisModel: LMStudioLoadedModel?
    ) async {
        let analysisSettings = snapshot.screenshotAnalysisModelProfile
        let summarySettings = snapshot.workContentSummaryModelProfile

        if analysisSettings.provider == .lmStudio {
            if summarySettings.provider == .lmStudio {
                if LMStudioAPI.hasEquivalentLoadConfiguration(analysisSettings, summarySettings) {
                    await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded(
                        lmStudioLifecyclePolicy: .alreadyLoadedKeepLoaded
                    )
                    return
                }

                await unloadScreenshotAnalysisModelIfNeeded(
                    for: snapshot,
                    loadedInstanceID: loadedAnalysisModel?.instanceID,
                    cancelActiveRequest: false
                )
                await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded(
                    lmStudioLifecyclePolicy: .loadAndKeepLoaded
                )
                return
            }

            await unloadScreenshotAnalysisModelIfNeeded(
                for: snapshot,
                loadedInstanceID: loadedAnalysisModel?.instanceID,
                cancelActiveRequest: false
            )
            await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded()
            return
        }

        await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded()
    }

    private func pendingScreenshotFiles(defaultDurationMinutes: Int) -> [ScreenshotFileRecord] {
        (try? database.listScreenshotFiles(defaultDurationMinutes: defaultDurationMinutes)) ?? []
    }

    @discardableResult
    private func appendPendingScreenshots(to run: ActiveAnalysisRun) -> Int {
        let screenshots = pendingScreenshotFiles(defaultDurationMinutes: run.settings.screenshotIntervalMinutes)
        let appendedCount = run.appendMissingScreenshots(screenshots)
        guard appendedCount > 0 else {
            return 0
        }

        do {
            try database.updateAnalysisRunTotalItems(id: run.id, totalItems: run.totalCount)
        } catch {
            logStore.add(level: .error, source: .analysis, message: error.localizedDescription)
        }
        updateRuntimeState(
            startedAt: run.startedAt,
            completedCount: run.completedCount,
            totalCount: run.totalCount
        )
        return appendedCount
    }

    private func rememberPendingRequestAfterCurrentRun(_ trigger: AnalysisTrigger) {
        if pendingRequestAfterCurrentRun == nil || trigger == .manual {
            pendingRequestAfterCurrentRun = trigger
        }
    }

    private func waitForAdditionalScreenshots(to run: ActiveAnalysisRun) async -> Bool {
        guard realtimeAnalysisTimer != nil else {
            return run.hasRemainingScreenshots
        }

        for _ in 0..<20 {
            if Task.isCancelled {
                return false
            }
            if run.hasRemainingScreenshots {
                return true
            }
            if realtimeAnalysisTimer == nil {
                return run.hasRemainingScreenshots
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return run.hasRemainingScreenshots
    }

    private func buildPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage
    ) -> String {
        L10n.analysisPrompt(with: rules, summaryInstruction: summaryInstruction, language: language)
    }


    private func updateRuntimeState(
        startedAt: Date?,
        completedCount: Int,
        totalCount: Int,
        stoppingStage: AnalysisStoppingStage? = nil
    ) {
        runtimeState = AnalysisRuntimeState(
            isRunning: true,
            stoppingStage: stoppingStage ?? runtimeState.stoppingStage,
            startedAt: startedAt,
            completedCount: completedCount,
            totalCount: totalCount
        )
    }

    private func unloadScreenshotAnalysisModelIfNeeded(
        for settings: AppSettingsSnapshot,
        loadedInstanceID: String?,
        cancelActiveRequest: Bool
    ) async {
        if settings.provider == .lmStudio {
            let lastInstanceID = lastLMStudioModelInstanceID ?? "未记录"
            recordLMStudioLog(
                chinese: "进入 LM Studio 清理阶段，Task.isCancelled=\(Task.isCancelled)，最近一次 chat 的 model_instance_id=\(lastInstanceID)。",
                english: "Entering LM Studio cleanup. Task.isCancelled=\(Task.isCancelled), last chat model_instance_id=\(lastInstanceID)."
            )
            if cancelActiveRequest {
                recordLMStudioLog(
                    chinese: "再次向当前 LM Studio 请求发送取消。",
                    english: "Sending cancellation to the current LM Studio request again."
                )
            }
        }

        if cancelActiveRequest {
            llmService.cancelActiveRemoteRequest()
        }

        guard settings.provider == .lmStudio else {
            return
        }

        do {
            try await lmStudioLifecycle.unload(
                settings: settings.screenshotAnalysisModelProfile,
                instanceID: loadedInstanceID
            )
        } catch {
            recordLMStudioLog(
                chinese: "LM Studio 模型卸载失败：\(error.localizedDescription)",
                english: "LM Studio model unload failed: \(error.localizedDescription)"
            )
            return
        }
    }


    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage, arguments: arguments)
    }

    private func recordLMStudioModelInstanceIfNeeded(_ modelInstanceID: String?, provider: ModelProvider) {
        guard provider == .lmStudio,
              let modelInstanceID,
              !modelInstanceID.isEmpty else {
            return
        }

        lastLMStudioModelInstanceID = modelInstanceID
        recordLMStudioLog(
            chinese: "LM Studio chat 返回 model_instance_id=\(modelInstanceID)。",
            english: "LM Studio chat returned model_instance_id=\(modelInstanceID)."
        )
    }

    private func recordLMStudioLog(chinese: String, english: String) {
        let message: String
        switch settingsStore.appLanguage {
        case .simplifiedChinese:
            message = chinese
        case .english:
            message = english
        }

        logStore.add(level: .log, source: .lmStudio, message: message)
    }

}
