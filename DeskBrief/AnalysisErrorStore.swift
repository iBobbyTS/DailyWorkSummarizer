import Foundation
import Combine

@MainActor
final class AppLogStore: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []

    private let database: AppDatabase
    private let maxEntries: Int

    var count: Int {
        entries.count
    }

    init(database: AppDatabase, maxEntries: Int = AppDefaults.maxLogEntries) {
        self.database = database
        self.maxEntries = maxEntries
        reload()
    }

    func reload() {
        do {
            entries = try database.fetchAppLogs(limit: maxEntries)
        } catch {
            entries = []
        }
        notifyDidChange()
    }

    func add(
        level: AppLogLevel,
        source: AppLogSource,
        message: String,
        createdAt: Date = Date()
    ) {
        let entry = AppLogEntry(
            createdAt: createdAt,
            level: level,
            source: source,
            message: message
        )

        do {
            do {
                try database.insertAppLog(entry, maxEntries: maxEntries)
            } catch {
                try database.insertAppLog(entry, maxEntries: maxEntries)
            }
            entries = try database.fetchAppLogs(limit: maxEntries)
        } catch {
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries = Array(entries.prefix(maxEntries))
            }
        }

        notifyDidChange()
    }

    func addError(source: AppLogSource, context: String, error: Error) {
        let detail = Self.describe(error)
        add(
            level: .error,
            source: source,
            message: detail.isEmpty ? context : "\(context): \(detail)"
        )
    }

    func remove(id: UUID) {
        do {
            try database.deleteAppLog(id: id)
        } catch {
            entries.removeAll { $0.id == id }
            notifyDidChange()
            return
        }

        entries.removeAll { $0.id == id }
        notifyDidChange()
    }

    func removeAll() {
        do {
            try database.deleteAllAppLogs()
        } catch {
            entries.removeAll()
            notifyDidChange()
            return
        }

        entries.removeAll()
        notifyDidChange()
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .appLogsDidChange, object: nil)
    }

    private static func describe(_ error: Error) -> String {
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return described
        }
        return error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
