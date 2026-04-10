import SwiftUI

struct AppLogsView: View {
    @ObservedObject var logStore: AppLogStore
    @ObservedObject var settingsStore: SettingsStore
    @State private var selectedFilter: AppLogFilter = .all

    private var language: AppLanguage {
        settingsStore.appLanguage
    }

    private var filteredEntries: [AppLogEntry] {
        logStore.entries.filter { selectedFilter.includes(level: $0.level) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedFilter) {
                ForEach(AppLogFilter.allCases) { filter in
                    Text(filter.title(in: language)).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    text(.logsEmptyTitle),
                    systemImage: "text.page",
                    description: Text(text(.logsEmptyDescription))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(L10n.timestampFormatter(language: language).string(from: entry.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(entry.level.title(in: language))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(levelBackgroundColor(for: entry.level))
                                        .foregroundStyle(levelForegroundColor(for: entry.level))
                                        .clipShape(Capsule())
                                }

                                Text(entry.message)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                logStore.remove(id: entry.id)
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
                Button(text(.logsClearAll)) {
                    logStore.removeAll()
                }
                .disabled(logStore.entries.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    private func levelBackgroundColor(for level: AppLogLevel) -> Color {
        switch level {
        case .error:
            return Color.red.opacity(0.15)
        case .log:
            return Color.accentColor.opacity(0.15)
        }
    }

    private func levelForegroundColor(for level: AppLogLevel) -> Color {
        switch level {
        case .error:
            return .red
        case .log:
            return .accentColor
        }
    }

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: language)
    }
}
