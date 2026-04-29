import AppKit
import Foundation
import SwiftUI

nonisolated enum AppDefaults {
    static let screenshotIntervalMinutes = 5
    static let analysisTimeMinutes = 18 * 60 + 30
    static let analysisStartupMode: AnalysisStartupMode = .scheduled
    static let autoAnalysisRequiresCharger = false
    nonisolated static let maxLogEntries = 1000
    static let lmStudioContextLength = 6000
    static let maxPageSize = 31
    static let screenshotFileExtension = "jpg"
    static let apiKeyAccount = "model-api-key.screenshot-analysis"
    static let workContentSummaryAPIKeyAccount = "model-api-key.work-content-summary"
    static let defaultImageAnalysisMethod: ImageAnalysisMethod = .multimodal
    nonisolated static let absenceCategoryName = "离开"
    static let preservedOtherCategoryName = "PRESERVED_OTHER"
    nonisolated static let temporaryReportPrefix = "TEMP_"
    nonisolated static let absenceCategoryColorHex = "#8E8E93"
    nonisolated static let categoryColorPresets = [
        "#2F7DD1",
        "#E1733B",
        "#45A564",
        "#B260C4",
        "#D7B72D",
        "#35A6B2",
        "#D94C6A",
        "#7A64D8",
        "#4B8E3F",
        "#D0832F",
        "#4C78A8",
        "#9D755D",
        "#72B7B2",
        "#F58518",
        "#54A24B",
        "#8E8E93",
    ]
    nonisolated static var defaultCategoryColorHex: String {
        categoryColorPresets[0]
    }

    nonisolated static func categoryColorPreset(at index: Int) -> String {
        categoryColorPresets[((index % categoryColorPresets.count) + categoryColorPresets.count) % categoryColorPresets.count]
    }

    nonisolated static func normalizedCategoryColorHex(_ colorHex: String?) -> String? {
        guard let colorHex else {
            return nil
        }

        let trimmed = colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawHex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard rawHex.count == 6,
              rawHex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return "#\(rawHex.uppercased())"
    }

    static func defaultSummaryInstruction(language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese:
            return "注意观察画面里所打开项目的名称、课程名称等信息，进行简要描述"
        case .english:
            return "Pay attention to the project name, course name, and other visible context in the screenshot, then write a brief description."
        }
    }

    static func defaultCategoryRules(language: AppLanguage) -> [CategoryRule] {
        switch language {
        case .simplifiedChinese:
            return [
                CategoryRule(name: "专注工作", description: "正在编码、写文档、阅读技术资料或完成明确的工作任务", colorHex: categoryColorPreset(at: 0)),
                CategoryRule(name: "会议沟通", description: "正在开会、聊天、回消息或处理协作沟通类事项", colorHex: categoryColorPreset(at: 1)),
                CategoryRule(name: "休息离开", description: "离开工位、娱乐浏览或进行与工作无关的活动", colorHex: categoryColorPreset(at: 2)),
                preservedOtherCategoryRule(language: language),
            ]
        case .english:
            return [
                CategoryRule(name: "Focused Work", description: "Coding, writing docs, reading technical materials, or completing clearly defined work", colorHex: categoryColorPreset(at: 0)),
                CategoryRule(name: "Meetings & Communication", description: "Meetings, chatting, replying to messages, or other collaboration-heavy tasks", colorHex: categoryColorPreset(at: 1)),
                CategoryRule(name: "Break / Away", description: "Away from the desk, casual browsing, entertainment, or non-work activities", colorHex: categoryColorPreset(at: 2)),
                preservedOtherCategoryRule(language: language),
            ]
        }
    }

    static func preservedOtherCategoryDescription(language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese:
            return "除以上类别外的其他工作、学习或屏幕内容。"
        case .english:
            return "Any other work, study, or on-screen content that does not fit the categories above."
        }
    }

    static func preservedOtherCategoryRule(language: AppLanguage) -> CategoryRule {
        CategoryRule(
            name: preservedOtherCategoryName,
            description: preservedOtherCategoryDescription(language: language),
            colorHex: categoryColorPreset(at: 15)
        )
    }
}

