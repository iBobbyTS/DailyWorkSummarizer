import AppKit
import SwiftUI

struct SettingsView: View {
    private enum ModelCopyDestination: String, Identifiable {
        case workContentAnalysis
        case screenshotAnalysis

        var id: String { rawValue }
    }

    private enum Layout {
        static let sectionSpacing: CGFloat = 16
        static let cardRowVerticalPadding: CGFloat = 10
        static let cardRowHorizontalPadding: CGFloat = 18
        static let tabHorizontalPadding: CGFloat = 8
        static let tabVerticalPadding: CGFloat = 10
        static let numberFieldWidth: CGFloat = 72
        static let contextFieldWidth: CGFloat = 84
        static let percentageFieldRatio: CGFloat = 0.7
        static let servicePickerWidth: CGFloat = 220
        static let reportPickerWidth: CGFloat = 160
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
    @State private var modelTestResult: AnalysisResponse?
    @State private var modelTestError: String?
    @State private var modelTestCountdownText: String?
    @State private var isTestingModel = false
    @State private var pendingModelCopyDestination: ModelCopyDestination?

    private var language: AppLanguage {
        settingsStore.appLanguage
    }

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
            screenshotAnalysisTab
                .tabItem { Text(text(.settingsTabScreenshotAnalysis)) }

            workContentAnalysisTab
                .tabItem { Text(text(.settingsTabWorkContentAnalysis)) }

            generalTab
                .tabItem { Text(text(.settingsTabGeneral)) }

