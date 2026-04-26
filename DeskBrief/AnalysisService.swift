import AppKit
import FoundationModels
import Foundation
import ImageIO
import IOKit.ps
import Vision

private final class URLSessionDataTaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}

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

private struct ParsedAnalysisPayload: Decodable {
    let category: String
    let summary: String

    private enum CodingKeys: String, CodingKey {
        case category
        case summary
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(String.self, forKey: .category)
        summary = try container.decode(String.self, forKey: .summary)
    }
}

@MainActor
final class AnalysisService {
    private struct DataRequestResult {
        let data: Data
        let response: URLResponse
        let roundTripSeconds: TimeInterval
    }

    private struct AnalysisExecutionResult {
        let response: AnalysisResponse
        let requestTiming: ModelRequestTiming?
        let lmStudioTiming: LMStudioTiming?
        let ocrText: String?
        let reasoningText: String?
    }
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore
    private let dailyReportSummaryService: DailyReportSummaryService
    private let session: URLSession
    private let llmService: LLMService
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var runningTask: Task<Void, Never>?
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
        self.session = resolvedSession
        self.llmService = LLMService(session: resolvedSession)
    }

    deinit {
        timer?.invalidate()
        runningTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        scheduleNextRun()
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
    }

    func runNow() {
        triggerAnalysis(scheduledFor: Date(), isAutomatic: false)
    }

    func cancelCurrentRun() {
        guard runtimeState.isRunning, !runtimeState.isStopping else { return }
        if activeRunSettings?.provider == .lmStudio {
            recordLMStudioLog(
                chinese: "用户点击了暂停分析。",
                english: "User requested to pause analysis."
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
            summaryInstruction: snapshot.analysisSummaryInstruction,
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
            summaryInstruction: snapshot.analysisSummaryInstruction,
            language: snapshot.appLanguage
        )
        do {
            let result = try await analyzeImageDetailed(at: imageFileURL, settings: snapshot, prompt: prompt)
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
        guard settingsStore.snapshot.automaticAnalysisEnabled else {
            return
        }
        let nextDate = settingsStore.snapshot.nextAnalysisDate(after: Date())
        timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerAnalysis(scheduledFor: nextDate, isAutomatic: true)
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func triggerAnalysis(scheduledFor: Date, isAutomatic: Bool) {
        if isAutomatic,
           settingsStore.snapshot.autoAnalysisRequiresCharger,
           !Self.isConnectedToCharger() {
            scheduleNextRun()
            return
        }

        runningTask?.cancel()
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis(scheduledFor: scheduledFor)
            await MainActor.run {
                self.scheduleNextRun()
            }
        }
    }

    private func runAnalysis(scheduledFor _: Date) async {
        let snapshot = settingsStore.snapshot
        lastLMStudioModelInstanceID = nil
        activeRunSettings = snapshot
        let prompt = buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.analysisSummaryInstruction,
            language: snapshot.appLanguage
        )
        let pendingCaptures = (try? database.listScreenshotFiles(defaultDurationMinutes: snapshot.screenshotIntervalMinutes)) ?? []

        let runID: Int64
        do {
            runID = try database.createAnalysisRun(
                modelName: snapshot.modelName,
                totalItems: pendingCaptures.count
            )
        } catch {
            return
        }

        updateRuntimeState(
            startedAt: pendingCaptures.first?.capturedAt,
            completedCount: 0,
            totalCount: pendingCaptures.count,
            stoppingStage: nil
        )
        defer {
            activeRunSettings = nil
            runtimeState = .idle
        }

        guard !pendingCaptures.isEmpty else {
            try? database.finishAnalysisRun(id: runID, status: "succeeded", successCount: 0, failureCount: 0)
            await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded()
            return
        }

        guard !snapshot.validCategoryRules.isEmpty else {
            try? database.finishAnalysisRun(
                id: runID,
                status: "failed",
                successCount: 0,
                failureCount: pendingCaptures.count,
                errorMessage: localized(.analysisNeedsCategoryRule, language: snapshot.appLanguage)
            )
            return
        }

        if snapshot.provider.requiresRemoteConfiguration {
            guard !snapshot.apiBaseURL.isEmpty else {
                try? database.finishAnalysisRun(
                    id: runID,
                    status: "failed",
                    successCount: 0,
                    failureCount: pendingCaptures.count,
                    errorMessage: localized(.analysisNeedsBaseURL, language: snapshot.appLanguage)
                )
                return
            }

            guard !snapshot.modelName.isEmpty else {
                try? database.finishAnalysisRun(
                    id: runID,
                    status: "failed",
                    successCount: 0,
                    failureCount: pendingCaptures.count,
                    errorMessage: localized(.analysisNeedsModelName, language: snapshot.appLanguage)
                )
                return
            }
        }

        var successCount = 0
        var failureCount = 0
        var completedCount = 0
        var consecutiveFailureCount = 0
        var wasCancelled = false
        var wasPausedAfterFailures = false
        var measuredDurationTotal: TimeInterval = 0
        var measuredItemCount = 0
        var didLogLMStudioCancellationObservation = false

        func recordLMStudioCancellationObservationIfNeeded() {
            guard snapshot.provider == .lmStudio, !didLogLMStudioCancellationObservation else { return }
            didLogLMStudioCancellationObservation = true
            recordLMStudioLog(
                chinese: "分析循环检测到取消，准备进入 LM Studio 清理阶段。",
                english: "Analysis loop observed cancellation and is entering LM Studio cleanup."
            )
        }

        for (index, capture) in pendingCaptures.enumerated() {
            if Task.isCancelled {
                recordLMStudioCancellationObservationIfNeeded()
                wasCancelled = true
                break
            }

            let fileURL = capture.url
            let capturedAt = capture.capturedAt
            let durationMinutes = capture.durationMinutes

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                failureCount += 1
                consecutiveFailureCount += 1
                completedCount += 1
                updateRuntimeState(
                    startedAt: pendingCaptures.first?.capturedAt,
                    completedCount: completedCount,
                    totalCount: pendingCaptures.count
                )
                if Self.shouldPauseAfterConsecutiveFailures(consecutiveFailureCount) {
                    wasPausedAfterFailures = true
                    break
                }
                continue
            }

            let shouldMeasureDuration = index > 0
            let itemStartTime = shouldMeasureDuration ? Date() : nil

            do {
                let response = try await analyzeImage(
                    at: fileURL,
                    settings: snapshot,
                    prompt: prompt
                )

                try database.insertAnalysisResult(
                    capturedAt: capturedAt,
                    categoryName: response.category,
                    summaryText: response.summary,
                    durationMinutesSnapshot: durationMinutes
                )

                successCount += 1
                consecutiveFailureCount = 0
                try? FileManager.default.removeItem(at: fileURL)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    recordLMStudioCancellationObservationIfNeeded()
                    wasCancelled = true
                    break
                }

                let message = error.localizedDescription
                if Self.shouldRecordRuntimeError(error) {
                    logStore.add(level: .error, source: .analysis, message: message)
                }
                failureCount += 1
                consecutiveFailureCount += 1
            }

            if let itemStartTime {
                measuredDurationTotal += Date().timeIntervalSince(itemStartTime)
                measuredItemCount += 1
            }

            completedCount += 1
            updateRuntimeState(
                startedAt: pendingCaptures.first?.capturedAt,
                completedCount: completedCount,
                totalCount: pendingCaptures.count
            )

            if Self.shouldPauseAfterConsecutiveFailures(consecutiveFailureCount) {
                wasPausedAfterFailures = true
                break
            }
        }

        if wasCancelled {
            try? database.finishAnalysisRun(
                id: runID,
                status: "cancelled",
                successCount: successCount,
                failureCount: failureCount,
                averageItemDurationSeconds: measuredItemCount > 0 ? measuredDurationTotal / Double(measuredItemCount) : nil,
                errorMessage: localized(.analysisCancelledByUser, language: snapshot.appLanguage)
            )
            if let unloadingStage = Self.stoppingStageAfterGenerationStops(for: snapshot.provider) {
                updateRuntimeState(
                    startedAt: pendingCaptures.first?.capturedAt,
                    completedCount: completedCount,
                    totalCount: pendingCaptures.count,
                    stoppingStage: unloadingStage
                )
            }
            await stopModelIfNeeded(for: snapshot)
            return
        }

        if wasPausedAfterFailures {
            let message = localized(.analysisPausedAfterFailures, language: snapshot.appLanguage)
            let finalStatus = successCount > 0 ? "partial_failed" : "failed"
            try? database.finishAnalysisRun(
                id: runID,
                status: finalStatus,
                successCount: successCount,
                failureCount: failureCount,
                averageItemDurationSeconds: measuredItemCount > 0 ? measuredDurationTotal / Double(measuredItemCount) : nil,
                errorMessage: message
            )
            await stopModelIfNeeded(for: snapshot)
            return
        }

        let finalStatus: String
        if successCount == 0 && failureCount > 0 {
            finalStatus = "failed"
        } else if failureCount > 0 {
            finalStatus = "partial_failed"
        } else {
            finalStatus = "succeeded"
        }

        try? database.finishAnalysisRun(
            id: runID,
            status: finalStatus,
            successCount: successCount,
            failureCount: failureCount,
            averageItemDurationSeconds: measuredItemCount > 0 ? measuredDurationTotal / Double(measuredItemCount) : nil,
            errorMessage: failureCount > 0 ? localized(.analysisPartialFailures, language: snapshot.appLanguage) : nil
        )
        await dailyReportSummaryService.summarizeMissingDailyReportsIfNeeded()
        await stopModelIfNeeded(for: snapshot)
    }

    private func buildPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage
    ) -> String {
        L10n.analysisPrompt(with: rules, summaryInstruction: summaryInstruction, language: language)
    }

    private func analyzeImage(
        at fileURL: URL,
        settings: AppSettingsSnapshot,
        prompt: String,
        allowLengthRetry: Bool = true,
        maxAttempts: Int = 3
    ) async throws -> AnalysisResponse {
        try await analyzeImageDetailed(
            at: fileURL,
            settings: settings,
            prompt: prompt,
            allowLengthRetry: allowLengthRetry,
            maxAttempts: maxAttempts
        ).response
    }

    private func analyzeImageDetailed(
        at fileURL: URL,
        settings: AppSettingsSnapshot,
        prompt: String,
        allowLengthRetry: Bool = true,
        maxAttempts: Int = 3
    ) async throws -> AnalysisExecutionResult {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await analyzeImageAttemptDetailed(
                    at: fileURL,
                    settings: settings,
                    prompt: prompt,
                    allowLengthRetry: allowLengthRetry
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }

                lastError = error

                guard Self.shouldRetryAnalysis(after: error, attempt: attempt, maxAttempts: maxAttempts) else {
                    throw error
                }

                try? await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }

        throw lastError ?? AnalysisServiceError.invalidResponse(localized(.analysisInvalidCategory, language: settings.appLanguage))
    }

    private func analyzeImageAttemptDetailed(
        at fileURL: URL,
        settings: AppSettingsSnapshot,
        prompt: String,
        allowLengthRetry: Bool
    ) async throws -> AnalysisExecutionResult {
        let imageData = try Data(contentsOf: fileURL)
        if settings.provider == .appleIntelligence {
            let recognizedText = try recognizedText(from: imageData, language: settings.appLanguage)
            let response = try await analyzeImageWithAppleIntelligence(
                recognizedText: recognizedText,
                validRules: settings.validCategoryRules,
                summaryInstruction: settings.analysisSummaryInstruction,
                language: settings.appLanguage
            )
            return AnalysisExecutionResult(
                response: response,
                requestTiming: nil,
                lmStudioTiming: nil,
                ocrText: recognizedText,
                reasoningText: nil
            )
        }

        let requestPrompt: String
        let requestImageData: Data?
        let ocrText: String?
        switch settings.imageAnalysisMethod {
        case .ocr:
            let recognizedText = try recognizedText(from: imageData, language: settings.appLanguage)
            ocrText = recognizedText
            guard !recognizedText.isEmpty else {
                return AnalysisExecutionResult(
                    response: fallbackOCRResponse(validRules: settings.validCategoryRules, language: settings.appLanguage),
                    requestTiming: nil,
                    lmStudioTiming: nil,
                    ocrText: recognizedText,
                    reasoningText: nil
                )
            }
            requestPrompt = buildOCRAnalysisPrompt(
                validRules: settings.validCategoryRules,
                summaryInstruction: settings.analysisSummaryInstruction,
                recognizedText: recognizedText,
                language: settings.appLanguage
            )
            requestImageData = nil
        case .multimodal:
            requestPrompt = prompt
            requestImageData = imageData
            ocrText = nil
        }

        let llmResponse: LLMServiceResponse
        do {
            llmResponse = try await llmService.send(
                LLMServiceRequest(
                    settings: settings.screenshotAnalysisModelSettings,
                    appLanguage: settings.appLanguage,
                    prompt: requestPrompt,
                    imageData: requestImageData,
                    maximumResponseTokens: 300,
                    timeoutInterval: 120,
                    appleUseCase: .general,
                    appleSchema: nil
                )
            )
        } catch let error as LLMServiceError {
            throw mapLLMServiceError(error, language: settings.appLanguage)
        }

        guard let text = llmResponse.text else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisInvalidCategoryWithText, language: settings.appLanguage))
        }

        if settings.provider == .lmStudio,
           let modelInstanceID = llmResponse.modelInstanceID,
           !modelInstanceID.isEmpty {
            lastLMStudioModelInstanceID = modelInstanceID
            recordLMStudioLog(
                chinese: "LM Studio chat 返回 model_instance_id=\(modelInstanceID)。",
                english: "LM Studio chat returned model_instance_id=\(modelInstanceID)."
            )
        }

        guard let response = Self.extractAnalysisResponse(from: text, validRules: settings.validCategoryRules) else {
            if llmResponse.finishReason == "length", allowLengthRetry {
                let retryPrompt = prompt + "\n\n" + localized(.analysisRetrySupplement, language: settings.appLanguage)
                return try await analyzeImageAttemptDetailed(
                    at: fileURL,
                    settings: settings,
                    prompt: retryPrompt,
                    allowLengthRetry: false
                )
            }
            if llmResponse.finishReason == "length" {
                throw AnalysisServiceError.lengthTruncated(localized(.analysisLengthTruncated, language: settings.appLanguage))
            }
            throw AnalysisServiceError.invalidResponse(
                invalidAnalysisResponseMessage(
                    rawText: text,
                    baseKey: .analysisInvalidCategoryWithText,
                    language: settings.appLanguage
                )
            )
        }

        return AnalysisExecutionResult(
            response: response,
            requestTiming: llmResponse.requestTiming,
            lmStudioTiming: llmResponse.lmStudioTiming,
            ocrText: ocrText,
            reasoningText: llmResponse.reasoningText
        )
    }

    private func analyzeImageWithAppleIntelligence(
        recognizedText: String,
        validRules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage
    ) async throws -> AnalysisResponse {
        guard !recognizedText.isEmpty else {
            return fallbackAppleIntelligenceResponse(validRules: validRules, language: language)
        }

        let applePrompt = L10n.appleIntelligenceAnalysisPrompt(
            with: validRules,
            summaryInstruction: summaryInstruction,
            recognizedText: recognizedText,
            language: language
        )
        let schema = appleIntelligenceAnalysisSchema(validRules: validRules, language: language)
        let llmResponse: LLMServiceResponse
        do {
            llmResponse = try await llmService.send(
                LLMServiceRequest(
                    settings: AnalysisModelSettings(
                        provider: .appleIntelligence,
                        apiBaseURL: "",
                        modelName: "",
                        apiKey: "",
                        lmStudioContextLength: AppDefaults.lmStudioContextLength,
                        imageAnalysisMethod: .ocr
                    ),
                    appLanguage: language,
                    prompt: applePrompt,
                    imageData: nil,
                    maximumResponseTokens: 300,
                    timeoutInterval: 120,
                    appleUseCase: .contentTagging,
                    appleSchema: schema
                )
            )
        } catch let error as LLMServiceError {
            throw mapLLMServiceError(error, language: language)
        }

        guard let rawContent = llmResponse.structuredContent,
              let parsedResponse = Self.extractGuidedAnalysisResponse(
            from: rawContent,
            validRules: validRules
        ) else {
            throw AnalysisServiceError.invalidResponse(
                invalidAnalysisResponseMessage(
                    rawText: llmResponse.rawStructuredText ?? localized(.analysisResponseUnavailable, language: language),
                    baseKey: .analysisInvalidStructuredResponseWithText,
                    language: language
                )
            )
        }

        return parsedResponse
    }

    private func recognizedText(from imageData: Data, language: AppLanguage) throws -> String {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages(for: language)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func recognitionLanguages(for language: AppLanguage) -> [String] {
        switch language {
        case .simplifiedChinese:
            return ["zh-Hans", "en-US"]
        case .english:
            return ["en-US", "zh-Hans"]
        }
    }

    private func fallbackAppleIntelligenceResponse(
        validRules: [CategoryRule],
        language: AppLanguage
    ) -> AnalysisResponse {
        return AnalysisResponse(
            category: fallbackCategoryName(from: validRules),
            summary: localized(.analysisAppleIntelligenceNoOCRTextSummary, language: language)
        )
    }

    private func fallbackOCRResponse(
        validRules: [CategoryRule],
        language: AppLanguage
    ) -> AnalysisResponse {
        AnalysisResponse(
            category: fallbackCategoryName(from: validRules),
            summary: localized(.analysisOCRNoTextSummary, language: language)
        )
    }

    private func fallbackCategoryName(from validRules: [CategoryRule]) -> String {
        validRules.first(where: \.isPreservedOther)?.name
            ?? validRules.first?.name
            ?? AppDefaults.preservedOtherCategoryName
    }

    private func appleIntelligenceAnalysisSchema(
        validRules: [CategoryRule],
        language: AppLanguage
    ) -> GenerationSchema {
        let categoryDescription: String
        let summaryDescription: String

        switch language {
        case .simplifiedChinese:
            categoryDescription = "必须从候选类别中选择一个完全匹配的类别名。"
            summaryDescription = "对截图主要工作内容的简短描述。"
        case .english:
            categoryDescription = "Choose exactly one category name from the candidate list."
            summaryDescription = "A short description of the main work shown in the screenshot."
        }

        return GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                GenerationSchema.Property(
                    name: "category",
                    description: categoryDescription,
                    type: String.self,
                    guides: [.anyOf(validRules.map(\.name))]
                ),
                GenerationSchema.Property(
                    name: "summary",
                    description: summaryDescription,
                    type: String.self
                ),
            ]
        )
    }

    private func buildOCRAnalysisPrompt(
        validRules: [CategoryRule],
        summaryInstruction: String,
        recognizedText: String,
        language: AppLanguage
    ) -> String {
        L10n.apiOCRAnalysisPrompt(
            with: validRules,
            summaryInstruction: summaryInstruction,
            recognizedText: recognizedText,
            language: language
        )
    }

    nonisolated static func extractAnalysisResponse(from rawText: String, validRules: [CategoryRule]) -> AnalysisResponse? {
        let validCategories = Set(validRules.map(\.name))
        let candidates = responseCandidates(from: rawText)

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ParsedAnalysisPayload.self, from: data) else {
                continue
            }

            let category = payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validCategories.contains(category), !summary.isEmpty else {
                continue
            }

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
              let summary = try? generatedContent.value(String.self, forProperty: "summary") else {
            return nil
        }

        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validCategories.contains(trimmedCategory), !trimmedSummary.isEmpty else {
            return nil
        }

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
        guard let startRange = rawText.range(of: "<think>") else {
            return rawText
        }

        let contentStart = startRange.upperBound
        guard let endRange = rawText.range(of: "</think>", range: contentStart..<rawText.endIndex) else {
            return ""
        }

        return String(rawText[endRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func unwrapCodeFence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }

        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty {
            lines.removeFirst()
        }
        if !lines.isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func performDataRequest(for request: URLRequest) async throws -> DataRequestResult {
        let taskBox = URLSessionDataTaskBox()
        let language = settingsStore.appLanguage
        let missingDataMessage = L10n.string(.analysisNoResponseData, language: language)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data, let response else {
                        continuation.resume(throwing: AnalysisServiceError.invalidResponse(missingDataMessage))
                        return
                    }

                    let endedAt = DispatchTime.now().uptimeNanoseconds
                    let elapsedSeconds = TimeInterval(endedAt - startedAt) / 1_000_000_000
                    continuation.resume(
                        returning: DataRequestResult(
                            data: data,
                            response: response,
                            roundTripSeconds: elapsedSeconds
                        )
                    )
                }

                let dataTask = session.dataTask(with: request, completionHandler: completion)
                taskBox.task = dataTask
                dataTask.resume()
            }
        } onCancel: {
            Task { @MainActor [taskBox] in
                taskBox.task?.cancel()
            }
        }
    }

    private func stopModelIfNeeded(for settings: AppSettingsSnapshot) async {
        if settings.provider == .lmStudio {
            let lastInstanceID = lastLMStudioModelInstanceID ?? "未记录"
            recordLMStudioLog(
                chinese: "进入 LM Studio 清理阶段，Task.isCancelled=\(Task.isCancelled)，最近一次 chat 的 model_instance_id=\(lastInstanceID)。",
                english: "Entering LM Studio cleanup. Task.isCancelled=\(Task.isCancelled), last chat model_instance_id=\(lastInstanceID)."
            )
            recordLMStudioLog(
                chinese: "再次向当前 LM Studio 请求发送取消。",
                english: "Sending cancellation to the current LM Studio request again."
            )
        }
        llmService.cancelActiveRemoteRequest()

        guard settings.provider == .lmStudio,
              let modelsURL = LMStudioAPI.modelsURL(from: settings.apiBaseURL) else {
            return
        }

        do {
            recordLMStudioLog(
                chinese: "开始请求 LM Studio /api/v1/models。",
                english: "Requesting LM Studio /api/v1/models."
            )
            let listRequest = makeJSONRequest(url: modelsURL, method: "GET", apiKey: settings.apiKey)
            let result = try await performDataRequest(for: listRequest)
            guard let httpResponse = result.response as? HTTPURLResponse else {
                recordLMStudioLog(
                    chinese: "LM Studio /api/v1/models 未返回有效的 HTTP 响应。",
                    english: "LM Studio /api/v1/models did not return a valid HTTP response."
                )
                return
            }

            let listResponseBody = Self.truncatedDebugText(String(decoding: result.data, as: UTF8.self))
            guard (200..<300).contains(httpResponse.statusCode) else {
                recordLMStudioLog(
                    chinese: "LM Studio /api/v1/models 返回 \(httpResponse.statusCode)，响应：\(listResponseBody)",
                    english: "LM Studio /api/v1/models returned \(httpResponse.statusCode). Body: \(listResponseBody)"
                )
                return
            }

            let modelsCount = LMStudioAPI.modelsCount(from: result.data) ?? 0
            recordLMStudioLog(
                chinese: "LM Studio /api/v1/models 成功，返回 \(modelsCount) 个模型。",
                english: "LM Studio /api/v1/models succeeded and returned \(modelsCount) models."
            )

            guard let instanceID = LMStudioAPI.extractLoadedInstanceID(from: result.data, modelName: settings.modelName) else {
                let lastInstanceID = lastLMStudioModelInstanceID ?? "未记录"
                recordLMStudioLog(
                    chinese: "未能为 modelName=\(settings.modelName) 匹配到已加载实例。最近一次 chat 的 model_instance_id=\(lastInstanceID)。",
                    english: "Could not match a loaded instance for modelName=\(settings.modelName). Last chat model_instance_id=\(lastInstanceID)."
                )
                return
            }

            recordLMStudioLog(
                chinese: "已匹配待卸载实例 \(instanceID)（modelName=\(settings.modelName)）。",
                english: "Matched loaded instance \(instanceID) for modelName=\(settings.modelName)."
            )

            let unloadURL = modelsURL.appendingPathComponent("unload")
            var unloadRequest = makeJSONRequest(url: unloadURL, method: "POST", apiKey: settings.apiKey)
            unloadRequest.httpBody = try JSONSerialization.data(withJSONObject: ["instance_id": instanceID])
            recordLMStudioLog(
                chinese: "开始请求 LM Studio /api/v1/models/unload，instance_id=\(instanceID)。",
                english: "Requesting LM Studio /api/v1/models/unload with instance_id=\(instanceID)."
            )
            let unloadResult = try await performDataRequest(for: unloadRequest)
            guard let unloadHTTPResponse = unloadResult.response as? HTTPURLResponse else {
                recordLMStudioLog(
                    chinese: "LM Studio unload 未返回有效的 HTTP 响应。",
                    english: "LM Studio unload did not return a valid HTTP response."
                )
                return
            }

            let unloadResponseBody = Self.truncatedDebugText(String(decoding: unloadResult.data, as: UTF8.self))
            guard (200..<300).contains(unloadHTTPResponse.statusCode) else {
                recordLMStudioLog(
                    chinese: "LM Studio unload 返回 \(unloadHTTPResponse.statusCode)，响应：\(unloadResponseBody)",
                    english: "LM Studio unload returned \(unloadHTTPResponse.statusCode). Body: \(unloadResponseBody)"
                )
                return
            }

            recordLMStudioLog(
                chinese: "LM Studio unload 成功，instance_id=\(instanceID)。",
                english: "LM Studio unload succeeded for instance_id=\(instanceID)."
            )
        } catch {
            recordLMStudioLog(
                chinese: "LM Studio 清理阶段发生错误：\(error.localizedDescription)",
                english: "LM Studio cleanup failed: \(error.localizedDescription)"
            )
            return
        }
    }

    private func makeJSONRequest(url: URL, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    nonisolated static func shouldPauseAfterConsecutiveFailures(_ failureCount: Int, threshold: Int = 5) -> Bool {
        failureCount >= threshold
    }

    nonisolated static func stoppingStageAfterGenerationStops(for provider: ModelProvider) -> AnalysisStoppingStage? {
        switch provider {
        case .lmStudio:
            return .unloadingModel
        case .openAI, .anthropic, .appleIntelligence:
            return nil
        }
    }

    nonisolated static func shouldRecordRuntimeError(_ error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case AnalysisServiceError.invalidConfiguration:
            return false
        case AnalysisServiceError.invalidResponse,
             AnalysisServiceError.httpError,
             AnalysisServiceError.lengthTruncated,
             is URLError:
            return true
        default:
            return false
        }
    }

    nonisolated static func isConnectedToCharger() -> Bool {
        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSourceType = IOPSGetProvidingPowerSourceType(powerInfo)?.takeUnretainedValue() as String? else {
            return false
        }

        return powerSourceType == kIOPMACPowerKey
    }

    nonisolated static func shouldRetryAnalysis(after error: Error, attempt: Int, maxAttempts: Int = 3) -> Bool {
        guard attempt < maxAttempts else {
            return false
        }

        switch error {
        case is CancellationError:
            return false
        case AnalysisServiceError.invalidConfiguration:
            return false
        case AnalysisServiceError.lengthTruncated:
            return false
        case AnalysisServiceError.invalidResponse:
            return true
        case AnalysisServiceError.httpError(let statusCode, _):
            return statusCode >= 500
        case is URLError:
            return true
        default:
            return false
        }
    }

    nonisolated private static func truncatedDebugText(_ text: String, limit: Int = 400) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return "(empty)"
        }

        guard collapsed.count > limit else {
            return collapsed
        }

        return String(collapsed.prefix(limit)) + "..."
    }

    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage, arguments: arguments)
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

    private func invalidAnalysisResponseMessage(
        rawText: String,
        baseKey: L10n.Key,
        language: AppLanguage
    ) -> String {
        let fullResponseHeader: String
        switch language {
        case .simplifiedChinese:
            fullResponseHeader = "以下是完整返回内容："
        case .english:
            fullResponseHeader = "Full response:"
        }

        return localized(baseKey, language: language)
            + "\n"
            + fullResponseHeader
            + "\n"
            + rawText
    }

    private func appleIntelligenceDecodingFailureMessage(
        details: String,
        rawText: String?,
        language: AppLanguage
    ) -> String {
        let capturedResponse = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedResponse = capturedResponse?.isEmpty == false
            ? capturedResponse!
            : localized(.analysisResponseUnavailable, language: language)

        return localized(.analysisAppleIntelligenceDecodingFailure, language: language)
            + "\n"
            + localized(.analysisUnderlyingDetailsHeader, language: language)
            + "\n"
            + details
            + "\n"
            + invalidAnalysisResponseMessage(
                rawText: resolvedResponse,
                baseKey: .analysisInvalidStructuredResponseWithText,
                language: language
            )
    }

    private func mapLLMServiceError(
        _ error: LLMServiceError,
        language: AppLanguage
    ) -> AnalysisServiceError {
        switch error {
        case .invalidRemoteConfiguration:
            return .invalidConfiguration(localized(.analysisInvalidBaseURL, language: language))
        case .invalidHTTPResponse:
            return .invalidResponse(localized(.analysisInvalidHTTPResponse, language: language))
        case .missingResponseData:
            return .invalidResponse(localized(.analysisNoResponseData, language: language))
        case .httpError(let statusCode, let body):
            return .httpError(statusCode: statusCode, body: body)
        case .invalidResponseFormat(let provider):
            return .invalidResponse(localized(formatInvalidKey(for: provider), language: language))
        case .missingText(let provider):
            return .invalidResponse(localized(noTextKey(for: provider), language: language))
        case .appleIntelligenceUnavailable(let reason):
            return .invalidConfiguration(
                localized(
                    .analysisAppleIntelligenceUnavailable,
                    arguments: [reason.localizedDescription(language: language)],
                    language: language
                )
            )
        case .appleStructuredDecodingFailure(let details, let rawText):
            return .invalidResponse(
                appleIntelligenceDecodingFailureMessage(
                    details: details,
                    rawText: rawText,
                    language: language
                )
            )
        }
    }

    private func formatInvalidKey(for provider: ModelProvider) -> L10n.Key {
        switch provider {
        case .openAI:
            return .analysisOpenAIFormatInvalid
        case .anthropic:
            return .analysisAnthropicFormatInvalid
        case .lmStudio:
            return .analysisLMStudioFormatInvalid
        case .appleIntelligence:
            return .analysisInvalidStructuredResponseWithText
        }
    }

    private func noTextKey(for provider: ModelProvider) -> L10n.Key {
        switch provider {
        case .openAI:
            return .analysisOpenAINoText
        case .anthropic:
            return .analysisAnthropicNoText
        case .lmStudio:
            return .analysisLMStudioNoText
        case .appleIntelligence:
            return .analysisResponseUnavailable
        }
    }
}
