import Foundation

enum EarlyScreenshotCleanupScope: Int, CaseIterable, Sendable {
    case oneDay = 1
    case oneWeek = 7

    nonisolated
    var age: TimeInterval {
        TimeInterval(rawValue) * 24 * 60 * 60
    }
}

struct EarlyScreenshotCleanupResult: Sendable, Equatable {
    let calculatedAt: Date
    let filesByScope: [EarlyScreenshotCleanupScope: [PendingScreenshot]]

    nonisolated
    func files(for scope: EarlyScreenshotCleanupScope) -> [PendingScreenshot] {
        filesByScope[scope] ?? []
    }

    nonisolated
    func isValid(now: Date, cacheDuration: TimeInterval) -> Bool {
        now.timeIntervalSince(calculatedAt) <= cacheDuration
    }
}

enum EarlyScreenshotCleanupStatus: Sendable, Equatable {
    case calculating
    case ready(EarlyScreenshotCleanupResult)
    case failed(String)
}

enum EarlyScreenshotCleanupMenuItemState: Sendable, Equatable {
    case calculating
    case ready(count: Int)
    case failed
}

struct EarlyScreenshotCleanupMenuItemPresentation: Sendable, Equatable {
    let title: String
    let isEnabled: Bool
}

struct EarlyScreenshotCleanupDeletionError: Error, Equatable {
    let failures: [String]
}

