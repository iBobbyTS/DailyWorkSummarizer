//
//  DailyWorkSummarizerTests.swift
//  DailyWorkSummarizerTests
//
//  Created by iBobby on 2025-12-01.
//

import Foundation
import FoundationModels
import CoreGraphics
import SQLite3
import Testing
@testable import DailyWorkSummarizer

@Suite(.serialized)
@MainActor
struct DailyWorkSummarizerTests {
    @Test func openAICompatibleURLNormalization() async throws {
        let url1 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000")
        let url2 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1")
        let url3 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1/chat/completions")

        #expect(url1?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url2?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url3?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
    }

    @Test func lmStudioURLNormalization() async throws {
        let url1 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234")
        let url2 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api")
        let url3 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1")
        let url4 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1/chat")

        #expect(url1?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url2?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url3?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url4?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
    }

    @Test func lmStudioTextOnlyChatRequestUsesPlainStringInput() async throws {
        let bodyData = try LMStudioAPI.buildChatRequestBody(
            modelName: "qwen3.5-8b",
            prompt: "请总结今天的工作",
            imageData: nil,
            contextLength: 12000
        )
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(body["model"] as? String == "qwen3.5-8b")
        #expect(body["input"] as? String == "请总结今天的工作")
        #expect(body["store"] as? Bool == false)
        #expect(body["context_length"] as? Int == 12000)
    }

