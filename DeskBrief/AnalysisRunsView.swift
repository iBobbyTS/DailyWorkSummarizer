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

struct AnalysisRunsView: View {
    @ObservedObject var viewModel: AnalysisRunsViewModel

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
                ScrollView([.horizontal]) {
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
        }
        .accessibilityIdentifier("analysisRuns.root")
        .padding(16)
        .frame(minWidth: 1100, minHeight: 400)
        .onAppear { viewModel.reload() }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            headerCell(L10n.string(.analysisRunsColumnTime, language: viewModel.language), width: 100)
            headerCell(L10n.string(.analysisRunsColumnModel, language: viewModel.language), width: 140)
            headerCell(L10n.string(.analysisRunsColumnStatus, language: viewModel.language), width: 70)
            headerCell(L10n.string(.analysisRunsColumnSuccess, language: viewModel.language), width: 80)
            headerCell(L10n.string(.analysisRunsColumnAnalysisDuration, language: viewModel.language), width: 90)
            headerCell(L10n.string(.analysisRunsColumnSummaryDuration, language: viewModel.language), width: 90)
            headerCell(L10n.string(.analysisRunsColumnAnalysisTokens, language: viewModel.language), width: 100)
            headerCell(L10n.string(.analysisRunsColumnSummaryTokens, language: viewModel.language), width: 100)
            headerCell(L10n.string(.analysisRunsColumnError, language: viewModel.language), width: 180)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
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
        return HStack(spacing: 0) {
            cell(dateFormatter.string(from: run.createdAt), width: 100)
            cell(run.modelName, width: 140)
            cell(statusText(run.status), width: 70)
            cell("\(run.successCount)/\(run.failureCount)", width: 80)
            cell(durationText(run.averageItemDurationSeconds), width: 90)
            cell(durationText(summaryRun?.averageItemDurationSeconds), width: 90)
            cell(tokensText(avg: run.totalTokensAvg, max: run.totalTokensMax), width: 100)
            cell(tokensText(avg: summaryRun?.totalTokensAvg, max: summaryRun?.totalTokensMax), width: 100)
            cell(run.errorMessage, width: 180)
        }
    }

    private func cell(_ text: String?, width: CGFloat) -> some View {
        Text(text ?? "—")
            .lineLimit(2)
            .font(.system(size: 12))
            .frame(width: width, alignment: .leading)
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
