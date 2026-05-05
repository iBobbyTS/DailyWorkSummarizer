import Foundation
import SQLite3

enum DatabaseSchema {
    static let currentVersion: Int32 = 1

    static func create(connection: DatabaseConnection) throws {
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS category_rules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                color_hex TEXT NOT NULL,
                sort_order INTEGER NOT NULL
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS analysis_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                status TEXT NOT NULL,
                model_name TEXT NOT NULL,
                total_items INTEGER NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                input_mean_tokens DOUBLE,
                input_max_tokens INTEGER,
                output_mean_tokens DOUBLE,
                output_max_tokens INTEGER,
                average_item_duration_seconds DOUBLE,
                error_message TEXT,
                created_at DOUBLE NOT NULL
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS summary_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                analysis_run_id INTEGER,
                status TEXT NOT NULL,
                model_name TEXT NOT NULL,
                total_items INTEGER NOT NULL,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,
                input_mean_tokens DOUBLE,
                input_max_tokens INTEGER,
                output_mean_tokens DOUBLE,
                output_max_tokens INTEGER,
                average_item_duration_seconds DOUBLE,
                error_message TEXT,
                created_at DOUBLE NOT NULL,
                FOREIGN KEY (analysis_run_id) REFERENCES analysis_runs(id)
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS analysis_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at DOUBLE NOT NULL,
                category_name TEXT,
                summary_text TEXT,
                duration_minutes_snapshot INTEGER NOT NULL
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS daily_work_block_summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category_name TEXT NOT NULL,
                start_at DOUBLE NOT NULL,
                end_at DOUBLE NOT NULL,
                summary_text TEXT NOT NULL,
                UNIQUE(start_at, end_at)
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS daily_reports (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                day_start DOUBLE NOT NULL UNIQUE,
                daily_summary_text TEXT NOT NULL,
                category_summaries_json TEXT NOT NULL,
                is_temporary INTEGER NOT NULL DEFAULT 0
            );
        """)

        try connection.execute("""
            CREATE TABLE IF NOT EXISTS app_logs (
                id TEXT PRIMARY KEY,
                created_at DOUBLE NOT NULL,
                level TEXT NOT NULL,
                source TEXT NOT NULL,
                message TEXT NOT NULL
            );
        """)

        try connection.execute("CREATE INDEX IF NOT EXISTS idx_analysis_results_category_name ON analysis_results (category_name, captured_at DESC);")
        try connection.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_analysis_results_captured_at_unique ON analysis_results (captured_at);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_daily_work_block_summaries_interval ON daily_work_block_summaries (start_at ASC, end_at ASC);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_daily_work_block_summaries_category_name ON daily_work_block_summaries (category_name, start_at ASC);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_daily_reports_day_start ON daily_reports (day_start DESC);")
        try connection.execute("CREATE INDEX IF NOT EXISTS idx_app_logs_created_at ON app_logs (created_at DESC);")

        try setVersion(connection: connection, version: currentVersion)
    }

    static func setVersion(connection: DatabaseConnection, version: Int32) throws {
        try connection.execute("PRAGMA user_version = \(version);")
    }

    static func loadVersion(connection: DatabaseConnection) throws -> Int32 {
        try connection.execute("PRAGMA user_version;")
        return 0
    }
}
