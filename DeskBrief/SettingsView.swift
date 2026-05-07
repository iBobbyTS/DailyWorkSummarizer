import AppKit
import Combine
import FoundationModels
import SwiftUI

@MainActor
final class SettingsWindowState: ObservableObject {
    var hasUnsavedDatabasePassphrase = false
    @Published var discardUnsavedDatabasePassphrase = false
}

enum SettingsTab: Hashable {
    case screenshotAnalysis
    case workContentSummary
    case general
}

struct SettingsView: View {
    private enum ModelCopyDestination: String, Identifiable {
        case workContentSummary
        case screenshotAnalysis

        var id: String { rawValue }
    }

    private enum DatabaseEncryptionAction: Identifiable, Equatable {
        case enable(DatabasePassphrase)
        case disable
        case update(DatabasePassphrase)

        var id: String {
            switch self {
            case .enable:
                return "enable"
            case .disable:
                return "disable"
            case .update:
                return "update"
            }
        }
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
        static let characterCounterBottomPadding: CGFloat = 6
        static let characterCounterTrailingPadding: CGFloat = 10
        static let characterCounterReservedHeight: CGFloat = 18
        static let inputWarningCornerRadius: CGFloat = 6
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
    let dailyReportSummaryService: DailyReportSummaryService
    @ObservedObject var windowState: SettingsWindowState
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
    @State private var pendingDatabasePassphrase = ""
    @State private var pendingDatabaseEncryptionAction: DatabaseEncryptionAction?
    @State private var selectedTab: SettingsTab

    @State private var showIntervalTooltip = false

