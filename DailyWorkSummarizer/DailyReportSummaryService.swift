import Foundation

private struct ParsedDailyReportPayload: Decodable {
    let dailySummary: String
    let categorySummaries: [String: String]

    private enum CodingKeys: String, CodingKey {
        case dailySummary
        case categorySummaries
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dailySummary = try container.decode(String.self, forKey: .dailySummary)
        categorySummaries = try container.decode([String: String].self, forKey: .categorySummaries)
    }
}

enum DailyReportSummaryServiceError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)
    case noActivity(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .httpError(let statusCode, let body):
            return L10n.string(.analysisHTTPError, arguments: [statusCode, body])
        case .noActivity(let message):
            return message
        }
    }
}

private actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

final class DailyReportSummaryService {
    private struct OpenAIResponsePayload {
        let content: String
    }

    private struct LMStudioResponsePayload {
        let content: String
    }

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let session: URLSession
    private let lock = AsyncLock()

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.session = session ?? Self.makeSession()
    }

    func summarizeMissingDailyReportsIfNeeded() async {
        do {
            try await lock.withLock {
                try await summarizeMissingDailyReportsLocked()
            }
        } catch {
            return
        }
    }

    func summarizeDay(_ dayStart: Date) async throws -> DailyReportRecord {
        try await lock.withLock {
            try await summarizeDayLocked(dayStart)
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

    private func summarizeMissingDailyReportsLocked() async throws {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        guard let latestDayStart = try database.fetchLatestActivityDayStart(calendar: calendar) else {
            return
        }

        let pendingDays = try database.fetchPendingDailyReportDayStarts(
            before: latestDayStart,
            calendar: calendar
        )
        guard !pendingDays.isEmpty else {
            return
        }

        let activityDaySet = Set(try database.fetchActivityDayStarts(calendar: calendar))
        for dayStart in pendingDays {
            do {
                _ = try await summarizeDayLocked(
                    dayStart,
                    snapshot: snapshot,
                    activityDaySet: activityDaySet
                )
            } catch {
                continue
            }
        }
    }

    private func summarizeDayLocked(_ dayStart: Date) async throws -> DailyReportRecord {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let activityDaySet = Set(try database.fetchActivityDayStarts(calendar: calendar))
        return try await summarizeDayLocked(
            dayStart,
            snapshot: snapshot,
            activityDaySet: activityDaySet
        )
    }

    private func summarizeDayLocked(
        _ dayStart: Date,
        snapshot: AppSettingsSnapshot,
        activityDaySet: Set<Date>
    ) async throws -> DailyReportRecord {
        let language = snapshot.appLanguage
        let settings = snapshot.workContentAnalysisModelSettings

        guard !settings.apiBaseURL.isEmpty else {
            throw DailyReportSummaryServiceError.invalidConfiguration(
                localized(.analysisNeedsBaseURL, language: language)
            )
        }

        guard !settings.modelName.isEmpty else {
            throw DailyReportSummaryServiceError.invalidConfiguration(
                localized(.analysisNeedsModelName, language: language)
            )
        }

        let activityItems = try database.fetchDailyReportActivityItems(for: dayStart)
        guard !activityItems.isEmpty else {
            throw DailyReportSummaryServiceError.noActivity(
                localized(.reportDailySummaryNoActivity, language: language)
            )
        }

        let categories = orderedCategories(from: activityItems)
        let prompt = buildPrompt(
            dayStart: dayStart,
            activityItems: activityItems,
            categories: categories,
            summaryInstruction: snapshot.analysisSummaryInstruction,
            language: language
        )
        let payload = try await requestSummary(prompt: prompt, settings: settings, language: language)

        guard let parsed = Self.extractDailyReportResponse(
            from: payload,
            categories: categories
        ) else {
            throw DailyReportSummaryServiceError.invalidResponse(
                localized(.reportDailySummaryInvalidResponse, language: language)
            )
        }

        let calendar = Calendar.reportCalendar(language: language)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let isTemporary = !activityDaySet.contains(nextDayStart)
        let record = storedRecord(
            from: parsed,
            dayStart: dayStart,
            isTemporary: isTemporary
        )

        try database.upsertDailyReport(
            dayStart: dayStart,
            dailySummaryText: record.dailySummaryText,
            categorySummaries: record.categorySummaries
        )

        return record
    }

    private func buildPrompt(
        dayStart: Date,
        activityItems: [DailyReportActivityItem],
        categories: [String],
        summaryInstruction: String,
        language: AppLanguage
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = language.locale
        timeFormatter.timeZone = .current
        timeFormatter.setLocalizedDateFormatFromTemplate("HH:mm")

        let activityLines = activityItems.map { item in
            let durationStyle: DurationDisplayStyle = item.durationMinutes >= 60 ? .hourAndMinute : .minute
            let durationText = L10n.durationText(
                totalMinutes: item.durationMinutes,
                style: durationStyle,
                language: language
            )
            let itemSummary = item.itemSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSummary = (itemSummary?.isEmpty == false)
                ? itemSummary!
                : localized(.reportAbsenceSummaryPlaceholder, language: language)
            return "\(timeFormatter.string(from: item.capturedAt)) | \(durationText) | \(item.categoryName) | \(resolvedSummary)"
        }

        return L10n.dailyReportSummaryPrompt(
            for: dayStart,
            categories: categories,
            activityLines: activityLines,
            summaryInstruction: summaryInstruction,
            language: language
        )
    }

    private func requestSummary(
        prompt: String,
        settings: AnalysisModelSettings,
        language: AppLanguage
    ) async throws -> String {
        guard let endpoint = settings.provider.requestURL(from: settings.apiBaseURL) else {
            throw DailyReportSummaryServiceError.invalidConfiguration(
                localized(.analysisInvalidBaseURL, language: language)
            )
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
                modelName: settings.modelName,
                prompt: prompt
            )
        case .anthropic:
            if !settings.apiKey.isEmpty {
                request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try buildAnthropicRequestBody(
                modelName: settings.modelName,
                prompt: prompt
            )
        case .lmStudio:
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try buildLMStudioRequestBody(
                modelName: settings.modelName,
                prompt: prompt,
                contextLength: settings.lmStudioContextLength
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DailyReportSummaryServiceError.invalidResponse(
                localized(.analysisInvalidHTTPResponse, language: language)
            )
        }

        let rawBody = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DailyReportSummaryServiceError.httpError(statusCode: httpResponse.statusCode, body: rawBody)
        }

        switch settings.provider {
        case .openAI:
            return try parseOpenAIResponse(from: data).content
        case .anthropic:
            return try parseAnthropicResponse(from: data)
        case .lmStudio:
            return try parseLMStudioResponse(from: data).content
        }
    }

    private func buildOpenAIRequestBody(modelName: String, prompt: String) throws -> Data {
        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ]
            ],
            "max_tokens": 900,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildAnthropicRequestBody(modelName: String, prompt: String) throws -> Data {
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 900,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt,
                        ]
                    ]
                ]
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func buildLMStudioRequestBody(
        modelName: String,
        prompt: String,
        contextLength: Int
    ) throws -> Data {
        let body: [String: Any] = [
            "model": modelName,
            "input": [
                [
                    "type": "text",
                    "content": prompt,
                ]
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
            throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisOpenAIFormatInvalid))
        }

        if let content = message["content"] as? String, !content.isEmpty {
            return OpenAIResponsePayload(content: content)
        }

        if let contentBlocks = message["content"] as? [[String: Any]] {
            let text = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty {
                return OpenAIResponsePayload(content: text)
            }
        }

        throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisOpenAINoText))
    }

    private func parseAnthropicResponse(from data: Data) throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [[String: Any]] else {
            throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisAnthropicFormatInvalid))
        }

        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else {
            throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisAnthropicNoText))
        }
        return text
    }

    private func parseLMStudioResponse(from data: Data) throws -> LMStudioResponsePayload {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]] else {
            throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisLMStudioFormatInvalid))
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
            throw DailyReportSummaryServiceError.invalidResponse(localized(.analysisLMStudioNoText))
        }

        return LMStudioResponsePayload(content: text)
    }

    nonisolated static func extractDailyReportResponse(
        from rawText: String,
        categories: [String]
    ) -> (dailySummary: String, categorySummaries: [String: String])? {
        let categorySet = Set(categories)
        let candidates = responseCandidates(from: rawText)

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ParsedDailyReportPayload.self, from: data) else {
                continue
            }

            let dailySummary = payload.dailySummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dailySummary.isEmpty else {
                continue
            }

            let normalizedSummaries = payload.categorySummaries.reduce(into: [String: String]()) { partialResult, entry in
                partialResult[entry.key.trimmingCharacters(in: .whitespacesAndNewlines)] = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard Set(normalizedSummaries.keys) == categorySet,
                  normalizedSummaries.values.allSatisfy({ !$0.isEmpty }) else {
                continue
            }

            return (dailySummary, normalizedSummaries)
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

    private func orderedCategories(from activityItems: [DailyReportActivityItem]) -> [String] {
        var seen = Set<String>()
        return activityItems.compactMap { item in
            if seen.contains(item.categoryName) {
                return nil
            }
            seen.insert(item.categoryName)
            return item.categoryName
        }
    }

    private func storedRecord(
        from payload: (dailySummary: String, categorySummaries: [String: String]),
        dayStart: Date,
        isTemporary: Bool
    ) -> DailyReportRecord {
        let dailySummaryText = storedText(payload.dailySummary, isTemporary: isTemporary)
        let categorySummaries = payload.categorySummaries.mapValues {
            storedText($0, isTemporary: isTemporary)
        }
        return DailyReportRecord(
            dayStart: dayStart,
            dailySummaryText: dailySummaryText,
            categorySummaries: categorySummaries
        )
    }

    private func storedText(_ value: String, isTemporary: Bool) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTemporary, !trimmedValue.hasPrefix(AppDefaults.temporaryReportPrefix) else {
            return trimmedValue
        }
        return AppDefaults.temporaryReportPrefix + trimmedValue
    }

    private func localized(_ key: L10n.Key, language: AppLanguage = .current) -> String {
        L10n.string(key, language: language)
    }
}
