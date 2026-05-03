import Foundation

enum AnalysisTrigger: Equatable {
    case manual
    case scheduled
    case realtime

    var priority: Int {
        switch self {
        case .manual:
            return 3
        case .realtime:
            return 2
        case .scheduled:
            return 1
        }
    }
}

enum AppRunKind: Equatable {
    case screenshotAnalysis
    case workContentSummary
}

enum AppRunDecision: Equatable {
    case startNow
    case mergeIntoCurrentRun
    case queued
}

enum WorkBlockSummaryScope: Equatable {
    case none
    // Matches work blocks that intersect any of these report days, including blocks that cross midnight.
    case dayStarts(Set<Date>)
    case all

    var targetDayStarts: Set<Date>? {
        switch self {
        case .none:
            return []
        case .dayStarts(let dayStarts):
            return dayStarts
        case .all:
            return nil
        }
    }

    func merged(with other: WorkBlockSummaryScope) -> WorkBlockSummaryScope {
        switch (self, other) {
        case (.all, _), (_, .all):
            return .all
        case (.none, let scope), (let scope, .none):
            return scope
        case (.dayStarts(let lhs), .dayStarts(let rhs)):
            return .dayStarts(lhs.union(rhs))
        }
    }
}

enum DailyReportGenerationScope: Equatable {
    case none
    // Candidate days are only the input range; execution still filters out unreportable or unclosed days.
    case candidateDayStarts(Set<Date>)
    case allMissing

    func merged(with other: DailyReportGenerationScope) -> DailyReportGenerationScope {
        switch (self, other) {
        case (.allMissing, _), (_, .allMissing):
            return .allMissing
        case (.none, let scope), (let scope, .none):
            return scope
        case (.candidateDayStarts(let lhs), .candidateDayStarts(let rhs)):
            return .candidateDayStarts(lhs.union(rhs))
        }
    }
}

struct DailyReportSummaryExecutionResult {
    var dailyReports: [Date: DailyReportRecord] = [:]
    var dayErrors: [Date: Error] = [:]
}

@MainActor
final class DailyReportSummaryWaiter {
    enum ExpectedResult {
        case completion
        case dailyReport(Date)
    }

    let expectedResult: ExpectedResult
    private var continuation: CheckedContinuation<DailyReportRecord?, Error>?

    init(
        expectedResult: ExpectedResult,
        continuation: CheckedContinuation<DailyReportRecord?, Error>
    ) {
        self.expectedResult = expectedResult
        self.continuation = continuation
    }

