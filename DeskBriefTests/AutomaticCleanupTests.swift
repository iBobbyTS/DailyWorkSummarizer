import Foundation
import Testing
@testable import DeskBrief

extension DeskBriefTests {
    // MARK: - Retention Days Calculation

    @Test func screenshotAutoDeletionRetentionDaysReturnsCorrectValues() async throws {
        #expect(ScreenshotAutoDeletionRetention.off.retentionDays == nil)
        #expect(ScreenshotAutoDeletionRetention.sevenDays.retentionDays == 7)
        #expect(ScreenshotAutoDeletionRetention.fourteenDays.retentionDays == 14)
        #expect(ScreenshotAutoDeletionRetention.twentyEightDays.retentionDays == 28)
    }

    // MARK: - File Age Filtering

    @Test func screenshotAutoDeletionAgeFilteringIncludesOnlyFilesOlderThanCutoff() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let screenshotsDirectory = try database.screenshotsDirectory()

        // Create files with capture times at various ages relative to a fixed "now" reference.
        // Using May 6, 2026 as "now".
        // 28-day cutoff = April 8, 2026 (now - 28 * 86400)
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let retentionDays = 28
        // cutoff = April 8, 2026 12:00

        // File older than cutoff: April 7, 2026 12:00
        let oldFileURL = screenshotsDirectory.appendingPathComponent("20260407-1200-i5.jpg")
        // File newer than cutoff: April 9, 2026 12:00
        let newFileURL = screenshotsDirectory.appendingPathComponent("20260409-1200-i5.jpg")
        // File exactly at cutoff boundary: April 8, 2026 12:00
        let boundaryFileURL = screenshotsDirectory.appendingPathComponent("20260408-1200-i5.jpg")

        try writeTestScreenshotPlaceholder(to: oldFileURL)
        try writeTestScreenshotPlaceholder(to: newFileURL)
        try writeTestScreenshotPlaceholder(to: boundaryFileURL)

        let screenshots = try database.listScreenshotFiles(defaultDurationMinutes: 5)

        #expect(screenshots.count == 3)

        let filesToDelete = AutomaticScreenshotCleanupTimer.filesEligibleForDeletion(
            screenshots: screenshots,
            retentionDays: retentionDays,
            now: now
        )
            .map { $0.lastPathComponent }
            .sorted()