            reportTab
                .tabItem { Text(text(.settingsTabReport)) }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 560)
        .alert(item: $pendingModelCopyDestination) { destination in
            Alert(
                title: Text(text(.settingsModelCopyConfirmTitle)),
                message: Text(copyConfirmationMessage(for: destination)),
                primaryButton: .destructive(Text(text(.commonConfirm))) {
                    copyModelConfiguration(to: destination)
                },
                secondaryButton: .cancel(Text(text(.commonCancel)))
            )
        }
        .onDisappear {
            removePreviewFile()
        }
    }

    private var screenshotAnalysisTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                Text(text(.settingsTabCapture))
                    .font(.title2.weight(.semibold))

                captureSection

                Divider()
                    .padding(.vertical, 4)

                modelConfigurationSection(
                    provider: $settingsStore.provider,
                    apiBaseURL: $settingsStore.apiBaseURL,
                    modelName: $settingsStore.modelName,
                    apiKey: $settingsStore.apiKey,
                    lmStudioContextLength: Binding(
                        get: { settingsStore.lmStudioContextLength },
                        set: { settingsStore.lmStudioContextLength = $0 }
                    ),
                    copyButtonTitle: text(.settingsModelCopyToWorkContent),
                    onCopy: { pendingModelCopyDestination = .workContentAnalysis },
                    showTestingPanel: true
                )

                Divider()
                    .padding(.vertical, 4)

                Text(text(.settingsAnalysisCategoryTitle))
                    .font(.title2.weight(.semibold))

                categoryRulesEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.tabHorizontalPadding)
            .padding(.vertical, Layout.tabVerticalPadding)
        }
    }

    private var workContentAnalysisTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                modelConfigurationSection(
                    provider: $settingsStore.workContentProvider,
                    apiBaseURL: $settingsStore.workContentAPIBaseURL,
                    modelName: $settingsStore.workContentModelName,
                    apiKey: $settingsStore.workContentAPIKey,
                    lmStudioContextLength: Binding(
                        get: { settingsStore.workContentLMStudioContextLength },
                        set: { settingsStore.workContentLMStudioContextLength = $0 }
                    ),
                    copyButtonTitle: text(.settingsModelCopyToScreenshotAnalysis),
                    onCopy: { pendingModelCopyDestination = .screenshotAnalysis },
                    showTestingPanel: false
                )

                Divider()
                    .padding(.vertical, 4)

                Text(text(.settingsAnalysisSummaryTitle))
                    .font(.title2.weight(.semibold))

                summarySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.tabHorizontalPadding)
            .padding(.vertical, Layout.tabVerticalPadding)
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                intervalRow

                Divider()

                HStack(spacing: 12) {
                    Text(text(.settingsCaptureAutoAnalysis))
                    Spacer()
                    Toggle("", isOn: $settingsStore.automaticAnalysisEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)

                Divider()

                HStack(spacing: 12) {
                    Text(text(.settingsCaptureRequireCharger))
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
                    Text(text(.settingsCaptureAnalysisTime))
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
                            Text(text(.settingsCaptureTestingScreenshot))
                        } else {
                            Label(text(.settingsCaptureTestScreenshot), systemImage: "camera")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturingPreview)

                    Button {
                        openAppLocation()
                    } label: {
                        Label(text(.settingsCaptureOpenAppLocation), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openScreenshotsFolder()
                    } label: {
                        Label(text(.settingsCaptureOpenScreenshotsFolder), systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }

                if let previewImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text(.settingsCaptureTestResult))
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

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(.settingsAnalysisSummaryHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.08))

                if settingsStore.analysisSummaryInstruction.isEmpty {
                    Text(text(.settingsAnalysisSummaryPlaceholder))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }

                TextEditor(text: $settingsStore.analysisSummaryInstruction)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            .frame(minHeight: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private func modelConfigurationSection(
        provider: Binding<ModelProvider>,
        apiBaseURL: Binding<String>,
        modelName: Binding<String>,
        apiKey: Binding<String>,
        lmStudioContextLength: Binding<Int>,
        copyButtonTitle: String,
        onCopy: @escaping () -> Void,
        showTestingPanel: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(text(.settingsModelTitle))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                proportionalFieldRow(text(.settingsModelService)) { fieldWidth in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Picker("", selection: provider) {
                            ForEach(ModelProvider.allCases) { option in
                                Text(option.title(in: language)).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: Layout.servicePickerWidth, alignment: .trailing)
                    }
                    .frame(width: fieldWidth, alignment: .trailing)
                }

                Divider()

                proportionalFieldRow(text(.settingsModelBaseURL)) { fieldWidth in
                    TextField(provider.wrappedValue == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:8000", text: apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }

                Divider()

                proportionalFieldRow(text(.settingsModelName)) { fieldWidth in
                    TextField(text(.settingsModelNamePlaceholder), text: modelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }

                Divider()

                proportionalFieldRow(text(.settingsModelAPIKey)) { fieldWidth in
                    SecureField(text(.settingsModelAPIKeyPlaceholder), text: apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }

                if provider.wrappedValue == .lmStudio {
                    Divider()

                    proportionalFieldRow(text(.settingsModelContextLength), fieldWidth: Layout.contextFieldWidth) { fieldWidth in
                        TextField(
                            "4096 - 65536",
                            value: lmStudioContextLength,
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

            if provider.wrappedValue != .lmStudio {
                Text(text(.settingsModelOfficialUntested))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onCopy()
            } label: {
                Label(copyButtonTitle, systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)

            if showTestingPanel {
                modelTestPanel
            }
        }
    }

    private var categoryRulesEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text(.settingsModelCategoryName))
                    .frame(width: 180, alignment: .leading)
                Text(text(.settingsModelCategoryDescription))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: 96)
            }
            .font(.headline)

            ForEach(settingsStore.categoryRules) { rule in
                HStack(alignment: .top, spacing: 12) {
                    if rule.isPreservedOther {
                        TextField("", text: .constant(rule.displayName(in: language)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .disabled(true)
                    } else {
                        TextField(
                            text(.settingsModelCategoryNameExample),
                            text: Binding(
                                get: {
                                    settingsStore.categoryRules.first(where: { $0.id == rule.id })?.name ?? ""
                                },
                                set: { settingsStore.updateCategoryRuleName(id: rule.id, name: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    }

                    TextField(
                        text(.settingsModelCategoryDescriptionExample),
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
                        .disabled(rule.isPreservedOther || isFirstCategoryRule(rule.id))

                        Button {
                            settingsStore.moveCategoryRuleDown(id: rule.id)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(rule.isPreservedOther || isLastMovableCategoryRule(rule.id))

                        Button {
                            settingsStore.removeCategoryRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(rule.isPreservedOther)
                    }
                    .frame(width: 96, alignment: .trailing)
                }
            }

            Button {
                settingsStore.addCategoryRule()
            } label: {
                Label(text(.settingsModelAddCategory), systemImage: "plus")
            }

            if let validationMessage = settingsStore.categoryRulesValidationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelTestPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    testModel()
                } label: {
                    if isTestingModel {
                        ProgressView()
                            .controlSize(.small)
                        Text(text(.settingsModelTesting))
                    } else {
                        Label(text(.settingsModelTest), systemImage: "bolt.horizontal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTestingModel)

                Button {
                    copyPrompt()
                } label: {
                    Label(text(.settingsModelCopyPrompt), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            if let modelTestCountdownText {
                Text(modelTestCountdownText)
                    .foregroundStyle(.secondary)
            }

            if let modelTestResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text(.settingsModelTestResult))
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(labeledValue(text(.settingsAnalysisResultCategory), modelTestResult.category))
                        Text(labeledValue(text(.settingsAnalysisResultSummary), modelTestResult.summary))
                    }
                }
            }

            if let modelTestError {
                Text(modelTestError)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var intervalRow: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - Layout.cardRowHorizontalPadding * 2
            let controlGroupWidth = max(280, availableWidth * 0.68)
            let sliderWidth = max(140, controlGroupWidth - Layout.numberFieldWidth - 40)

            HStack(spacing: 12) {
                Text(text(.settingsCaptureInterval))
                Spacer()
                HStack(spacing: 12) {
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
                        text(.settingsCaptureMinutesPlaceholder),
                        value: Binding(
                            get: { settingsStore.screenshotIntervalMinutes },
                            set: { settingsStore.screenshotIntervalMinutes = $0 }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.numberFieldWidth)

                    Text(text(.settingsCaptureMinutesUnit))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(width: controlGroupWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
        }
        .frame(height: 52)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(text(.settingsGeneralTitle))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                proportionalFieldRow(text(.settingsLanguage)) { fieldWidth in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Picker("", selection: $settingsStore.appLanguage) {
                            ForEach(AppLanguage.allCases) { option in
                                Text(option.localizedName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: Layout.reportPickerWidth)
                    }
                    .frame(width: fieldWidth, alignment: .trailing)
                }
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

    private var reportTab: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(text(.settingsReportTitle))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                proportionalFieldRow(text(.settingsReportWeekStart)) { fieldWidth in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Picker("", selection: $settingsStore.reportWeekStart) {
                            ForEach(ReportWeekStart.allCases) { option in
                                Text(option.title(in: language)).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: Layout.reportPickerWidth)
                    }
                    .frame(width: fieldWidth, alignment: .trailing)
                }
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

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: language)
    }

    private func text(_ key: L10n.Key, arguments: [CVarArg]) -> String {
        L10n.string(key, language: language, arguments: arguments)
    }

    private func countdownText(_ remainingSeconds: Int) -> String {
        text(.settingsCountdown, arguments: [remainingSeconds])
    }

    private func labeledValue(_ label: String, _ value: String) -> String {
        let separator = language == .simplifiedChinese ? "：" : ": "
        return "\(label)\(separator)\(value)"
    }

    private func copyConfirmationMessage(for destination: ModelCopyDestination) -> String {
        switch destination {
        case .workContentAnalysis:
            return text(.settingsModelCopyToWorkContentConfirmMessage)
        case .screenshotAnalysis:
            return text(.settingsModelCopyToScreenshotAnalysisConfirmMessage)
        }
    }

    private func copyModelConfiguration(to destination: ModelCopyDestination) {
        switch destination {
        case .workContentAnalysis:
            settingsStore.copyScreenshotAnalysisModelToWorkContent()
        case .screenshotAnalysis:
            settingsStore.copyWorkContentModelToScreenshotAnalysis()
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
                    previewCountdownText = countdownText(remainingSeconds)
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
                        modelTestCountdownText = text(.settingsModelWaitingForModel)
                    } else {
                        modelTestCountdownText = countdownText(remainingSeconds)
                    }
                    try await Task.sleep(for: .seconds(1))
                }

                temporaryFileURL = try screenshotService.captureTemporaryMainDisplay()
                guard let temporaryFileURL else {
                    throw NSError(
                        domain: "SettingsView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: text(.settingsModelNoTempScreenshot)]
                    )
                }
                let response = try await analysisService.testCurrentSettings(with: temporaryFileURL)
                modelTestResult = response
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

    private func isLastMovableCategoryRule(_ id: UUID) -> Bool {
        guard let index = settingsStore.categoryRules.firstIndex(where: { $0.id == id }) else {
            return true
        }
        return index >= max(settingsStore.categoryRules.count - 2, 0)
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
