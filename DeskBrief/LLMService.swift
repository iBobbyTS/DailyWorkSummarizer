import Foundation
import FoundationModels

struct LLMParameterDescriptor: Equatable {
    let name: String
    let detail: String
}

struct LLMProviderContract: Equatable {
    let requestParameters: [LLMParameterDescriptor]
    let responseParameters: [LLMParameterDescriptor]
}

struct LLMTokenUsage: Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let reasoningTokens: Int?
}

struct LLMServiceRequest {
    let settings: ModelProfileSettings
    let appLanguage: AppLanguage
    let prompt: String
    let imageData: Data?
    let maximumResponseTokens: Int
    let timeoutInterval: TimeInterval
    let appleUseCase: SystemLanguageModel.UseCase
    let appleSchema: GenerationSchema?
}

struct LLMServiceResponse {
    let text: String?
    let structuredContent: GeneratedContent?
    let rawStructuredText: String?
    let finishReason: String?
    let requestTiming: ModelRequestTiming?
    let lmStudioTiming: LMStudioTiming?
    let reasoningText: String?
    let modelInstanceID: String?
    let tokenUsage: LLMTokenUsage?
}

enum LLMServiceError: Error {
    case invalidRemoteConfiguration
    case invalidHTTPResponse
    case missingResponseData
    case httpError(statusCode: Int, body: String)
    case invalidResponseFormat(ModelProvider)
    case missingText(ModelProvider)
    case appleIntelligenceUnavailable(SystemLanguageModel.Availability.UnavailableReason)
    case appleStructuredDecodingFailure(details: String, rawText: String?)
}

private final class LLMURLSessionDataTaskBox: @unchecked Sendable {
    nonisolated(unsafe) var task: URLSessionDataTask?
}

