import Foundation
import SQLite3

final class ReportDataStore: @unchecked Sendable {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func fetchCategoryRules() throws -> [CategoryRule] {
        try connection.withLock { lock in
            try lock.ensureTableExists("category_rules")
            let stmt = try lock.prepareStatement("""
                SELECT id, name, description, color_hex
                FROM category_rules ORDER BY sort_order ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            var result: [CategoryRule] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(CategoryRule(
                    id: UUID(uuidString: lock.string(at: 0, from: stmt)) ?? UUID(),
                    name: lock.string(at: 1, from: stmt),
                    description: lock.string(at: 2, from: stmt),
                    colorHex: lock.string(at: 3, from: stmt)
                ))
            }
            return result
        }
    }

    func replaceCategoryRules(_ rules: [CategoryRule]) throws {
        try connection.withLock { lock in
            try lock.beginTransaction()
            do {
                try lock.execute("DELETE FROM category_rules;")
                let stmt = try lock.prepareStatement("""
                    INSERT INTO category_rules (id, name, description, color_hex, sort_order)
                    VALUES (?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(stmt) }

                for (index, rule) in rules.enumerated() {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try lock.bind(rule.id.uuidString, at: 1, to: stmt)
                    try lock.bind(rule.name, at: 2, to: stmt)
                    try lock.bind(rule.description, at: 3, to: stmt)
                    try lock.bind(rule.colorHex, at: 4, to: stmt)
                    sqlite3_bind_int64(stmt, 5, Int64(index))

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DatabaseError.execute("insert category_rule failed")
                    }
                }
                try lock.commitTransaction()
                postChangeNotification()
            } catch {
                let opError = error
                do { try lock.rollbackTransaction() } catch {
                    throw DatabaseError.execute(
                        "transaction failed: \(String(describing: opError)); rollback failed: \(String(describing: error))"
                    )
                }
                throw opError
            }
        }
    }

    func fetchDailyReport(for dayStart: Date) throws -> DailyReportRecord? {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                SELECT day_start, daily_summary_text, category_summaries_json, is_temporary
                FROM daily_reports WHERE day_start = ? LIMIT 1;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, dayStart.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            return DailyReportRecord(
                dayStart: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                dailySummaryText: lock.string(at: 1, from: stmt),
                categorySummaries: try decodeCategorySummaries(from: lock.string(at: 2, from: stmt)),
                isTemporary: sqlite3_column_int64(stmt, 3) != 0
            )
        }
    }

    func upsertDailyReport(
        dayStart: Date,
        dailySummaryText: String,
        categorySummaries: [String: String],
        isTemporary: Bool = false
    ) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT INTO daily_reports (day_start, daily_summary_text, category_summaries_json, is_temporary)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(day_start) DO UPDATE SET
                    daily_summary_text = excluded.daily_summary_text,
                    category_summaries_json = excluded.category_summaries_json,
                    is_temporary = excluded.is_temporary;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, dayStart.timeIntervalSince1970)
            try lock.bind(dailySummaryText, at: 2, to: stmt)
            try lock.bind(try encodeCategorySummaries(categorySummaries), at: 3, to: stmt)
            sqlite3_bind_int64(stmt, 4, isTemporary ? 1 : 0)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("upsert daily_report failed")
            }
            postChangeNotification()
        }
    }

    func fetchDailyWorkBlockSummaries() throws -> [DailyWorkBlockSummaryRecord] {
        try connection.withLock { lock in
            try lock.ensureTableExists("daily_work_block_summaries")
            let stmt = try lock.prepareStatement("""
                SELECT id, category_name, start_at, end_at, summary_text
                FROM daily_work_block_summaries
                ORDER BY start_at ASC, end_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            var records: [DailyWorkBlockSummaryRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(DailyWorkBlockSummaryRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    categoryName: lock.string(at: 1, from: stmt),
                    startAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    endAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    summaryText: lock.string(at: 4, from: stmt)
                ))
            }
            return records
        }
    }

    func fetchDailyWorkBlockSummaries(intersecting interval: DateInterval) throws -> [DailyWorkBlockSummaryRecord] {
        try connection.withLock { lock in
            try lock.ensureTableExists("daily_work_block_summaries")
            let stmt = try lock.prepareStatement("""
                SELECT id, category_name, start_at, end_at, summary_text
                FROM daily_work_block_summaries
                WHERE start_at < ? AND end_at > ?
                ORDER BY start_at ASC, end_at ASC, id ASC;
            """)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, interval.end.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, interval.start.timeIntervalSince1970)

            var records: [DailyWorkBlockSummaryRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(DailyWorkBlockSummaryRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    categoryName: lock.string(at: 1, from: stmt),
                    startAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    endAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    summaryText: lock.string(at: 4, from: stmt)
                ))
            }
            return records
        }
    }

    func upsertDailyWorkBlockSummary(
        categoryName: String,
        startAt: Date,
        endAt: Date,
        summaryText: String
    ) throws {
        try connection.withLock { lock in
            let stmt = try lock.prepareStatement("""
                INSERT INTO daily_work_block_summaries (category_name, start_at, end_at, summary_text)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(start_at, end_at) DO UPDATE SET
                    category_name = excluded.category_name,
                    summary_text = excluded.summary_text;
            """)
            defer { sqlite3_finalize(stmt) }

            try lock.bind(categoryName, at: 1, to: stmt)
            sqlite3_bind_double(stmt, 2, startAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, endAt.timeIntervalSince1970)
            try lock.bind(summaryText, at: 4, to: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.execute("upsert daily_work_block_summary failed")
            }
            postChangeNotification()
        }
    }

    func deleteDailyWorkBlockSummaries(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }

        try connection.withLock { lock in
            try lock.beginTransaction()
            do {
                let stmt = try lock.prepareStatement("DELETE FROM daily_work_block_summaries WHERE id = ?;")
                defer { sqlite3_finalize(stmt) }

                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, id)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DatabaseError.execute("delete daily_work_block_summary failed")
                    }
                }
                try lock.commitTransaction()
                postChangeNotification()
            } catch {
                let opError = error
                do { try lock.rollbackTransaction() } catch {
                    throw DatabaseError.execute(
                        "transaction failed: \(String(describing: opError)); rollback failed: \(String(describing: error))"
                    )
                }
                throw opError
            }
        }
    }

    private func encodeCategorySummaries(_ value: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeCategorySummaries(from rawValue: String) throws -> [String: String] {
        guard let data = rawValue.data(using: .utf8) else {
            throw DatabaseError.execute("daily report category summaries are not valid UTF-8")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        }
    }
}
