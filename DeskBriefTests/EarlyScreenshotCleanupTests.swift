import Foundation
import Testing
@testable import DeskBrief

extension DeskBriefTests {
    @Test func earlyScreenshotCleanupMenuPresentationsMatchStateAndLanguage() async throws {
        let calculating = EarlyScreenshotCleanupCoordinator.presentation(
            scope: .oneDay,
            state: .calculating,
            language: .simplifiedChinese
        )
        let empty = EarlyScreenshotCleanupCoordinator.presentation(
            scope: .oneWeek,
            state: .ready(count: 0),
            language: .simplifiedChinese
        )
        let counted = EarlyScreenshotCleanupCoordinator.presentation(
            scope: .oneDay,
            state: .ready(count: 3),
            language: .simplifiedChinese
        )
        let failed = EarlyScreenshotCleanupCoordinator.presentation(
            scope: .oneWeek,
            state: .failed,
            language: .simplifiedChinese
        )
        let singularEnglish = EarlyScreenshotCleanupCoordinator.presentation(
            scope: .oneDay,
            state: .ready(count: 1),
            language: .english
        )

        #expect(calculating.title == "一天以前（计算中）")
        #expect(!calculating.isEnabled)
        #expect(empty.title == "一周以前（无截屏）")
        #expect(!empty.isEnabled)
        #expect(counted.title == "一天以前（3张）")
        #expect(counted.isEnabled)
        #expect(failed.title == "一周以前（计算失败）")
        #expect(!failed.isEnabled)
        #expect(singularEnglish.title == "Older Than 1 Day (1 screenshot)")
        #expect(singularEnglish.isEnabled)
    }

    @Test func earlyScreenshotCleanupCalculationUsesStrictAgeThresholds() async throws {
        let now = makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 12, minute: 0)
        let oldDayURL = URL(fileURLWithPath: "/tmp/20260429-1158-i5.jpg")
        let dayBoundaryURL = URL(fileURLWithPath: "/tmp/20260429-1200-i5.jpg")
        let oldWeekURL = URL(fileURLWithPath: "/tmp/20260423-1158-i5.jpg")

        let result = EarlyScreenshotCleanupCoordinator.calculate(
            screenshots: [
                ScreenshotFileRecord(
                    url: oldDayURL,
                    capturedAt: now.addingTimeInterval(-24 * 60 * 60 - 120),
                    durationMinutes: 5
                ),
                ScreenshotFileRecord(
                    url: dayBoundaryURL,
                    capturedAt: now.addingTimeInterval(-24 * 60 * 60),
                    durationMinutes: 5
                ),
                ScreenshotFileRecord(
                    url: oldWeekURL,
                    capturedAt: now.addingTimeInterval(-7 * 24 * 60 * 60 - 120),
                    durationMinutes: 5
                ),
            ],
            now: now
        )

        #expect(result.files(for: .oneDay) == [oldDayURL, oldWeekURL])
        #expect(result.files(for: .oneWeek) == [oldWeekURL])
        #expect(!result.files(for: .oneDay).contains(dayBoundaryURL))
    }

    @Test func earlyScreenshotCleanupScanIgnoresPreviewAndTempSubdirectories() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let screenshotsDirectory = try database.screenshotsDirectory()
        let previewDirectory = screenshotsDirectory.appendingPathComponent("preview", isDirectory: true)
        let tempDirectory = screenshotsDirectory.appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let rootScreenshot = screenshotsDirectory.appendingPathComponent("20260429-1100-i5.jpg")
        let previewScreenshot = previewDirectory.appendingPathComponent("20260429-1055-i5.jpg")
        let tempScreenshot = tempDirectory.appendingPathComponent("20260429-1050-i5.jpg")
        try writeTestScreenshotPlaceholder(to: rootScreenshot)
        try writeTestScreenshotPlaceholder(to: previewScreenshot)
        try writeTestScreenshotPlaceholder(to: tempScreenshot)

        let now = makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 12, minute: 0)
        let result = try EarlyScreenshotCleanupCoordinator.scan(
            database: database,
            defaultDurationMinutes: 5,
            now: now
        )

        #expect(result.files(for: .oneDay) == [rootScreenshot])
        #expect(!result.files(for: .oneDay).contains(previewScreenshot))
        #expect(!result.files(for: .oneDay).contains(tempScreenshot))
    }

    @Test func earlyScreenshotCleanupDoesNotStartDuplicateCalculationWhileOneIsRunning() async throws {
        let coordinator = EarlyScreenshotCleanupCoordinator()
        let now = makeScreenshotDate(year: 2026, month: 4, day: 30, hour: 12, minute: 0)
        let result = EarlyScreenshotCleanupResult(
            calculatedAt: now,
            filesByScope: [.oneDay: [URL(fileURLWithPath: "/tmp/old.jpg")], .oneWeek: []]
        )
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let firstStatus = await coordinator.beginCalculationIfNeeded(now: now) {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return result
        }
        #expect(firstStatus == .calculating)
        #expect(await waitForSemaphore(started, timeoutSeconds: 1))

        let secondStatus = await coordinator.beginCalculationIfNeeded(now: now) {
            Issue.record("Duplicate calculation should not start")
            return result
        }
        #expect(secondStatus == .calculating)
        #expect(await coordinator.calculationStartCountForTesting() == 1)

        release.signal()
        let finalStatus = await coordinator.waitForCalculation()
        #expect(finalStatus == .ready(result))

        let cachedStatus = await coordinator.beginCalculationIfNeeded(now: now.addingTimeInterval(30)) {
            Issue.record("Valid cache should be reused")
            return result
        }
        #expect(cachedStatus == .ready(result))
        #expect(await coordinator.calculationStartCountForTesting() == 1)
    }

    @Test func earlyScreenshotCleanupDeleteFilesRemovesOnlyProvidedURLs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldScreenshot = directory.appendingPathComponent("20260429-1100-i5.jpg")
        let retainedScreenshot = directory.appendingPathComponent("20260430-1100-i5.jpg")
        try writeTestScreenshotPlaceholder(to: oldScreenshot)
        try writeTestScreenshotPlaceholder(to: retainedScreenshot)

        let deletedCount = try EarlyScreenshotCleanupCoordinator.deleteFiles([oldScreenshot])

        #expect(deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: oldScreenshot.path))
        #expect(FileManager.default.fileExists(atPath: retainedScreenshot.path))
    }
}
