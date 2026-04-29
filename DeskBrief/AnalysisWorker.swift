import Foundation
import FoundationModels
import ImageIO
import Vision

struct AnalysisExecutionResult {
    let response: AnalysisResponse
    let requestTiming: ModelRequestTiming?
    let lmStudioTiming: LMStudioTiming?
    let ocrText: String?
    let reasoningText: String?
    let modelInstanceID: String?
}

struct ParsedAnalysisPayload: Decodable {
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

nonisolated final class AnalysisWorker: @unchecked Sendable {
    private let llmService: LLMService

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    func analyzeImage(
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

    func analyzeImageDetailed(
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

                guard AnalysisService.shouldRetryAnalysis(after: error, attempt: attempt, maxAttempts: maxAttempts) else {
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
        let imageData = try await imageData(from: fileURL)
        if settings.provider == .appleIntelligence {
            let recognizedText = try await recognizedText(from: imageData, language: settings.appLanguage)
            let response = try await analyzeImageWithAppleIntelligence(
                recognizedText: recognizedText,
                validRules: settings.validCategoryRules,
                summaryInstruction: settings.summaryInstruction,
                language: settings.appLanguage
            )
            return AnalysisExecutionResult(
                response: response,
                requestTiming: nil,
                lmStudioTiming: nil,
                ocrText: recognizedText,
                reasoningText: nil,
                modelInstanceID: nil
            )
        }

        let requestPrompt: String
        let requestImageData: Data?
        let ocrText: String?
        switch settings.imageAnalysisMethod {
        case .ocr:
            let recognizedText = try await recognizedText(from: imageData, language: settings.appLanguage)
            ocrText = recognizedText
            guard !recognizedText.isEmpty else {
                return AnalysisExecutionResult(
                    response: fallbackOCRResponse(validRules: settings.validCategoryRules, language: settings.appLanguage),
                    requestTiming: nil,
                    lmStudioTiming: nil,
                    ocrText: recognizedText,
                    reasoningText: nil,
                    modelInstanceID: nil
                )
            }
            requestPrompt = buildOCRAnalysisPrompt(
                validRules: settings.validCategoryRules,
                summaryInstruction: settings.summaryInstruction,
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
                    settings: settings.screenshotAnalysisModelProfile,
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

        guard let response = AnalysisService.extractAnalysisResponse(from: text, validRules: settings.validCategoryRules) else {
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
            reasoningText: llmResponse.reasoningText,
            modelInstanceID: llmResponse.modelInstanceID
        )
    }

    private func imageData(from fileURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL)
        }.value
    }

    private func recognizedText(from imageData: Data, language: AppLanguage) async throws -> String {
        let recognitionLanguages = Self.recognitionLanguages(for: language)
        return try await Task.detached(priority: .utility) {
            try Self.recognizedText(from: imageData, recognitionLanguages: recognitionLanguages)
        }.value
    }

    private static func recognizedText(from imageData: Data, recognitionLanguages: [String]) throws -> String {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func recognitionLanguages(for language: AppLanguage) -> [String] {
        switch language {
        case .simplifiedChinese:
            return ["zh-Hans", "en-US"]
        case .english:
            return ["en-US", "zh-Hans"]
        }
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
                    settings: ModelProfileSettings(
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
              let parsedResponse = AnalysisService.extractGuidedAnalysisResponse(
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

    private func fallbackAppleIntelligenceResponse(
        validRules: [CategoryRule],
        language: AppLanguage
    ) -> AnalysisResponse {
        AnalysisResponse(
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
            summaryDescription = "对截屏主要工作内容的简短描述。"
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

    private func localized(_ key: L10n.Key, language: AppLanguage) -> String {
        L10n.string(key, language: language)
    }

    private func localized(_ key: L10n.Key, arguments: [CVarArg], language: AppLanguage) -> String {
        L10n.string(key, language: language, arguments: arguments)
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
