import Foundation
import FoundationModels
import IOKit.ps

extension AnalysisService {
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
             is LMStudioModelLifecycleError,
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

    nonisolated static func shouldSkipForChargerRequirement(
        trigger: AnalysisTrigger,
        requiresCharger: Bool,
        isConnectedToCharger: Bool
    ) -> Bool {
        let usesChargerRequirement: Bool
        switch trigger {
        case .manual:
            usesChargerRequirement = false
        case .scheduled, .realtime:
            usesChargerRequirement = true
        }
        return usesChargerRequirement && requiresCharger && !isConnectedToCharger
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
}
