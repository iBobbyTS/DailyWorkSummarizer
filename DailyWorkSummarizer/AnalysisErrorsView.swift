import SwiftUI

struct AnalysisErrorsView: View {
    @ObservedObject var errorStore: AnalysisErrorStore

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.M.d HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 16) {
            if errorStore.entries.isEmpty {
                ContentUnavailableView(
                    "当前没有错误",
                    systemImage: "checkmark.circle",
                    description: Text("后续分析出错时，会在这里显示最新的大模型返回错误。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(errorStore.entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.timestampFormatter.string(from: entry.createdAt))
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
                Button("清空所有错误") {
                    errorStore.removeAll()
                }
                .disabled(errorStore.entries.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }
}
