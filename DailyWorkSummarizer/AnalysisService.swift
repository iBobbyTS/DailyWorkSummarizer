import AppKit
import Foundation

private final class URLSessionDataTaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}

enum AnalysisServiceError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .httpError(let statusCode, let body):
            return "接口返回错误 (\(statusCode))：\(body)"
        }
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
        let responseID: String?
    }

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let session: URLSession
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var runningTask: Task<Void, Never>?
    private var activeRequestTask: URLSessionDataTask?
    private var activeRunSettings: AppSettingsSnapshot?
    private var lastLMStudioResponseID: String?
    private var runtimeState: AnalysisRuntimeState = .idle {
        didSet {
            NotificationCenter.default.post(name: .analysisStatusDidChange, object: nil)
        }
    }

    init(database: AppDatabase, settingsStore: SettingsStore, session: URLSession? = nil) {
        self.database = database
        self.settingsStore = settingsStore
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
        triggerAnalysis(scheduledFor: Date())
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

    func testCurrentSettings(with imageFileURL: URL) async throws -> AnalysisResponse {
        let snapshot = settingsStore.snapshot

        guard !snapshot.validCategoryRules.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration("至少需要配置一条有效的分析类别和描述")
        }

        guard !snapshot.apiBaseURL.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration("请先配置模型接口地址")
        }

        guard !snapshot.modelName.isEmpty else {
            throw AnalysisServiceError.invalidConfiguration("请先配置模型名称")
        }

        let prompt = buildPrompt(with: snapshot.validCategoryRules)
        return try await analyzeImage(at: imageFileURL, settings: snapshot, prompt: prompt)
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
        let nextDate = settingsStore.snapshot.nextAnalysisDate(after: Date())
        timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerAnalysis(scheduledFor: nextDate)
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func triggerAnalysis(scheduledFor: Date) {
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
        let prompt = buildPrompt(with: snapshot.validCategoryRules)
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
                errorMessage: "至少需要配置一条有效的分析类别和描述"
            )
            return
        }

        guard !snapshot.apiBaseURL.isEmpty else {
            try? database.finishAnalysisRun(
                id: runID,
                status: "failed",
                successCount: 0,
                failureCount: pendingCaptures.count,
                errorMessage: "请先配置模型接口地址"
            )
            return
        }

        guard !snapshot.modelName.isEmpty else {
            try? database.finishAnalysisRun(
                id: runID,
                status: "failed",
                successCount: 0,
                failureCount: pendingCaptures.count,
                errorMessage: "请先配置模型名称"
            )
            return
        }

        var successCount = 0
        var failureCount = 0
        var completedCount = 0
        var wasCancelled = false
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
                let message = "截图文件不存在，无法继续分析"
                try? database.insertAnalysisResult(
                    runID: runID,
                    capturedAt: capturedAt,
                    categoryName: nil,
                    rawResponseText: nil,
                    status: "failed",
                    errorMessage: message,
                    durationMinutesSnapshot: durationMinutes
                )
                failureCount += 1
                completedCount += 1
                updateRuntimeState(
                    startedAt: pendingCaptures.first?.capturedAt,
                    completedCount: completedCount,
                    totalCount: pendingCaptures.count
                )
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
                    rawResponseText: response.rawText,
                    status: "succeeded",
                    errorMessage: nil,
                    durationMinutesSnapshot: durationMinutes
                )

                successCount += 1
                try? FileManager.default.removeItem(at: fileURL)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    wasCancelled = true
                    break
                }

                let message = error.localizedDescription
                try? database.insertAnalysisResult(
                    runID: runID,
                    capturedAt: capturedAt,
                    categoryName: nil,
                    rawResponseText: nil,
                    status: "failed",
                    errorMessage: message,
                    durationMinutesSnapshot: durationMinutes
                )
                failureCount += 1
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
        }

        if wasCancelled {
            try? database.finishAnalysisRun(
                id: runID,
                status: "cancelled",
                successCount: successCount,
                failureCount: failureCount,
                averageItemDurationSeconds: measuredItemCount > 0 ? measuredDurationTotal / Double(measuredItemCount) : nil,
                errorMessage: "用户手动暂停分析"
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
            errorMessage: failureCount > 0 ? "部分截图分析失败，请检查网络、模型接口或返回格式" : nil
        )
        await stopModelIfNeeded(for: snapshot)
    }

    private func buildPrompt(with rules: [CategoryRule]) -> String {
        let list = rules.enumerated().map { index, rule in
            "\(index + 1). \(rule.name)：\(rule.description)"
        }.joined(separator: "\n")

        return """
        你是一个工作桌面截图分类助手。
        请严格从下面的候选类别中选择唯一一个最匹配的类别。

        候选类别：
        \(list)

        返回要求：
        1. 只能返回一个类别名
        2. 不要返回 JSON、Markdown、解释、思考过程或其他多余文本
        3. 返回的类别名必须与候选类别完全一致
        """
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
        allowLengthRetry: Bool = true
    ) async throws -> AnalysisResponse {
        let imageData = try Data(contentsOf: fileURL)
        guard let endpoint = settings.provider.requestURL(from: settings.apiBaseURL) else {
            throw AnalysisServiceError.invalidConfiguration("模型接口地址不合法")
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
            if !settings.inheritPreviousResponse {
                lastLMStudioResponseID = nil
            }
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try buildLMStudioRequestBody(
                imageData: imageData,
                modelName: settings.modelName,
                prompt: prompt,
                inheritPreviousResponse: settings.inheritPreviousResponse,
                previousResponseID: lastLMStudioResponseID,
                contextLength: settings.lmStudioContextLength
            )
        }

        let (data, response) = try await performDataRequest(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisServiceError.invalidResponse("模型接口没有返回有效的 HTTP 响应")
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
            lastLMStudioResponseID = settings.inheritPreviousResponse ? payload.responseID : nil
        }

        guard let category = extractCategory(
            from: text,
            validRules: settings.validCategoryRules,
            finishReason: finishReason
        ) else {
            if finishReason == "length", allowLengthRetry {
                let retryPrompt = prompt + "\n\n补充要求：不要过度思考"
                return try await analyzeImage(
                    at: fileURL,
                    settings: settings,
                    prompt: retryPrompt,
                    allowLengthRetry: false
                )
            }
            if finishReason == "length" {
                throw AnalysisServiceError.invalidResponse("模型输出因长度截断，未能生成完整分类结果：\(text)")
            }
            throw AnalysisServiceError.invalidResponse("模型返回无法解析为有效类别：\(text)")
        }

        return AnalysisResponse(category: category, rawText: text)
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
        inheritPreviousResponse: Bool,
        previousResponseID: String?,
        contextLength: Int
    ) throws -> Data {
        let imageBase64 = imageData.base64EncodedString()
        var body: [String: Any] = [
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
            "store": inheritPreviousResponse,
            "context_length": contextLength,
        ]

        if inheritPreviousResponse, let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private func parseOpenAIResponse(from data: Data) throws -> OpenAIResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AnalysisServiceError.invalidResponse("OpenAI 兼容接口返回格式不正确")
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

        throw AnalysisServiceError.invalidResponse("OpenAI 兼容接口没有返回可读文本")
    }

    private func parseAnthropicResponse(from data: Data) throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [[String: Any]] else {
            throw AnalysisServiceError.invalidResponse("Anthropic 兼容接口返回格式不正确")
        }

        let text = content.compactMap { block in
            block["text"] as? String
        }.joined(separator: "\n")

        guard !text.isEmpty else {
            throw AnalysisServiceError.invalidResponse("Anthropic 兼容接口没有返回可读文本")
        }

        return text
    }

    private func parseLMStudioResponse(from data: Data) throws -> LMStudioResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else {
            throw AnalysisServiceError.invalidResponse("LM Studio API 返回格式不正确")
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
            throw AnalysisServiceError.invalidResponse("LM Studio API 没有返回可读文本")
        }

        let responseID = payload["response_id"] as? String
        return LMStudioResponsePayload(content: text, responseID: responseID)
    }

    private func extractCategory(from rawText: String, validRules: [CategoryRule], finishReason: String?) -> String? {
        let categories = validRules.map { $0.name }

        if let matched = extractCategoryFromPlainText(in: rawText, categories: categories) {
            return matched
        }

        if finishReason == "length",
           let dominantCategory = extractDominantCategoryFromThinking(in: rawText, categories: categories) {
            return dominantCategory
        }

        return nil
    }

    private func extractCategoryFromPlainText(in rawText: String, categories: [String]) -> String? {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [
            normalized,
            unwrapCodeFence(from: normalized),
            normalized
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty }) ?? "",
            unwrapCodeFence(from: normalized)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty }) ?? "",
        ]

        for candidate in candidates {
            if let matched = matchCategory(candidate, categories: categories) {
                return matched
            }
        }

        return nil
    }

    private func extractDominantCategoryFromThinking(in rawText: String, categories: [String]) -> String? {
        let thinkingText = extractThinkingText(from: rawText)
        let counts = categories
            .map { category in
                (category, occurrenceCount(of: category, in: thinkingText))
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 > rhs.1
            }

        guard let first = counts.first else {
            return nil
        }

        let remainingSum = counts.dropFirst().reduce(0) { $0 + $1.1 }
        return first.1 > remainingSum * 2 ? first.0 : nil
    }

    private func extractThinkingText(from rawText: String) -> String {
        guard let startRange = rawText.range(of: "<think>") else {
            return rawText
        }

        let contentStart = startRange.upperBound
        if let endRange = rawText.range(of: "</think>", range: contentStart..<rawText.endIndex) {
            return String(rawText[contentStart..<endRange.lowerBound])
        }

        return String(rawText[contentStart...])
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else {
            return 0
        }

        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex

        while let foundRange = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = foundRange.upperBound..<haystack.endIndex
        }

        return count
    }

    private func matchCategory(_ value: String, categories: [String]) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'`"))
        )
        return categories.first { $0 == trimmed }
    }

    private func unwrapCodeFence(from text: String) -> String {
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
                        continuation.resume(throwing: AnalysisServiceError.invalidResponse("模型接口没有返回数据"))
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
        lastLMStudioResponseID = nil

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
}
