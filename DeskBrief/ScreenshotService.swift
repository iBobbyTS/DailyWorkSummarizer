import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated struct ScreenshotCaptureTarget: Equatable {
    let displayIndex: Int?
    let frame: CGRect?
}

@MainActor
struct ScreenshotCaptureRuntime {
    var hasScreenCaptureAccess: () -> Bool
    var mouseLocation: () -> CGPoint?
    var frontmostAppIdentifier: () -> String?
    var preferredCaptureTarget: () -> ScreenshotCaptureTarget
    var runScreenCapture: (_ arguments: [String]) async throws -> Void
    var captureDisplayImage: (_ rect: CGRect) async throws -> CGImage
}

@MainActor
final class ScreenshotService {
    struct ScreenshotPreviewResult {
        let image: NSImage
        let fileURL: URL
    }

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let logStore: AppLogStore?
    private let userDefaults: UserDefaults
    private let captureRuntime: ScreenshotCaptureRuntime
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var didLogCapturePermissionDenied = false
    private(set) var nextScreenshotDate: Date?

    init(
        database: AppDatabase,
        settingsStore: SettingsStore,
        logStore: AppLogStore? = nil,
        userDefaults: UserDefaults = .standard,
        captureRuntime: ScreenshotCaptureRuntime? = nil
    ) {
        self.database = database
        self.settingsStore = settingsStore
        self.logStore = logStore
        self.userDefaults = userDefaults
        self.captureRuntime = captureRuntime ?? ScreenshotCaptureRuntime.liveCaptureRuntime(settingsStore: settingsStore)
        removeLeftoverTemporaryScreenshots()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        scheduleTimer(captureImmediately: false)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTimer(captureImmediately: false)
            }
        }
    }

    func reschedule() {
        scheduleTimer(captureImmediately: false)
    }

    func captureScheduledScreenshotForTesting(scheduledAt: Date, settings: AppSettingsSnapshot) async {
        await performCapture(scheduledAt: scheduledAt, settings: settings)
    }

    func capturePreview() async throws -> ScreenshotPreviewResult {
        guard captureRuntime.hasScreenCaptureAccess() else {
            throw NSError(
                domain: "ScreenshotService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: text(.screenshotPermissionDenied)]
            )
        }

        let previewDirectory = try database.screenshotsDirectory().appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)

        let previewID = fileName(for: Date(), suffix: "-preview").replacingOccurrences(of: ".\(AppDefaults.screenshotFileExtension)", with: "")
        let finalURL = previewDirectory.appendingPathComponent("\(previewID).\(AppDefaults.screenshotFileExtension)")

        try await capturePreferredSingleDisplayJPEG(to: finalURL)
        guard let image = NSImage(contentsOf: finalURL) else {
            throw NSError(
                domain: "ScreenshotService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: text(.screenshotPreviewUnreadable)]
            )
        }
        return ScreenshotPreviewResult(image: image, fileURL: finalURL)
    }

    func openScreenshotsFolder() {
        do {
            let screenshotsURL = try database.screenshotsDirectory()
            NSWorkspace.shared.open(screenshotsURL)
        } catch {
            logStore?.addError(source: .screenshot, context: "Failed to open screenshots folder", error: error)
        }
    }

    func captureTemporaryMainDisplay() async throws -> URL {
        guard captureRuntime.hasScreenCaptureAccess() else {
            throw NSError(
                domain: "ScreenshotService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: text(.screenshotPermissionDenied)]
            )
        }

        let tempDirectory = try database.screenshotsDirectory().appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let fileURL = tempDirectory.appendingPathComponent(fileName(for: Date(), suffix: "-model-test"))
        try await capturePreferredSingleDisplayJPEG(to: fileURL)
        return fileURL
    }

    private func removeLeftoverTemporaryScreenshots() {
        do {
            let tempDirectory = try database.screenshotsDirectory().appendingPathComponent("temp", isDirectory: true)
            guard FileManager.default.fileExists(atPath: tempDirectory.path) else {
                return
            }
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: tempDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for fileURL in fileURLs {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            logStore?.addError(source: .screenshot, context: "Failed to clean up leftover model test screenshots", error: error)
        }
    }

    private func scheduleTimer(captureImmediately: Bool) {
        timer?.invalidate()

        let snapshot = settingsStore.snapshot
        if captureImmediately {
            Task { @MainActor [weak self] in
                await self?.performCapture(scheduledAt: Date(), settings: snapshot)
            }
        }

        let seconds = TimeInterval(snapshot.screenshotIntervalMinutes * 60)
        nextScreenshotDate = Date().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performCapture(scheduledAt: Date(), settings: self.settingsStore.snapshot)
                self.nextScreenshotDate = Date().addingTimeInterval(seconds)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func performCapture(scheduledAt: Date, settings: AppSettingsSnapshot) async {
        let currentMouseLocation = captureRuntime.mouseLocation()
        let currentFrontmostAppIdentifier = captureRuntime.frontmostAppIdentifier()

        if Self.shouldSkipCapture(
            currentMouseLocation: currentMouseLocation,
            lastMouseLocation: lastMouseLocation(),
            currentFrontmostAppIdentifier: currentFrontmostAppIdentifier,
            lastFrontmostAppIdentifier: lastFrontmostAppIdentifier()
        ) {
            return
        }

        guard captureRuntime.hasScreenCaptureAccess() else {
            recordCapturePermissionDeniedIfNeeded()
            return
        }

        do {
            switch settings.screenshotStorageLocation {
            case .disk:
                let directory = try database.screenshotsDirectory()
                let fileURL = directory.appendingPathComponent(
                    fileName(for: scheduledAt, intervalMinutes: settings.screenshotIntervalMinutes)
                )
                try await capturePreferredSingleDisplayJPEG(to: fileURL)
                if let currentMouseLocation {
                    saveLastMouseLocation(currentMouseLocation)
                }
                if let currentFrontmostAppIdentifier {
                    saveLastFrontmostAppIdentifier(currentFrontmostAppIdentifier)
                }
                NotificationCenter.default.post(name: .screenshotFileSaved, object: fileURL)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)

            case .memory:
                let jpegData = try await capturePreferredSingleDisplayJPEGData()
                let pending = PendingScreenshot(
                    memory: jpegData,
                    capturedAt: scheduledAt,
                    durationMinutes: settings.screenshotIntervalMinutes
                )
                database.pendingScreenshotStore.addMemoryScreenshot(pending)
                if let currentMouseLocation {
                    saveLastMouseLocation(currentMouseLocation)
                }
                if let currentFrontmostAppIdentifier {
                    saveLastFrontmostAppIdentifier(currentFrontmostAppIdentifier)
                }
                NotificationCenter.default.post(name: .screenshotFileSaved, object: pending)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            }
        } catch {
            logStore?.addError(source: .screenshot, context: "Failed to capture scheduled screenshot", error: error)
            return
        }
    }

    nonisolated static func shouldSkipCapture(
        currentMouseLocation: CGPoint?,
        lastMouseLocation: CGPoint?,
        currentFrontmostAppIdentifier: String?,
        lastFrontmostAppIdentifier: String?
    ) -> Bool {
        guard let currentMouseLocation,
              let lastMouseLocation,
              currentMouseLocation == lastMouseLocation,
              let currentFrontmostAppIdentifier,
              let lastFrontmostAppIdentifier else {
            return false
        }

        return currentFrontmostAppIdentifier == lastFrontmostAppIdentifier
    }

    private func fileName(for date: Date, intervalMinutes: Int? = nil, suffix: String = "") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let intervalComponent = intervalMinutes.map { "-i\($0)" } ?? ""
        return formatter.string(from: date) + intervalComponent + suffix + ".\(AppDefaults.screenshotFileExtension)"
    }

    private func capturePreferredSingleDisplayJPEG(to destinationURL: URL) async throws {
        let target = captureRuntime.preferredCaptureTarget()
        if let displayIndex = target.displayIndex {
            try await captureRuntime.runScreenCapture(["-x", "-D", "\(displayIndex)", "-t", "jpg", destinationURL.path])
            return
        }

        try await captureRuntime.runScreenCapture(["-x", "-m", "-t", "jpg", destinationURL.path])
    }

    /// Captures the preferred display directly to in-memory JPEG data.
    private func capturePreferredSingleDisplayJPEGData() async throws -> Data {
        guard let rect = captureRuntime.preferredCaptureTarget().frame else {
            throw NSError(
                domain: "ScreenshotService",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve display for capture"]
            )
        }
        let image = try await captureRuntime.captureDisplayImage(rect)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [:]) else {
            throw NSError(
                domain: "ScreenshotService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode display image as JPEG"]
            )
        }
        return data
    }

    fileprivate static func captureDisplayImage(in rect: CGRect) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: NSError(
                        domain: "ScreenshotService",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit returned no image"]
                    ))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func recordCapturePermissionDeniedIfNeeded() {
        guard !didLogCapturePermissionDenied else {
            return
        }
        didLogCapturePermissionDenied = true
        logStore?.add(
            level: .error,
            source: .screenshot,
            message: text(.screenshotPermissionDenied)
        )
    }

    fileprivate static func preferredCaptureTarget() -> ScreenshotCaptureTarget {
        guard let screen = preferredScreen() else {
            return ScreenshotCaptureTarget(displayIndex: nil, frame: NSScreen.main?.frame)
        }
        let displayIndex = displayID(for: screen).flatMap { activeDisplayIndicesByDisplayID()[$0] }
        return ScreenshotCaptureTarget(displayIndex: displayIndex, frame: screen.frame)
    }

    private static func preferredScreen() -> NSScreen? {
        let screenIndexByDisplayID = activeDisplayIndicesByDisplayID()
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windowRect = frontmostWindowRect(for: frontmostPID) {
            let screenMatches = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
                guard let displayID = displayID(for: screen),
                      screenIndexByDisplayID[displayID] != nil else {
                    return nil
                }

                let overlap = screen.frame.intersection(windowRect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return area > 0 ? (screen, area) : nil
            }

            if let bestMatch = screenMatches.max(by: { $0.1 < $1.1 }) {
                return bestMatch.0
            }

            let windowCenter = CGPoint(x: windowRect.midX, y: windowRect.midY)
            for screen in NSScreen.screens {
                guard screen.frame.contains(windowCenter),
                      let displayID = displayID(for: screen),
                      screenIndexByDisplayID[displayID] != nil else {
                    continue
                }
                return screen
            }
        }

        return mouseScreen(screenIndexByDisplayID: screenIndexByDisplayID)
    }

    private static func mouseScreen(screenIndexByDisplayID: [CGDirectDisplayID: Int]) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard screen.frame.contains(mouseLocation),
                  let displayID = displayID(for: screen),
                  screenIndexByDisplayID[displayID] != nil else {
                continue
            }
            return screen
        }
        return nil
    }

    private static func frontmostWindowRect(for processID: pid_t) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowInfo {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processID,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 0,
                  rect.height > 0 else {
                continue
            }

            return rect
        }

        return nil
    }

    private static func activeDisplayIndicesByDisplayID() -> [CGDirectDisplayID: Int] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return [:]
        }

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: displayIDs.enumerated().map { (offset, displayID) in
            (displayID, offset + 1)
        })
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    nonisolated fileprivate static func runScreenCapture(arguments: [String], commandFailedMessage: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "ScreenshotService",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorText.isEmpty ? commandFailedMessage : errorText
                ]
            )
        }
    }

    fileprivate static func mouseLocation() -> CGPoint? {
        if let eventLocation = CGEvent(source: nil)?.location {
            return eventLocation
        }
        return nil
    }

    private func lastMouseLocation() -> CGPoint? {
        guard userDefaults.bool(forKey: Keys.hasLastMouseLocation) else {
            return nil
        }

        return CGPoint(
            x: userDefaults.double(forKey: Keys.lastMouseX),
            y: userDefaults.double(forKey: Keys.lastMouseY)
        )
    }

    private func saveLastMouseLocation(_ location: CGPoint) {
        userDefaults.set(true, forKey: Keys.hasLastMouseLocation)
        userDefaults.set(location.x, forKey: Keys.lastMouseX)
        userDefaults.set(location.y, forKey: Keys.lastMouseY)
    }

    fileprivate static func frontmostAppIdentifier() -> String? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let localizedName = application.localizedName, !localizedName.isEmpty {
            return localizedName
        }

        return "\(application.processIdentifier)"
    }

    private func lastFrontmostAppIdentifier() -> String? {
        userDefaults.string(forKey: Keys.lastFrontmostAppIdentifier)
    }

    private func saveLastFrontmostAppIdentifier(_ identifier: String) {
        userDefaults.set(identifier, forKey: Keys.lastFrontmostAppIdentifier)
    }

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: settingsStore.appLanguage)
    }

    private enum Keys {
        static let hasLastMouseLocation = "screenshot.lastMouseLocation.exists"
        static let lastMouseX = "screenshot.lastMouseLocation.x"
        static let lastMouseY = "screenshot.lastMouseLocation.y"
        static let lastFrontmostAppIdentifier = "screenshot.lastFrontmostAppIdentifier"
    }
}

extension ScreenshotCaptureRuntime {
    fileprivate static func liveCaptureRuntime(settingsStore: SettingsStore) -> ScreenshotCaptureRuntime {
        ScreenshotCaptureRuntime(
            hasScreenCaptureAccess: {
                CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            },
            mouseLocation: {
                ScreenshotService.mouseLocation()
            },
            frontmostAppIdentifier: {
                ScreenshotService.frontmostAppIdentifier()
            },
            preferredCaptureTarget: {
                ScreenshotService.preferredCaptureTarget()
            },
            runScreenCapture: { arguments in
                let commandFailedMessage = await MainActor.run {
                    L10n.string(.screenshotCommandFailed, language: settingsStore.appLanguage)
                }
                try await Task.detached {
                    try ScreenshotService.runScreenCapture(
                        arguments: arguments,
                        commandFailedMessage: commandFailedMessage
                    )
                }.value
            },
            captureDisplayImage: { rect in
                try await ScreenshotService.captureDisplayImage(in: rect)
            }
        )
    }
}
