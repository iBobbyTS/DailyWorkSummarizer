import SwiftUI

struct AnalysisErrorsView: View {
    @ObservedObject var errorStore: AnalysisErrorStore
    @ObservedObject var settingsStore: SettingsStore

    private var language: AppLanguage {
        settingsStore.appLanguage
    }

    var body: some View {
        VStack(spacing: 16) {
            if errorStore.entries.isEmpty {
                ContentUnavailableView(
                    text(.errorsEmptyTitle),
                    systemImage: "checkmark.circle",
                    description: Text(text(.errorsEmptyDescription))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(errorStore.entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.timestampFormatter(language: language).string(from: entry.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                errorStore.remove(id: entry.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button(text(.errorsClearAll)) {
                    errorStore.removeAll()
                }
                .disabled(errorStore.entries.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: language)
    }
}