    @Test func lmStudioMultimodalChatRequestUsesTextAndImageInputItems() async throws {
        let bodyData = try LMStudioAPI.buildChatRequestBody(
            modelName: "qwen3.5-vl",
            prompt: "请根据图片分析当前工作",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            contextLength: 8000
        )
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])

        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "text")
        #expect(input[0]["content"] as? String == "请根据图片分析当前工作")
        #expect(input[1]["type"] as? String == "image")
        #expect((input[1]["data_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func lmStudioMultimodalChatRequestSupportsLegacyMessageInputItems() async throws {
        let bodyData = try LMStudioAPI.buildChatRequestBody(
            modelName: "qwen3.5-vl",
            prompt: "请根据图片分析当前工作",
            imageData: Data([0xFF, 0xD8, 0xFF]),
            contextLength: 8000,
            multimodalTextInputStyle: .message
        )
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let input = try #require(body["input"] as? [[String: Any]])

        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["content"] as? String == "请根据图片分析当前工作")
        #expect(input[1]["type"] as? String == "image")
    }

    @Test func lmStudioMultimodalFallbackStyleRecognizesBothServerVariants() async throws {
        let textExpectedBody = """
        {
          "error": {
            "message": "Invalid discriminator value. Expected 'text' | 'image'",
            "type": "invalid_request",
            "code": "invalid_union",
            "param": "input"
          }
        }
        """
        let messageExpectedBody = """
        {
          "error": {
            "message": "Invalid discriminator value. Expected 'message' | 'image'",
            "type": "invalid_request",
            "code": "invalid_union",
            "param": "input"
          }
        }
        """

        #expect(
            LMStudioAPI.fallbackMultimodalTextInputStyle(
                statusCode: 400,
                responseBody: textExpectedBody,
                attemptedStyle: .message
            ) == .text
        )
        #expect(
            LMStudioAPI.fallbackMultimodalTextInputStyle(
                statusCode: 400,
                responseBody: messageExpectedBody,
                attemptedStyle: .text
            ) == .message
        )
        #expect(
            LMStudioAPI.fallbackMultimodalTextInputStyle(
                statusCode: 400,
                responseBody: textExpectedBody,
                attemptedStyle: .text
            ) == nil
        )
    }

    @Test func lmStudioChatResponseParsingCapturesReasoningAndTiming() async throws {
        let payload = """
        {
          "model_instance_id": "qwen3.5-0.8b",
          "output": [
            {
              "type": "reasoning",
              "content": "Thinking Process:\\n\\n1. Inspect OCR text"
            },
            {
              "type": "message",
              "content": "{\\"category\\":\\"软件开发\\",\\"summary\\":\\"开发设置页\\"}"
            }
          ],
          "stats": {
            "input_tokens": 953,
            "total_output_tokens": 111,
            "reasoning_output_tokens": 0,
            "tokens_per_second": 183.703360447508,
            "time_to_first_token_seconds": 0.192,
            "model_load_time_seconds": 0.484
          }
        }
        """

        let response = try #require(LMStudioAPI.parseChatResponse(from: Data(payload.utf8)))

        #expect(response.modelInstanceID == "qwen3.5-0.8b")
        #expect(response.content == #"{"category":"软件开发","summary":"开发设置页"}"#)
        #expect(response.reasoningText == "Thinking Process:\n\n1. Inspect OCR text")
        #expect(abs((response.timing?.modelLoadTimeSeconds ?? 0) - 0.484) < 0.000_1)
        #expect(abs((response.timing?.timeToFirstTokenSeconds ?? 0) - 0.192) < 0.000_1)
        #expect(response.timing?.totalOutputTokens == 111)
        #expect(abs((response.timing?.outputTimeSeconds ?? 0) - (111.0 / 183.703360447508)) < 0.000_1)
    }

    @Test func lmStudioChatResponseFallsBackToReasoningWhenNoMessageExists() async throws {
        let payload = """
        {
          "output": [
            {
              "type": "reasoning",
              "content": "Thinking Process:\\n\\nOnly reasoning is available"
            }
          ]
        }
        """

        let response = try #require(LMStudioAPI.parseChatResponse(from: Data(payload.utf8)))

        #expect(response.messageText == nil)
        #expect(response.content == "Thinking Process:\n\nOnly reasoning is available")
    }

    @Test func lmStudioModelHelpersUseModelsEndpointAndSelectedVariant() async throws {
        let modelsURL = LMStudioAPI.modelsURL(from: "http://127.0.0.1:1234")
        let payload = """
        {
          "models": [
            {
              "key": "qwen3.5-27b",
              "selected_variant": "qwen3.5-27b-instruct",
              "loaded_instances": [
                {
                  "identifier": "instance-123"
                }
              ]
            }
          ]
        }
        """

        #expect(modelsURL?.absoluteString == "http://127.0.0.1:1234/api/v1/models")
        #expect(LMStudioAPI.modelsCount(from: Data(payload.utf8)) == 1)
        #expect(
            LMStudioAPI.extractLoadedInstanceID(
                from: Data(payload.utf8),
                modelName: "qwen3.5-27b-instruct"
            ) == "instance-123"
        )
    }

    @Test func llmServiceProviderContractsDescribeSupportedParameters() async throws {
        let openAI = LLMService.providerContract(for: .openAI)
        let anthropic = LLMService.providerContract(for: .anthropic)
        let lmStudio = LLMService.providerContract(for: .lmStudio)
        let apple = LLMService.providerContract(for: .appleIntelligence)

        #expect(openAI.requestParameters.map(\.name).contains("messages"))
        #expect(openAI.responseParameters.map(\.name).contains("choices[].finish_reason"))
        #expect(anthropic.requestParameters.map(\.name).contains("anthropic-version"))
        #expect(anthropic.responseParameters.map(\.name).contains("stop_reason"))
        #expect(lmStudio.requestParameters.map(\.name).contains("context_length"))
        #expect(lmStudio.responseParameters.map(\.name).contains("stats"))
        #expect(apple.requestParameters.map(\.name).contains("GenerationSchema"))
        #expect(apple.responseParameters.map(\.name).contains("GeneratedContent"))
    }

    @Test func llmServiceOpenAIRequestAndResponseNormalization() async throws {
        let settings = makeModelSettings(
            provider: .openAI,
            apiBaseURL: "https://openai.example.com",
            modelName: "gpt-4o-mini",
            apiKey: "openai-key"
        )
        let session = makeMockSession { request in
            #expect(request.url?.absoluteString == "https://openai.example.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")

            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])

            #expect(body["model"] as? String == "gpt-4o-mini")
            #expect(body["max_tokens"] as? Int == 300)
            #expect(messages.count == 1)
            #expect(messages[0]["role"] as? String == "user")
            #expect(messages[0]["content"] as? String == "请总结当前工作")

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"编写 LLMService\\"}"
                  },
                  "finish_reason": "length"
                }
              ],
              "usage": {
                "prompt_tokens": 120,
                "completion_tokens": 45,
                "total_tokens": 165,
                "completion_tokens_details": {
                  "reasoning_tokens": 12
                }
              }
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload,
                headerFields: [
                    "Content-Type": "application/json",
                    "openai-processing-ms": "321"
                ]
            )
        }

        let service = LLMService(session: session)
        let response = try await service.send(
            LLMServiceRequest(
                settings: settings,
                appLanguage: .simplifiedChinese,
                prompt: "请总结当前工作",
                imageData: nil,
                maximumResponseTokens: 300,
                timeoutInterval: 120,
                appleUseCase: .general,
                appleSchema: nil
            )
        )

        #expect(response.text == #"{"category":"专注工作","summary":"编写 LLMService"}"#)
        #expect(response.finishReason == "length")
        #expect(abs((response.requestTiming?.serverProcessingSeconds ?? 0) - 0.321) < 0.000_1)
        #expect(response.tokenUsage?.inputTokens == 120)
        #expect(response.tokenUsage?.outputTokens == 45)
        #expect(response.tokenUsage?.totalTokens == 165)
        #expect(response.tokenUsage?.reasoningTokens == 12)
    }

    @Test func llmServiceAnthropicMultimodalRequestAndResponseNormalization() async throws {
        let settings = makeModelSettings(
            provider: .anthropic,
            apiBaseURL: "https://anthropic.example.com",
            modelName: "claude-4-sonnet",
            apiKey: "anthropic-key"
        )
        let session = makeMockSession { request in
            #expect(request.url?.absoluteString == "https://anthropic.example.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            let imageSource = try #require(content.first?["source"] as? [String: Any])

            #expect(body["model"] as? String == "claude-4-sonnet")
            #expect(body["max_tokens"] as? Int == 300)
            #expect(content.count == 2)
            #expect(content[0]["type"] as? String == "image")
            #expect(imageSource["type"] as? String == "base64")
            #expect(imageSource["media_type"] as? String == "image/jpeg")
            #expect(content[1]["type"] as? String == "text")
            #expect(content[1]["text"] as? String == "根据图片总结当前工作")

            let payload = """
            {
              "content": [
                {
                  "type": "text",
                  "text": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"检查多模态请求\\"}"
                }
              ],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 88,
                "output_tokens": 17
              }
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = LLMService(session: session)
        let response = try await service.send(
            LLMServiceRequest(
                settings: settings,
                appLanguage: .simplifiedChinese,
                prompt: "根据图片总结当前工作",
                imageData: Data([0xFF, 0xD8, 0xFF]),
                maximumResponseTokens: 300,
                timeoutInterval: 120,
                appleUseCase: .general,
                appleSchema: nil
            )
        )

        #expect(response.text == #"{"category":"专注工作","summary":"检查多模态请求"}"#)
        #expect(response.finishReason == "end_turn")
        #expect(response.tokenUsage?.inputTokens == 88)
        #expect(response.tokenUsage?.outputTokens == 17)
    }

    @Test func llmServiceLMStudioRequestAndResponseNormalization() async throws {
        let expectedContextLength = AppDefaults.lmStudioContextLength
        let settings = makeModelSettings(
            provider: .lmStudio,
            apiBaseURL: "http://127.0.0.1:1234",
            modelName: "qwen3.5-8b",
            apiKey: "lmstudio-key"
        )
        let session = makeMockSession { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lmstudio-key")

            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])

            #expect(body["model"] as? String == "qwen3.5-8b")
            #expect(body["input"] as? String == "请总结当前工作")
            #expect(body["store"] as? Bool == false)
            #expect(body["context_length"] as? Int == expectedContextLength)

            let payload = """
            {
              "model_instance_id": "lm-instance-001",
              "output": [
                {
                  "type": "reasoning",
                  "content": "Thinking Process:\\n\\n1. Review OCR content"
                },
                {
                  "type": "message",
                  "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"整理 provider 封装\\"}"
                }
              ],
              "stats": {
                "input_tokens": 91,
                "total_output_tokens": 23,
                "reasoning_output_tokens": 7,
                "tokens_per_second": 46.0,
                "time_to_first_token_seconds": 0.42,
                "model_load_time_seconds": 0.18
              }
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = LLMService(session: session)
        let response = try await service.send(
            LLMServiceRequest(
                settings: settings,
                appLanguage: .simplifiedChinese,
                prompt: "请总结当前工作",
                imageData: nil,
                maximumResponseTokens: 300,
                timeoutInterval: 120,
                appleUseCase: .general,
                appleSchema: nil
            )
        )

        #expect(response.text == #"{"category":"专注工作","summary":"整理 provider 封装"}"#)
        #expect(response.modelInstanceID == "lm-instance-001")
        #expect(response.reasoningText == "Thinking Process:\n\n1. Review OCR content")
        #expect(response.tokenUsage?.inputTokens == 91)
        #expect(response.tokenUsage?.outputTokens == 23)
        #expect(response.tokenUsage?.reasoningTokens == 7)
        #expect(abs((response.lmStudioTiming?.timeToFirstTokenSeconds ?? 0) - 0.42) < 0.000_1)
        #expect(abs((response.lmStudioTiming?.modelLoadTimeSeconds ?? 0) - 0.18) < 0.000_1)
    }

    @Test func llmServiceLMStudioMultimodalFallsBackToLegacyMessageDiscriminator() async throws {
        let settings = makeModelSettings(
            provider: .lmStudio,
            apiBaseURL: "http://127.0.0.1:1234",
            modelName: "qwen3.5-vl",
            apiKey: "lmstudio-key"
        )
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let prompt = "请根据图片总结当前工作"

        defer { MockURLProtocol.reset() }

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1

            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let input = try #require(body["input"] as? [[String: Any]])

            #expect(body["model"] as? String == "qwen3.5-vl")
            #expect(input.count == 2)
            #expect(input[0]["content"] as? String == prompt)
            #expect(input[1]["type"] as? String == "image")

            if MockURLProtocol.requestCount == 1 {
                #expect(input[0]["type"] as? String == "text")
                return try makeHTTPResponse(
                    url: try #require(request.url),
                    body: """
                    {
                      "error": {
                        "message": "Invalid discriminator value. Expected 'message' | 'image'",
                        "type": "invalid_request",
                        "code": "invalid_union",
                        "param": "input"
                      }
                    }
                    """,
                    statusCode: 400
                )
            }

            #expect(MockURLProtocol.requestCount == 2)
            #expect(input[0]["type"] as? String == "message")
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: """
                {
                  "output": [
                    {
                      "type": "message",
                      "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"兼容旧版 LM Studio 多模态输入格式\\"}"
                    }
                  ]
                }
                """
            )
        }

        let service = LLMService(session: session)
        let response = try await service.send(
            LLMServiceRequest(
                settings: settings,
                appLanguage: .simplifiedChinese,
                prompt: prompt,
                imageData: imageData,
                maximumResponseTokens: 300,
                timeoutInterval: 120,
                appleUseCase: .general,
                appleSchema: nil
            )
        )

        #expect(MockURLProtocol.requestCount == 2)
        #expect(response.text == #"{"category":"专注工作","summary":"兼容旧版 LM Studio 多模态输入格式"}"#)
    }

    @Test func nextAnalysisDateFallsToTomorrowWhenTodayIsMissed() async throws {
        var calendar = Calendar.reportCalendar
        calendar.timeZone = TimeZone(identifier: "America/Edmonton") ?? .current

        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 20, minute: 10))!
        let snapshot = AppSettingsSnapshot(
            screenshotIntervalMinutes: 5,
            analysisTimeMinutes: 18 * 60 + 30,
            automaticAnalysisEnabled: true,
            autoAnalysisRequiresCharger: false,
            appLanguage: .simplifiedChinese,
            analysisSummaryInstruction: AppDefaults.defaultAnalysisSummaryInstruction(language: .simplifiedChinese),
            screenshotAnalysisModelSettings: AnalysisModelSettings(
                provider: .openAI,
                apiBaseURL: "",
                modelName: "",
                apiKey: "",
                lmStudioContextLength: AppDefaults.lmStudioContextLength,
                imageAnalysisMethod: .ocr
            ),
            workContentAnalysisModelSettings: AnalysisModelSettings(
                provider: .openAI,
                apiBaseURL: "",
                modelName: "",
                apiKey: "",
                lmStudioContextLength: AppDefaults.lmStudioContextLength,
                imageAnalysisMethod: .ocr
            ),
            categoryRules: []
        )

        let next = snapshot.nextAnalysisDate(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)

        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 14)
        #expect(components.hour == 18)
        #expect(components.minute == 30)
    }

    @Test func absenceRequiresSameMouseLocationAndSameFrontmostApp() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.Safari"
        )

        #expect(shouldRecord)
    }

    @Test func absenceDoesNotRecordWhenFrontmostAppChanges() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.dt.Xcode"
        )

        #expect(!shouldRecord)
    }

    @Test func retryPolicyRetriesServerAndInvalidResponseErrorsBeforeMaxAttempts() async throws {
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.httpError(statusCode: 500, body: "server error"),
                attempt: 1
            )
        )
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("no output"),
                attempt: 2
            )
        )
    }

    @Test func retryPolicyDoesNotRetryLengthOrFourthAttempt() async throws {
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.lengthTruncated("truncated"),
                attempt: 1
            )
        )
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("invalid category"),
                attempt: 3
            )
        )
    }

    @Test func pauseAfterFiveConsecutiveFailures() async throws {
        #expect(!AnalysisService.shouldPauseAfterConsecutiveFailures(4))
        #expect(AnalysisService.shouldPauseAfterConsecutiveFailures(5))
    }

    @Test func lmStudioPauseTransitionsToUnloadStageAfterGenerationStops() async throws {
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .lmStudio) == .unloadingModel)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .openAI) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .anthropic) == nil)
        #expect(AnalysisService.stoppingStageAfterGenerationStops(for: .appleIntelligence) == nil)
    }

    @Test func pausingStagesUseDistinctMenuLabels() async throws {
        #expect(
            L10n.string(.menuAnalyzeNowPausingStoppingGeneration, language: .simplifiedChinese)
                == "正在暂停（正在停止生成）"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingUnloadingModel, language: .simplifiedChinese)
                == "正在暂停（正在卸载模型）"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingStoppingGeneration, language: .english)
                == "Stopping (Stopping Generation)"
        )
        #expect(
            L10n.string(.menuAnalyzeNowPausingUnloadingModel, language: .english)
                == "Stopping (Unloading Model)"
        )
    }

    @Test func runtimeErrorRecordingFiltersOutNonAPIErrors() async throws {
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidResponse("empty output")))
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.httpError(statusCode: 500, body: "server error")))
        #expect(!AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidConfiguration("missing url")))
        #expect(!AnalysisService.shouldRecordRuntimeError(CancellationError()))
    }

    @Test func analysisPromptIncludesSummaryInstructionAndJSONContract() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let instruction = "请关注课程名称和项目仓库名"

        let prompt = L10n.analysisPrompt(
            with: rules,
            summaryInstruction: instruction,
            language: .simplifiedChinese
        )

        #expect(prompt.contains("描述要求："))
        #expect(prompt.contains(instruction))
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("专注工作：写代码和做项目"))
    }

    @Test func analysisResponseParsingHandlesThinkAndCodeFenceJSON() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
            CategoryRule(name: "上课学习", description: "上课或完成课程作业"),
        ]
        let rawText = """
        <think>先看一下窗口内容</think>
        ```json
        {"category":"专注工作","summary":"开发 DailyWorkSummarizer 菜单栏项目"}
        ```
        """

        let response = AnalysisService.extractAnalysisResponse(from: rawText, validRules: rules)

        #expect(response?.category == "专注工作")
        #expect(response?.summary == "开发 DailyWorkSummarizer 菜单栏项目")
    }

    @Test func analysisResponseParsingRejectsInvalidStructuredPayloads() async throws {
        let rules = [
            CategoryRule(name: "专注工作", description: "写代码和做项目"),
        ]

        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"错误类别","summary":"开发项目"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作","summary":"   "}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: #"{"category":"专注工作"}"#,
                validRules: rules
            ) == nil
        )
        #expect(
            AnalysisService.extractAnalysisResponse(
                from: "专注工作",
                validRules: rules
            ) == nil
        )
    }

    @Test func defaultCategoryRulesAlwaysAppendPreservedOther() async throws {
        let chineseRules = AppDefaults.defaultCategoryRules(language: .simplifiedChinese)
        let englishRules = AppDefaults.defaultCategoryRules(language: .english)

        #expect(chineseRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(englishRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(chineseRules.last?.description == AppDefaults.preservedOtherCategoryDescription(language: .simplifiedChinese))
    }

    @MainActor
    @Test func settingsStorePersistsSummaryInstruction() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let updatedInstruction = "最近在做操作系统课程项目和 DailyWorkSummarizer 重构"

        #expect(
            store.analysisSummaryInstruction == AppDefaults.defaultAnalysisSummaryInstruction(language: .simplifiedChinese)
        )

        store.analysisSummaryInstruction = updatedInstruction

        let reloadedStore = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        #expect(store.snapshot.analysisSummaryInstruction == updatedInstruction)
        #expect(reloadedStore.analysisSummaryInstruction == updatedInstruction)
        #expect(reloadedStore.workContentProvider == store.provider)
    }

    @MainActor
    @Test func settingsStoreKeepsPreservedOtherLastAndRejectsReservedPrefixNames() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        try database.replaceCategoryRules([
            CategoryRule(name: "专注工作", description: "写代码"),
        ])

        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        let editableRuleID = try #require(store.categoryRules.first?.id)
        let preservedRule = try #require(store.categoryRules.last)

        #expect(store.categoryRules.count == 2)
        #expect(preservedRule.name == AppDefaults.preservedOtherCategoryName)

        store.updateCategoryRuleName(id: editableRuleID, name: "PRESERVED_TEST")

        #expect(store.categoryRules.first?.name == "专注工作")
        #expect(
            store.categoryRulesValidationMessage
            == L10n.string(.settingsAnalysisReservedPrefixError, language: .simplifiedChinese)
        )

        store.addCategoryRule()
        let newlyAddedRule = try #require(store.categoryRules.dropLast().last)
        store.updateCategoryRuleName(id: newlyAddedRule.id, name: "课程学习")

        let preservedRuleID = try #require(store.categoryRules.last?.id)
        store.updateCategoryRuleDescription(id: preservedRuleID, description: "用户自定义的其他内容描述")

        #expect(store.categoryRules.last?.name == AppDefaults.preservedOtherCategoryName)
        #expect(store.categoryRules.dropLast().last?.name == "课程学习")
        #expect(store.categoryRules.last?.description == "用户自定义的其他内容描述")
    }

    @MainActor
    @Test func settingsStoreCanCopyModelConfigurationBetweenTabs() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)

        store.provider = .anthropic
        store.apiBaseURL = "https://screenshot.example.com"
        store.modelName = "claude-screenshot"
        store.apiKey = "screenshot-key"
        store.lmStudioContextLength = 8192

        store.copyScreenshotAnalysisModelToWorkContent()

        #expect(store.workContentProvider == .anthropic)
        #expect(store.workContentAPIBaseURL == "https://screenshot.example.com")
        #expect(store.workContentModelName == "claude-screenshot")
        #expect(store.workContentAPIKey == "screenshot-key")

        store.workContentProvider = .lmStudio
        store.workContentAPIBaseURL = "http://127.0.0.1:1234"
        store.workContentModelName = "work-content-model"
        store.workContentAPIKey = "work-content-key"
        store.workContentLMStudioContextLength = 12000

        store.copyWorkContentModelToScreenshotAnalysis()

        #expect(store.provider == .lmStudio)
        #expect(store.apiBaseURL == "http://127.0.0.1:1234")
        #expect(store.modelName == "work-content-model")
        #expect(store.apiKey == "work-content-key")
        #expect(store.lmStudioContextLength == 12000)
    }

    @Test func databaseMigratesAnalysisResultsSchemaToSummaryOnly() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let handle = try openSQLite(at: databaseURL)

        try executeSQL("""
            CREATE TABLE analysis_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scheduled_for DOUBLE NOT NULL,
                started_at DOUBLE NOT NULL,
                finished_at DOUBLE,
                status TEXT NOT NULL,
                provider TEXT NOT NULL,
                base_url TEXT NOT NULL,
                model_name TEXT NOT NULL,
                prompt_snapshot TEXT NOT NULL,
                category_snapshot_json TEXT NOT NULL,
                total_items INTEGER NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                average_item_duration_seconds DOUBLE,
                error_message TEXT,
                created_at DOUBLE NOT NULL
            );
        """, on: handle)
        try executeSQL("""
            INSERT INTO analysis_runs (
                id, scheduled_for, started_at, finished_at, status, provider, base_url, model_name,
                prompt_snapshot, category_snapshot_json, total_items, success_count, failure_count,
                average_item_duration_seconds, error_message, created_at
            )
            VALUES (1, 0, 0, 0, 'succeeded', 'openai', '', '', '', '[]', 1, 1, 0, NULL, NULL, 0);
        """, on: handle)
        try executeSQL("""
            CREATE TABLE analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id INTEGER NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                raw_response_text TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                duration_minutes_snapshot INTEGER NOT NULL,
                created_at DOUBLE NOT NULL
            );
        """, on: handle)
        try executeSQL("""
            INSERT INTO analysis_results (
                id, run_id, captured_at, category_name, raw_response_text, status, error_message,
                duration_minutes_snapshot, created_at
            )
            VALUES (1, 1, 0, '专注工作', '{"category":"专注工作","summary":"旧数据"}', 'succeeded', NULL, 5, 0);
        """, on: handle)

        sqlite3_close(handle)

        _ = try AppDatabase(databaseURL: databaseURL)

        let columns = try columnNames(in: "analysis_results", databaseURL: databaseURL)
        let summaryText = try fetchOptionalString(
            "SELECT summary_text FROM analysis_results WHERE id = 1;",
            databaseURL: databaseURL
        )

        #expect(columns.contains("summary_text"))
        #expect(!columns.contains("raw_response_text"))
        #expect(summaryText == nil)
    }

    @Test func databaseStoresCategoryAndSummaryWithoutRawResponseText() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let runID = try database.createAnalysisRun(
            scheduledFor: Date(timeIntervalSince1970: 0),
            provider: .openAI,
            baseURL: "http://127.0.0.1:8000",
            modelName: "gpt-test",
            promptSnapshot: "prompt",
            categorySnapshotJSON: "[]",
            totalItems: 1
        )

        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: Date(timeIntervalSince1970: 60),
            categoryName: "专注工作",
            summaryText: "开发 DailyWorkSummarizer 项目",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 5
        )

        let columns = try columnNames(in: "analysis_results", databaseURL: databaseURL)
        let categoryName = try fetchOptionalString(
            "SELECT category_name FROM analysis_results WHERE run_id = \(runID);",
            databaseURL: databaseURL
        )
        let summaryText = try fetchOptionalString(
            "SELECT summary_text FROM analysis_results WHERE run_id = \(runID);",
            databaseURL: databaseURL
        )

        #expect(columns.contains("summary_text"))
        #expect(!columns.contains("raw_response_text"))
        #expect(categoryName == "专注工作")
        #expect(summaryText == "开发 DailyWorkSummarizer 项目")
    }

    @Test func dailyReportPromptIncludesActivitiesAndJSONContract() async throws {
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let prompt = L10n.dailyReportSummaryPrompt(
            for: dayStart,
            categories: ["专注工作", "离开"],
            activityLines: [
                "09:00 | 30分钟 | 专注工作 | 开发 DailyWorkSummarizer 报告页",
                "10:00 | 5分钟 | 离开 | 离开工位"
            ],
            summaryInstruction: "请突出项目名和课程名",
            language: .simplifiedChinese
        )

        #expect(prompt.contains("请突出项目名和课程名"))
        #expect(prompt.contains("\"dailySummary\""))
        #expect(prompt.contains("\"categorySummaries\""))
        #expect(prompt.contains("专注工作"))
        #expect(prompt.contains("10:00 | 5分钟 | 离开 | 离开工位"))
    }

    @Test func dailyReportResponseParsingHandlesThinkAndCodeFenceJSON() async throws {
        let rawText = """
        <think>先整理一下当天内容</think>
        ```json
        {"dailySummary":"推进了 DailyWorkSummarizer 的日报总结功能","categorySummaries":{"专注工作":"完成日报总结链路开发","离开":"有短暂离开工位的时间"}}
        ```
        """

        let response = DailyReportSummaryService.extractDailyReportResponse(
            from: rawText,
            categories: ["专注工作", "离开"]
        )

        #expect(response?.dailySummary == "推进了 DailyWorkSummarizer 的日报总结功能")
        #expect(response?.categorySummaries["专注工作"] == "完成日报总结链路开发")
        #expect(response?.categorySummaries["离开"] == "有短暂离开工位的时间")
    }

    @Test func dailyReportResponseParsingRejectsInvalidCategorySummaryShape() async throws {
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"日报","categorySummaries":{"专注工作":"工作总结"}}"#,
                categories: ["专注工作", "离开"]
            ) == nil
        )
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"日报","categorySummaries":{"专注工作":"工作总结","离开":"离开总结","额外分类":"无效"}}"#,
                categories: ["专注工作", "离开"]
            ) == nil
        )
        #expect(
            DailyReportSummaryService.extractDailyReportResponse(
                from: #"{"dailySummary":"  ","categorySummaries":{"专注工作":"工作总结","离开":"离开总结"}}"#,
                categories: ["专注工作", "离开"]
            ) == nil
        )
    }

    @Test func databaseCreatesAndUpsertsDailyReports() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11))!

        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "第一次日报",
            categorySummaries: ["专注工作": "第一次分类总结"]
        )
        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: "第二次日报",
            categorySummaries: ["专注工作": "第二次分类总结"]
        )

        let columns = try columnNames(in: "daily_reports", databaseURL: databaseURL)
        let fetchedReport = try database.fetchDailyReport(for: dayStart)
        let report = try #require(fetchedReport)

        #expect(columns.contains("day_start"))
        #expect(columns.contains("daily_summary_text"))
        #expect(columns.contains("category_summaries_json"))
        #expect(report.dailySummaryText == "第二次日报")
        #expect(report.categorySummaries["专注工作"] == "第二次分类总结")
    }

    @Test func databaseCreatesAndFetchesAppLogs() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let entry = AppLogEntry(
            createdAt: Date(timeIntervalSince1970: 120),
            level: .error,
            source: .analysis,
            message: "模型返回格式错误"
        )

        try database.insertAppLog(entry)

        let columns = try columnNames(in: "app_logs", databaseURL: databaseURL)
        let logs = try database.fetchAppLogs()

        #expect(columns == ["id", "created_at", "level", "source", "message"])
        #expect(logs.count == 1)
        #expect(logs.first?.id == entry.id)
        #expect(logs.first?.level == .error)
        #expect(logs.first?.source == .analysis)
        #expect(logs.first?.message == "模型返回格式错误")
    }

    @Test func appLogStorePersistsAcrossReloadAndPrunesOldEntries() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = AppLogStore(database: database, maxEntries: 3)

        store.add(level: .error, source: .analysis, message: "first", createdAt: Date(timeIntervalSince1970: 1))
        store.add(level: .log, source: .analysis, message: "second", createdAt: Date(timeIntervalSince1970: 2))
        store.add(level: .error, source: .analysis, message: "third", createdAt: Date(timeIntervalSince1970: 3))
        store.add(level: .log, source: .analysis, message: "fourth", createdAt: Date(timeIntervalSince1970: 4))

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.message) == ["fourth", "third", "second"])

        let reloadedStore = AppLogStore(database: database, maxEntries: 3)
        #expect(reloadedStore.entries.count == 3)
        #expect(reloadedStore.entries.map(\.message) == ["fourth", "third", "second"])
    }

    @Test func appLogStoreRemoveAndClearPersistToDatabase() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = AppLogStore(database: database)

        store.add(level: .error, source: .analysis, message: "first", createdAt: Date(timeIntervalSince1970: 1))
        store.add(level: .log, source: .analysis, message: "second", createdAt: Date(timeIntervalSince1970: 2))

        let removedID = try #require(store.entries.last?.id)
        store.remove(id: removedID)

        let remainingAfterRemove = try database.fetchAppLogs()
        #expect(remainingAfterRemove.count == 1)
        #expect(remainingAfterRemove.first?.message == "second")

        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(try database.fetchAppLogs().isEmpty)
    }

    @Test func appLogFilterAndMenuLocalizationReflectLogUI() async throws {
        #expect(AppLogFilter.all.includes(level: .error))
        #expect(AppLogFilter.all.includes(level: .log))
        #expect(AppLogFilter.error.includes(level: .error))
        #expect(!AppLogFilter.error.includes(level: .log))
        #expect(AppLogFilter.log.includes(level: .log))
        #expect(!AppLogFilter.log.includes(level: .error))

        #expect(L10n.string(.menuShowLogs, language: .simplifiedChinese) == "显示日志")
        #expect(L10n.string(.menuShowLogs, language: .english) == "Show Logs")
        #expect(L10n.string(.logsEmptyTitle, language: .simplifiedChinese) == "当前没有日志")
        #expect(L10n.string(.logsClearAll, language: .english) == "Clear All Logs")
        #expect(AppLogFilter.all.title(in: .simplifiedChinese) == "全部")
        #expect(AppLogFilter.error.title(in: .english) == "Error")
        #expect(AppLogFilter.log.title(in: .english) == "Log")
    }

    @Test func latestActivityDayStartIncludesAbsenceEvents() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = try AppDatabase(databaseURL: databaseURL)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 10))!
        let runID = try makeAnalysisRun(database: database)

        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: dayOne,
            categoryName: "专注工作",
            summaryText: "开发项目",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 5
        )
        try database.recordAbsenceEvent(capturedAt: dayTwo, durationMinutes: 5)

        let latestDayStart = try database.fetchLatestActivityDayStart(calendar: calendar)

        #expect(latestDayStart == calendar.startOfDay(for: dayTwo))
    }

    @MainActor
    @Test func dailyReportSummaryServiceUsesWorkContentModelAndMarksIncompleteDayTemporary() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!
        let captureTime = calendar.date(byAdding: .hour, value: 9, to: dayStart)!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.provider = .anthropic
        store.apiBaseURL = "https://screenshot.invalid"
        store.modelName = "screenshot-model"
        store.workContentProvider = .openAI
        store.workContentAPIBaseURL = "https://work-content.example.com"
        store.workContentModelName = "work-content-model"
        store.analysisSummaryInstruction = "请突出项目名"

        let runID = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: captureTime,
            categoryName: "专注工作",
            summaryText: "开发 DailyWorkSummarizer 日报功能",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 30
        )

        let session = makeMockSession { request in
            let requestBody = try #require(requestBodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            MockURLProtocol.lastRequestedModel = body["model"] as? String

            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了 DailyWorkSummarizer 日报总结开发\\",\\"categorySummaries\\":{\\"专注工作\\":\\"实现了日报总结服务与报告页展示\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        let report = try await service.summarizeDay(dayStart)
        let fetchedStoredReport = try database.fetchDailyReport(for: dayStart)
        let storedReport = try #require(fetchedStoredReport)

        #expect(MockURLProtocol.lastRequestedModel == "work-content-model")
        #expect(report.isTemporary)
        #expect(storedReport.isTemporary)
        #expect(storedReport.displayDailySummaryText == "完成了 DailyWorkSummarizer 日报总结开发")
        #expect(storedReport.displayCategorySummary(for: "专注工作") == "实现了日报总结服务与报告页展示")
    }

    @MainActor
    @Test func dailyReportSummaryServiceSummarizesOnlyPendingDaysBeforeLatestActivityDay() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let suiteName = "DailyWorkSummarizerTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let keychain = KeychainStore(service: suiteName)
        let calendar = makeTestCalendar()
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            keychain.set("", for: AppDefaults.apiKeyAccount)
            keychain.set("", for: AppDefaults.workContentAPIKeyAccount)
            try? FileManager.default.removeItem(at: databaseURL)
            MockURLProtocol.reset()
        }

        let database = try AppDatabase(databaseURL: databaseURL)
        let store = SettingsStore(database: database, userDefaults: userDefaults, keychain: keychain)
        store.workContentProvider = .openAI
        store.workContentAPIBaseURL = "https://work-content.example.com"
        store.workContentModelName = "daily-report-model"

        let runID = try makeAnalysisRun(database: database)
        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: calendar.date(byAdding: .hour, value: 9, to: dayOne)!,
            categoryName: "专注工作",
            summaryText: "整理日报需求",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 30
        )
        try database.insertAnalysisResult(
            runID: runID,
            capturedAt: calendar.date(byAdding: .hour, value: 10, to: dayTwo)!,
            categoryName: "专注工作",
            summaryText: "继续开发第二天功能",
            status: "succeeded",
            errorMessage: nil,
            durationMinutesSnapshot: 30
        )
        try database.upsertDailyReport(
            dayStart: dayOne,
            dailySummaryText: "TEMP_旧的临时日报",
            categorySummaries: ["专注工作": "TEMP_旧的临时分类总结"]
        )

        let session = makeMockSession { request in
            MockURLProtocol.requestCount += 1
            let payload = """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"dailySummary\\":\\"完成了第一天的最终日报总结\\",\\"categorySummaries\\":{\\"专注工作\\":\\"完成了第一天的最终分类总结\\"}}"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """

            return try makeHTTPResponse(
                url: try #require(request.url),
                body: payload
            )
        }

        let service = DailyReportSummaryService(database: database, settingsStore: store, session: session)
        await service.summarizeMissingDailyReportsIfNeeded()

        let fetchedFirstDayReport = try database.fetchDailyReport(for: dayOne)
        let firstDayReport = try #require(fetchedFirstDayReport)
        let secondDayReport = try database.fetchDailyReport(for: dayTwo)

        #expect(MockURLProtocol.requestCount == 1)
        #expect(!firstDayReport.isTemporary)
        #expect(firstDayReport.dailySummaryText == "完成了第一天的最终日报总结")
        #expect(firstDayReport.categorySummaries["专注工作"] == "完成了第一天的最终分类总结")
        #expect(secondDayReport == nil)
    }
}

