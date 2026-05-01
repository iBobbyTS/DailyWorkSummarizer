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
            modelName: runtimeState.modelName,
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
            loadedModel = try await loadScreenshotAnalysisModelIfNeeded(for: snapshot.screenshotAnalysisModelProfile)
            let result = try await analysisWorker.analyzeImageDetailed(
                at: imageFileURL,
                settings: snapshot,
                prompt: prompt
            )
            recordLMStudioModelInstanceIfNeeded(result.modelInstanceID, provider: snapshot.provider)
            if let loadedModel {
                await unloadModelAfterSettingsTest(
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
                await unloadModelAfterSettingsTest(
                    settings: snapshot.screenshotAnalysisModelProfile,
                    instanceID: loadedModel.instanceID
                )
            }
            if Self.shouldRecordRuntimeError(error) {
                logStore.addError(source: .analysis, context: "Failed to test screenshot analysis settings", error: error)
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

        let runID: Int64
        do {
            runID = try database.createAnalysisRun(
                modelName: snapshot.modelName,
                totalItems: pendingScreenshots.count
            )
        } catch {
            logStore.addError(source: .analysis, context: "Failed to create analysis run", error: error)
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
            modelName: snapshot.modelName,
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
            finishAnalysisRun(
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
                finishAnalysisRun(
                    id: run.id,
                    status: "failed",
                    successCount: 0,
                    failureCount: run.totalCount,
                    errorMessage: localized(.analysisNeedsBaseURL, language: snapshot.appLanguage)
                )
                return
            }

            guard !snapshot.modelName.isEmpty else {
                finishAnalysisRun(
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
            loadedAnalysisModel = try await loadScreenshotAnalysisModelIfNeeded(for: snapshot.screenshotAnalysisModelProfile)
        } catch {
            if Self.shouldRecordRuntimeError(error) {
                logStore.addError(source: .analysis, context: "Failed to load screenshot analysis model", error: error)
            }
            finishAnalysisRun(
                id: run.id,
                status: "failed",
                successCount: 0,
                failureCount: run.totalCount,
                errorMessage: error.localizedDescription
            )
            return
        }

        func recordLMStudioCancellationObservationIfNeeded() {
            guard snapshot.screenshotAnalysisModelProfile.provider == .lmStudio,
                  snapshot.screenshotAnalysisModelProfile.automaticallyLoadAndUnloadModel,
                  !run.didLogLMStudioCancellationObservation else { return }
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
                    logStore.add(
                        level: .log,
                        source: .analysis,
                        message: "Pending screenshot no longer exists: \(fileURL.path)"
                    )
                    run.failureCount += 1
                    run.consecutiveFailureCount += 1
                    run.completedCount += 1
                    updateRuntimeState(
                        startedAt: run.startedAt,
                        modelName: snapshot.modelName,
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
                    removeProcessedScreenshot(at: fileURL)
                    NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        recordLMStudioCancellationObservationIfNeeded()
                        run.wasCancelled = true
                        break
                    }

                    if Self.shouldRecordRuntimeError(error) {
                        logStore.addError(source: .analysis, context: "Failed to analyze screenshot \(fileURL.lastPathComponent)", error: error)
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
                    modelName: snapshot.modelName,
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
            finishAnalysisRun(
                id: run.id,
                status: "cancelled",
                successCount: run.successCount,
                failureCount: run.failureCount,
                averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                errorMessage: localized(.analysisCancelledByUser, language: snapshot.appLanguage)
            )
            if let unloadingStage = Self.stoppingStageAfterGenerationStops(
                for: snapshot.screenshotAnalysisModelProfile.provider,
                lifecycleEnabled: snapshot.screenshotAnalysisModelProfile.automaticallyLoadAndUnloadModel
            ) {
                updateRuntimeState(
                    startedAt: run.startedAt,
                    modelName: snapshot.modelName,
                    completedCount: run.completedCount,
                    totalCount: run.totalCount,
                    stoppingStage: unloadingStage
                )
            }
            await unloadScreenshotAnalysisModelIfNeeded(
                for: snapshot.screenshotAnalysisModelProfile,
                loadedInstanceID: loadedAnalysisModel?.instanceID,
                cancelActiveRequest: true
            )
            return
        }

        if run.wasPausedAfterFailures {
            let message = localized(.analysisPausedAfterFailures, language: snapshot.appLanguage)
            let finalStatus = run.successCount > 0 ? "partial_failed" : "failed"
            finishAnalysisRun(
                id: run.id,
                status: finalStatus,
                successCount: run.successCount,
                failureCount: run.failureCount,
                averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                errorMessage: message
            )
            await unloadScreenshotAnalysisModelIfNeeded(
                for: snapshot.screenshotAnalysisModelProfile,
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

        finishAnalysisRun(
            id: run.id,
            status: finalStatus,
            successCount: run.successCount,
            failureCount: run.failureCount,
            averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
            errorMessage: run.failureCount > 0 ? localized(.analysisPartialFailures, language: snapshot.appLanguage) : nil
        )
        let affectedDayStarts = Self.affectedDayStarts(
            from: run.screenshots,
            calendar: Calendar.reportCalendar(language: snapshot.appLanguage)
        )
        await summarizeMissingReportsAfterAnalysis(
            snapshot: snapshot,
            loadedAnalysisModel: loadedAnalysisModel,
            affectedDayStarts: affectedDayStarts
        )
    }

    private func loadScreenshotAnalysisModelIfNeeded(for settings: ModelProfileSettings) async throws -> LMStudioLoadedModel? {
        guard settings.provider == .lmStudio,
              settings.automaticallyLoadAndUnloadModel else {
            return nil
        }

        return try await lmStudioLifecycle.load(settings: settings)
    }

    private func summarizeMissingReportsAfterAnalysis(
        snapshot: AppSettingsSnapshot,
        loadedAnalysisModel: LMStudioLoadedModel?,
        affectedDayStarts: Set<Date>
    ) async {
        let analysisSettings = snapshot.screenshotAnalysisModelProfile
        let summarySettings = snapshot.workContentSummaryModelProfile

        let analysisLifecycleEnabled = analysisSettings.provider == .lmStudio && analysisSettings.automaticallyLoadAndUnloadModel
        let summaryLifecycleEnabled = summarySettings.provider == .lmStudio && summarySettings.automaticallyLoadAndUnloadModel
        let equivalentLoadConfiguration = LMStudioAPI.hasEquivalentLoadConfiguration(analysisSettings, summarySettings)
        let canReuseAnalysisModel = analysisLifecycleEnabled
            && summarySettings.provider == .lmStudio
            && equivalentLoadConfiguration
            && loadedAnalysisModel != nil

        if analysisLifecycleEnabled,
           loadedAnalysisModel != nil,
           (summarySettings.provider != .lmStudio || !equivalentLoadConfiguration) {
            await unloadScreenshotAnalysisModelIfNeeded(
                for: analysisSettings,
                loadedInstanceID: loadedAnalysisModel?.instanceID,
                cancelActiveRequest: false
            )
        }

        await dailyReportSummaryService.summarizeAffectedSummaries(
            for: affectedDayStarts,
            lmStudioLifecyclePolicy: (summaryLifecycleEnabled && !canReuseAnalysisModel)
                ? .automaticUnload
                : .alreadyLoadedKeepLoaded
        )
    }

    private func pendingScreenshotFiles(defaultDurationMinutes: Int) -> [ScreenshotFileRecord] {
        do {
            return try database.listScreenshotFiles(defaultDurationMinutes: defaultDurationMinutes)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to list pending screenshot files", error: error)
            return []
        }
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
            logStore.addError(source: .analysis, context: "Failed to update analysis run total items", error: error)
        }
        updateRuntimeState(
            startedAt: run.startedAt,
            modelName: run.settings.modelName,
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
        modelName: String?,
        completedCount: Int,
        totalCount: Int,
        stoppingStage: AnalysisStoppingStage? = nil
    ) {
        runtimeState = AnalysisRuntimeState(
            isRunning: true,
            stoppingStage: stoppingStage ?? runtimeState.stoppingStage,
            startedAt: startedAt,
            modelName: modelName ?? runtimeState.modelName,
            completedCount: completedCount,
            totalCount: totalCount
        )
    }

    func forceUnloadManagedModel() async throws -> Bool {
        let snapshot = settingsStore.snapshot.screenshotAnalysisModelProfile
        guard snapshot.provider == .lmStudio else {
            return false
        }

        if runtimeState.isRunning {
            cancelCurrentRun()
            await waitForAnalysisToStop()
        }

        do {
            try await lmStudioLifecycle.unload(settings: snapshot, instanceID: nil)
            return true
        } catch LMStudioModelLifecycleError.missingLoadedInstanceID {
            logStore.add(
                level: .log,
                source: .lmStudio,
                message: localized(.menuForceUnloadNoLoadedModel)
            )
            return false
        } catch {
            logStore.addError(source: .lmStudio, context: "Forced unload of screenshot analysis model failed", error: error)
            throw error
        }
    }

    private func finishAnalysisRun(
        id: Int64,
        status: String,
        successCount: Int,
        failureCount: Int,
        averageItemDurationSeconds: Double? = nil,
        errorMessage: String? = nil
    ) {
        do {
            try database.finishAnalysisRun(
                id: id,
                status: status,
                successCount: successCount,
                failureCount: failureCount,
                averageItemDurationSeconds: averageItemDurationSeconds,
                errorMessage: errorMessage
            )
        } catch {
            logStore.addError(source: .analysis, context: "Failed to finish analysis run \(id)", error: error)
        }
    }

    private func removeProcessedScreenshot(at fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to remove processed screenshot \(fileURL.lastPathComponent)", error: error)
        }
    }

    private func unloadModelAfterSettingsTest(
        settings: ModelProfileSettings,
        instanceID: String?
    ) async {
        do {
            try await lmStudioLifecycle.unload(settings: settings, instanceID: instanceID)
        } catch {
            logStore.addError(source: .lmStudio, context: "Failed to unload LM Studio model after settings test", error: error)
        }
    }

    private func unloadScreenshotAnalysisModelIfNeeded(
        for settings: ModelProfileSettings,
        loadedInstanceID: String?,
        cancelActiveRequest: Bool
    ) async {
        if settings.provider == .lmStudio,
           settings.automaticallyLoadAndUnloadModel {
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

        guard settings.provider == .lmStudio,
              settings.automaticallyLoadAndUnloadModel else {
            return
        }

        do {
            try await lmStudioLifecycle.unload(settings: settings, instanceID: loadedInstanceID)
        } catch {
            logStore.addError(source: .lmStudio, context: "LM Studio model unload failed", error: error)
            return
        }
    }

    private func waitForAnalysisToStop(timeoutSeconds: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while runtimeState.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }


    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage, arguments: arguments)
    }

    private static func affectedDayStarts(
        from screenshots: [ScreenshotFileRecord],
        calendar: Calendar
    ) -> Set<Date> {
        var dayStarts = Set<Date>()

        for screenshot in screenshots {
            let start = screenshot.capturedAt
            let end = screenshot.endAt
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
        }

        return dayStarts
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
