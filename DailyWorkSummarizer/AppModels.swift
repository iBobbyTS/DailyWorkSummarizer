import Foundation
import SwiftUI

enum AppDefaults {
    static let screenshotIntervalMinutes = 5
    static let analysisTimeMinutes = 18 * 60 + 30
    static let automaticAnalysisEnabled = true
    static let autoAnalysisRequiresCharger = false
    static let lmStudioContextLength = 6000
    static let maxPageSize = 31
    static let screenshotFileExtension = "jpg"
    static let apiKeyAccount = "model-api-key"
    static let absenceCategoryName = "离开"
    static let defaultCategoryRules: [CategoryRule] = [
        CategoryRule(name: "专注工作", description: "正在编码、写文档、阅读技术资料或完成明确的工作任务"),
        CategoryRule(name: "会议沟通", description: "正在开会、聊天、回消息或处理协作沟通类事项"),
        CategoryRule(name: "休息离开", description: "离开工位、娱乐浏览或进行与工作无关的活动"),
    ]
}

enum ModelProvider: String, CaseIterable, Codable, Identifiable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case lmStudio = "lm_studio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI（未测试）"
        case .anthropic:
            return "Anthropic（未测试）"
        case .lmStudio:
            return "LM Studio API"
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
        }
    }
}

enum CaptureScope: String, Codable {
    case activeDisplay = "active_display"

    var title: String {
        switch self {
        case .activeDisplay:
            return "当前活跃的屏幕"
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
        switch self {
        case .day:
            return "日报"
        case .week:
            return "周报"
        case .month:
            return "月报"
        case .year:
            return "年报"
        }
    }
}

enum ReportVisualization: String, CaseIterable, Identifiable {
    case barChart = "bar_chart"
    case heatmap = "heatmap"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .barChart:
            return "柱状图"
        case .heatmap:
            return "热力图"
        }
    }
}

enum DurationDisplayStyle {
    case minute
    case hourAndMinute
    case dayAndHour
}

enum ReportWeekStart: String, CaseIterable, Codable, Identifiable {
    case sunday
    case monday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunday:
            return "周日"
        case .monday:
            return "周一"
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

struct CategoryRule: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var description: String

    init(id: UUID = UUID(), name: String = "", description: String = "") {
        self.id = id
        self.name = name
        self.description = description
    }
}

struct AppSettingsSnapshot {
    let screenshotIntervalMinutes: Int
    let analysisTimeMinutes: Int
    let automaticAnalysisEnabled: Bool
    let autoAnalysisRequiresCharger: Bool
    let provider: ModelProvider
    let apiBaseURL: String
    let modelName: String
    let apiKey: String
    let lmStudioContextLength: Int
    let categoryRules: [CategoryRule]

    var captureScope: CaptureScope {
        .activeDisplay
    }

    var validCategoryRules: [CategoryRule] {
        categoryRules.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func nextAnalysisDate(after now: Date, calendar: Calendar = .reportCalendar) -> Date {
        let minutes = max(0, min(23 * 60 + 59, analysisTimeMinutes))
        let startOfToday = calendar.startOfDay(for: now)
        let todayTarget = calendar.date(byAdding: .minute, value: minutes, to: startOfToday) ?? now
        if todayTarget > now {
            return todayTarget
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return calendar.date(byAdding: .minute, value: minutes, to: tomorrow) ?? now
    }
}

struct ReportSourceItem: Identifiable {
    let id: Int64
    let capturedAt: Date
    let categoryName: String
    let durationMinutes: Int
}

struct ScreenshotFileRecord: Identifiable {
    let url: URL
    let capturedAt: Date
    let durationMinutes: Int

    var id: String { url.lastPathComponent }
}

struct AnalysisRuntimeState {
    let isRunning: Bool
    let isStopping: Bool
    let startedAt: Date?
    let completedCount: Int
    let totalCount: Int

    static let idle = AnalysisRuntimeState(
        isRunning: false,
        isStopping: false,
        startedAt: nil,
        completedCount: 0,
        totalCount: 0
    )
}

struct AnalysisErrorEntry: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let message: String

    init(id: UUID = UUID(), createdAt: Date = Date(), message: String) {
        self.id = id
        self.createdAt = createdAt
        self.message = message
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

struct AnalysisResponse {
    let category: String
    let rawText: String
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
    static var reportCalendar: Calendar {
        reportCalendar(firstWeekday: 1)
    }

    static func reportCalendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
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
    var endAt: Date {
        capturedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }
}

extension Double {
    func durationText(style: DurationDisplayStyle) -> String {
        let totalMinutes = max(Int((self * 60).rounded()), 0)

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
    }

    func durationText(for kind: ReportKind) -> String {
        let totalMinutes = max(Int((self * 60).rounded()), 0)
        let style: DurationDisplayStyle

        switch kind {
        case .day, .week:
            style = totalMinutes >= 60 ? .hourAndMinute : .minute
        case .month, .year:
            if totalMinutes >= 24 * 60 {
                style = .dayAndHour
            } else if totalMinutes >= 60 {
                style = .hourAndMinute
            } else {
                style = .minute
            }
        }

        return durationText(style: style)
    }
}

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("DailyWorkSummarizer.AppSettingsDidChange")
    static let appDatabaseDidChange = Notification.Name("DailyWorkSummarizer.AppDatabaseDidChange")
    static let screenshotFilesDidChange = Notification.Name("DailyWorkSummarizer.ScreenshotFilesDidChange")
    static let analysisStatusDidChange = Notification.Name("DailyWorkSummarizer.AnalysisStatusDidChange")
    static let analysisErrorsDidChange = Notification.Name("DailyWorkSummarizer.AnalysisErrorsDidChange")
}
