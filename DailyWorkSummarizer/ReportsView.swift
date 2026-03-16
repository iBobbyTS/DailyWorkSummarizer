import Charts
import Combine
import SwiftUI

@MainActor
final class ReportsViewModel: ObservableObject {
    @Published var selectedKind: ReportKind = .day {
        didSet {
            selectedPage = 0
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
            updateChartItems()
        }
    }

    @Published var selectedVisualization: ReportVisualization = .barChart
    @Published var overlayDailyHeatmap = false
    @Published var includeWorkdays = true {
        didSet {
            updateChartItems()
        }
    }
    @Published var includeWeekends = true {
        didSet {
            updateChartItems()
        }
    }
    @Published private(set) var pageItems: [ReportRange] = []
    @Published private(set) var chartItems: [CategoryDuration] = []
    @Published private(set) var heatmapItems: [HeatmapEvent] = []
    @Published private(set) var heatmapCategories: [String] = []
    @Published private(set) var totalPages: Int = 1
    @Published private(set) var allRanges: [ReportRange] = []

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private var sourceItems: [ReportSourceItem] = []
    private var databaseObserver: AnyCancellable?

    init(database: AppDatabase, settingsStore: SettingsStore) {
        self.database = database
        self.settingsStore = settingsStore
        reload()
        databaseObserver = NotificationCenter.default.publisher(for: .appDatabaseDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    func reload() {
        sourceItems = (try? database.fetchReportSourceItems()) ?? []
        rebuildRanges()
    }

    func showPreviousPage() {
        guard selectedPage > 0 else { return }
        selectedPage -= 1
    }

    func showNextPage() {
        guard selectedPage + 1 < totalPages else { return }
        selectedPage += 1
    }

    var selectedRange: ReportRange? {
        allRanges.first(where: { $0.id == selectedRangeID })
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
        .sorted { lhs, rhs in
            if lhs.category == AppDefaults.absenceCategoryName, rhs.category != AppDefaults.absenceCategoryName {
                return false
            }
            if rhs.category == AppDefaults.absenceCategoryName, lhs.category != AppDefaults.absenceCategoryName {
                return true
            }
            if lhs.hours == rhs.hours {
                return lhs.category < rhs.category
            }
            return lhs.hours > rhs.hours
        }

        heatmapCategories = chartItems.map(\.category)
        heatmapItems = visibleItems
            .compactMap { item in
                let start = max(item.capturedAt, selectedRange.interval.start)
                let end = min(
                    item.capturedAt.addingTimeInterval(TimeInterval(item.durationMinutes * 60)),
                    selectedRange.interval.end
                )

                guard end > start else {
                    return nil
                }

                return HeatmapEvent(
                    id: "\(item.id)-\(Int(start.timeIntervalSince1970))-\(item.durationMinutes)",
                    category: item.categoryName,
                    start: start,
                    end: end,
                    durationMinutes: item.durationMinutes
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
        let calendar = Calendar.reportCalendar(firstWeekday: settingsStore.reportWeekStart.calendarFirstWeekday)
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
                label = DateFormatter.reportDay.string(from: startDate)
            case .week:
                let end = calendar.date(byAdding: .day, value: 7, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                let displayEnd = calendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
                label = "\(DateFormatter.reportDay.string(from: startDate)) - \(DateFormatter.reportDay.string(from: displayEnd))"
            case .month:
                let end = calendar.date(byAdding: .month, value: 1, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                label = DateFormatter.reportMonth.string(from: startDate)
            case .year:
                let end = calendar.date(byAdding: .year, value: 1, to: startDate) ?? startDate
                interval = DateInterval(start: startDate, end: end)
                label = DateFormatter.reportYear.string(from: startDate)
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

private extension Array where Element == HeatmapEvent {
    func mergedContiguousEvents(tolerance: TimeInterval = 1) -> [HeatmapEvent] {
        guard var current = first else {
            return []
        }

        var merged: [HeatmapEvent] = []

        for event in dropFirst() {
            if event.category == current.category,
               event.start.timeIntervalSince(current.end) <= tolerance {
                current = HeatmapEvent(
                    id: current.id,
                    category: current.category,
                    start: current.start,
                    end: Swift.max(current.end, event.end),
                    durationMinutes: Swift.max(
                        Int((Swift.max(current.end, event.end).timeIntervalSince(current.start) / 60.0).rounded()),
                        1
                    )
                )
            } else {
                merged.append(current)
                current = event
            }
        }

        merged.append(current)
        return merged
    }
}

struct ReportsView: View {
    @ObservedObject var viewModel: ReportsViewModel

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 340)

            Divider()

            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("报告类型", selection: $viewModel.selectedKind) {
                ForEach(ReportKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button("上一页") {
                    viewModel.showPreviousPage()
                }
                .disabled(viewModel.selectedPage == 0)

                Spacer()

                Text("\(viewModel.selectedPage + 1) / \(viewModel.totalPages)")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("下一页") {
                    viewModel.showNextPage()
                }
                .disabled(viewModel.selectedPage + 1 >= viewModel.totalPages)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.pageItems) { range in
                        Button {
                            viewModel.selectedRangeID = range.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(range.label)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text("累计 \(range.totalHours.durationText(for: viewModel.selectedKind))")
                                        .foregroundStyle(.secondary)
                                    if viewModel.selectedKind != .day {
                                        Text("日均 \(range.averageHoursPerDay.durationText(for: viewModel.selectedKind))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(viewModel.selectedRangeID == range.id ? Color.accentColor.opacity(0.14) : Color.gray.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(20)
    }

    private var rightPanel: some View {
        let categoryColors = Dictionary(uniqueKeysWithValues: viewModel.chartItems.enumerated().map { index, item in
            (item.category, Self.palette[index % Self.palette.count])
        })
        let barChartItems = viewModel.chartItems.filter { $0.category != AppDefaults.absenceCategoryName }
        let visibleLegendItems = viewModel.selectedVisualization == .barChart ? barChartItems : viewModel.chartItems

        return VStack(alignment: .leading, spacing: 16) {
            if let selectedRange = viewModel.selectedRange {
                Text(selectedRange.label)
                    .font(.title2.weight(.semibold))
            } else {
                Text("查看报告")
                    .font(.title2.weight(.semibold))
            }

            HStack(alignment: .center, spacing: 16) {
                Picker("图表类型", selection: $viewModel.selectedVisualization) {
                    ForEach(ReportVisualization.allCases) { visualization in
                        Text(visualization.title).tag(visualization)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                if viewModel.selectedKind != .day {
                    Spacer(minLength: 0)

                    Toggle("工作日", isOn: $viewModel.includeWorkdays)
                        .toggleStyle(.checkbox)

                    Toggle("周末", isOn: $viewModel.includeWeekends)
                        .toggleStyle(.checkbox)
                }
            }

            if viewModel.selectedVisualization == .heatmap,
               viewModel.selectedKind == .month || viewModel.selectedKind == .year {
                Toggle("叠加每日时间", isOn: $viewModel.overlayDailyHeatmap)
                    .toggleStyle(.switch)
            }

            if visibleLegendItems.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "暂无报告数据",
                    systemImage: viewModel.selectedVisualization == .barChart ? "chart.bar.xaxis" : "square.grid.3x2",
                    description: Text("当前时间范围没有符合筛选条件的记录。")
                )
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                WrappingFlowLayout(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(visibleLegendItems.enumerated()), id: \.element.category) { index, item in
                        legendItem(
                            color: Self.palette[index % Self.palette.count],
                            item: item
                        )
                    }
                }

                Group {
                    if viewModel.selectedVisualization == .barChart {
                        Chart(Array(barChartItems.enumerated()), id: \.element.category) { index, item in
                            BarMark(
                                x: .value("分类", item.category),
                                y: .value("累计小时", item.hours)
                            )
                            .foregroundStyle(Self.palette[index % Self.palette.count])
                            .annotation(position: .top) {
                                Text(item.hours.durationText(for: viewModel.selectedKind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .chartXAxisLabel("分类")
                        .chartYAxisLabel("累计小时")
                        .chartLegend(.hidden)
                    } else if let selectedRange = viewModel.selectedRange {
                        HeatmapTimelineView(
                            kind: viewModel.selectedKind,
                            range: selectedRange,
                            categories: viewModel.heatmapCategories,
                            items: viewModel.heatmapItems,
                            categoryColors: categoryColors,
                            overlayDailyHeatmap: viewModel.overlayDailyHeatmap,
                            includeWorkdays: viewModel.includeWorkdays,
                            includeWeekends: viewModel.includeWeekends
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private func legendItem(color: Color, item: CategoryDuration) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(item.category)
                .font(.subheadline)
            Text(item.hours.durationText(for: viewModel.selectedKind))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private static let palette: [Color] = [
        Color(red: 0.18, green: 0.45, blue: 0.78),
        Color(red: 0.86, green: 0.44, blue: 0.24),
        Color(red: 0.26, green: 0.62, blue: 0.38),
        Color(red: 0.67, green: 0.38, blue: 0.72),
        Color(red: 0.82, green: 0.68, blue: 0.18),
        Color(red: 0.18, green: 0.63, blue: 0.68),
    ]
}

private struct WrappingFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = arrangedRows(for: subviews, maxWidth: maxWidth)
        let width = rows.map { row in
            row.reduce(CGFloat.zero) { partialResult, item in
                partialResult + item.size.width
            } + CGFloat(max(0, row.count - 1)) * horizontalSpacing
        }.max() ?? 0
        let height = rows.enumerated().reduce(CGFloat.zero) { partialResult, element in
            let rowHeight = element.1.map(\.size.height).max() ?? 0
            return partialResult + rowHeight + (element.offset == rows.count - 1 ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangedRows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map(\.size.height).max() ?? 0
            for item in row {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func arrangedRows(for subviews: Subviews, maxWidth: CGFloat) -> [[RowItem]] {
        var rows: [[RowItem]] = [[]]
        var currentWidth: CGFloat = 0
        let availableWidth = max(maxWidth, 1)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = rows[rows.count - 1].isEmpty ? size.width : currentWidth + horizontalSpacing + size.width

            if proposedWidth > availableWidth, !rows[rows.count - 1].isEmpty {
                rows.append([RowItem(subview: subview, size: size)])
                currentWidth = size.width
            } else {
                rows[rows.count - 1].append(RowItem(subview: subview, size: size))
                currentWidth = rows[rows.count - 1].isEmpty ? size.width : proposedWidth
            }
        }

        return rows.filter { !$0.isEmpty }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
}

private struct HeatmapTimelineView: View {
    let kind: ReportKind
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]
    let overlayDailyHeatmap: Bool
    let includeWorkdays: Bool
    let includeWeekends: Bool

    var body: some View {
        switch kind {
        case .day:
            DailyHeatmapView(
                range: range,
                categories: categories,
                items: items,
                categoryColors: categoryColors
            )
        case .week:
            WeeklyHeatmapView(
                categories: categories,
                items: items,
                categoryColors: categoryColors,
                includeWorkdays: includeWorkdays,
                includeWeekends: includeWeekends
            )
        case .month, .year:
            if overlayDailyHeatmap {
                OverlayDailyHeatmapView(
                    categories: categories,
                    items: items,
                    categoryColors: categoryColors
                )
            } else {
                ContinuousHeatmapView(
                    range: range,
                    categories: categories,
                    items: items,
                    categoryColors: categoryColors
                )
            }
        }
    }
}

private struct ContinuousHeatmapView: View {
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 72
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let canvasWidth = max(geometry.size.width - labelWidth - horizontalPadding * 2, 320)
            let rowStride = rowHeight + rowSpacing
            let canvasHeight = max(CGFloat(categories.count) * rowStride - rowSpacing, rowHeight)
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let tickDates = timelineTicks(canvasWidth: canvasWidth)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 0) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: 20)

                        ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                            let xPosition = position(for: tick, in: canvasWidth)
                            VStack(spacing: 4) {
                                Text(tickLabel(for: tick, isLast: index == tickDates.count - 1))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: axisLabelWidth, alignment: .center)
                                    .multilineTextAlignment(.center)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 8)
                            }
                            .frame(width: axisLabelWidth)
                            .offset(x: xPosition - axisLabelWidth / 2)
                        }
                    }
                    .frame(width: canvasWidth, height: 30)
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(categories, id: \.self) { category in
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                                .frame(width: canvasWidth, height: rowHeight)
                                .offset(y: CGFloat(index) * rowStride)
                        }

                        ForEach(items) { item in
                            if let rowIndex = rowIndexMap[item.category] {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill((categoryColors[item.category] ?? .accentColor).opacity(0.78))
                                    .frame(
                                        width: max(eventWidth(for: item, in: canvasWidth), 1),
                                        height: rowHeight - 4
                                    )
                                    .offset(
                                        x: position(for: item.start, in: canvasWidth),
                                        y: CGFloat(rowIndex) * rowStride + 2
                                    )
                            }
                        }
                    }
                    .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.06))
        )
    }

    fileprivate func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let tickCount = max(3, min(Int(canvasWidth / axisLabelWidth), 8))
        let totalDuration = range.interval.duration
        guard totalDuration > 0 else {
            return [range.interval.start]
        }

        return (0..<tickCount).map { index in
            if index == tickCount - 1 {
                return range.interval.end
            }
            let progress = Double(index) / Double(tickCount - 1)
            return range.interval.start.addingTimeInterval(totalDuration * progress)
        }
    }

    fileprivate func position(for date: Date, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        let offset = date.timeIntervalSince(range.interval.start)
        let progress = min(max(offset / totalDuration, 0), 1)
        return CGFloat(progress) * width
    }

    fileprivate func eventWidth(for item: HeatmapEvent, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        return CGFloat(item.end.timeIntervalSince(item.start) / totalDuration) * width
    }

    fileprivate static func tickFormatter(for interval: DateInterval) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current

        switch interval.duration {
        case ..<86_400.0:
            formatter.dateFormat = "H:mm"
        case ..<1_209_600.0:
            formatter.dateFormat = "M.d H:mm"
        case ..<3_888_000.0:
            formatter.dateFormat = "M.d"
        case ..<34_560_000.0:
            formatter.dateFormat = "M月d日"
        default:
            formatter.dateFormat = "yyyy.M"
        }

        return formatter
    }

    private func tickLabel(for tick: Date, isLast: Bool) -> String {
        if isLast {
            return Self.finalTickFormatter.string(from: range.interval.end.addingTimeInterval(-1))
        }
        return Self.tickFormatter(for: range.interval).string(from: tick)
    }

    private static let finalTickFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

private struct DailyHeatmapView: View {
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 44
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let canvasWidth = max(geometry.size.width - labelWidth - horizontalPadding * 2, 320)
            let rowStride = rowHeight + rowSpacing
            let canvasHeight = max(CGFloat(categories.count) * rowStride - rowSpacing, rowHeight)
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let tickDates = timelineTicks(canvasWidth: canvasWidth)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 0) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: 20)

                        ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                            let xPosition = position(for: tick, in: canvasWidth)
                            VStack(spacing: 4) {
                                Text(tickLabel(for: tick))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: axisLabelWidth, alignment: .center)
                                    .multilineTextAlignment(.center)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 8)
                            }
                            .frame(width: axisLabelWidth)
                            .offset(x: xPosition - axisLabelWidth / 2)
                        }
                    }
                    .frame(width: canvasWidth, height: 30)
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(categories, id: \.self) { category in
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                                .frame(width: canvasWidth, height: rowHeight)
                                .offset(y: CGFloat(index) * rowStride)
                        }

                        ForEach(items) { item in
                            if let rowIndex = rowIndexMap[item.category] {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill((categoryColors[item.category] ?? .accentColor).opacity(0.78))
                                    .frame(
                                        width: max(eventWidth(for: item, in: canvasWidth), 1),
                                        height: rowHeight - 4
                                    )
                                    .offset(
                                        x: position(for: item.start, in: canvasWidth),
                                        y: CGFloat(rowIndex) * rowStride + 2
                                    )
                            }
                        }
                    }
                    .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.06))
        )
    }

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        let progress = min(max(date.timeIntervalSince(range.interval.start) / totalDuration, 0), 1)
        return CGFloat(progress) * width
    }

    private func eventWidth(for item: HeatmapEvent, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        return CGFloat(item.end.timeIntervalSince(item.start) / totalDuration) * width
    }

    private func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let hourStep = adaptiveHourStep(canvasWidth: canvasWidth)
        let totalHours = 24

        return stride(from: 0, through: totalHours, by: hourStep).compactMap { hour in
            Calendar.reportCalendar.date(byAdding: .hour, value: hour, to: range.interval.start)
        }
    }

    private func adaptiveHourStep(canvasWidth: CGFloat) -> Int {
        let maxLabelCount = max(Int(canvasWidth / axisLabelWidth), 2)
        for hourStep in [1, 2, 3, 4, 6, 8, 12] {
            if (24 / hourStep) + 1 <= maxLabelCount {
                return hourStep
            }
        }
        return 12
    }

    private func tickLabel(for tick: Date) -> String {
        let hours = Calendar.reportCalendar.dateComponents([.hour], from: range.interval.start, to: tick).hour ?? 0
        if hours == 24 {
            return "24:00"
        }
        return Self.tickFormatter.string(from: tick)
    }

    fileprivate static let tickFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "H:mm"
        return formatter
    }()
}

