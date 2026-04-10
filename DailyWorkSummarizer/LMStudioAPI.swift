import Foundation

struct LMStudioChatResponse {
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

enum LMStudioAPI {
    static func buildChatRequestBody(
        modelName: String,
        prompt: String,
        imageData: Data?,
        contextLength: Int
    ) throws -> Data {
        let input: Any
        if let imageData {
            let imageBase64 = imageData.base64EncodedString()
            input = [
                [
                    "type": "message",
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

    static func parseChatResponse(from data: Data) -> LMStudioChatResponse? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else {
            return nil
        }

        return LMStudioChatResponse(
            messageText: joinedText(from: output, type: "message"),
            reasoningText: joinedText(from: output, type: "reasoning"),
            timing: parseTiming(from: payload["stats"] as? [String: Any]),
            tokenUsage: parseTokenUsage(from: payload["stats"] as? [String: Any])
        )
    }

    static func modelsURL(from baseURLString: String) -> URL? {
        guard let chatURL = ModelProvider.lmStudio.requestURL(from: baseURLString) else {
            return nil
        }
        return chatURL.deletingLastPathComponent().appendingPathComponent("models")
    }

    static func extractLoadedInstanceID(from data: Data, modelName: String) -> String? {
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

    private static func intValue(from value: Any?) -> Int? {
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
