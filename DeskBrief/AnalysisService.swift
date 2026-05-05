import AppKit
import Foundation
import FoundationModels

enum AnalysisServiceError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case lengthTruncated(String)
    case invalidImageData(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .invalidResponse(let message): return message
        case .httpError(let statusCode, let body): return L10n.string(.analysisHTTPError, arguments: [statusCode, body])
        case .lengthTruncated(let message): return message
        case .invalidImageData(let message): return message
        }
    }
}

@MainActor
final class AnalysisService {
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let dailyReportSummaryService: DailyReportSummaryService
    private let runCoordinator: AppRunCoordinator
    private let scheduler: AnalysisScheduler
    private let executor: AnalysisRunExecutor
    private let llmService: LLMService
    private let analysisWorker: AnalysisWorker
    private let notificationSender: AppNotificationSending

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore,
        dailyReportSummaryService: DailyReportSummaryService,
        session: URLSession? = nil,
        runCoordinator: AppRunCoordinator? = nil,
        notificationSender: AppNotificationSending? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.dailyReportSummaryService = dailyReportSummaryService
        self.runCoordinator = runCoordinator ?? dailyReportSummaryService.runCoordinator
        self.notificationSender = notificationSender ?? NoOpAppNotificationService()

        let resolvedSession = session ?? Self.makeIsolatedSession()
        self.llmService = LLMService(session: resolvedSession)
        self.analysisWorker = AnalysisWorker(llmService: self.llmService)

        let lmStudioLifecycle = LMStudioModelLifecycle(session: resolvedSession) { [weak settingsStore, weak logStore] chinese, english in
            Task { @MainActor in
                guard let logStore else { return }
                let language = settingsStore?.appLanguage ?? .current
                let message = language == .simplifiedChinese ? chinese : english
                logStore.add(level: .log, source: .lmStudio, message: message)
            }
        }

        self.scheduler = AnalysisScheduler(
            database: database,
            settingsStore: settingsStore,
            logStore: logStore,
            notificationSender: self.notificationSender
        )

        self.executor = AnalysisRunExecutor(
            database: database,
            settingsStore: settingsStore,
            logStore: logStore,
            llmService: self.llmService,
            analysisWorker: self.analysisWorker,
            lmStudioLifecycle: lmStudioLifecycle,
            notificationSender: self.notificationSender
        )

        self.runCoordinator.startAnalysisHandler = { [weak self] trigger in
            self?.startAnalysisFromCoordinator(trigger: trigger)
        }

