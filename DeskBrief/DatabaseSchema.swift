import Foundation
import GRDB

nonisolated enum DatabaseSchema {
    static let currentVersion: Int32 = 1
    private static let baseSchemaVersion: Int32 = 1

    private struct Migration {
        let targetVersion: Int32
        let migrate: (Database) throws -> Void
    }

    // Add future schema changes here as one-step migrations from version N to N + 1.
    private static let migrations: [Migration] = []

    static func create(connection: DatabaseConnection) throws {
        try connection.write { db in
            try migrate(db: db)
        }
    }

    static func migrate(connection: DatabaseConnection) throws {
        try connection.write { db in
            try migrate(db: db)
        }
    }

    static func validate(connection: DatabaseConnection) throws {
        try connection.read { db in
            try validateCurrentSchema(db: db)
        }
    }

    private static func migrate(db: Database) throws {
        let storedVersion = try loadVersion(db: db)
        guard storedVersion <= currentVersion else {
            throw DatabaseError.execute(
                "unsupported database schema version \(storedVersion); app supports \(currentVersion)"
            )
        }

        let startVersion: Int32
        if storedVersion == 0 {
            if try hasKnownApplicationTables(db: db) {
                try validateVersion1Schema(db: db)
            } else {
                try createVersion1Schema(db: db)
            }
            try setVersion(db: db, version: baseSchemaVersion)
            startVersion = baseSchemaVersion
        } else {
            startVersion = storedVersion
        }

        try runMigrations(db: db, from: startVersion)
        try validateCurrentSchema(db: db)
    }

    private static func runMigrations(db: Database, from storedVersion: Int32) throws {
        var version = storedVersion
        for migration in migrations.sorted(by: { $0.targetVersion < $1.targetVersion })
            where migration.targetVersion > version && migration.targetVersion <= currentVersion {
            guard migration.targetVersion == version + 1 else {
                throw DatabaseError.execute(
                    "missing database migration from version \(version) to \(migration.targetVersion)"
                )
            }
            try migration.migrate(db)
            version = migration.targetVersion
            try setVersion(db: db, version: version)
        }

        guard version == currentVersion else {
            throw DatabaseError.execute(
                "missing database migration from version \(version) to \(currentVersion)"
            )
        }
    }

    private static func createVersion1Schema(db: Database) throws {
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

    private static func hasKnownApplicationTables(db: Database) throws -> Bool {
        for tableName in version1RequiredColumns.keys where try db.tableExists(tableName) {
            return true
        }
        return false
    }

    private static func validateCurrentSchema(db: Database) throws {
        try validateVersion1Schema(db: db)
    }

    private static func validateVersion1Schema(db: Database) throws {
        try validateRequiredColumns(db: db, requiredColumns: version1RequiredColumns)
        try validateRequiredIndexes(db: db, requiredIndexes: version1RequiredIndexes)
    }

    private static func validateRequiredColumns(
        db: Database,
        requiredColumns: [String: Set<String>]
    ) throws {
        for tableName in requiredColumns.keys.sorted() {
            guard try db.tableExists(tableName) else {
                throw DatabaseError.execute("database schema validation failed: missing required table \(tableName)")
            }

            let existingColumns = try columnNames(db: db, tableName: tableName)
            let missingColumns = requiredColumns[tableName, default: []].subtracting(existingColumns).sorted()
            guard missingColumns.isEmpty else {
                throw DatabaseError.execute(
                    "database schema validation failed for \(tableName): missing columns \(missingColumns.joined(separator: ", "))"
                )
            }
        }
    }

    private static func validateRequiredIndexes(
        db: Database,
        requiredIndexes: Set<String>
    ) throws {
        for indexName in requiredIndexes.sorted() {
            let existingName = try String.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?;",
                arguments: [indexName]
            )
            guard existingName != nil else {
                throw DatabaseError.execute("database schema validation failed: missing required index \(indexName)")
            }
        }
    }

    private static func columnNames(db: Database, tableName: String) throws -> Set<String> {
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(\(tableName.quotedDatabaseIdentifier));"
        )
        return Set(rows.compactMap { row -> String? in
            row["name"]
        })
    }

    private static let version1RequiredColumns: [String: Set<String>] = [
        CategoryRuleRow.databaseTableName: [
            "id",
            "name",
            "description",
            "color_hex",
            "sort_order",
        ],
        AnalysisRunRow.databaseTableName: [
            "id",
            "status",
            "model_name",
            "total_items",
            "success_count",
            "failure_count",
            "input_mean_tokens",
            "input_max_tokens",
            "output_mean_tokens",
            "output_max_tokens",
            "average_item_duration_seconds",
            "error_message",
            "created_at",
        ],
        SummaryRunRow.databaseTableName: [
            "id",
            "analysis_run_id",
            "status",
            "model_name",
            "total_items",
            "success_count",
            "failure_count",
            "input_mean_tokens",
            "input_max_tokens",
            "output_mean_tokens",
            "output_max_tokens",
            "average_item_duration_seconds",
            "error_message",
            "created_at",
        ],
        AnalysisResultRow.databaseTableName: [
            "id",
            "captured_at",
            "category_name",
            "summary_text",
            "duration_minutes_snapshot",
        ],
        DailyWorkBlockSummaryRow.databaseTableName: [
            "id",
            "category_name",
            "start_at",
            "end_at",
            "summary_text",
        ],
        DailyReportRow.databaseTableName: [
            "id",
            "day_start",
            "daily_summary_text",
            "category_summaries_json",
            "is_temporary",
        ],
        AppLogRow.databaseTableName: [
            "id",
            "created_at",
            "level",
            "source",
            "message",
        ],
    ]

    private static let version1RequiredIndexes: Set<String> = [
        "idx_analysis_results_category_name",
        "idx_analysis_results_captured_at_unique",
        "idx_daily_work_block_summaries_interval",
        "idx_daily_work_block_summaries_category_name",
        "idx_daily_reports_day_start",
        "idx_app_logs_created_at",
    ]
}
