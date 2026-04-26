import AppKit
import CoreGraphics
import Foundation

@MainActor
final class ScreenshotService {
    struct PreviewCaptureResult {
        let image: NSImage
        let fileURL: URL
    }

    private let database: AppDatabase
    private let settingsStore: SettingsStore
    private let userDefaults: UserDefaults
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private(set) var nextCaptureDate: Date?

    init(database: AppDatabase, settingsStore: SettingsStore, userDefaults: UserDefaults = .standard) {
        self.database = database
        self.settingsStore = settingsStore
        self.userDefaults = userDefaults
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

    func capturePreview() throws -> PreviewCaptureResult {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
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

        try capturePreferredSingleDisplayJPEG(to: finalURL)
        guard let image = NSImage(contentsOf: finalURL) else {
            throw NSError(
                domain: "ScreenshotService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: text(.screenshotPreviewUnreadable)]
            )
        }
        return PreviewCaptureResult(image: image, fileURL: finalURL)
    }

    func openScreenshotsFolder() {
        guard let screenshotsURL = try? database.screenshotsDirectory() else { return }
        NSWorkspace.shared.open(screenshotsURL)
    }

    func captureTemporaryMainDisplay() throws -> URL {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NSError(
                domain: "ScreenshotService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: text(.screenshotPermissionDenied)]
            )
        }

        let tempDirectory = try database.screenshotsDirectory().appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let fileURL = tempDirectory.appendingPathComponent(fileName(for: Date(), suffix: "-model-test"))
        try capturePreferredSingleDisplayJPEG(to: fileURL)
        return fileURL
    }

    private func scheduleTimer(captureImmediately: Bool) {
        timer?.invalidate()

        let snapshot = settingsStore.snapshot
        if captureImmediately {
            performCapture(scheduledAt: Date(), settings: snapshot)
        }

        let seconds = TimeInterval(snapshot.screenshotIntervalMinutes * 60)
        nextCaptureDate = Date().addingTimeInterval(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.performCapture(scheduledAt: Date(), settings: self.settingsStore.snapshot)
                self.nextCaptureDate = Date().addingTimeInterval(seconds)
                NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func performCapture(scheduledAt: Date, settings: AppSettingsSnapshot) {
        let currentMouseLocation = mouseLocation()
        let currentFrontmostAppIdentifier = frontmostAppIdentifier()

        if Self.shouldSkipCapture(
            currentMouseLocation: currentMouseLocation,
            lastMouseLocation: lastMouseLocation(),
            currentFrontmostAppIdentifier: currentFrontmostAppIdentifier,
            lastFrontmostAppIdentifier: lastFrontmostAppIdentifier()
        ) {
            return
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return
        }

        do {
            let directory = try database.screenshotsDirectory()
            let fileURL = directory.appendingPathComponent(
                fileName(for: scheduledAt, intervalMinutes: settings.screenshotIntervalMinutes)
            )
            try capturePreferredSingleDisplayJPEG(to: fileURL)
            if let currentMouseLocation {
                saveLastMouseLocation(currentMouseLocation)
            }
            if let currentFrontmostAppIdentifier {
                saveLastFrontmostAppIdentifier(currentFrontmostAppIdentifier)
            }
            NotificationCenter.default.post(name: .screenshotFilesDidChange, object: nil)
        } catch {
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

    private func capturePreferredSingleDisplayJPEG(to destinationURL: URL) throws {
        if let displayIndex = preferredDisplayIndex() {
            try runScreenCapture(arguments: ["-x", "-D", "\(displayIndex)", "-t", "jpg", destinationURL.path])
            return
        }

        try runScreenCapture(arguments: ["-x", "-m", "-t", "jpg", destinationURL.path])
    }

    private func preferredDisplayIndex() -> Int? {
        let screenIndexByDisplayID = activeDisplayIndicesByDisplayID()
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windowRect = frontmostWindowRect(for: frontmostPID) {
            let screenMatches = NSScreen.screens.compactMap { screen -> (Int, CGFloat)? in
                guard let displayID = displayID(for: screen),
                      let displayIndex = screenIndexByDisplayID[displayID] else {
                    return nil
                }

                let overlap = screen.frame.intersection(windowRect)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return area > 0 ? (displayIndex, area) : nil
            }

            if let bestMatch = screenMatches.max(by: { $0.1 < $1.1 }) {
                return bestMatch.0
            }

            let windowCenter = CGPoint(x: windowRect.midX, y: windowRect.midY)
            for screen in NSScreen.screens {
                guard screen.frame.contains(windowCenter),
                      let displayID = displayID(for: screen),
                      let displayIndex = screenIndexByDisplayID[displayID] else {
                    continue
                }
                return displayIndex
            }
        }

        return mouseDisplayIndex(screenIndexByDisplayID: screenIndexByDisplayID)
    }

    private func mouseDisplayIndex(screenIndexByDisplayID: [CGDirectDisplayID: Int]) -> Int? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard screen.frame.contains(mouseLocation),
                  let displayID = displayID(for: screen),
                  let displayIndex = screenIndexByDisplayID[displayID] else {
                continue
            }
            return displayIndex
        }
        return nil
    }

    private func frontmostWindowRect(for processID: pid_t) -> CGRect? {
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

    private func activeDisplayIndicesByDisplayID() -> [CGDirectDisplayID: Int] {
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

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func runScreenCapture(arguments: [String]) throws {
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
                    NSLocalizedDescriptionKey: errorText.isEmpty ? text(.screenshotCommandFailed) : errorText
                ]
            )
        }
    }

    private func mouseLocation() -> CGPoint? {
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

    private func frontmostAppIdentifier() -> String? {
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