        setupExecutorCallbacks()
    }

    private func setupExecutorCallbacks() {
        scheduler.onTrigger = { [weak self] trigger in
            self?.triggerAnalysis(trigger: trigger)
        }

        executor.onStateChange = { [weak self] _ in
            NotificationCenter.default.post(name: .analysisStatusDidChange, object: nil)
        }

        executor.onRunResult = { [weak self] result in
            guard let self else { return }
            self.handleRunResult(result)
        }
    }

    func start() {
        scheduler.start()
    }

    func reschedule() {
        scheduler.reschedule()
        // If rescheduled to non-realtime mode and executor hasn't started its own cleanup
    }

    func runNow() {
        let snapshot = settingsStore.snapshot
        guard !snapshot.validCategoryRules.isEmpty else { return }
        let pendingScreenshots = pendingScreenshotFiles()
        guard !pendingScreenshots.isEmpty else { return }

        let trigger = AnalysisTrigger.manual
        let canMerge = executor.currentState.isRunning && executor.isAcceptingAppends
        switch runCoordinator.requestAnalysis(trigger: trigger, canMergeWithActiveAnalysis: canMerge) {
        case .startNow:
            beginAnalysisRun(trigger: trigger, pendingScreenshots: pendingScreenshots)
        case .mergeIntoCurrentRun:
            executor.appendPendingScreenshots(pendingScreenshots)
        case .queued:
            break
        }
    }

    func cancelCurrentRun() {
        executor.cancelCurrentRun()
    }

    var currentState: AnalysisRuntimeState {
        executor.currentState
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
        let lmStudioLifecycleForTest = LMStudioModelLifecycle(session: Self.makeIsolatedSession())
        do {
            loadedModel = try await loadScreenshotAnalysisModelIfNeeded(
                for: snapshot.screenshotAnalysisModelProfile,
                lifecycle: lmStudioLifecycleForTest
            )
            let result = try await analysisWorker.analyzeImageDetailed(at: imageFileURL, settings: snapshot, prompt: prompt)

            if let loadedModel {
                await unloadModelAfterSettingsTest(
                    settings: snapshot.screenshotAnalysisModelProfile,
                    instanceID: loadedModel.instanceID,
                    lifecycle: lmStudioLifecycleForTest
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
                    instanceID: loadedModel.instanceID,
                    lifecycle: lmStudioLifecycleForTest
                )
            }
            if AnalysisRunExecutor.shouldRecordRuntimeError(error) {
                logStore.addError(source: .analysis, context: "Failed to test screenshot analysis settings", error: error)
            }
            throw error
        }
    }

    func checkRealtimeAnalysisBacklogNow() async {
        await scheduler.checkRealtimeAnalysisBacklogNow()
    }

    func forceUnloadManagedModel() async throws -> Bool {
        try await executor.forceUnloadManagedModel()
    }

    private func triggerAnalysis(trigger: AnalysisTrigger) {
        guard canRunAnalysisTrigger(trigger) else {
            if trigger == .scheduled { scheduler.start() }
            return
        }

        let canMerge = executor.currentState.isRunning && executor.isAcceptingAppends
        switch runCoordinator.requestAnalysis(trigger: trigger, canMergeWithActiveAnalysis: canMerge) {
        case .startNow:
            beginAnalysisRun(trigger: trigger)
        case .mergeIntoCurrentRun:
            let pending = pendingScreenshotFiles()
            executor.appendPendingScreenshots(pending)
        case .queued:
            break
        }
    }

    private func startAnalysisFromCoordinator(trigger: AnalysisTrigger) {
        guard canRunAnalysisTrigger(trigger) else {
            if trigger == .scheduled { scheduler.start() }
            runCoordinator.finishRun(.screenshotAnalysis)
            return
        }
        beginAnalysisRun(trigger: trigger)
    }

    private func canRunAnalysisTrigger(_ trigger: AnalysisTrigger) -> Bool {
        if AnalysisService.shouldSkipForChargerRequirement(
            trigger: trigger,
            requiresCharger: settingsStore.snapshot.autoAnalysisRequiresCharger,
            devicePowerState: DevicePowerState.current()
        ) {
            return false
        }
        return true
    }

    private func beginAnalysisRun(trigger: AnalysisTrigger, pendingScreenshots: [ScreenshotFileRecord]? = nil) {
        if executor.currentState.isRunning && executor.isAcceptingAppends {
            let screenshots = pendingScreenshots ?? pendingScreenshotFiles()
            executor.appendPendingScreenshots(screenshots)
            return
        }

        let snapshot = settingsStore.snapshot
        let screenshots = pendingScreenshots ?? pendingScreenshotFiles()
        guard !screenshots.isEmpty else {
            if trigger == .scheduled { scheduler.start() }
            runCoordinator.finishRun(.screenshotAnalysis)
            return
        }

        let prompt = currentPrompt()
        executor.execute(trigger: trigger, pendingScreenshots: screenshots, prompt: prompt)
    }

    private func handleRunResult(_ result: AnalysisRunResult) {
        scheduler.start()

        let snapshot = settingsStore.snapshot
        let analysisSettings = snapshot.screenshotAnalysisModelProfile
        let summarySettings = snapshot.workContentSummaryModelProfile

        let analysisLifecycleEnabled = analysisSettings.provider == .lmStudio && analysisSettings.explicitLoadUnloadModel
        let summaryLifecycleEnabled = summarySettings.provider == .lmStudio && summarySettings.explicitLoadUnloadModel
        let equivalentLoadConfiguration = LMStudioAPI.hasEquivalentLoadConfiguration(analysisSettings, summarySettings)
        let canReuseAnalysisModel = analysisLifecycleEnabled
            && summarySettings.provider == .lmStudio
            && equivalentLoadConfiguration
            && !result.wasCancelled

        let notificationContext = AnalysisCompletionNotificationContext(
            trigger: result.trigger,
            successfulScreenshotCount: result.successCount,
            failedScreenshotCount: result.failureCount
        )
        let notificationIntent: DailyReportSummaryNotificationIntent
        if result.dailyReportCandidateDayStarts.isEmpty {
            notificationIntent = .none
            sendCompletionNotification(context: notificationContext, dailyReportDayStarts: [], language: snapshot.appLanguage)
        } else {
            notificationIntent = .analysisCompletion(notificationContext)
        }

        let lmStudioPolicy: DailyReportLMStudioLifecyclePolicy = (summaryLifecycleEnabled && !canReuseAnalysisModel)
            ? .loadForSummaryThenUnload
            : .reuseAlreadyLoadedModelAndKeepLoaded

        dailyReportSummaryService.enqueueSummariesAfterAnalysis(
            workBlockDayStarts: result.affectedDayStarts,
            dailyReportCandidateDayStarts: result.dailyReportCandidateDayStarts,
            lmStudioLifecyclePolicy: lmStudioPolicy,
            notificationIntent: notificationIntent
        )

        runCoordinator.finishRun(.screenshotAnalysis)
    }

    private func sendCompletionNotification(
        context: AnalysisCompletionNotificationContext,
        dailyReportDayStarts: [Date],
        summaryFailed: Bool = false,
        language: AppLanguage
    ) {
        Task { @MainActor [weak self] in
            guard let message = AppNotificationMessageBuilder.analysisCompletion(
                context: context,
                dailyReportDayStarts: dailyReportDayStarts,
                summaryFailed: summaryFailed,
                language: language
            ) else { return }
            await self?.notificationSender.send(message)
        }
    }

    private var activeAnalysisRunIsAcceptingAppends: Bool {
        executor.isAcceptingAppends
    }

    private func pendingScreenshotFiles() -> [ScreenshotFileRecord] {
        do {
            return try database.listScreenshotFiles(defaultDurationMinutes: settingsStore.snapshot.screenshotIntervalMinutes)
        } catch {
            logStore.addError(source: .analysis, context: "Failed to list pending screenshot files", error: error)
            return []
        }
    }

    private func buildPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage
    ) -> String {
        L10n.analysisPrompt(with: rules, summaryInstruction: summaryInstruction, language: language)
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

    private func loadScreenshotAnalysisModelIfNeeded(
        for settings: ModelProfileSettings,
        lifecycle: LMStudioModelLifecycle
    ) async throws -> LMStudioLoadedModel? {
        guard settings.provider == .lmStudio, settings.explicitLoadUnloadModel else { return nil }
        if Task.isCancelled { throw CancellationError() }
        return try await lifecycle.load(settings: settings)
    }

    private func unloadModelAfterSettingsTest(
        settings: ModelProfileSettings,
        instanceID: String?,
        lifecycle: LMStudioModelLifecycle
    ) async {
        do {
            try await lifecycle.unload(settings: settings, instanceID: instanceID)
        } catch {
            logStore.addError(source: .lmStudio, context: "Failed to unload LM Studio model after settings test", error: error)
        }
    }

    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }
}

