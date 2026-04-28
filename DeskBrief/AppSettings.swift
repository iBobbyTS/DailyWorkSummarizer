import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var screenshotIntervalMinutes: Int {
        didSet {
            let clamped = max(1, min(60, screenshotIntervalMinutes))
            if screenshotIntervalMinutes != clamped {
                screenshotIntervalMinutes = clamped
                return
            }
            userDefaults.set(screenshotIntervalMinutes, forKey: Keys.screenshotIntervalMinutes)
            notifySettingsChanged()
        }
    }

    @Published var analysisTimeMinutes: Int {
        didSet {
            let clamped = max(0, min(23 * 60 + 59, analysisTimeMinutes))
            if analysisTimeMinutes != clamped {
                analysisTimeMinutes = clamped
                return
            }
            userDefaults.set(analysisTimeMinutes, forKey: Keys.analysisTimeMinutes)
            notifySettingsChanged()
        }
    }

    @Published var analysisStartupMode: AnalysisStartupMode {
        didSet {
            userDefaults.set(analysisStartupMode.rawValue, forKey: Keys.analysisStartupMode)
            notifySettingsChanged()
        }
    }

    @Published var reportWeekStart: ReportWeekStart {
        didSet {
            userDefaults.set(reportWeekStart.rawValue, forKey: Keys.reportWeekStart)
            notifySettingsChanged()
        }
    }

    @Published var autoAnalysisRequiresCharger: Bool {
        didSet {
            userDefaults.set(autoAnalysisRequiresCharger, forKey: Keys.autoAnalysisRequiresCharger)
            notifySettingsChanged()
        }
    }

    @Published var appLanguage: AppLanguage {
        didSet {
            userDefaults.set(appLanguage.rawValue, forKey: AppLanguage.userDefaultsKey)
            normalizeCategoryRulesForCurrentLanguage()
            notifySettingsChanged()
        }
    }

    @Published var summaryInstruction: String {
        didSet {
            userDefaults.set(summaryInstruction, forKey: Keys.summaryInstruction)
            notifySettingsChanged()
        }
    }

    @Published var provider: ModelProvider {
        didSet {
            userDefaults.set(provider.rawValue, forKey: Keys.provider)
            let resolvedMethod = Self.resolvedImageAnalysisMethod(imageAnalysisMethod, for: provider)
            if imageAnalysisMethod != resolvedMethod {
                imageAnalysisMethod = resolvedMethod
            }
            notifySettingsChanged()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            userDefaults.set(apiBaseURL, forKey: Keys.apiBaseURL)
            notifySettingsChanged()
        }
    }

    @Published var modelName: String {
        didSet {
            userDefaults.set(modelName, forKey: Keys.modelName)
            notifySettingsChanged()
        }
    }

    @Published var apiKey: String {
        didSet {
            keychain.set(apiKey, for: AppDefaults.apiKeyAccount)
            notifySettingsChanged()
        }
    }

    @Published var lmStudioContextLength: Int {
        didSet {
            let clamped = max(4096, min(65536, lmStudioContextLength))
            if lmStudioContextLength != clamped {
                lmStudioContextLength = clamped
                return
            }
            userDefaults.set(lmStudioContextLength, forKey: Keys.lmStudioContextLength)
            notifySettingsChanged()
        }
    }

    @Published var imageAnalysisMethod: ImageAnalysisMethod {
        didSet {
            let resolved = Self.resolvedImageAnalysisMethod(imageAnalysisMethod, for: provider)
            if imageAnalysisMethod != resolved {
                imageAnalysisMethod = resolved
                return
            }
            userDefaults.set(imageAnalysisMethod.rawValue, forKey: Keys.imageAnalysisMethod)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryProvider: ModelProvider {
        didSet {
            userDefaults.set(workContentSummaryProvider.rawValue, forKey: Keys.workContentSummaryProvider)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryAPIBaseURL: String {
        didSet {
            userDefaults.set(workContentSummaryAPIBaseURL, forKey: Keys.workContentSummaryAPIBaseURL)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryModelName: String {
        didSet {
            userDefaults.set(workContentSummaryModelName, forKey: Keys.workContentSummaryModelName)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryAPIKey: String {
        didSet {
            keychain.set(workContentSummaryAPIKey, for: AppDefaults.workContentSummaryAPIKeyAccount)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryLMStudioContextLength: Int {
        didSet {
            let clamped = max(4096, min(65536, workContentSummaryLMStudioContextLength))
            if workContentSummaryLMStudioContextLength != clamped {
                workContentSummaryLMStudioContextLength = clamped
                return
            }
            userDefaults.set(workContentSummaryLMStudioContextLength, forKey: Keys.workContentSummaryLMStudioContextLength)
            notifySettingsChanged()
        }
    }

    @Published private(set) var categoryRules: [CategoryRule]
    @Published private(set) var categoryRulesValidationMessage: String?

    private let userDefaults: UserDefaults
    private let keychain: KeychainStore
    private let database: AppDatabase

    init(
        database: AppDatabase,
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStore
    ) {
        self.database = database
        self.userDefaults = userDefaults
        self.keychain = keychain

        let savedInterval = userDefaults.object(forKey: Keys.screenshotIntervalMinutes) as? Int ?? AppDefaults.screenshotIntervalMinutes
        let savedAnalysisTime = userDefaults.object(forKey: Keys.analysisTimeMinutes) as? Int ?? AppDefaults.analysisTimeMinutes
        let savedAnalysisStartupMode = AnalysisStartupMode(rawValue: userDefaults.string(forKey: Keys.analysisStartupMode) ?? "")
            ?? AppDefaults.analysisStartupMode
        let savedReportWeekStart = ReportWeekStart(rawValue: userDefaults.string(forKey: Keys.reportWeekStart) ?? "") ?? .sunday
        let savedAutoAnalysisRequiresCharger = userDefaults.object(forKey: Keys.autoAnalysisRequiresCharger) as? Bool ?? AppDefaults.autoAnalysisRequiresCharger
        let savedAppLanguage = AppLanguage(rawValue: userDefaults.string(forKey: AppLanguage.userDefaultsKey) ?? "") ?? .defaultValue
        let savedSummaryInstruction = userDefaults.string(forKey: Keys.summaryInstruction)
            ?? AppDefaults.defaultSummaryInstruction(language: savedAppLanguage)
        let savedProvider = Self.resolvedProvider(
            ModelProvider(rawValue: userDefaults.string(forKey: Keys.provider) ?? "") ?? .openAI,
            language: savedAppLanguage
        )
        let savedBaseURL = userDefaults.string(forKey: Keys.apiBaseURL) ?? ""
        let savedModelName = userDefaults.string(forKey: Keys.modelName) ?? ""
        let savedAPIKey = keychain.string(for: AppDefaults.apiKeyAccount)
        let savedLMStudioContextLength = userDefaults.object(forKey: Keys.lmStudioContextLength) as? Int ?? AppDefaults.lmStudioContextLength
        let savedImageAnalysisMethod = Self.resolvedImageAnalysisMethod(
            ImageAnalysisMethod(rawValue: userDefaults.string(forKey: Keys.imageAnalysisMethod) ?? "")
                ?? AppDefaults.defaultImageAnalysisMethod,
            for: savedProvider
        )
        let savedWorkContentSummaryProvider = Self.resolvedProvider(
            ModelProvider(rawValue: userDefaults.string(forKey: Keys.workContentSummaryProvider) ?? "") ?? savedProvider,
            language: savedAppLanguage
        )
        let savedWorkContentSummaryBaseURL = userDefaults.string(forKey: Keys.workContentSummaryAPIBaseURL) ?? savedBaseURL
        let savedWorkContentSummaryModelName = userDefaults.string(forKey: Keys.workContentSummaryModelName) ?? savedModelName
        let savedWorkContentSummaryAPIKey = keychain.string(for: AppDefaults.workContentSummaryAPIKeyAccount).isEmpty
            ? savedAPIKey
            : keychain.string(for: AppDefaults.workContentSummaryAPIKeyAccount)
        let savedWorkContentSummaryLMStudioContextLength = userDefaults.object(forKey: Keys.workContentSummaryLMStudioContextLength) as? Int ?? savedLMStudioContextLength
        let savedRules = (try? database.fetchCategoryRules()) ?? []

        screenshotIntervalMinutes = max(1, min(60, savedInterval))
        analysisTimeMinutes = max(0, min(23 * 60 + 59, savedAnalysisTime))
        analysisStartupMode = savedAnalysisStartupMode
        reportWeekStart = savedReportWeekStart
        autoAnalysisRequiresCharger = savedAutoAnalysisRequiresCharger
        appLanguage = savedAppLanguage
        summaryInstruction = savedSummaryInstruction
        provider = savedProvider
        apiBaseURL = savedBaseURL
        modelName = savedModelName
        apiKey = savedAPIKey
        lmStudioContextLength = max(4096, min(65536, savedLMStudioContextLength))
        imageAnalysisMethod = savedImageAnalysisMethod
        workContentSummaryProvider = savedWorkContentSummaryProvider
        workContentSummaryAPIBaseURL = savedWorkContentSummaryBaseURL
        workContentSummaryModelName = savedWorkContentSummaryModelName
        workContentSummaryAPIKey = savedWorkContentSummaryAPIKey
        workContentSummaryLMStudioContextLength = max(4096, min(65536, savedWorkContentSummaryLMStudioContextLength))
        let initialRules = savedRules.isEmpty ? AppDefaults.defaultCategoryRules(language: savedAppLanguage) : savedRules
        categoryRules = Self.normalizedCategoryRules(initialRules, language: savedAppLanguage)
        categoryRulesValidationMessage = nil
        userDefaults.set(analysisStartupMode.rawValue, forKey: Keys.analysisStartupMode)

        if savedRules.isEmpty || initialRules != categoryRules {
            try? database.replaceCategoryRules(categoryRules)
        }
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            screenshotIntervalMinutes: screenshotIntervalMinutes,
            analysisTimeMinutes: analysisTimeMinutes,
            analysisStartupMode: analysisStartupMode,
            autoAnalysisRequiresCharger: autoAnalysisRequiresCharger,
            appLanguage: appLanguage,
            summaryInstruction: summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshotAnalysisModelProfile: ModelProfileSettings(
                provider: provider,
                apiBaseURL: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                lmStudioContextLength: lmStudioContextLength,
                imageAnalysisMethod: imageAnalysisMethod
            ),
            workContentSummaryModelProfile: ModelProfileSettings(
                provider: workContentSummaryProvider,
                apiBaseURL: workContentSummaryAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: workContentSummaryModelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: workContentSummaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                lmStudioContextLength: workContentSummaryLMStudioContextLength,
                imageAnalysisMethod: .ocr
            ),
            categoryRules: categoryRules
        )
    }

    func addCategoryRule() {
        clearCategoryRulesValidationMessage()
        let insertIndex = max(categoryRules.count - 1, 0)
        categoryRules.insert(
            CategoryRule(colorHex: AppDefaults.categoryColorPreset(at: insertIndex)),
            at: insertIndex
        )
        saveCategoryRules()
    }

    func removeCategoryRule(id: UUID) {
        guard !isPreservedCategoryRule(id: id) else { return }
        clearCategoryRulesValidationMessage()
        categoryRules.removeAll { $0.id == id }
        saveCategoryRules()
    }

    func updateCategoryRuleName(id: UUID, name: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              !categoryRules[index].isPreservedOther else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.hasPrefix("PRESERVED_") {
            categoryRulesValidationMessage = L10n.string(.settingsAnalysisReservedPrefixError, language: appLanguage)
            return
        }
        categoryRules[index].name = name
        clearCategoryRulesValidationMessage()
        saveCategoryRules()
    }

    func updateCategoryRuleDescription(id: UUID, description: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }) else { return }
        categoryRules[index].description = description
        clearCategoryRulesValidationMessage()
        saveCategoryRules()
    }

    func updateCategoryRuleColor(id: UUID, colorHex: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              let normalizedColorHex = AppDefaults.normalizedCategoryColorHex(colorHex) else {
            return
        }
        categoryRules[index].colorHex = normalizedColorHex
        clearCategoryRulesValidationMessage()
        saveCategoryRules()
    }

    func moveCategoryRuleUp(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index > 0,
              !categoryRules[index].isPreservedOther else { return }
        clearCategoryRulesValidationMessage()
        categoryRules.swapAt(index, index - 1)
        saveCategoryRules()
    }

    func moveCategoryRuleDown(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index < max(categoryRules.count - 2, 0),
              !categoryRules[index].isPreservedOther else { return }
        clearCategoryRulesValidationMessage()
        categoryRules.swapAt(index, index + 1)
        saveCategoryRules()
    }

    func copyScreenshotAnalysisModelToWorkContentSummary() {
        workContentSummaryProvider = provider
        workContentSummaryAPIBaseURL = apiBaseURL
        workContentSummaryModelName = modelName
        workContentSummaryAPIKey = apiKey
        workContentSummaryLMStudioContextLength = lmStudioContextLength
    }

    func copyWorkContentSummaryModelToScreenshotAnalysis() {
        provider = workContentSummaryProvider
        apiBaseURL = workContentSummaryAPIBaseURL
        modelName = workContentSummaryModelName
        apiKey = workContentSummaryAPIKey
        lmStudioContextLength = workContentSummaryLMStudioContextLength
    }

    private func saveCategoryRules() {
        categoryRules = Self.normalizedCategoryRules(categoryRules, language: appLanguage)
        try? database.replaceCategoryRules(categoryRules)
        notifySettingsChanged()
    }

    private func normalizeCategoryRulesForCurrentLanguage() {
        let normalizedRules = Self.normalizedCategoryRules(categoryRules, language: appLanguage)
        guard normalizedRules != categoryRules else {
            return
        }
        categoryRules = normalizedRules
        try? database.replaceCategoryRules(categoryRules)
    }

    private func isPreservedCategoryRule(id: UUID) -> Bool {
        categoryRules.first(where: { $0.id == id })?.isPreservedOther == true
    }

    private func clearCategoryRulesValidationMessage() {
        categoryRulesValidationMessage = nil
    }

    private static func normalizedCategoryRules(_ rules: [CategoryRule], language: AppLanguage) -> [CategoryRule] {
        let preservedSource = rules.first { $0.isPreservedOther }
        let preservedDescription = preservedSource?
            .description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedColorHex = AppDefaults.normalizedCategoryColorHex(preservedSource?.colorHex)
            ?? AppDefaults.categoryColorPreset(at: 15)
        let editableRules = rules
            .filter { !$0.isPreservedOther }
            .enumerated()
            .map { index, rule in
                CategoryRule(
                    id: rule.id,
                    name: rule.name,
                    description: rule.description,
                    colorHex: AppDefaults.normalizedCategoryColorHex(rule.colorHex)
                        ?? AppDefaults.categoryColorPreset(at: index)
                )
            }
        let preservedRule = CategoryRule(
            name: AppDefaults.preservedOtherCategoryName,
            description: (preservedDescription?.isEmpty == false)
                ? preservedDescription!
                : AppDefaults.preservedOtherCategoryDescription(language: language),
            colorHex: preservedColorHex
        )
        return editableRules + [preservedRule]
    }

    private static func resolvedProvider(_ provider: ModelProvider, language: AppLanguage) -> ModelProvider {
        guard provider == .appleIntelligence else {
            return provider
        }

        return AppleIntelligenceSupport.currentStatus(for: language).isSelectable
            ? .appleIntelligence
            : .openAI
    }

    private static func resolvedImageAnalysisMethod(
        _ method: ImageAnalysisMethod,
        for provider: ModelProvider
    ) -> ImageAnalysisMethod {
        provider == .appleIntelligence ? .ocr : method
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }

    private enum Keys {
        static let screenshotIntervalMinutes = "settings.screenshotIntervalMinutes"
        static let analysisTimeMinutes = "settings.analysisTimeMinutes"
        static let analysisStartupMode = "settings.analysisStartupMode"
        static let reportWeekStart = "settings.reportWeekStart"
        static let autoAnalysisRequiresCharger = "settings.autoAnalysisRequiresCharger"
        static let summaryInstruction = "settings.summaryInstruction"
        static let provider = "settings.provider"
        static let apiBaseURL = "settings.apiBaseURL"
        static let modelName = "settings.modelName"
        static let lmStudioContextLength = "settings.lmStudioContextLength"
        static let imageAnalysisMethod = "settings.imageAnalysisMethod"
        static let workContentSummaryProvider = "settings.workContentSummary.provider"
        static let workContentSummaryAPIBaseURL = "settings.workContentSummary.apiBaseURL"
        static let workContentSummaryModelName = "settings.workContentSummary.modelName"
        static let workContentSummaryLMStudioContextLength = "settings.workContentSummary.lmStudioContextLength"
    }
}
