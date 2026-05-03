import Foundation

// LM Studio has shipped both "text" and "message" discriminators for multimodal text input items.
enum LMStudioMultimodalTextInputStyle: String {
    case text
    case message

    var alternate: LMStudioMultimodalTextInputStyle {
        switch self {
        case .text:
            return .message
        case .message:
            return .text
        }
    }
}

struct LMStudioChatResponse {
    let modelInstanceID: String?
    let messageText: String?
    let reasoningText: String?
    let timing: LMStudioTiming?
    let tokenUsage: LLMTokenUsage?

    var content: String? {
        if let messageText, !messageText.isEmpty {
            return messageText
        }
        if let reasoningText, !reasoningText.isEmpty {
            return reasoningText
        }
        return nil
    }
}

struct LMStudioLoadedModel: Equatable {
    let instanceID: String
}

enum LMStudioModelLifecycleError: LocalizedError {
    case invalidRemoteConfiguration
    case invalidHTTPResponse
    case missingResponseData
    case httpError(statusCode: Int, body: String)
    case missingLoadedInstanceID(modelName: String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteConfiguration:
            return "LM Studio model management endpoint is invalid."
        case .invalidHTTPResponse:
            return "LM Studio model management did not return a valid HTTP response."
        case .missingResponseData:
            return "LM Studio model management did not return data."
        case .httpError(let statusCode, let body):
            return L10n.string(.analysisHTTPError, arguments: [statusCode, body])
        case .missingLoadedInstanceID(let modelName):
            return "LM Studio did not return or expose a loaded instance for \(modelName)."
        }
    }
}

private struct LMStudioLifecycleDataRequestResult {
    let data: Data
    let response: URLResponse
}

private final class LMStudioLifecycleURLSessionDataTaskBox: @unchecked Sendable {
    nonisolated(unsafe) var task: URLSessionDataTask?
}

final class LMStudioModelLifecycle {
    typealias LogHandler = (String, String) -> Void

    private let session: URLSession
    private let log: LogHandler

    init(
        session: URLSession,
        log: @escaping LogHandler = { _, _ in }
    ) {
        self.session = session
        self.log = log
    }

    func load(settings: ModelProfileSettings) async throws -> LMStudioLoadedModel {
        guard settings.provider == .lmStudio,
              let modelsURL = LMStudioAPI.modelsURL(from: settings.apiBaseURL) else {
            throw LMStudioModelLifecycleError.invalidRemoteConfiguration
        }

        let loadURL = modelsURL.appendingPathComponent("load")
        var request = makeJSONRequest(url: loadURL, method: "POST", apiKey: settings.apiKey)
        request.httpBody = try LMStudioAPI.buildLoadRequestBody(
            modelName: settings.modelName,
            contextLength: settings.lmStudioContextLength
        )
        record(
            chinese: "开始请求 LM Studio /api/v1/models/load，model=\(settings.modelName)，context_length=\(settings.lmStudioContextLength)。",
            english: "Requesting LM Studio /api/v1/models/load with model=\(settings.modelName), context_length=\(settings.lmStudioContextLength)."
        )

        let result = try await performDataRequest(for: request)
        guard let response = result.response as? HTTPURLResponse else {
            record(
                chinese: "LM Studio load 未返回有效的 HTTP 响应。",
                english: "LM Studio load did not return a valid HTTP response."
            )
            throw LMStudioModelLifecycleError.invalidHTTPResponse
        }

        let responseBody = String(decoding: result.data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            let body = Self.truncatedDebugText(responseBody)
            record(
                chinese: "LM Studio load 返回 \(response.statusCode)，响应：\(body)",
                english: "LM Studio load returned \(response.statusCode). Body: \(body)"
            )
            throw LMStudioModelLifecycleError.httpError(statusCode: response.statusCode, body: responseBody)
        }

        guard let instanceID = LMStudioAPI.parseLoadResponseInstanceID(from: result.data) else {
            record(
                chinese: "LM Studio load 成功但未返回 instance_id，model=\(settings.modelName)。",
                english: "LM Studio load succeeded but did not return instance_id for model=\(settings.modelName)."
            )
            throw LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: settings.modelName)
        }

