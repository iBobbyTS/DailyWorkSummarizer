import Foundation
import GRDB

nonisolated struct CategoryRuleRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "category_rules"

    var id: String
    var name: String
    var description: String
    var colorHex: String
    var sortOrder: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let description = Column(CodingKeys.description)
        static let colorHex = Column(CodingKeys.colorHex)
        static let sortOrder = Column(CodingKeys.sortOrder)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case colorHex = "color_hex"
        case sortOrder = "sort_order"
    }
}

nonisolated struct AnalysisRunRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "analysis_runs"

    var id: Int64?
    var status: String
    var modelName: String
    var totalItems: Int
    var successCount: Int
    var failureCount: Int
    var inputMeanTokens: Double?
    var inputMaxTokens: Int?
    var outputMeanTokens: Double?
    var outputMaxTokens: Int?
    var averageItemDurationSeconds: Double?
    var errorMessage: String?
    var createdAt: Double

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let status = Column(CodingKeys.status)
        static let modelName = Column(CodingKeys.modelName)
        static let totalItems = Column(CodingKeys.totalItems)
        static let successCount = Column(CodingKeys.successCount)
        static let failureCount = Column(CodingKeys.failureCount)
        static let inputMeanTokens = Column(CodingKeys.inputMeanTokens)
        static let inputMaxTokens = Column(CodingKeys.inputMaxTokens)
        static let outputMeanTokens = Column(CodingKeys.outputMeanTokens)
        static let outputMaxTokens = Column(CodingKeys.outputMaxTokens)
        static let averageItemDurationSeconds = Column(CodingKeys.averageItemDurationSeconds)
        static let errorMessage = Column(CodingKeys.errorMessage)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case modelName = "model_name"
        case totalItems = "total_items"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case inputMeanTokens = "input_mean_tokens"
        case inputMaxTokens = "input_max_tokens"
        case outputMeanTokens = "output_mean_tokens"
        case outputMaxTokens = "output_max_tokens"
        case averageItemDurationSeconds = "average_item_duration_seconds"
        case errorMessage = "error_message"
        case createdAt = "created_at"
    }
}

nonisolated struct SummaryRunRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "summary_runs"

    var id: Int64?
    var analysisRunID: Int64?
    var status: String
    var modelName: String
    var totalItems: Int
    var successCount: Int
    var failureCount: Int
    var inputMeanTokens: Double?
    var inputMaxTokens: Int?
    var outputMeanTokens: Double?
    var outputMaxTokens: Int?
    var averageItemDurationSeconds: Double?
    var errorMessage: String?
    var createdAt: Double

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let analysisRunID = Column(CodingKeys.analysisRunID)
        static let status = Column(CodingKeys.status)
        static let modelName = Column(CodingKeys.modelName)
        static let totalItems = Column(CodingKeys.totalItems)
        static let successCount = Column(CodingKeys.successCount)
        static let failureCount = Column(CodingKeys.failureCount)
        static let inputMeanTokens = Column(CodingKeys.inputMeanTokens)
        static let inputMaxTokens = Column(CodingKeys.inputMaxTokens)
        static let outputMeanTokens = Column(CodingKeys.outputMeanTokens)
        static let outputMaxTokens = Column(CodingKeys.outputMaxTokens)
        static let averageItemDurationSeconds = Column(CodingKeys.averageItemDurationSeconds)
        static let errorMessage = Column(CodingKeys.errorMessage)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case analysisRunID = "analysis_run_id"
        case status
        case modelName = "model_name"
        case totalItems = "total_items"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case inputMeanTokens = "input_mean_tokens"
        case inputMaxTokens = "input_max_tokens"
        case outputMeanTokens = "output_mean_tokens"
        case outputMaxTokens = "output_max_tokens"
        case averageItemDurationSeconds = "average_item_duration_seconds"
        case errorMessage = "error_message"
        case createdAt = "created_at"
    }
}

nonisolated struct AnalysisResultRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "analysis_results"

    var id: Int64?
    var capturedAt: Double
    var categoryName: String?
    var summaryText: String?
    var durationMinutesSnapshot: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let capturedAt = Column(CodingKeys.capturedAt)
        static let categoryName = Column(CodingKeys.categoryName)
        static let summaryText = Column(CodingKeys.summaryText)
        static let durationMinutesSnapshot = Column(CodingKeys.durationMinutesSnapshot)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case categoryName = "category_name"
        case summaryText = "summary_text"
        case durationMinutesSnapshot = "duration_minutes_snapshot"
    }
}

nonisolated struct DailyWorkBlockSummaryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "daily_work_block_summaries"

    var id: Int64?
    var categoryName: String
    var startAt: Double
    var endAt: Double
    var summaryText: String

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let categoryName = Column(CodingKeys.categoryName)
        static let startAt = Column(CodingKeys.startAt)
        static let endAt = Column(CodingKeys.endAt)
        static let summaryText = Column(CodingKeys.summaryText)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case categoryName = "category_name"
        case startAt = "start_at"
        case endAt = "end_at"
        case summaryText = "summary_text"
    }
}

nonisolated struct DailyReportRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "daily_reports"

    var id: Int64?
    var dayStart: Double
    var dailySummaryText: String
    var categorySummariesJSON: String
    var isTemporary: Int

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let dayStart = Column(CodingKeys.dayStart)
        static let dailySummaryText = Column(CodingKeys.dailySummaryText)
        static let categorySummariesJSON = Column(CodingKeys.categorySummariesJSON)
        static let isTemporary = Column(CodingKeys.isTemporary)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dayStart = "day_start"
        case dailySummaryText = "daily_summary_text"
        case categorySummariesJSON = "category_summaries_json"
        case isTemporary = "is_temporary"
    }
}

nonisolated struct AppLogRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "app_logs"

    var id: String
    var createdAt: Double
    var level: String
    var source: String
    var message: String

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let createdAt = Column(CodingKeys.createdAt)
        static let level = Column(CodingKeys.level)
        static let source = Column(CodingKeys.source)
        static let message = Column(CodingKeys.message)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case level
        case source
        case message
    }
}
