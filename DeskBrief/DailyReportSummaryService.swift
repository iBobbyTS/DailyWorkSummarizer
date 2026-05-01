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

private struct ParsedDailyWorkBlockPayload: Decodable {
    let summary: String

    private enum CodingKeys: String, CodingKey {
        case summary
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
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

@MainActor
final class DailyReportSummaryService {
    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private weak var logStore: AppLogStore?
    private let llmService: LLMService
    private let lmStudioLifecycle: LMStudioModelLifecycle
    private let lock = AsyncLock()
    private var runtimeState: DailyReportSummaryRuntimeState = .idle {
        didSet {
            NotificationCenter.default.post(name: .dailyReportSummaryStatusDidChange, object: nil)
        }
    }

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore? = nil,
        session: URLSession? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
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
        } catch is CancellationError {
            return
        } catch {
            recordSummaryError(error, context: "Failed to summarize missing daily reports")
            return
        }
    }

    func backfillMissingSummaries(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy = .automaticUnload
    ) async {
        do {
            try await lock.withLock {
                try await summarizeBackfillLocked(lmStudioLifecyclePolicy: lmStudioLifecyclePolicy)
            }
        } catch is CancellationError {
            return
        } catch {
            recordSummaryError(error, context: "Failed to backfill missing summaries")
            return
        }
    }

    func summarizeAffectedSummaries(
        for dayStarts: Set<Date>,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy = .automaticUnload
    ) async {
        do {
            try await lock.withLock {
                try await summarizeAffectedSummariesLocked(
                    dayStarts: dayStarts,
                    lmStudioLifecyclePolicy: lmStudioLifecyclePolicy
                )
            }
        } catch is CancellationError {
            return
        } catch {
            recordSummaryError(error, context: "Failed to summarize affected summaries")
            return
        }
    }

    func summarizeDay(_ dayStart: Date) async throws -> DailyReportRecord {
        try await lock.withLock {
            try await summarizeDayLocked(dayStart, lmStudioLifecyclePolicy: .automaticUnload)
        }
    }

    var currentState: DailyReportSummaryRuntimeState {
        runtimeState
    }

    func cancelCurrentSummary() {
        guard runtimeState.isRunning, !runtimeState.isStopping else {
            return
        }

        runtimeState = DailyReportSummaryRuntimeState(
            isRunning: true,
            isStopping: true,
            modelName: runtimeState.modelName,
            completedCount: runtimeState.completedCount,
            totalCount: runtimeState.totalCount
        )
        llmService.cancelActiveRemoteRequest()
    }

