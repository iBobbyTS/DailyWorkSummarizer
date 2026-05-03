import AppKit
import Charts
import SwiftUI

struct ReportsView: View {
    @ObservedObject var viewModel: ReportsViewModel
    @State private var hoveredLegendCategory: String?
    @State private var hoveredBarCategory: String?
    @State private var hoveredHeatmapEvent: HeatmapEvent?
    @State private var legendHoverRects: [CGRect] = []

    private var language: AppLanguage {
        viewModel.appLanguage
    }

    private var hoveredCategory: String? {
        hoveredLegendCategory ?? hoveredBarCategory
    }

    private var hoveredCategorySummary: (category: String, text: String, isTemporary: Bool)? {
        guard viewModel.selectedKind == .day,
              let hoveredCategory,
              let summary = viewModel.categorySummary(for: hoveredCategory) else {
            return nil
        }

        return (
            category: hoveredCategory,
            text: summary.text,
            isTemporary: summary.isTemporary
        )
    }

    private var hoveredHeatmapSummary: (title: String, summary: String)? {
        guard viewModel.selectedKind == .day,
              let selectedRange = viewModel.selectedRange,
              let hoveredHeatmapEvent,
              let summary = ReportHeatmapFormatting.summaryText(for: hoveredHeatmapEvent) else {
            return nil
        }

        return (
            title: ReportHeatmapFormatting.title(
                for: hoveredHeatmapEvent,
                in: selectedRange.interval,
                language: language
            ),
            summary: summary
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 340)

            Divider()

            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
        .onChange(of: viewModel.selectedKind) { _, _ in
            clearHoveredState(ReportHoverStatePolicy.resetScopeForReportContextChange())
        }
        .onChange(of: viewModel.selectedVisualization) { _, _ in
            clearHoveredState(ReportHoverStatePolicy.resetScopeForReportContextChange())
        }
        .onChange(of: viewModel.selectedRangeID) { _, _ in
            clearHoveredState(ReportHoverStatePolicy.resetScopeForReportContextChange())
        }
        .onChange(of: viewModel.selectedHeatmapCategories) { _, _ in
            clearHoveredState(ReportHoverStatePolicy.resetScopeForHeatmapSelectionChange())
        }
    }

