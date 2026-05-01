import Foundation

enum ReportHeatmapFormatting {
    static func title(for event: HeatmapEvent, in range: DateInterval, language: AppLanguage) -> String {
        let timeSpan = timeSpanText(for: event, in: range, language: language)
        let category = L10n.displayCategoryName(event.category, language: language)
        return "\(timeSpan) - \(category)"
    }

    static func summaryText(for event: HeatmapEvent) -> String? {
        let trimmed = event.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func timeSpanText(for event: HeatmapEvent, in range: DateInterval, language: AppLanguage) -> String {
        let calendar = Calendar.reportCalendar(language: language)
        let baseDay = calendar.startOfDay(for: range.start)
        let start = event.summaryStart ?? event.start
        let end = event.summaryEnd ?? event.end
        let startText = timeLabel(for: start, baseDay: baseDay, calendar: calendar, language: language)
        let endText = timeLabel(for: end, baseDay: baseDay, calendar: calendar, language: language)
        return "\(startText)-\(endText)"
    }

    private static func timeLabel(
        for date: Date,
        baseDay: Date,
        calendar: Calendar,
        language: AppLanguage
    ) -> String {
        let dayStart = calendar.startOfDay(for: date)
        let timeText = L10n.dailyHeatmapTickFormatter(language: language).string(from: date)

        if dayStart == baseDay {
            return timeText
        }

        let dayOffset = calendar.dateComponents([.day], from: baseDay, to: dayStart).day ?? 0
        if dayOffset == -1 {
            return "\(L10n.string(.reportHeatmapYesterday, language: language)) \(timeText)"
        }
        if dayOffset == 1 {
            return "\(L10n.string(.reportHeatmapTomorrow, language: language)) \(timeText)"
        }

        return "\(L10n.reportDayFormatter(language: language).string(from: dayStart)) \(timeText)"
    }
}
