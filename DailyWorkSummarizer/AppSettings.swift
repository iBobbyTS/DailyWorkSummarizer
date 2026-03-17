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

    @Published private(set) var categoryRules: [CategoryRule]

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
        let savedProvider = ModelProvider(rawValue: userDefaults.string(forKey: Keys.provider) ?? "") ?? .openAI
        let savedBaseURL = userDefaults.string(forKey: Keys.apiBaseURL) ?? ""
        let savedModelName = userDefaults.string(forKey: Keys.modelName) ?? ""
        let savedAPIKey = keychain.string(for: AppDefaults.apiKeyAccount)
        let savedLMStudioContextLength = userDefaults.object(forKey: Keys.lmStudioContextLength) as? Int ?? AppDefaults.lmStudioContextLength
        let savedRules = (try? database.fetchCategoryRules()) ?? []

        screenshotIntervalMinutes = max(1, min(60, savedInterval))
        analysisTimeMinutes = max(0, min(23 * 60 + 59, savedAnalysisTime))
        automaticAnalysisEnabled = savedAutomaticAnalysisEnabled
        reportWeekStart = savedReportWeekStart
        autoAnalysisRequiresCharger = savedAutoAnalysisRequiresCharger
        appLanguage = savedAppLanguage
        provider = savedProvider
        apiBaseURL = savedBaseURL
        modelName = savedModelName
        apiKey = savedAPIKey
        lmStudioContextLength = max(4096, min(65536, savedLMStudioContextLength))
        categoryRules = savedRules.isEmpty ? AppDefaults.defaultCategoryRules(language: savedAppLanguage) : savedRules

        if savedRules.isEmpty {
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
            provider: provider,
            apiBaseURL: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            lmStudioContextLength: lmStudioContextLength,
            categoryRules: categoryRules
        )
    }

    func addCategoryRule() {
        categoryRules.append(CategoryRule())
        saveCategoryRules()
    }

    func removeCategoryRule(id: UUID) {
        categoryRules.removeAll { $0.id == id }
        if categoryRules.isEmpty {
            categoryRules = [CategoryRule()]
        }
        saveCategoryRules()
    }

    func updateCategoryRuleName(id: UUID, name: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }) else { return }
        categoryRules[index].name = name
        saveCategoryRules()
    }

    func updateCategoryRuleDescription(id: UUID, description: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }) else { return }
        categoryRules[index].description = description
        saveCategoryRules()
    }

    func moveCategoryRuleUp(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        categoryRules.swapAt(index, index - 1)
        saveCategoryRules()
    }

    func moveCategoryRuleDown(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index < categoryRules.count - 1 else { return }
        categoryRules.swapAt(index, index + 1)
        saveCategoryRules()
    }

    private func saveCategoryRules() {
        try? database.replaceCategoryRules(categoryRules)
        notifySettingsChanged()
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
        static let provider = "settings.provider"
        static let apiBaseURL = "settings.apiBaseURL"
        static let modelName = "settings.modelName"
        static let lmStudioContextLength = "settings.lmStudioContextLength"
    }
}