    private var leftPanel: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(text(.reportType), selection: $viewModel.selectedKind) {
                    ForEach(ReportKind.allCases) { kind in
                        Text(kind.title(in: language)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(text(.reportPreviousPage)) {
                        viewModel.showPreviousPage()
                    }
                    .disabled(viewModel.selectedPage == 0)

                    Spacer()

                    Text("\(viewModel.selectedPage + 1) / \(viewModel.totalPages)")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(text(.reportNextPage)) {
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
                                        Text(text(.reportTotalDuration, arguments: [
                                            range.totalHours.durationText(for: viewModel.selectedKind, language: language)
                                        ]))
                                            .foregroundStyle(.secondary)
                                        if viewModel.selectedKind != .day {
                                            Text(text(.reportAverageDuration, arguments: [
                                                range.averageHoursPerDay.durationText(for: viewModel.selectedKind, language: language)
                                            ]))
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

            if let hoveredHeatmapSummary {
                heatmapHoverCard(summary: hoveredHeatmapSummary)
                    .padding(.top, 88)
                    .padding(.trailing, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(20)
    }

    private var rightPanel: some View {
        let configuredCategoryColors = viewModel.categoryColorMap
        let categoryColors = Dictionary(uniqueKeysWithValues: viewModel.chartItems.enumerated().map { index, item in
            (
                item.category,
                configuredCategoryColors[item.category] ?? Color(hexRGB: AppDefaults.categoryColorPreset(at: index))
            )
        })
        let barChartItems = viewModel.chartItems.filter { $0.category != AppDefaults.absenceCategoryName }
        let legendItems = viewModel.chartItems
        let hasAnyChartData = !viewModel.chartItems.isEmpty
        let hasHeatmapSelection = !viewModel.heatmapCategories.isEmpty

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                if let selectedRange = viewModel.selectedRange {
                    Text(selectedRange.label)
                        .font(.title2.weight(.semibold))
                } else {
                    Text(text(.reportViewTitle))
                        .font(.title2.weight(.semibold))
                }

                Spacer(minLength: 0)

                if viewModel.selectedKind == .day, viewModel.shouldShowSummarizeNowButton {
                    Button(viewModel.isGeneratingDailyReport ? text(.reportSummarizing) : text(.reportSummarizeNow)) {
                        viewModel.summarizeSelectedDay()
                    }
                    .disabled(viewModel.isGeneratingDailyReport)
                }
            }

            if viewModel.selectedKind == .day,
               let selectedDailyReport = viewModel.selectedDailyReport {
                dailySummaryCard(report: selectedDailyReport)
            }

            if viewModel.selectedKind == .day,
               let errorMessage = viewModel.dailyReportGenerationError,
               !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .center, spacing: 16) {
                Picker(text(.reportChartType), selection: $viewModel.selectedVisualization) {
                    ForEach(ReportVisualization.allCases) { visualization in
                        Text(visualization.title(in: language)).tag(visualization)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                if viewModel.selectedKind != .day {
                    Spacer(minLength: 0)

                    Toggle(text(.reportWorkdays), isOn: $viewModel.includeWorkdays)
                        .toggleStyle(.checkbox)

                    Toggle(text(.reportWeekends), isOn: $viewModel.includeWeekends)
                        .toggleStyle(.checkbox)
                }
            }

            if viewModel.selectedVisualization == .heatmap,
               viewModel.selectedKind == .month || viewModel.selectedKind == .year {
                Toggle(text(.reportOverlayDailyTime), isOn: $viewModel.overlayDailyHeatmap)
                    .toggleStyle(.switch)
            }

            if viewModel.selectedVisualization == .barChart {
                if hasAnyChartData {
                    legendFlow(items: legendItems, categoryColors: categoryColors, interactive: false)

                    if let hoveredCategorySummary {
                        categorySummaryCard(summary: hoveredCategorySummary)
                    }

                    if barChartItems.isEmpty {
                        Spacer()
                        ContentUnavailableView(
                            text(.reportNoDataTitle),
                            systemImage: "chart.bar.xaxis",
                            description: Text(text(.reportNoDataDescription))
                        )
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        chartView(barChartItems: barChartItems, categoryColors: categoryColors)
                    }
                } else {
                    Spacer()
                    ContentUnavailableView(
                        text(.reportNoDataTitle),
                        systemImage: "chart.bar.xaxis",
                        description: Text(text(.reportNoDataDescription))
                    )
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            } else {
                if hasAnyChartData {
                    legendFlow(items: legendItems, categoryColors: categoryColors, interactive: true)

                    if let hoveredCategorySummary {
                        categorySummaryCard(summary: hoveredCategorySummary)
                    }

                    if hasHeatmapSelection, let selectedRange = viewModel.selectedRange {
                        HeatmapTimelineView(
                            kind: viewModel.selectedKind,
                            range: selectedRange,
                            categories: viewModel.heatmapCategories,
                            items: viewModel.heatmapItems,
                            categoryColors: categoryColors,
                            overlayDailyHeatmap: viewModel.overlayDailyHeatmap,
                            includeWorkdays: viewModel.includeWorkdays,
                            includeWeekends: viewModel.includeWeekends,
                            hoveredDailyHeatmapEvent: $hoveredHeatmapEvent
                        )
                    } else {
                        Spacer()
                        ContentUnavailableView(
                            text(.reportHeatmapNoSelectedCategoriesTitle),
                            systemImage: "square.grid.3x2",
                            description: Text(text(.reportHeatmapNoSelectedCategoriesDescription))
                        )
                        .frame(maxWidth: .infinity)
                        Spacer()
                    }
                } else {
                    Spacer()
                    ContentUnavailableView(
                        text(.reportNoDataTitle),
                        systemImage: "square.grid.3x2",
                        description: Text(text(.reportNoDataDescription))
                    )
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private func chartView(
        barChartItems: [CategoryDuration],
        categoryColors: [String: Color]
    ) -> some View {
        Chart(Array(barChartItems.enumerated()), id: \.element.category) { index, item in
            BarMark(
                x: .value(text(.reportCategoryAxis), displayCategory(item.category)),
                y: .value(text(.reportTotalHoursAxis), item.hours)
            )
            .foregroundStyle(categoryColors[item.category] ?? Color(hexRGB: AppDefaults.categoryColorPreset(at: index)))
            .annotation(position: .top) {
                Text(item.hours.durationText(for: viewModel.selectedKind, language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxisLabel(text(.reportCategoryAxis))
        .chartYAxisLabel(text(.reportTotalHoursAxis))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard viewModel.selectedKind == .day else {
                            hoveredBarCategory = nil
                            return
                        }

                        switch phase {
                        case .active(let location):
                            guard let plotFrameAnchor = proxy.plotFrame else {
                                hoveredBarCategory = nil
                                return
                            }
                            let plotFrame = geometry[plotFrameAnchor]
                            let relativeX = location.x - plotFrame.origin.x
                            let relativeY = location.y - plotFrame.origin.y
                            guard relativeX >= 0,
                                  relativeX <= plotFrame.width,
                                  relativeY >= 0,
                                  relativeY <= plotFrame.height else {
                                hoveredBarCategory = nil
                                return
                            }

                            hoveredBarCategory = resolvedHoveredBarCategory(
                                at: relativeX,
                                proxy: proxy,
                                items: barChartItems
                            )
                        case .ended:
                            hoveredBarCategory = nil
                        }
                    }
            }
        }
    }

    private func legendFlow(
        items: [CategoryDuration],
        categoryColors: [String: Color],
        interactive: Bool
    ) -> some View {
        WrappingFlowLayout(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.category) { index, item in
                legendItem(
                    color: categoryColors[item.category] ?? Color(hexRGB: AppDefaults.categoryColorPreset(at: index)),
                    item: item,
                    interactive: interactive
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LegendItemFramePreferenceKey.self,
                            value: [
                                LegendItemFrame(
                                    rect: proxy.frame(in: .named(LegendHoverCoordinateSpace.name))
                                )
                            ]
                        )
                    }
                )
            }
        }
        .coordinateSpace(name: LegendHoverCoordinateSpace.name)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard viewModel.selectedKind == .day else { return }

            switch phase {
            case .active(let location):
                if ReportHoverStatePolicy.shouldClearLegendHover(at: location, in: legendHoverRects) {
                    hoveredLegendCategory = nil
                }
            case .ended:
                hoveredLegendCategory = nil
            }
        }
        .onPreferenceChange(LegendItemFramePreferenceKey.self) { frames in
            let hoverRects = LegendHoverGeometry.hoverRects(for: frames.map(\.rect))
            if legendHoverRects != hoverRects {
                legendHoverRects = hoverRects
            }
        }
    }

    @ViewBuilder
    private func legendItem(color: Color, item: CategoryDuration, interactive: Bool) -> some View {
        let isSelected = !interactive || viewModel.isHeatmapCategorySelected(item.category)
        let content = legendItemContent(color: color, item: item, isSelected: isSelected)

        if interactive {
            Button {
                viewModel.toggleHeatmapCategory(item.category)
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func legendItemContent(color: Color, item: CategoryDuration, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(displayCategory(item.category))
                .font(.subheadline)
            Text(item.hours.durationText(for: viewModel.selectedKind, language: language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(hoveredLegendCategory == item.category ? Color.accentColor.opacity(0.14) : Color.gray.opacity(0.08))
        )
        .opacity(isSelected ? 1 : 0.45)
        .onHover { isHovering in
            guard viewModel.selectedKind == .day else { return }

            guard isHovering else { return }

            if viewModel.categorySummary(for: item.category) != nil {
                hoveredLegendCategory = item.category
            } else {
                hoveredLegendCategory = nil
            }
        }
    }

    private func heatmapHoverCard(summary: (title: String, summary: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(summary.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                .shadow(color: Color.black.opacity(0.16), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    private func dailySummaryCard(report: DailyReportRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(text(.reportDailySummaryTitle))
                    .font(.headline)
                if report.isTemporary {
                    temporaryBadge
                }
            }

            Text(report.displayDailySummaryText)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private func categorySummaryCard(
        summary: (category: String, text: String, isTemporary: Bool)
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(displayCategory(summary.category))
                    .font(.headline)
                if summary.isTemporary {
                    temporaryBadge
                }
            }

            Text(summary.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var temporaryBadge: some View {
        Text(text(.reportTemporarySummary))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.16))
            )
    }

    private func resolvedHoveredBarCategory(
        at relativeX: CGFloat,
        proxy: ChartProxy,
        items: [CategoryDuration]
    ) -> String? {
        guard let displayName = proxy.value(atX: relativeX, as: String.self) else {
            return nil
        }
        return items.first { displayCategory($0.category) == displayName }?.category
    }

    private func clearHoveredState(_ scope: ReportHoverStatePolicy.ResetScope) {
        if scope == .all {
            hoveredLegendCategory = nil
            hoveredBarCategory = nil
        }
        hoveredHeatmapEvent = nil
    }

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: language)
    }

    private func text(_ key: L10n.Key, arguments: [CVarArg]) -> String {
        L10n.string(key, language: language, arguments: arguments)
    }

    private func displayCategory(_ categoryName: String) -> String {
        L10n.displayCategoryName(categoryName, language: language)
    }

}
