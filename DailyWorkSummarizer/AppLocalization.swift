import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let userDefaultsKey = "settings.appLanguage"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var localizedName: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
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

enum L10n {
    enum Key: String {
        case settingsTabCapture
        case settingsTabModel
        case settingsTabAnalysis
        case settingsTabGeneral
        case settingsTabReport
        case settingsCaptureAutoAnalysis
        case settingsCaptureRequireCharger
        case settingsCaptureAnalysisTime
        case settingsCaptureTestingScreenshot
        case settingsCaptureTestScreenshot
        case settingsCaptureOpenAppLocation
        case settingsCaptureOpenScreenshotsFolder
        case settingsCaptureTestResult
        case settingsCaptureInterval
        case settingsCaptureMinutesPlaceholder
        case settingsCaptureMinutesUnit
        case settingsModelTitle
        case settingsModelService
        case settingsModelBaseURL
        case settingsModelName
        case settingsModelNamePlaceholder
        case settingsModelAPIKey
        case settingsModelAPIKeyPlaceholder
        case settingsModelContextLength
        case settingsModelOfficialUntested
        case settingsModelCategoriesTitle
        case settingsAnalysisCategoryTitle
        case settingsAnalysisSummaryTitle
        case settingsAnalysisSummaryHint
        case settingsAnalysisSummaryPlaceholder
        case settingsAnalysisResultCategory
        case settingsAnalysisResultSummary
        case settingsModelCategoryName
        case settingsModelCategoryDescription
        case settingsModelCategoryNameExample
        case settingsModelCategoryDescriptionExample
        case settingsModelAddCategory
        case settingsModelTesting
        case settingsModelTest
        case settingsModelCopyPrompt
        case settingsModelTestResult
        case settingsModelWaitingForModel
        case settingsModelNoTempScreenshot
        case settingsGeneralTitle
        case settingsLanguage
        case settingsReportTitle
        case settingsReportWeekStart
        case settingsCountdown
        case statusAccessibilityDescription
        case menuNoPending
        case menuOpenScreenshotsFolder
        case menuShowErrorsCount
        case menuTurnOffAutoAnalysis
        case menuTurnOnAutoAnalysis
        case menuAnalyzeNowStart
        case menuAnalyzeNowPause
        case menuAnalyzeNowPausing
        case menuCurrentStatus
        case menuSettings
        case menuReports
        case menuQuit
        case windowSettings
        case windowReports
        case windowErrors
        case alertDatabaseInitFailed
        case menuLastAverageDuration
        case menuSummaryPausing
        case menuSummaryAnalyzing
        case menuSummaryPending
        case menuNextCaptureAt
        case errorsEmptyTitle
        case errorsEmptyDescription
        case errorsClearAll
        case providerOpenAIUntested
        case providerAnthropicUntested
        case captureScopeActiveDisplay
        case reportKindDay
        case reportKindWeek
        case reportKindMonth
        case reportKindYear
        case reportVisualizationBar
        case reportVisualizationHeatmap
        case reportWeekStartSunday
        case reportWeekStartMonday
        case absenceCategoryDisplay
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
        case analysisOpenAIFormatInvalid
        case analysisOpenAINoText
        case analysisAnthropicFormatInvalid
        case analysisAnthropicNoText
        case analysisLMStudioFormatInvalid
        case analysisLMStudioNoText
        case analysisNoResponseData
        case screenshotPermissionDenied
        case screenshotPreviewUnreadable
        case screenshotCommandFailed
    }

