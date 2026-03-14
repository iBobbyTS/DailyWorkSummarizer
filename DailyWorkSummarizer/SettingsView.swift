import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    let screenshotService: ScreenshotService
    let analysisService: AnalysisService

    @State private var previewImage: NSImage?
    @State private var previewFileURL: URL?
    @State private var previewError: String?
    @State private var previewCountdownText: String?
    @State private var isCapturingPreview = false
    @State private var modelTestResult: String?
    @State private var modelTestError: String?
    @State private var isTestingModel = false

    private var analysisTimeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                let calendar = Calendar.reportCalendar
                let startOfToday = calendar.startOfDay(for: Date())
                return calendar.date(byAdding: .minute, value: settingsStore.analysisTimeMinutes, to: startOfToday) ?? Date()
            },
            set: { newDate in
                let components = Calendar.reportCalendar.dateComponents([.hour, .minute], from: newDate)
                let hours = components.hour ?? 0
                let minutes = components.minute ?? 0
                settingsStore.analysisTimeMinutes = hours * 60 + minutes
            }
        )
    }

    var body: some View {
        TabView {
            captureTab
                .tabItem { Text("截屏") }

            modelTab
                .tabItem { Text("模型") }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 560)
        .onDisappear {
            removePreviewFile()
        }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("截屏设置")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Text("截图间隔")
                    .font(.headline)

                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { Double(settingsStore.screenshotIntervalMinutes) },
                            set: { settingsStore.screenshotIntervalMinutes = Int($0.rounded()) }
                        ),
                        in: 1...60,
                        step: 1
                    )

                    TextField(
                        "分钟",
                        value: Binding(
                            get: { settingsStore.screenshotIntervalMinutes },
                            set: { settingsStore.screenshotIntervalMinutes = $0 }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                    Text("分钟")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("截屏范围")
                    .font(.headline)

                Text("截取当前活跃的屏幕")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("分析启动时间")
                    .font(.headline)

                DatePicker(
                    "每天开始分析",
                    selection: analysisTimeBinding,
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.field)

                Text("建议使用 18:30。本项目会在下一个分析时间点处理尚未分析的截图，不会在启动应用时自动补跑。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        capturePreview()
                    } label: {
                        if isCapturingPreview {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在测试截屏…")
                        } else {
                            Label("测试截屏", systemImage: "camera")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturingPreview)

                    Button {
                        openAppLocation()
                    } label: {
                        Label("打开 App 位置", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openScreenshotsFolder()
                    } label: {
                        Label("打开截屏文件夹", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }

                if let previewImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("测试结果")
                            .font(.headline)

                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                }

                if let previewCountdownText {
                    Text(previewCountdownText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let previewError {
                    Text(previewError)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
    }

    private var modelTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("模型设置")
                    .font(.title2.weight(.semibold))

                Picker("模型服务", selection: $settingsStore.provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                VStack(alignment: .leading, spacing: 8) {
                    Text("接口地址")
                        .font(.headline)
                    TextField(settingsStore.provider == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:8000", text: $settingsStore.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                    if settingsStore.provider != .lmStudio {
                        Text("官方 API 未经过测试")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("模型名称")
                        .font(.headline)
                    TextField("请输入模型名称", text: $settingsStore.modelName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.headline)
                    SecureField("请输入 API Key（可留空）", text: $settingsStore.apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                if settingsStore.provider == .lmStudio {
                    VStack(alignment: .leading, spacing: 8) {
                    Toggle("继承 previous response", isOn: $settingsStore.inheritPreviousResponse)
                    }
                }

                if settingsStore.provider == .lmStudio {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context Length")
                            .font(.headline)

                        TextField(
                            "4096 - 65536",
                            value: Binding(
                                get: { settingsStore.lmStudioContextLength },
                                set: { settingsStore.lmStudioContextLength = $0 }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)

                        Text("如果分类较多，建议更长的上下文。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("分析分类")
                        .font(.headline)
                    Text("下面是用于模型分析的分类，请输入你期望的类别和简介的描述，方便大模型进行分类。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    HStack {
                        Text("类别名")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("描述")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(width: 36)
                    }
                    .font(.headline)

                    ForEach(settingsStore.categoryRules) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            TextField(
                                "例如：专注工作",
                                text: Binding(
                                    get: {
                                        settingsStore.categoryRules.first(where: { $0.id == rule.id })?.name ?? ""
                                    },
                                    set: { settingsStore.updateCategoryRuleName(id: rule.id, name: $0) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

                            TextField(
                                "例如：正在编码、查资料或写文档",
                                text: Binding(
                                    get: {
                                        settingsStore.categoryRules.first(where: { $0.id == rule.id })?.description ?? ""
                                    },
                                    set: { settingsStore.updateCategoryRuleDescription(id: rule.id, description: $0) }
                                ),
                                axis: .vertical
                            )
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)

                            Button {
                                settingsStore.removeCategoryRule(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Button {
                    settingsStore.addCategoryRule()
                } label: {
                    Label("添加分类", systemImage: "plus")
                }

                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        testModel()
                    } label: {
                        if isTestingModel {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在测试模型…")
                        } else {
                            Label("测试模型", systemImage: "bolt.horizontal")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTestingModel)

                    if let modelTestResult {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("测试分类结果")
                                .font(.headline)
                            Text(modelTestResult)
                        }
                    }

                    if let modelTestError {
                        Text(modelTestError)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capturePreview() {
        previewError = nil
        previewCountdownText = nil
        isCapturingPreview = true

        Task { @MainActor in
            defer {
                previewCountdownText = nil
                isCapturingPreview = false
            }

            do {
                removePreviewFile()

                let validationResult = try screenshotService.capturePreview()
                try? FileManager.default.removeItem(at: validationResult.fileURL)

                for remainingSeconds in stride(from: 3, through: 1, by: -1) {
                    previewCountdownText = "倒计时：\(remainingSeconds)秒"
                    try await Task.sleep(for: .seconds(1))
                }

                let result = try screenshotService.capturePreview()
                previewFileURL = result.fileURL
                previewImage = result.image
                previewError = nil
            } catch {
                previewImage = nil
                removePreviewFile()
                previewError = error.localizedDescription
            }
        }
    }

    private func openAppLocation() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    private func openScreenshotsFolder() {
        screenshotService.openScreenshotsFolder()
    }

    private func testModel() {
        modelTestResult = nil
        modelTestError = nil
        isTestingModel = true

        Task { @MainActor in
            var temporaryFileURL: URL?
            defer {
                if let temporaryFileURL {
                    try? FileManager.default.removeItem(at: temporaryFileURL)
                }
                isTestingModel = false
            }

            do {
                temporaryFileURL = try screenshotService.captureTemporaryMainDisplay()
                guard let temporaryFileURL else {
                    throw NSError(
                        domain: "SettingsView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "测试模型时未生成临时截图"]
                    )
                }
                let response = try await analysisService.testCurrentSettings(with: temporaryFileURL)
                modelTestResult = response.category
            } catch {
                modelTestError = error.localizedDescription
            }
        }
    }

    private func removePreviewFile() {
        if let previewFileURL {
            try? FileManager.default.removeItem(at: previewFileURL)
            self.previewFileURL = nil
        }
        previewImage = nil
        previewCountdownText = nil
    }
}
