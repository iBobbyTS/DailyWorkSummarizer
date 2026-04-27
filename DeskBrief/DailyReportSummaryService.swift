import FoundationModels
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

enum DailyReportLMStudioLifecyclePolicy {
    case automaticUnload
    case alreadyLoadedKeepLoaded
    case loadAndKeepLoaded
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
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let llmService: LLMService
    private let lmStudioLifecycle: LMStudioModelLifecycle
    private let lock = AsyncLock()

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore? = nil,
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        let resolvedSession = session ?? Self.makeSession()
        self.llmService = LLMService(session: resolvedSession)
        self.lmStudioLifecycle = LMStudioModelLifecycle(session: resolvedSession) { [weak settingsStore, weak logStore] chinese, english in
            Task { @MainActor in
                guard let logStore else { return }
                let language = settingsStore?.appLanguage ?? .current
                let message = language == .simplifiedChinese ? chinese : english
                logStore.add(level: .log, source: .lmStudio, message: message)
            }
        }
    }

    func summarizeMissingDailyReportsIfNeeded(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy = .automaticUnload
    ) async {
        do {
            try await lock.withLock {
                try await summarizeMissingDailyReportsLocked(lmStudioLifecyclePolicy: lmStudioLifecyclePolicy)
            }
        } catch {
            return
        }
    }

    func summarizeDay(_ dayStart: Date) async throws -> DailyReportRecord {
        try await lock.withLock {
            try await summarizeDayLocked(dayStart, lmStudioLifecyclePolicy: .automaticUnload)
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

    private func summarizeMissingDailyReportsLocked(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    ) async throws {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let reportableDayStarts = try fetchReportableActivityDayStarts(calendar: calendar)
        guard let latestDayStart = reportableDayStarts.last else {
            return
        }

        let pendingDays = try pendingReportableDayStarts(
            in: reportableDayStarts,
            before: latestDayStart
        )
        guard !pendingDays.isEmpty else {
            return
        }

        let activityDaySet = Set(reportableDayStarts)
        try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            for dayStart in pendingDays {
                do {
                    _ = try await summarizeDayContentLocked(
                        dayStart,
                        snapshot: snapshot,
                        activityDaySet: activityDaySet
                    )
                } catch {
                    continue
                }
            }
        }
    }

    private func summarizeDayLocked(
        _ dayStart: Date,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    ) async throws -> DailyReportRecord {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let activityDaySet = Set(try fetchReportableActivityDayStarts(calendar: calendar))
        return try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            try await summarizeDayContentLocked(
                dayStart,
                snapshot: snapshot,
                activityDaySet: activityDaySet
            )
        }
    }

    private func summarizeDayContentLocked(
        _ dayStart: Date,
        snapshot: AppSettingsSnapshot,
        activityDaySet: Set<Date>
    ) async throws -> DailyReportRecord {
        let language = snapshot.appLanguage
        let settings = snapshot.workContentSummaryModelProfile

        if settings.provider.requiresRemoteConfiguration {
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
        }

        let calendar = Calendar.reportCalendar(language: language)
        let activityItems = try fetchReportableActivityItems(for: dayStart, calendar: calendar)
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
            summaryInstruction: snapshot.summaryInstruction,
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

    private func withLMStudioLifecycleIfNeeded<T>(
        settings: ModelProfileSettings,
        policy: DailyReportLMStudioLifecyclePolicy,
        operation: () async throws -> T
    ) async throws -> T {
        guard settings.provider == .lmStudio else {
            return try await operation()
        }

        switch policy {
        case .alreadyLoadedKeepLoaded:
            return try await operation()
        case .loadAndKeepLoaded:
            _ = try await lmStudioLifecycle.load(settings: settings)
            return try await operation()
        case .automaticUnload:
            let loadedModel = try await lmStudioLifecycle.load(settings: settings)
            do {
                let result = try await operation()
                try? await lmStudioLifecycle.unload(settings: settings, instanceID: loadedModel.instanceID)
                return result
            } catch {
                try? await lmStudioLifecycle.unload(settings: settings, instanceID: loadedModel.instanceID)
                throw error
            }
        }
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

    private func fetchReportableActivityItems(for dayStart: Date, calendar: Calendar) throws -> [DailyReportActivityItem] {
        try database.fetchDailyReportActivityItems(for: dayStart, calendar: calendar)
            .filter { Self.isReportableCategory($0.categoryName) }
    }

    private func fetchReportableActivityDayStarts(calendar: Calendar) throws -> [Date] {
        let dayStarts = try database.fetchReportSourceItems()
            .filter { Self.isReportableCategory($0.categoryName) }
            .map { calendar.startOfDay(for: $0.capturedAt) }
        return Array(Set(dayStarts)).sorted()
    }

    private func pendingReportableDayStarts(
        in dayStarts: [Date],
        before dayStartExclusive: Date
    ) throws -> [Date] {
        try dayStarts
            .filter { $0 < dayStartExclusive }
            .filter { dayStart in
                guard let report = try database.fetchDailyReport(for: dayStart) else {
                    return true
                }
                return report.isTemporary
            }
    }

    private static func isReportableCategory(_ categoryName: String) -> Bool {
        categoryName != AppDefaults.absenceCategoryName
    }

    private func requestSummary(
        prompt: String,
        settings: ModelProfileSettings,
        language: AppLanguage
    ) async throws -> String {
        do {
            let response = try await llmService.send(
                LLMServiceRequest(
                    settings: settings,
                    appLanguage: language,
                    prompt: prompt,
                    imageData: nil,
                    maximumResponseTokens: 900,
                    timeoutInterval: 120,
                    appleUseCase: .general,
                    appleSchema: nil
                )
            )
            guard let text = response.text else {
                throw DailyReportSummaryServiceError.invalidResponse(
                    localized(.reportDailySummaryInvalidResponse, language: language)
                )
            }
            return text
        } catch let error as LLMServiceError {
            throw mapLLMServiceError(error, language: language)
        }
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

    private func localized(
        _ key: L10n.Key,
        arguments: [CVarArg],
        language: AppLanguage = .current
    ) -> String {
        L10n.string(key, language: language, arguments: arguments)
    }

    private func mapLLMServiceError(
        _ error: LLMServiceError,
        language: AppLanguage
    ) -> DailyReportSummaryServiceError {
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
            let responseText = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedResponse = responseText?.isEmpty == false
                ? responseText!
                : localized(.analysisResponseUnavailable, language: language)
            return .invalidResponse(
                L10n.string(.analysisAppleIntelligenceDecodingFailure, language: language)
                    + "\n"
                    + details
                    + "\n"
                    + resolvedResponse
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
            return .reportDailySummaryInvalidResponse
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
            return .reportDailySummaryInvalidResponse
        }
    }
}
