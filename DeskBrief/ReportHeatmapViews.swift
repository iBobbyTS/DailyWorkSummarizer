import Foundation
import SwiftUI

struct HeatmapTimelineView: View {
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
                            Text(L10n.displayCategoryName(category))
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
        L10n.reportTickFormatter(for: interval)
    }

    private func tickLabel(for tick: Date, isLast: Bool) -> String {
        if isLast {
            return L10n.reportFinalTickFormatter().string(from: range.interval.end.addingTimeInterval(-1))
        }
        return Self.tickFormatter(for: range.interval).string(from: tick)
    }
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
                            Text(L10n.displayCategoryName(category))
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
        return L10n.dailyHeatmapTickFormatter().string(from: tick)
    }
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
                            Text(L10n.displayCategoryName(category))
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
        return L10n.dailyHeatmapTickFormatter().string(from: tick)
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
                            Text(L10n.displayCategoryName(category))
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
        return L10n.dailyHeatmapTickFormatter().string(from: tick)
    }
}
