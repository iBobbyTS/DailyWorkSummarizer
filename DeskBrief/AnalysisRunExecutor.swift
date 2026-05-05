import AppKit
import Foundation

@MainActor
final class AnalysisRunExecutor {
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let llmService: LLMService
    private let analysisWorker: AnalysisWorker
    private let lmStudioLifecycle: LMStudioModelLifecycle
    private let notificationSender: AppNotificationSending

    private var activeAnalysisRun: ActiveAnalysisRun?
    private var activeRunSettings: AppSettingsSnapshot?
    private var lastLMStudioModelInstanceID: String?
    private var runningTask: Task<Void, Never>?
    private var runtimeState: AnalysisRuntimeState = .idle {
        didSet {
            onStateChange?(runtimeState)
        }
    }

    var onStateChange: ((AnalysisRuntimeState) -> Void)?
    var onRunResult: ((AnalysisRunResult) -> Void)?

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore,
        llmService: LLMService,
        analysisWorker: AnalysisWorker,
        lmStudioLifecycle: LMStudioModelLifecycle,
        notificationSender: AppNotificationSending
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.llmService = llmService
        self.analysisWorker = analysisWorker
        self.lmStudioLifecycle = lmStudioLifecycle
        self.notificationSender = notificationSender
    }

    var currentState: AnalysisRuntimeState {
        runtimeState
    }

    var isAcceptingAppends: Bool {
        activeAnalysisRun?.isAcceptingAppends ?? false
    }

    @discardableResult
    func appendPendingScreenshots(_ screenshots: [ScreenshotFileRecord]) -> Int {
        guard let run = activeAnalysisRun else { return 0 }
        let appendedCount = run.appendMissingScreenshots(screenshots)
        guard appendedCount > 0 else { return 0 }
        updateRuntimeState(startedAt: run.startedAt, modelName: run.settings.modelName,
                           completedCount: run.completedCount, totalCount: run.totalCount)
        return appendedCount
    }

    func execute(
        trigger: AnalysisTrigger,
        pendingScreenshots: [ScreenshotFileRecord],
        prompt: String
    ) {
        guard !pendingScreenshots.isEmpty else { return }

        let snapshot = settingsStore.snapshot
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let previousAnalysisResultDayStarts = previousAnalysisResultDayStarts(
            before: pendingScreenshots.map(\.capturedAt).min(),
            calendar: calendar
        )

        let runID: Int64
        do {
            runID = try database.createAnalysisRun(
                modelName: snapshot.modelName,
                totalItems: pendingScreenshots.count
            )
        } catch {
            logStore.addError(source: .analysis, context: "Failed to create analysis run", error: error)
            onRunResult?(AnalysisRunResult(
                trigger: trigger,
                successCount: 0,
                failureCount: pendingScreenshots.count,
                inputMeanTokens: nil,
                inputMaxTokens: nil,
                outputMeanTokens: nil,
                outputMaxTokens: nil,
                averageItemDurationSeconds: nil,
                errorMessage: nil,
                affectedDayStarts: [],
                dailyReportCandidateDayStarts: [],
                wasCancelled: false
            ))
            return
        }

        let run = ActiveAnalysisRun(
            id: runID,
            settings: snapshot,
            prompt: prompt,
            screenshots: pendingScreenshots,
            trigger: trigger,
            previousAnalysisResultDayStarts: previousAnalysisResultDayStarts
        )
        activeAnalysisRun = run
        updateRuntimeState(
            startedAt: run.startedAt,
            modelName: snapshot.modelName,
            completedCount: run.completedCount,
            totalCount: run.totalCount
        )

        runningTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.runAnalysis(for: run)
            self.runningTask = nil
            self.onRunResult?(result)
        }
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
            stoppingStage: .stoppingGeneration,
            isLoadingModel: false
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

    func forceUnloadManagedModel() async throws -> Bool {
        let snapshot = settingsStore.snapshot.screenshotAnalysisModelProfile
        guard snapshot.provider == .lmStudio else { return false }
        if runtimeState.isRunning {
            cancelCurrentRun()
            await waitForAnalysisToStop()
        }
        do {
            try await lmStudioLifecycle.unload(settings: snapshot, instanceID: nil)
            return true
        } catch LMStudioModelLifecycleError.missingLoadedInstanceID {
            logStore.add(level: .log, source: .lmStudio, message: L10n.string(.menuForceUnloadNoLoadedModel, language: settingsStore.appLanguage))
            return false
        } catch {
            logStore.addError(source: .lmStudio, context: "Forced unload of screenshot analysis model failed", error: error)
            throw error
        }
    }

    private func runAnalysis(for run: ActiveAnalysisRun) async -> AnalysisRunResult {
        let snapshot = run.settings
        let reportCalendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        lastLMStudioModelInstanceID = nil
        activeRunSettings = snapshot
        defer {
            activeRunSettings = nil
            activeAnalysisRun = nil
            runtimeState = .idle
        }

        if snapshot.validCategoryRules.isEmpty {
            finishAnalysisRun(id: run.id, status: "failed", successCount: 0, failureCount: run.totalCount,
                              errorMessage: localized(.analysisNeedsCategoryRule, language: snapshot.appLanguage))
            run.failureCount = run.totalCount
            return AnalysisRunResult(trigger: .manual, successCount: 0, failureCount: run.totalCount,
                                     inputMeanTokens: nil, inputMaxTokens: nil,
                                     outputMeanTokens: nil, outputMaxTokens: nil,
                                     averageItemDurationSeconds: nil, errorMessage: "No valid category rules",
                                     affectedDayStarts: [], dailyReportCandidateDayStarts: [], wasCancelled: false)
        }

        if snapshot.provider.requiresRemoteConfiguration {
            if snapshot.apiBaseURL.isEmpty {
                finishAnalysisRun(id: run.id, status: "failed", successCount: 0, failureCount: run.totalCount,
                                  errorMessage: localized(.analysisNeedsBaseURL, language: snapshot.appLanguage))
                run.failureCount = run.totalCount
                return AnalysisRunResult(trigger: .manual, successCount: 0, failureCount: run.totalCount,
                                         inputMeanTokens: nil, inputMaxTokens: nil,
                                         outputMeanTokens: nil, outputMaxTokens: nil,
                                         averageItemDurationSeconds: nil, errorMessage: "No base URL",
                                         affectedDayStarts: [], dailyReportCandidateDayStarts: [], wasCancelled: false)
            }
            if snapshot.modelName.isEmpty {
                finishAnalysisRun(id: run.id, status: "failed", successCount: 0, failureCount: run.totalCount,
                                  errorMessage: localized(.analysisNeedsModelName, language: snapshot.appLanguage))
                run.failureCount = run.totalCount
                return AnalysisRunResult(trigger: .manual, successCount: 0, failureCount: run.totalCount,
                                         inputMeanTokens: nil, inputMaxTokens: nil,
                                         outputMeanTokens: nil, outputMaxTokens: nil,
                                         averageItemDurationSeconds: nil, errorMessage: "No model name",
                                         affectedDayStarts: [], dailyReportCandidateDayStarts: [], wasCancelled: false)
            }
        }

        let loadedAnalysisModel: LMStudioLoadedModel?
        do {
            loadedAnalysisModel = try await loadModelIfNeeded(for: snapshot.screenshotAnalysisModelProfile)
        } catch {
            let memoryError = error as? ModelMemoryError
            if memoryError == nil, Self.shouldRecordRuntimeError(error) {
                logStore.addError(source: .analysis, context: "Failed to load screenshot analysis model", error: error)
            }
            finishAnalysisRun(id: run.id, status: "failed", successCount: 0, failureCount: run.totalCount,
                              errorMessage: error.localizedDescription)
            run.failureCount = run.totalCount
            if let memoryError {
                Task { @MainActor [weak self] in
                    await self?.notificationSender.send(
                        AppNotificationMessageBuilder.modelMemoryInsufficient(
                            runTypeName: L10n.string(.settingsTabScreenshotAnalysis, language: snapshot.appLanguage),
                            thresholdGB: memoryError.thresholdGB,
                            availableGB: memoryError.availableGB,
                            language: snapshot.appLanguage
                        )
                    )
                }
            }
            return AnalysisRunResult(trigger: .manual, successCount: 0, failureCount: run.totalCount,
                                     inputMeanTokens: nil, inputMaxTokens: nil,
                                     outputMeanTokens: nil, outputMaxTokens: nil,
                                     averageItemDurationSeconds: nil, errorMessage: error.localizedDescription,
                                     affectedDayStarts: [], dailyReportCandidateDayStarts: [], wasCancelled: false)
        }

        recordLMStudioCancellationObservationIfNeeded(for: run, snapshot: snapshot)

        while true {
            while let screenshot = run.nextScreenshot() {
                if Task.isCancelled {
                    recordLMStudioCancellationObservationIfNeeded(for: run, snapshot: snapshot)
                    run.wasCancelled = true
                    break
                }

                if !FileManager.default.fileExists(atPath: screenshot.url.path) {
                    logStore.add(level: .log, source: .analysis, message: "Pending screenshot no longer exists: \(screenshot.url.path)")
                    run.failureCount += 1
                    run.consecutiveFailureCount += 1
                    run.completedCount += 1
                    updateRuntimeState(startedAt: run.startedAt, modelName: snapshot.modelName,
                                       completedCount: run.completedCount, totalCount: run.totalCount)
                    if Self.shouldPauseAfterConsecutiveFailures(run.consecutiveFailureCount) {
                        run.wasPausedAfterFailures = true
                        break
                    }
                    continue
                }

                let shouldMeasureDuration = run.completedCount > 0
                let itemStartTime = shouldMeasureDuration ? Date() : nil

                do {
                    let result = try await analysisWorker.analyzeImageDetailed(at: screenshot.url, settings: snapshot, prompt: run.prompt)
                    recordLMStudioModelInstanceIfNeeded(result.modelInstanceID, provider: snapshot.provider)
                    let response = result.response

                    _ = try database.insertAnalysisResult(
                        capturedAt: screenshot.capturedAt,
                        categoryName: response.category,
                        summaryText: response.summary,
                        durationMinutesSnapshot: screenshot.durationMinutes
                    )
                    run.recordProcessedAnalysisResult(for: screenshot, calendar: reportCalendar)
                    run.successCount += 1
                    run.consecutiveFailureCount = 0
                    run.recordTokenUsage(from: result.tokenUsage)
                    removeProcessedScreenshot(at: screenshot.url)
                    NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        recordLMStudioCancellationObservationIfNeeded(for: run, snapshot: snapshot)
                        run.wasCancelled = true
                        break
                    }
                    if Self.shouldRecordRuntimeError(error) {
                        logStore.addError(source: .analysis, context: "Failed to analyze screenshot \(screenshot.url.lastPathComponent)", error: error)
                    }
                    if Self.shouldRemoveFailedScreenshot(after: error) {
                        removeProcessedScreenshot(at: screenshot.url)
                        NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
                    }
                    run.failureCount += 1
                    run.consecutiveFailureCount += 1
                }

                if let itemStartTime {
                    run.measuredDurationTotal += Date().timeIntervalSince(itemStartTime)
                    run.measuredItemCount += 1
                }
                run.completedCount += 1
                updateRuntimeState(startedAt: run.startedAt, modelName: snapshot.modelName,
                                   completedCount: run.completedCount, totalCount: run.totalCount)
                if Self.shouldPauseAfterConsecutiveFailures(run.consecutiveFailureCount) {
                    run.wasPausedAfterFailures = true
                    break
                }
                await Task.yield()
            }

            if run.wasCancelled || run.wasPausedAfterFailures { break }
            if await waitForAdditionalScreenshots(to: run) { continue }
            if Task.isCancelled {
                recordLMStudioCancellationObservationIfNeeded(for: run, snapshot: snapshot)
                run.wasCancelled = true
                break
            }
            run.isAcceptingAppends = false
            break
        }

        run.isAcceptingAppends = false

        let affectedDayStarts = Self.affectedDayStarts(from: run.screenshots, calendar: reportCalendar)
        let dailyReportCandidateDayStarts = run.dailyReportCandidateDayStarts(calendar: reportCalendar)
        let result = finalizeRun(run: run, snapshot: snapshot, loadedAnalysisModel: loadedAnalysisModel, reportCalendar: reportCalendar,
                                 affectedDayStarts: affectedDayStarts, dailyReportCandidateDayStarts: dailyReportCandidateDayStarts)

        await unloadModelIfNeeded(for: snapshot.screenshotAnalysisModelProfile, loadedInstanceID: loadedAnalysisModel?.instanceID, cancelActiveRequest: run.wasCancelled)
        return result
    }

    private func finalizeRun(
        run: ActiveAnalysisRun,
        snapshot: AppSettingsSnapshot,
        loadedAnalysisModel: LMStudioLoadedModel?,
        reportCalendar: Calendar,
        affectedDayStarts: Set<Date>,
        dailyReportCandidateDayStarts: Set<Date>
    ) -> AnalysisRunResult {
        if run.wasCancelled {
            finishAnalysisRun(id: run.id, status: "cancelled", successCount: run.successCount, failureCount: run.failureCount,
                              inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                              outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                              averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                              errorMessage: localized(.analysisCancelledByUser, language: snapshot.appLanguage))
            return AnalysisRunResult(trigger: .manual, successCount: run.successCount, failureCount: run.failureCount,
                                     inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                                     outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                                     averageItemDurationSeconds: nil, errorMessage: nil,
                                     affectedDayStarts: [], dailyReportCandidateDayStarts: [], wasCancelled: true)
        }

        if run.wasPausedAfterFailures {
            let message = localized(.analysisPausedAfterFailures, language: snapshot.appLanguage)
            let finalStatus = run.successCount > 0 ? "partial_failed" : "failed"
            finishAnalysisRun(id: run.id, status: finalStatus, successCount: run.successCount, failureCount: run.failureCount,
                              inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                              outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                              averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                              errorMessage: message)
            return AnalysisRunResult(trigger: .manual, successCount: run.successCount, failureCount: run.failureCount,
                                     inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                                     outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                                     averageItemDurationSeconds: nil, errorMessage: message,
                                     affectedDayStarts: affectedDayStarts, dailyReportCandidateDayStarts: dailyReportCandidateDayStarts, wasCancelled: false)
        }

        let finalStatus: String
        if run.successCount == 0 && run.failureCount > 0 {
            finalStatus = "failed"
        } else if run.failureCount > 0 {
            finalStatus = "partial_failed"
        } else {
            finalStatus = "succeeded"
        }

        finishAnalysisRun(id: run.id, status: finalStatus, successCount: run.successCount, failureCount: run.failureCount,
                          inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                          outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                          averageItemDurationSeconds: run.measuredItemCount > 0 ? run.measuredDurationTotal / Double(run.measuredItemCount) : nil,
                          errorMessage: run.failureCount > 0 ? localized(.analysisPartialFailures, language: snapshot.appLanguage) : nil)

        return AnalysisRunResult(trigger: .manual, successCount: run.successCount, failureCount: run.failureCount,
                                 inputMeanTokens: run.inputMeanTokens, inputMaxTokens: run.inputMaxTokens,
                                 outputMeanTokens: run.outputMeanTokens, outputMaxTokens: run.outputMaxTokens,
                                 averageItemDurationSeconds: nil, errorMessage: nil,
                                 affectedDayStarts: affectedDayStarts, dailyReportCandidateDayStarts: dailyReportCandidateDayStarts, wasCancelled: false)
    }

    private func loadModelIfNeeded(for settings: ModelProfileSettings) async throws -> LMStudioLoadedModel? {
        guard settings.provider == .lmStudio, settings.explicitLoadUnloadModel else { return nil }
        if Task.isCancelled { throw CancellationError() }

        if settings.memoryCheckEnabled, settings.isLocalBaseURL,
           !SystemMemoryInfo.isAboveThreshold(thresholdGB: settings.memoryThresholdGB) {
            let available = SystemMemoryInfo.currentAvailableGB ?? 0
            throw ModelMemoryError.insufficientMemory(thresholdGB: settings.memoryThresholdGB, availableGB: available)
        }

        if runtimeState.isRunning, !runtimeState.isStopping {
            updateRuntimeState(startedAt: runtimeState.startedAt, modelName: settings.modelName,
                               completedCount: runtimeState.completedCount, totalCount: runtimeState.totalCount,
                               isLoadingModel: true)
        }

        do {
            let loadedModel = try await lmStudioLifecycle.load(settings: settings)
            clearLoadingModelStateIfNeeded(modelName: settings.modelName)
            return loadedModel
        } catch {
            clearLoadingModelStateIfNeeded(modelName: settings.modelName)
            throw error
        }
    }

    private func unloadModelIfNeeded(for settings: ModelProfileSettings, loadedInstanceID: String?, cancelActiveRequest: Bool) async {
        if settings.provider == .lmStudio, settings.explicitLoadUnloadModel {
            let lastInstanceID = lastLMStudioModelInstanceID ?? "未记录"
            recordLMStudioLog(
                chinese: "进入 LM Studio 清理阶段，最近一次 chat 的 model_instance_id=\(lastInstanceID)。",
                english: "Entering LM Studio cleanup. Last chat model_instance_id=\(lastInstanceID)."
            )
        }
        if cancelActiveRequest {
            llmService.cancelActiveRemoteRequest()
        }
        guard settings.provider == .lmStudio, settings.explicitLoadUnloadModel else { return }
        do {
            try await lmStudioLifecycle.unload(settings: settings, instanceID: loadedInstanceID)
        } catch {
            logStore.addError(source: .lmStudio, context: "LM Studio model unload failed", error: error)
        }
    }

    private func previousAnalysisResultDayStarts(before date: Date?, calendar: Calendar) -> Set<Date> {
        guard let date else { return [] }
        do {
            guard let previousResult = try database.fetchLatestReportActivityItem(before: date) else { return [] }
            return ActiveAnalysisRun.dayStarts(from: previousResult.capturedAt, endAt: previousResult.endAt, calendar: calendar)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to fetch previous analysis result for realtime summary boundary", error: error)
            return []
        }
    }

    private func waitForAdditionalScreenshots(to run: ActiveAnalysisRun) async -> Bool {
        let checkInterval: TimeInterval = 0.1
        for _ in 0..<20 {
            if Task.isCancelled { return false }
            if run.hasRemainingScreenshots { return true }
            try? await Task.sleep(for: .milliseconds(Int(checkInterval * 1000)))
        }
        return run.hasRemainingScreenshots
    }

    private func waitForAnalysisToStop(timeoutSeconds: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while runtimeState.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishAnalysisRun(id: Int64, status: String, successCount: Int, failureCount: Int,
                                   inputMeanTokens: Double? = nil, inputMaxTokens: Int? = nil,
                                   outputMeanTokens: Double? = nil, outputMaxTokens: Int? = nil,
                                   averageItemDurationSeconds: Double? = nil, errorMessage: String? = nil) {
        do {
            try database.finishAnalysisRun(id: id, status: status, successCount: successCount, failureCount: failureCount,
                                           inputMeanTokens: inputMeanTokens, inputMaxTokens: inputMaxTokens,
                                           outputMeanTokens: outputMeanTokens, outputMaxTokens: outputMaxTokens,
                                           averageItemDurationSeconds: averageItemDurationSeconds, errorMessage: errorMessage)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to finish analysis run \(id)", error: error)
        }
    }

    private func removeProcessedScreenshot(at fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to remove processed screenshot \(fileURL.lastPathComponent)", error: error)
        }
    }

    private func updateRuntimeState(
        startedAt: Date?, modelName: String?, completedCount: Int, totalCount: Int,
        stoppingStage: AnalysisStoppingStage? = nil, isLoadingModel: Bool? = nil
    ) {
        runtimeState = AnalysisRuntimeState(
            isRunning: true,
            stoppingStage: stoppingStage ?? runtimeState.stoppingStage,
            isLoadingModel: isLoadingModel ?? runtimeState.isLoadingModel,
            startedAt: startedAt,
            modelName: modelName ?? runtimeState.modelName,
            completedCount: completedCount,
            totalCount: totalCount
        )
    }

    private func clearLoadingModelStateIfNeeded(modelName: String?) {
        guard runtimeState.isRunning, runtimeState.isLoadingModel, !runtimeState.isStopping else { return }
        updateRuntimeState(startedAt: runtimeState.startedAt, modelName: modelName,
                           completedCount: runtimeState.completedCount, totalCount: runtimeState.totalCount,
                           isLoadingModel: false)
    }

    private func recordLMStudioModelInstanceIfNeeded(_ modelInstanceID: String?, provider: ModelProvider) {
        guard provider == .lmStudio, let modelInstanceID, !modelInstanceID.isEmpty else { return }
        lastLMStudioModelInstanceID = modelInstanceID
        recordLMStudioLog(
            chinese: "LM Studio chat 返回 model_instance_id=\(modelInstanceID)。",
            english: "LM Studio chat returned model_instance_id=\(modelInstanceID)."
        )
    }

    private func recordLMStudioCancellationObservationIfNeeded(for run: ActiveAnalysisRun, snapshot: AppSettingsSnapshot) {
        guard snapshot.screenshotAnalysisModelProfile.provider == .lmStudio,
              snapshot.screenshotAnalysisModelProfile.explicitLoadUnloadModel,
              !run.didLogLMStudioCancellationObservation else { return }
        run.didLogLMStudioCancellationObservation = true
        recordLMStudioLog(
            chinese: "分析循环检测到取消，准备进入 LM Studio 清理阶段。",
            english: "Analysis loop observed cancellation and is entering LM Studio cleanup."
        )
    }

    private func recordLMStudioLog(chinese: String, english: String) {
        let message: String
        switch settingsStore.appLanguage {
        case .simplifiedChinese: message = chinese
        case .english: message = english
        }
        logStore.add(level: .log, source: .lmStudio, message: message)
    }

    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private static func affectedDayStarts(from screenshots: [ScreenshotFileRecord], calendar: Calendar) -> Set<Date> {
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
                guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: currentDayStart) else { break }
                currentDayStart = nextDayStart
            }
        }
        return dayStarts
    }
}

extension AnalysisRunExecutor {
    nonisolated static func shouldPauseAfterConsecutiveFailures(_ failureCount: Int, threshold: Int = 5) -> Bool {
        failureCount >= threshold
    }

    nonisolated static func shouldRecordRuntimeError(_ error: Error) -> Bool {
        switch error {
        case is CancellationError: return false
        case AnalysisServiceError.invalidConfiguration: return false
        case AnalysisServiceError.invalidResponse, AnalysisServiceError.httpError,
             AnalysisServiceError.lengthTruncated, AnalysisServiceError.invalidImageData,
             is LMStudioModelLifecycleError, is URLError: return true
        default: return false
        }
    }

    nonisolated static func shouldRemoveFailedScreenshot(after error: Error) -> Bool {
        if case AnalysisServiceError.invalidImageData = error { return true }
        return false
    }

    nonisolated static func stoppingStageAfterGenerationStops(
        for provider: ModelProvider,
        lifecycleEnabled: Bool = true
    ) -> AnalysisStoppingStage? {
        guard provider == .lmStudio, lifecycleEnabled else { return nil }
        return .unloadingModel
    }
}