    func resumeSuccess(_ result: DailyReportSummaryExecutionResult) {
        guard let continuation else { return }
        self.continuation = nil

        switch expectedResult {
        case .completion:
            continuation.resume(returning: nil)
        case .dailyReport(let dayStart):
            if let record = result.dailyReports[dayStart] {
                continuation.resume(returning: record)
            } else if let error = result.dayErrors[dayStart] {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: DailyReportSummaryServiceError.noActivity(""))
            }
        }
    }

    func resumeFailure(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

struct DailyReportSummaryRequest {
    var workBlockScope: WorkBlockSummaryScope
    var dailyReportScope: DailyReportGenerationScope
    var explicitDayStarts: Set<Date>
    var lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy
    var waiters: [DailyReportSummaryWaiter]

    static func backfill(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy,
        waiter: DailyReportSummaryWaiter?
    ) -> DailyReportSummaryRequest {
        DailyReportSummaryRequest(
            workBlockScope: .all,
            dailyReportScope: .allMissing,
            explicitDayStarts: [],
            lmStudioLifecyclePolicy: lmStudioLifecyclePolicy,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    static func missingDailyReports(
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy,
        waiter: DailyReportSummaryWaiter?
    ) -> DailyReportSummaryRequest {
        DailyReportSummaryRequest(
            workBlockScope: .none,
            dailyReportScope: .allMissing,
            explicitDayStarts: [],
            lmStudioLifecyclePolicy: lmStudioLifecyclePolicy,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    static func affectedSummaries(
        dayStarts: Set<Date>,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy,
        waiter: DailyReportSummaryWaiter?
    ) -> DailyReportSummaryRequest {
        DailyReportSummaryRequest(
            workBlockScope: .dayStarts(dayStarts),
            dailyReportScope: .none,
            explicitDayStarts: [],
            lmStudioLifecyclePolicy: lmStudioLifecyclePolicy,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    // One follow-up request after an analysis run can contain both work-block and daily-report tasks.
    static func summariesAfterAnalysisRun(
        workBlockDayStarts: Set<Date>,
        dailyReportCandidateDayStarts: Set<Date>,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy,
        waiter: DailyReportSummaryWaiter?
    ) -> DailyReportSummaryRequest {
        DailyReportSummaryRequest(
            workBlockScope: workBlockDayStarts.isEmpty ? .none : .dayStarts(workBlockDayStarts),
            dailyReportScope: dailyReportCandidateDayStarts.isEmpty ? .none : .candidateDayStarts(dailyReportCandidateDayStarts),
            explicitDayStarts: [],
            lmStudioLifecyclePolicy: lmStudioLifecyclePolicy,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    static func explicitDay(
        _ dayStart: Date,
        lmStudioLifecyclePolicy: DailyReportLMStudioLifecyclePolicy,
        waiter: DailyReportSummaryWaiter?
    ) -> DailyReportSummaryRequest {
        DailyReportSummaryRequest(
            workBlockScope: .none,
            dailyReportScope: .none,
            explicitDayStarts: [dayStart],
            lmStudioLifecyclePolicy: lmStudioLifecyclePolicy,
            waiters: waiter.map { [$0] } ?? []
        )
    }

    mutating func merge(_ other: DailyReportSummaryRequest) {
        workBlockScope = workBlockScope.merged(with: other.workBlockScope)
        dailyReportScope = dailyReportScope.merged(with: other.dailyReportScope)
        explicitDayStarts.formUnion(other.explicitDayStarts)
        if lmStudioLifecyclePolicy != other.lmStudioLifecyclePolicy {
            lmStudioLifecyclePolicy = .loadForSummaryThenUnload
        }
        waiters.append(contentsOf: other.waiters)
    }
}

@MainActor
final class AppRunCoordinator {
    typealias StartAnalysisHandler = (AnalysisTrigger) -> Void
    typealias StartSummaryHandler = (DailyReportSummaryRequest) -> Void

    private struct PendingAnalysis {
        var trigger: AnalysisTrigger
        let sequence: Int
    }

    private struct PendingSummary {
        var request: DailyReportSummaryRequest
        let sequence: Int
    }

    var startAnalysisHandler: StartAnalysisHandler?
    var startSummaryHandler: StartSummaryHandler?

    private(set) var activeRunKind: AppRunKind?
    private var pendingAnalysis: PendingAnalysis?
    private var pendingSummary: PendingSummary?
    private var nextSequence = 0

    var isAnyRunActive: Bool {
        activeRunKind != nil
    }

    func requestAnalysis(
        trigger: AnalysisTrigger,
        canMergeWithActiveAnalysis: Bool
    ) -> AppRunDecision {
        guard let activeRunKind else {
            self.activeRunKind = .screenshotAnalysis
            return .startNow
        }

        if activeRunKind == .screenshotAnalysis, canMergeWithActiveAnalysis {
            return .mergeIntoCurrentRun
        }

        rememberPendingAnalysis(trigger)
        return .queued
    }

    func requestSummary(_ request: DailyReportSummaryRequest) -> AppRunDecision {
        guard let activeRunKind else {
            self.activeRunKind = .workContentSummary
            return .startNow
        }

        if activeRunKind == .workContentSummary {
            return .mergeIntoCurrentRun
        }

        rememberPendingSummary(request)
        return .queued
    }

    func finishRun(_ kind: AppRunKind) {
        guard activeRunKind == kind else {
            return
        }

        activeRunKind = nil
        startNextRunIfNeeded()
    }

    private func rememberPendingAnalysis(_ trigger: AnalysisTrigger) {
        if var pendingAnalysis {
            if trigger.priority > pendingAnalysis.trigger.priority {
                pendingAnalysis.trigger = trigger
            }
            self.pendingAnalysis = pendingAnalysis
            return
        }

        pendingAnalysis = PendingAnalysis(trigger: trigger, sequence: claimSequence())
    }

    private func rememberPendingSummary(_ request: DailyReportSummaryRequest) {
        if var pendingSummary {
            pendingSummary.request.merge(request)
            self.pendingSummary = pendingSummary
            return
        }

        pendingSummary = PendingSummary(request: request, sequence: claimSequence())
    }

    private func startNextRunIfNeeded() {
        guard activeRunKind == nil else {
            return
        }

        switch nextPendingRunKind() {
        case .screenshotAnalysis:
            guard let pendingAnalysis else { return }
            self.pendingAnalysis = nil
            activeRunKind = .screenshotAnalysis
            startAnalysisHandler?(pendingAnalysis.trigger)
        case .workContentSummary:
            guard let pendingSummary else { return }
            self.pendingSummary = nil
            activeRunKind = .workContentSummary
            startSummaryHandler?(pendingSummary.request)
        case nil:
            return
        }
    }

    private func nextPendingRunKind() -> AppRunKind? {
        switch (pendingAnalysis, pendingSummary) {
        case (.some(let analysis), .some(let summary)):
            return analysis.sequence <= summary.sequence ? .screenshotAnalysis : .workContentSummary
        case (.some, .none):
            return .screenshotAnalysis
        case (.none, .some):
            return .workContentSummary
        case (.none, .none):
            return nil
        }
    }

    private func claimSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }
}
