import Foundation
import Testing
@testable import DeskBrief

@MainActor
extension DeskBriefTests {
    @Test func runCoordinatorMergesSameKindAndQueuesCrossKindRuns() {
        let coordinator = AppRunCoordinator()
        var startedAnalysisTriggers: [AnalysisTrigger] = []
        var startedSummaryRequests: [DailyReportSummaryRequest] = []
        coordinator.startAnalysisHandler = { trigger in
            startedAnalysisTriggers.append(trigger)
        }
        coordinator.startSummaryHandler = { request in
            startedSummaryRequests.append(request)
        }

        let summaryRequest = DailyReportSummaryRequest.affectedSummaries(
            dayStarts: [Date(timeIntervalSince1970: 100)],
            lmStudioLifecyclePolicy: .automaticUnload,
            waiter: nil
        )

        #expect(coordinator.requestAnalysis(trigger: .manual, canMergeWithActiveAnalysis: false) == .startNow)
        #expect(coordinator.requestAnalysis(trigger: .scheduled, canMergeWithActiveAnalysis: true) == .mergeIntoCurrentRun)
        #expect(coordinator.requestSummary(summaryRequest) == .queued)

        coordinator.finishRun(.screenshotAnalysis)

        #expect(startedAnalysisTriggers.isEmpty)
        #expect(startedSummaryRequests.count == 1)
        #expect(startedSummaryRequests[0].affectedDayStarts == summaryRequest.affectedDayStarts)
        #expect(coordinator.activeRunKind == .workContentSummary)
    }

    @Test func runCoordinatorKeepsQueuedAnalysisPriorityWithinAnalysisBucket() {
        let coordinator = AppRunCoordinator()
        var startedAnalysisTriggers: [AnalysisTrigger] = []
        coordinator.startAnalysisHandler = { trigger in
            startedAnalysisTriggers.append(trigger)
        }

        let summaryRequest = DailyReportSummaryRequest.missingDailyReports(
            lmStudioLifecyclePolicy: .automaticUnload,
            waiter: nil
        )

        #expect(coordinator.requestSummary(summaryRequest) == .startNow)
        #expect(coordinator.requestAnalysis(trigger: .scheduled, canMergeWithActiveAnalysis: false) == .queued)
        #expect(coordinator.requestAnalysis(trigger: .manual, canMergeWithActiveAnalysis: false) == .queued)

        coordinator.finishRun(.workContentSummary)

        #expect(startedAnalysisTriggers == [.manual])
        #expect(coordinator.activeRunKind == .screenshotAnalysis)
    }

    @Test func runCoordinatorMergesSummaryRequestsWhileSummaryIsActive() {
        let coordinator = AppRunCoordinator()
        let firstDay = Date(timeIntervalSince1970: 100)
        let secondDay = Date(timeIntervalSince1970: 200)
        let firstRequest = DailyReportSummaryRequest.affectedSummaries(
            dayStarts: [firstDay],
            lmStudioLifecyclePolicy: .automaticUnload,
            waiter: nil
        )
        let secondRequest = DailyReportSummaryRequest.affectedSummaries(
            dayStarts: [secondDay],
            lmStudioLifecyclePolicy: .automaticUnload,
            waiter: nil
        )

        #expect(coordinator.requestSummary(firstRequest) == .startNow)
        #expect(coordinator.requestSummary(secondRequest) == .mergeIntoCurrentRun)

        coordinator.finishRun(.workContentSummary)

        #expect(coordinator.activeRunKind == nil)
    }
}
