import CoreGraphics
import Foundation
import FoundationModels
import SQLite3
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
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

    @Test func lmStudioLoadRequestAndResponseParsing() async throws {
        let bodyData = try LMStudioAPI.buildLoadRequestBody(
            modelName: "qwen3.5-8b",
            contextLength: 12000
        )
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let payload = """
        {
          "type": "llm",
          "instance_id": "qwen3.5-8b-loaded",
          "status": "loaded",
          "load_config": {
            "context_length": 12000
          }
        }
        """

        #expect(body["model"] as? String == "qwen3.5-8b")
        #expect(body["context_length"] as? Int == 12000)
        #expect(body["echo_load_config"] as? Bool == true)
        #expect(LMStudioAPI.parseLoadResponseInstanceID(from: Data(payload.utf8)) == "qwen3.5-8b-loaded")
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

    @Test func lmStudioMultimodalChatRequestSupportsMessageInputItemsVariant() async throws {
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

    @Test func lmStudioLoadedInstanceMatchingRespectsContextLength() async throws {
        let payload = """
        {
          "models": [
            {
              "key": "qwen3.5-27b",
              "selected_variant": "qwen3.5-27b-instruct",
              "loaded_instances": [
                {
                  "id": "short-context",
                  "config": {
                    "context_length": 6000
                  }
                },
                {
                  "id": "long-context",
                  "config": {
                    "context_length": 12000
                  }
                }
              ]
            }
          ]
        }
        """

        #expect(
            LMStudioAPI.extractLoadedInstanceID(
                from: Data(payload.utf8),
                modelName: "qwen3.5-27b-instruct",
                contextLength: 12000
            ) == "long-context"
        )
        #expect(
            LMStudioAPI.extractLoadedInstanceID(
                from: Data(payload.utf8),
                modelName: "qwen3.5-27b-instruct",
                contextLength: 32000
            ) == nil
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

    @Test func llmServiceLMStudioMultimodalFallsBackToMessageDiscriminatorVariant() async throws {
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
            analysisStartupMode: .scheduled,
            autoAnalysisRequiresCharger: false,
            appLanguage: .simplifiedChinese,
            summaryInstruction: AppDefaults.defaultSummaryInstruction(language: .simplifiedChinese),
            screenshotAnalysisModelProfile: ModelProfileSettings(
                provider: .openAI,
                apiBaseURL: "",
                modelName: "",
                apiKey: "",
                lmStudioContextLength: AppDefaults.lmStudioContextLength,
                imageAnalysisMethod: .ocr
            ),
            workContentSummaryModelProfile: ModelProfileSettings(
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
}