        record(
            chinese: "LM Studio load 成功，instance_id=\(instanceID)。",
            english: "LM Studio load succeeded with instance_id=\(instanceID)."
        )
        return LMStudioLoadedModel(instanceID: instanceID)
    }

    func unload(settings: ModelProfileSettings, instanceID: String?) async throws {
        guard settings.provider == .lmStudio,
              let modelsURL = LMStudioAPI.modelsURL(from: settings.apiBaseURL) else {
            throw LMStudioModelLifecycleError.invalidRemoteConfiguration
        }

        let resolvedInstanceID: String
        if let instanceID, !instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedInstanceID = instanceID
        } else {
            resolvedInstanceID = try await loadedInstanceID(settings: settings, modelsURL: modelsURL)
        }

        let unloadURL = modelsURL.appendingPathComponent("unload")
        var request = makeJSONRequest(url: unloadURL, method: "POST", apiKey: settings.apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["instance_id": resolvedInstanceID])
        record(
            chinese: "开始请求 LM Studio /api/v1/models/unload，instance_id=\(resolvedInstanceID)。",
            english: "Requesting LM Studio /api/v1/models/unload with instance_id=\(resolvedInstanceID)."
        )

        let result = try await performDataRequest(for: request)
        guard let response = result.response as? HTTPURLResponse else {
            record(
                chinese: "LM Studio unload 未返回有效的 HTTP 响应。",
                english: "LM Studio unload did not return a valid HTTP response."
            )
            throw LMStudioModelLifecycleError.invalidHTTPResponse
        }

        let responseBody = String(decoding: result.data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            let body = Self.truncatedDebugText(responseBody)
            record(
                chinese: "LM Studio unload 返回 \(response.statusCode)，响应：\(body)",
                english: "LM Studio unload returned \(response.statusCode). Body: \(body)"
            )
            throw LMStudioModelLifecycleError.httpError(statusCode: response.statusCode, body: responseBody)
        }

        record(
            chinese: "LM Studio unload 成功，instance_id=\(resolvedInstanceID)。",
            english: "LM Studio unload succeeded for instance_id=\(resolvedInstanceID)."
        )
    }

    private func loadedInstanceID(settings: ModelProfileSettings, modelsURL: URL) async throws -> String {
        record(
            chinese: "开始请求 LM Studio /api/v1/models，用于匹配待卸载实例。",
            english: "Requesting LM Studio /api/v1/models to match the instance to unload."
        )
        let request = makeJSONRequest(url: modelsURL, method: "GET", apiKey: settings.apiKey)
        let result = try await performDataRequest(for: request)
        guard let response = result.response as? HTTPURLResponse else {
            record(
                chinese: "LM Studio /api/v1/models 未返回有效的 HTTP 响应。",
                english: "LM Studio /api/v1/models did not return a valid HTTP response."
            )
            throw LMStudioModelLifecycleError.invalidHTTPResponse
        }

        let responseBody = String(decoding: result.data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            let body = Self.truncatedDebugText(responseBody)
            record(
                chinese: "LM Studio /api/v1/models 返回 \(response.statusCode)，响应：\(body)",
                english: "LM Studio /api/v1/models returned \(response.statusCode). Body: \(body)"
            )
            throw LMStudioModelLifecycleError.httpError(statusCode: response.statusCode, body: responseBody)
        }

        let modelsCount = LMStudioAPI.modelsCount(from: result.data) ?? 0
        record(
            chinese: "LM Studio /api/v1/models 成功，返回 \(modelsCount) 个模型。",
            english: "LM Studio /api/v1/models succeeded and returned \(modelsCount) models."
        )

        guard let instanceID = LMStudioAPI.extractLoadedInstanceID(
            from: result.data,
            modelName: settings.modelName,
            contextLength: settings.lmStudioContextLength
        ) else {
            record(
                chinese: "未能为 model=\(settings.modelName)、context_length=\(settings.lmStudioContextLength) 匹配到已加载实例。",
                english: "Could not match a loaded instance for model=\(settings.modelName), context_length=\(settings.lmStudioContextLength)."
            )
            throw LMStudioModelLifecycleError.missingLoadedInstanceID(modelName: settings.modelName)
        }

        record(
            chinese: "已匹配待卸载实例 \(instanceID)（model=\(settings.modelName)，context_length=\(settings.lmStudioContextLength)）。",
            english: "Matched loaded instance \(instanceID) for model=\(settings.modelName), context_length=\(settings.lmStudioContextLength)."
        )
        return instanceID
    }

    private func makeJSONRequest(url: URL, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func performDataRequest(for request: URLRequest) async throws -> LMStudioLifecycleDataRequestResult {
        let taskBox = LMStudioLifecycleURLSessionDataTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data, let response else {
                        continuation.resume(throwing: LMStudioModelLifecycleError.missingResponseData)
                        return
                    }

                    continuation.resume(
                        returning: LMStudioLifecycleDataRequestResult(
                            data: data,
                            response: response
                        )
                    )
                }

                let dataTask = session.dataTask(with: request, completionHandler: completion)
                taskBox.task = dataTask
                dataTask.resume()
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }

    private func record(chinese: String, english: String) {
        log(chinese, english)
    }

    private static func truncatedDebugText(_ value: String, maxLength: Int = 1_000) -> String {
        guard value.count > maxLength else {
            return value
        }
        return String(value.prefix(maxLength)) + "…"
    }
}

