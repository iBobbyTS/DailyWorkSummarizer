import Combine
import Foundation
import SwiftUI

@MainActor
final class ReportsViewModel: ObservableObject {
    @Published var selectedKind: ReportKind = .day {
        didSet {
            dailyReportGenerationError = nil
            selectedPage = 0
            shouldResetHeatmapSelection = true
            rebuildRanges()
        }
    }

    @Published var selectedPage: Int = 0 {
        didSet {
            updatePageItems()
        }
    }

    @Published var selectedRangeID: String? {
        didSet {
            dailyReportGenerationError = nil
            shouldResetHeatmapSelection = true
            updateChartItems()
        }
    }

    @Published var selectedVisualization: ReportVisualization = .barChart
    @Published var overlayDailyHeatmap = false
    @Published var includeWorkdays = true {
        didSet {
            shouldResetHeatmapSelection = true
            updateChartItems()
        }
    }
    @Published var includeWeekends = true {
        didSet {
            shouldResetHeatmapSelection = true
            updateChartItems()
        }
    }
    @Published private(set) var selectedDailyReport: DailyReportRecord?
    @Published private(set) var isGeneratingDailyReport = false
    @Published private(set) var dailyReportGenerationError: String?
    @Published private(set) var pageItems: [ReportRange] = []
    @Published private(set) var chartItems: [CategoryDuration] = []
    @Published private(set) var heatmapItems: [HeatmapEvent] = []
    @Published private(set) var heatmapCategories: [String] = []
    @Published private(set) var selectedHeatmapCategories: Set<String> = []
    @Published private(set) var totalPages: Int = 1
    @Published private(set) var allRanges: [ReportRange] = []

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let dailyReportSummaryService: DailyReportSummaryService
    private let logStore: AppLogStore?
    private var sourceItems: [ReportSourceItem] = []
    private var heatmapCategoryUniverse: [String] = []
    private var databaseObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var shouldResetHeatmapSelection = true

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        dailyReportSummaryService: DailyReportSummaryService,
        logStore: AppLogStore? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.dailyReportSummaryService = dailyReportSummaryService
        self.logStore = logStore
        reload()
        databaseObserver = NotificationCenter.default.publisher(for: .appDatabaseDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
        settingsObserver = NotificationCenter.default.publisher(for: .appSettingsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    func reload() {
        let persistedItems: [ReportSourceItem]
        do {
            persistedItems = try database.fetchReportSourceItems()
        } catch {
            persistedItems = []
            logStore?.addError(source: .reports, context: "Failed to load report source items", error: error)
        }
        sourceItems = Self.itemsIncludingDerivedAbsences(
            from: persistedItems,
            calendar: .reportCalendar
        )
        shouldResetHeatmapSelection = true
        rebuildRanges()
    }

    func toggleHeatmapCategory(_ category: String) {
        guard heatmapCategoryUniverse.contains(category) else {
            return
        }

        if selectedHeatmapCategories.contains(category) {
            selectedHeatmapCategories.remove(category)
        } else {
            selectedHeatmapCategories.insert(category)
        }
        updateChartItems()
    }

    func isHeatmapCategorySelected(_ category: String) -> Bool {
        selectedHeatmapCategories.contains(category)
    }

    func showPreviousPage() {
        guard selectedPage > 0 else { return }
        selectedPage -= 1
    }

    func showNextPage() {
        guard selectedPage + 1 < totalPages else { return }
        selectedPage += 1
    }

    var appLanguage: AppLanguage {
        settingsStore.appLanguage
    }

    var categoryColorMap: [String: Color] {
        var colors: [String: Color] = [:]
        for rule in settingsStore.categoryRules {
            colors[rule.name] = rule.displayColor
        }
        colors[AppDefaults.absenceCategoryName] = Color(hexRGB: AppDefaults.absenceCategoryColorHex)
        return colors
    }

    var selectedRange: ReportRange? {
        allRanges.first(where: { $0.id == selectedRangeID })
    }

    var shouldShowSummarizeNowButton: Bool {
        guard selectedKind == .day, selectedRange != nil else {
            return false
        }

        guard let selectedDailyReport else {
            return true
        }

        return selectedDailyReport.isTemporary
    }

    func categorySummary(for category: String) -> (text: String, isTemporary: Bool)? {
        guard category != AppDefaults.absenceCategoryName else {
            return nil
        }

        guard let selectedDailyReport,
              let text = selectedDailyReport.displayCategorySummary(for: category) else {
            return nil
        }

        return (
            text: text,
            isTemporary: selectedDailyReport.isTemporaryCategorySummary(for: category)
        )
    }

    func summarizeSelectedDay() {
        guard selectedKind == .day,
              let dayStart = selectedRange?.interval.start,
              !isGeneratingDailyReport else {
            return
        }

        dailyReportGenerationError = nil
        isGeneratingDailyReport = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isGeneratingDailyReport = false
            }

            do {
                let record = try await dailyReportSummaryService.summarizeDay(dayStart)
                selectedDailyReport = record
            } catch is CancellationError {
                return
            } catch {
                dailyReportGenerationError = error.localizedDescription
                logStore?.addError(source: .summary, context: "Failed to summarize selected day", error: error)
                updateSelectedDailyReport()
            }
        }
    }

