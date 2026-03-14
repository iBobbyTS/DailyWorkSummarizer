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
    @Published private(set) var pageItems: [ReportRange] = []
    @Published private(set) var chartItems: [CategoryDuration] = []
    @Published private(set) var heatmapItems: [HeatmapEvent] = []
    @Published private(set) var heatmapCategories: [String] = []
    @Published private(set) var totalPages: Int = 1
    @Published private(set) var allRanges: [ReportRange] = []

    private let database: AppDatabase
    private var sourceItems: [ReportSourceItem] = []
    private var databaseObserver: AnyCancellable?

    init(database: AppDatabase) {
        self.database = database
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

        let filteredItems = sourceItems.filter { selectedRange.interval.contains($0.capturedAt) }
        let grouped = Dictionary(grouping: filteredItems) {
            $0.categoryName
        }

        chartItems = grouped.map { category, items in
            CategoryDuration(
                category: category,
                hours: Double(items.reduce(0) { $0 + $1.durationMinutes }) / 60.0
            )
        }
        .sorted { lhs, rhs in
            if lhs.hours == rhs.hours {
                return lhs.category < rhs.category
            }
            return lhs.hours > rhs.hours
        }

        heatmapCategories = chartItems.map(\.category)
        heatmapItems = filteredItems
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
                    id: item.id,
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
    }

    private func buildRanges(for kind: ReportKind, from items: [ReportSourceItem]) -> [ReportRange] {
        let calendar = Calendar.reportCalendar
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

            let totalHours = Double(records.reduce(0) { $0 + $1.durationMinutes }) / 60.0
            return ReportRange(
                id: "\(kind.rawValue)-\(Int(startDate.timeIntervalSince1970))",
                label: label,
                interval: interval,
                totalHours: totalHours,
                itemCount: records.count
            )
        }
        .sorted { $0.interval.start > $1.interval.start }
    }
}

struct ReportsView: View {
    @ObservedObject var viewModel: ReportsViewModel

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 320, maxWidth: 360)

            rightPanel
                .frame(minWidth: 580)
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
                                Text("累计 \(range.totalHours.hourText)")
                                    .foregroundStyle(.secondary)
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
        }
        .padding(20)
    }

    private var rightPanel: some View {
        let categoryColors = Dictionary(uniqueKeysWithValues: viewModel.chartItems.enumerated().map { index, item in
            (item.category, Self.palette[index % Self.palette.count])
        })

        return VStack(alignment: .leading, spacing: 20) {
            if let selectedRange = viewModel.selectedRange {
                Text(selectedRange.label)
                    .font(.title2.weight(.semibold))
                Text(viewModel.selectedVisualization == .barChart ? "按分类统计截图对应的累计小时数" : "按时间连续展示各分类的截图时段")
                    .foregroundStyle(.secondary)
            } else {
                Text("查看报告")
                    .font(.title2.weight(.semibold))
                Text("左侧选择一个时间范围后，这里会展示该范围内的柱状图或热力图。")
                    .foregroundStyle(.secondary)
            }

            Picker("图表类型", selection: $viewModel.selectedVisualization) {
                ForEach(ReportVisualization.allCases) { visualization in
                    Text(visualization.title).tag(visualization)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.chartItems.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "暂无报告数据",
                    systemImage: viewModel.selectedVisualization == .barChart ? "chart.bar.xaxis" : "square.grid.3x2",
                    description: Text("当前时间范围没有可展示的分析结果。")
                )
                Spacer()
            } else {
                Group {
                    if viewModel.selectedVisualization == .barChart {
                        Chart(Array(viewModel.chartItems.enumerated()), id: \.element.category) { index, item in
                            BarMark(
                                x: .value("分类", item.category),
                                y: .value("累计小时", item.hours)
                            )
                            .foregroundStyle(Self.palette[index % Self.palette.count])
                            .annotation(position: .top) {
                                Text(item.hours.hourText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .chartXAxisLabel("分类")
                        .chartYAxisLabel("累计小时")
                        .chartLegend(.hidden)
                        .frame(height: 360)
                    } else if let selectedRange = viewModel.selectedRange {
                        HeatmapTimelineView(
                            range: selectedRange,
                            categories: viewModel.heatmapCategories,
                            items: viewModel.heatmapItems,
                            categoryColors: categoryColors
                        )
                        .frame(height: 360)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("图例")
                        .font(.headline)

                    ForEach(Array(viewModel.chartItems.enumerated()), id: \.element.category) { index, item in
                        HStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Self.palette[index % Self.palette.count])
                                .frame(width: 12, height: 12)
                            Text(item.category)
                            Spacer()
                            Text(item.hours.hourText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(24)
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

private struct HeatmapTimelineView: View {
    let range: ReportRange
    let categories: [String]
    let items: [HeatmapEvent]
    let categoryColors: [String: Color]

    private let labelWidth: CGFloat = 96
    private let rowHeight: CGFloat = 26
    private let rowSpacing: CGFloat = 10

    var body: some View {
        let canvasWidth = timelineWidth
        let rowStride = rowHeight + rowSpacing
        let canvasHeight = max(CGFloat(categories.count) * rowStride - rowSpacing, rowHeight)
        let rowIndexMap = Dictionary(uniqueKeysWithValues: categories.enumerated().map { ($0.element, $0.offset) })
        let tickDates = timelineTicks

        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    Color.clear
                        .frame(width: labelWidth, height: 1)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                            .offset(y: 20)

                        ForEach(Array(tickDates.enumerated()), id: \.offset) { index, tick in
                            let xPosition = position(for: tick, in: canvasWidth)
                            VStack(alignment: index == tickDates.count - 1 ? .trailing : .leading, spacing: 4) {
                                Text(Self.tickFormatter(for: range.interval).string(from: tick))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(width: 1, height: 8)
                            }
                            .offset(x: min(max(0, xPosition - 18), max(0, canvasWidth - 36)))
                        }
                    }
                    .frame(width: canvasWidth, height: 30)
                }

                HStack(alignment: .top, spacing: 12) {
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
            .padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.06))
        )
    }

    private var timelineWidth: CGFloat {
        let totalHours = max(range.interval.duration / 3600.0, 1)
        let pointsPerHour: CGFloat

        switch totalHours {
        case ...24:
            pointsPerHour = 36
        case ...168:
            pointsPerHour = 10
        case ...744:
            pointsPerHour = 3
        default:
            pointsPerHour = 0.4
        }

        return max(720, CGFloat(totalHours) * pointsPerHour)
    }

    private var timelineTicks: [Date] {
        let tickCount = 7
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

    private func position(for date: Date, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        let offset = date.timeIntervalSince(range.interval.start)
        let progress = min(max(offset / totalDuration, 0), 1)
        return CGFloat(progress) * width
    }

    private func eventWidth(for item: HeatmapEvent, in width: CGFloat) -> CGFloat {
        let totalDuration = max(range.interval.duration, 1)
        return CGFloat(item.end.timeIntervalSince(item.start) / totalDuration) * width
    }

    private static func tickFormatter(for interval: DateInterval) -> DateFormatter {
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
