import Foundation

final class ScreenshotFileStore {
    private let applicationSupportDirectoryOverride: URL?

    init(applicationSupportDirectory: URL? = nil) {
        self.applicationSupportDirectoryOverride = applicationSupportDirectory
    }

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "DeskBrief"
        let directory = base.appendingPathComponent(bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func supportDirectory() throws -> URL {
        if let applicationSupportDirectoryOverride {
            return applicationSupportDirectoryOverride
        }
        return try Self.applicationSupportDirectory()
    }

    func screenshotsDirectory() throws -> URL {
        let directory = try supportDirectory().appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func listScreenshotFiles(defaultDurationMinutes: Int) throws -> [ScreenshotFileRecord] {
        let directory = try screenshotsDirectory()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return fileURLs
            .filter { $0.pathExtension.lowercased() == AppDefaults.screenshotFileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { screenshotRecord(for: $0, defaultDurationMinutes: defaultDurationMinutes) }
    }

    private func screenshotRecord(for url: URL, defaultDurationMinutes: Int) -> ScreenshotFileRecord? {
        let baseName = url.deletingPathExtension().lastPathComponent
        guard let capturedAt = parseScreenshotDate(from: baseName) else {
            return nil
        }
        return ScreenshotFileRecord(
            url: url,
            capturedAt: capturedAt,
            durationMinutes: parseScreenshotIntervalMinutes(from: baseName) ?? defaultDurationMinutes
        )
    }

    private func parseScreenshotDate(from baseName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.date(from: String(baseName.prefix(13)))
    }

    private func parseScreenshotIntervalMinutes(from baseName: String) -> Int? {
        guard let markerRange = baseName.range(of: "-i", options: .backwards) else {
            return nil
        }
        let value = baseName[markerRange.upperBound...]
        return Int(value)
    }
}