enum LMStudioAPI {
    static func buildLoadRequestBody(
        modelName: String,
        contextLength: Int
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "model": modelName,
                "context_length": contextLength,
                "echo_load_config": true,
            ]
        )
    }

    static func buildChatRequestBody(
        modelName: String,
        prompt: String,
        imageData: Data?,
        contextLength: Int,
        multimodalTextInputStyle: LMStudioMultimodalTextInputStyle = .text
    ) throws -> Data {
        let input: Any
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            input = [
                [
                    "type": multimodalTextInputStyle.rawValue,
                    "content": prompt,
                ],
                [
                    "type": "image",
                    "data_url": "data:image/jpeg;base64,\(imageBase64)",
                ],
            ]
        } else {
            input = prompt
        }

        let body: [String: Any] = [
            "model": modelName,
            "input": input,
            "store": false,
            "context_length": contextLength,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func fallbackMultimodalTextInputStyle(
        statusCode: Int,
        responseBody: String,
        attemptedStyle: LMStudioMultimodalTextInputStyle
    ) -> LMStudioMultimodalTextInputStyle? {
        // Retry only the known LM Studio discriminator compatibility error.
        guard statusCode == 400 else {
            return nil
        }

        let errorPayload = parseErrorPayload(from: responseBody)
        guard errorPayload.code == "invalid_union",
              errorPayload.param == "input" else {
            return nil
        }

        let message = errorPayload.message
        if message.contains("Expected 'text' | 'image'") {
            return attemptedStyle == .text ? nil : .text
        }
        if message.contains("Expected 'message' | 'image'") {
            return attemptedStyle == .message ? nil : .message
        }
        if message.contains("Invalid discriminator value") {
            return attemptedStyle.alternate
        }
        return nil
    }

    static func parseChatResponse(from data: Data) -> LMStudioChatResponse? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else {
            return nil
        }

        return LMStudioChatResponse(
            modelInstanceID: payload["model_instance_id"] as? String,
            messageText: joinedText(from: output, type: "message"),
            reasoningText: joinedText(from: output, type: "reasoning"),
            timing: parseTiming(from: payload["stats"] as? [String: Any]),
            tokenUsage: parseTokenUsage(from: payload["stats"] as? [String: Any])
        )
    }

    static func parseLoadResponseInstanceID(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return payload["instance_id"] as? String
    }

    static func modelsCount(from data: Data) -> Int? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else {
            return nil
        }

        return models.count
    }

    static func modelsURL(from baseURLString: String) -> URL? {
        guard let chatURL = ModelProvider.lmStudio.requestURL(from: baseURLString) else {
            return nil
        }
        return chatURL.deletingLastPathComponent().appendingPathComponent("models")
    }

    static func extractLoadedInstanceID(from data: Data, modelName: String, contextLength: Int? = nil) -> String? {
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
            if let instanceID = loadedInstances.firstLoadedInstanceID(matchingContextLength: contextLength) {
                return instanceID
            }
        }

        return nil
    }

    static func hasEquivalentLoadConfiguration(_ lhs: ModelProfileSettings, _ rhs: ModelProfileSettings) -> Bool {
        guard lhs.provider == .lmStudio,
              rhs.provider == .lmStudio,
              let lhsURL = ModelProvider.lmStudio.requestURL(from: lhs.apiBaseURL),
              let rhsURL = ModelProvider.lmStudio.requestURL(from: rhs.apiBaseURL) else {
            return false
        }

        return lhsURL == rhsURL
            && lhs.modelName.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            && lhs.lmStudioContextLength == rhs.lmStudioContextLength
    }

    private static func joinedText(from output: [[String: Any]], type: String) -> String? {
        let text = output
            .filter { ($0["type"] as? String) == type }
            .compactMap { $0["content"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return text.isEmpty ? nil : text
    }

    private static func parseTiming(from stats: [String: Any]?) -> LMStudioTiming? {
        guard let stats else { return nil }

        return LMStudioTiming(
            modelLoadTimeSeconds: doubleValue(from: stats["model_load_time_seconds"]),
            timeToFirstTokenSeconds: doubleValue(from: stats["time_to_first_token_seconds"]),
            totalOutputTokens: intValue(from: stats["total_output_tokens"]),
            tokensPerSecond: doubleValue(from: stats["tokens_per_second"])
        )
    }

    private static func parseTokenUsage(from stats: [String: Any]?) -> LLMTokenUsage? {
        guard let stats else { return nil }

        return LLMTokenUsage(
            inputTokens: intValue(from: stats["input_tokens"]),
            outputTokens: intValue(from: stats["total_output_tokens"]),
            totalTokens: nil,
            reasoningTokens: intValue(from: stats["reasoning_output_tokens"])
        )
    }

    private static func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    fileprivate static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func parseErrorPayload(from body: String) -> (message: String, code: String?, param: String?) {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any] else {
            return (body, nil, nil)
        }

        return (
            error["message"] as? String ?? body,
            error["code"] as? String,
            error["param"] as? String
        )
    }
}

private extension Array where Element == [String: Any] {
    func firstLoadedInstanceID(matchingContextLength contextLength: Int?) -> String? {
        for instance in self {
            if let contextLength {
                guard let config = instance["config"] as? [String: Any],
                      LMStudioAPI.intValue(from: config["context_length"]) == contextLength else {
                    continue
                }
            }

            if let instanceID = (instance["identifier"] as? String) ?? (instance["id"] as? String) {
                return instanceID
            }
        }

        return nil
    }
}
