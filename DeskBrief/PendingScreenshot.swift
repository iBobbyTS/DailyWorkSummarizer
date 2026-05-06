import Foundation

/// Represents a pending screenshot awaiting analysis, regardless of storage backing (disk or memory).
nonisolated struct PendingScreenshot: Identifiable, Sendable, Hashable {
    /// Stable identifier for deduplication. For disk: filename. For memory: UUID string.
    let id: String

    /// When this screenshot was captured
    let capturedAt: Date

    /// The configured screenshot interval duration in minutes at capture time
    let durationMinutes: Int

    /// Where this screenshot is stored
    let storageLocation: ScreenshotStorageLocation

    /// File URL, only non-nil for disk-backed screenshots
    let fileURL: URL?

    /// In-memory JPEG data, only non-nil for memory-backed screenshots
    let imageData: Data?

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PendingScreenshot, rhs: PendingScreenshot) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Convenience

    /// Display/debug name for logging
    var displayName: String {
        switch storageLocation {
        case .disk: return fileURL?.lastPathComponent ?? id
        case .memory: return "[memory] \(id)"
        }
    }
}

extension PendingScreenshot {
    /// The calculated end time of the screenshot interval
    nonisolated var endAt: Date {
        capturedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    /// Create a pending screenshot from a disk file record
    init(disk record: ScreenshotFileRecord) {
        self.id = record.id
        self.capturedAt = record.capturedAt
        self.durationMinutes = record.durationMinutes
        self.storageLocation = .disk
        self.fileURL = record.url
        self.imageData = nil
    }

    /// Create a pending screenshot from in-memory image data
    init(memory data: Data, capturedAt: Date, durationMinutes: Int) {
        self.id = UUID().uuidString
        self.capturedAt = capturedAt
        self.durationMinutes = durationMinutes
        self.storageLocation = .memory
        self.fileURL = nil
        self.imageData = data
    }
}