        #expect(filesToDelete == ["20260407-1200-i5.jpg"])
        // boundary file should NOT be included (equal, not less)
        #expect(!filesToDelete.contains("20260408-1200-i5.jpg"))
        #expect(!filesToDelete.contains("20260409-1200-i5.jpg"))
    }

    @Test func screenshotAutoDeletionAgeFilteringWith7DayRetention() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let screenshotsDirectory = try database.screenshotsDirectory()

        // Using May 6, 2026 as "now". 7-day cutoff = April 29, 2026 12:00
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let retentionDays = 7

        let oldFileURL = screenshotsDirectory.appendingPathComponent("20260428-1200-i5.jpg")
        let newFileURL = screenshotsDirectory.appendingPathComponent("20260430-1200-i5.jpg")

        try writeTestScreenshotPlaceholder(to: oldFileURL)
        try writeTestScreenshotPlaceholder(to: newFileURL)

        let screenshots = try database.listScreenshotFiles(defaultDurationMinutes: 5)
        #expect(screenshots.count == 2)

        let filesToDelete = AutomaticScreenshotCleanupTimer.filesEligibleForDeletion(
            screenshots: screenshots,
            retentionDays: retentionDays,
            now: now
        )
            .map { $0.lastPathComponent }
            .sorted()

        #expect(filesToDelete == ["20260428-1200-i5.jpg"])
    }

    @Test func screenshotAutoDeletionAgeFilteringWith14DayRetention() async throws {
        let databaseURL = makeTemporaryDatabaseURL()
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }

        let database = try AppDatabase(databaseURL: databaseURL, applicationSupportDirectory: supportURL)
        let screenshotsDirectory = try database.screenshotsDirectory()

        // Using May 6, 2026 as "now". 14-day cutoff = April 22, 2026 12:00
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let retentionDays = 14

        let oldFileURL = screenshotsDirectory.appendingPathComponent("20260421-1200-i5.jpg")
        let newFileURL = screenshotsDirectory.appendingPathComponent("20260423-1200-i5.jpg")

        try writeTestScreenshotPlaceholder(to: oldFileURL)
        try writeTestScreenshotPlaceholder(to: newFileURL)

        let screenshots = try database.listScreenshotFiles(defaultDurationMinutes: 5)
        #expect(screenshots.count == 2)

        let filesToDelete = AutomaticScreenshotCleanupTimer.filesEligibleForDeletion(
            screenshots: screenshots,
            retentionDays: retentionDays,
            now: now
        )
            .map { $0.lastPathComponent }
            .sorted()

        #expect(filesToDelete == ["20260421-1200-i5.jpg"])
    }

    // MARK: - Root-Only Scope

    @Test func screenshotListFilesExcludesSubdirectoryFiles() async throws {
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

        let rootFileURL = screenshotsDirectory.appendingPathComponent("20260429-1100-i5.jpg")
        let previewFileURL = previewDirectory.appendingPathComponent("20260429-1055-i5.jpg")
        let tempFileURL = tempDirectory.appendingPathComponent("20260429-1050-i5.jpg")

        try writeTestScreenshotPlaceholder(to: rootFileURL)
        try writeTestScreenshotPlaceholder(to: previewFileURL)
        try writeTestScreenshotPlaceholder(to: tempFileURL)

        let screenshots = try database.listScreenshotFiles(defaultDurationMinutes: 5)

        #expect(screenshots.count == 1)
        #expect(screenshots[0].url.standardizedFileURL == rootFileURL.standardizedFileURL)

        let listedPaths = screenshots.map { $0.url.standardizedFileURL }
        #expect(!listedPaths.contains(previewFileURL.standardizedFileURL))
        #expect(!listedPaths.contains(tempFileURL.standardizedFileURL))
    }

    // MARK: - Off Retention Skips Cleanup

    @Test func screenshotAutoDeletionOffRetentionReturnsNilRetentionDays() async throws {
        #expect(ScreenshotAutoDeletionRetention.off.retentionDays == nil)
    }

    // MARK: - Enum Cases

    @Test func screenshotAutoDeletionRetentionAllCasesArePresent() async throws {
        let allCases = ScreenshotAutoDeletionRetention.allCases
        #expect(allCases.count == 4)
        #expect(allCases.contains(.off))
        #expect(allCases.contains(.sevenDays))
        #expect(allCases.contains(.fourteenDays))
        #expect(allCases.contains(.twentyEightDays))
    }

    @Test func screenshotAutoDeletionRetentionRawValues() async throws {
        #expect(ScreenshotAutoDeletionRetention.off.rawValue == "off")
        #expect(ScreenshotAutoDeletionRetention.sevenDays.rawValue == "7")
        #expect(ScreenshotAutoDeletionRetention.fourteenDays.rawValue == "14")
        #expect(ScreenshotAutoDeletionRetention.twentyEightDays.rawValue == "28")
    }

    @Test func screenshotAutoDeletionRetentionInitFromRawValue() async throws {
        #expect(ScreenshotAutoDeletionRetention(rawValue: "off") == .off)
        #expect(ScreenshotAutoDeletionRetention(rawValue: "7") == .sevenDays)
        #expect(ScreenshotAutoDeletionRetention(rawValue: "14") == .fourteenDays)
        #expect(ScreenshotAutoDeletionRetention(rawValue: "28") == .twentyEightDays)
        #expect(ScreenshotAutoDeletionRetention(rawValue: "invalid") == nil)
        #expect(ScreenshotAutoDeletionRetention(rawValue: "") == nil)
    }

    // MARK: - AppDefaults Constants

    @Test func screenshotAutoDeletionAppDefaultsConstants() async throws {
        #expect(AppDefaults.screenshotAutoDeletionRetentionDays == .twentyEightDays)
        #expect(AppDefaults.screenshotAutoDeletionCheckIntervalSeconds == 3600)
    }

    // MARK: - Timer Scheduling and Lifecycle

    @MainActor
    @Test func automaticCleanupTimerDoesNotScheduleWhenBackgroundServicesDisabled() async throws {
        let fixture = try makeAutomaticCleanupFixture(retention: .twentyEightDays)
        defer { fixture.cleanUp() }

        let scheduler = ManualAutomaticScreenshotCleanupScheduler()
        let timer = AutomaticScreenshotCleanupTimer(
            database: fixture.database,
            settingsStore: fixture.settingsStore,
            logStore: fixture.logStore,
            backgroundServicesEnabled: false,
            scheduler: scheduler
        )

        timer.start()
        #expect(!timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals.isEmpty)

        timer.reschedule()
        #expect(!timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals.isEmpty)

        timer.setBackgroundServicesEnabled(true)
        #expect(timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals == [AppDefaults.screenshotAutoDeletionCheckIntervalSeconds])

        timer.setBackgroundServicesEnabled(false)
        #expect(!timer.isScheduledForTesting)
        #expect(scheduler.timers.last?.isInvalidated == true)
    }

    @MainActor
    @Test func automaticCleanupTimerStartIsIdempotentAndRetentionOffStopsTimer() async throws {
        let fixture = try makeAutomaticCleanupFixture(retention: .twentyEightDays)
        defer { fixture.cleanUp() }

        let scheduler = ManualAutomaticScreenshotCleanupScheduler()
        let timer = AutomaticScreenshotCleanupTimer(
            database: fixture.database,
            settingsStore: fixture.settingsStore,
            logStore: fixture.logStore,
            scheduler: scheduler
        )

        timer.start()
        timer.start()
        #expect(timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals.count == 1)

        fixture.settingsStore.screenshotAutoDeletionRetention = .off
        timer.reschedule()
        #expect(!timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals.count == 1)
        #expect(scheduler.timers.last?.isInvalidated == true)

        fixture.settingsStore.screenshotAutoDeletionRetention = .sevenDays
        timer.reschedule()
        #expect(timer.isScheduledForTesting)
        #expect(scheduler.scheduledIntervals.count == 2)
    }

    @MainActor
    @Test func automaticCleanupTimerFireDeletesExpiredRootFilesAndPostsNotification() async throws {
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let fixture = try makeAutomaticCleanupFixture(retention: .sevenDays)
        defer { fixture.cleanUp() }

        let screenshotsDirectory = try fixture.database.screenshotsDirectory()
        let oldFileURL = screenshotsDirectory.appendingPathComponent("20260428-1200-i5.jpg")
        let boundaryFileURL = screenshotsDirectory.appendingPathComponent("20260429-1200-i5.jpg")
        let newFileURL = screenshotsDirectory.appendingPathComponent("20260430-1200-i5.jpg")
        let previewDirectory = screenshotsDirectory.appendingPathComponent("preview", isDirectory: true)
        let tempDirectory = screenshotsDirectory.appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let previewFileURL = previewDirectory.appendingPathComponent("20260428-1155-i5.jpg")
        let tempFileURL = tempDirectory.appendingPathComponent("20260428-1150-i5.jpg")

        for fileURL in [oldFileURL, boundaryFileURL, newFileURL, previewFileURL, tempFileURL] {
            try writeTestScreenshotPlaceholder(to: fileURL)
        }

        let scheduler = ManualAutomaticScreenshotCleanupScheduler()
        let timer = AutomaticScreenshotCleanupTimer(
            database: fixture.database,
            settingsStore: fixture.settingsStore,
            logStore: fixture.logStore,
            scheduler: scheduler,
            nowProvider: { now }
        )

        let semaphore = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .screenshotFilesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            semaphore.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        timer.start()
        scheduler.fireLatest()

        let deleted = await waitUntil(timeoutSeconds: 2) {
            !FileManager.default.fileExists(atPath: oldFileURL.path)
        }
        #expect(deleted)
        #expect(await waitForSemaphore(semaphore, timeoutSeconds: 2))
        #expect(FileManager.default.fileExists(atPath: boundaryFileURL.path))
        #expect(FileManager.default.fileExists(atPath: newFileURL.path))
        #expect(FileManager.default.fileExists(atPath: previewFileURL.path))
        #expect(FileManager.default.fileExists(atPath: tempFileURL.path))
    }

    @MainActor
    @Test func automaticCleanupOffRetentionDoesNotDeleteOrNotify() async throws {
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let fixture = try makeAutomaticCleanupFixture(retention: .off)
        defer { fixture.cleanUp() }

        let screenshotsDirectory = try fixture.database.screenshotsDirectory()
        let oldFileURL = screenshotsDirectory.appendingPathComponent("20260401-1200-i5.jpg")
        try writeTestScreenshotPlaceholder(to: oldFileURL)

        let timer = AutomaticScreenshotCleanupTimer(
            database: fixture.database,
            settingsStore: fixture.settingsStore,
            logStore: fixture.logStore
        )

        let semaphore = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .screenshotFilesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            semaphore.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await timer.performCleanupForTesting(now: now)

        #expect(FileManager.default.fileExists(atPath: oldFileURL.path))
        #expect(!(await waitForSemaphore(semaphore, timeoutSeconds: 0.2)))
    }

    @MainActor
    @Test func automaticCleanupSkipsOverlappingCleanupRuns() async throws {
        let now = makeScreenshotDate(year: 2026, month: 5, day: 6, hour: 12, minute: 0)
        let fixture = try makeAutomaticCleanupFixture(retention: .sevenDays)
        defer { fixture.cleanUp() }

        let screenshotsDirectory = try fixture.database.screenshotsDirectory()
        try writeTestScreenshotPlaceholder(
            to: screenshotsDirectory.appendingPathComponent("20260401-1200-i5.jpg")
        )

        let probe = BlockingAutomaticCleanupProbe()
        let timer = AutomaticScreenshotCleanupTimer(
            database: fixture.database,
            settingsStore: fixture.settingsStore,
            logStore: fixture.logStore,
            cleanupOperation: { fileURLs in
                probe.cleanup(fileURLs: fileURLs)
            }
        )

        let firstCleanup = Task { @MainActor in
            await timer.performCleanupForTesting(now: now)
        }
        #expect(await waitForSemaphore(probe.started, timeoutSeconds: 2))
        #expect(timer.isCleaningUpForTesting)

        await timer.performCleanupForTesting(now: now)
        #expect(probe.callCount == 1)

        probe.release.signal()
        await firstCleanup.value
        #expect(!timer.isCleaningUpForTesting)
        #expect(probe.callCount == 1)
    }
}

