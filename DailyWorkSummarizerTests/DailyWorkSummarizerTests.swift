//
//  DailyWorkSummarizerTests.swift
//  DailyWorkSummarizerTests
//
//  Created by iBobby on 2025-12-01.
//

import Foundation
import CoreGraphics
import Testing
@testable import DailyWorkSummarizer

struct DailyWorkSummarizerTests {
    @Test func openAICompatibleURLNormalization() async throws {
        let url1 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000")
        let url2 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1")
        let url3 = ModelProvider.openAI.requestURL(from: "http://127.0.0.1:8000/v1/chat/completions")

        #expect(url1?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url2?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(url3?.absoluteString == "http://127.0.0.1:8000/v1/chat/completions")
    }

    @Test func lmStudioURLNormalization() async throws {
        let url1 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234")
        let url2 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api")
        let url3 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1")
        let url4 = ModelProvider.lmStudio.requestURL(from: "http://127.0.0.1:1234/api/v1/chat")

        #expect(url1?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url2?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url3?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
        #expect(url4?.absoluteString == "http://127.0.0.1:1234/api/v1/chat")
    }

    @Test func nextAnalysisDateFallsToTomorrowWhenTodayIsMissed() async throws {
        var calendar = Calendar.reportCalendar
        calendar.timeZone = TimeZone(identifier: "America/Edmonton") ?? .current

        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 20, minute: 10))!
        let snapshot = AppSettingsSnapshot(
            screenshotIntervalMinutes: 5,
            analysisTimeMinutes: 18 * 60 + 30,
            automaticAnalysisEnabled: true,
            autoAnalysisRequiresCharger: false,
            provider: .openAI,
            apiBaseURL: "",
            modelName: "",
            apiKey: "",
            lmStudioContextLength: AppDefaults.lmStudioContextLength,
            categoryRules: []
        )

        let next = snapshot.nextAnalysisDate(after: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)

        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 14)
        #expect(components.hour == 18)
        #expect(components.minute == 30)
    }

    @Test func absenceRequiresSameMouseLocationAndSameFrontmostApp() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.Safari"
        )

        #expect(shouldRecord)
    }

    @Test func absenceDoesNotRecordWhenFrontmostAppChanges() async throws {
        let shouldRecord = ScreenshotService.shouldRecordAbsence(
            currentMouseLocation: CGPoint(x: 120, y: 240),
            lastMouseLocation: CGPoint(x: 120, y: 240),
            currentFrontmostAppIdentifier: "com.apple.Safari",
            lastFrontmostAppIdentifier: "com.apple.dt.Xcode"
        )

        #expect(!shouldRecord)
    }

    @Test func retryPolicyRetriesServerAndInvalidResponseErrorsBeforeMaxAttempts() async throws {
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.httpError(statusCode: 500, body: "server error"),
                attempt: 1
            )
        )
        #expect(
            AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("no output"),
                attempt: 2
            )
        )
    }

    @Test func retryPolicyDoesNotRetryLengthOrFourthAttempt() async throws {
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.lengthTruncated("truncated"),
                attempt: 1
            )
        )
        #expect(
            !AnalysisService.shouldRetryAnalysis(
                after: AnalysisServiceError.invalidResponse("invalid category"),
                attempt: 3
            )
        )
    }

    @Test func pauseAfterFiveConsecutiveFailures() async throws {
        #expect(!AnalysisService.shouldPauseAfterConsecutiveFailures(4))
        #expect(AnalysisService.shouldPauseAfterConsecutiveFailures(5))
    }

    @Test func runtimeErrorRecordingFiltersOutNonAPIErrors() async throws {
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidResponse("empty output")))
        #expect(AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.httpError(statusCode: 500, body: "server error")))
        #expect(!AnalysisService.shouldRecordRuntimeError(AnalysisServiceError.invalidConfiguration("missing url")))
        #expect(!AnalysisService.shouldRecordRuntimeError(CancellationError()))
    }
}
