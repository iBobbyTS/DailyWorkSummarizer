import Foundation
import GRDB

nonisolated final class ReportDataStore: @unchecked Sendable {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    func fetchCategoryRules() throws -> [CategoryRule] {
        try connection.read { db in
            try ensureTableExists(CategoryRuleRow.databaseTableName, db: db)
            return try CategoryRuleRow
                .order(CategoryRuleRow.Columns.sortOrder)
                .fetchAll(db)
                .map { row in
                    CategoryRule(
                        id: UUID(uuidString: row.id) ?? UUID(),
                        name: row.name,
                        description: row.description,
                        colorHex: row.colorHex
                    )
                }
        }
    }

    func replaceCategoryRules(_ rules: [CategoryRule]) throws {
        try connection.write { db in
            try CategoryRuleRow.deleteAll(db)
            for (index, rule) in rules.enumerated() {
                try CategoryRuleRow(
                    id: rule.id.uuidString,
                    name: rule.name,
                    description: rule.description,
                    colorHex: rule.colorHex,
                    sortOrder: index
                ).insert(db)
            }
            postChangeNotification()
        }
    }

    func fetchDailyReport(for dayStart: Date) throws -> DailyReportRecord? {
        try connection.read { db in
            guard let row = try DailyReportRow
                .filter(DailyReportRow.Columns.dayStart == dayStart.timeIntervalSince1970)
                .limit(1)
                .fetchOne(db) else {
                return nil
            }

            return DailyReportRecord(
                dayStart: Date(timeIntervalSince1970: row.dayStart),
                dailySummaryText: row.dailySummaryText,
                categorySummaries: try decodeCategorySummaries(from: row.categorySummariesJSON),
                isTemporary: row.isTemporary != 0
            )
        }
    }

    func upsertDailyReport(
        dayStart: Date,
        dailySummaryText: String,
        categorySummaries: [String: String],
        isTemporary: Bool = false
    ) throws {
        try connection.write { db in
            let dayStartValue = dayStart.timeIntervalSince1970
            if let existing = try DailyReportRow
                .filter(DailyReportRow.Columns.dayStart == dayStartValue)
                .limit(1)
                .fetchOne(db) {
                try DailyReportRow
                    .filter(DailyReportRow.Columns.id == existing.id)
                    .updateAll(db, [
                        DailyReportRow.Columns.dailySummaryText.set(to: dailySummaryText),
                        DailyReportRow.Columns.categorySummariesJSON.set(to: try encodeCategorySummaries(categorySummaries)),
                        DailyReportRow.Columns.isTemporary.set(to: isTemporary ? 1 : 0),
                    ])
            } else {
                try DailyReportRow(
                    id: nil,
                    dayStart: dayStartValue,
                    dailySummaryText: dailySummaryText,
                    categorySummariesJSON: try encodeCategorySummaries(categorySummaries),
                    isTemporary: isTemporary ? 1 : 0
                ).insert(db)
            }
            postChangeNotification()
        }
    }

    func fetchDailyWorkBlockSummaries() throws -> [DailyWorkBlockSummaryRecord] {
        try connection.read { db in
            try ensureTableExists(DailyWorkBlockSummaryRow.databaseTableName, db: db)
            return try DailyWorkBlockSummaryRow
                .order(
                    DailyWorkBlockSummaryRow.Columns.startAt,
                    DailyWorkBlockSummaryRow.Columns.endAt,
                    DailyWorkBlockSummaryRow.Columns.id
                )
                .fetchAll(db)
                .map(Self.dailyWorkBlockSummaryRecord)
        }
    }

    func fetchDailyWorkBlockSummaries(intersecting interval: DateInterval) throws -> [DailyWorkBlockSummaryRecord] {
        try connection.read { db in
            try ensureTableExists(DailyWorkBlockSummaryRow.databaseTableName, db: db)
            return try DailyWorkBlockSummaryRow
                .filter(DailyWorkBlockSummaryRow.Columns.startAt < interval.end.timeIntervalSince1970)
                .filter(DailyWorkBlockSummaryRow.Columns.endAt > interval.start.timeIntervalSince1970)
                .order(
                    DailyWorkBlockSummaryRow.Columns.startAt,
                    DailyWorkBlockSummaryRow.Columns.endAt,
                    DailyWorkBlockSummaryRow.Columns.id
                )
                .fetchAll(db)
                .map(Self.dailyWorkBlockSummaryRecord)
        }
    }

    func upsertDailyWorkBlockSummary(
        categoryName: String,
        startAt: Date,
        endAt: Date,
        summaryText: String
    ) throws {
        try connection.write { db in
            let startValue = startAt.timeIntervalSince1970
            let endValue = endAt.timeIntervalSince1970
            if let existing = try DailyWorkBlockSummaryRow
                .filter(DailyWorkBlockSummaryRow.Columns.startAt == startValue)
                .filter(DailyWorkBlockSummaryRow.Columns.endAt == endValue)
                .limit(1)
                .fetchOne(db) {
                try DailyWorkBlockSummaryRow
                    .filter(DailyWorkBlockSummaryRow.Columns.id == existing.id)
                    .updateAll(db, [
                        DailyWorkBlockSummaryRow.Columns.categoryName.set(to: categoryName),
                        DailyWorkBlockSummaryRow.Columns.summaryText.set(to: summaryText),
                    ])
            } else {
                try DailyWorkBlockSummaryRow(
                    id: nil,
                    categoryName: categoryName,
                    startAt: startValue,
                    endAt: endValue,
                    summaryText: summaryText
                ).insert(db)
            }
            postChangeNotification()
        }
    }

    func deleteDailyWorkBlockSummaries(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }

        try connection.write { db in
            try DailyWorkBlockSummaryRow
                .filter(ids.contains(DailyWorkBlockSummaryRow.Columns.id))
                .deleteAll(db)
            postChangeNotification()
        }
    }

    nonisolated private static func dailyWorkBlockSummaryRecord(_ row: DailyWorkBlockSummaryRow) -> DailyWorkBlockSummaryRecord {
        DailyWorkBlockSummaryRecord(
            id: row.id ?? 0,
            categoryName: row.categoryName,
            startAt: Date(timeIntervalSince1970: row.startAt),
            endAt: Date(timeIntervalSince1970: row.endAt),
            summaryText: row.summaryText
        )
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

    private func ensureTableExists(_ tableName: String, db: Database) throws {
        guard try db.tableExists(tableName) else {
            throw DatabaseError.prepareStatement("missing table \(tableName)")
        }
    }

    private func postChangeNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appDatabaseDidChange, object: nil)
        }
    }
}