nonisolated enum AnalysisStartupMode: String, CaseIterable, Codable, Hashable, Identifiable {
    case manual
    case scheduled
    case realtime

    var id: String { rawValue }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .manual:
            return L10n.string(.analysisStartupModeManual, language: language)
        case .scheduled:
            return L10n.string(.analysisStartupModeScheduled, language: language)
        case .realtime:
            return L10n.string(.analysisStartupModeRealtime, language: language)
        }
    }
}

nonisolated enum ImageAnalysisMethod: String, CaseIterable, Codable, Identifiable {
    case ocr
    case multimodal

    var id: String { rawValue }

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .ocr:
            return L10n.string(.imageAnalysisMethodOCR, language: language)
        case .multimodal:
            return L10n.string(.imageAnalysisMethodMultimodal, language: language)
        }
    }
}

nonisolated enum ModelProvider: String, CaseIterable, Codable, Identifiable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case lmStudio = "lm_studio"
    case appleIntelligence = "apple_intelligence"

    var id: String { rawValue }

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .openAI:
            return L10n.string(.providerOpenAIUntested, language: language)
        case .anthropic:
            return L10n.string(.providerAnthropicUntested, language: language)
        case .lmStudio:
            return "LM Studio API"
        case .appleIntelligence:
            return L10n.string(.providerAppleIntelligence, language: language)
        }
    }

    var requiresRemoteConfiguration: Bool {
        switch self {
        case .openAI, .anthropic, .lmStudio:
            return true
        case .appleIntelligence:
            return false
        }
    }

    func requestURL(from baseURLString: String) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let baseURL = components.url else {
            return nil
        }

        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch self {
        case .openAI:
            if normalizedPath.hasSuffix("chat/completions") {
                return baseURL
            }
            if normalizedPath.hasSuffix("v1") {
                return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
            }
            components.path = components.path.hasSuffix("/") ? components.path + "v1/chat/completions" : components.path + "/v1/chat/completions"
            return components.url
        case .anthropic:
            if normalizedPath.hasSuffix("messages") {
                return baseURL
            }
            if normalizedPath.hasSuffix("v1") {
                return baseURL.appendingPathComponent("messages")
            }
            components.path = components.path.hasSuffix("/") ? components.path + "v1/messages" : components.path + "/v1/messages"
            return components.url
        case .lmStudio:
            if normalizedPath.hasSuffix("api/v1/chat") {
                return baseURL
            }
            if normalizedPath.hasSuffix("api/v1") {
                return baseURL.appendingPathComponent("chat")
            }
            if normalizedPath.hasSuffix("api") {
                return baseURL.appendingPathComponent("v1").appendingPathComponent("chat")
            }
            components.path = components.path.hasSuffix("/") ? components.path + "api/v1/chat" : components.path + "/api/v1/chat"
            return components.url
        case .appleIntelligence:
            return nil
        }
    }
}

enum ScreenshotScope: String, Codable {
    case activeDisplay = "active_display"

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .activeDisplay:
            return L10n.string(.screenshotScopeActiveDisplay, language: language)
        }
    }
}

enum ReportKind: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .day:
            return L10n.string(.reportKindDay, language: language)
        case .week:
            return L10n.string(.reportKindWeek, language: language)
        case .month:
            return L10n.string(.reportKindMonth, language: language)
        case .year:
            return L10n.string(.reportKindYear, language: language)
        }
    }
}

enum ReportVisualization: String, CaseIterable, Identifiable {
    case barChart = "bar_chart"
    case heatmap = "heatmap"

    var id: String { rawValue }

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .barChart:
            return L10n.string(.reportVisualizationBar, language: language)
        case .heatmap:
            return L10n.string(.reportVisualizationHeatmap, language: language)
        }
    }
}

enum DurationDisplayStyle {
    case minute
    case hourOnly
    case hourAndMinute
}

