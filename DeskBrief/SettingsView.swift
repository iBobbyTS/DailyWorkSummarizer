import AppKit
import FoundationModels
import SwiftUI

struct SettingsView: View {
    private enum ModelCopyDestination: String, Identifiable {
        case workContentSummary
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
        static let imageAnalysisMethodPickerWidth: CGFloat = 320
        static let reportPickerWidth: CGFloat = 160
        static let categoryColorWidth: CGFloat = 72
        static let analysisStartupModePickerWidth: CGFloat = 260
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
    let logStore: AppLogStore?

    @State private var previewImage: NSImage?
    @State private var previewFileURL: URL?
    @State private var previewError: String?
    @State private var previewCountdownText: String?
    @State private var isCapturingPreview = false
    @State private var modelTestResult: ModelTestResult?
    @State private var modelTestError: String?
    @State private var modelTestCountdownText: String?
    @State private var isTestingModel = false
    @State private var pendingModelCopyDestination: ModelCopyDestination?

    private var language: AppLanguage {
        settingsStore.appLanguage
    }

    private var appleIntelligenceStatus: AppleIntelligenceStatus {
        AppleIntelligenceSupport.currentStatus(for: language)
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

            workContentSummaryTab
                .tabItem { Text(text(.settingsTabWorkContentSummary)) }

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
                Text(text(.settingsTabScreenshot))
                    .font(.title2.weight(.semibold))

                screenshotSection

                modelConfigurationSection(
                    provider: $settingsStore.provider,
                    imageAnalysisMethod: $settingsStore.imageAnalysisMethod,
                    apiBaseURL: $settingsStore.apiBaseURL,
                    modelName: $settingsStore.modelName,
                    apiKey: $settingsStore.apiKey,
                    lmStudioContextLength: Binding(
                        get: { settingsStore.lmStudioContextLength },
                        set: { settingsStore.lmStudioContextLength = $0 }
                    ),
                    copyButtonTitle: text(.settingsModelCopyToWorkContentSummary),
                    onCopy: { pendingModelCopyDestination = .workContentSummary },
                    showImageAnalysisMethod: true,
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

    private var workContentSummaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                modelConfigurationSection(
                    provider: $settingsStore.workContentSummaryProvider,
                    imageAnalysisMethod: .constant(.ocr),
                    apiBaseURL: $settingsStore.workContentSummaryAPIBaseURL,
                    modelName: $settingsStore.workContentSummaryModelName,
                    apiKey: $settingsStore.workContentSummaryAPIKey,
                    lmStudioContextLength: Binding(
                        get: { settingsStore.workContentSummaryLMStudioContextLength },
                        set: { settingsStore.workContentSummaryLMStudioContextLength = $0 }
                    ),
                    copyButtonTitle: text(.settingsModelCopyToScreenshotAnalysis),
                    onCopy: { pendingModelCopyDestination = .screenshotAnalysis },
                    showImageAnalysisMethod: false,
                    showTestingPanel: false
                )

                Divider()
                    .padding(.vertical, 4)

                Text(text(.settingsSummaryTitle))
                    .font(.title2.weight(.semibold))

                summarySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.tabHorizontalPadding)
            .padding(.vertical, Layout.tabVerticalPadding)
        }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                intervalRow

                Divider()

