import Foundation

/// Manages the combined set of disk and memory pending screenshots.
/// Disk screenshots are enumerated from the filesystem each time via ScreenshotFileStore.
/// Memory screenshots are stored in-process and lost on app restart (privacy-preserving).
@MainActor
final class PendingScreenshotStore {
    private let database: AppDatabase

    /// In-memory only pending screenshots (not persisted anywhere)
    private var memoryScreenshots: [PendingScreenshot] = []

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Listing

    /// List ALL pending screenshots — disk from filesystem + memory from in-process store.
    /// Sorted by capture time, with a stable id tie-breaker for deterministic analysis order.
    func listPendingScreenshots(defaultDurationMinutes: Int) throws -> [PendingScreenshot] {
        let diskRecords = try database.listScreenshotFiles(defaultDurationMinutes: defaultDurationMinutes)
        let diskPending = diskRecords.map { PendingScreenshot(disk: $0) }
        return (diskPending + memoryScreenshots).sorted { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Add

    /// Add a memory-backed pending screenshot
    func addMemoryScreenshot(_ screenshot: PendingScreenshot) {
        memoryScreenshots.append(screenshot)
    }

    // MARK: - Remove

    /// Remove a pending screenshot object directly.
    /// For disk: deletes the actual file. For memory: removes from the in-process array.
    func remove(_ screenshot: PendingScreenshot) throws {
        switch screenshot.storageLocation {
        case .disk:
            if let url = screenshot.fileURL, FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        case .memory:
            memoryScreenshots.removeAll { $0.id == screenshot.id }
        }
    }

    /// Remove a pending screenshot by ID.
    /// For memory: removes from the array.
    /// For disk: attempts to locate and delete the file.
    func removePendingScreenshot(id: String) throws {
        // Check memory first
        if let index = memoryScreenshots.firstIndex(where: { $0.id == id }) {
            memoryScreenshots.remove(at: index)
            return
        }

        let diskRecord = try database
            .listScreenshotFiles(defaultDurationMinutes: AppDefaults.screenshotIntervalMinutes)
            .first { $0.id == id }
        guard let fileURL = diskRecord?.url, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Remove all memory screenshots (called on app exit for cleanup)
    func removeAllMemoryScreenshots() {
        memoryScreenshots.removeAll()
    }

    // MARK: - Query

    /// Count of all pending screenshots (disk + memory)
    func pendingCount(defaultDurationMinutes: Int) -> Int {
        (try? listPendingScreenshots(defaultDurationMinutes: defaultDurationMinutes).count) ?? 0
    }
}