private struct AutomaticCleanupFixture {
    let supportURL: URL
    let suiteName: String
    let userDefaults: UserDefaults
    let database: AppDatabase
    let settingsStore: SettingsStore
    let logStore: AppLogStore

    func cleanUp() {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: supportURL)
    }
}

@MainActor
private func makeAutomaticCleanupFixture(
    retention: ScreenshotAutoDeletionRetention
) throws -> AutomaticCleanupFixture {
    let supportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

    let suiteName = "DeskBriefAutomaticCleanupTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)

    let database = try AppDatabase(
        databaseURL: supportURL.appendingPathComponent("desk-brief.sqlite", isDirectory: false),
        applicationSupportDirectory: supportURL
    )
    let logStore = AppLogStore(database: database)
    let settingsStore = SettingsStore(
        database: database,
        userDefaults: userDefaults,
        keychain: FakeKeychainStore(),
        logStore: logStore
    )
    settingsStore.screenshotAutoDeletionRetention = retention

    return AutomaticCleanupFixture(
        supportURL: supportURL,
        suiteName: suiteName,
        userDefaults: userDefaults,
        database: database,
        settingsStore: settingsStore,
        logStore: logStore
    )
}

@MainActor
private final class ManualAutomaticScreenshotCleanupScheduler: AutomaticScreenshotCleanupScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var timers: [ManualAutomaticScreenshotCleanupTimerHandle] = []

    func scheduleRepeatingTimer(
        interval: TimeInterval,
        handler: @escaping @MainActor () -> Void
    ) -> AutomaticScreenshotCleanupScheduledTimer {
        scheduledIntervals.append(interval)
        let timer = ManualAutomaticScreenshotCleanupTimerHandle(handler: handler)
        timers.append(timer)
        return timer
    }

    func fireLatest() {
        timers.last?.fire()
    }
}

@MainActor
private final class ManualAutomaticScreenshotCleanupTimerHandle: AutomaticScreenshotCleanupScheduledTimer {
    private let handler: @MainActor () -> Void
    private(set) var isInvalidated = false

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func invalidate() {
        isInvalidated = true
    }

    func fire() {
        guard !isInvalidated else { return }
        handler()
    }
}

private final class BlockingAutomaticCleanupProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var cleanupCallCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanupCallCount
    }

    func cleanup(fileURLs: [URL]) -> AutomaticScreenshotCleanupResult {
        lock.lock()
        cleanupCallCount += 1
        lock.unlock()

        started.signal()
        release.wait()
        return AutomaticScreenshotCleanupResult(deletedCount: 0, failures: [])
    }
}