    init(
        settingsStore: SettingsStore,
        screenshotService: ScreenshotService,
        analysisService: AnalysisService,
        dailyReportSummaryService: DailyReportSummaryService,
        windowState: SettingsWindowState,
        logStore: AppLogStore?,
        selectedTab: SettingsTab = .screenshotAnalysis
    ) {
        self.settingsStore = settingsStore
        self.screenshotService = screenshotService
        self.analysisService = analysisService
        self.dailyReportSummaryService = dailyReportSummaryService
        self.windowState = windowState
        self.logStore = logStore
        _selectedTab = State(initialValue: selectedTab)
    }

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
        TabView(selection: $selectedTab) {
            screenshotAnalysisTab
                .tabItem { Text(text(.settingsTabScreenshotAnalysis)) }
                .tag(SettingsTab.screenshotAnalysis)

            workContentSummaryTab
                .tabItem { Text(text(.settingsTabWorkContentSummary)) }
                .tag(SettingsTab.workContentSummary)

            generalTab
                .tabItem { Text(text(.settingsTabGeneral)) }
                .tag(SettingsTab.general)
        }
        .accessibilityIdentifier("settings.root")
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
        .alert(item: $settingsStore.persistenceAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(text(.commonConfirm)))
            )
        }
        .alert(item: $pendingDatabaseEncryptionAction) { action in
            databaseEncryptionAlert(for: action)
        }
        .onChange(of: pendingDatabasePassphrase) { _, newValue in
            windowState.hasUnsavedDatabasePassphrase = settingsStore.databasePassphraseCanBeUpdated(to: newValue)
        }
        .onChange(of: settingsStore.databaseEncryptionEnabled) { _, isEnabled in
            if !isEnabled {
                pendingDatabasePassphrase = ""
            }
        }
        .onChange(of: windowState.discardUnsavedDatabasePassphrase) { _, shouldDiscard in
            guard shouldDiscard else { return }
            pendingDatabasePassphrase = ""
            windowState.hasUnsavedDatabasePassphrase = false
            DispatchQueue.main.async {
                windowState.discardUnsavedDatabasePassphrase = false
            }
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
                    lmStudioExplicitLoadUnloadModel: Binding(
                        get: { settingsStore.screenshotAnalysisLMStudioExplicitLoadUnloadModel },
                        set: { settingsStore.screenshotAnalysisLMStudioExplicitLoadUnloadModel = $0 }
                    ),
                    memoryCheckEnabled: Binding(
                        get: { settingsStore.screenshotAnalysisMemoryCheckEnabled },
                        set: { settingsStore.screenshotAnalysisMemoryCheckEnabled = $0 }
                    ),
                    memoryThresholdGB: Binding(
                        get: { settingsStore.screenshotAnalysisMemoryThresholdGB },
                        set: { settingsStore.screenshotAnalysisMemoryThresholdGB = $0 }
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
        .accessibilityIdentifier("settings.tab.screenshotAnalysis")
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
                    lmStudioExplicitLoadUnloadModel: Binding(
                        get: { settingsStore.workContentSummaryLMStudioExplicitLoadUnloadModel },
                        set: { settingsStore.workContentSummaryLMStudioExplicitLoadUnloadModel = $0 }
                    ),
                    memoryCheckEnabled: Binding(
                        get: { settingsStore.workContentSummaryMemoryCheckEnabled },
                        set: { settingsStore.workContentSummaryMemoryCheckEnabled = $0 }
                    ),
                    memoryThresholdGB: Binding(
                        get: { settingsStore.workContentSummaryMemoryThresholdGB },
                        set: { settingsStore.workContentSummaryMemoryThresholdGB = $0 }
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

                Divider()
                    .padding(.vertical, 4)

                Text(text(.settingsReportTitle))
                    .font(.title2.weight(.semibold))

                reportSettingsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.tabHorizontalPadding)
            .padding(.vertical, Layout.tabVerticalPadding)
        }
        .accessibilityIdentifier("settings.tab.workContentSummary")
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                intervalRow

                Divider()

                storageLocationRow

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
                    InfoTooltipButton(text: text(.settingsAnalysisStartupModeTooltip))
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
                        InfoTooltipButton(text: text(.settingsAnalysisScheduledTimeTooltip))
                    }
                    .padding(.horizontal, Layout.cardRowHorizontalPadding)
                    .padding(.vertical, Layout.cardRowVerticalPadding)
                }

                if SettingsAnalysisControlsPolicy.showsChargerRequirement(
                    for: settingsStore.analysisStartupMode,
                    hasInternalBattery: DevicePowerState.current().hasInternalBattery
                ) {
                    Divider()

                    HStack(spacing: 12) {
                        Text(text(.settingsAnalysisRequireCharger))
                        Spacer()
                        Toggle("", isOn: $settingsStore.autoAnalysisRequiresCharger)
                            .labelsHidden()
                            .toggleStyle(.switch)
                        InfoTooltipButton(text: text(.settingsAnalysisChargerRequirementTooltip))
                    }
                    .padding(.horizontal, Layout.cardRowHorizontalPadding)
                    .padding(.vertical, Layout.cardRowVerticalPadding)
                }

                Divider()

                proportionalFieldRow(text(.settingsAutoDeletionRetention), tooltip: text(.settingsAutoDeletionRetentionTooltip)) { fieldWidth in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Picker("", selection: $settingsStore.screenshotAutoDeletionRetention) {
                            ForEach(ScreenshotAutoDeletionRetention.allCases) { option in
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
        let isOverLimit = SettingsInputLimits.isOverLimit(
            settingsStore.summaryInstruction,
            limit: SettingsInputLimits.summaryInstructionCharacters
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text(text(.settingsSummaryHint))
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.08))

                ZStack(alignment: .topLeading) {
                    if settingsStore.summaryInstruction.isEmpty {
                        Text(text(.settingsSummaryPlaceholder))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }

                    SummaryInstructionTextView(text: $settingsStore.summaryInstruction)
                }
                .padding(.bottom, Layout.characterCounterReservedHeight)

                characterLimitCounter(
                    for: settingsStore.summaryInstruction,
                    limit: SettingsInputLimits.summaryInstructionCharacters
                )
                .padding(.trailing, Layout.characterCounterTrailingPadding)
                .padding(.bottom, Layout.characterCounterBottomPadding)
            }
            .frame(minHeight: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isOverLimit ? Color.red : Color.gray.opacity(0.14), lineWidth: 1)
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
        lmStudioExplicitLoadUnloadModel: Binding<Bool>,
        memoryCheckEnabled: Binding<Bool>,
        memoryThresholdGB: Binding<Double>,
        copyButtonTitle: String,
        onCopy: @escaping () -> Void,
        showImageAnalysisMethod: Bool,
        showTestingPanel: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(text(.settingsModelTitle))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                proportionalFieldRow(text(.settingsModelService), tooltip: text(.settingsModelServiceTooltip)) { fieldWidth in
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

                    proportionalFieldRow(text(.settingsModelImageAnalysisMethod), tooltip: text(.settingsModelImageAnalysisMethodTooltip)) { fieldWidth in
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

                    proportionalFieldRow(text(.settingsModelBaseURL), tooltip: text(.settingsModelBaseURLTooltip)) { fieldWidth in
                        TextField(provider.wrappedValue == .lmStudio ? "http://127.0.0.1:1234" : "http://127.0.0.1:8000", text: apiBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    Divider()

                    proportionalFieldRow(text(.settingsModelName), tooltip: text(.settingsModelNameTooltip)) { fieldWidth in
                        TextField(text(.settingsModelNamePlaceholder), text: modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    Divider()

                    proportionalFieldRow(text(.settingsModelAPIKey), tooltip: text(.settingsModelAPIKeyTooltip)) { fieldWidth in
                        SecureField(text(.settingsModelAPIKeyPlaceholder), text: apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: fieldWidth)
                    }

                    if provider.wrappedValue == .lmStudio {
                        Divider()

                        proportionalFieldRow(text(.settingsModelContextLength), fieldWidth: Layout.contextFieldWidth, tooltip: text(.settingsModelContextLengthTooltip)) { fieldWidth in
                            TextField(
                                "4096 - 65536",
                                value: lmStudioContextLength,
                                formatter: Layout.plainIntegerFormatter
                            )
                            .textFieldStyle(.roundedBorder)
                                .frame(width: fieldWidth)
                        }

                        Divider()

                        modelLifecycleToggleRow(
                            text(.settingsModelLMStudioExplicitLoadUnloadModel),
                            helpText: text(.settingsModelLMStudioExplicitLoadUnloadModelHelp),
                            tooltip: text(.settingsModelLMStudioExplicitLoadUnloadModelTooltip),
                            isOn: lmStudioExplicitLoadUnloadModel
                        )

                        if lmStudioExplicitLoadUnloadModel.wrappedValue,
                           apiBaseURL.wrappedValue.contains("127.0.0.1") || apiBaseURL.wrappedValue.contains("localhost") {
                            Divider()

                            VStack(alignment: .leading, spacing: 0) {
                                proportionalFieldRow(text(.memoryCheckTitle), fieldWidth: 64, tooltip: text(.memoryThresholdTooltip)) { fieldWidth in
                                    HStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        Toggle("", isOn: memoryCheckEnabled)
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .accessibilityLabel(text(.memoryCheckTitle))
                                    }
                                    .frame(width: fieldWidth, alignment: .trailing)
                                }

                                if memoryCheckEnabled.wrappedValue {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(text(.memoryTotalRam) + memorySizeText(SystemMemoryInfo.totalGB))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(text(.memoryAvailableRam) + memorySizeText(SystemMemoryInfo.currentAvailableGB))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, Layout.cardRowHorizontalPadding)

                                    HStack(spacing: 8) {
                                        Text(memorySizeText(1))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Slider(value: memoryThresholdGB, in: 1.0...max(1.1, SystemMemoryInfo.totalGB), step: 1)
                                            .help(text(.memoryThresholdTooltip))
                                        TextField(
                                            "",
                                            value: memoryThresholdGB,
                                            formatter: Layout.plainIntegerFormatter
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 56)
                                        Text(text(.memoryUnitGiB))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, Layout.cardRowHorizontalPadding)
                                    .padding(.bottom, Layout.cardRowVerticalPadding)
                                    .padding(.top, 4)
                                }
                            }
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

                    categoryRuleNameField(rule)
                        .frame(width: 180)

                    categoryRuleDescriptionField(rule)
                        .frame(maxWidth: .infinity, minHeight: 56)

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

    @ViewBuilder
    private func categoryRuleNameField(_ rule: CategoryRule) -> some View {
        if rule.isPreservedOther {
            TextField("", text: .constant(rule.displayName(in: language)))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
        } else {
            let name = settingsStore.categoryRules.first(where: { $0.id == rule.id })?.name ?? ""

            TextField(
                categoryNamePlaceholder,
                text: Binding(
                    get: {
                        settingsStore.categoryRules.first(where: { $0.id == rule.id })?.name ?? ""
                    },
                    set: { settingsStore.updateCategoryRuleName(id: rule.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .overlay(
                inputLimitStroke(
                    isOverLimit: SettingsInputLimits.isOverLimit(
                        name,
                        limit: SettingsInputLimits.categoryNameCharacters
                    )
                )
            )
        }
    }

    private func categoryRuleDescriptionField(_ rule: CategoryRule) -> some View {
        let description = settingsStore.categoryRules.first(where: { $0.id == rule.id })?.description ?? ""
        let isOverLimit = SettingsInputLimits.isOverLimit(
            description,
            limit: SettingsInputLimits.categoryDescriptionCharacters
        )

        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: Layout.inputWarningCornerRadius)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(inputLimitStroke(isOverLimit: isOverLimit))

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
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 22)

            characterLimitCounter(
                for: description,
                limit: SettingsInputLimits.categoryDescriptionCharacters
            )
            .padding(.trailing, Layout.characterCounterTrailingPadding)
            .padding(.bottom, Layout.characterCounterBottomPadding)
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

                Button {
                    showIntervalTooltip.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .help("")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showIntervalTooltip, arrowEdge: .trailing) {
                        Text(text(.settingsIntervalTooltip))
                        .padding()
                        .frame(width: 280)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
        }
        .frame(height: 52)
    }

    private var storageLocationRow: some View {
        proportionalFieldRow(text(.settingsScreenshotStorageLocation), tooltip: text(.settingsScreenshotStorageLocationTooltip)) { fieldWidth in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker("", selection: $settingsStore.screenshotStorageLocation) {
                    ForEach(ScreenshotStorageLocation.allCases) { location in
                        Text(location.localizedTitle(language: language))
                            .tag(location)
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

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(text(.settingsGeneralTitle))
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("settings.tab.general")

            VStack(alignment: .leading, spacing: 0) {
                proportionalFieldRow(text(.settingsLanguage), tooltip: text(.settingsLanguageTooltip)) { fieldWidth in
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

            Text(text(.settingsDatabaseSectionTitle))
                .font(.title2.weight(.semibold))

            databaseSettingsSection

            Button {
                openDatabaseLocation()
            } label: {
                Label(text(.settingsDatabaseOpenLocation), systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.tabHorizontalPadding)
        .padding(.vertical, Layout.tabVerticalPadding)
    }

    private var databaseSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            proportionalFieldRow(text(.settingsDatabaseEncryption), tooltip: text(.settingsDatabaseEncryptionTooltip)) { fieldWidth in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsStore.databaseEncryptionEnabled },
                            set: handleDatabaseEncryptionToggle
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(text(.settingsDatabaseEncryption))
                    .accessibilityIdentifier("settings.databaseEncryptionToggle")
                }
                .frame(width: fieldWidth, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleDatabaseEncryptionToggle(!settingsStore.databaseEncryptionEnabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text(.settingsDatabaseEncryption))
                .accessibilityIdentifier("settings.databaseEncryptionToggle")
                .accessibilityValue(settingsStore.databaseEncryptionEnabled ? "On" : "Off")
            }

            if settingsStore.databaseEncryptionEnabled {
                Divider()

                proportionalFieldRow(text(.settingsDatabasePassphrase), tooltip: text(.settingsDatabasePassphraseTooltip)) { fieldWidth in
                    HStack(spacing: 8) {
                        SecureField(text(.settingsDatabasePassphrasePlaceholder), text: $pendingDatabasePassphrase)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: max(160, fieldWidth - 88), alignment: .trailing)
                        Button(text(.settingsDatabasePassphraseConfirm)) {
                            requestDatabasePassphraseUpdate()
                        }
                        .disabled(!settingsStore.databasePassphraseCanBeUpdated(to: pendingDatabasePassphrase))
                    }
                    .frame(width: fieldWidth, alignment: .trailing)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var reportSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            proportionalFieldRow(text(.settingsReportWeekStart), tooltip: text(.settingsReportWeekStartTooltip)) { fieldWidth in
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
    }

    private func proportionalFieldRow<Content: View>(
        _ title: String,
        fieldWidth: CGFloat? = nil,
        tooltip: String? = nil,
        @ViewBuilder field: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - Layout.cardRowHorizontalPadding * 2
            let resolvedFieldWidth = fieldWidth ?? max(220, availableWidth * Layout.percentageFieldRatio)

            HStack(spacing: 12) {
                Text(title)
                Spacer()
                field(resolvedFieldWidth)
                if let tooltip {
                    InfoTooltipButton(text: tooltip)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
        }
        .frame(height: 52)
    }

    private func modelLifecycleToggleRow(
        _ title: String,
        helpText: String,
        tooltip: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - Layout.cardRowHorizontalPadding * 2
            let resolvedFieldWidth = max(220, availableWidth * Layout.percentageFieldRatio)

            HStack(spacing: 12) {
                Text(title)
                Spacer()
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text(title))
                }
                .frame(width: resolvedFieldWidth, alignment: .trailing)
                if let tooltip {
                    InfoTooltipButton(text: tooltip)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Layout.cardRowHorizontalPadding)
            .padding(.vertical, Layout.cardRowVerticalPadding)
            .contentShape(Rectangle())
            .help(helpText)
        }
        .frame(height: 52)
    }

    private func formatGB(_ gb: Double?) -> String {
        guard let gb else { return "—" }
        return String(format: "%.1f", gb)
    }

    private func memorySizeText(_ gb: Double?) -> String {
        text(.memorySizeGiB, arguments: [formatGB(gb)])
    }

    private func text(_ key: L10n.Key) -> String {
        L10n.string(key, language: language)
    }

    private func text(_ key: L10n.Key, arguments: [CVarArg]) -> String {
        L10n.string(key, language: language, arguments: arguments)
    }

    private var categoryNamePlaceholder: String {
        text(.settingsModelCategoryNameExample)
            + text(.settingsCharacterLimitSuffix, arguments: [SettingsInputLimits.categoryNameCharacters])
    }

    private func characterLimitCounter(for value: String, limit: Int) -> some View {
        let isOverLimit = SettingsInputLimits.isOverLimit(value, limit: limit)

        return Text(SettingsInputLimits.counterText(for: value, limit: limit))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(isOverLimit ? Color.red : Color.secondary)
            .allowsHitTesting(false)
    }

    private func inputLimitStroke(
        isOverLimit: Bool,
        cornerRadius: CGFloat = Layout.inputWarningCornerRadius
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isOverLimit ? Color.red : Color.clear, lineWidth: 1)
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

    private func handleDatabaseEncryptionToggle(_ enabled: Bool) {
        guard enabled != settingsStore.databaseEncryptionEnabled else {
            return
        }
        guard ensureDatabaseEncryptionOperationAllowed() else {
            return
        }

        do {
            if enabled {
                pendingDatabaseEncryptionAction = .enable(try settingsStore.generateDatabasePassphrase())
            } else {
                pendingDatabaseEncryptionAction = .disable
            }
        } catch {
            showDatabaseOperationFailed(error)
        }
    }

    private func requestDatabasePassphraseUpdate() {
        guard ensureDatabaseEncryptionOperationAllowed() else {
            return
        }
        let trimmedPassphrase = pendingDatabasePassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            pendingDatabaseEncryptionAction = .update(try DatabasePassphrase(trimmedPassphrase))
        } catch {
            showDatabaseOperationFailed(error)
        }
    }

    private func applyDatabaseEncryptionAction(_ action: DatabaseEncryptionAction) {
        do {
            switch action {
            case .enable(let passphrase):
                try settingsStore.enableDatabaseEncryption(with: passphrase)
                pendingDatabasePassphrase = ""
            case .disable:
                try settingsStore.disableDatabaseEncryption()
            case .update(let passphrase):
                try settingsStore.updateDatabasePassphrase(to: passphrase)
                pendingDatabasePassphrase = ""
            }
            windowState.hasUnsavedDatabasePassphrase = false
        } catch {
            showDatabaseOperationFailed(error)
        }
    }

    private func databaseEncryptionAlert(for action: DatabaseEncryptionAction) -> Alert {
        switch action {
        case .disable:
            return Alert(
                title: Text(text(.settingsDatabaseDisableConfirmTitle)),
                message: Text(text(.settingsDatabaseDisableConfirmMessage)),
                primaryButton: .destructive(Text(text(.settingsDatabaseDisableConfirmButton))) {
                    applyDatabaseEncryptionAction(action)
                },
                secondaryButton: .cancel(Text(text(.commonCancel)))
            )
        case .enable(let passphrase), .update(let passphrase):
            return Alert(
                title: Text(text(.settingsDatabaseEnableConfirmTitle)),
                message: Text(text(.settingsDatabaseEnableConfirmMessage, arguments: [passphrase.value])),
                primaryButton: .default(Text(text(.commonConfirm))) {
                    applyDatabaseEncryptionAction(action)
                },
                secondaryButton: .cancel(Text(text(.commonCancel)))
            )
        }
    }

    private func ensureDatabaseEncryptionOperationAllowed() -> Bool {
        guard !analysisService.currentState.isRunning,
              !dailyReportSummaryService.currentState.isRunning else {
            settingsStore.persistenceAlert = SettingsPersistenceAlert(
                title: text(.settingsDatabaseBusyTitle),
                message: text(.settingsDatabaseBusyMessage)
            )
            return false
        }
        return true
    }

    private func showDatabaseOperationFailed(_ error: Error) {
        settingsStore.persistenceAlert = SettingsPersistenceAlert(
            title: text(.settingsDatabaseOperationFailedTitle),
            message: error.localizedDescription
        )
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

                let validationResult = try await screenshotService.capturePreview()
                removeTemporaryFileIfExists(
                    validationResult.fileURL,
                    context: "Failed to remove screenshot validation preview"
                )

                for remainingSeconds in stride(from: 3, through: 1, by: -1) {
                    previewCountdownText = countdownText(remainingSeconds)
                    try await Task.sleep(for: .seconds(1))
                }

                let result = try await screenshotService.capturePreview()
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

    private func openDatabaseLocation() {
        NSWorkspace.shared.activateFileViewerSelecting([settingsStore.databaseURL])
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

                temporaryFileURL = try await screenshotService.captureTemporaryMainDisplay()
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

private struct SummaryInstructionTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        SummaryInstructionTextViewTextSystem.apply(to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let textLength = (text as NSString).length
            let location = min(selectedRange.location, textLength)
            let length = min(selectedRange.length, max(0, textLength - location))
            textView.setSelectedRange(NSRange(location: location, length: length))
        }
        SummaryInstructionTextViewTextSystem.apply(to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}

enum SummaryInstructionTextViewTextSystem {
    static let textContainerInset = NSSize(width: 12, height: 12)
    static let lineFragmentPadding: CGFloat = 0

    static func apply(to textView: NSTextView) {
        let preferredFont = NSFont.preferredFont(forTextStyle: .body)
        if textView.drawsBackground {
            textView.drawsBackground = false
        }
        if textView.font != preferredFont {
            textView.font = preferredFont
        }
        if textView.textColor != .labelColor {
            textView.textColor = .labelColor
        }
        if textView.textContainerInset != textContainerInset {
            textView.textContainerInset = textContainerInset
        }
        if textView.textContainer?.lineFragmentPadding != lineFragmentPadding {
            textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        }
    }
}

nonisolated enum SettingsAnalysisControlsPolicy {
    static func showsChargerRequirement(for startupMode: AnalysisStartupMode, hasInternalBattery: Bool = true) -> Bool {
        startupMode != .manual && hasInternalBattery
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
private struct InfoTooltipButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            parsedTooltip(text)
        }
    }

    private func parsedTooltip(_ raw: String) -> some View {
        var result = AttributedString()
        for (index, part) in raw.components(separatedBy: "*").enumerated() {
            guard !part.isEmpty else { continue }
            var segment = AttributedString(part)
            if !index.isMultiple(of: 2) {
                segment.font = .body.bold()
            }
            result.append(segment)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(result)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 280)
    }
}