private struct WeeklyHeatmapView: View {
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]
    let includeWorkdays: Bool
    let includeWeekends: Bool

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 44
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let canvasWidth = max(geometry.size.width - labelWidth - horizontalPadding * 2, 320)
            let rowStride = rowHeight + rowSpacing
            let canvasHeight = max(CGFloat(categories.count) * rowStride - rowSpacing, rowHeight)
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let tickDates = timelineTicks(canvasWidth: canvasWidth)
            let fragments = weeklyFragments()
            let opacity = fragmentOpacity(for: fragments)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 0) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: 20)

                        ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                            let xPosition = position(for: tick, in: canvasWidth)
                            VStack(spacing: 4) {
                                Text(tickLabel(for: tick))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: axisLabelWidth, alignment: .center)
                                    .multilineTextAlignment(.center)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 8)
                            }
                            .frame(width: axisLabelWidth)
                            .offset(x: xPosition - axisLabelWidth / 2)
                        }
                    }
                    .frame(width: canvasWidth, height: 30)
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(categories, id: \.self) { category in
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                                .frame(width: canvasWidth, height: rowHeight)
                                .offset(y: CGFloat(index) * rowStride)
                        }

                        ForEach(fragments) { fragment in
                            if let rowIndex = rowIndexMap[fragment.category] {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill((categoryColors[fragment.category] ?? .accentColor).opacity(opacity))
                                    .frame(
                                        width: max(position(for: fragment.endSeconds, in: canvasWidth) - position(for: fragment.startSeconds, in: canvasWidth), 1),
                                        height: rowHeight - 4
                                    )
                                    .offset(
                                        x: position(for: fragment.startSeconds, in: canvasWidth),
                                        y: CGFloat(rowIndex) * rowStride + 2
                                    )
                            }
                        }
                    }
                    .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.06))
        )
    }

    private func fragmentOpacity(for fragments: [WeeklyHeatmapFragment]) -> Double {
        let recordedDayCount = Set(fragments.map(\.dayStart)).count
        guard recordedDayCount > 0 else {
            return 0
        }
        return 1.0 / Double(recordedDayCount)
    }

    private func weeklyFragments() -> [WeeklyHeatmapFragment] {
        guard includeWorkdays || includeWeekends else {
            return []
        }

        var fragments: [WeeklyHeatmapFragment] = []
        let calendar = Calendar.reportCalendar

        for item in items {
            var segmentStart = item.start
            while segmentStart < item.end {
                let dayStart = calendar.startOfDay(for: segmentStart)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? item.end
                let segmentEnd = min(item.end, dayEnd)
                let isWeekend = calendar.isDateInWeekend(segmentStart)
                let shouldInclude = isWeekend ? includeWeekends : includeWorkdays

                if shouldInclude {
                    fragments.append(
                        WeeklyHeatmapFragment(
                            id: "\(item.id)-\(segmentStart.timeIntervalSince1970)",
                            category: item.category,
                            dayStart: dayStart,
                            startSeconds: segmentStart.timeIntervalSince(dayStart),
                            endSeconds: segmentEnd.timeIntervalSince(dayStart)
                        )
                    )
                }

                segmentStart = segmentEnd
            }
        }

        return fragments
    }

    private func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let hourStep = adaptiveHourStep(canvasWidth: canvasWidth)
        let base = Calendar.reportCalendar.startOfDay(for: Date())

        return stride(from: 0, through: 24, by: hourStep).compactMap { hour in
            Calendar.reportCalendar.date(byAdding: .hour, value: hour, to: base)
        }
    }

    private func adaptiveHourStep(canvasWidth: CGFloat) -> Int {
        let maxLabelCount = max(Int(canvasWidth / axisLabelWidth), 2)
        for hourStep in [1, 2, 3, 4, 6, 8, 12] {
            if (24 / hourStep) + 1 <= maxLabelCount {
                return hourStep
            }
        }
        return 12
    }

    private func position(for seconds: TimeInterval, in width: CGFloat) -> CGFloat {
        CGFloat(min(max(seconds / 86_400.0, 0), 1)) * width
    }

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let dayStart = Calendar.reportCalendar.startOfDay(for: date)
        return position(for: date.timeIntervalSince(dayStart), in: width)
    }

    private func tickLabel(for tick: Date) -> String {
        let base = Calendar.reportCalendar.startOfDay(for: tick)
        let hours = Calendar.reportCalendar.dateComponents([.hour], from: base, to: tick).hour ?? 0
        if hours == 24 {
            return "24:00"
        }
        return DailyHeatmapView.tickFormatter.string(from: tick)
    }
}

