import Foundation

enum DailyWorkBlockComposer {
    static func groupBlocks(
        from items: [DailyReportActivityItem],
        tolerance: TimeInterval = 1
    ) -> [DailyWorkBlock] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.id < rhs.id
            }
            return lhs.capturedAt < rhs.capturedAt
        }

        guard let first = sorted.first else {
            return []
        }

        var groupedItems: [[DailyReportActivityItem]] = [[first]]

        for item in sorted.dropFirst() {
            guard let currentGroup = groupedItems.last,
                  let current = currentGroup.last else {
                groupedItems.append([item])
                continue
            }

            let isContiguous = item.categoryName == current.categoryName
                && item.capturedAt.timeIntervalSince(current.endAt) <= tolerance

            if isContiguous {
                groupedItems[groupedItems.count - 1].append(item)
            } else {
                groupedItems.append([item])
            }
        }

        return groupedItems.enumerated().map { index, group in
            let startAt = group.first?.capturedAt ?? sorted[0].capturedAt
            let endAt = group.map(\.endAt).max() ?? startAt
            return DailyWorkBlock(
                categoryName: group.first?.categoryName ?? "",
                startAt: startAt,
                endAt: endAt,
                sourceItems: group,
                isClosed: index < groupedItems.count - 1
            )
        }
    }

    static func composeDailyHeatmapEvents(
        rawItems: [DailyReportActivityItem],
        blockSummaries: [DailyWorkBlockSummaryRecord],
        range: DateInterval,
        selectedCategories: Set<String>
    ) -> [HeatmapEvent] {
        let visibleRawEvents = rawItems
            .filter { selectedCategories.contains($0.categoryName) }
            .compactMap { rawEvent(for: $0, range: range) }

        let visibleSummaryEvents = blockSummaries
            .filter { selectedCategories.contains($0.categoryName) }
            .compactMap { summaryEvent(for: $0, range: range) }

        guard !visibleSummaryEvents.isEmpty else {
            return visibleRawEvents.mergedContiguousEvents()
        }

        let summaryIntervals = visibleSummaryEvents.map { $0.hoverSummaryInterval }

        let rawFragments = visibleRawEvents
            .flatMap { event in
                subtract(interval: event.hoverSummaryInterval, removing: summaryIntervals)
                    .map { fragmentInterval in
                        HeatmapEvent(
                            id: "\(event.id)-\(Int(fragmentInterval.start.timeIntervalSince1970))-\(Int(fragmentInterval.end.timeIntervalSince1970))",
                            category: event.category,
                            start: fragmentInterval.start,
                            end: fragmentInterval.end,
                            durationMinutes: max(Int((fragmentInterval.end.timeIntervalSince(fragmentInterval.start) / 60.0).rounded()), 1)
                        )
                    }
            }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    if lhs.category == rhs.category {
                        return lhs.id < rhs.id
                    }
                    return lhs.category < rhs.category
                }
                return lhs.start < rhs.start
            }
            .mergedContiguousEvents()

        return (visibleSummaryEvents + rawFragments).sorted { lhs, rhs in
            if lhs.start == rhs.start {
                if lhs.category == rhs.category {
                    return lhs.id < rhs.id
                }
                return lhs.category < rhs.category
            }
            return lhs.start < rhs.start
        }
    }

    private static func rawEvent(for item: DailyReportActivityItem, range: DateInterval) -> HeatmapEvent? {
        guard let interval = itemInterval(for: item, range: range) else {
            return nil
        }

        return HeatmapEvent(
            id: "\(item.id)",
            category: item.categoryName,
            start: interval.start,
            end: interval.end,
            durationMinutes: max(Int((interval.end.timeIntervalSince(interval.start) / 60.0).rounded()), 1)
        )
    }

    private static func summaryEvent(for record: DailyWorkBlockSummaryRecord, range: DateInterval) -> HeatmapEvent? {
        guard let interval = record.interval.intersection(with: range), interval.end > interval.start else {
            return nil
        }

        return HeatmapEvent(
            id: "\(record.id)",
            category: record.categoryName,
            start: interval.start,
            end: interval.end,
            durationMinutes: max(Int((interval.end.timeIntervalSince(interval.start) / 60.0).rounded()), 1),
            summaryText: record.summaryText.trimmingCharacters(in: .whitespacesAndNewlines),
            summaryStart: record.startAt,
            summaryEnd: record.endAt
        )
    }

    private static func itemInterval(for item: DailyReportActivityItem, range: DateInterval) -> DateInterval? {
        let start = max(item.capturedAt, range.start)
        let end = min(item.endAt, range.end)
        guard end > start else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    private static func subtract(interval: DateInterval, removing blockers: [DateInterval]) -> [DateInterval] {
        let relevantBlockers = merge(blockers.filter { $0.intersects(interval) })
        guard !relevantBlockers.isEmpty else {
            return [interval]
        }

        var remaining = [interval]
        for blocker in relevantBlockers {
            var next: [DateInterval] = []
            for segment in remaining {
                if blocker.end <= segment.start || blocker.start >= segment.end {
                    next.append(segment)
                    continue
                }

                if blocker.start > segment.start {
                    next.append(DateInterval(start: segment.start, end: min(blocker.start, segment.end)))
                }

                if blocker.end < segment.end {
                    next.append(DateInterval(start: max(blocker.end, segment.start), end: segment.end))
                }
            }
            remaining = next
            if remaining.isEmpty {
                break
            }
        }

        return remaining.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    private static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        guard let first = sorted.first else {
            return []
        }

        var merged: [DateInterval] = [first]
        for interval in sorted.dropFirst() {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }

            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }

        return merged
    }
}

extension Array where Element == HeatmapEvent {
    func mergedContiguousEvents(tolerance: TimeInterval = 1) -> [HeatmapEvent] {
        guard var current = first else {
            return []
        }

        var merged: [HeatmapEvent] = []

        for event in dropFirst() {
            if event.category == current.category,
               event.start.timeIntervalSince(current.end) <= tolerance {
                current = Self.merge(current, with: event)
            } else {
                merged.append(current)
                current = event
            }
        }

        merged.append(current)
        return merged
    }

    private static func merge(_ lhs: HeatmapEvent, with rhs: HeatmapEvent) -> HeatmapEvent {
        let mergedStart = lhs.start
        let mergedEnd = Swift.max(lhs.end, rhs.end)
        let mergedSummaryText: String?
        let leftSummary = lhs.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightSummary = rhs.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let left = leftSummary, !left.isEmpty, let right = rightSummary, left == right {
            mergedSummaryText = left
        } else {
            mergedSummaryText = nil
        }

        return HeatmapEvent(
            id: lhs.id,
            category: lhs.category,
            start: mergedStart,
            end: mergedEnd,
            durationMinutes: Swift.max(Int((mergedEnd.timeIntervalSince(mergedStart) / 60.0).rounded()), 1),
            summaryText: mergedSummaryText,
            summaryStart: mergedSummaryText == nil ? nil : (lhs.summaryStart ?? lhs.start),
            summaryEnd: mergedSummaryText == nil ? nil : (rhs.summaryEnd ?? rhs.end)
        )
    }
}