    private func rebuildRanges() {
        allRanges = buildRanges(for: selectedKind, from: sourceItems)
        totalPages = max(1, Int(ceil(Double(allRanges.count) / Double(AppDefaults.maxPageSize))))
        selectedPage = min(selectedPage, max(0, totalPages - 1))
        updatePageItems()
    }

    private func updatePageItems() {
        let start = selectedPage * AppDefaults.maxPageSize
        let end = min(start + AppDefaults.maxPageSize, allRanges.count)
        if start < end {
            pageItems = Array(allRanges[start..<end])
        } else {
            pageItems = []
        }

        if let selectedRangeID, pageItems.contains(where: { $0.id == selectedRangeID }) {
            updateChartItems()
            return
        }

        selectedRangeID = pageItems.first?.id
    }

    private func updateChartItems() {
        guard let selectedRange else {
            chartItems = []
            heatmapItems = []
            heatmapCategories = []
            selectedHeatmapCategories = []
            selectedDailyReport = nil
            return
        }

        let visibleItems = displayedItems(for: selectedRange)
        let grouped = Dictionary(grouping: visibleItems) {
            $0.categoryName
        }

        chartItems = grouped.map { category, items in
            CategoryDuration(
                category: category,
                hours: Double(items.reduce(0) { $0 + $1.durationMinutes }) / 60.0
            )
        }
        .sorted(by: Self.categoryDurationSort)

        let availableHeatmapCategories = chartItems.map(\.category)
        if shouldResetHeatmapSelection || Set(availableHeatmapCategories) != Set(heatmapCategoryUniverse) {
            let availableSet = Set(availableHeatmapCategories)
            let preserved = selectedHeatmapCategories.intersection(availableSet)
            let missing = availableSet.subtracting(selectedHeatmapCategories)
            selectedHeatmapCategories = preserved.union(missing)
            if selectedHeatmapCategories.isEmpty, !availableSet.isEmpty {
                selectedHeatmapCategories = availableSet
            }
            shouldResetHeatmapSelection = false
        }

        heatmapCategoryUniverse = availableHeatmapCategories
        heatmapCategories = availableHeatmapCategories.filter { selectedHeatmapCategories.contains($0) }
        heatmapItems = buildHeatmapItems(for: selectedRange, visibleItems: visibleItems)
        updateSelectedDailyReport()
    }

    private func updateSelectedDailyReport() {
        guard selectedKind == .day,
              let dayStart = selectedRange?.interval.start else {
            selectedDailyReport = nil
            return
        }

        do {
            selectedDailyReport = try database.fetchDailyReport(for: dayStart)
        } catch {
            selectedDailyReport = nil
            logStore?.addError(source: .reports, context: "Failed to load selected daily report", error: error)
        }
    }

    private func buildHeatmapItems(for range: ReportRange, visibleItems: [ReportSourceItem]) -> [HeatmapEvent] {
        let selectedCategories = selectedHeatmapCategories
        guard !selectedCategories.isEmpty else {
            return []
        }

        let selectedSet = Set(selectedCategories)
        switch selectedKind {
        case .day:
            do {
                let calendar = Calendar.reportCalendar(language: appLanguage)
                let dailyItems = try database.fetchDailyReportActivityItems(for: range.interval.start, calendar: calendar)
                let summaryLookup = Dictionary(uniqueKeysWithValues: dailyItems.map { ($0.id, $0.itemSummaryText) })
                let heatmapItems = visibleItems.map { item in
                    DailyReportActivityItem(
                        id: item.id,
                        capturedAt: item.capturedAt,
                        categoryName: item.categoryName,
                        durationMinutes: item.durationMinutes,
                        itemSummaryText: summaryLookup[item.id] ?? nil
                    )
                }
                let workBlockSummaries = try database.fetchDailyWorkBlockSummaries(intersecting: range.interval)
                return DailyWorkBlockComposer.composeDailyHeatmapEvents(
                    rawItems: heatmapItems,
                    blockSummaries: workBlockSummaries,
                    range: range.interval,
                    selectedCategories: selectedSet
                )
            } catch {
                logStore?.addError(source: .reports, context: "Failed to load daily heatmap items", error: error)
                return []
            }
        case .week, .month, .year:
            return visibleItems
                .filter { selectedSet.contains($0.categoryName) }
                .compactMap { item in
                    let start = max(item.capturedAt, range.interval.start)
                    let end = min(item.endAt, range.interval.end)
                    guard end > start else {
                        return nil
                    }

                    return HeatmapEvent(
                        id: "\(item.id)-\(Int(start.timeIntervalSince1970))-\(item.durationMinutes)",
                        category: item.categoryName,
                        start: start,
                        end: end,
                        durationMinutes: max(Int((end.timeIntervalSince(start) / 60.0).rounded()), 1),
                        summaryStart: start,
                        summaryEnd: end
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.category < rhs.category
                    }
                    return lhs.start < rhs.start
                }
                .mergedContiguousEvents()
        }
    }