extension AnalysisService {
    nonisolated static func shouldSkipForChargerRequirement(
        trigger: AnalysisTrigger,
        requiresCharger: Bool,
        devicePowerState: DevicePowerState
    ) -> Bool {
        shouldSkipForChargerRequirement(
            trigger: trigger,
            requiresCharger: requiresCharger,
            hasInternalBattery: devicePowerState.hasInternalBattery,
            isConnectedToCharger: devicePowerState.isConnectedToCharger
        )
    }

    nonisolated static func shouldSkipForChargerRequirement(
        trigger: AnalysisTrigger,
        requiresCharger: Bool,
        hasInternalBattery: Bool = true,
        isConnectedToCharger: Bool
    ) -> Bool {
        let usesChargerRequirement: Bool
        switch trigger {
        case .manual: usesChargerRequirement = false
        case .scheduled, .realtime: usesChargerRequirement = true
        }
        return usesChargerRequirement && requiresCharger && hasInternalBattery && !isConnectedToCharger
    }

    nonisolated static func shouldRetryAnalysis(after error: Error, attempt: Int, maxAttempts: Int = 3) -> Bool {
        guard attempt < maxAttempts else { return false }
        switch error {
        case is CancellationError: return false
        case AnalysisServiceError.invalidConfiguration: return false
        case AnalysisServiceError.lengthTruncated: return false
        case AnalysisServiceError.invalidResponse: return true
        case AnalysisServiceError.httpError(let statusCode, _): return statusCode >= 500
        case is URLError: return true
        default: return false
        }
    }

    nonisolated static func extractAnalysisResponse(from rawText: String, validRules: [CategoryRule]) -> AnalysisResponse? {
        let validCategories = Set(validRules.map(\.name))
        let candidates = responseCandidates(from: rawText)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ParsedAnalysisPayload.self, from: data) else { continue }
            let category = payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty, !summary.isEmpty, validCategories.contains(category) else { continue }
            return AnalysisResponse(category: category, summary: summary)
        }
        return nil
    }

    nonisolated static func extractGuidedAnalysisResponse(
        from generatedContent: GeneratedContent,
        validRules: [CategoryRule]
    ) -> AnalysisResponse? {
        let validCategories = Set(validRules.map(\.name))
        guard let category = try? generatedContent.value(String.self, forProperty: "category"),
              let summary = try? generatedContent.value(String.self, forProperty: "summary") else { return nil }
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validCategories.contains(trimmedCategory), !trimmedSummary.isEmpty else { return nil }
        return AnalysisResponse(category: trimmedCategory, summary: trimmedSummary)
    }

    nonisolated private static func responseCandidates(from rawText: String) -> [String] {
        let formalReply = extractFormalReply(from: rawText)
        let orderedCandidates = [formalReply, rawText]
            .map { unwrapCodeFence(from: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var deduplicated: [String] = []
        for candidate in orderedCandidates where !deduplicated.contains(candidate) {
            deduplicated.append(candidate)
        }
        return deduplicated
    }

    nonisolated private static func extractFormalReply(from rawText: String) -> String {
        guard let startRange = rawText.range(of: "<think>") else { return rawText }
        let contentStart = startRange.upperBound
        guard let endRange = rawText.range(of: "</think>", range: contentStart..<rawText.endIndex) else { return "" }
        return String(rawText[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func unwrapCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