    private static let tables: [AppLanguage: [Key: String]] = [
        .simplifiedChinese: [
            .settingsTabCapture: "截屏",
            .settingsTabModel: "模型",
            .settingsTabAnalysis: "分析",
            .settingsTabGeneral: "通用",
            .settingsTabReport: "报告",
            .settingsCaptureAutoAnalysis: "定时自动分析",
            .settingsCaptureRequireCharger: "仅在连接充电器时定时开始分析",
            .settingsCaptureAnalysisTime: "定时分析时间",
            .settingsCaptureTestingScreenshot: "正在测试截屏…",
            .settingsCaptureTestScreenshot: "测试截屏",
            .settingsCaptureOpenAppLocation: "打开 App 位置",
            .settingsCaptureOpenScreenshotsFolder: "打开截屏文件夹",
            .settingsCaptureTestResult: "测试结果",
            .settingsCaptureInterval: "截图间隔",
            .settingsCaptureMinutesPlaceholder: "分钟",
            .settingsCaptureMinutesUnit: "分钟",
            .settingsModelTitle: "模型设置",
            .settingsModelService: "模型服务",
            .settingsModelBaseURL: "接口地址",
            .settingsModelName: "模型名称",
            .settingsModelNamePlaceholder: "请输入模型名称",
            .settingsModelAPIKey: "API 秘钥",
            .settingsModelAPIKeyPlaceholder: "请输入 API Key（可留空）",
            .settingsModelContextLength: "上下文长度",
            .settingsModelOfficialUntested: "官方 API 未经过测试",
            .settingsModelCategoriesTitle: "分析分类",
            .settingsAnalysisCategoryTitle: "类别",
            .settingsAnalysisSummaryTitle: "总结",
            .settingsAnalysisSummaryHint: "请描述你最近在做什么项目，方便模型进行更准确的归纳",
            .settingsAnalysisSummaryPlaceholder: "注意观察画面里所打开项目的名称、课程名称等信息，进行简要描述",
            .settingsAnalysisResultCategory: "类别",
            .settingsAnalysisResultSummary: "总结",
            .settingsModelCategoryName: "类别名",
            .settingsModelCategoryDescription: "描述",
            .settingsModelCategoryNameExample: "例如：专注工作",
            .settingsModelCategoryDescriptionExample: "例如：正在编码、查资料或写文档",
            .settingsModelAddCategory: "添加分类",
            .settingsModelTesting: "正在测试模型…",
            .settingsModelTest: "测试模型",
            .settingsModelCopyPrompt: "复制 Prompt",
            .settingsModelTestResult: "测试结果",
            .settingsModelWaitingForModel: "正在分析，可能需要等待模型加载",
            .settingsModelNoTempScreenshot: "测试模型时未生成临时截图",
            .settingsGeneralTitle: "通用设置",
            .settingsLanguage: "语言",
            .settingsReportTitle: "报告设置",
            .settingsReportWeekStart: "一周的第一天",
            .settingsCountdown: "倒计时：%d秒",
            .statusAccessibilityDescription: "每日工作总结",
            .menuNoPending: "当前没有待分析的截图",
            .menuOpenScreenshotsFolder: "打开截图文件夹",
            .menuShowErrorsCount: "显示%d个错误",
            .menuTurnOffAutoAnalysis: "关闭定时分析",
            .menuTurnOnAutoAnalysis: "开启定时分析",
            .menuAnalyzeNowStart: "开始分析",
            .menuAnalyzeNowPause: "暂停分析",
            .menuAnalyzeNowPausing: "正在暂停",
            .menuCurrentStatus: "当前状态",
            .menuSettings: "设置",
            .menuReports: "查看报告",
            .menuQuit: "退出",
            .windowSettings: "设置",
            .windowReports: "查看报告",
            .windowErrors: "查看错误",
            .alertDatabaseInitFailed: "初始化数据库失败",
            .menuLastAverageDuration: "上次分析平均每张耗时%@秒",
            .menuSummaryPausing: "正在暂停从 %@ 开始的截屏分析（%d/%d）",
            .menuSummaryAnalyzing: "正在分析从 %@ 开始的截屏（%d/%d）",
            .menuSummaryPending: "当前截图从 %@ 开始，共 %d 张",
            .menuNextCaptureAt: "下一次会在%@进行截图",
            .errorsEmptyTitle: "当前没有错误",
            .errorsEmptyDescription: "后续分析出错时，会在这里显示最新的大模型返回错误。",
            .errorsClearAll: "清空所有错误",
            .providerOpenAIUntested: "OpenAI（未测试）",
            .providerAnthropicUntested: "Anthropic（未测试）",
            .captureScopeActiveDisplay: "当前活跃的屏幕",
            .reportKindDay: "日报",
            .reportKindWeek: "周报",
            .reportKindMonth: "月报",
            .reportKindYear: "年报",
            .reportVisualizationBar: "柱状图",
            .reportVisualizationHeatmap: "热力图",
            .reportWeekStartSunday: "周日",
            .reportWeekStartMonday: "周一",
            .absenceCategoryDisplay: "离开",
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
            .analysisHTTPError: "接口返回错误 (%d)：%@",
            .analysisNeedsCategoryRule: "至少需要配置一条有效的分析类别和描述",
            .analysisNeedsBaseURL: "请先配置模型接口地址",
            .analysisNeedsModelName: "请先配置模型名称",
            .analysisScreenshotMissing: "截图文件不存在，无法继续分析",
            .analysisCancelledByUser: "用户手动暂停分析",
            .analysisPausedAfterFailures: "连续 5 张截图处理失败，已暂停当前分析",
            .analysisPartialFailures: "部分截图分析失败，请检查网络、模型接口或返回格式",
            .analysisInvalidCategory: "模型返回无法解析为有效的 JSON 分析结果",
            .analysisInvalidBaseURL: "模型接口地址不合法",
            .analysisInvalidHTTPResponse: "模型接口没有返回有效的 HTTP 响应",
            .analysisRetrySupplement: "补充要求：直接输出完整 JSON，不要过度思考",
            .analysisLengthTruncated: "模型输出因长度截断，未能生成完整的 JSON 分析结果",
            .analysisInvalidCategoryWithText: "模型返回无法解析为有效的 JSON 分析结果",
            .analysisOpenAIFormatInvalid: "OpenAI 兼容接口返回格式不正确",
            .analysisOpenAINoText: "OpenAI 兼容接口没有返回可读文本",
            .analysisAnthropicFormatInvalid: "Anthropic 兼容接口返回格式不正确",
            .analysisAnthropicNoText: "Anthropic 兼容接口没有返回可读文本",
            .analysisLMStudioFormatInvalid: "LM Studio API 返回格式不正确",
            .analysisLMStudioNoText: "LM Studio API 没有返回可读文本",
            .analysisNoResponseData: "模型接口没有返回数据",
            .screenshotPermissionDenied: "没有获得屏幕录制权限",
            .screenshotPreviewUnreadable: "测试截图完成，但无法读取预览图像",
            .screenshotCommandFailed: "系统 screencapture 命令执行失败",
        ],
        .english: [
            .settingsTabCapture: "Capture",
            .settingsTabModel: "Model",
            .settingsTabAnalysis: "Analysis",
            .settingsTabGeneral: "General",
            .settingsTabReport: "Report",
            .settingsCaptureAutoAnalysis: "Scheduled analysis",
            .settingsCaptureRequireCharger: "Only run scheduled analysis while charging",
            .settingsCaptureAnalysisTime: "Scheduled analysis time",
            .settingsCaptureTestingScreenshot: "Testing screenshot…",
            .settingsCaptureTestScreenshot: "Test Screenshot",
            .settingsCaptureOpenAppLocation: "Open App Location",
            .settingsCaptureOpenScreenshotsFolder: "Open Screenshots Folder",
            .settingsCaptureTestResult: "Preview Result",
            .settingsCaptureInterval: "Screenshot interval",
            .settingsCaptureMinutesPlaceholder: "min",
            .settingsCaptureMinutesUnit: "min",
            .settingsModelTitle: "Model Settings",
            .settingsModelService: "Model provider",
            .settingsModelBaseURL: "Base URL",
            .settingsModelName: "Model name",
            .settingsModelNamePlaceholder: "Enter model name",
            .settingsModelAPIKey: "API key",
            .settingsModelAPIKeyPlaceholder: "Enter API key (optional)",
            .settingsModelContextLength: "Context length",
            .settingsModelOfficialUntested: "Official APIs have not been tested",
            .settingsModelCategoriesTitle: "Analysis categories",
            .settingsAnalysisCategoryTitle: "Category",
            .settingsAnalysisSummaryTitle: "Summary",
            .settingsAnalysisSummaryHint: "Describe the project or coursework you've been working on recently so the model can summarize more accurately.",
            .settingsAnalysisSummaryPlaceholder: "Pay attention to the project name, course name, and other visible context in the screenshot, then write a brief description.",
            .settingsAnalysisResultCategory: "Category",
            .settingsAnalysisResultSummary: "Summary",
            .settingsModelCategoryName: "Category",
            .settingsModelCategoryDescription: "Description",
            .settingsModelCategoryNameExample: "Example: Focused Work",
            .settingsModelCategoryDescriptionExample: "Example: Coding, researching, or writing docs",
            .settingsModelAddCategory: "Add Category",
            .settingsModelTesting: "Testing model…",
            .settingsModelTest: "Test Model",
            .settingsModelCopyPrompt: "Copy Prompt",
            .settingsModelTestResult: "Test Result",
            .settingsModelWaitingForModel: "Analyzing. The model may still be loading",
            .settingsModelNoTempScreenshot: "No temporary screenshot was created for model testing",
            .settingsGeneralTitle: "General Settings",
            .settingsLanguage: "Language",
            .settingsReportTitle: "Report Settings",
            .settingsReportWeekStart: "First day of the week",
            .settingsCountdown: "Countdown: %d sec",
            .statusAccessibilityDescription: "Daily Work Summarizer",
            .menuNoPending: "No screenshots pending analysis",
            .menuOpenScreenshotsFolder: "Open Screenshots Folder",
            .menuShowErrorsCount: "Show %d Errors",
            .menuTurnOffAutoAnalysis: "Turn Off Scheduled Analysis",
            .menuTurnOnAutoAnalysis: "Turn On Scheduled Analysis",
            .menuAnalyzeNowStart: "Start Analysis",
            .menuAnalyzeNowPause: "Pause Analysis",
            .menuAnalyzeNowPausing: "Stopping",
            .menuCurrentStatus: "Current Status",
            .menuSettings: "Settings",
            .menuReports: "View Reports",
            .menuQuit: "Quit",
            .windowSettings: "Settings",
            .windowReports: "Reports",
            .windowErrors: "Errors",
            .alertDatabaseInitFailed: "Failed to initialize database",
            .menuLastAverageDuration: "Last run averaged %@ sec per screenshot",
            .menuSummaryPausing: "Stopping screenshot analysis started at %@ (%d/%d)",
            .menuSummaryAnalyzing: "Analyzing screenshots starting at %@ (%d/%d)",
            .menuSummaryPending: "Pending screenshots since %@, %d total",
            .menuNextCaptureAt: "Next screenshot at %@",
            .errorsEmptyTitle: "No Errors",
            .errorsEmptyDescription: "New model errors will appear here when analysis fails.",
            .errorsClearAll: "Clear All Errors",
            .providerOpenAIUntested: "OpenAI (Untested)",
            .providerAnthropicUntested: "Anthropic (Untested)",
            .captureScopeActiveDisplay: "Current active display",
            .reportKindDay: "Day",
            .reportKindWeek: "Week",
            .reportKindMonth: "Month",
            .reportKindYear: "Year",
            .reportVisualizationBar: "Bar",
            .reportVisualizationHeatmap: "Heatmap",
            .reportWeekStartSunday: "Sunday",
            .reportWeekStartMonday: "Monday",
            .absenceCategoryDisplay: "Away",
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
            .analysisHTTPError: "API returned an error (%d): %@",
            .analysisNeedsCategoryRule: "Configure at least one valid category and description first",
            .analysisNeedsBaseURL: "Configure the model base URL first",
            .analysisNeedsModelName: "Configure the model name first",
            .analysisScreenshotMissing: "The screenshot file is missing, so analysis cannot continue",
            .analysisCancelledByUser: "Analysis was paused by the user",
            .analysisPausedAfterFailures: "Analysis was paused after 5 consecutive screenshot failures",
            .analysisPartialFailures: "Some screenshots failed to analyze. Check the network, model API, or response format",
            .analysisInvalidCategory: "The model response could not be parsed into a valid JSON analysis result",
            .analysisInvalidBaseURL: "The model base URL is invalid",
            .analysisInvalidHTTPResponse: "The model API did not return a valid HTTP response",
            .analysisRetrySupplement: "Additional requirement: return complete JSON directly and do not overthink it",
            .analysisLengthTruncated: "The model output was truncated before a complete JSON analysis result could be returned",
            .analysisInvalidCategoryWithText: "The model response could not be parsed into a valid JSON analysis result",
            .analysisOpenAIFormatInvalid: "The OpenAI-compatible API response format is invalid",
            .analysisOpenAINoText: "The OpenAI-compatible API did not return readable text",
            .analysisAnthropicFormatInvalid: "The Anthropic-compatible API response format is invalid",
            .analysisAnthropicNoText: "The Anthropic-compatible API did not return readable text",
            .analysisLMStudioFormatInvalid: "The LM Studio API response format is invalid",
            .analysisLMStudioNoText: "The LM Studio API did not return readable text",
            .analysisNoResponseData: "The model API returned no data",
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
        return categoryName
    }

    static func statusDateFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMdHm", language: language, timeZone: .current)
    }