private func makeTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func openSQLite(at url: URL) throws -> OpaquePointer? {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        sqlite3_close(handle)
        throw DatabaseError.openDatabase(message)
    }
    return handle
}

private func executeSQL(_ sql: String, on handle: OpaquePointer?) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.execute(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite exec failed")
    }
}

private func columnNames(in table: String, databaseURL: URL) throws -> [String] {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 1) {
            columns.append(String(cString: text))
        }
    }
    return columns
}

private func fetchOptionalString(_ sql: String, databaseURL: URL) throws -> String? {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        return nil
    }
    guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, 0) else {
        return nil
    }
    return String(cString: text)
}

private func makeTestCalendar() -> Calendar {
    var calendar = Calendar.reportCalendar(language: .simplifiedChinese)
    calendar.timeZone = TimeZone(identifier: "America/Edmonton") ?? .current
    return calendar
}

private func makeAnalysisRun(database: AppDatabase) throws -> Int64 {
    try database.createAnalysisRun(
        scheduledFor: Date(timeIntervalSince1970: 0),
        provider: .openAI,
        baseURL: "https://example.com",
        modelName: "test-model",
        promptSnapshot: "prompt",
        categorySnapshotJSON: "[]",
        totalItems: 1
    )
}

private func makeModelSettings(
    provider: ModelProvider,
    apiBaseURL: String,
    modelName: String,
    apiKey: String = ""
) -> AnalysisModelSettings {
    AnalysisModelSettings(
        provider: provider,
        apiBaseURL: apiBaseURL,
        modelName: modelName,
        apiKey: apiKey,
        lmStudioContextLength: AppDefaults.lmStudioContextLength,
        imageAnalysisMethod: .ocr
    )
}

private func makeMockSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200,
    headerFields: [String: String] = ["Content-Type": "application/json"]
) throws -> (HTTPURLResponse, Data) {
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headerFields
    ) else {
        throw URLError(.badServerResponse)
    }
    return (response, Data(body.utf8))
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        guard readCount > 0 else {
            break
        }
        data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0
    static var lastRequestedModel: String?

    static func reset() {
        requestHandler = nil
        requestCount = 0
        lastRequestedModel = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
