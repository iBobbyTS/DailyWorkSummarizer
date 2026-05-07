import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let userDefaultsKey = "com.deskbrief.settings.appLanguage"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var localizedName: String {
        displayName(in: .current)
    }

    func displayName(in language: AppLanguage) -> String {
        switch self {
        case .simplifiedChinese:
            return language == .simplifiedChinese ? "简体中文" : "Simplified Chinese"
        case .english:
            return language == .simplifiedChinese ? "英文" : "English"
        }
    }

    static var current: AppLanguage {
        if let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        return defaultValue
    }

    static var defaultValue: AppLanguage {
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("zh") {
                return .simplifiedChinese
            }
            if identifier.hasPrefix("en") {
                return .english
            }
        }
        return .simplifiedChinese
    }
}

nonisolated enum L10n {
    enum Key: String {
        case settingsTabScreenshot
        case settingsTabModel
        case settingsTabAnalysis
        case settingsTabScreenshotAnalysis
        case settingsTabWorkContentSummary
        case settingsTabGeneral
        case settingsTabReport
        case settingsAnalysisStartupMode
        case analysisStartupModeManual
        case analysisStartupModeScheduled
        case analysisStartupModeRealtime
        case settingsAnalysisRequireCharger
        case settingsAnalysisScheduledTime
        case settingsScreenshotTesting
        case settingsScreenshotTest
        case settingsOpenAppLocation
        case settingsScreenshotOpenFolder
        case settingsScreenshotPreviewResult
        case settingsScreenshotInterval
        case settingsScreenshotMinutesPlaceholder
        case settingsScreenshotMinutesUnit
        case settingsModelTitle
        case settingsModelService
        case settingsModelBaseURL
        case settingsModelName
        case settingsModelNamePlaceholder
        case settingsModelAPIKey
        case settingsModelAPIKeyPlaceholder
        case settingsModelContextLength
        case settingsModelLMStudioExplicitLoadUnloadModel
        case settingsModelLMStudioExplicitLoadUnloadModelHelp
        case settingsModelImageAnalysisMethod
        case settingsModelOfficialUntested
        case settingsModelCategoriesTitle
        case settingsAnalysisCategoryTitle
        case settingsSummaryTitle
        case settingsSummaryHint
        case settingsSummaryPlaceholder
        case settingsAnalysisResultCategory
        case settingsResultSummary
        case settingsAnalysisReservedPrefixError
        case settingsModelCategoryColor
        case settingsModelCustomColor
        case settingsModelCategoryName
        case settingsModelCategoryDescription
        case settingsModelCategoryNameExample
        case settingsModelCategoryDescriptionExample
        case settingsCharacterLimitSuffix
        case settingsModelAddCategory
        case settingsModelTesting
        case settingsModelTest
        case settingsModelCopyPrompt
        case settingsModelCopyToWorkContentSummary
        case settingsModelCopyToScreenshotAnalysis
        case settingsModelCopyConfirmTitle
        case settingsModelCopyToWorkContentSummaryConfirmMessage
        case settingsModelCopyToScreenshotAnalysisConfirmMessage
        case settingsKeychainSaveFailedTitle
        case settingsKeychainSaveFailedMessage
        case settingsKeychainLoadFailedTitle
        case settingsKeychainLoadFailedMessage
        case settingsCategoryRulesSaveFailedTitle
        case settingsCategoryRulesSaveFailedMessage
        case commonConfirm
        case commonCancel
        case settingsModelTestResult
        case settingsModelWaitingForModel
        case settingsModelNoTempScreenshot
        case settingsModelTimingRequest
        case settingsModelTimingServerProcessing
        case settingsModelTimingModelLoad
        case settingsModelTimingTTFT
        case settingsModelTimingOutput
        case settingsModelTimingUnavailable
        case settingsModelOCRText
        case settingsModelOCRTextEmpty
        case settingsModelReasoningProcess
        case settingsGeneralTitle
        case settingsLanguage
        case settingsAutoDeletionRetention
        case settingsDatabaseSectionTitle
        case settingsDatabaseEncryption
        case settingsDatabasePassphrase
        case settingsDatabasePassphrasePlaceholder
        case settingsDatabasePassphraseConfirm
        case settingsDatabaseOpenLocation
        case settingsDatabaseDisableConfirmTitle
        case settingsDatabaseDisableConfirmMessage
        case settingsDatabaseDisableConfirmButton
        case settingsDatabaseEnableConfirmTitle
        case settingsDatabaseEnableConfirmMessage
        case settingsDatabasePassphraseUnsavedTitle
        case settingsDatabasePassphraseUnsavedMessage
        case settingsDatabasePassphraseContinueEditing
        case settingsDatabasePassphraseContinueClosing
        case settingsDatabaseBusyTitle
        case settingsDatabaseBusyMessage
        case settingsDatabaseOperationFailedTitle
        case autoDeletionRetentionOff
        case autoDeletionRetention7Days
        case autoDeletionRetention14Days
        case autoDeletionRetention28Days
        case settingsReportTitle
        case settingsReportWeekStart
        case settingsCountdown
        case appName
        case statusAccessibilityDescription
        case menuNoPending
        case menuOpenScreenshotsFolder
        case menuShowLogs
        case menuShowErrorsCount
        case menuAnalysisStartupMode
        case menuAnalyzeNowStart
        case menuAnalyzeNowPause
        case menuAnalyzeNowPausingStoppingGeneration
        case menuAnalyzeNowPausingUnloadingModel
        case menuStopCurrentSummary
        case menuStopCurrentSummaryStoppingGeneration
        case menuStopCurrentSummaryUnloadingModel
        case menuBackfillMissingSummaries
        case menuCurrentStatus
        case menuSettings
        case menuReports
        case menuClearEarlyScreenshots
        case menuClearEarlyScreenshotsOneDay
        case menuClearEarlyScreenshotsOneWeek
        case menuClearEarlyScreenshotsCalculating
        case menuClearEarlyScreenshotsEmpty
        case menuClearEarlyScreenshotsCount
        case menuClearEarlyScreenshotsCountSingular
        case menuClearEarlyScreenshotsFailed
        case menuClearEarlyScreenshotsConfirmTitle
        case menuClearEarlyScreenshotsConfirmMessage
        case menuQuit
        case windowSettings
        case windowReports
        case windowLogs
        case windowErrors
        case alertDatabaseInitFailed
        case alertDatabaseRecoveryTitle
        case alertDatabasePassphraseMissingMessage
        case alertDatabasePassphraseInvalidMessage
        case alertDatabaseEnterPassphrase
        case alertDatabaseDeleteDatabase
        case alertDatabaseQuit
        case alertDatabaseEnterPassphraseTitle
        case alertDatabaseEnterPassphraseMessage
        case alertDatabasePassphrasePlaceholder
        case alertDatabasePassphraseInvalidTitle
        case alertDatabasePassphraseInvalidRetryMessage
        case alertDatabasePassphraseSavedTitle
        case alertDatabasePassphraseSavedMessage
        case alertDatabaseDeleteConfirmTitle
        case alertDatabaseDeleteConfirmMessage
        case alertDatabaseDeletedTitle
        case alertDatabaseDeletedMessage
        case menuLastAverageDuration
        case menuSummaryPausingStoppingGeneration
        case menuSummaryPausingUnloadingModel
        case menuSummaryAnalyzing
        case menuCurrentStatusRunningScreenshotAnalysis
        case menuCurrentStatusRunningWorkContentSummary
        case menuCurrentStatusCurrentModel
        case menuCurrentStatusLoadingModel
        case menuCurrentStatusProgress
        case menuSummaryPending
        case menuNextScreenshotAt
        case menuForceUnloadScreenshotAnalysisModel
        case menuForceUnloadWorkContentSummaryModel
        case menuForceUnloadConfirmStopAnalysis
        case menuForceUnloadConfirmLifecycleDisabled
        case menuForceUnloadNoLoadedModel
        case menuForceUnloadFailedTitle
        case logsEmptyTitle
        case logsEmptyDescription
        case logsCopyAll
        case logsClearAll
        case logsLevelError
        case logsLevelLog
        case errorsEmptyTitle
        case errorsEmptyDescription
        case errorsClearAll
        case providerOpenAIUntested
        case providerAnthropicUntested
        case providerAppleIntelligence
        case providerAppleIntelligenceDeviceNotEligible
        case providerAppleIntelligenceNotEnabled
        case providerAppleIntelligenceModelNotReady
        case providerAppleIntelligenceUnsupportedLanguage
        case settingsAppleIntelligenceSupportedLanguages
        case settingsAppleIntelligenceOCROnly
        case imageAnalysisMethodOCR
        case imageAnalysisMethodMultimodal
        case screenshotScopeActiveDisplay
        case reportKindDay
        case reportKindWeek
        case reportKindMonth
        case reportKindYear
        case reportVisualizationBar
        case reportVisualizationHeatmap
        case reportWeekStartSunday
        case reportWeekStartMonday
        case absenceCategoryDisplay
        case preservedOtherCategoryDisplay
        case reportType
        case reportPreviousPage
        case reportNextPage
        case reportTotalDuration
        case reportAverageDuration
        case reportViewTitle
        case reportChartType
        case reportWorkdays
        case reportWeekends
        case reportOverlayDailyTime
        case reportNoDataTitle
        case reportNoDataDescription
        case reportCategoryAxis
        case reportTotalHoursAxis
        case reportSummarizeNow
        case reportSummarizing
        case reportDailySummaryTitle
        case reportTemporarySummary
        case reportHeatmapNoSelectedCategoriesTitle
        case reportHeatmapNoSelectedCategoriesDescription
        case reportHeatmapYesterday
        case reportHeatmapTomorrow
        case reportAbsenceSummaryPlaceholder
        case reportDailySummaryInvalidResponse
        case reportDailySummaryNoActivity
        case analysisHTTPError
        case analysisInvalidImageData
        case analysisNeedsCategoryRule
        case analysisNeedsBaseURL
        case analysisNeedsModelName
        case analysisScreenshotMissing
        case analysisCancelledByUser
        case analysisPausedAfterFailures
        case analysisPartialFailures
        case analysisInvalidCategory
        case analysisInvalidBaseURL
        case analysisInvalidHTTPResponse
        case analysisRetrySupplement
        case analysisLengthTruncated
        case analysisInvalidCategoryWithText
        case analysisInvalidStructuredResponseWithText
        case analysisAppleIntelligenceDecodingFailure
        case analysisUnderlyingDetailsHeader
        case analysisResponseUnavailable
        case analysisOpenAIFormatInvalid
        case analysisOpenAINoText
        case analysisAnthropicFormatInvalid
        case analysisAnthropicNoText
        case analysisLMStudioFormatInvalid
        case analysisLMStudioNoText
        case analysisNoResponseData
        case analysisAppleIntelligenceUnavailable
        case analysisAppleIntelligenceNoOCRTextSummary
        case analysisOCRNoTextSummary
        case screenshotPermissionDenied
        case screenshotPreviewUnreadable
        case screenshotCommandFailed
        case notificationAnalysisCompleteTitle
        case notificationAnalysisFailedTitle
        case notificationMemoryInsufficientTitle
        case notificationMemoryInsufficientBody
        case notificationBackfillCompleteTitle
        case notificationBackfillFailedTitle
        case notificationRealtimeBacklogTitle
        case notificationAnalysisCompleteNoReports
        case notificationAnalysisCompleteWithReports
        case notificationAnalysisPartialNoReports
        case notificationAnalysisPartialWithReports
        case notificationAnalysisSummaryFailedNoReports
        case notificationAnalysisSummaryFailedWithReports
        case notificationAnalysisFailedBody
        case notificationBackfillCompleteBody
        case notificationBackfillPartialBody
        case notificationBackfillFailedBody
        case notificationRealtimeBacklogBody
        case notificationDailyReportForDay
        case notificationScreenshotCount
        case notificationScreenshotCountSingular
        case notificationDailyReportCount
        case notificationDailyReportCountSingular
        case memoryCheckTitle
        case memoryTotalRam
        case memoryAvailableRam
        case memorySizeGiB
        case memoryUnitGiB
        case memoryThresholdTooltip
        case menuAnalysisRuns
        case windowAnalysisRuns
        case windowAnalysisRunsEmptyTitle
        case windowAnalysisRunsEmptyDescription
        case analysisRunsColumnTime
        case analysisRunsColumnModel
        case analysisRunsColumnStatus
        case analysisRunsColumnSuccess
        case analysisRunsColumnAnalysisDuration
        case analysisRunsColumnSummaryDuration
        case analysisRunsColumnAnalysisTokens
        case analysisRunsColumnSummaryTokens
        case analysisRunsColumnError
        case analysisRunsStatusSucceeded
        case analysisRunsStatusFailed
        case analysisRunsStatusCancelled
        case analysisRunsStatusPartial
        case analysisRunsStatusRunning
        case notificationWorkBlockSummaryCount
        case notificationWorkBlockSummaryCountSingular
        case settingsAnalysisStartupModeTooltip
        case settingsAnalysisScheduledTimeTooltip
        case settingsAnalysisChargerRequirementTooltip
        case settingsModelServiceTooltip
        case settingsModelImageAnalysisMethodTooltip
        case settingsModelBaseURLTooltip
        case settingsModelNameTooltip
        case settingsModelAPIKeyTooltip
        case settingsModelContextLengthTooltip
        case settingsModelLMStudioExplicitLoadUnloadModelTooltip
        case settingsIntervalTooltip
        case settingsLanguageTooltip
        case settingsAutoDeletionRetentionTooltip
        case settingsDatabaseEncryptionTooltip
        case settingsDatabasePassphraseTooltip
        case settingsReportWeekStartTooltip
        case modelMemoryError
        case lmStudioEndpointInvalid
        case lmStudioHTTPResponseInvalid
        case lmStudioNoData
        case settingsScreenshotStorageLocation
        case settingsScreenshotStorageLocationTooltip
        case lmStudioMissingLoadedInstanceID
    }

    private static let tables: [AppLanguage: [Key: String]] = [
        .simplifiedChinese: [
            .settingsTabScreenshot: "截屏",
            .settingsTabModel: "模型",
            .settingsTabAnalysis: "分析",
            .settingsTabScreenshotAnalysis: "截屏分析",
            .settingsTabWorkContentSummary: "工作内容总结",
            .settingsTabGeneral: "通用",
            .settingsTabReport: "报告",
            .settingsAnalysisStartupMode: "分析启动模式",
            .analysisStartupModeManual: "不自动启动",
            .analysisStartupModeScheduled: "定时启动",
            .analysisStartupModeRealtime: "截屏后立即启动",
            .settingsAnalysisRequireCharger: "仅在充电时自动启动分析",
            .settingsAnalysisScheduledTime: "定时分析时间",
            .settingsScreenshotTesting: "正在测试截屏…",
            .settingsScreenshotTest: "测试截屏",
            .settingsOpenAppLocation: "打开 App 位置",
            .settingsScreenshotOpenFolder: "打开截屏文件夹",
            .settingsScreenshotPreviewResult: "测试结果",
            .settingsScreenshotInterval: "截屏间隔",
            .settingsScreenshotMinutesPlaceholder: "分钟",
            .settingsScreenshotMinutesUnit: "分钟",
            .settingsModelTitle: "模型设置",
            .settingsModelService: "模型服务",
            .settingsModelBaseURL: "接口地址",
            .settingsModelName: "模型名称",
            .settingsModelNamePlaceholder: "请输入模型名称",
            .settingsModelAPIKey: "API 密钥",
            .settingsModelAPIKeyPlaceholder: "请输入 API Key（可留空）",
            .settingsModelContextLength: "上下文长度",
            .settingsModelLMStudioExplicitLoadUnloadModel: "主动装卸载模型",
            .settingsModelLMStudioExplicitLoadUnloadModelHelp: "App会在开始分析前后主动加载和卸载模型，如果使用的模型是始终保持在后台的，请关闭这个选项",
            .settingsModelImageAnalysisMethod: "图像分析方法",
            .settingsModelOfficialUntested: "官方 API 未经过测试",
            .settingsModelCategoriesTitle: "分析分类",
            .settingsAnalysisCategoryTitle: "类别",
            .settingsSummaryTitle: "总结",
            .settingsSummaryHint: "请描述你最近在做什么项目，方便模型进行更准确的归纳",
            .settingsSummaryPlaceholder: "注意观察画面里所打开项目的名称、课程名称等信息，进行简要描述",
            .settingsAnalysisResultCategory: "类别",
            .settingsResultSummary: "总结",
            .settingsAnalysisReservedPrefixError: "不允许使用 PRESERVED_ 开头的类别。",
            .settingsModelCategoryColor: "颜色",
            .settingsModelCustomColor: "自定义颜色",
            .settingsModelCategoryName: "类别名",
            .settingsModelCategoryDescription: "描述",
            .settingsModelCategoryNameExample: "例如：专注工作",
            .settingsModelCategoryDescriptionExample: "例如：正在编码、查资料或写文档",
            .settingsCharacterLimitSuffix: "（最多 %d 字符）",
            .settingsModelAddCategory: "添加分类",
            .settingsModelTesting: "正在测试模型…",
            .settingsModelTest: "测试模型",
            .settingsModelCopyPrompt: "复制 Prompt",
            .settingsModelCopyToWorkContentSummary: "复制到“工作内容总结”",
            .settingsModelCopyToScreenshotAnalysis: "复制到“截屏分析”",
            .settingsModelCopyConfirmTitle: "确认复制模型配置",
            .settingsModelCopyToWorkContentSummaryConfirmMessage: "确认后会覆盖“工作内容总结”里的模型配置。",
            .settingsModelCopyToScreenshotAnalysisConfirmMessage: "确认后会覆盖“截屏分析”里的模型配置。",
            .settingsKeychainSaveFailedTitle: "API Key 保存失败",
            .settingsKeychainSaveFailedMessage: "未能把“%@”的 API Key 写入 Keychain，设置已恢复为上一次保存的值。\n\n%@",
            .settingsKeychainLoadFailedTitle: "API Key 读取失败",
            .settingsKeychainLoadFailedMessage: "未能从 Keychain 读取“%@”的 API Key。DeskBrief 会暂时按未配置 API Key 处理；请在设置中重新保存这个密钥。\n\n%@",
            .settingsCategoryRulesSaveFailedTitle: "分类规则保存失败",
            .settingsCategoryRulesSaveFailedMessage: "未能保存分类规则，设置已恢复为上一次保存的值。\n\n%@",
            .commonConfirm: "确认",
            .commonCancel: "取消",
            .settingsModelTestResult: "测试结果",
            .settingsModelWaitingForModel: "正在分析，可能需要等待模型加载",
            .settingsModelNoTempScreenshot: "测试模型时未生成临时截屏",
            .settingsModelTimingRequest: "请求耗时",
            .settingsModelTimingServerProcessing: "服务端处理耗时",
            .settingsModelTimingModelLoad: "模型加载耗时",
            .settingsModelTimingTTFT: "首 Token 耗时",
            .settingsModelTimingOutput: "输出耗时",
            .settingsModelTimingUnavailable: "未返回（模型可能已预加载）",
            .settingsModelOCRText: "OCR 内容",
            .settingsModelOCRTextEmpty: "未识别到文字",
            .settingsModelReasoningProcess: "思考过程",
            .settingsGeneralTitle: "通用设置",
            .settingsLanguage: "语言",
            .settingsAutoDeletionRetention: "自动删除截屏",
            .settingsDatabaseSectionTitle: "数据库设置",
            .settingsDatabaseEncryption: "数据库加密",
            .settingsDatabasePassphrase: "修改数据库密钥",
            .settingsDatabasePassphrasePlaceholder: "输入新密钥",
            .settingsDatabasePassphraseConfirm: "确定",
            .settingsDatabaseOpenLocation: "打开数据库位置",
            .settingsDatabaseDisableConfirmTitle: "是否继续关闭密码",
            .settingsDatabaseDisableConfirmMessage: "关闭后，数据库将可被直接读取其中的数据，数据库密钥会从 macOS Keychain 中删除。",
            .settingsDatabaseDisableConfirmButton: "继续关闭密码",
            .settingsDatabaseEnableConfirmTitle: "确认数据库密钥",
            .settingsDatabaseEnableConfirmMessage: "即将对数据库进行加密。数据库密钥不会在 App 内显示，之后可在钥匙串 app 里查看。",
            .settingsDatabasePassphraseUnsavedTitle: "数据库密钥尚未更新，是否继续关闭",
            .settingsDatabasePassphraseUnsavedMessage: "关闭设置窗口会丢弃当前输入的新数据库密钥。",
            .settingsDatabasePassphraseContinueEditing: "继续编辑",
            .settingsDatabasePassphraseContinueClosing: "继续关闭（不保存）",
            .settingsDatabaseBusyTitle: "暂时无法修改数据库加密",
            .settingsDatabaseBusyMessage: "当前正在分析或总结。请等待当前任务结束后再修改数据库加密设置。",
            .settingsDatabaseOperationFailedTitle: "数据库加密操作失败",
            .autoDeletionRetentionOff: "关闭",
            .autoDeletionRetention7Days: "7 天",
            .autoDeletionRetention14Days: "14 天",
            .autoDeletionRetention28Days: "28 天",
            .settingsReportTitle: "报告设置",
            .settingsReportWeekStart: "一周的第一天",
            .settingsCountdown: "倒计时：%d秒",
            .appName: "工迹",
            .statusAccessibilityDescription: "工迹",
            .menuNoPending: "当前没有待分析的截屏",
            .menuOpenScreenshotsFolder: "打开截屏文件夹",
            .menuShowLogs: "显示日志",
            .menuShowErrorsCount: "显示%d个错误",
            .menuAnalysisStartupMode: "分析启动模式",
            .menuAnalyzeNowStart: "立即分析",
            .menuAnalyzeNowPause: "停止本次分析",
            .menuAnalyzeNowPausingStoppingGeneration: "正在停止本次分析（正在停止生成）",
            .menuAnalyzeNowPausingUnloadingModel: "正在停止本次分析（正在卸载模型）",
            .menuStopCurrentSummary: "停止本次总结",
            .menuStopCurrentSummaryStoppingGeneration: "正在停止本次总结（正在停止生成）",
            .menuStopCurrentSummaryUnloadingModel: "正在停止本次总结（正在卸载模型）",
            .menuBackfillMissingSummaries: "检查并补充过去遗漏的总结",
            .menuCurrentStatus: "当前状态",
            .menuSettings: "设置",
            .menuReports: "查看报告",
            .menuCurrentStatusRunningScreenshotAnalysis: "正在进行：截屏分析",
            .menuCurrentStatusRunningWorkContentSummary: "正在进行：工作内容总结",
            .menuCurrentStatusCurrentModel: "当前加载模型：%@",
            .menuCurrentStatusLoadingModel: "正在加载模型：%@",
            .menuCurrentStatusProgress: "进度：%d%%",
            .menuClearEarlyScreenshots: "清除早期截屏",
            .menuClearEarlyScreenshotsOneDay: "一天以前",
            .menuClearEarlyScreenshotsOneWeek: "一周以前",
            .menuClearEarlyScreenshotsCalculating: "%@（计算中）",
            .menuClearEarlyScreenshotsEmpty: "%@（无截屏）",
            .menuClearEarlyScreenshotsCount: "%@（%d张）",
            .menuClearEarlyScreenshotsCountSingular: "%@（%d张）",
            .menuClearEarlyScreenshotsFailed: "%@（计算失败）",
            .menuClearEarlyScreenshotsConfirmTitle: "确认清除早期截屏",
            .menuClearEarlyScreenshotsConfirmMessage: "将删除%@的 %d 张待分析截屏。此操作不可撤销。",
            .menuQuit: "退出",
            .windowSettings: "设置",
            .windowReports: "查看报告",
            .windowLogs: "查看日志",
            .windowErrors: "查看错误",
            .alertDatabaseInitFailed: "初始化数据库失败",
            .alertDatabaseRecoveryTitle: "无法打开加密数据库",
            .alertDatabasePassphraseMissingMessage: "数据库已经加密，但 Keychain 中没有找到数据库密钥。你可以手动输入密钥，或删除数据库并创建一个新的空数据库。",
            .alertDatabasePassphraseInvalidMessage: "数据库密钥可能不匹配，或数据库文件无法读取。你可以重新输入密钥；如果仍然失败，请先备份数据库文件，再决定是否删除数据库并创建一个新的空数据库。",
            .alertDatabaseEnterPassphrase: "输入密钥",
            .alertDatabaseDeleteDatabase: "删除数据库",
            .alertDatabaseQuit: "退出",
            .alertDatabaseEnterPassphraseTitle: "输入数据库密钥",
            .alertDatabaseEnterPassphraseMessage: "请输入用于打开 DeskBrief 加密数据库的密钥。密钥正确后会保存到 Keychain。",
            .alertDatabasePassphrasePlaceholder: "数据库密钥",
            .alertDatabasePassphraseInvalidTitle: "无法打开加密数据库",
            .alertDatabasePassphraseInvalidRetryMessage: "无法使用这个密钥打开数据库。请确认密钥是否完整，然后重试。\n\n%@",
            .alertDatabasePassphraseSavedTitle: "数据库已解锁",
            .alertDatabasePassphraseSavedMessage: "密钥已保存到 Keychain，DeskBrief 将继续启动。",
            .alertDatabaseDeleteConfirmTitle: "确认删除数据库",
            .alertDatabaseDeleteConfirmMessage: "将删除 DeskBrief 数据库文件并创建新的空数据库。截屏文件夹会保留，但已有报告、日志和分析记录会从应用中清空。此操作不可撤销。",
            .alertDatabaseDeletedTitle: "数据库已删除",
            .alertDatabaseDeletedMessage: "DeskBrief 已创建新的空加密数据库，截屏文件夹已保留。",
            .menuLastAverageDuration: "上次分析平均每张耗时%@秒",
            .menuSummaryPausingStoppingGeneration: "正在停止本次分析，从 %@ 开始的截屏分析（正在停止生成，%d/%d）",
            .menuSummaryPausingUnloadingModel: "正在停止本次分析，从 %@ 开始的截屏分析（正在卸载模型，%d/%d）",
            .menuSummaryAnalyzing: "正在分析从 %@ 开始的截屏（%d/%d）",
            .menuSummaryPending: "当前截屏从 %@ 开始，共 %d 张",
            .menuNextScreenshotAt: "下一次会在%@进行截屏",
            .menuForceUnloadScreenshotAnalysisModel: "强制卸载截屏分析模型",
            .menuForceUnloadWorkContentSummaryModel: "强制卸载工作内容总结模型",
            .menuForceUnloadConfirmStopAnalysis: "是否停止本次分析",
            .menuForceUnloadConfirmLifecycleDisabled: "根据当前设置，模型装卸载不由%@管理，是否仍要发起卸载请求？",
            .menuForceUnloadNoLoadedModel: "未找到匹配的已加载模型，已跳过卸载。",
            .menuForceUnloadFailedTitle: "强制卸载模型失败",
            .logsEmptyTitle: "当前没有日志",
            .logsEmptyDescription: "这里会显示分析错误，以及后续模型调试日志。",
            .logsCopyAll: "全部复制",
            .logsClearAll: "清空所有日志",
            .logsLevelError: "错误",
            .logsLevelLog: "日志",
            .errorsEmptyTitle: "当前没有错误",
            .errorsEmptyDescription: "后续分析出错时，会在这里显示最新的大模型返回错误。",
            .errorsClearAll: "清空所有错误",
            .providerOpenAIUntested: "OpenAI（未测试）",
            .providerAnthropicUntested: "Anthropic（未测试）",
            .providerAppleIntelligence: "Apple Intelligence",
            .providerAppleIntelligenceDeviceNotEligible: "设备不支持",
            .providerAppleIntelligenceNotEnabled: "未启用",
            .providerAppleIntelligenceModelNotReady: "模型未就绪",
            .providerAppleIntelligenceUnsupportedLanguage: "不支持%@",
            .settingsAppleIntelligenceSupportedLanguages: "Apple Intelligence 仅支持 %@ 语言。",
            .settingsAppleIntelligenceOCROnly: "Apple Intelligence 不支持图像理解，仅支持 OCR 后分析文字。",
            .imageAnalysisMethodOCR: "OCR（大模型仅做语言分析）",
            .imageAnalysisMethodMultimodal: "多模态（使用包含视觉能力的大模型）",
            .screenshotScopeActiveDisplay: "当前活跃的屏幕",
            .reportKindDay: "日报",
            .reportKindWeek: "周报",
            .reportKindMonth: "月报",
            .reportKindYear: "年报",
            .reportVisualizationBar: "柱状图",
            .reportVisualizationHeatmap: "热力图",
            .reportWeekStartSunday: "周日",
            .reportWeekStartMonday: "周一",
            .absenceCategoryDisplay: "离开",
            .preservedOtherCategoryDisplay: "其他",
            .reportType: "报告类型",
            .reportPreviousPage: "上一页",
            .reportNextPage: "下一页",
            .reportTotalDuration: "累计 %@",
            .reportAverageDuration: "日均 %@",
            .reportViewTitle: "查看报告",
            .reportChartType: "图表类型",
            .reportWorkdays: "工作日",
            .reportWeekends: "周末",
            .reportOverlayDailyTime: "叠加每日时间",
            .reportNoDataTitle: "暂无报告数据",
            .reportNoDataDescription: "当前时间范围没有符合筛选条件的记录。",
            .reportCategoryAxis: "分类",
            .reportTotalHoursAxis: "累计小时",
            .reportSummarizeNow: "立即总结",
            .reportSummarizing: "总结中…",
            .reportDailySummaryTitle: "日报总结",
            .reportTemporarySummary: "临时总结",
            .reportHeatmapNoSelectedCategoriesTitle: "未选择分类",
            .reportHeatmapNoSelectedCategoriesDescription: "请选择至少一个分类后再查看热力图。",
            .reportHeatmapYesterday: "昨天",
            .reportHeatmapTomorrow: "明天",
            .reportAbsenceSummaryPlaceholder: "该时间段没有截屏，用户离开了工位或未在电脑前活动。",
            .reportDailySummaryInvalidResponse: "模型返回无法解析为有效的日报 JSON 总结结果",
            .reportDailySummaryNoActivity: "当天没有可用于总结的活动记录",
            .analysisHTTPError: "接口返回错误 (%d)：%@",
            .analysisInvalidImageData: "截图文件已损坏或不是可识别的图片",
            .analysisNeedsCategoryRule: "至少需要配置一条有效的分析类别和描述",
            .analysisNeedsBaseURL: "请先配置模型接口地址",
            .analysisNeedsModelName: "请先配置模型名称",
            .analysisScreenshotMissing: "截屏文件不存在，无法继续分析",
            .analysisCancelledByUser: "用户手动停止本次分析",
            .analysisPausedAfterFailures: "连续 5 张截屏处理失败，已暂停当前分析",
            .analysisPartialFailures: "部分截屏分析失败，请检查网络、模型接口或返回格式",
            .analysisInvalidCategory: "模型返回无法解析为有效的 JSON 分析结果",
            .analysisInvalidBaseURL: "模型接口地址不合法",
            .analysisInvalidHTTPResponse: "模型接口没有返回有效的 HTTP 响应",
            .analysisRetrySupplement: "补充要求：直接输出完整 JSON，不要过度思考",
            .analysisLengthTruncated: "模型输出因长度截断，未能生成完整的 JSON 分析结果",
            .analysisInvalidCategoryWithText: "模型返回无法解析为有效的 JSON 分析结果",
            .analysisInvalidStructuredResponseWithText: "模型返回不符合预期的结构化分析结果",
            .analysisAppleIntelligenceDecodingFailure: "Apple Intelligence 返回的结构化结果无法完成解析",
            .analysisUnderlyingDetailsHeader: "底层错误详情：",
            .analysisResponseUnavailable: "未捕获到模型返回内容",
            .analysisOpenAIFormatInvalid: "OpenAI 兼容接口返回格式不正确",
            .analysisOpenAINoText: "OpenAI 兼容接口没有返回可读文本",
            .analysisAnthropicFormatInvalid: "Anthropic 兼容接口返回格式不正确",
            .analysisAnthropicNoText: "Anthropic 兼容接口没有返回可读文本",
            .analysisLMStudioFormatInvalid: "LM Studio API 返回格式不正确",
            .analysisLMStudioNoText: "LM Studio API 没有返回可读文本",
            .analysisNoResponseData: "模型接口没有返回数据",
            .analysisAppleIntelligenceUnavailable: "Apple Intelligence 当前不可用：%@",
            .analysisAppleIntelligenceNoOCRTextSummary: "截屏中未识别到足够文字，已按 OCR 结果为空处理。",
            .analysisOCRNoTextSummary: "截屏中未识别到足够文字，已按 OCR 结果为空处理。",
            .screenshotPermissionDenied: "没有获得屏幕录制权限",
            .screenshotPreviewUnreadable: "测试截屏完成，但无法读取预览图像",
            .screenshotCommandFailed: "系统 screencapture 命令执行失败",
            .notificationAnalysisCompleteTitle: "分析完成",
            .notificationAnalysisFailedTitle: "分析失败",
            .notificationMemoryInsufficientTitle: "内存不足",
            .notificationMemoryInsufficientBody: "取消执行%@，当前可用内存%@GiB，少于设置的%@GiB下限",
            .notificationBackfillCompleteTitle: "补漏完成",
            .notificationBackfillFailedTitle: "补漏失败",
            .notificationRealtimeBacklogTitle: "实时分析可能在积压",
            .notificationAnalysisCompleteNoReports: "已分析 %@。",
            .notificationAnalysisCompleteWithReports: "已分析 %@，并生成 %@。",
            .notificationAnalysisPartialNoReports: "已分析 %@，%@失败。请进入日志查看详情。",
            .notificationAnalysisPartialWithReports: "已分析 %@，%@失败，并生成 %@。请进入日志查看详情。",
            .notificationAnalysisSummaryFailedNoReports: "已分析 %@，但日报生成失败。请进入日志查看详情。",
            .notificationAnalysisSummaryFailedWithReports: "已分析 %@，并生成 %@，但部分日报生成失败。请进入日志查看详情。",
            .notificationAnalysisFailedBody: "本次分析运行失败，%@失败。请进入日志查看详情。",
            .notificationBackfillCompleteBody: "已补充 %@，%@。",
            .notificationBackfillPartialBody: "已补充 %@，%@。部分项目失败，请进入日志查看详情。",
            .notificationBackfillFailedBody: "补漏运行失败，请进入日志查看详情。",
            .notificationRealtimeBacklogBody: "当前有 %@待分析，比上次检查多 %@。",
            .notificationDailyReportForDay: "%@ 的日报",
            .notificationScreenshotCount: "%d 张截屏",
            .notificationScreenshotCountSingular: "%d 张截屏",
            .notificationDailyReportCount: "%d 个日报",
            .notificationDailyReportCountSingular: "%d 个日报",
            .memoryCheckTitle: "加载模型前进行可用内存检查",
            .memoryTotalRam: "总内存：",
            .memoryAvailableRam: "当前可用内存：",
            .memorySizeGiB: "%@ GiB",
            .memoryUnitGiB: "GiB",
            .memoryThresholdTooltip: "系统可用内存低于此阈值时不会加载模型",
            .menuAnalysisRuns: "分析记录",
            .windowAnalysisRuns: "分析记录",
            .windowAnalysisRunsEmptyTitle: "暂无分析记录",
            .windowAnalysisRunsEmptyDescription: "完成截屏分析后，会在这里显示运行记录。",
            .analysisRunsColumnTime: "时间",
            .analysisRunsColumnModel: "模型",
            .analysisRunsColumnStatus: "状态",
            .analysisRunsColumnSuccess: "成功/失败",
            .analysisRunsColumnAnalysisDuration: "平均分析耗时",
            .analysisRunsColumnSummaryDuration: "平均总结耗时",
            .analysisRunsColumnAnalysisTokens: "分析Token\n平均/最大",
            .analysisRunsColumnSummaryTokens: "总结Token\n平均/最大",
            .analysisRunsColumnError: "错误信息",
            .analysisRunsStatusSucceeded: "成功",
            .analysisRunsStatusFailed: "失败",
            .analysisRunsStatusCancelled: "已取消",
            .analysisRunsStatusPartial: "部分失败",
            .analysisRunsStatusRunning: "运行中",
            .notificationWorkBlockSummaryCount: "%d 个工作块总结",
            .notificationWorkBlockSummaryCountSingular: "%d 个工作块总结",
            .settingsAnalysisStartupModeTooltip: "软件提供3种启动截屏分析的模式：\n1. *不自动启动*：必须点开 菜单栏图标-当前状态-立即分析 来启动。\n2. *定时启动*：如果电脑晚上通常不睡眠，建议选择这一项。\n3. *截屏后立即启动*：适合使用远程大模型服务，或者有一个专门运行大模型的电脑/服务器（包含本机）常驻运行大模型。",
            .settingsAnalysisScheduledTimeTooltip: "当\"分析启动模式\"设置为\"*定时启动*\"时，会在这个时间分析所有存着的截屏。",
            .settingsAnalysisChargerRequirementTooltip: "当\"分析启动模式\"设置为\"*定时启动*\"或\"*截屏后立即启动*\"时，只有在连接电源适配器时，才会触发分析。如果笔记本电脑在本地运行大模型，建议开启。\n注：如果充电器功率小于电脑能耗，系统也会认为正在充电。",
            .settingsModelServiceTooltip: "Anthropic尚未测试。*LM Studio*已经过详细测试，Ollama等其他提供商建议使用*OpenAI*格式。Apple Intelligence目前质量非常差，不建议使用。",
            .settingsModelImageAnalysisMethodTooltip: "优先使用*多模态*，即原生支持图像理解的语言模型，如千问3.5、Gemma 4等；*OCR*是进行文字识别后再使用语言模型进行分析，文字识别适用于Apple Intelligence",
            .settingsModelBaseURLTooltip: "例：http://localhost:1234, https://api.deepseek.com\n不要包含/v1等后缀，也不要包含/",
            .settingsModelNameTooltip: "例：google/gemma-4-26b-a4b, deepseek-v4-flash",
            .settingsModelAPIKeyTooltip: "可留空（如本地模型服务）",
            .settingsModelContextLengthTooltip: "截屏分析不建议超过6000，总结可以更长。",
            .settingsModelLMStudioExplicitLoadUnloadModelTooltip: "目前仅支持LM Studio，打开后App会在截屏分析、工作内容总结前后发起加载、卸载请求。通常打开此选项配合*定时启动*，适合运行在工作电脑上；关闭此选项配合*截屏后立即启动*，适合专门的大模型电脑/服务器。",
            .settingsIntervalTooltip: "建议**10分钟**。\n启动软件时开始计时，退出软件暂停，软件本身不提供暂停功能。",
            .settingsScreenshotStorageLocation: "截屏保存位置",
            .settingsScreenshotStorageLocationTooltip: "保存到*硬盘*时安全级别和其他用户文件一致，别的用户无法直接访问，如果对隐私要求较高，可选择保存到内存，app退出/系统重启等操作会导致没有分析过的截屏直接消失",
            .settingsLanguageTooltip: "建议选择和截屏分析、工作内容总结填入的信息相同的语言",
            .settingsAutoDeletionRetentionTooltip: "自动删除超过保留期限的待分析截屏文件。保留期删除仅处理 screenshots 根目录下的 JPEG 文件；App 启动时会清理 preview/ 和 temp/ 子目录中的残留临时截屏。",
            .settingsDatabaseEncryptionTooltip: "*关闭*：别的app只要可以读取这个文件，就可以读取数据。\n*开启*：别的app必须输入密钥才能读取其中的数据，您可随时在app内修改，也可在钥匙串里查看。\n密钥会在苹果Keychain里安全存储，每次打开app时自动解密数据库。",
            .settingsDatabasePassphraseTooltip: "输入新的数据库密钥后点击确定。当前密钥不会在 App 内显示，可在钥匙串 app 里查看。",
            .settingsReportWeekStartTooltip: "仅用于周报。",
            .modelMemoryError: "可用内存不足：已要求 %.0f GiB，当前可用 %.1f GiB",
            .lmStudioEndpointInvalid: "LM Studio 模型管理接口地址无效。",
            .lmStudioHTTPResponseInvalid: "LM Studio 模型管理未返回有效的 HTTP 响应。",
            .lmStudioNoData: "LM Studio 模型管理未返回数据。",
            .lmStudioMissingLoadedInstanceID: "LM Studio 未返回或未暴露模型 %@ 的已加载实例。",
        ],
        .english: [
            .settingsTabScreenshot: "Screenshot",
            .settingsTabModel: "Model",
            .settingsTabAnalysis: "Analysis",
            .settingsTabScreenshotAnalysis: "Screenshot Analysis",
            .settingsTabWorkContentSummary: "Work Content Summary",
            .settingsTabGeneral: "General",
            .settingsTabReport: "Report",
            .settingsAnalysisStartupMode: "Analysis startup mode",
            .analysisStartupModeManual: "Do Not Auto Start",
            .analysisStartupModeScheduled: "Scheduled Start",
            .analysisStartupModeRealtime: "Start Immediately After Screenshot",
            .settingsAnalysisRequireCharger: "Only auto-start analysis while charging",
            .settingsAnalysisScheduledTime: "Scheduled analysis time",
            .settingsScreenshotTesting: "Testing screenshot…",
            .settingsScreenshotTest: "Test Screenshot",
            .settingsOpenAppLocation: "Open App Location",
            .settingsScreenshotOpenFolder: "Open Screenshots Folder",
            .settingsScreenshotPreviewResult: "Preview Result",
            .settingsScreenshotInterval: "Screenshot interval",
            .settingsScreenshotMinutesPlaceholder: "min",
            .settingsScreenshotMinutesUnit: "min",
            .settingsModelTitle: "Model Settings",
            .settingsModelService: "Model provider",
            .settingsModelBaseURL: "Base URL",
            .settingsModelName: "Model name",
            .settingsModelNamePlaceholder: "Enter model name",
            .settingsModelAPIKey: "API key",
            .settingsModelAPIKeyPlaceholder: "Enter API key (optional)",
            .settingsModelContextLength: "Context length",
            .settingsModelLMStudioExplicitLoadUnloadModel: "Explicitly load/unload model",
            .settingsModelLMStudioExplicitLoadUnloadModelHelp: "The app will proactively load and unload the model before and after analysis. If the model stays loaded in the background, turn this off.",
            .settingsModelImageAnalysisMethod: "Image analysis method",
            .settingsModelOfficialUntested: "Official APIs have not been tested",
            .settingsModelCategoriesTitle: "Analysis categories",
            .settingsAnalysisCategoryTitle: "Category",
            .settingsSummaryTitle: "Summary",
            .settingsSummaryHint: "Describe the project or coursework you've been working on recently so the model can summarize more accurately.",
            .settingsSummaryPlaceholder: "Pay attention to the project name, course name, and other visible context in the screenshot, then write a brief description.",
            .settingsAnalysisResultCategory: "Category",
            .settingsResultSummary: "Summary",
            .settingsAnalysisReservedPrefixError: "Category names cannot start with PRESERVED_.",
            .settingsModelCategoryColor: "Color",
            .settingsModelCustomColor: "Custom Color",
            .settingsModelCategoryName: "Category",
            .settingsModelCategoryDescription: "Description",
            .settingsModelCategoryNameExample: "Example: Focused Work",
            .settingsModelCategoryDescriptionExample: "Example: Coding, researching, or writing docs",
            .settingsCharacterLimitSuffix: " (%d chars max)",
            .settingsModelAddCategory: "Add Category",
            .settingsModelTesting: "Testing model…",
            .settingsModelTest: "Test Model",
            .settingsModelCopyPrompt: "Copy Prompt",
            .settingsModelCopyToWorkContentSummary: "Copy to Work Content Summary",
            .settingsModelCopyToScreenshotAnalysis: "Copy to Screenshot Analysis",
            .settingsModelCopyConfirmTitle: "Confirm model config copy",
            .settingsModelCopyToWorkContentSummaryConfirmMessage: "This will overwrite the model configuration in Work Content Summary.",
            .settingsModelCopyToScreenshotAnalysisConfirmMessage: "This will overwrite the model configuration in Screenshot Analysis.",
            .settingsKeychainSaveFailedTitle: "Failed to Save API Key",
            .settingsKeychainSaveFailedMessage: "DeskBrief could not write the API key for “%@” to Keychain, so the setting was restored to the last saved value.\n\n%@",
            .settingsKeychainLoadFailedTitle: "Failed to Load API Key",
            .settingsKeychainLoadFailedMessage: "DeskBrief could not read the API key for “%@” from Keychain. It will temporarily treat the API key as unset; save that key again in Settings.\n\n%@",
            .settingsCategoryRulesSaveFailedTitle: "Failed to Save Categories",
            .settingsCategoryRulesSaveFailedMessage: "DeskBrief could not save the analysis categories, so the setting was restored to the last saved value.\n\n%@",
            .commonConfirm: "Confirm",
            .commonCancel: "Cancel",
            .settingsModelTestResult: "Test Result",
            .settingsModelWaitingForModel: "Analyzing. The model may still be loading",
            .settingsModelNoTempScreenshot: "No temporary screenshot was created for model testing",
            .settingsModelTimingRequest: "Request time",
            .settingsModelTimingServerProcessing: "Server processing time",
            .settingsModelTimingModelLoad: "Model load time",
            .settingsModelTimingTTFT: "Time to first token",
            .settingsModelTimingOutput: "Output time",
            .settingsModelTimingUnavailable: "Not returned (the model may already be preloaded)",
            .settingsModelOCRText: "OCR text",
            .settingsModelOCRTextEmpty: "No text was recognized",
            .settingsModelReasoningProcess: "Reasoning",
            .settingsGeneralTitle: "General Settings",
            .settingsLanguage: "Language",
            .settingsAutoDeletionRetention: "Auto-Delete Screenshots",
            .settingsDatabaseSectionTitle: "Database Settings",
            .settingsDatabaseEncryption: "Database Encryption",
            .settingsDatabasePassphrase: "Change Database Key",
            .settingsDatabasePassphrasePlaceholder: "Enter new key",
            .settingsDatabasePassphraseConfirm: "Confirm",
            .settingsDatabaseOpenLocation: "Open Database Location",
            .settingsDatabaseDisableConfirmTitle: "Continue turning off the password?",
            .settingsDatabaseDisableConfirmMessage: "After this is turned off, the database can be read directly. The database key will be removed from macOS Keychain.",
            .settingsDatabaseDisableConfirmButton: "Turn Off Password",
            .settingsDatabaseEnableConfirmTitle: "Confirm Database Key",
            .settingsDatabaseEnableConfirmMessage: "DeskBrief will encrypt the database. The database key is not shown in the app and can be viewed later in Keychain Access.",
            .settingsDatabasePassphraseUnsavedTitle: "The database key has not been updated. Continue closing?",
            .settingsDatabasePassphraseUnsavedMessage: "Closing the Settings window will discard the database key currently entered.",
            .settingsDatabasePassphraseContinueEditing: "Keep Editing",
            .settingsDatabasePassphraseContinueClosing: "Close Without Saving",
            .settingsDatabaseBusyTitle: "Cannot Change Database Encryption Yet",
            .settingsDatabaseBusyMessage: "Analysis or summary work is currently running. Try again after the current task finishes.",
            .settingsDatabaseOperationFailedTitle: "Database Encryption Failed",
            .autoDeletionRetentionOff: "Off",
            .autoDeletionRetention7Days: "7 Days",
            .autoDeletionRetention14Days: "14 Days",
            .autoDeletionRetention28Days: "28 Days",
            .settingsReportTitle: "Report Settings",
            .settingsReportWeekStart: "First day of the week",
            .settingsCountdown: "Countdown: %d sec",
            .appName: "DeskBrief",
            .statusAccessibilityDescription: "DeskBrief",
            .menuNoPending: "No screenshots pending analysis",
            .menuOpenScreenshotsFolder: "Open Screenshots Folder",
            .menuShowLogs: "Show Logs",
            .menuShowErrorsCount: "Show %d Errors",
            .menuAnalysisStartupMode: "Analysis Startup Mode",
            .menuAnalyzeNowStart: "Analyze Now",
            .menuAnalyzeNowPause: "Stop Current Analysis",
            .menuAnalyzeNowPausingStoppingGeneration: "Stopping (Stopping Generation)",
            .menuAnalyzeNowPausingUnloadingModel: "Stopping (Unloading Model)",
            .menuStopCurrentSummary: "Stop Current Summary",
            .menuStopCurrentSummaryStoppingGeneration: "Stopping Summary (Stopping Generation)",
            .menuStopCurrentSummaryUnloadingModel: "Stopping Summary (Unloading Model)",
            .menuBackfillMissingSummaries: "Fill Missing Summaries",
            .menuCurrentStatus: "Current Status",
            .menuSettings: "Settings",
            .menuReports: "View Reports",
            .menuCurrentStatusRunningScreenshotAnalysis: "Running: Screenshot Analysis",
            .menuCurrentStatusRunningWorkContentSummary: "Running: Work Content Summary",
            .menuCurrentStatusCurrentModel: "Current model: %@",
            .menuCurrentStatusLoadingModel: "Loading model: %@",
            .menuCurrentStatusProgress: "Progress: %d%%",
            .menuClearEarlyScreenshots: "Clear Early Screenshots",
            .menuClearEarlyScreenshotsOneDay: "Older Than 1 Day",
            .menuClearEarlyScreenshotsOneWeek: "Older Than 1 Week",
            .menuClearEarlyScreenshotsCalculating: "%@ (Calculating)",
            .menuClearEarlyScreenshotsEmpty: "%@ (No screenshots)",
            .menuClearEarlyScreenshotsCount: "%@ (%d screenshots)",
            .menuClearEarlyScreenshotsCountSingular: "%@ (%d screenshot)",
            .menuClearEarlyScreenshotsFailed: "%@ (Calculation failed)",
            .menuClearEarlyScreenshotsConfirmTitle: "Confirm Screenshot Cleanup",
            .menuClearEarlyScreenshotsConfirmMessage: "This will delete pending screenshots %@ (%d total). This cannot be undone.",
            .menuQuit: "Quit",
            .windowSettings: "Settings",
            .windowReports: "Reports",
            .windowLogs: "Logs",
            .windowErrors: "Errors",
            .alertDatabaseInitFailed: "Failed to initialize database",
            .alertDatabaseRecoveryTitle: "Cannot Open Encrypted Database",
            .alertDatabasePassphraseMissingMessage: "The database is encrypted, but DeskBrief could not find its database key in Keychain. You can enter the key manually, or delete the database and create a new empty one.",
            .alertDatabasePassphraseInvalidMessage: "The database key may not match, or the database file could not be read. You can enter the key again; if it still fails, back up the database file before deciding whether to delete it and create a new empty database.",
            .alertDatabaseEnterPassphrase: "Enter Key",
            .alertDatabaseDeleteDatabase: "Delete Database",
            .alertDatabaseQuit: "Quit",
            .alertDatabaseEnterPassphraseTitle: "Enter Database Key",
            .alertDatabaseEnterPassphraseMessage: "Enter the key used to open the encrypted DeskBrief database. If it is correct, DeskBrief will save it to Keychain.",
            .alertDatabasePassphrasePlaceholder: "Database key",
            .alertDatabasePassphraseInvalidTitle: "Cannot Open Encrypted Database",
            .alertDatabasePassphraseInvalidRetryMessage: "DeskBrief could not open the database with this key. Check that the full key was entered, then try again.\n\n%@",
            .alertDatabasePassphraseSavedTitle: "Database Unlocked",
            .alertDatabasePassphraseSavedMessage: "The key has been saved to Keychain. DeskBrief will continue starting.",
            .alertDatabaseDeleteConfirmTitle: "Confirm Database Deletion",
            .alertDatabaseDeleteConfirmMessage: "DeskBrief will delete the database file and create a new empty database. The screenshots folder will be kept, but existing reports, logs, and analysis records will be cleared from the app. This cannot be undone.",
            .alertDatabaseDeletedTitle: "Database Deleted",
            .alertDatabaseDeletedMessage: "DeskBrief created a new empty encrypted database. The screenshots folder was kept.",
            .menuLastAverageDuration: "Last run averaged %@ sec per screenshot",
            .menuSummaryPausingStoppingGeneration: "Stopping screenshot analysis started at %@ (stopping generation, %d/%d)",
            .menuSummaryPausingUnloadingModel: "Stopping screenshot analysis started at %@ (unloading model, %d/%d)",
            .menuSummaryAnalyzing: "Analyzing screenshots starting at %@ (%d/%d)",
            .menuSummaryPending: "Pending screenshots since %@, %d total",
            .menuNextScreenshotAt: "Next screenshot at %@",
            .menuForceUnloadScreenshotAnalysisModel: "Force Unload Screenshot Analysis Model",
            .menuForceUnloadWorkContentSummaryModel: "Force Unload Work Content Summary Model",
            .menuForceUnloadConfirmStopAnalysis: "Stop the current analysis or summary?",
            .menuForceUnloadConfirmLifecycleDisabled: "According to the current settings, model load/unload is not managed by %@. Do you still want to send an unload request?",
            .menuForceUnloadNoLoadedModel: "No loaded model matched the current configuration, so unload was skipped.",
            .menuForceUnloadFailedTitle: "Force unload failed",
            .logsEmptyTitle: "No Logs",
            .logsEmptyDescription: "Analysis errors and later model-debugging logs will appear here.",
            .logsCopyAll: "Copy All",
            .logsClearAll: "Clear All Logs",
            .logsLevelError: "Error",
            .logsLevelLog: "Log",
            .errorsEmptyTitle: "No Errors",
            .errorsEmptyDescription: "New model errors will appear here when analysis fails.",
            .errorsClearAll: "Clear All Errors",
            .providerOpenAIUntested: "OpenAI (Untested)",
            .providerAnthropicUntested: "Anthropic (Untested)",
            .providerAppleIntelligence: "Apple Intelligence",
            .providerAppleIntelligenceDeviceNotEligible: "Unsupported Device",
            .providerAppleIntelligenceNotEnabled: "Not Enabled",
            .providerAppleIntelligenceModelNotReady: "Model Not Ready",
            .providerAppleIntelligenceUnsupportedLanguage: "Unsupported %@",
            .settingsAppleIntelligenceSupportedLanguages: "Apple Intelligence only supports %@.",
            .settingsAppleIntelligenceOCROnly: "Apple Intelligence does not support direct image understanding. It only supports OCR-first text analysis.",
            .imageAnalysisMethodOCR: "OCR (LLM text-only analysis)",
            .imageAnalysisMethodMultimodal: "Multimodal (vision-capable LLM)",
            .screenshotScopeActiveDisplay: "Current active display",
            .reportKindDay: "Day",
            .reportKindWeek: "Week",
            .reportKindMonth: "Month",
            .reportKindYear: "Year",
            .reportVisualizationBar: "Bar",
            .reportVisualizationHeatmap: "Heatmap",
            .reportWeekStartSunday: "Sunday",
            .reportWeekStartMonday: "Monday",
            .absenceCategoryDisplay: "Away",
            .preservedOtherCategoryDisplay: "Other",
            .reportType: "Report type",
            .reportPreviousPage: "Previous",
            .reportNextPage: "Next",
            .reportTotalDuration: "Total %@",
            .reportAverageDuration: "Daily avg %@",
            .reportViewTitle: "Reports",
            .reportChartType: "Chart type",
            .reportWorkdays: "Workdays",
            .reportWeekends: "Weekends",
            .reportOverlayDailyTime: "Overlay daily time",
            .reportNoDataTitle: "No Report Data",
            .reportNoDataDescription: "No records match the current time range and filters.",
            .reportCategoryAxis: "Category",
            .reportTotalHoursAxis: "Total Hours",
            .reportSummarizeNow: "Summarize Now",
            .reportSummarizing: "Summarizing…",
            .reportDailySummaryTitle: "Daily Summary",
            .reportTemporarySummary: "Temporary Summary",
            .reportHeatmapNoSelectedCategoriesTitle: "No Categories Selected",
            .reportHeatmapNoSelectedCategoriesDescription: "Select at least one category to view the heatmap.",
            .reportHeatmapYesterday: "Yesterday",
            .reportHeatmapTomorrow: "Tomorrow",
            .reportAbsenceSummaryPlaceholder: "No screenshot was captured in this period because the user was away from the desk or inactive on the computer.",
            .reportDailySummaryInvalidResponse: "The model response could not be parsed into a valid daily report JSON result",
            .reportDailySummaryNoActivity: "There are no activity records available for this day",
            .analysisHTTPError: "API returned an error (%d): %@",
            .analysisInvalidImageData: "The screenshot file is damaged or is not a recognizable image",
            .analysisNeedsCategoryRule: "Configure at least one valid category and description first",
            .analysisNeedsBaseURL: "Configure the model base URL first",
            .analysisNeedsModelName: "Configure the model name first",
            .analysisScreenshotMissing: "The screenshot file is missing, so analysis cannot continue",
            .analysisCancelledByUser: "Analysis was stopped by the user",
            .analysisPausedAfterFailures: "Analysis was paused after 5 consecutive screenshot failures",
            .analysisPartialFailures: "Some screenshots failed to analyze. Check the network, model API, or response format",
            .analysisInvalidCategory: "The model response could not be parsed into a valid JSON analysis result",
            .analysisInvalidBaseURL: "The model base URL is invalid",
            .analysisInvalidHTTPResponse: "The model API did not return a valid HTTP response",
            .analysisRetrySupplement: "Additional requirement: return complete JSON directly and do not overthink it",
            .analysisLengthTruncated: "The model output was truncated before a complete JSON analysis result could be returned",
            .analysisInvalidCategoryWithText: "The model response could not be parsed into a valid JSON analysis result",
            .analysisInvalidStructuredResponseWithText: "The model response did not match the expected structured analysis result",
            .analysisAppleIntelligenceDecodingFailure: "Apple Intelligence returned a structured result that could not be decoded",
            .analysisUnderlyingDetailsHeader: "Underlying error details:",
            .analysisResponseUnavailable: "No model response content was captured",
            .analysisOpenAIFormatInvalid: "The OpenAI-compatible API response format is invalid",
            .analysisOpenAINoText: "The OpenAI-compatible API did not return readable text",
            .analysisAnthropicFormatInvalid: "The Anthropic-compatible API response format is invalid",
            .analysisAnthropicNoText: "The Anthropic-compatible API did not return readable text",
            .analysisLMStudioFormatInvalid: "The LM Studio API response format is invalid",
            .analysisLMStudioNoText: "The LM Studio API did not return readable text",
            .analysisNoResponseData: "The model API returned no data",
            .analysisAppleIntelligenceUnavailable: "Apple Intelligence is currently unavailable: %@",
            .analysisAppleIntelligenceNoOCRTextSummary: "Not enough text was recognized in the screenshot, so it was analyzed as OCR-empty content.",
            .analysisOCRNoTextSummary: "Not enough text was recognized in the screenshot, so it was analyzed as OCR-empty content.",
            .screenshotPermissionDenied: "Screen recording permission was not granted",
            .screenshotPreviewUnreadable: "The screenshot test finished, but the preview image could not be loaded",
            .screenshotCommandFailed: "The system screencapture command failed",
            .notificationAnalysisCompleteTitle: "Analysis Complete",
            .notificationAnalysisFailedTitle: "Analysis Failed",
            .notificationMemoryInsufficientTitle: "Insufficient Memory",
            .notificationMemoryInsufficientBody: "Cancelled %@: current available memory %@GiB is below the %@GiB threshold",
            .notificationBackfillCompleteTitle: "Backfill Complete",
            .notificationBackfillFailedTitle: "Backfill Failed",
            .notificationRealtimeBacklogTitle: "Realtime Analysis May Be Backlogged",
            .notificationAnalysisCompleteNoReports: "Analyzed %@.",
            .notificationAnalysisCompleteWithReports: "Analyzed %@ and generated %@.",
            .notificationAnalysisPartialNoReports: "Analyzed %@, %@ failed. Check the logs for details.",
            .notificationAnalysisPartialWithReports: "Analyzed %@, %@ failed, and generated %@. Check the logs for details.",
            .notificationAnalysisSummaryFailedNoReports: "Analyzed %@, but daily report generation failed. Check the logs for details.",
            .notificationAnalysisSummaryFailedWithReports: "Analyzed %@ and generated %@, but some daily reports failed. Check the logs for details.",
            .notificationAnalysisFailedBody: "This analysis run failed. %@ failed. Check the logs for details.",
            .notificationBackfillCompleteBody: "Filled in %@ and %@.",
            .notificationBackfillPartialBody: "Filled in %@ and %@. Some items failed; check the logs for details.",
            .notificationBackfillFailedBody: "Backfill failed. Check the logs for details.",
            .notificationRealtimeBacklogBody: "There are %@ waiting to be analyzed, %@ more than the previous check.",
            .notificationDailyReportForDay: "the daily report for %@",
            .notificationScreenshotCount: "%d screenshots",
            .notificationScreenshotCountSingular: "%d screenshot",
            .notificationDailyReportCount: "%d daily reports",
            .notificationDailyReportCountSingular: "%d daily report",
            .memoryCheckTitle: "Check available memory before loading model",
            .memoryTotalRam: "Total RAM: ",
            .memoryAvailableRam: "Available: ",
            .memorySizeGiB: "%@ GiB",
            .memoryUnitGiB: "GiB",
            .memoryThresholdTooltip: "Model will not be loaded when available memory falls below this threshold",
            .menuAnalysisRuns: "Analysis Runs",
            .windowAnalysisRuns: "Analysis Runs",
            .windowAnalysisRunsEmptyTitle: "No Analysis Runs",
            .windowAnalysisRunsEmptyDescription: "Analysis run records will appear here after you complete a screenshot analysis.",
            .analysisRunsColumnTime: "Time",
            .analysisRunsColumnModel: "Model",
            .analysisRunsColumnStatus: "Status",
            .analysisRunsColumnSuccess: "Succeed/Fail",
            .analysisRunsColumnAnalysisDuration: "Avg Analysis",
            .analysisRunsColumnSummaryDuration: "Avg Summary",
            .analysisRunsColumnAnalysisTokens: "Analysis\nAvg/Max",
            .analysisRunsColumnSummaryTokens: "Summary\nAvg/Max",
            .analysisRunsColumnError: "Error",
            .analysisRunsStatusSucceeded: "Succeeded",
            .analysisRunsStatusFailed: "Failed",
            .analysisRunsStatusCancelled: "Cancelled",
            .analysisRunsStatusPartial: "Partial",
            .analysisRunsStatusRunning: "Running",
            .notificationWorkBlockSummaryCount: "%d work block summaries",
            .notificationWorkBlockSummaryCountSingular: "%d work block summary",
            .settingsAnalysisStartupModeTooltip: "3 analysis startup modes:\n1. *Manual*: Click menu bar icon > Status > Analyze Now.\n2. *Scheduled*: Best if your Mac stays on overnight.\n3. *On capture*: Best for remote AI services or a dedicated AI server (including local).",
            .settingsAnalysisScheduledTimeTooltip: "When startup mode is set to \"*Scheduled*\", all pending screenshots will be analyzed at this time.",
            .settingsAnalysisChargerRequirementTooltip: "When startup mode is \"*Scheduled*\" or \"*On capture*\", analysis only runs when connected to a power adapter. Recommended for laptops running local models.\nNote: The system considers charging active even if the charger power is lower than consumption.",
            .settingsModelServiceTooltip: "Anthropic is untested. *LM Studio* has been thoroughly tested. For Ollama and other providers, use the *OpenAI* format. Apple Intelligence currently has very low quality and is not recommended.",
            .settingsModelImageAnalysisMethodTooltip: "Prefer *Multimodal* (native image understanding models like Qwen 2.5, Gemma 4); *OCR* extracts text first then uses a language model. OCR is suitable for Apple Intelligence.",
            .settingsModelBaseURLTooltip: "Example: http://localhost:1234, https://api.deepseek.com\nDo not include /v1 or trailing /",
            .settingsModelNameTooltip: "Example: google/gemma-4-26b-a4b, deepseek-v4-flash",
            .settingsModelAPIKeyTooltip: "Leave empty if not required (e.g., local model service)",
            .settingsModelContextLengthTooltip: "Screenshot analysis should not exceed 6000. Summaries can be longer.",
            .settingsModelLMStudioExplicitLoadUnloadModelTooltip: "Currently only supports LM Studio. When enabled, the app sends load/unload requests around screenshot analysis and work content summary. Usually paired with *Scheduled* mode. Disable for *On capture* mode on a dedicated AI server.",
            .settingsIntervalTooltip: "Recommended: **10 minutes**.\nTiming starts when the app launches and pauses when the app exits. The app does not have a built-in pause feature.",
            .settingsScreenshotStorageLocation: "Screenshot Storage",
            .settingsScreenshotStorageLocationTooltip: "When saved to *Disk*, the security level is consistent with other user files and cannot be directly accessed by other users. If you have high privacy requirements, choose memory storage. Unanalyzed screenshots will be lost when the app exits or system restarts.",
            .settingsLanguageTooltip: "It is recommended to use the same language as the information entered for screenshot analysis and work content summary.",
            .settingsAutoDeletionRetentionTooltip: "Automatically delete pending screenshot files older than the selected retention period. Retention cleanup only deletes JPEG files in the root screenshots directory; app launch cleans up leftover transient screenshots in preview/ and temp/.",
            .settingsDatabaseEncryptionTooltip: "*Off*: Other apps can read the data if they can read this file.\n*On*: Other apps must enter the key before reading the data. You can change it in the app at any time, or view it in Keychain Access.\nThe key is stored securely in Apple Keychain and automatically decrypts the database each time the app opens.",
            .settingsDatabasePassphraseTooltip: "Enter a new database key, then click Confirm. The current key is not shown in the app and can be viewed in Keychain Access.",
            .settingsReportWeekStartTooltip: "Only used for weekly reports.",
            .modelMemoryError: "Insufficient available memory: requested %.0f GiB, available %.1f GiB",
            .lmStudioEndpointInvalid: "LM Studio model management endpoint is invalid.",
            .lmStudioHTTPResponseInvalid: "LM Studio model management did not return a valid HTTP response.",
            .lmStudioNoData: "LM Studio model management did not return data.",
            .lmStudioMissingLoadedInstanceID: "LM Studio did not return or expose a loaded instance for %@.",
        ],
    ]

    static func string(_ key: Key, language: AppLanguage = .current) -> String {
        table(for: language)[key] ?? table(for: .simplifiedChinese)[key] ?? key.rawValue
    }

    static func string(_ key: Key, language: AppLanguage = .current, arguments: [CVarArg]) -> String {
        let format = string(key, language: language)
        guard !arguments.isEmpty else {
            return format
        }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    static func displayCategoryName(_ categoryName: String, language: AppLanguage = .current) -> String {
        if categoryName == AppDefaults.absenceCategoryName {
            return string(.absenceCategoryDisplay, language: language)
        }
        if categoryName == AppDefaults.preservedOtherCategoryName {
            return string(.preservedOtherCategoryDisplay, language: language)
        }
        return categoryName
    }

    static func statusDateFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMdHm", language: language, timeZone: .current)
    }

    static func analysisRunTimeFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "MdHm", language: language, timeZone: .current)
    }

    static func timestampFormatter(language: AppLanguage = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = .current

        switch language {
        case .simplifiedChinese:
            formatter.dateFormat = "yyyy/M/d HH:mm:ss.SSS"
        case .english:
            formatter.dateFormat = "M/d/yyyy, HH:mm:ss.SSS"
        }

        return formatter
    }

    static func reportDayFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMMMd", language: language)
    }

    static func reportDayDisplayText(for dayStart: Date, language: AppLanguage = .current) -> String {
        let dayText = reportDayFormatter(language: language).string(from: dayStart)
        let weekdayText = dateFormatter(template: "EEEE", language: language, timeZone: .current).string(from: dayStart)
        return "\(dayText)·\(weekdayText)"
    }

    static func reportMonthFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMMMM", language: language)
    }

    static func reportYearFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "y", language: language)
    }

    static func reportTickFormatter(for interval: DateInterval, language: AppLanguage = .current) -> DateFormatter {
        switch interval.duration {
        case ..<86_400.0:
            return dateFormatter(template: "Hm", language: language, timeZone: .current)
        case ..<1_209_600.0:
            return dateFormatter(template: "MdHm", language: language, timeZone: .current)
        case ..<3_888_000.0:
            return dateFormatter(template: "Md", language: language, timeZone: .current)
        case ..<34_560_000.0:
            return dateFormatter(template: "MMMd", language: language, timeZone: .current)
        default:
            return dateFormatter(template: "yM", language: language, timeZone: .current)
        }
    }

    static func reportFinalTickFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "MMMd", language: language, timeZone: .current)
    }

    static func dailyHeatmapTickFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "Hm", language: language, timeZone: .current)
    }

    static func notificationScreenshotCount(_ count: Int, language: AppLanguage = .current) -> String {
        string(
            count == 1 ? .notificationScreenshotCountSingular : .notificationScreenshotCount,
            language: language,
            arguments: [count]
        )
    }

    static func notificationDailyReportCount(_ count: Int, language: AppLanguage = .current) -> String {
        string(
            count == 1 ? .notificationDailyReportCountSingular : .notificationDailyReportCount,
            language: language,
            arguments: [count]
        )
    }

    static func notificationWorkBlockSummaryCount(_ count: Int, language: AppLanguage = .current) -> String {
        string(
            count == 1 ? .notificationWorkBlockSummaryCountSingular : .notificationWorkBlockSummaryCount,
            language: language,
            arguments: [count]
        )
    }

    static func durationText(totalMinutes: Int, style: DurationDisplayStyle, language: AppLanguage = .current) -> String {
        switch language {
        case .simplifiedChinese:
            switch style {
            case .minute:
                return "\(totalMinutes) 分钟"
            case .hourOnly:
                return "\(totalMinutes / 60) 小时"
            case .hourAndMinute:
                let hours = totalMinutes / 60
                let minutes = totalMinutes % 60
                if hours > 0, minutes > 0 {
                    return "\(hours) 小时 \(minutes) 分"
                }
                if hours > 0 {
                    return "\(hours) 小时"
                }
                return "\(minutes) 分钟"
            }
        case .english:
            switch style {
            case .minute:
                return minuteUnit(totalMinutes)
            case .hourOnly:
                return hourUnit(totalMinutes / 60)
            case .hourAndMinute:
                let hours = totalMinutes / 60
                let minutes = totalMinutes % 60
                if hours > 0, minutes > 0 {
                    return "\(hourUnit(hours)) \(compactMinuteUnit(minutes))"
                }
                if hours > 0 {
                    return hourUnit(hours)
                }
                return minuteUnit(minutes)
            }
        }
    }

    static func analysisPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        language: AppLanguage = .current
    ) -> String {
        let separator = language == .simplifiedChinese ? "：" : ": "
        let list = rules.map { rule in
            "\(rule.name)\(separator)\(rule.description)"
        }
        .joined(separator: "\n")
        let trimmedInstruction = summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = trimmedInstruction.isEmpty
            ? AppDefaults.defaultSummaryInstruction(language: language)
            : trimmedInstruction

        switch language {
        case .simplifiedChinese:
            return """
            你是一个工作桌面截屏分类助手，请严格从下面的候选类别中选择唯一一个最匹配的类别。然后对工作内容进行一个简短的描述。
            不要过度思考，只关注截屏主要部分。

            候选类别：
            \(list)
            
            描述要求：
            \(resolvedInstruction)

            返回要求：
            1. 返回的category必须与候选类别完全一致
            2. 返回格式：包含以下字段的JSON {"category": 分析得出的类别, "summary": 对截屏简短的描述}
            3. 不要返回 Markdown、解释、思考过程或其他多余文本
            """
        case .english:
            return """
            You are a desktop screenshot classifier for daily work summaries, choose exactly one best-matching category from the candidates below, then write a short description of the work.
            Do not overthink it. Focus only on the main content of the screenshot.

            Candidate categories:
            \(list)

            Description requirements:
            \(resolvedInstruction)

            Output requirements:
            1. The returned `category` must exactly match one of the candidate names
            2. Return JSON with these fields: {"category": chosen category, "summary": short description of the screenshot}
            3. Do not return Markdown, explanations, reasoning, or any extra text
            """
        }
    }

    static func appleIntelligenceAnalysisPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        recognizedText: String,
        language: AppLanguage = .current
    ) -> String {
        ocrAnalysisPrompt(
            with: rules,
            summaryInstruction: summaryInstruction,
            recognizedText: recognizedText,
            language: language,
            outputMode: .appleIntelligenceStructuredOutput
        )
    }

    static func apiOCRAnalysisPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        recognizedText: String,
        language: AppLanguage = .current
    ) -> String {
        ocrAnalysisPrompt(
            with: rules,
            summaryInstruction: summaryInstruction,
            recognizedText: recognizedText,
            language: language,
            outputMode: .remoteAPIJSONTextOutput
        )
    }

    private enum OCRPromptOutputMode {
        case remoteAPIJSONTextOutput
        case appleIntelligenceStructuredOutput
    }

    private static func ocrAnalysisPrompt(
        with rules: [CategoryRule],
        summaryInstruction: String,
        recognizedText: String,
        language: AppLanguage,
        outputMode: OCRPromptOutputMode
    ) -> String {
        let separator = language == .simplifiedChinese ? "：" : ": "
        let list = rules.map { rule in
            "\(rule.name)\(separator)\(rule.description)"
        }
        .joined(separator: "\n")
        let trimmedInstruction = summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = trimmedInstruction.isEmpty
            ? AppDefaults.defaultSummaryInstruction(language: language)
            : trimmedInstruction
        let trimmedText = String(recognizedText.prefix(6000))

        switch language {
        case .simplifiedChinese:
            return """
            你是一个工作桌面截屏分类助手，请严格从下面的候选类别中选择唯一一个最匹配的类别。然后对工作内容进行一个简短的描述。
            你无法直接查看原始截屏，只能根据 OCR 识别出的文字进行判断。不要过度思考，只关注主要内容，不要编造 OCR 中没有出现的视觉细节。

            候选类别：
            \(list)

            描述要求：
            \(resolvedInstruction)

            输出要求：
            1. 返回的 category 必须与候选类别完全一致
            2. summary 必须是对截屏主要工作内容的简短描述
            3. 如果信息不足，请给出最保守的判断；若候选类别中有 PRESERVED_OTHER，可优先考虑它
            4. \(outputMode == .appleIntelligenceStructuredOutput
                ? "按提供的结构化 schema 返回，不要额外输出解释、Markdown 或思考过程"
                : "返回格式：包含以下字段的 JSON {\"category\": 分析得出的类别, \"summary\": 对截屏简短的描述}，不要额外输出解释、Markdown 或思考过程")

            OCR 文字：
            \(trimmedText)
            """
        case .english:
            return """
            You are a desktop screenshot classifier for daily work summaries. Choose exactly one best-matching category from the candidates below, then write a short description of the work.
            You cannot view the original screenshot directly. You can only reason from the OCR text below. Do not overthink it, and do not invent visual details that do not appear in the OCR output.

            Candidate categories:
            \(list)

            Description requirements:
            \(resolvedInstruction)

            Output requirements:
            1. The returned category must exactly match one of the candidate names
            2. The summary must be a short description of the main work shown in the screenshot
            3. If the information is insufficient, make the most conservative choice. Prefer PRESERVED_OTHER when it is available
            4. \(outputMode == .appleIntelligenceStructuredOutput
                ? "Return only the structured result defined by the provided schema, with no explanations, Markdown, or reasoning"
                : "Return JSON with these fields: {\"category\": chosen category, \"summary\": short description of the screenshot}. Do not return explanations, Markdown, or reasoning")

            OCR text:
            \(trimmedText)
            """
        }
    }

    static func dailyReportSummaryPrompt(
        for _: Date,
        categories: [String],
        activityLines: [String],
        summaryInstruction: String,
        language: AppLanguage = .current
    ) -> String {
        let categoryList = categories.map { "- \($0)" }.joined(separator: "\n")
        let activityList = activityLines.map { "- \($0)" }.joined(separator: "\n")
        let trimmedInstruction = summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = trimmedInstruction.isEmpty
            ? AppDefaults.defaultSummaryInstruction(language: language)
            : trimmedInstruction

        switch language {
        case .simplifiedChinese:
            return """
            你是一个日报总结助手。请根据下面这一天的活动记录，生成一段话日报和每个分类的单独总结。
            只总结这一天的主要工作内容，不要编造没有出现的信息。

            当天分类：
            \(categoryList)

            活动记录：
            \(activityList)

            总结要求：
            \(resolvedInstruction)

            返回要求：
            1. 返回 JSON，格式为 {"dailySummary":"一段话日报","categorySummaries":{"分类A":"该分类总结","分类B":"该分类总结"}}
            2. `dailySummary` 必须是非空字符串
            3. `categorySummaries` 必须包含且仅包含当天分类里的每一个分类，key 必须与分类名完全一致
            4. 每个分类总结都必须是非空字符串
            5. 不要返回 Markdown、解释、思考过程或其他多余文本
            """
        case .english:
            return """
            You are a daily report summarizer. Based on the activity records for this day, generate a one-paragraph daily report and one short summary for each category.
            Only summarize the work that appears in these records. Do not invent details.

            Categories for this day:
            \(categoryList)

            Activity records:
            \(activityList)

            Summary requirements:
            \(resolvedInstruction)

            Output requirements:
            1. Return JSON in this format: {"dailySummary":"one-paragraph daily report","categorySummaries":{"Category A":"category summary","Category B":"category summary"}}
            2. `dailySummary` must be a non-empty string
            3. `categorySummaries` must contain each category from the list above exactly once, and every key must exactly match the category name
            4. Every category summary must be a non-empty string
            5. Do not return Markdown, explanations, reasoning, or any extra text
            """
        }
    }

    static func dailyWorkBlockSummaryPrompt(
        category: String,
        sourceSummaries: [String],
        summaryInstruction: String,
        language: AppLanguage = .current
    ) -> String {
        let summaryList = sourceSummaries.map { "- \($0)" }.joined(separator: "\n")
        let trimmedInstruction = summaryInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = trimmedInstruction.isEmpty
            ? AppDefaults.defaultSummaryInstruction(language: language)
            : trimmedInstruction

        switch language {
        case .simplifiedChinese:
            return """
            你是一个连续工作块总结助手。请根据下面同一分类、连续的一段工作记录，生成一句简短总结。
            只总结工作内容本身，不要提及时间、时长、开始结束时间、日期、时间跨度或时间安排评价。

            分类：
            \(category)

            源记录总结：
            \(summaryList)

            总结要求：
            \(resolvedInstruction)

            返回要求：
            1. 返回 JSON，格式为 {"summary":"连续工作块总结"}
            2. `summary` 必须是非空字符串
            3. 不要返回 Markdown、解释、思考过程或其他多余文本
            """
        case .english:
            return """
            You are a continuous work block summarizer. Based on the records below from one continuous block in the same category, write one short summary.
            Only summarize the work itself. Do not mention time, duration, start or end time, dates, time spans, or evaluate the schedule.

            Category:
            \(category)

            Source summaries:
            \(summaryList)

            Summary requirements:
            \(resolvedInstruction)

            Output requirements:
            1. Return JSON in this format: {"summary":"continuous work block summary"}
            2. `summary` must be a non-empty string
            3. Do not return Markdown, explanations, reasoning, or any extra text
            """
        }
    }

    private static func table(for language: AppLanguage) -> [Key: String] {
        tables[language] ?? [:]
    }

    private static func dateFormatter(template: String, language: AppLanguage, timeZone: TimeZone? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func minuteUnit(_ value: Int) -> String {
        value == 1 ? "1 minute" : "\(value) minutes"
    }

    private static func compactMinuteUnit(_ value: Int) -> String {
        "\(value) min"
    }

    private static func hourUnit(_ value: Int) -> String {
        value == 1 ? "1 hr" : "\(value) hrs"
    }
}
