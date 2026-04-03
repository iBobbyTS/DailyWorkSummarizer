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
    private struct OpenAIResponsePayload {
        let content: String
        let finishReason: String?
    }

    private struct LMStudioResponsePayload {
        let content: String
        let timing: LMStudioTiming?
        let reasoningText: String?
    }

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
    private let errorStore: AnalysisErrorStore
    private let dailyReportSummaryService: DailyReportSummaryService
    private let session: URLSession
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var runningTask: Task<Void, Never>?
    private var activeRequestTask: URLSessionDataTask?
    private var activeRunSettings: AppSettingsSnapshot?
    private var runtimeState: AnalysisRuntimeState = .idle {
        didSet {
            NotificationCenter.default.post(name: .analysisStatusDidChange, object: nil)
        }
    }

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        errorStore: AnalysisErrorStore,
        dailyReportSummaryService: DailyReportSummaryService,
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.errorStore = errorStore
        self.dailyReportSummaryService = dailyReportSummaryService
        self.session = session ?? Self.makeIsolatedSession()
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
        updateRuntimeState(
            startedAt: runtimeState.startedAt,
            completedCount: runtimeState.completedCount,
            totalCount: runtimeState.totalCount,
            isStopping: true
        )
        runningTask?.cancel()
        activeRequestTask?.cancel()
        if let activeRunSettings {
            Task { [weak self] in
                await self?.stopModelIfNeeded(for: activeRunSettings)
            }
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
                errorStore.add(error.localizedDescription)
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

    private func runAnalysis(scheduledFor: Date) async {
        let snapshot = settingsStore.snapshot
        activeRunSettings = snapshot
        let prompt = buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.analysisSummaryInstruction,
            language: snapshot.appLanguage
        )
        let categoriesJSON = encodeCategories(snapshot.validCategoryRules)
        let pendingCaptures = (try? database.listScreenshotFiles(defaultDurationMinutes: snapshot.screenshotIntervalMinutes)) ?? []

        let runID: Int64
        do {
            runID = try database.createAnalysisRun(
                scheduledFor: scheduledFor,
                provider: snapshot.provider,
                baseURL: snapshot.apiBaseURL,
                modelName: snapshot.modelName,
                promptSnapshot: prompt,
                categorySnapshotJSON: categoriesJSON,
                totalItems: pendingCaptures.count
            )
        } catch {
            return
        }

        updateRuntimeState(
            startedAt: pendingCaptures.first?.capturedAt,
            completedCount: 0,
            totalCount: pendingCaptures.count,
            isStopping: false
        )
        defer {
            activeRunSettings = nil
            activeRequestTask = nil
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

        for (index, capture) in pendingCaptures.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }

            let fileURL = capture.url
            let capturedAt = capture.capturedAt
            let durationMinutes = capture.durationMinutes

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let message = localized(.analysisScreenshotMissing, language: snapshot.appLanguage)
                try? database.insertAnalysisResult(
                    runID: runID,
                    capturedAt: capturedAt,
                    categoryName: nil,
                    summaryText: nil,
                    status: "failed",
                    errorMessage: message,
                    durationMinutesSnapshot: durationMinutes
                )
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
                    runID: runID,
                    capturedAt: capturedAt,
                    categoryName: response.category,
                    summaryText: response.summary,
                    status: "succeeded",
                    errorMessage: nil,
                    durationMinutesSnapshot: durationMinutes
                )

                successCount += 1
                consecutiveFailureCount = 0
                try? FileManager.default.removeItem(at: fileURL)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    wasCancelled = true
                    break
                }

                let message = error.localizedDescription
                if Self.shouldRecordRuntimeError(error) {
                    errorStore.add(message)
                }
                try? database.insertAnalysisResult(
                    runID: runID,
                    capturedAt: capturedAt,
                    categoryName: nil,
                    summaryText: nil,
                    status: "failed",
                    errorMessage: message,
                    durationMinutesSnapshot: durationMinutes
                )
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

    private func encodeCategories(_ rules: [CategoryRule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
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

        guard let endpoint = settings.provider.requestURL(from: settings.apiBaseURL) else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisInvalidBaseURL, language: settings.appLanguage))
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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")

        switch settings.provider {
        case .openAI:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try buildOpenAIRequestBody(
                imageData: requestImageData,
                modelName: settings.modelName,
                prompt: requestPrompt
            )
        case .anthropic:
            if !settings.apiKey.isEmpty {
                request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try buildAnthropicRequestBody(
                imageData: requestImageData,
                modelName: settings.modelName,
                prompt: requestPrompt
            )
        case .lmStudio:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try buildLMStudioRequestBody(
                imageData: requestImageData,
                modelName: settings.modelName,
                prompt: requestPrompt,
                contextLength: settings.lmStudioContextLength
            )
        case .appleIntelligence:
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisInvalidBaseURL, language: settings.appLanguage))
        }

        let requestResult = try await performDataRequest(for: request)
        guard let httpResponse = requestResult.response as? HTTPURLResponse else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisInvalidHTTPResponse, language: settings.appLanguage))
        }

        let rawBody = String(decoding: requestResult.data, as: UTF8.self)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnalysisServiceError.httpError(statusCode: httpResponse.statusCode, body: rawBody)
        }

        let text: String
        let finishReason: String?
        let requestTiming: ModelRequestTiming?
        let lmStudioTiming: LMStudioTiming?
        let reasoningText: String?
        switch settings.provider {
        case .openAI:
            let payload = try parseOpenAIResponse(from: requestResult.data)
            text = payload.content
            finishReason = payload.finishReason
            requestTiming = ModelRequestTiming(
                roundTripSeconds: requestResult.roundTripSeconds,
                serverProcessingSeconds: openAIProcessingSeconds(from: httpResponse)
            )
            lmStudioTiming = nil
            reasoningText = nil
        case .anthropic:
            text = try parseAnthropicResponse(from: requestResult.data)
            finishReason = nil
            requestTiming = ModelRequestTiming(
                roundTripSeconds: requestResult.roundTripSeconds,
                serverProcessingSeconds: nil
            )
            lmStudioTiming = nil
            reasoningText = nil
        case .lmStudio:
            let payload = try parseLMStudioResponse(from: requestResult.data)
            text = payload.content
            finishReason = nil
            requestTiming = ModelRequestTiming(
                roundTripSeconds: requestResult.roundTripSeconds,
                serverProcessingSeconds: nil
            )
            lmStudioTiming = payload.timing
            reasoningText = payload.reasoningText
        case .appleIntelligence:
            throw AnalysisServiceError.invalidResponse(localized(.analysisInvalidCategoryWithText, language: settings.appLanguage))
        }

        guard let response = Self.extractAnalysisResponse(from: text, validRules: settings.validCategoryRules) else {
            if finishReason == "length", allowLengthRetry {
                let retryPrompt = prompt + "\n\n" + localized(.analysisRetrySupplement, language: settings.appLanguage)
                return try await analyzeImageAttemptDetailed(
                    at: fileURL,
                    settings: settings,
                    prompt: retryPrompt,
                    allowLengthRetry: false
                )
            }
            if finishReason == "length" {
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
            requestTiming: requestTiming,
            lmStudioTiming: lmStudioTiming,
            ocrText: ocrText,
            reasoningText: reasoningText
        )
    }

    private func buildOpenAIRequestBody(imageData: Data?, modelName: String, prompt: String) throws -> Data {
        let content: Any
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            content = [
                ["type": "text", "text": prompt],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(imageBase64)"
                    ]
                ],
            ]
        } else {
            content = prompt
        }

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
            "max_tokens": 300,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildAnthropicRequestBody(imageData: Data?, modelName: String, prompt: String) throws -> Data {
        var content: [[String: Any]] = []
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            content.append(
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": imageBase64,
                    ]
                ]
            )
        }
        content.append(
            [
                "type": "text",
                "text": prompt,
            ]
        )

        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 300,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildLMStudioRequestBody(
        imageData: Data?,
        modelName: String,
        prompt: String,
        contextLength: Int
    ) throws -> Data {
        var input: [[String: Any]] = [
            [
                "type": "text",
                "content": prompt,
            ]
        ]
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            input.append(
                [
                    "type": "image",
                    "data_url": "data:image/jpeg;base64,\(imageBase64)"
                ]
            )
        }

        let body: [String: Any] = [
            "model": modelName,
            "input": input,
            "store": false,
            "context_length": contextLength,
        ]

        return try JSONSerialization.data(withJSONObject: body)
    }

    private func analyzeImageWithAppleIntelligence(
        recognizedText: String,
        validRules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage
    ) async throws -> AnalysisResponse {
        try ensureAppleIntelligenceAvailable(language: language)

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
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging)
        )
        let stream = session.streamResponse(
            to: applePrompt,
            schema: schema,
            options: GenerationOptions(maximumResponseTokens: 300)
        )
        var lastRawContent: GeneratedContent?

        do {
            for try await snapshot in stream {
                lastRawContent = snapshot.rawContent
            }
        } catch LanguageModelSession.GenerationError.decodingFailure(let context) {
            throw AnalysisServiceError.invalidResponse(
                appleIntelligenceDecodingFailureMessage(
                    details: context.debugDescription,
                    rawText: capturedAppleIntelligenceResponseText(
                        lastRawContent: lastRawContent,
                        session: session
                    ),
                    language: language
                )
            )
        } catch {
            throw error
        }

        let rawContent = lastRawContent ?? capturedAppleIntelligenceGeneratedContent(from: session)
        guard let rawContent,
              let parsedResponse = Self.extractGuidedAnalysisResponse(
            from: rawContent,
            validRules: validRules
        ) else {
            throw AnalysisServiceError.invalidResponse(
                invalidAnalysisResponseMessage(
                    rawText: capturedAppleIntelligenceResponseText(
                        lastRawContent: lastRawContent,
                        session: session
                    ) ?? localized(.analysisResponseUnavailable, language: language),
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

    private func capturedAppleIntelligenceResponseText(
        lastRawContent: GeneratedContent?,
        session: LanguageModelSession
    ) -> String? {
        if let jsonString = lastRawContent?.jsonString.trimmingCharacters(in: .whitespacesAndNewlines),
           !jsonString.isEmpty {
            return jsonString
        }

        if let content = capturedAppleIntelligenceGeneratedContent(from: session)?.jsonString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return content
        }

        return nil
    }

    private func capturedAppleIntelligenceGeneratedContent(from session: LanguageModelSession) -> GeneratedContent? {
        for entry in session.transcript.reversed() {
            guard case .response(let response) = entry else {
                continue
            }

            for segment in response.segments.reversed() {
                switch segment {
                case .structure(let structured):
                    return structured.content
                case .text:
                    continue
                @unknown default:
                    continue
                }
            }
        }

        return nil
    }

    private func parseOpenAIResponse(from data: Data) throws -> OpenAIResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisOpenAIFormatInvalid))
        }

        let finishReason = firstChoice["finish_reason"] as? String

        if let content = message["content"] as? String {
            return OpenAIResponsePayload(content: content, finishReason: finishReason)
        }

        if let contentBlocks = message["content"] as? [[String: Any]] {
            let text = contentBlocks.compactMap { block in
                block["text"] as? String
            }.joined(separator: "\n")
            if !text.isEmpty {
                return OpenAIResponsePayload(content: text, finishReason: finishReason)
            }
        }

        throw AnalysisServiceError.invalidResponse(localized(.analysisOpenAINoText))
    }

    private func parseAnthropicResponse(from data: Data) throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [[String: Any]] else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisAnthropicFormatInvalid))
        }

        let text = content.compactMap { block in
            block["text"] as? String
        }.joined(separator: "\n")

        guard !text.isEmpty else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisAnthropicNoText))
        }

        return text
    }

    private func parseLMStudioResponse(from data: Data) throws -> LMStudioResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisLMStudioFormatInvalid))
        }

        let messageText = output
            .filter { ($0["type"] as? String) == "message" }
            .compactMap { $0["content"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let reasoningText = output
            .filter { ($0["type"] as? String) == "reasoning" }
            .compactMap { $0["content"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let text = messageText.isEmpty ? reasoningText : messageText

        guard !text.isEmpty else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisLMStudioNoText))
        }

        let timing = parseLMStudioTiming(from: payload["stats"] as? [String: Any])
        return LMStudioResponsePayload(
            content: text,
            timing: timing,
            reasoningText: reasoningText.isEmpty ? nil : reasoningText
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
        isStopping: Bool? = nil
    ) {
        runtimeState = AnalysisRuntimeState(
            isRunning: true,
            isStopping: isStopping ?? runtimeState.isStopping,
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
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { [weak self, taskBox] data, response, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.activeRequestTask === taskBox.task {
                            self.activeRequestTask = nil
                        }
                    }

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
                activeRequestTask = dataTask
                dataTask.resume()
            }
        } onCancel: {
            Task { @MainActor [taskBox] in
                taskBox.task?.cancel()
            }
        }
    }

    private func stopModelIfNeeded(for settings: AppSettingsSnapshot) async {
        activeRequestTask?.cancel()
        activeRequestTask = nil

        guard settings.provider == .lmStudio,
              let modelsURL = lmStudioModelsURL(from: settings.apiBaseURL) else {
            return
        }

        do {
            let listRequest = makeJSONRequest(url: modelsURL, method: "GET", apiKey: settings.apiKey)
            let result = try await performDataRequest(for: listRequest)
            guard let httpResponse = result.response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }

            guard let instanceID = extractLMStudioInstanceID(from: result.data, modelName: settings.modelName) else {
                return
            }

            let unloadURL = modelsURL.appendingPathComponent("unload")
            var unloadRequest = makeJSONRequest(url: unloadURL, method: "POST", apiKey: settings.apiKey)
            unloadRequest.httpBody = try JSONSerialization.data(withJSONObject: ["instance_id": instanceID])
            _ = try await performDataRequest(for: unloadRequest)
        } catch {
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

    private func lmStudioModelsURL(from baseURLString: String) -> URL? {
        guard let chatURL = ModelProvider.lmStudio.requestURL(from: baseURLString) else {
            return nil
        }
        return chatURL.deletingLastPathComponent().appendingPathComponent("models")
    }

    private func extractLMStudioInstanceID(from data: Data, modelName: String) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else {
            return nil
        }

        for model in models {
            let key = model["key"] as? String
            let selectedVariant = model["selected_variant"] as? String
            guard key == modelName || selectedVariant == modelName else {
                continue
            }

            let loadedInstances = model["loaded_instances"] as? [[String: Any]] ?? []
            if let instanceID = loadedInstances.compactMap({
                ($0["identifier"] as? String) ?? ($0["id"] as? String)
            }).first {
                return instanceID
            }
        }

        return nil
    }

    private func parseLMStudioTiming(from stats: [String: Any]?) -> LMStudioTiming? {
        guard let stats else { return nil }

        return LMStudioTiming(
            modelLoadTimeSeconds: Self.doubleValue(from: stats["model_load_time_seconds"]),
            timeToFirstTokenSeconds: Self.doubleValue(from: stats["time_to_first_token_seconds"]),
            totalOutputTokens: Self.intValue(from: stats["total_output_tokens"]),
            tokensPerSecond: Self.doubleValue(from: stats["tokens_per_second"])
        )
    }

    private func openAIProcessingSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "openai-processing-ms")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let milliseconds = Double(rawValue) else {
            return nil
        }

        return milliseconds / 1_000
    }

    nonisolated private static func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    nonisolated private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage, arguments: arguments)
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

    private func ensureAppleIntelligenceAvailable(language: AppLanguage) throws {
        guard let unavailableReason = AppleIntelligenceSupport.currentStatus(for: language).unavailableReason else {
            return
        }

        throw AnalysisServiceError.invalidConfiguration(
            localized(
                .analysisAppleIntelligenceUnavailable,
                arguments: [appleIntelligenceReasonText(for: unavailableReason, language: language)],
                language: language
            )
        )
    }

    private func appleIntelligenceReasonText(
        for reason: SystemLanguageModel.Availability.UnavailableReason,
        language: AppLanguage
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return localized(.providerAppleIntelligenceDeviceNotEligible, language: language)
        case .appleIntelligenceNotEnabled:
            return localized(.providerAppleIntelligenceNotEnabled, language: language)
        case .modelNotReady:
            return localized(.providerAppleIntelligenceModelNotReady, language: language)
        @unknown default:
            return localized(.providerAppleIntelligenceModelNotReady, language: language)
        }
    }
}