actor EarlyScreenshotCleanupCoordinator {
    typealias ScanOperation = @Sendable () async throws -> EarlyScreenshotCleanupResult

    private let cacheDuration: TimeInterval
    private var cachedResult: EarlyScreenshotCleanupResult?
    private var calculationTask: Task<EarlyScreenshotCleanupResult, Error>?
    private var calculationStartCount = 0

    init(cacheDuration: TimeInterval = 60) {
        self.cacheDuration = cacheDuration
    }

    func beginCalculationIfNeeded(
        database: AppDatabase,
        defaultDurationMinutes: Int,
        now: Date = Date()
    ) -> EarlyScreenshotCleanupStatus {
        beginCalculationIfNeeded(now: now) {
            try await Self.scan(database: database, defaultDurationMinutes: defaultDurationMinutes, now: now)
        }
    }

    func beginCalculationIfNeeded(
        now: Date = Date(),
        scan: @escaping ScanOperation
    ) -> EarlyScreenshotCleanupStatus {
        if let cachedResult, cachedResult.isValid(now: now, cacheDuration: cacheDuration) {
            return .ready(cachedResult)
        }
        if calculationTask != nil {
            return .calculating
        }

        cachedResult = nil
        calculationStartCount += 1
        calculationTask = Task.detached(priority: .utility) {
            try await scan()
        }
        return .calculating
    }

    func waitForCalculation() async -> EarlyScreenshotCleanupStatus {
        guard let calculationTask else {
            if let cachedResult, cachedResult.isValid(now: Date(), cacheDuration: cacheDuration) {
                return .ready(cachedResult)
            }
            return .calculating
        }

        do {
            let result = try await calculationTask.value
            cachedResult = result
            self.calculationTask = nil
            return .ready(result)
        } catch {
            self.calculationTask = nil
            return .failed(Self.describe(error))
        }
    }

    func currentStatus(now: Date = Date()) -> EarlyScreenshotCleanupStatus {
        if let cachedResult, cachedResult.isValid(now: now, cacheDuration: cacheDuration) {
            return .ready(cachedResult)
        }
        if calculationTask != nil {
            return .calculating
        }
        return .calculating
    }

    func cachedFiles(for scope: EarlyScreenshotCleanupScope, now: Date = Date()) -> [PendingScreenshot]? {
        guard let cachedResult, cachedResult.isValid(now: now, cacheDuration: cacheDuration) else {
            return nil
        }
        return cachedResult.files(for: scope)
    }

    func invalidateCache() {
        cachedResult = nil
    }

    func calculationStartCountForTesting() -> Int {
        calculationStartCount
    }

    nonisolated static func menuItemState(
        for status: EarlyScreenshotCleanupStatus,
        scope: EarlyScreenshotCleanupScope
    ) -> EarlyScreenshotCleanupMenuItemState {
        switch status {
        case .calculating:
            return .calculating
        case .failed(_):
            return .failed
        case let .ready(result):
            return .ready(count: result.files(for: scope).count)
        }
    }

    nonisolated static func presentation(
        scope: EarlyScreenshotCleanupScope,
        state: EarlyScreenshotCleanupMenuItemState,
        language: AppLanguage
    ) -> EarlyScreenshotCleanupMenuItemPresentation {
        let scopeTitle = title(for: scope, language: language)
        switch state {
        case .calculating:
            return EarlyScreenshotCleanupMenuItemPresentation(
                title: L10n.string(.menuClearEarlyScreenshotsCalculating, language: language, arguments: [scopeTitle]),
                isEnabled: false
            )
        case .failed:
            return EarlyScreenshotCleanupMenuItemPresentation(
                title: L10n.string(.menuClearEarlyScreenshotsFailed, language: language, arguments: [scopeTitle]),
                isEnabled: false
            )
        case let .ready(count):
            if count == 0 {
                return EarlyScreenshotCleanupMenuItemPresentation(
                    title: L10n.string(.menuClearEarlyScreenshotsEmpty, language: language, arguments: [scopeTitle]),
                    isEnabled: false
                )
            }
            let key: L10n.Key
            if language == .english, count == 1 {
                key = .menuClearEarlyScreenshotsCountSingular
            } else {
                key = .menuClearEarlyScreenshotsCount
            }
            return EarlyScreenshotCleanupMenuItemPresentation(
                title: L10n.string(key, language: language, arguments: [scopeTitle, count]),
                isEnabled: true
            )
        }
    }

    nonisolated static func title(for scope: EarlyScreenshotCleanupScope, language: AppLanguage) -> String {
        switch scope {
        case .oneDay:
            return L10n.string(.menuClearEarlyScreenshotsOneDay, language: language)
        case .oneWeek:
            return L10n.string(.menuClearEarlyScreenshotsOneWeek, language: language)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let deletionError = error as? EarlyScreenshotCleanupDeletionError {
            return deletionError.failures.joined(separator: "; ")
        }

        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return described
        }
        return error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func scan(
        database: AppDatabase,
        defaultDurationMinutes: Int,
        now: Date
    ) async throws -> EarlyScreenshotCleanupResult {
        let screenshots = try await database.pendingScreenshotStore.listPendingScreenshots(defaultDurationMinutes: defaultDurationMinutes)
        return calculate(screenshots: screenshots, now: now)
    }

    nonisolated static func calculate(
        screenshots: [PendingScreenshot],
        now: Date
    ) -> EarlyScreenshotCleanupResult {
        var filesByScope: [EarlyScreenshotCleanupScope: [PendingScreenshot]] = [:]
        for scope in EarlyScreenshotCleanupScope.allCases {
            let cutoff = now.addingTimeInterval(-scope.age)
            filesByScope[scope] = screenshots
                .filter { $0.capturedAt < cutoff }
        }
        return EarlyScreenshotCleanupResult(calculatedAt: now, filesByScope: filesByScope)
    }

    @discardableResult
    nonisolated static func deleteFiles(_ screenshots: [PendingScreenshot]) throws -> Int {
        var deletedCount = 0
        var failures: [String] = []

        for screenshot in screenshots {
            switch screenshot.storageLocation {
            case .disk:
                guard let fileURL = screenshot.fileURL else {
                    failures.append("\(screenshot.displayName): missing file URL for disk screenshot")
                    continue
                }
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                } catch {
                    failures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            case .memory:
                // Memory screenshots must be removed via PendingScreenshotStore.remove()
                // which requires MainActor context. Skip here; caller handles separately.
                continue
            }
        }

        if !failures.isEmpty {
            throw EarlyScreenshotCleanupDeletionError(failures: failures)
        }
        return deletedCount
    }
}
