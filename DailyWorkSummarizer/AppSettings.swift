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

    @Published var automaticAnalysisEnabled: Bool {
        didSet {
            userDefaults.set(automaticAnalysisEnabled, forKey: Keys.automaticAnalysisEnabled)
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

    @Published var analysisSummaryInstruction: String {
        didSet {
            userDefaults.set(analysisSummaryInstruction, forKey: Keys.analysisSummaryInstruction)
            notifySettingsChanged()
        }
    }

    @Published var provider: ModelProvider {
        didSet {
            userDefaults.set(provider.rawValue, forKey: Keys.provider)
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

    @Published var workContentProvider: ModelProvider {
        didSet {
            userDefaults.set(workContentProvider.rawValue, forKey: Keys.workContentProvider)
            notifySettingsChanged()
        }
    }

    @Published var workContentAPIBaseURL: String {
        didSet {
            userDefaults.set(workContentAPIBaseURL, forKey: Keys.workContentAPIBaseURL)
            notifySettingsChanged()
        }
    }

    @Published var workContentModelName: String {
        didSet {
            userDefaults.set(workContentModelName, forKey: Keys.workContentModelName)
            notifySettingsChanged()
        }
    }

    @Published var workContentAPIKey: String {
        didSet {
            keychain.set(workContentAPIKey, for: AppDefaults.workContentAPIKeyAccount)
            notifySettingsChanged()
        }
    }

    @Published var workContentLMStudioContextLength: Int {
        didSet {
            let clamped = max(4096, min(65536, workContentLMStudioContextLength))
            if workContentLMStudioContextLength != clamped {
                workContentLMStudioContextLength = clamped
                return
            }
            userDefaults.set(workContentLMStudioContextLength, forKey: Keys.workContentLMStudioContextLength)
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
        let savedAutomaticAnalysisEnabled = userDefaults.object(forKey: Keys.automaticAnalysisEnabled) as? Bool ?? AppDefaults.automaticAnalysisEnabled
        let savedReportWeekStart = ReportWeekStart(rawValue: userDefaults.string(forKey: Keys.reportWeekStart) ?? "") ?? .sunday
        let savedAutoAnalysisRequiresCharger = userDefaults.object(forKey: Keys.autoAnalysisRequiresCharger) as? Bool ?? AppDefaults.autoAnalysisRequiresCharger
        let savedAppLanguage = AppLanguage(rawValue: userDefaults.string(forKey: AppLanguage.userDefaultsKey) ?? "") ?? .defaultValue
        let savedAnalysisSummaryInstruction = userDefaults.string(forKey: Keys.analysisSummaryInstruction)
            ?? AppDefaults.defaultAnalysisSummaryInstruction(language: savedAppLanguage)
        let savedProvider = ModelProvider(rawValue: userDefaults.string(forKey: Keys.provider) ?? "") ?? .openAI
        let savedBaseURL = userDefaults.string(forKey: Keys.apiBaseURL) ?? ""
        let savedModelName = userDefaults.string(forKey: Keys.modelName) ?? ""
        let savedAPIKey = keychain.string(for: AppDefaults.apiKeyAccount)
        let savedLMStudioContextLength = userDefaults.object(forKey: Keys.lmStudioContextLength) as? Int ?? AppDefaults.lmStudioContextLength
        let savedWorkContentProvider = ModelProvider(rawValue: userDefaults.string(forKey: Keys.workContentProvider) ?? "") ?? savedProvider
        let savedWorkContentBaseURL = userDefaults.string(forKey: Keys.workContentAPIBaseURL) ?? savedBaseURL
        let savedWorkContentModelName = userDefaults.string(forKey: Keys.workContentModelName) ?? savedModelName
        let savedWorkContentAPIKey = keychain.string(for: AppDefaults.workContentAPIKeyAccount).isEmpty
            ? savedAPIKey
            : keychain.string(for: AppDefaults.workContentAPIKeyAccount)
        let savedWorkContentLMStudioContextLength = userDefaults.object(forKey: Keys.workContentLMStudioContextLength) as? Int ?? savedLMStudioContextLength
        let savedRules = (try? database.fetchCategoryRules()) ?? []

        screenshotIntervalMinutes = max(1, min(60, savedInterval))
        analysisTimeMinutes = max(0, min(23 * 60 + 59, savedAnalysisTime))
        automaticAnalysisEnabled = savedAutomaticAnalysisEnabled
        reportWeekStart = savedReportWeekStart
        autoAnalysisRequiresCharger = savedAutoAnalysisRequiresCharger
        appLanguage = savedAppLanguage
        analysisSummaryInstruction = savedAnalysisSummaryInstruction
        provider = savedProvider
        apiBaseURL = savedBaseURL
        modelName = savedModelName
        apiKey = savedAPIKey
        lmStudioContextLength = max(4096, min(65536, savedLMStudioContextLength))
        workContentProvider = savedWorkContentProvider
        workContentAPIBaseURL = savedWorkContentBaseURL
        workContentModelName = savedWorkContentModelName
        workContentAPIKey = savedWorkContentAPIKey
        workContentLMStudioContextLength = max(4096, min(65536, savedWorkContentLMStudioContextLength))
        let initialRules = savedRules.isEmpty ? AppDefaults.defaultCategoryRules(language: savedAppLanguage) : savedRules
        categoryRules = Self.normalizedCategoryRules(initialRules, language: savedAppLanguage)
        categoryRulesValidationMessage = nil

        if savedRules.isEmpty || initialRules != categoryRules {
            try? database.replaceCategoryRules(categoryRules)
        }
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            screenshotIntervalMinutes: screenshotIntervalMinutes,
            analysisTimeMinutes: analysisTimeMinutes,
            automaticAnalysisEnabled: automaticAnalysisEnabled,
            autoAnalysisRequiresCharger: autoAnalysisRequiresCharger,
            appLanguage: appLanguage,
            analysisSummaryInstruction: analysisSummaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshotAnalysisModelSettings: AnalysisModelSettings(
                provider: provider,
                apiBaseURL: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                lmStudioContextLength: lmStudioContextLength
            ),
            workContentAnalysisModelSettings: AnalysisModelSettings(
                provider: workContentProvider,
                apiBaseURL: workContentAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: workContentModelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: workContentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                lmStudioContextLength: workContentLMStudioContextLength
            ),
            categoryRules: categoryRules
        )
    }

    func addCategoryRule() {
        clearCategoryRulesValidationMessage()
        let insertIndex = max(categoryRules.count - 1, 0)
        categoryRules.insert(CategoryRule(), at: insertIndex)
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

    func copyScreenshotAnalysisModelToWorkContent() {
        workContentProvider = provider
        workContentAPIBaseURL = apiBaseURL
        workContentModelName = modelName
        workContentAPIKey = apiKey
        workContentLMStudioContextLength = lmStudioContextLength
    }

    func copyWorkContentModelToScreenshotAnalysis() {
        provider = workContentProvider
        apiBaseURL = workContentAPIBaseURL
        modelName = workContentModelName
        apiKey = workContentAPIKey
        lmStudioContextLength = workContentLMStudioContextLength
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
        let preservedDescription = rules
            .first(where: { $0.isPreservedOther })?
            .description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedRule = CategoryRule(
            name: AppDefaults.preservedOtherCategoryName,
            description: (preservedDescription?.isEmpty == false)
                ? preservedDescription!
                : AppDefaults.preservedOtherCategoryDescription(language: language)
        )
        let editableRules = rules.filter { !$0.isPreservedOther }
        return editableRules + [preservedRule]
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }

    private enum Keys {
        static let screenshotIntervalMinutes = "settings.screenshotIntervalMinutes"
        static let analysisTimeMinutes = "settings.analysisTimeMinutes"
        static let automaticAnalysisEnabled = "settings.automaticAnalysisEnabled"
        static let reportWeekStart = "settings.reportWeekStart"
        static let autoAnalysisRequiresCharger = "settings.autoAnalysisRequiresCharger"
        static let analysisSummaryInstruction = "settings.analysisSummaryInstruction"
        static let provider = "settings.provider"
        static let apiBaseURL = "settings.apiBaseURL"
        static let modelName = "settings.modelName"
        static let lmStudioContextLength = "settings.lmStudioContextLength"
        static let workContentProvider = "settings.workContent.provider"
        static let workContentAPIBaseURL = "settings.workContent.apiBaseURL"
        static let workContentModelName = "settings.workContent.modelName"
        static let workContentLMStudioContextLength = "settings.workContent.lmStudioContextLength"
    }
}
