import Foundation
import GRDB

enum DatabaseSchema {
    static let currentVersion: Int32 = 1

    static func create(connection: DatabaseConnection) throws {
        try connection.write { db in
            try db.create(table: CategoryRuleRow.databaseTableName, ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("description", .text).notNull()
                table.column("color_hex", .text).notNull()
                table.column("sort_order", .integer).notNull()
            }

            try db.create(table: AnalysisRunRow.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("status", .text).notNull()
                table.column("model_name", .text).notNull()
                table.column("total_items", .integer).notNull()
                table.column("success_count", .integer).notNull().defaults(to: 0)
                table.column("failure_count", .integer).notNull().defaults(to: 0)
                table.column("input_mean_tokens", .double)
                table.column("input_max_tokens", .integer)
                table.column("output_mean_tokens", .double)
                table.column("output_max_tokens", .integer)
                table.column("average_item_duration_seconds", .double)
                table.column("error_message", .text)
                table.column("created_at", .double).notNull()
            }

            try db.create(table: SummaryRunRow.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("analysis_run_id", .integer)
                    .references(AnalysisRunRow.databaseTableName)
                table.column("status", .text).notNull()
                table.column("model_name", .text).notNull()
                table.column("total_items", .integer).notNull()
                table.column("success_count", .integer).notNull().defaults(to: 0)
                table.column("failure_count", .integer).notNull().defaults(to: 0)
                table.column("input_mean_tokens", .double)
                table.column("input_max_tokens", .integer)
                table.column("output_mean_tokens", .double)
                table.column("output_max_tokens", .integer)
                table.column("average_item_duration_seconds", .double)
                table.column("error_message", .text)
                table.column("created_at", .double).notNull()
            }

            try db.create(table: AnalysisResultRow.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("captured_at", .double).notNull()
                table.column("category_name", .text)
                table.column("summary_text", .text)
                table.column("duration_minutes_snapshot", .integer).notNull()
            }

            try db.create(table: DailyWorkBlockSummaryRow.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("category_name", .text).notNull()
                table.column("start_at", .double).notNull()
                table.column("end_at", .double).notNull()
                table.column("summary_text", .text).notNull()
                table.uniqueKey(["start_at", "end_at"])
            }

            try db.create(table: DailyReportRow.databaseTableName, ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("day_start", .double).notNull().unique()
                table.column("daily_summary_text", .text).notNull()
                table.column("category_summaries_json", .text).notNull()
                table.column("is_temporary", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: AppLogRow.databaseTableName, ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .double).notNull()
                table.column("level", .text).notNull()
                table.column("source", .text).notNull()
                table.column("message", .text).notNull()
            }

            try db.create(
                index: "idx_analysis_results_category_name",
                on: AnalysisResultRow.databaseTableName,
                expressions: [AnalysisResultRow.Columns.categoryName, SQL("captured_at DESC")],
                options: .ifNotExists
            )
            try db.create(
                index: "idx_analysis_results_captured_at_unique",
                on: AnalysisResultRow.databaseTableName,
                columns: ["captured_at"],
                unique: true,
                ifNotExists: true
            )
            try db.create(
                index: "idx_daily_work_block_summaries_interval",
                on: DailyWorkBlockSummaryRow.databaseTableName,
                columns: ["start_at", "end_at"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_daily_work_block_summaries_category_name",
                on: DailyWorkBlockSummaryRow.databaseTableName,
                columns: ["category_name", "start_at"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_daily_reports_day_start",
                on: DailyReportRow.databaseTableName,
                expressions: [SQL("day_start DESC")],
                options: .ifNotExists
            )
            try db.create(
                index: "idx_app_logs_created_at",
                on: AppLogRow.databaseTableName,
                expressions: [SQL("created_at DESC")],
                options: .ifNotExists
            )

            try setVersion(db: db, version: currentVersion)
        }
    }

    static func setVersion(connection: DatabaseConnection, version: Int32) throws {
        try connection.write { db in
            try setVersion(db: db, version: version)
        }
    }

    static func loadVersion(connection: DatabaseConnection) throws -> Int32 {
        try connection.read { db in
            try loadVersion(db: db)
        }
    }

    private static func setVersion(db: Database, version: Int32) throws {
        try db.execute(sql: "PRAGMA user_version = \(version);")
    }

    private static func loadVersion(db: Database) throws -> Int32 {
        try Int32.fetchOne(db, sql: "PRAGMA user_version;") ?? 0
    }
}