    func forceUnloadManagedModel() async throws -> Bool {
        let snapshot = settingsStore.snapshot.workContentSummaryModelProfile
        guard snapshot.provider == .lmStudio else {
            return false
        }

        if runtimeState.isRunning {
            cancelCurrentSummary()
            await waitForSummaryToStop()
        }

        do {
            try await lmStudioLifecycle.unload(settings: snapshot, instanceID: nil)
            return true
        } catch LMStudioModelLifecycleError.missingLoadedInstanceID {
            logStore?.add(
                level: .log,
                source: .lmStudio,
                message: localized(.menuForceUnloadNoLoadedModel, language: settingsStore.appLanguage)
            )
            return false
        } catch {
            logStore?.addError(source: .lmStudio, context: "Forced unload of work content summary model failed", error: error)
            throw error
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
        updateRuntimeState(
            modelName: snapshot.workContentSummaryModelProfile.modelName,
            completedCount: 0,
            totalCount: pendingDays.count
        )
        defer { runtimeState = .idle }

        try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            var completedCount = 0
            for dayStart in pendingDays {
                do {
                    _ = try await summarizeDayContentLocked(
                        dayStart,
                        snapshot: snapshot,
                        activityDaySet: activityDaySet
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    recordSummaryError(error, context: "Failed to summarize daily report for \(dayStart)")
                }
                completedCount += 1
                updateRuntimeState(
                    modelName: snapshot.workContentSummaryModelProfile.modelName,
                    completedCount: completedCount,
                    totalCount: pendingDays.count
                )
            }
        }
    }

    private func summarizeBackfillLocked(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    ) async throws {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let candidateBlocks = try candidateWorkBlocks(targetDayStarts: nil)
        let reportableDayStarts = try fetchReportableActivityDayStarts(calendar: calendar)
        let latestDayStart = reportableDayStarts.last
        let pendingDays = try pendingReportableDayStarts(
            in: reportableDayStarts,
            before: latestDayStart ?? .distantPast
        )

        guard !candidateBlocks.isEmpty || !pendingDays.isEmpty else {
            return
        }

        updateRuntimeState(
            modelName: snapshot.workContentSummaryModelProfile.modelName,
            completedCount: 0,
            totalCount: candidateBlocks.count + pendingDays.count
        )
        defer { runtimeState = .idle }

        try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            var completedCount = 0
            completedCount += try await summarizeWorkBlocksWorkLocked(
                blocks: candidateBlocks,
                snapshot: snapshot,
                targetDayStarts: nil,
                completedCountOffset: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
            completedCount += try await summarizeDailyReportsWorkLocked(
                pendingDays: pendingDays,
                activityDaySet: Set(reportableDayStarts),
                snapshot: snapshot,
                completedCountOffset: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
            updateRuntimeState(
                modelName: snapshot.workContentSummaryModelProfile.modelName,
                completedCount: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
        }
    }

    private func summarizeAffectedSummariesLocked(
        dayStarts: Set<Date>,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    ) async throws {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let candidateBlocks = try candidateWorkBlocks(targetDayStarts: dayStarts)
        let reportableDayStarts = try fetchReportableActivityDayStarts(calendar: calendar)
        let latestDayStart = reportableDayStarts.last
        let pendingDays = try pendingReportableDayStarts(
            in: reportableDayStarts,
            before: latestDayStart ?? .distantPast
        )

        guard !candidateBlocks.isEmpty || !pendingDays.isEmpty else {
            return
        }

        updateRuntimeState(
            modelName: snapshot.workContentSummaryModelProfile.modelName,
            completedCount: 0,
            totalCount: candidateBlocks.count + pendingDays.count
        )
        defer { runtimeState = .idle }

        try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            var completedCount = 0
            completedCount += try await summarizeWorkBlocksWorkLocked(
                blocks: candidateBlocks,
                snapshot: snapshot,
                targetDayStarts: dayStarts,
                completedCountOffset: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
            completedCount += try await summarizeDailyReportsWorkLocked(
                pendingDays: pendingDays,
                activityDaySet: Set(reportableDayStarts),
                snapshot: snapshot,
                completedCountOffset: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
            updateRuntimeState(
                modelName: snapshot.workContentSummaryModelProfile.modelName,
                completedCount: completedCount,
                totalCount: candidateBlocks.count + pendingDays.count
            )
        }
    }

    private func summarizeDailyReportsWorkLocked(
        pendingDays: [Date],
        activityDaySet: Set<Date>,
        snapshot: AppSettingsSnapshot,
        completedCountOffset: Int,
        totalCount: Int
    ) async throws -> Int {
        guard !pendingDays.isEmpty else {
            return 0
        }

        var completedCount = 0
        for dayStart in pendingDays {
            do {
                _ = try await summarizeDayContentLocked(
                    dayStart,
                    snapshot: snapshot,
                    activityDaySet: activityDaySet
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordSummaryError(error, context: "Failed to summarize daily report for \(dayStart)")
            }
            completedCount += 1
            updateRuntimeState(
                modelName: snapshot.workContentSummaryModelProfile.modelName,
                completedCount: completedCountOffset + completedCount,
                totalCount: totalCount
            )
        }

        return completedCount
    }

    private func summarizeWorkBlocksWorkLocked(
        blocks: [DailyWorkBlock],
        snapshot: AppSettingsSnapshot,
        targetDayStarts: Set<Date>?,
        completedCountOffset: Int,
        totalCount: Int
    ) async throws -> Int {
        guard !blocks.isEmpty else {
            return 0
        }

        let language = snapshot.appLanguage
        let settings = snapshot.workContentSummaryModelProfile
        let calendar = Calendar.reportCalendar(language: language)
        let targetIntervals = targetDayStarts.map { dayStarts -> [DateInterval] in
            dayStarts.compactMap { dayStart in
                let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                return DateInterval(start: dayStart, end: end)
            }
        }

        let relevantBlocks = blocks.filter { block in
            guard block.categoryName != AppDefaults.absenceCategoryName,
                  block.isClosed else {
                return false
            }

            guard let targetIntervals else {
                return true
            }

            return targetIntervals.contains { $0.intersects(block.interval) }
        }

        let existingSummaries = try database.fetchDailyWorkBlockSummaries()
        let relevantExistingSummaries = existingSummaries.filter { summary in
            guard let targetIntervals else {
                return true
            }
            let interval = summary.interval
            return targetIntervals.contains { $0.intersects(interval) }
        }
        let existingSummaryMap = Dictionary(uniqueKeysWithValues: relevantExistingSummaries.map { summary in
            (workBlockKey(startAt: summary.startAt, endAt: summary.endAt), summary)
        })

        guard !relevantBlocks.isEmpty || !relevantExistingSummaries.isEmpty else {
            return 0
        }

        var completedCount = 0
        var retainedKeys = Set<String>()

        for block in relevantBlocks {
            if Task.isCancelled {
                throw CancellationError()
            }

            do {
                let key = workBlockKey(startAt: block.startAt, endAt: block.endAt)
                let sourceSummaries = block.nonEmptySourceSummaries
                let existingSummary = existingSummaryMap[key]

                if block.sourceItems.count == 1 {
                    if let directSummary = sourceSummaries.first, !directSummary.isEmpty {
                        if existingSummary == nil {
                            try database.upsertDailyWorkBlockSummary(
                                categoryName: block.categoryName,
                                startAt: block.startAt,
                                endAt: block.endAt,
                                summaryText: directSummary
                            )
                        }
                        retainedKeys.insert(key)
                    } else if let existingSummary {
                        try database.deleteDailyWorkBlockSummaries(ids: [existingSummary.id])
                    } else {
                        recordSummarySkip(
                            "Skipped work block summary for \(block.categoryName) because there is no source summary."
                        )
                    }
                } else if sourceSummaries.count >= 2 {
                    if existingSummary == nil {
                        let summaryText = try await summarizeWorkBlockContentLocked(
                            block: block,
                            sourceSummaries: sourceSummaries,
                            snapshot: snapshot
                        )
                        try database.upsertDailyWorkBlockSummary(
                            categoryName: block.categoryName,
                            startAt: block.startAt,
                            endAt: block.endAt,
                            summaryText: summaryText
                        )
                    }
                    retainedKeys.insert(key)
                } else if let existingSummary {
                    try database.deleteDailyWorkBlockSummaries(ids: [existingSummary.id])
                } else {
                    recordSummarySkip(
                        "Skipped work block summary for \(block.categoryName) because it has fewer than 2 non-empty source summaries."
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordSummaryError(
                    error,
                    context: "Failed to persist work block summary for \(block.categoryName) (\(block.startAt) - \(block.endAt))"
                )
            }

            completedCount += 1
            updateRuntimeState(
                modelName: settings.modelName,
                completedCount: completedCountOffset + completedCount,
                totalCount: totalCount
            )
        }

        let staleSummaryIDs = relevantExistingSummaries
            .filter { !retainedKeys.contains(workBlockKey(startAt: $0.startAt, endAt: $0.endAt)) }
            .map(\.id)

        if !staleSummaryIDs.isEmpty {
            try database.deleteDailyWorkBlockSummaries(ids: staleSummaryIDs)
        }

        return completedCount
    }

    private func summarizeWorkBlockContentLocked(
        block: DailyWorkBlock,
        sourceSummaries: [String],
        snapshot: AppSettingsSnapshot
    ) async throws -> String {
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

        let prompt = L10n.dailyWorkBlockSummaryPrompt(
            category: block.categoryName,
            sourceSummaries: sourceSummaries,
            summaryInstruction: snapshot.summaryInstruction,
            language: language
        )
        let payload = try await requestSummary(prompt: prompt, settings: settings, language: language)

        guard let summary = Self.extractDailyWorkBlockResponse(from: payload) else {
            throw DailyReportSummaryServiceError.invalidResponse(
                localized(.reportDailySummaryInvalidResponse, language: language)
            )
        }

        return summary
    }

    private func candidateWorkBlocks(targetDayStarts: Set<Date>?) throws -> [DailyWorkBlock] {
        let activityItems = try database.fetchReportActivityItems()
        let blocks = DailyWorkBlockComposer.groupBlocks(from: activityItems)

        guard let targetDayStarts else {
            return blocks
        }

        let calendar = Calendar.reportCalendar
        let targetIntervals = targetDayStarts.compactMap { dayStart -> DateInterval? in
            guard let end = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return nil
            }
            return DateInterval(start: dayStart, end: end)
        }

        guard !targetIntervals.isEmpty else {
            return []
        }

        return blocks.filter { block in
            targetIntervals.contains { $0.intersects(block.interval) }
        }
    }

    private func workBlockKey(startAt: Date, endAt: Date) -> String {
        "\(startAt.timeIntervalSince1970)-\(endAt.timeIntervalSince1970)"
    }

    nonisolated static func extractDailyWorkBlockResponse(from rawText: String) -> String? {
        let candidates = responseCandidates(from: rawText)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ParsedDailyWorkBlockPayload.self, from: data) else {
                continue
            }

            let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else {
                continue
            }

            return summary
        }
        return nil
    }

    private func recordSummarySkip(_ message: String) {
        Task { @MainActor [weak logStore] in
            logStore?.add(level: .log, source: .summary, message: message)
        }
    }

    private func summarizeDayLocked(
        _ dayStart: Date,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    ) async throws -> DailyReportRecord {
        let snapshot = await MainActor.run { settingsStore.snapshot }
        let calendar = Calendar.reportCalendar(language: snapshot.appLanguage)
        let activityDaySet = Set(try fetchReportableActivityDayStarts(calendar: calendar))
        updateRuntimeState(
            modelName: snapshot.workContentSummaryModelProfile.modelName,
            completedCount: 0,
            totalCount: 1
        )
        defer { runtimeState = .idle }

        return try await withLMStudioLifecycleIfNeeded(
            settings: snapshot.workContentSummaryModelProfile,
            policy: lmStudioLifecyclePolicy
        ) {
            defer {
                updateRuntimeState(
                    modelName: snapshot.workContentSummaryModelProfile.modelName,
                    completedCount: 1,
                    totalCount: 1
                )
            }
            return try await summarizeDayContentLocked(
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
            categorySummaries: record.categorySummaries,
            isTemporary: record.isTemporary
        )

        return record
    }

    private func withLMStudioLifecycleIfNeeded<T>(
        settings: ModelProfileSettings,
        policy: DailyReportLMStudioLifecyclePolicy,
        operation: () async throws -> T
    ) async throws -> T {
        guard settings.provider == .lmStudio,
              settings.automaticallyLoadAndUnloadModel else {
            return try await operation()
        }

        switch policy {
        case .alreadyLoadedKeepLoaded:
            return try await operation()
        case .automaticUnload:
            let loadedModel = try await lmStudioLifecycle.load(settings: settings)
            do {
                let result = try await operation()
                do {
                    try await lmStudioLifecycle.unload(settings: settings, instanceID: loadedModel.instanceID)
                } catch {
                    recordSummaryError(error, context: "Failed to unload LM Studio summary model")
                }
                return result
            } catch {
                do {
                    try await lmStudioLifecycle.unload(settings: settings, instanceID: loadedModel.instanceID)
                } catch {
                    recordSummaryError(error, context: "Failed to unload LM Studio summary model after summary failure")
                }
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
        return DailyReportRecord(
            dayStart: dayStart,
            dailySummaryText: cleanedReportText(payload.dailySummary),
            categorySummaries: payload.categorySummaries.mapValues(cleanedReportText(_:)),
            isTemporary: isTemporary
        )
    }

    private func cleanedReportText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func updateRuntimeState(
        modelName: String?,
        completedCount: Int,
        totalCount: Int,
        isStopping: Bool = false
    ) {
        runtimeState = DailyReportSummaryRuntimeState(
            isRunning: true,
            isStopping: isStopping,
            modelName: modelName ?? runtimeState.modelName,
            completedCount: completedCount,
            totalCount: totalCount
        )
    }

    private func waitForSummaryToStop(timeoutSeconds: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while runtimeState.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
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

    private func recordSummaryError(_ error: Error, context: String) {
        let level: AppLogLevel
        switch error {
        case DailyReportSummaryServiceError.noActivity:
            level = .log
        case is CancellationError:
            level = .log
        default:
            level = .error
        }

        Task { @MainActor [weak logStore] in
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            logStore?.add(
                level: level,
                source: .summary,
                message: detail.isEmpty ? context : "\(context): \(detail)"
            )
        }
    }
}
