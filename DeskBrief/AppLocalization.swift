import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let userDefaultsKey = "settings.appLanguage"

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
        case settingsModelLMStudioAutoLoadUnloadModel
        case settingsModelLMStudioAutoLoadUnloadModelHelp
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
        case settingsModelAddCategory
        case settingsModelTesting
        case settingsModelTest
        case settingsModelCopyPrompt
        case settingsModelCopyToWorkContentSummary
        case settingsModelCopyToScreenshotAnalysis
        case settingsModelCopyConfirmTitle
        case settingsModelCopyToWorkContentSummaryConfirmMessage
        case settingsModelCopyToScreenshotAnalysisConfirmMessage
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
        case menuLastAverageDuration
        case menuSummaryPausingStoppingGeneration
        case menuSummaryPausingUnloadingModel
        case menuSummaryAnalyzing
        case menuCurrentStatusRunningScreenshotAnalysis
        case menuCurrentStatusRunningWorkContentSummary
        case menuCurrentStatusCurrentModel
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
            .settingsAnalysisRequireCharger: "仅在充电时自动分析",
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
            .settingsModelAPIKey: "API 秘钥",
            .settingsModelAPIKeyPlaceholder: "请输入 API Key（可留空）",
            .settingsModelContextLength: "上下文长度",
            .settingsModelLMStudioAutoLoadUnloadModel: "主动装卸载模型",
            .settingsModelLMStudioAutoLoadUnloadModelHelp: "App会在开始分析前后主动加载和卸载模型，如果使用的模型是始终保持在后台的，请关闭这个选项",
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
            .settingsModelAddCategory: "添加分类",
            .settingsModelTesting: "正在测试模型…",
            .settingsModelTest: "测试模型",
            .settingsModelCopyPrompt: "复制 Prompt",
            .settingsModelCopyToWorkContentSummary: "复制到“工作内容总结”",
            .settingsModelCopyToScreenshotAnalysis: "复制到“截屏分析”",
            .settingsModelCopyConfirmTitle: "确认复制模型配置",
            .settingsModelCopyToWorkContentSummaryConfirmMessage: "确认后会覆盖“工作内容总结”里的模型配置。",
            .settingsModelCopyToScreenshotAnalysisConfirmMessage: "确认后会覆盖“截屏分析”里的模型配置。",
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
            .menuBackfillMissingSummaries: "检查并补充过去遗漏的总结",
            .menuCurrentStatus: "当前状态",
            .menuSettings: "设置",
            .menuReports: "查看报告",
            .menuCurrentStatusRunningScreenshotAnalysis: "正在进行：截屏分析",
            .menuCurrentStatusRunningWorkContentSummary: "正在进行：工作内容总结",
            .menuCurrentStatusCurrentModel: "当前加载模型：%@",
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
            .settingsAnalysisRequireCharger: "Only run automatic analysis while charging",
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
            .settingsModelLMStudioAutoLoadUnloadModel: "Auto load/unload model",
            .settingsModelLMStudioAutoLoadUnloadModelHelp: "The app will proactively load and unload the model before and after analysis. If the model stays loaded in the background, turn this off.",
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
            .settingsModelAddCategory: "Add Category",
            .settingsModelTesting: "Testing model…",
            .settingsModelTest: "Test Model",
            .settingsModelCopyPrompt: "Copy Prompt",
            .settingsModelCopyToWorkContentSummary: "Copy to Work Content Summary",
            .settingsModelCopyToScreenshotAnalysis: "Copy to Screenshot Analysis",
            .settingsModelCopyConfirmTitle: "Confirm model config copy",
            .settingsModelCopyToWorkContentSummaryConfirmMessage: "This will overwrite the model configuration in Work Content Summary.",
            .settingsModelCopyToScreenshotAnalysisConfirmMessage: "This will overwrite the model configuration in Screenshot Analysis.",
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
            .menuBackfillMissingSummaries: "Fill Missing Summaries",
            .menuCurrentStatus: "Current Status",
            .menuSettings: "Settings",
            .menuReports: "View Reports",
            .menuCurrentStatusRunningScreenshotAnalysis: "Running: Screenshot Analysis",
            .menuCurrentStatusRunningWorkContentSummary: "Running: Work Content Summary",
            .menuCurrentStatusCurrentModel: "Current model: %@",
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
