import Foundation

struct AnalysisRunResult {
    let analysisRunID: Int64?
    let trigger: AnalysisTrigger
    let successCount: Int
    let failureCount: Int
    let inputMeanTokens: Double?
    let inputMaxTokens: Int?
    let outputMeanTokens: Double?
    let outputMaxTokens: Int?
    let averageItemDurationSeconds: Double?
    let errorMessage: String?
    let affectedDayStarts: Set<Date>
    let dailyReportCandidateDayStarts: Set<Date>
    let wasCancelled: Bool
}