private struct WeeklyHeatmapFragment: Identifiable {
    let id: String
    let category: String
    let dayStart: Date
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

private struct OverlayDailyHeatmapView: View {
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10
    private let axisLabelWidth: CGFloat = 44
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let canvasWidth = max(geometry.size.width - labelWidth - horizontalPadding * 2, 320)
            let rowStride = rowHeight + rowSpacing
            let canvasHeight = max(CGFloat(categories.count) * rowStride - rowSpacing, rowHeight)
            let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
            let tickDates = timelineTicks(canvasWidth: canvasWidth)
            let fragments = overlayFragments()
            let opacity = fragmentOpacity(for: fragments)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 0) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: 20)

                        ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                            let xPosition = position(for: tick, in: canvasWidth)
                            VStack(spacing: 4) {
                                Text(tickLabel(for: tick))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: axisLabelWidth, alignment: .center)
                                    .multilineTextAlignment(.center)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 8)
                            }
                            .frame(width: axisLabelWidth)
                            .offset(x: xPosition - axisLabelWidth / 2)
                        }
                    }
                    .frame(width: canvasWidth, height: 30)
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(categories, id: \.self) { category in
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(Array(categories.enumerated()), id: \.element) { index, _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index.isMultiple(of: 2) ? Color.gray.opacity(0.08) : Color.clear)
                                .frame(width: canvasWidth, height: rowHeight)
                                .offset(y: CGFloat(index) * rowStride)
                        }

                        ForEach(fragments) { fragment in
                            if let rowIndex = rowIndexMap[fragment.category] {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill((categoryColors[fragment.category] ?? .accentColor).opacity(opacity))
                                    .frame(
                                        width: max(position(for: fragment.endSeconds, in: canvasWidth) - position(for: fragment.startSeconds, in: canvasWidth), 1),
                                        height: rowHeight - 4
                                    )
                                    .offset(
                                        x: position(for: fragment.startSeconds, in: canvasWidth),
                                        y: CGFloat(rowIndex) * rowStride + 2
                                    )
                            }
                        }
                    }
                    .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.06))
        )
    }

    private func overlayFragments() -> [WeeklyHeatmapFragment] {
        var fragments: [WeeklyHeatmapFragment] = []
        let calendar = Calendar.reportCalendar

        for item in items {
            var segmentStart = item.start
            while segmentStart < item.end {
                let dayStart = calendar.startOfDay(for: segmentStart)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? item.end
                let segmentEnd = min(item.end, dayEnd)
                fragments.append(
                    WeeklyHeatmapFragment(
                        id: "\(item.id)-\(segmentStart.timeIntervalSince1970)",
                        category: item.category,
                        dayStart: dayStart,
                        startSeconds: segmentStart.timeIntervalSince(dayStart),
                        endSeconds: segmentEnd.timeIntervalSince(dayStart)
                    )
                )
                segmentStart = segmentEnd
            }
        }

        return fragments
    }

    private func fragmentOpacity(for fragments: [WeeklyHeatmapFragment]) -> Double {
        let recordedDayCount = Set(fragments.map(\.dayStart)).count
        guard recordedDayCount > 0 else {
            return 0
        }
        return 1.0 / Double(recordedDayCount)
    }

    private func timelineTicks(canvasWidth: CGFloat) -> [Date] {
        let hourStep = adaptiveHourStep(canvasWidth: canvasWidth)
        let base = Calendar.reportCalendar.startOfDay(for: Date())

        return stride(from: 0, through: 24, by: hourStep).compactMap { hour in
            Calendar.reportCalendar.date(byAdding: .hour, value: hour, to: base)
        }
    }

    private func adaptiveHourStep(canvasWidth: CGFloat) -> Int {
        let maxLabelCount = max(Int(canvasWidth / axisLabelWidth), 2)
        for hourStep in [1, 2, 3, 4, 6, 8, 12] {
            if (24 / hourStep) + 1 <= maxLabelCount {
                return hourStep
            }
        }
        return 12
    }

    private func position(for seconds: TimeInterval, in width: CGFloat) -> CGFloat {
        CGFloat(min(max(seconds / 86_400.0, 0), 1)) * width
    }

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let dayStart = Calendar.reportCalendar.startOfDay(for: date)
        return position(for: date.timeIntervalSince(dayStart), in: width)
    }

    private func tickLabel(for tick: Date) -> String {
        let base = Calendar.reportCalendar.startOfDay(for: tick)
        let hours = Calendar.reportCalendar.dateComponents([.hour], from: base, to: tick).hour ?? 0
        if hours == 24 {
            return "24:00"
        }
        return DailyHeatmapView.tickFormatter.string(from: tick)
    }
}

private extension DateFormatter {
    static let reportDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    static let reportMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()

    static let reportYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年"
        return formatter
    }()
}