private final class LLMActiveRequestTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var task: URLSessionDataTask?

    nonisolated func set(_ task: URLSessionDataTask?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    nonisolated func clearIfMatching(_ candidate: URLSessionDataTask?) {
        lock.lock()
        if task === candidate {
            task = nil
        }
        lock.unlock()
    }

    nonisolated func cancelCurrentTask() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

final class LLMService: @unchecked Sendable {
    private struct OpenAIResponsePayload {
        let content: String
        let finishReason: String?
        let tokenUsage: LLMTokenUsage?
    }

    private struct AnthropicResponsePayload {
        let content: String
        let stopReason: String?
        let tokenUsage: LLMTokenUsage?
    }

    private struct DataRequestResult {
        let data: Data
        let response: URLResponse
        let roundTripSeconds: TimeInterval
    }

    private let session: URLSession
    private let activeRequestTaskStore = LLMActiveRequestTaskStore()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func providerContract(for provider: ModelProvider) -> LLMProviderContract {
        switch provider {
        case .openAI:
            return LLMProviderContract(
                requestParameters: [
                    LLMParameterDescriptor(name: "Authorization", detail: "Bearer API key header when an API key is configured."),
                    LLMParameterDescriptor(name: "model", detail: "Chat Completions model name."),
                    LLMParameterDescriptor(name: "messages", detail: "Text-only requests send a string content value; multimodal requests send text and image_url parts."),
                    LLMParameterDescriptor(name: "max_tokens", detail: "Maximum output token budget forwarded by the app."),
                ],
                responseParameters: [
                    LLMParameterDescriptor(name: "choices[].message.content", detail: "Assistant text content returned either as a string or text blocks."),
                    LLMParameterDescriptor(name: "choices[].finish_reason", detail: "Stop reason such as stop or length."),
                    LLMParameterDescriptor(name: "usage", detail: "Token accounting including prompt, completion, total, and reasoning token details when available."),
                    LLMParameterDescriptor(name: "openai-processing-ms", detail: "Optional response header for server-side processing time."),
                ]
            )
        case .anthropic:
            return LLMProviderContract(
                requestParameters: [
                    LLMParameterDescriptor(name: "x-api-key", detail: "Anthropic API key header."),
                    LLMParameterDescriptor(name: "anthropic-version", detail: "Required Anthropic API version header."),
                    LLMParameterDescriptor(name: "model", detail: "Messages API model name."),
                    LLMParameterDescriptor(name: "max_tokens", detail: "Maximum output token budget forwarded by the app."),
                    LLMParameterDescriptor(name: "messages", detail: "Stateless conversation array. Multimodal requests send image and text content blocks in one user message."),
                ],
                responseParameters: [
                    LLMParameterDescriptor(name: "content[].text", detail: "Assistant text blocks returned by the Messages API."),
                    LLMParameterDescriptor(name: "stop_reason", detail: "Successful stop reason such as end_turn or max_tokens."),
                    LLMParameterDescriptor(name: "usage", detail: "Input and output token counts."),
                    LLMParameterDescriptor(name: "request-id", detail: "Response header identifying the Anthropic request."),
                ]
            )
        case .lmStudio:
            return LLMProviderContract(
                requestParameters: [
                    LLMParameterDescriptor(name: "Authorization", detail: "Optional Bearer token header when the local server requires authentication."),
                    LLMParameterDescriptor(name: "model", detail: "Loaded model or selected variant name."),
                    LLMParameterDescriptor(name: "input", detail: "Text-only requests use a plain string; multimodal requests use v1 input items with text and image entries, with automatic fallback to the older message discriminator when the server requires it."),
                    LLMParameterDescriptor(name: "store", detail: "Always false in this app so request history is not persisted."),
                    LLMParameterDescriptor(name: "context_length", detail: "Configured prompt context size for the LM Studio v1 chat endpoint."),
                ],
                responseParameters: [
                    LLMParameterDescriptor(name: "output[].type", detail: "Distinguishes message content from reasoning content."),
                    LLMParameterDescriptor(name: "output[].content", detail: "Assistant message text and optional reasoning text blocks."),
                    LLMParameterDescriptor(name: "model_instance_id", detail: "LM Studio model instance identifier echoed by some servers."),
                    LLMParameterDescriptor(name: "stats", detail: "Timing and token stats including model load time, TTFT, output tokens, and tokens per second."),
                    LLMParameterDescriptor(name: "response_id", detail: "Only available when store is not false; this app intentionally does not request it."),
                ]
            )
        case .appleIntelligence:
            return LLMProviderContract(
                requestParameters: [
                    LLMParameterDescriptor(name: "prompt", detail: "Local prompt text passed into LanguageModelSession."),
                    LLMParameterDescriptor(name: "SystemLanguageModel(useCase:)", detail: "On-device use case selection such as general or contentTagging."),
                    LLMParameterDescriptor(name: "GenerationOptions.maximumResponseTokens", detail: "Maximum local output token budget."),
                    LLMParameterDescriptor(name: "GenerationSchema", detail: "Optional guided-generation schema for structured output."),
                ],
                responseParameters: [
                    LLMParameterDescriptor(name: "Response.content", detail: "Plain-text response content for text generations."),
                    LLMParameterDescriptor(name: "GeneratedContent", detail: "Structured content returned by guided generation."),
                    LLMParameterDescriptor(name: "GeneratedContent.jsonString", detail: "Structured raw JSON representation captured for debugging."),
                    LLMParameterDescriptor(name: "transcript", detail: "Session history containing prompts and generated responses."),
                ]
            )
        }
    }

    func cancelActiveRemoteRequest() {
        activeRequestTaskStore.cancelCurrentTask()
    }

    func send(_ request: LLMServiceRequest) async throws -> LLMServiceResponse {
        switch request.settings.provider {
        case .appleIntelligence:
            return try await sendAppleRequest(request)
        case .openAI, .anthropic, .lmStudio:
            return try await sendRemoteRequest(request)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func sendAppleRequest(_ request: LLMServiceRequest) async throws -> LLMServiceResponse {
        guard let unavailableReason = AppleIntelligenceSupport.currentStatus(for: request.appLanguage).unavailableReason else {
            let session = LanguageModelSession(
                model: SystemLanguageModel(useCase: request.appleUseCase)
            )

            if let schema = request.appleSchema {
                return try await sendAppleStructuredRequest(
                    prompt: request.prompt,
                    session: session,
                    schema: schema,
                    maximumResponseTokens: request.maximumResponseTokens
                )
            }

            let response = try await session.respond(
                to: request.prompt,
                options: GenerationOptions(maximumResponseTokens: request.maximumResponseTokens)
            )
            return LLMServiceResponse(
                text: response.content,
                structuredContent: nil,
                rawStructuredText: nil,
                finishReason: nil,
                requestTiming: nil,
                lmStudioTiming: nil,
                reasoningText: nil,
                modelInstanceID: nil,
                tokenUsage: nil
            )
        }

        throw LLMServiceError.appleIntelligenceUnavailable(unavailableReason)
    }

    private func sendAppleStructuredRequest(
        prompt: String,
        session: LanguageModelSession,
        schema: GenerationSchema,
        maximumResponseTokens: Int
    ) async throws -> LLMServiceResponse {
        let stream = session.streamResponse(
            to: prompt,
            schema: schema,
            options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
        )
        var lastRawContent: GeneratedContent?

        do {
            for try await snapshot in stream {
                lastRawContent = snapshot.rawContent
            }
        } catch LanguageModelSession.GenerationError.decodingFailure(let context) {
            throw LLMServiceError.appleStructuredDecodingFailure(
                details: context.debugDescription,
                rawText: capturedAppleResponseText(
                    lastRawContent: lastRawContent,
                    session: session
                )
            )
        }

        let generatedContent = lastRawContent ?? capturedAppleGeneratedContent(from: session)
        return LLMServiceResponse(
            text: nil,
            structuredContent: generatedContent,
            rawStructuredText: capturedAppleResponseText(
                lastRawContent: lastRawContent,
                session: session
            ),
            finishReason: nil,
            requestTiming: nil,
            lmStudioTiming: nil,
            reasoningText: nil,
            modelInstanceID: nil,
            tokenUsage: nil
        )
    }

    private func sendRemoteRequest(_ request: LLMServiceRequest) async throws -> LLMServiceResponse {
        guard let endpoint = request.settings.provider.requestURL(from: request.settings.apiBaseURL) else {
            throw LLMServiceError.invalidRemoteConfiguration
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeoutInterval
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("close", forHTTPHeaderField: "Connection")

        switch request.settings.provider {
        case .openAI:
            if !request.settings.apiKey.isEmpty {
                urlRequest.setValue("Bearer \(request.settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            urlRequest.httpBody = try buildOpenAIRequestBody(
                imageData: request.imageData,
                modelName: request.settings.modelName,
                prompt: request.prompt,
                maximumResponseTokens: request.maximumResponseTokens
            )
        case .anthropic:
            if !request.settings.apiKey.isEmpty {
                urlRequest.setValue(request.settings.apiKey, forHTTPHeaderField: "x-api-key")
            }
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            urlRequest.httpBody = try buildAnthropicRequestBody(
                imageData: request.imageData,
                modelName: request.settings.modelName,
                prompt: request.prompt,
                maximumResponseTokens: request.maximumResponseTokens
            )
        case .lmStudio:
            if !request.settings.apiKey.isEmpty {
                urlRequest.setValue("Bearer \(request.settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .appleIntelligence:
            throw LLMServiceError.invalidRemoteConfiguration
        }

        let requestResult: DataRequestResult
        switch request.settings.provider {
        case .lmStudio:
            requestResult = try await performLMStudioRequest(
                request: request,
                urlRequest: urlRequest
            )
        case .openAI, .anthropic:
            requestResult = try await performDataRequest(for: urlRequest)
        case .appleIntelligence:
            throw LLMServiceError.invalidRemoteConfiguration
        }
        guard let httpResponse = requestResult.response as? HTTPURLResponse else {
            throw LLMServiceError.invalidHTTPResponse
        }

        let rawBody = String(decoding: requestResult.data, as: UTF8.self)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: rawBody)
        }

        switch request.settings.provider {
        case .openAI:
            let payload = try parseOpenAIResponse(from: requestResult.data)
            return LLMServiceResponse(
                text: payload.content,
                structuredContent: nil,
                rawStructuredText: nil,
                finishReason: payload.finishReason,
                requestTiming: ModelRequestTiming(
                    roundTripSeconds: requestResult.roundTripSeconds,
                    serverProcessingSeconds: openAIProcessingSeconds(from: httpResponse)
                ),
                lmStudioTiming: nil,
                reasoningText: nil,
                modelInstanceID: nil,
                tokenUsage: payload.tokenUsage
            )
        case .anthropic:
            let payload = try parseAnthropicResponse(from: requestResult.data)
            return LLMServiceResponse(
                text: payload.content,
                structuredContent: nil,
                rawStructuredText: nil,
                finishReason: payload.stopReason,
                requestTiming: ModelRequestTiming(
                    roundTripSeconds: requestResult.roundTripSeconds,
                    serverProcessingSeconds: nil
                ),
                lmStudioTiming: nil,
                reasoningText: nil,
                modelInstanceID: nil,
                tokenUsage: payload.tokenUsage
            )
        case .lmStudio:
            guard let payload = LMStudioAPI.parseChatResponse(from: requestResult.data) else {
                throw LLMServiceError.invalidResponseFormat(.lmStudio)
            }
            guard let content = payload.content else {
                throw LLMServiceError.missingText(.lmStudio)
            }
            return LLMServiceResponse(
                text: content,
                structuredContent: nil,
                rawStructuredText: nil,
                finishReason: nil,
                requestTiming: ModelRequestTiming(
                    roundTripSeconds: requestResult.roundTripSeconds,
                    serverProcessingSeconds: nil
                ),
                lmStudioTiming: payload.timing,
                reasoningText: payload.reasoningText,
                modelInstanceID: payload.modelInstanceID,
                tokenUsage: payload.tokenUsage
            )
        case .appleIntelligence:
            throw LLMServiceError.invalidRemoteConfiguration
        }
    }

    private func performLMStudioRequest(
        request: LLMServiceRequest,
        urlRequest baseRequest: URLRequest
    ) async throws -> DataRequestResult {
        var attemptedStyle = LMStudioMultimodalTextInputStyle.text
        var urlRequest = baseRequest
        urlRequest.httpBody = try LMStudioAPI.buildChatRequestBody(
            modelName: request.settings.modelName,
            prompt: request.prompt,
            imageData: request.imageData,
            contextLength: request.settings.lmStudioContextLength,
            multimodalTextInputStyle: attemptedStyle
        )

        var requestResult = try await performDataRequest(for: urlRequest)
        guard request.imageData != nil,
              let httpResponse = requestResult.response as? HTTPURLResponse else {
            return requestResult
        }

        let rawBody = String(decoding: requestResult.data, as: UTF8.self)
        guard let fallbackStyle = LMStudioAPI.fallbackMultimodalTextInputStyle(
            statusCode: httpResponse.statusCode,
            responseBody: rawBody,
            attemptedStyle: attemptedStyle
        ) else {
            return requestResult
        }

        attemptedStyle = fallbackStyle
        urlRequest.httpBody = try LMStudioAPI.buildChatRequestBody(
            modelName: request.settings.modelName,
            prompt: request.prompt,
            imageData: request.imageData,
            contextLength: request.settings.lmStudioContextLength,
            multimodalTextInputStyle: attemptedStyle
        )
        requestResult = try await performDataRequest(for: urlRequest)
        return requestResult
    }

    private func buildOpenAIRequestBody(
        imageData: Data?,
        modelName: String,
        prompt: String,
        maximumResponseTokens: Int
    ) throws -> Data {
        let content: Any
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            content = [
                [
                    "type": "text",
                    "text": prompt,
                ],
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
            "max_tokens": maximumResponseTokens,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildAnthropicRequestBody(
        imageData: Data?,
        modelName: String,
        prompt: String,
        maximumResponseTokens: Int
    ) throws -> Data {
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
            "max_tokens": maximumResponseTokens,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func parseOpenAIResponse(from data: Data) throws -> OpenAIResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMServiceError.invalidResponseFormat(.openAI)
        }

        let finishReason = firstChoice["finish_reason"] as? String
        let tokenUsage = parseOpenAITokenUsage(from: payload["usage"] as? [String: Any])

        if let content = message["content"] as? String, !content.isEmpty {
            return OpenAIResponsePayload(
                content: content,
                finishReason: finishReason,
                tokenUsage: tokenUsage
            )
        }

        if let contentBlocks = message["content"] as? [[String: Any]] {
            let text = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty {
                return OpenAIResponsePayload(
                    content: text,
                    finishReason: finishReason,
                    tokenUsage: tokenUsage
                )
            }
        }

        throw LLMServiceError.missingText(.openAI)
    }

    private func parseAnthropicResponse(from data: Data) throws -> AnthropicResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [[String: Any]] else {
            throw LLMServiceError.invalidResponseFormat(.anthropic)
        }

        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else {
            throw LLMServiceError.missingText(.anthropic)
        }

        return AnthropicResponsePayload(
            content: text,
            stopReason: payload["stop_reason"] as? String,
            tokenUsage: parseAnthropicTokenUsage(from: payload["usage"] as? [String: Any])
        )
    }

    private func parseOpenAITokenUsage(from usage: [String: Any]?) -> LLMTokenUsage? {
        guard let usage else { return nil }

        return LLMTokenUsage(
            inputTokens: intValue(from: usage["prompt_tokens"]),
            outputTokens: intValue(from: usage["completion_tokens"]),
            totalTokens: intValue(from: usage["total_tokens"]),
            reasoningTokens: intValue(
                from: (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]
            )
        )
    }

    private func parseAnthropicTokenUsage(from usage: [String: Any]?) -> LLMTokenUsage? {
        guard let usage else { return nil }

        return LLMTokenUsage(
            inputTokens: intValue(from: usage["input_tokens"]),
            outputTokens: intValue(from: usage["output_tokens"]),
            totalTokens: nil,
            reasoningTokens: nil
        )
    }

    private func performDataRequest(for request: URLRequest) async throws -> DataRequestResult {
        let taskBox = LLMURLSessionDataTaskBox()
        let activeRequestTaskStore = self.activeRequestTaskStore

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { [taskBox, activeRequestTaskStore] data, response, error in
                    activeRequestTaskStore.clearIfMatching(taskBox.task)

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data, let response else {
                        continuation.resume(throwing: LLMServiceError.missingResponseData)
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
                activeRequestTaskStore.set(dataTask)
                dataTask.resume()
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }

    private func openAIProcessingSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "openai-processing-ms")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let milliseconds = Double(rawValue) else {
            return nil
        }

        return milliseconds / 1_000
    }

    private func capturedAppleResponseText(
        lastRawContent: GeneratedContent?,
        session: LanguageModelSession
    ) -> String? {
        if let jsonString = lastRawContent?.jsonString.trimmingCharacters(in: .whitespacesAndNewlines),
           !jsonString.isEmpty {
            return jsonString
        }

        if let content = capturedAppleGeneratedContent(from: session)?.jsonString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return content
        }

        return nil
    }

    private func capturedAppleGeneratedContent(from session: LanguageModelSession) -> GeneratedContent? {
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

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
