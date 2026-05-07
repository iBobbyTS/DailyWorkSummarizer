import Foundation
import Combine

struct SettingsPersistenceAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

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

    @Published var screenshotAutoDeletionRetention: ScreenshotAutoDeletionRetention {
        didSet {
            userDefaults.set(screenshotAutoDeletionRetention.rawValue, forKey: Keys.screenshotAutoDeletionRetention)
            notifySettingsChanged()
        }
    }

    @Published var screenshotStorageLocation: ScreenshotStorageLocation {
        didSet {
            userDefaults.set(screenshotStorageLocation.rawValue, forKey: Keys.screenshotStorageLocation)
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
            guard !isRollingBackScreenshotAPIKey else {
                return
            }

            let result = keychain.set(apiKey, for: AppDefaults.apiKeyAccount)
            guard result.isSuccess else {
                handleKeychainWriteFailure(
                    result,
                    profileName: L10n.string(.settingsTabScreenshotAnalysis, language: appLanguage)
                )
                isRollingBackScreenshotAPIKey = true
                apiKey = oldValue
                isRollingBackScreenshotAPIKey = false
                notifySettingsChanged()
                return
            }
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

    @Published var screenshotAnalysisLMStudioExplicitLoadUnloadModel: Bool {
        didSet {
            userDefaults.set(screenshotAnalysisLMStudioExplicitLoadUnloadModel, forKey: Keys.screenshotAnalysisLMStudioExplicitLoadUnloadModel)
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
            guard !isRollingBackWorkContentSummaryAPIKey else {
                return
            }

            let result = keychain.set(workContentSummaryAPIKey, for: AppDefaults.workContentSummaryAPIKeyAccount)
            guard result.isSuccess else {
                handleKeychainWriteFailure(
                    result,
                    profileName: L10n.string(.settingsTabWorkContentSummary, language: appLanguage)
                )
                isRollingBackWorkContentSummaryAPIKey = true
                workContentSummaryAPIKey = oldValue
                isRollingBackWorkContentSummaryAPIKey = false
                notifySettingsChanged()
                return
            }
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

    @Published var workContentSummaryLMStudioExplicitLoadUnloadModel: Bool {
        didSet {
            userDefaults.set(workContentSummaryLMStudioExplicitLoadUnloadModel, forKey: Keys.workContentSummaryLMStudioExplicitLoadUnloadModel)
            notifySettingsChanged()
        }
    }

    @Published var screenshotAnalysisMemoryCheckEnabled: Bool {
        didSet {
            userDefaults.set(screenshotAnalysisMemoryCheckEnabled, forKey: Keys.screenshotAnalysisMemoryCheckEnabled)
            notifySettingsChanged()
        }
    }

    @Published var screenshotAnalysisMemoryThresholdGB: Double {
        didSet {
            userDefaults.set(screenshotAnalysisMemoryThresholdGB, forKey: Keys.screenshotAnalysisMemoryThresholdGB)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryMemoryCheckEnabled: Bool {
        didSet {
            userDefaults.set(workContentSummaryMemoryCheckEnabled, forKey: Keys.workContentSummaryMemoryCheckEnabled)
            notifySettingsChanged()
        }
    }

    @Published var workContentSummaryMemoryThresholdGB: Double {
        didSet {
            userDefaults.set(workContentSummaryMemoryThresholdGB, forKey: Keys.workContentSummaryMemoryThresholdGB)
            notifySettingsChanged()
        }
    }

    @Published private(set) var categoryRules: [CategoryRule]
    @Published private(set) var categoryRulesValidationMessage: String?
    @Published private(set) var databaseEncryptionEnabled: Bool
    @Published var persistenceAlert: SettingsPersistenceAlert?

    private let userDefaults: UserDefaults
    private let keychain: KeychainStoring
    private let database: AppDatabase
    private let logStore: AppLogStore?
    private var isRollingBackScreenshotAPIKey = false
    private var isRollingBackWorkContentSummaryAPIKey = false

    init(
        database: AppDatabase,
        userDefaults: UserDefaults = .standard,
        keychain: KeychainStoring,
        logStore: AppLogStore? = nil
    ) {
        self.database = database
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.logStore = logStore

        func read<T>(key: String, fallback: @autoclosure () -> T) -> T {
            (userDefaults.object(forKey: key) as? T) ?? fallback()
        }

        func readString(key: String) -> String? {
            userDefaults.string(forKey: key)
        }

        let savedInterval: Int = read(key: Keys.screenshotIntervalMinutes, fallback: AppDefaults.screenshotIntervalMinutes)
        let savedAnalysisTime: Int = read(key: Keys.analysisTimeMinutes, fallback: AppDefaults.analysisTimeMinutes)
        let savedAnalysisStartupMode = AnalysisStartupMode(rawValue: readString(key: Keys.analysisStartupMode) ?? "")
            ?? AppDefaults.analysisStartupMode
        let savedReportWeekStart = ReportWeekStart(rawValue: readString(key: Keys.reportWeekStart) ?? "") ?? .sunday
        let savedAutoDeletionRetention = ScreenshotAutoDeletionRetention(rawValue: readString(key: Keys.screenshotAutoDeletionRetention) ?? "")
            ?? AppDefaults.screenshotAutoDeletionRetentionDays
        let savedScreenshotStorageLocation = ScreenshotStorageLocation(rawValue: readString(key: Keys.screenshotStorageLocation) ?? "")
            ?? .disk
        let savedAutoAnalysisRequiresCharger: Bool = read(key: Keys.autoAnalysisRequiresCharger, fallback: AppDefaults.autoAnalysisRequiresCharger)

        let savedAppLanguageRaw = userDefaults.string(forKey: AppLanguage.userDefaultsKey)
        let savedAppLanguage = AppLanguage(rawValue: savedAppLanguageRaw ?? "") ?? .defaultValue

        let savedSummaryInstruction = readString(key: Keys.summaryInstruction)
            ?? AppDefaults.defaultSummaryInstruction(language: savedAppLanguage)
        let savedProvider = Self.resolvedProvider(
            ModelProvider(rawValue: readString(key: Keys.provider) ?? "") ?? .openAI,
            language: savedAppLanguage
        )
        let savedBaseURL = readString(key: Keys.apiBaseURL) ?? ""
        let savedModelName = readString(key: Keys.modelName) ?? ""
        let savedAPIKey = keychain.string(for: AppDefaults.apiKeyAccount)
        let savedLMStudioContextLength: Int = read(key: Keys.lmStudioContextLength, fallback: AppDefaults.lmStudioContextLength)

        let savedScreenshotAnalysisLMStudioExplicitLoadUnloadModel: Bool = read(key: Keys.screenshotAnalysisLMStudioExplicitLoadUnloadModel, fallback: AppDefaults.lmStudioExplicitLoadUnloadModel)
        let savedScreenshotAnalysisMemoryCheckEnabled: Bool = read(key: Keys.screenshotAnalysisMemoryCheckEnabled, fallback: AppDefaults.memoryCheckEnabled)
        let savedScreenshotAnalysisMemoryThresholdGB: Double = read(key: Keys.screenshotAnalysisMemoryThresholdGB, fallback: AppDefaults.memoryThresholdGB)
        let savedImageAnalysisMethod = Self.resolvedImageAnalysisMethod(
            ImageAnalysisMethod(rawValue: readString(key: Keys.imageAnalysisMethod) ?? "")
                ?? AppDefaults.defaultImageAnalysisMethod,
            for: savedProvider
        )
        let savedWorkContentSummaryProvider = Self.resolvedProvider(
            ModelProvider(rawValue: readString(key: Keys.workContentSummaryProvider) ?? "") ?? .openAI,
            language: savedAppLanguage
        )
        let savedWorkContentSummaryBaseURL = readString(key: Keys.workContentSummaryAPIBaseURL) ?? ""
        let savedWorkContentSummaryModelName = readString(key: Keys.workContentSummaryModelName) ?? ""
        let savedWorkContentSummaryAPIKey = keychain.string(for: AppDefaults.workContentSummaryAPIKeyAccount)
        let savedWorkContentSummaryLMStudioContextLength: Int = read(key: Keys.workContentSummaryLMStudioContextLength, fallback: AppDefaults.lmStudioContextLength)
        let savedWorkContentSummaryLMStudioExplicitLoadUnloadModel: Bool = read(key: Keys.workContentSummaryLMStudioExplicitLoadUnloadModel, fallback: AppDefaults.lmStudioExplicitLoadUnloadModel)
        let savedWorkContentSummaryMemoryCheckEnabled: Bool = read(key: Keys.workContentSummaryMemoryCheckEnabled, fallback: AppDefaults.memoryCheckEnabled)
        let savedWorkContentSummaryMemoryThresholdGB: Double = read(key: Keys.workContentSummaryMemoryThresholdGB, fallback: AppDefaults.memoryThresholdGB)
        let savedDatabaseEncryptionEnabled = Self.databaseEncryptionEnabled(from: userDefaults)
        let savedRules: [CategoryRule]
        do {
            savedRules = try database.fetchCategoryRules()
        } catch {
            savedRules = []
            logStore?.addError(source: .settings, context: "Failed to load category rules", error: error)
        }

        screenshotIntervalMinutes = max(1, min(60, savedInterval))
        analysisTimeMinutes = max(0, min(23 * 60 + 59, savedAnalysisTime))
        analysisStartupMode = savedAnalysisStartupMode
        reportWeekStart = savedReportWeekStart
        screenshotAutoDeletionRetention = savedAutoDeletionRetention
        screenshotStorageLocation = savedScreenshotStorageLocation
        autoAnalysisRequiresCharger = savedAutoAnalysisRequiresCharger
        appLanguage = savedAppLanguage
        summaryInstruction = savedSummaryInstruction
        provider = savedProvider
        apiBaseURL = savedBaseURL
        modelName = savedModelName
        apiKey = savedAPIKey
        lmStudioContextLength = max(4096, min(65536, savedLMStudioContextLength))
        screenshotAnalysisLMStudioExplicitLoadUnloadModel = savedScreenshotAnalysisLMStudioExplicitLoadUnloadModel
        imageAnalysisMethod = savedImageAnalysisMethod
        workContentSummaryProvider = savedWorkContentSummaryProvider
        workContentSummaryAPIBaseURL = savedWorkContentSummaryBaseURL
        workContentSummaryModelName = savedWorkContentSummaryModelName
        workContentSummaryAPIKey = savedWorkContentSummaryAPIKey
        workContentSummaryLMStudioContextLength = max(4096, min(65536, savedWorkContentSummaryLMStudioContextLength))
        workContentSummaryLMStudioExplicitLoadUnloadModel = savedWorkContentSummaryLMStudioExplicitLoadUnloadModel
        screenshotAnalysisMemoryCheckEnabled = savedScreenshotAnalysisMemoryCheckEnabled
        screenshotAnalysisMemoryThresholdGB = savedScreenshotAnalysisMemoryThresholdGB
        workContentSummaryMemoryCheckEnabled = savedWorkContentSummaryMemoryCheckEnabled
        workContentSummaryMemoryThresholdGB = savedWorkContentSummaryMemoryThresholdGB
        databaseEncryptionEnabled = savedDatabaseEncryptionEnabled
        let initialRules = savedRules.isEmpty ? AppDefaults.defaultCategoryRules(language: savedAppLanguage) : savedRules
        categoryRules = Self.normalizedCategoryRules(initialRules, language: savedAppLanguage)
        categoryRulesValidationMessage = nil
        userDefaults.set(analysisStartupMode.rawValue, forKey: Keys.analysisStartupMode)
        userDefaults.set(screenshotAnalysisLMStudioExplicitLoadUnloadModel, forKey: Keys.screenshotAnalysisLMStudioExplicitLoadUnloadModel)
        userDefaults.set(workContentSummaryLMStudioExplicitLoadUnloadModel, forKey: Keys.workContentSummaryLMStudioExplicitLoadUnloadModel)
        userDefaults.set(databaseEncryptionEnabled, forKey: Keys.databaseEncryptionEnabled)

        if savedRules.isEmpty || initialRules != categoryRules {
            persistCategoryRules(categoryRules, context: "Failed to initialize category rules")
        }
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            screenshotIntervalMinutes: screenshotIntervalMinutes,
            screenshotStorageLocation: screenshotStorageLocation,
            analysisTimeMinutes: analysisTimeMinutes,
            analysisStartupMode: analysisStartupMode,
            autoAnalysisRequiresCharger: autoAnalysisRequiresCharger,
            appLanguage: appLanguage,
            summaryInstruction: summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
            screenshotAnalysisModelProfile: ModelProfileSettings(
                provider: provider,
                apiBaseURL: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: "",
                lmStudioContextLength: lmStudioContextLength,
                imageAnalysisMethod: imageAnalysisMethod,
                explicitLoadUnloadModel: screenshotAnalysisLMStudioExplicitLoadUnloadModel,
                memoryCheckEnabled: screenshotAnalysisMemoryCheckEnabled,
                memoryThresholdGB: screenshotAnalysisMemoryThresholdGB
            ),
            workContentSummaryModelProfile: ModelProfileSettings(
                provider: workContentSummaryProvider,
                apiBaseURL: workContentSummaryAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: workContentSummaryModelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: "",
                lmStudioContextLength: workContentSummaryLMStudioContextLength,
                imageAnalysisMethod: .ocr,
                explicitLoadUnloadModel: workContentSummaryLMStudioExplicitLoadUnloadModel,
                memoryCheckEnabled: workContentSummaryMemoryCheckEnabled,
                memoryThresholdGB: workContentSummaryMemoryThresholdGB
            ),
            categoryRules: categoryRules
        )
    }

    func addCategoryRule() {
        clearCategoryRulesValidationMessage()
        var updatedRules = categoryRules
        let insertIndex = max(categoryRules.count - 1, 0)
        updatedRules.insert(
            CategoryRule(colorHex: AppDefaults.nextCategoryColorHex(for: categoryRules)),
            at: insertIndex
        )
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func removeCategoryRule(id: UUID) {
        guard !isPreservedCategoryRule(id: id) else { return }
        clearCategoryRulesValidationMessage()
        var updatedRules = categoryRules
        updatedRules.removeAll { $0.id == id }
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func updateCategoryRuleName(id: UUID, name: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              !categoryRules[index].isPreservedOther else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.hasPrefix("PRESERVED_") {
            categoryRulesValidationMessage = L10n.string(.settingsAnalysisReservedPrefixError, language: appLanguage)
            return
        }
        var updatedRules = categoryRules
        updatedRules[index].name = name
        clearCategoryRulesValidationMessage()
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func updateCategoryRuleDescription(id: UUID, description: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }) else { return }
        var updatedRules = categoryRules
        updatedRules[index].description = description
        clearCategoryRulesValidationMessage()
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func updateCategoryRuleColor(id: UUID, colorHex: String) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              let normalizedColorHex = AppDefaults.normalizedCategoryColorHex(colorHex) else {
            return
        }
        var updatedRules = categoryRules
        updatedRules[index].colorHex = normalizedColorHex
        clearCategoryRulesValidationMessage()
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func moveCategoryRuleUp(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index > 0,
              !categoryRules[index].isPreservedOther else { return }
        clearCategoryRulesValidationMessage()
        var updatedRules = categoryRules
        updatedRules.swapAt(index, index - 1)
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func moveCategoryRuleDown(id: UUID) {
        guard let index = categoryRules.firstIndex(where: { $0.id == id }),
              index < max(categoryRules.count - 2, 0),
              !categoryRules[index].isPreservedOther else { return }
        clearCategoryRulesValidationMessage()
        var updatedRules = categoryRules
        updatedRules.swapAt(index, index + 1)
        saveCategoryRules(updatedRules, context: "Failed to save category rules")
    }

    func copyScreenshotAnalysisModelToWorkContentSummary() {
        workContentSummaryProvider = provider
        workContentSummaryAPIBaseURL = apiBaseURL
        workContentSummaryModelName = modelName
        workContentSummaryAPIKey = apiKey
        workContentSummaryLMStudioContextLength = lmStudioContextLength
        workContentSummaryLMStudioExplicitLoadUnloadModel = screenshotAnalysisLMStudioExplicitLoadUnloadModel
        workContentSummaryMemoryCheckEnabled = screenshotAnalysisMemoryCheckEnabled
        workContentSummaryMemoryThresholdGB = screenshotAnalysisMemoryThresholdGB
    }

    func copyWorkContentSummaryModelToScreenshotAnalysis() {
        provider = workContentSummaryProvider
        apiBaseURL = workContentSummaryAPIBaseURL
        modelName = workContentSummaryModelName
        apiKey = workContentSummaryAPIKey
        lmStudioContextLength = workContentSummaryLMStudioContextLength
        screenshotAnalysisLMStudioExplicitLoadUnloadModel = workContentSummaryLMStudioExplicitLoadUnloadModel
        screenshotAnalysisMemoryCheckEnabled = workContentSummaryMemoryCheckEnabled
        screenshotAnalysisMemoryThresholdGB = workContentSummaryMemoryThresholdGB
    }

    var databaseURL: URL {
        database.databaseURL
    }

    var currentDatabasePassphrase: String {
        switch keychain.readString(for: AppDefaults.databasePassphraseAccount) {
        case .success(_, let value):
            return value
        case .notFound:
            return ""
        case .failure(let account, let status):
            logStore?.addError(
                source: .settings,
                context: "Failed to read current database passphrase",
                error: KeychainReadError(result: .failure(account: account, status: status))
            )
            return ""
        }
    }

    func databasePassphraseCanBeUpdated(to value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedValue.isEmpty && trimmedValue != currentDatabasePassphrase
    }

    func generateDatabasePassphrase() throws -> DatabasePassphrase {
        try DatabasePassphrase.generate()
    }

    func disableDatabaseEncryption() throws {
        guard let currentPassphrase = try DatabasePassphraseStore(keychain: keychain).load() else {
            throw DatabaseError.missingPassphrase(database.databaseURL)
        }
        try database.decryptDatabase()
        let result = keychain.set("", for: AppDefaults.databasePassphraseAccount)
        guard result.isSuccess else {
            do {
                try database.encryptDatabase(passphrase: currentPassphrase)
            } catch {
                databaseEncryptionEnabled = false
                userDefaults.set(false, forKey: Keys.databaseEncryptionEnabled)
                notifySettingsChanged()
                throw DatabaseError.databaseStateRestoreFailed(
                    operation: "Disable database encryption",
                    originalError: DatabaseError.keychainWriteFailed(result).localizedDescription,
                    restoreError: error.localizedDescription
                )
            }
            throw DatabaseError.keychainWriteFailed(result)
        }
        databaseEncryptionEnabled = false
        userDefaults.set(false, forKey: Keys.databaseEncryptionEnabled)
        notifySettingsChanged()
    }

    func enableDatabaseEncryption(with passphrase: DatabasePassphrase) throws {
        do {
            try DatabasePassphraseStore(keychain: keychain).save(passphrase)
        } catch {
            throw error
        }
        do {
            try database.encryptDatabase(passphrase: passphrase)
        } catch {
            let keychainRestoreResult = keychain.set("", for: AppDefaults.databasePassphraseAccount)
            if !keychainRestoreResult.isSuccess {
                throw DatabaseError.databaseStateRestoreFailed(
                    operation: "Enable database encryption",
                    originalError: error.localizedDescription,
                    restoreError: DatabaseError.keychainWriteFailed(keychainRestoreResult).localizedDescription
                )
            }
            throw error
        }
        databaseEncryptionEnabled = true
        userDefaults.set(true, forKey: Keys.databaseEncryptionEnabled)
        notifySettingsChanged()
    }

    func updateDatabasePassphrase(to passphrase: DatabasePassphrase) throws {
        guard let currentPassphrase = try DatabasePassphraseStore(keychain: keychain).load() else {
            throw DatabaseError.missingPassphrase(database.databaseURL)
        }
        try database.changeDatabasePassphrase(to: passphrase)
        do {
            try DatabasePassphraseStore(keychain: keychain).save(passphrase)
        } catch {
            let originalError = error.localizedDescription
            do {
                try database.changeDatabasePassphrase(to: currentPassphrase)
            } catch {
                throw DatabaseError.databaseStateRestoreFailed(
                    operation: "Change database passphrase",
                    originalError: originalError,
                    restoreError: error.localizedDescription
                )
            }
            throw error
        }
        notifySettingsChanged()
    }

    static func databaseEncryptionEnabled(from userDefaults: UserDefaults) -> Bool {
        guard let value = userDefaults.object(forKey: Keys.databaseEncryptionEnabled) as? Bool else {
            return AppDefaults.databaseEncryptionEnabled
        }
        return value
    }

    private func saveCategoryRules(_ rules: [CategoryRule], context: String, notify: Bool = true) {
        let normalizedRules = Self.normalizedCategoryRules(rules, language: appLanguage)
        guard persistCategoryRules(normalizedRules, context: context, showAlert: true) else {
            return
        }
        categoryRules = normalizedRules
        if notify {
            notifySettingsChanged()
        }
    }

    private func normalizeCategoryRulesForCurrentLanguage() {
        let normalizedRules = Self.normalizedCategoryRules(categoryRules, language: appLanguage)
        guard normalizedRules != categoryRules else {
            return
        }
        saveCategoryRules(normalizedRules, context: "Failed to normalize category rules", notify: false)
    }

    @discardableResult
    private func persistCategoryRules(
        _ rules: [CategoryRule],
        context: String,
        showAlert: Bool = false
    ) -> Bool {
        do {
            try database.replaceCategoryRules(rules)
            return true
        } catch {
            logStore?.addError(source: .settings, context: context, error: error)
            if showAlert {
                showCategoryRulesPersistenceAlert(error)
            }
            return false
        }
    }

    private func showCategoryRulesPersistenceAlert(_ error: Error) {
        let errorMessage = CredentialSanitizer.sanitizeForError(error.localizedDescription)
        persistenceAlert = SettingsPersistenceAlert(
            title: L10n.string(.settingsCategoryRulesSaveFailedTitle, language: appLanguage),
            message: L10n.string(
                .settingsCategoryRulesSaveFailedMessage,
                language: appLanguage,
                arguments: [errorMessage]
            )
        )
    }

    private func handleKeychainWriteFailure(_ result: KeychainWriteResult, profileName: String) {
        let error = KeychainWriteError(result: result)
        logStore?.addError(source: .settings, context: "Failed to save API key for \(profileName)", error: error)
        persistenceAlert = SettingsPersistenceAlert(
            title: L10n.string(.settingsKeychainSaveFailedTitle, language: appLanguage),
            message: L10n.string(
                .settingsKeychainSaveFailedMessage,
                language: appLanguage,
                arguments: [profileName, result.statusDescription]
            )
        )
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
        private static let prefix = "com.deskbrief.settings."

        static let screenshotIntervalMinutes = prefix + "screenshotIntervalMinutes"
        static let analysisTimeMinutes = prefix + "analysisTimeMinutes"
        static let analysisStartupMode = prefix + "analysisStartupMode"
        static let reportWeekStart = prefix + "reportWeekStart"
        static let screenshotAutoDeletionRetention = prefix + "screenshotAutoDeletionRetention"
        static let screenshotStorageLocation = prefix + "screenshotStorageLocation"
        static let autoAnalysisRequiresCharger = prefix + "autoAnalysisRequiresCharger"
        static let summaryInstruction = prefix + "summaryInstruction"
        static let provider = prefix + "provider"
        static let apiBaseURL = prefix + "apiBaseURL"
        static let modelName = prefix + "modelName"
        static let lmStudioContextLength = prefix + "lmStudioContextLength"
        static let screenshotAnalysisLMStudioExplicitLoadUnloadModel = prefix + "screenshotAnalysis.lmStudioExplicitLoadUnloadModel"
        static let screenshotAnalysisMemoryCheckEnabled = prefix + "screenshotAnalysis.memoryCheckEnabled"
        static let screenshotAnalysisMemoryThresholdGB = prefix + "screenshotAnalysis.memoryThresholdGB"
        static let imageAnalysisMethod = prefix + "imageAnalysisMethod"
        static let workContentSummaryProvider = prefix + "workContentSummary.provider"
        static let workContentSummaryAPIBaseURL = prefix + "workContentSummary.apiBaseURL"
        static let workContentSummaryModelName = prefix + "workContentSummary.modelName"
        static let workContentSummaryLMStudioContextLength = prefix + "workContentSummary.lmStudioContextLength"
        static let workContentSummaryLMStudioExplicitLoadUnloadModel = prefix + "workContentSummary.lmStudioExplicitLoadUnloadModel"
        static let workContentSummaryMemoryCheckEnabled = prefix + "workContentSummary.memoryCheckEnabled"
        static let workContentSummaryMemoryThresholdGB = prefix + "workContentSummary.memoryThresholdGB"
        static let databaseEncryptionEnabled = prefix + "databaseEncryptionEnabled"
    }
}