    private static func categorySortPriority(_ category: String) -> Int {
        if category == AppDefaults.absenceCategoryName {
            return 2
        }
        if category == AppDefaults.preservedOtherCategoryName {
            return 1
        }
        return 0
    }

    private static func categoryDurationSort(lhs: CategoryDuration, rhs: CategoryDuration) -> Bool {
        let lhsPriority = categorySortPriority(lhs.category)
        let rhsPriority = categorySortPriority(rhs.category)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.hours == rhs.hours {
            return lhs.category < rhs.category
        }
        return lhs.hours > rhs.hours
    }

    nonisolated static func itemsIncludingDerivedAbsences(
        from persistedItems: [ReportSourceItem],
        calendar: Calendar
    ) -> [ReportSourceItem] {
        let anchors = persistedItems.sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.id < rhs.id
            }
            return lhs.capturedAt < rhs.capturedAt
        }
        guard anchors.count > 1 else {
            return persistedItems
        }

        var nextDerivedID: Int64 = -1
        var derivedItems: [ReportSourceItem] = []

        for index in anchors.indices.dropLast() {
            let previous = anchors[index]
            let next = anchors[anchors.index(after: index)]
            var segmentStart = previous.endAt
            let gapEnd = next.capturedAt
            guard gapEnd > segmentStart else {
                continue
            }

            while segmentStart < gapEnd {
                let dayStart = calendar.startOfDay(for: segmentStart)
                guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
                      dayEnd > segmentStart else {
                    break
                }

                let segmentEnd = Swift.min(dayEnd, gapEnd)
                if let item = absenceItem(id: nextDerivedID, start: segmentStart, end: segmentEnd) {
                    derivedItems.append(item)
                    nextDerivedID -= 1
                }
                segmentStart = segmentEnd
            }
        }

        return (persistedItems + derivedItems).sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.id > rhs.id
            }
            return lhs.capturedAt > rhs.capturedAt
        }
    }

    private nonisolated static func absenceItem(id: Int64, start: Date, end: Date) -> ReportSourceItem? {
        guard end > start else {
            return nil
        }

        return ReportSourceItem(
            id: id,
            capturedAt: start,
            categoryName: AppDefaults.absenceCategoryName,
            durationMinutes: max(Int((end.timeIntervalSince(start) / 60.0).rounded()), 1)
        )
    }

    private func displayedItems(for range: ReportRange) -> [ReportSourceItem] {
        sourceItems
            .compactMap { clippedItem($0, to: range.interval) }
            .flatMap { splitItemByDayAndFilter($0, for: selectedKind) }
            .sorted { lhs, rhs in
                if lhs.capturedAt == rhs.capturedAt {
                    return lhs.id < rhs.id
                }
                return lhs.capturedAt < rhs.capturedAt
            }
    }

    private func clippedItem(_ item: ReportSourceItem, to interval: DateInterval) -> ReportSourceItem? {
        let start = max(item.capturedAt, interval.start)
        let end = min(item.endAt, interval.end)
        return normalizedItem(item, start: start, end: end)
    }

    private func splitItemByDayAndFilter(_ item: ReportSourceItem, for kind: ReportKind) -> [ReportSourceItem] {
        guard kind != .day else {
            return [item]
        }

        guard includeWorkdays || includeWeekends else {
            return []
        }

        var segments: [ReportSourceItem] = []
        var segmentStart = item.capturedAt
        let itemEnd = item.endAt
        let calendar = Calendar.reportCalendar

        while segmentStart < itemEnd {
            let dayStart = calendar.startOfDay(for: segmentStart)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? itemEnd
            let segmentEnd = min(itemEnd, dayEnd)
            let isWeekend = calendar.isDateInWeekend(segmentStart)
            let shouldInclude = isWeekend ? includeWeekends : includeWorkdays

            if shouldInclude, let normalized = normalizedItem(item, start: segmentStart, end: segmentEnd) {
                segments.append(normalized)
            }

            segmentStart = segmentEnd
        }

        return segments
    }

    private func normalizedItem(_ item: ReportSourceItem, start: Date, end: Date) -> ReportSourceItem? {
        guard end > start else {
            return nil
        }

        let durationMinutes = max(Int((end.timeIntervalSince(start) / 60.0).rounded()), 1)
        return ReportSourceItem(
            id: item.id,
            capturedAt: start,
            categoryName: item.categoryName,
            durationMinutes: durationMinutes
        )
    }
    private func buildRanges(for kind: ReportKind, from items: [ReportSourceItem]) -> [ReportRange] {
        let language = settingsStore.appLanguage
        let calendar = Calendar.reportCalendar(
            language: language,
            firstWeekday: settingsStore.reportWeekStart.calendarFirstWeekday
        )
        let grouped: [Date: [ReportSourceItem]]

        switch kind {
        case .day:
            grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.capturedAt) }
        case .week:
            grouped = Dictionary(grouping: items) { $0.capturedAt.startOfWeek(calendar: calendar) }
        case .month:
            grouped = Dictionary(grouping: items) { $0.capturedAt.monthStart(calendar: calendar) }
        case .year:
            grouped = Dictionary(grouping: items) { $0.capturedAt.yearStart(calendar: calendar) }
        }

        return grouped.map { startDate, records in
            let interval: DateInterval
            let label: String

            switch kind {
            case .day:
                let end = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                label = L10n.reportDayFormatter(language: language).string(from: startDate)
            case .week:
                let end = calendar.date(byAdding: .day, value: 7, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                let displayEnd = calendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
                label = "\(L10n.reportDayFormatter(language: language).string(from: startDate)) - \(L10n.reportDayFormatter(language: language).string(from: displayEnd))"
            case .month:
                let end = calendar.date(byAdding: .month, value: 1, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                label = L10n.reportMonthFormatter(language: language).string(from: startDate)
            case .year:
                let end = calendar.date(byAdding: .year, value: 1, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                label = L10n.reportYearFormatter(language: language).string(from: startDate)
            }

            let durationRecords = records.filter { $0.categoryName != AppDefaults.absenceCategoryName }
            let totalHours = Double(durationRecords.reduce(0) { $0 + $1.durationMinutes }) / 60.0
            let averageDayCount = resolvedAverageDayCount(
                for: records,
                in: interval,
                kind: kind,
                calendar: calendar
            )

            return ReportRange(
                id: "\(kind.rawValue)-\(Int(startDate.timeIntervalSince1970))",
                label: label,
                interval: interval,
                totalHours: totalHours,
                averageHoursPerDay: totalHours / Double(averageDayCount),
                itemCount: records.count
            )
        }
        .sorted { $0.interval.start > $1.interval.start }
    }

    private func resolvedAverageDayCount(
        for records: [ReportSourceItem],
        in interval: DateInterval,
        kind: ReportKind,
        calendar: Calendar
    ) -> Int {
        var recordedDays = Set(records.map { calendar.startOfDay(for: $0.capturedAt) })
        guard kind != .day else {
            return max(recordedDays.count, 1)
        }

        guard let rangeLastDay = calendar.date(byAdding: .day, value: -1, to: interval.end).map({ calendar.startOfDay(for: $0) }),
              recordedDays.contains(rangeLastDay) else {
            return max(recordedDays.count, 1)
        }

        if !hasLateCoverage(on: rangeLastDay, in: records, calendar: calendar), recordedDays.count > 1 {
            recordedDays.remove(rangeLastDay)
        }

        return max(recordedDays.count, 1)
    }

    private func hasLateCoverage(
        on dayStart: Date,
        in records: [ReportSourceItem],
        calendar: Calendar
    ) -> Bool {
        guard let lateThreshold = calendar.date(byAdding: .hour, value: 23, to: dayStart),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return false
        }

        return records.contains { record in
            let clippedStart = max(record.capturedAt, dayStart)
            let clippedEnd = min(record.endAt, dayEnd)
            return clippedEnd > clippedStart && clippedEnd > lateThreshold
        }
    }
}
