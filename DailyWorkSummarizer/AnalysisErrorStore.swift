import Foundation
import Combine

@MainActor
final class AnalysisErrorStore: ObservableObject {
    @Published private(set) var entries: [AnalysisErrorEntry] = []

    var count: Int {
        entries.count
    }

    func add(_ message: String) {
        entries.insert(AnalysisErrorEntry(message: message), at: 0)
        notifyDidChange()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        notifyDidChange()
    }

    func removeAll() {
        entries.removeAll()
        notifyDidChange()
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .analysisErrorsDidChange, object: nil)
    }
}