enum ReportWeekStart: String, CaseIterable, Codable, Identifiable {
    case sunday
    case monday

    var id: String { rawValue }

    var title: String {
        title(in: .current)
    }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .sunday:
            return L10n.string(.reportWeekStartSunday, language: language)
        case .monday:
            return L10n.string(.reportWeekStartMonday, language: language)
        }
    }

    var calendarFirstWeekday: Int {
        switch self {
        case .sunday:
            return 1
        case .monday:
            return 2
        }
    }
}

nonisolated struct CategoryRule: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var description: String
    var colorHex: String

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        colorHex: String = AppDefaults.defaultCategoryColorHex
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.colorHex = AppDefaults.normalizedCategoryColorHex(colorHex) ?? AppDefaults.defaultCategoryColorHex
    }

    var isPreservedOther: Bool {
        name == AppDefaults.preservedOtherCategoryName
    }

    func displayName(in language: AppLanguage) -> String {
        isPreservedOther ? L10n.displayCategoryName(name, language: language) : name
    }

    var displayColor: Color {
        Color(hexRGB: colorHex)
    }
}

nonisolated struct ModelProfileSettings: Equatable {
    let provider: ModelProvider
    let apiBaseURL: String
    let modelName: String
    let apiKey: String
    let lmStudioContextLength: Int
    let imageAnalysisMethod: ImageAnalysisMethod
}

