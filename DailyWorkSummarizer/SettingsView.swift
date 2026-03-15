import AppKit
import SwiftUI

struct SettingsView: View {
    private enum Layout {
        static let sectionSpacing: CGFloat = 16
        static let cardRowVerticalPadding: CGFloat = 10
        static let cardRowHorizontalPadding: CGFloat = 18
        static let tabHorizontalPadding: CGFloat = 8
        static let tabVerticalPadding: CGFloat = 10
        static let sliderLabelWidth: CGFloat = 64
        static let numberFieldWidth: CGFloat = 72
        static let contextFieldWidth: CGFloat = 84
        static let percentageFieldRatio: CGFloat = 0.7
        static let plainIntegerFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
            return formatter
        }()
    }

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
    @State private var modelTestCountdownText: String?
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

            reportTab
                .tabItem { Text("报告") }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 560)
        .onDisappear {
            removePreviewFile()
        }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                intervalRow

                Divider()

                HStack(spacing: 12) {
                    Text("定时自动分析")
                    Spacer()
                    Toggle("", isOn: $settingsStore.automaticAnalysisEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)

                Divider()

                HStack(spacing: 12) {
                    Text("仅在连接充电器时定时开始分析")
                    Spacer()
                    Toggle("", isOn: $settingsStore.autoAnalysisRequiresCharger)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)
                .disabled(!settingsStore.automaticAnalysisEnabled)

                Divider()

                HStack(spacing: 12) {
                    Text("定时分析时间")
                    Spacer()
                    DatePicker(
                        "",
                        selection: analysisTimeBinding,
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .disabled(!settingsStore.automaticAnalysisEnabled)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.08))
            )

            Divider()
                .padding(.vertical, 4)

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
        .padding(.horizontal, Layout.tabHorizontalPadding)
        .padding(.vertical, Layout.tabVerticalPadding)
    }

    private var modelTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                Text("模型设置")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text("模型服务")
                        Spacer()
                        Picker("", selection: $settingsStore.provider) {
                            ForEach(ModelProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                    .padding(.horizontal, Layout.cardRowHorizontalPadding)
                    .padding(.vertical, Layout.cardRowVerticalPadding)

                    Divider()

                    proportionalFieldRow("接口地址") { fieldWidth in
                        TextField(settingsStore.provider == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:8000", text: $settingsStore.apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    Divider()

                    proportionalFieldRow("模型名称") { fieldWidth in
                        TextField("请输入模型名称", text: $settingsStore.modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    Divider()

                    proportionalFieldRow("API 秘钥") { fieldWidth in
                        SecureField("请输入 API Key（可留空）", text: $settingsStore.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    if settingsStore.provider == .lmStudio {
                        Divider()

                        proportionalFieldRow("上下文长度", fieldWidth: Layout.contextFieldWidth) { fieldWidth in
                            TextField(
                                "4096 - 65536",
                                value: Binding(
                                    get: { settingsStore.lmStudioContextLength },
                                    set: { settingsStore.lmStudioContextLength = $0 }
                                ),
                                formatter: Layout.plainIntegerFormatter
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.gray.opacity(0.08))
                )

                if settingsStore.provider != .lmStudio {
                    Text("官方 API 未经过测试")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("分析分类")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 12) {
                    HStack {
                        Text("类别名")
                            .frame(width: 180, alignment: .leading)
                        Text("描述")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(width: 96)
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
                            .frame(width: 180)

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
                            .frame(maxWidth: .infinity, minHeight: 36)

                            HStack(spacing: 6) {
                                Button {
                                    settingsStore.moveCategoryRuleUp(id: rule.id)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(isFirstCategoryRule(rule.id))

                                Button {
                                    settingsStore.moveCategoryRuleDown(id: rule.id)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(isLastCategoryRule(rule.id))

                                Button {
                                    settingsStore.removeCategoryRule(id: rule.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .frame(width: 96, alignment: .trailing)
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
                    HStack(spacing: 12) {
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

                        Button {
                            copyPrompt()
                        } label: {
                            Label("复制prompt", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let modelTestCountdownText {
                        Text(modelTestCountdownText)
                            .foregroundStyle(.secondary)
                    }

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
            .padding(.horizontal, Layout.tabHorizontalPadding)
            .padding(.vertical, Layout.tabVerticalPadding)
        }
    }

    private var intervalRow: some View {
        GeometryReader { geometry in
            let reservedWidth =
                Layout.sliderLabelWidth +
                Layout.numberFieldWidth +
                28 +
                Layout.cardRowHorizontalPadding * 2 +
                36
            let maxSliderWidth = max(140, geometry.size.width - reservedWidth)
            let sliderWidth = min(maxSliderWidth, geometry.size.width * 0.6)

            HStack(spacing: 12) {
                Text("截图间隔")
                    .frame(width: Layout.sliderLabelWidth, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(settingsStore.screenshotIntervalMinutes) },
                        set: { settingsStore.screenshotIntervalMinutes = Int($0.rounded()) }
                    ),
                    in: 1...60,
                    step: 1
                )
                .frame(width: sliderWidth)

                TextField(
                    "分钟",
                    value: Binding(
                        get: { settingsStore.screenshotIntervalMinutes },
                        set: { settingsStore.screenshotIntervalMinutes = $0 }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: Layout.numberFieldWidth)

                Text("分钟")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
        }
        .frame(height: 52)
    }

    private var reportTab: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text("报告设置")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("一周的第一天")
                    Spacer()
                    Picker("", selection: $settingsStore.reportWeekStart) {
                        ForEach(ReportWeekStart.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.08))
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.tabHorizontalPadding)
        .padding(.vertical, Layout.tabVerticalPadding)
    }

    private func proportionalFieldRow<Content: View>(
        _ title: String,
        fieldWidth: CGFloat? = nil,
        @ViewBuilder field: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - Layout.cardRowHorizontalPadding * 2
            let resolvedFieldWidth = fieldWidth ?? max(220, availableWidth * Layout.percentageFieldRatio)

            HStack(spacing: 12) {
                Text(title)
                Spacer()
                field(resolvedFieldWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
        }
        .frame(height: 52)
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
        modelTestCountdownText = nil
        isTestingModel = true

        Task { @MainActor in
            var temporaryFileURL: URL?
            defer {
                if let temporaryFileURL {
                    try? FileManager.default.removeItem(at: temporaryFileURL)
                }
                modelTestCountdownText = nil
                isTestingModel = false
            }

            do {
                for remainingSeconds in stride(from: 3, through: 1, by: -1) {
                    if remainingSeconds == 1 {
                        modelTestCountdownText = "正在分析，可能需要等待模型加载"
                    } else {
                        modelTestCountdownText = "倒计时：\(remainingSeconds)秒"
                    }
                    try await Task.sleep(for: .seconds(1))
                }

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

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(analysisService.currentPrompt(), forType: .string)
    }

    private func isFirstCategoryRule(_ id: UUID) -> Bool {
        settingsStore.categoryRules.first?.id == id
    }

    private func isLastCategoryRule(_ id: UUID) -> Bool {
        settingsStore.categoryRules.last?.id == id
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