                HStack(spacing: 12) {
                    Text(text(.settingsAnalysisStartupMode))
                    Spacer()
                    Picker("", selection: $settingsStore.analysisStartupMode) {
                        ForEach(AnalysisStartupMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .frame(width: Layout.analysisStartupModePickerWidth, alignment: .trailing)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)

                if settingsStore.analysisStartupMode == .scheduled {
                    Divider()

                    HStack(spacing: 12) {
                        Text(text(.settingsAnalysisScheduledTime))
                        Spacer()
                        DatePicker(
                            "",
                            selection: analysisTimeBinding,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.field)
                    }
                    .padding(.horizontal, Layout.cardRowHorizontalPadding)
                    .padding(.vertical, Layout.cardRowVerticalPadding)
                }

                Divider()

                HStack(spacing: 12) {
                    Text(text(.settingsAnalysisRequireCharger))
                    Spacer()
                    Toggle("", isOn: $settingsStore.autoAnalysisRequiresCharger)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.horizontal, Layout.cardRowHorizontalPadding)
                .padding(.vertical, Layout.cardRowVerticalPadding)
                .disabled(settingsStore.analysisStartupMode == .manual)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.08))
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        capturePreview()
                    } label: {
                        if isCapturingPreview {
                            ProgressView()
                                .controlSize(.small)
                            Text(text(.settingsScreenshotTesting))
                        } else {
                            Label(text(.settingsScreenshotTest), systemImage: "camera")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCapturingPreview)

                    Button {
                        openAppLocation()
                    } label: {
                        Label(text(.settingsOpenAppLocation), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openScreenshotsFolder()
                    } label: {
                        Label(text(.settingsScreenshotOpenFolder), systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }

                if let previewImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text(.settingsScreenshotPreviewResult))
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
            .padding(.top, Layout.sectionSpacing)
            .padding(.bottom, Layout.sectionSpacing)

            Divider()
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text(.settingsSummaryHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.08))

                if settingsStore.summaryInstruction.isEmpty {
                    Text(text(.settingsSummaryPlaceholder))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }

                TextEditor(text: $settingsStore.summaryInstruction)
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
        imageAnalysisMethod: Binding<ImageAnalysisMethod>,
        apiBaseURL: Binding<String>,
        modelName: Binding<String>,
        apiKey: Binding<String>,
        lmStudioContextLength: Binding<Int>,
        copyButtonTitle: String,
        onCopy: @escaping () -> Void,
        showImageAnalysisMethod: Bool,
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
                                Text(providerOptionTitle(for: option))
                                    .tag(option)
                                    .disabled(!isProviderSelectable(option))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: Layout.servicePickerWidth, alignment: .trailing)
                    }
                    .frame(width: fieldWidth, alignment: .trailing)
                }

                if showImageAnalysisMethod {
                    Divider()

                    proportionalFieldRow(text(.settingsModelImageAnalysisMethod)) { fieldWidth in
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Picker("", selection: imageAnalysisMethod) {
                                ForEach(ImageAnalysisMethod.allCases) { option in
                                    Text(option.title(in: language)).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .disabled(provider.wrappedValue == .appleIntelligence)
                            .frame(width: Layout.imageAnalysisMethodPickerWidth, alignment: .trailing)
                        }
                        .frame(width: fieldWidth, alignment: .trailing)
                    }
                }

                if provider.wrappedValue.requiresRemoteConfiguration {
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
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.gray.opacity(0.08))
            )

            ForEach(providerFooterMessages(for: provider.wrappedValue), id: \.self) { message in
                Text(message)
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
                Text(text(.settingsModelCategoryColor))
                    .frame(width: Layout.categoryColorWidth, alignment: .leading)
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
                    CategoryRuleColorControl(
                        colorHex: Binding(
                            get: {
                                settingsStore.categoryRules.first(where: { $0.id == rule.id })?.colorHex ?? rule.colorHex
                            },
                            set: { settingsStore.updateCategoryRuleColor(id: rule.id, colorHex: $0) }
                        ),
                        language: language
                    )
                    .frame(width: Layout.categoryColorWidth, alignment: .leading)

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
                        Text(labeledValue(text(.settingsAnalysisResultCategory), modelTestResult.response.category))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(labeledValue(text(.settingsResultSummary), modelTestResult.response.summary))
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(modelTestTimingLines(for: modelTestResult), id: \.self) { line in
                            Text(line)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if modelTestResult.imageAnalysisMethod == .ocr {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(text(.settingsModelOCRText))
                                .font(.subheadline.weight(.medium))

                            ScrollView {
                                Text(ocrTextDisplay(for: modelTestResult))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                            }
                            .frame(minHeight: 120, maxHeight: 220)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.14), lineWidth: 1)
                            )
                        }
                    }

                    if let reasoningText = reasoningTextDisplay(for: modelTestResult) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(text(.settingsModelReasoningProcess))
                                .font(.subheadline.weight(.medium))

                            ScrollView {
                                Text(reasoningText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                            }
                            .frame(minHeight: 120, maxHeight: 220)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray.opacity(0.14), lineWidth: 1)
                            )
                        }
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
                Text(text(.settingsScreenshotInterval))
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
                        text(.settingsScreenshotMinutesPlaceholder),
                        value: Binding(
                            get: { settingsStore.screenshotIntervalMinutes },
                            set: { settingsStore.screenshotIntervalMinutes = $0 }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Layout.numberFieldWidth)

                    Text(text(.settingsScreenshotMinutesUnit))
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
                                Text(option.displayName(in: language)).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: Layout.reportPickerWidth, alignment: .trailing)
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
                        .fixedSize()
                        .frame(width: Layout.reportPickerWidth, alignment: .trailing)
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

    private func modelTestTimingLines(for result: ModelTestResult) -> [String] {
        switch result.provider {
        case .lmStudio:
            var lines: [String] = [
                labeledValue(
                    text(.settingsModelTimingModelLoad),
                    result.lmStudioTiming?.modelLoadTimeSeconds.map(formattedDuration)
                        ?? text(.settingsModelTimingUnavailable)
                )
            ]

            if let ttft = result.lmStudioTiming?.timeToFirstTokenSeconds {
                lines.append(labeledValue(text(.settingsModelTimingTTFT), formattedDuration(ttft)))
            }

            if let outputTime = result.lmStudioTiming?.outputTimeSeconds {
                lines.append(labeledValue(text(.settingsModelTimingOutput), formattedDuration(outputTime)))
            }

            if let roundTrip = result.requestTiming?.roundTripSeconds {
                lines.append(labeledValue(text(.settingsModelTimingRequest), formattedDuration(roundTrip)))
            }

            return lines
        case .openAI:
            if let serverProcessing = result.requestTiming?.serverProcessingSeconds {
                return [labeledValue(text(.settingsModelTimingServerProcessing), formattedDuration(serverProcessing))]
            }
            if let roundTrip = result.requestTiming?.roundTripSeconds {
                return [labeledValue(text(.settingsModelTimingRequest), formattedDuration(roundTrip))]
            }
            return []
        case .anthropic:
            if let roundTrip = result.requestTiming?.roundTripSeconds {
                return [labeledValue(text(.settingsModelTimingRequest), formattedDuration(roundTrip))]
            }
            return []
        case .appleIntelligence:
            return []
        }
    }

    private func ocrTextDisplay(for result: ModelTestResult) -> String {
        let trimmed = result.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? text(.settingsModelOCRTextEmpty) : trimmed
    }

    private func reasoningTextDisplay(for result: ModelTestResult) -> String? {
        let trimmed = result.reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            let milliseconds = seconds * 1_000
            if language == .simplifiedChinese {
                return String(format: "%.0f 毫秒", milliseconds)
            }
            return String(format: "%.0f ms", milliseconds)
        }

        if language == .simplifiedChinese {
            return String(format: "%.2f 秒", seconds)
        }
        return String(format: "%.2f s", seconds)
    }

    private func copyConfirmationMessage(for destination: ModelCopyDestination) -> String {
        switch destination {
        case .workContentSummary:
            return text(.settingsModelCopyToWorkContentSummaryConfirmMessage)
        case .screenshotAnalysis:
            return text(.settingsModelCopyToScreenshotAnalysisConfirmMessage)
        }
    }

    private func copyModelConfiguration(to destination: ModelCopyDestination) {
        switch destination {
        case .workContentSummary:
            settingsStore.copyScreenshotAnalysisModelToWorkContentSummary()
        case .screenshotAnalysis:
            settingsStore.copyWorkContentSummaryModelToScreenshotAnalysis()
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
                removeTemporaryFileIfExists(
                    validationResult.fileURL,
                    context: "Failed to remove screenshot validation preview"
                )

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
                logStore?.addError(source: .settings, context: "Failed to capture preview screenshot", error: error)
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
                    removeTemporaryFileIfExists(
                        temporaryFileURL,
                        context: "Failed to remove model test screenshot"
                    )
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
                logStore?.addError(source: .settings, context: "Failed to test current model settings", error: error)
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

    private func providerOptionTitle(for provider: ModelProvider) -> String {
        let baseTitle = provider.title(in: language)
        guard provider == .appleIntelligence,
              let suffix = appleIntelligencePickerSuffix() else {
            return baseTitle
        }

        let open = language == .simplifiedChinese ? "（" : " ("
        let close = language == .simplifiedChinese ? "）" : ")"
        return "\(baseTitle)\(open)\(suffix)\(close)"
    }

    private func appleIntelligencePickerSuffix() -> String? {
        if let unavailableReason = appleIntelligenceStatus.unavailableReason {
            return appleIntelligenceReasonText(for: unavailableReason)
        }

        guard !appleIntelligenceStatus.currentLanguageSupported else {
            return nil
        }

        return text(
            .providerAppleIntelligenceUnsupportedLanguage,
            arguments: [language.displayName(in: language)]
        )
    }

    private func appleIntelligenceReasonText(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return text(.providerAppleIntelligenceDeviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return text(.providerAppleIntelligenceNotEnabled)
        case .modelNotReady:
            return text(.providerAppleIntelligenceModelNotReady)
        @unknown default:
            return text(.providerAppleIntelligenceModelNotReady)
        }
    }

    private func isProviderSelectable(_ provider: ModelProvider) -> Bool {
        guard provider == .appleIntelligence else {
            return true
        }

        return appleIntelligenceStatus.isSelectable
    }

    private func providerFooterMessages(for provider: ModelProvider) -> [String] {
        switch provider {
        case .openAI, .anthropic:
            return [text(.settingsModelOfficialUntested)]
        case .lmStudio:
            return []
        case .appleIntelligence:
            var messages: [String] = []

            if !appleIntelligenceStatus.currentLanguageSupported {
                let supportedLanguages = appleIntelligenceStatus.supportedAppLanguages
                let supportedLanguageList = supportedLanguages.isEmpty
                    ? (language == .simplifiedChinese ? "无" : "none")
                    : supportedLanguages
                        .map { $0.displayName(in: language) }
                        .joined(separator: language == .simplifiedChinese ? "、" : ", ")
                messages.append(
                    text(
                        .settingsAppleIntelligenceSupportedLanguages,
                        arguments: [supportedLanguageList]
                    )
                )
            }

            messages.append(text(.settingsAppleIntelligenceOCROnly))
            return messages
        }
    }

    private func removePreviewFile() {
        if let previewFileURL {
            removeTemporaryFileIfExists(
                previewFileURL,
                context: "Failed to remove preview screenshot"
            )
            self.previewFileURL = nil
        }
        previewImage = nil
        previewCountdownText = nil
    }

    private func removeTemporaryFileIfExists(_ url: URL, context: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logStore?.addError(source: .settings, context: context, error: error)
        }
    }
}

private struct CategoryRuleColorControl: View {
    @Binding var colorHex: String
    let language: AppLanguage
    @State private var isPresetPopoverPresented = false

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hexRGB: colorHex) },
            set: { newColor in
                guard let newColorHex = newColor.hexRGB else { return }
                colorHex = newColorHex
            }
        )
    }

    private var presetColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(22), spacing: 6), count: 4)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isPresetPopoverPresented.toggle()
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hexRGB: colorHex))
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresetPopoverPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: presetColumns, spacing: 6) {
                        ForEach(AppDefaults.categoryColorPresets, id: \.self) { preset in
                            Button {
                                colorHex = preset
                                isPresetPopoverPresented = false
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(hexRGB: preset))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if colorHex == preset {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(.secondary.opacity(0.35), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()

                    ColorPicker(
                        L10n.string(.settingsModelCustomColor, language: language),
                        selection: colorBinding,
                        supportsOpacity: false
                    )
                }
                .padding(12)
                .frame(width: 154)
            }
        }
        .frame(height: 28, alignment: .center)
    }
}
