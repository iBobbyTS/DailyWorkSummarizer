import AppKit
import Foundation
import IOKit.ps

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
    }
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let errorStore: AnalysisErrorStore
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
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.errorStore = errorStore
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

    func testCurrentSettings(with imageFileURL: URL) async throws -> AnalysisResponse {
        let snapshot = settingsStore.snapshot

        guard !snapshot.validCategoryRules.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsCategoryRule, language: snapshot.appLanguage))
        }

        guard !snapshot.apiBaseURL.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsBaseURL, language: snapshot.appLanguage))
        }

        guard !snapshot.modelName.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisNeedsModelName, language: snapshot.appLanguage))
        }

        let prompt = buildPrompt(
            with: snapshot.validCategoryRules,
            summaryInstruction: snapshot.analysisSummaryInstruction,
            language: snapshot.appLanguage
        )
        do {
            return try await analyzeImage(at: imageFileURL, settings: snapshot, prompt: prompt)
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
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await analyzeImageAttempt(
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

    private func analyzeImageAttempt(
        at fileURL: URL,
        settings: AppSettingsSnapshot,
        prompt: String,
        allowLengthRetry: Bool
    ) async throws -> AnalysisResponse {
        let imageData = try Data(contentsOf: fileURL)
        guard let endpoint = settings.provider.requestURL(from: settings.apiBaseURL) else {
            throw AnalysisServiceError.invalidConfiguration(localized(.analysisInvalidBaseURL, language: settings.appLanguage))
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
                imageData: imageData,
                modelName: settings.modelName,
                prompt: prompt
            )
        case .anthropic:
            if !settings.apiKey.isEmpty {
                request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try buildAnthropicRequestBody(
                imageData: imageData,
                modelName: settings.modelName,
                prompt: prompt
            )
        case .lmStudio:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try buildLMStudioRequestBody(
                imageData: imageData,
                modelName: settings.modelName,
                prompt: prompt,
                contextLength: settings.lmStudioContextLength
            )
        }

        let (data, response) = try await performDataRequest(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisServiceError.invalidResponse(localized(.analysisInvalidHTTPResponse, language: settings.appLanguage))
        }

        let rawBody = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnalysisServiceError.httpError(statusCode: httpResponse.statusCode, body: rawBody)
        }

        let text: String
        let finishReason: String?
        switch settings.provider {
        case .openAI:
            let payload = try parseOpenAIResponse(from: data)
            text = payload.content
            finishReason = payload.finishReason
        case .anthropic:
            text = try parseAnthropicResponse(from: data)
            finishReason = nil
        case .lmStudio:
            let payload = try parseLMStudioResponse(from: data)
            text = payload.content
            finishReason = nil
        }

        guard let response = Self.extractAnalysisResponse(from: text, validRules: settings.validCategoryRules) else {
            if finishReason == "length", allowLengthRetry {
                let retryPrompt = prompt + "\n\n" + localized(.analysisRetrySupplement, language: settings.appLanguage)
                return try await analyzeImageAttempt(
                    at: fileURL,
                    settings: settings,
                    prompt: retryPrompt,
                    allowLengthRetry: false
                )
            }
            if finishReason == "length" {
                throw AnalysisServiceError.lengthTruncated(localized(.analysisLengthTruncated, language: settings.appLanguage))
            }
            throw AnalysisServiceError.invalidResponse(localized(.analysisInvalidCategoryWithText, language: settings.appLanguage))
        }

        return response
    }

    private func buildOpenAIRequestBody(imageData: Data, modelName: String, prompt: String) throws -> Data {
        let imageBase64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(imageBase64)"
                            ]
                        ],
                    ]
                ]
            ],
            "max_tokens": 300,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildAnthropicRequestBody(imageData: Data, modelName: String, prompt: String) throws -> Data {
        let imageBase64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 300,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageBase64,
                            ]
                        ],
                        [
                            "type": "text",
                            "text": prompt,
                        ],
                    ]
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildLMStudioRequestBody(
        imageData: Data,
        modelName: String,
        prompt: String,
        contextLength: Int
    ) throws -> Data {
        let imageBase64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": modelName,
            "input": [
                [
                    "type": "text",
                    "content": prompt,
                ],
                [
                    "type": "image",
                    "data_url": "data:image/jpeg;base64,\(imageBase64)"
                ],
            ],
            "store": false,
            "context_length": contextLength,
        ]

        return try JSONSerialization.data(withJSONObject: body)
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

        return LMStudioResponsePayload(content: text)
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

    private func performDataRequest(for request: URLRequest) async throws -> (Data, URLResponse) {
        let taskBox = URLSessionDataTaskBox()
        let language = settingsStore.appLanguage
        let missingDataMessage = L10n.string(.analysisNoResponseData, language: language)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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

                    continuation.resume(returning: (data, response))
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
            let (data, response) = try await performDataRequest(for: listRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }

            guard let instanceID = extractLMStudioInstanceID(from: data, modelName: settings.modelName) else {
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

    private func localized(_ key: L10n.Key, language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        L10n.string(key, language: language ?? settingsStore.appLanguage, arguments: arguments)
    }
}
