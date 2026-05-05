import AppKit
import Combine
import SwiftUI

@MainActor
final class AnalysisRunsViewModel: ObservableObject {
    private let database: AppDatabase
    private let settingsStore: SettingsStore

    @Published var analysisRuns: [AnalysisRunRecord] = []
    @Published var summaryRunsByAnalysisID: [Int64: SummaryRunRecord] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var observer: NSObjectProtocol?

    var language: AppLanguage {
        settingsStore.appLanguage
    }

    init(database: AppDatabase, settingsStore: SettingsStore) {
        self.database = database
        self.settingsStore = settingsStore
        observer = NotificationCenter.default.addObserver(
            forName: .appDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        do {
            let runs = try database.fetchAnalysisRuns()
            let summaries = try database.fetchSummaryRuns()
            analysisRuns = runs
            var summaryMap: [Int64: SummaryRunRecord] = [:]
            for s in summaries {
                if let aid = s.analysisRunID {
                    summaryMap[aid] = s
                }
            }
            summaryRunsByAnalysisID = summaryMap
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct WeightedColumnLayout: Layout {
    let weights: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let totalWidth = proposal.width ?? 0
        let widths = computeWidths(total: totalWidth)
        var maxHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.init(width: widths[index], height: nil))
            maxHeight = max(maxHeight, size.height)
        }
        return CGSize(width: totalWidth, height: maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let totalWidth = bounds.width
        let widths = computeWidths(total: totalWidth)
        var x: CGFloat = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let w = widths[index]
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: .init(width: w, height: nil)
            )
            x += w
        }
    }

    private func computeWidths(total: CGFloat) -> [CGFloat] {
        weights.map { max($0 * total, 50) }
    }
}

struct AnalysisRunsView: View {
    @ObservedObject var viewModel: AnalysisRunsViewModel

    private let columnWeights: [CGFloat] = [
        100 / 910,
        140 / 910,
        70 / 910,
        80 / 910,
        90 / 910,
        90 / 910,
        100 / 910,
        100 / 910,
        140 / 910,
    ]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private let durationFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.analysisRuns.isEmpty {
                ContentUnavailableView(
                    L10n.string(.windowAnalysisRunsEmptyTitle, language: viewModel.language),
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text(L10n.string(.windowAnalysisRunsEmptyDescription, language: viewModel.language))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    headerRow
                    Divider()
                    ScrollView([.vertical]) {
                        rows
                    }
                }
                .font(.system(size: 12))
            }
        }
        .accessibilityIdentifier("analysisRuns.root")
        .padding(16)
        .frame(minWidth: 800, minHeight: 400)
        .onAppear { viewModel.reload() }
    }

    private var headerRow: some View {
        WeightedColumnLayout(weights: columnWeights) {
            headerCell(L10n.string(.analysisRunsColumnTime, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnModel, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnStatus, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnSuccess, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnAnalysisDuration, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnSummaryDuration, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnAnalysisTokens, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnSummaryTokens, language: viewModel.language))
            headerCell(L10n.string(.analysisRunsColumnError, language: viewModel.language))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func headerCell(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
    }

    private var rows: some View {
        ForEach(viewModel.analysisRuns) { run in
            VStack(spacing: 0) {
                rowContent(for: run)
                Divider()
            }
        }
    }

    private func rowContent(for run: AnalysisRunRecord) -> some View {
        let summaryRun = viewModel.summaryRunsByAnalysisID[run.id]
        return WeightedColumnLayout(weights: columnWeights) {
            cell(dateFormatter.string(from: run.createdAt))
            cell(run.modelName)
            cell(statusText(run.status))
            cell("\(run.successCount)/\(run.failureCount)")
            cell(durationText(run.averageItemDurationSeconds))
            cell(durationText(summaryRun?.averageItemDurationSeconds))
            cell(tokensText(avg: run.totalTokensAvg, max: run.totalTokensMax))
            cell(tokensText(avg: summaryRun?.totalTokensAvg, max: summaryRun?.totalTokensMax))
            cell(run.errorMessage)
        }
        .frame(maxWidth: .infinity)
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "succeeded":
            return L10n.string(.analysisRunsStatusSucceeded, language: viewModel.language)
        case "failed":
            return L10n.string(.analysisRunsStatusFailed, language: viewModel.language)
        case "cancelled":
            return L10n.string(.analysisRunsStatusCancelled, language: viewModel.language)
        case "partial_failed":
            return L10n.string(.analysisRunsStatusPartial, language: viewModel.language)
        case "running":
            return L10n.string(.analysisRunsStatusRunning, language: viewModel.language)
        default:
            return status
        }
    }

    private func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let value = durationFormatter.string(from: NSNumber(value: seconds)) ?? String(format: "%.1f", seconds)
        return "\(value)s"
    }

    private func tokensText(avg: Double?, max: Int?) -> String {
        guard let avg, let max else { return "—" }
        let avgStr = String(format: "%.0f", avg)
        return "\(avgStr)/\(max)"
    }
}