    static func timestampFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMdHms", language: language, timeZone: .current)
    }

    static func reportDayFormatter(language: AppLanguage = .current) -> DateFormatter {
        dateFormatter(template: "yMMMd", language: language)
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
            case .dayAndHour:
                let totalHours = totalMinutes / 60
                let days = totalHours / 24
                let hours = totalHours % 24
                if days > 0, hours > 0 {
                    return "\(days) 天 \(hours) 小时"
                }
                if days > 0 {
                    return "\(days) 天"
                }

                let minutes = totalMinutes % 60
                if totalHours > 0, minutes > 0 {
                    return "\(totalHours) 小时 \(minutes) 分"
                }
                if totalHours > 0 {
                    return "\(totalHours) 小时"
                }
                return "\(minutes) 分钟"
            }
        case .english:
            switch style {
            case .minute:
                return minuteUnit(totalMinutes)
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
            case .dayAndHour:
                let totalHours = totalMinutes / 60
                let days = totalHours / 24
                let hours = totalHours % 24
                if days > 0, hours > 0 {
                    return "\(dayUnit(days)) \(hourUnit(hours))"
                }
                if days > 0 {
                    return dayUnit(days)
                }

                let minutes = totalMinutes % 60
                if totalHours > 0, minutes > 0 {
                    return "\(hourUnit(totalHours)) \(compactMinuteUnit(minutes))"
                }
                if totalHours > 0 {
                    return hourUnit(totalHours)
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
            ? AppDefaults.defaultAnalysisSummaryInstruction(language: language)
            : trimmedInstruction

        switch language {
        case .simplifiedChinese:
            return """
            你是一个工作桌面截图分类助手。
            请进行思考后，严格从下面的候选类别中选择唯一一个最匹配的类别。然后对工作内容进行一个简短的描述。
            不要过度思考，只关注截图主要部分。

            候选类别：
            \(list)
            
            描述要求：
            \(resolvedInstruction)

            返回要求：
            1. 返回的category必须与候选类别完全一致
            2. 返回格式：包含以下字段的JSON {"category": 分析得出的类别, "summary": 对截图简短的描述}
            3. 不要返回 Markdown、解释、思考过程或其他多余文本
            """
        case .english:
            return """
            You are a desktop screenshot classifier for daily work summaries.
            Think briefly, choose exactly one best-matching category from the candidates below, then write a short description of the work.
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

    private static func dayUnit(_ value: Int) -> String {
        value == 1 ? "1 day" : "\(value) days"
    }
}
