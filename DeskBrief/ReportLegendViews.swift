import SwiftUI

enum LegendHoverCoordinateSpace {
    static let name = "reports-legend-hover-area"
}

struct LegendItemFrame: Equatable {
    let rect: CGRect
}

struct LegendItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LegendItemFrame] = []

    static func reduce(value: inout [LegendItemFrame], nextValue: () -> [LegendItemFrame]) {
        value.append(contentsOf: nextValue())
    }
}

struct LegendHoverGeometry {
    static func hoverRects(
        for itemRects: [CGRect],
        rowTolerance: CGFloat = 2,
        margin: CGFloat = 4
    ) -> [CGRect] {
        let validRects = itemRects
            .filter { rect in
                rect.size.width > 0 && rect.size.height > 0 && !rect.isNull && !rect.isInfinite
            }
            .sorted { lhs, rhs in
                if abs(lhs.minY - rhs.minY) <= rowTolerance {
                    return lhs.minX < rhs.minX
                }
                return lhs.minY < rhs.minY
            }

        guard !validRects.isEmpty else { return [] }

        let rowRects = groupedRowRects(for: validRects, rowTolerance: rowTolerance)
            .map { $0.insetBy(dx: -margin, dy: -margin) }
        return bridgeVerticalGaps(in: rowRects)
    }

    static func contains(_ point: CGPoint, in rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }

    private static func groupedRowRects(
        for sortedRects: [CGRect],
        rowTolerance: CGFloat
    ) -> [CGRect] {
        var rows: [[CGRect]] = []

        for rect in sortedRects {
            guard let lastRow = rows.indices.last,
                  let referenceRect = rows[lastRow].first,
                  abs(referenceRect.midY - rect.midY) <= rowTolerance else {
                rows.append([rect])
                continue
            }

            rows[lastRow].append(rect)
        }

        return rows.map { row in
            row.reduce(row[0]) { partialResult, rect in
                partialResult.union(rect)
            }
        }
    }

    private static func bridgeVerticalGaps(in rowRects: [CGRect]) -> [CGRect] {
        guard rowRects.count > 1 else { return rowRects }

        return rowRects.enumerated().map { index, rowRect in
            var minY = rowRect.minY
            var maxY = rowRect.maxY

            if index > 0 {
                let previousRow = rowRects[index - 1]
                minY = bridgeBoundary(upperRow: previousRow, lowerRow: rowRect)
            }

            if index + 1 < rowRects.count {
                let nextRow = rowRects[index + 1]
                maxY = bridgeBoundary(upperRow: rowRect, lowerRow: nextRow)
            }

            return CGRect(
                x: rowRect.minX,
                y: minY,
                width: rowRect.width,
                height: max(0, maxY - minY)
            )
        }
    }

    private static func bridgeBoundary(upperRow: CGRect, lowerRow: CGRect) -> CGFloat {
        let gap = max(0, lowerRow.minY - upperRow.maxY)
        return upperRow.maxY + gap / 2
    }
}

struct WrappingFlowLayout: Layout {
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