nonisolated struct AppSettingsSnapshot {
    let screenshotIntervalMinutes: Int
    let analysisTimeMinutes: Int
    let analysisStartupMode: AnalysisStartupMode
    let autoAnalysisRequiresCharger: Bool
    let appLanguage: AppLanguage
    let summaryInstruction: String
    let screenshotAnalysisModelProfile: ModelProfileSettings
    let workContentSummaryModelProfile: ModelProfileSettings
    let categoryRules: [CategoryRule]

    var screenshotScope: ScreenshotScope {
        .activeDisplay
    }

    var provider: ModelProvider {
        screenshotAnalysisModelProfile.provider
    }

    var apiBaseURL: String {
        screenshotAnalysisModelProfile.apiBaseURL
    }

    var modelName: String {
        screenshotAnalysisModelProfile.modelName
    }

    var apiKey: String {
        screenshotAnalysisModelProfile.apiKey
    }

    var lmStudioContextLength: Int {
        screenshotAnalysisModelProfile.lmStudioContextLength
    }

    var imageAnalysisMethod: ImageAnalysisMethod {
        screenshotAnalysisModelProfile.imageAnalysisMethod
    }

    var validCategoryRules: [CategoryRule] {
        categoryRules.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func nextAnalysisDate(after now: Date, calendar: Calendar? = nil) -> Date {
        let resolvedCalendar = calendar ?? .reportCalendar(language: appLanguage)
        let minutes = max(0, min(23 * 60 + 59, analysisTimeMinutes))
        let startOfToday = resolvedCalendar.startOfDay(for: now)
        let todayTarget = resolvedCalendar.date(byAdding: .minute, value: minutes, to: startOfToday) ?? now
        if todayTarget > now {
            return todayTarget
        }
        let tomorrow = resolvedCalendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return resolvedCalendar.date(byAdding: .minute, value: minutes, to: tomorrow) ?? now
    }
}

struct ReportSourceItem: Identifiable {
    let id: Int64
    let capturedAt: Date
    let categoryName: String
    let durationMinutes: Int
}

struct DailyReportActivityItem: Identifiable {
    let id: Int64
    let capturedAt: Date
    let categoryName: String
    let durationMinutes: Int
    let itemSummaryText: String?
}

struct DailyReportRecord: Equatable {
    let dayStart: Date
    let dailySummaryText: String
    let categorySummaries: [String: String]

    nonisolated
    var isTemporary: Bool {
        dailySummaryText.hasPrefix(AppDefaults.temporaryReportPrefix)
    }

    nonisolated
    var displayDailySummaryText: String {
        Self.displayText(from: dailySummaryText)
    }

    nonisolated
    func displayCategorySummary(for category: String) -> String? {
        categorySummaries[category].map(Self.displayText(from:))
    }

    nonisolated
    func isTemporaryCategorySummary(for category: String) -> Bool {
        categorySummaries[category]?.hasPrefix(AppDefaults.temporaryReportPrefix) == true
    }

    nonisolated
    private static func displayText(from value: String) -> String {
        guard value.hasPrefix(AppDefaults.temporaryReportPrefix) else {
            return value
        }

        return String(value.dropFirst(AppDefaults.temporaryReportPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ScreenshotFileRecord: Identifiable {
    let url: URL
    let capturedAt: Date
    let durationMinutes: Int

    var id: String { url.lastPathComponent }
}

enum AnalysisStoppingStage {
    case stoppingGeneration
    case unloadingModel

    var analyzeNowLocalizationKey: L10n.Key {
        switch self {
        case .stoppingGeneration:
            return .menuAnalyzeNowPausingStoppingGeneration
        case .unloadingModel:
            return .menuAnalyzeNowPausingUnloadingModel
        }
    }

    var statusSummaryLocalizationKey: L10n.Key {
        switch self {
        case .stoppingGeneration:
            return .menuSummaryPausingStoppingGeneration
        case .unloadingModel:
            return .menuSummaryPausingUnloadingModel
        }
    }
}

struct AnalysisRuntimeState {
    let isRunning: Bool
    let stoppingStage: AnalysisStoppingStage?
    let startedAt: Date?
    let completedCount: Int
    let totalCount: Int

    var isStopping: Bool { stoppingStage != nil }

    static let idle = AnalysisRuntimeState(
        isRunning: false,
        stoppingStage: nil,
        startedAt: nil,
        completedCount: 0,
        totalCount: 0
    )
}

enum AppLogLevel: String, Codable, CaseIterable, Identifiable {
    case error
    case log

    var id: String { rawValue }

    func title(in language: AppLanguage) -> String {
        switch self {
        case .error:
            return L10n.string(.logsLevelError, language: language)
        case .log:
            return L10n.string(.logsLevelLog, language: language)
        }
    }
}

enum AppLogSource: String, Codable {
    case analysis = "analysis"
    case lmStudio = "lm_studio"
}

enum AppLogFilter: String, CaseIterable, Identifiable {
    case all
    case error
    case log

    var id: String { rawValue }

    func includes(level: AppLogLevel) -> Bool {
        switch self {
        case .all:
            return true
        case .error:
            return level == .error
        case .log:
            return level == .log
        }
    }

    func title(in language: AppLanguage) -> String {
        switch (self, language) {
        case (.all, .simplifiedChinese):
            return "全部"
        case (.all, .english):
            return "All"
        case (.error, _):
            return L10n.string(.logsLevelError, language: language)
        case (.log, _):
            return L10n.string(.logsLevelLog, language: language)
        }
    }
}

struct AppLogEntry: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let level: AppLogLevel
    let source: AppLogSource
    let message: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        level: AppLogLevel,
        source: AppLogSource,
        message: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.level = level
        self.source = source
        self.message = message
    }

    func exportText(in language: AppLanguage) -> String {
        let timestamp = L10n.timestampFormatter(language: language).string(from: createdAt)
        return "\(timestamp) [\(level.title(in: language))] \(message)"
    }
}

struct ReportRange: Identifiable, Hashable {
    let id: String
    let label: String
    let interval: DateInterval
    let totalHours: Double
    let averageHoursPerDay: Double
    let itemCount: Int
}

struct CategoryDuration: Identifiable {
    let category: String
    let hours: Double

    var id: String { category }
}

struct HeatmapEvent: Identifiable {
    let id: String
    let category: String
    let start: Date
    let end: Date
    let durationMinutes: Int
}

nonisolated struct AnalysisResponse {
    let category: String
    let summary: String
}

nonisolated struct ModelRequestTiming {
    let roundTripSeconds: TimeInterval?
    let serverProcessingSeconds: TimeInterval?
}

nonisolated struct LMStudioTiming {
    let modelLoadTimeSeconds: TimeInterval?
    let timeToFirstTokenSeconds: TimeInterval?
    let totalOutputTokens: Int?
    let tokensPerSecond: Double?

    var outputTimeSeconds: TimeInterval? {
        guard let totalOutputTokens,
              let tokensPerSecond,
              totalOutputTokens > 0,
              tokensPerSecond > 0 else {
            return nil
        }
        return Double(totalOutputTokens) / tokensPerSecond
    }
}

nonisolated struct ModelTestResult {
    let provider: ModelProvider
    let imageAnalysisMethod: ImageAnalysisMethod
    let response: AnalysisResponse
    let requestTiming: ModelRequestTiming?
    let lmStudioTiming: LMStudioTiming?
    let ocrText: String?
    let reasoningText: String?
}

extension Array where Element == CategoryRule {
    var hasValidRule: Bool {
        contains {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension Calendar {
    nonisolated static var reportCalendar: Calendar {
        reportCalendar(language: .current, firstWeekday: 1)
    }

    nonisolated static func reportCalendar(language: AppLanguage) -> Calendar {
        reportCalendar(language: language, firstWeekday: 1)
    }

    nonisolated static func reportCalendar(firstWeekday: Int) -> Calendar {
        reportCalendar(language: .current, firstWeekday: firstWeekday)
    }

    nonisolated static func reportCalendar(language: AppLanguage, firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}

extension Date {
    func startOfWeek(calendar: Calendar = .reportCalendar) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return calendar.date(from: components) ?? calendar.startOfDay(for: self)
    }

    func monthStart(calendar: Calendar = .reportCalendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? calendar.startOfDay(for: self)
    }

    func yearStart(calendar: Calendar = .reportCalendar) -> Date {
        let components = calendar.dateComponents([.year], from: self)
        return calendar.date(from: components) ?? calendar.startOfDay(for: self)
    }
}

extension ReportSourceItem {
    nonisolated var endAt: Date {
        capturedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}

extension Double {
    func durationText(style: DurationDisplayStyle, language: AppLanguage = .current) -> String {
        let totalMinutes = max(Int((self * 60).rounded()), 0)
        return L10n.durationText(totalMinutes: totalMinutes, style: style, language: language)
    }

    func durationText(for _: ReportKind, language: AppLanguage = .current) -> String {
        let totalMinutes = max(Int((self * 60).rounded()), 0)
        let style: DurationDisplayStyle

        if totalMinutes < 60 {
            style = .minute
        } else if totalMinutes < 6_000 {
            style = .hourAndMinute
        } else {
            style = .hourOnly
        }

        return durationText(style: style, language: language)
    }
}

extension Color {
    nonisolated init(hexRGB: String) {
        let normalized = AppDefaults.normalizedCategoryColorHex(hexRGB) ?? AppDefaults.defaultCategoryColorHex
        let hex = String(normalized.dropFirst())
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value & 0xFF0000) >> 16) / 255.0
        let green = Double((value & 0x00FF00) >> 8) / 255.0
        let blue = Double(value & 0x0000FF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    var hexRGB: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return nil
        }

        let red = max(0, min(255, Int((color.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((color.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((color.blueComponent * 255).rounded())))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("DeskBrief.AppSettingsDidChange")
    static let appDatabaseDidChange = Notification.Name("DeskBrief.AppDatabaseDidChange")
    static let screenshotFileSaved = Notification.Name("DeskBrief.ScreenshotFileSaved")
    static let screenshotFilesDidChange = Notification.Name("DeskBrief.ScreenshotFilesDidChange")
    static let analysisStatusDidChange = Notification.Name("DeskBrief.AnalysisStatusDidChange")
    static let appLogsDidChange = Notification.Name("DeskBrief.AppLogsDidChange")
}
