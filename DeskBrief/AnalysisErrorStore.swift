import Foundation
import Combine

protocol AppLogPersisting: AnyObject {
    func fetchAppLogs(limit: Int?) throws -> [AppLogEntry]
    func insertAppLog(_ entry: AppLogEntry, maxEntries: Int) throws
    func deleteAppLog(id: UUID) throws
    func deleteAllAppLogs() throws
}

extension AppDatabase: AppLogPersisting {}

@MainActor
final class AppLogStore: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []
    @Published private(set) var persistenceErrorMessage: String?

    private let database: AppLogPersisting
    private let maxEntries: Int

    var count: Int {
        entries.count
    }

    convenience init(database: AppDatabase, maxEntries: Int = AppDefaults.maxLogEntries) {
        self.init(persistence: database, maxEntries: maxEntries)
    }

    init(persistence: AppLogPersisting, maxEntries: Int = AppDefaults.maxLogEntries) {
        self.database = persistence
        self.maxEntries = maxEntries
        reload()
    }

    func reload() {
        do {
            entries = try database.fetchAppLogs(limit: maxEntries)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = Self.describe(error)
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
            persistenceErrorMessage = nil
        } catch {
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries = Array(entries.prefix(maxEntries))
            }
            persistenceErrorMessage = Self.describe(error)
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
            persistenceErrorMessage = Self.describe(error)
            notifyDidChange()
            return
        }

        entries.removeAll { $0.id == id }
        persistenceErrorMessage = nil
        notifyDidChange()
    }

    func removeAll() {
        do {
            try database.deleteAllAppLogs()
        } catch {
            persistenceErrorMessage = Self.describe(error)
            notifyDidChange()
            return
        }

        entries.removeAll()
        persistenceErrorMessage = nil
        notifyDidChange()
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .appLogsDidChange, object: nil)
    }

    private static func describe(_ error: Error) -> String {
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return CredentialSanitizer.sanitize(described)
        }
        return CredentialSanitizer.sanitize(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
