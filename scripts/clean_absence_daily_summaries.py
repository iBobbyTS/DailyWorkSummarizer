#!/usr/bin/env python3
"""Remove legacy absence category summaries from DailyWorkSummarizer reports."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


ABSENCE_CATEGORY = "离开"
DEFAULT_DATABASE_PATH = (
    Path.home()
    / "Library"
    / "Containers"
    / "com.iBobby.DailyWorkSummarizer"
    / "Data"
    / "Library"
    / "Application Support"
    / "DailyWorkSummarizer"
    / "daily-work-summarizer.sqlite"
)


@dataclass(frozen=True)
class CleanupResult:
    scanned_rows: int
    updated_rows: int
    skipped_invalid_json: int
    dry_run: bool


def clean_database(
    database_path: Path,
    category_name: str = ABSENCE_CATEGORY,
    dry_run: bool = False,
) -> CleanupResult:
    if not database_path.exists():
        raise FileNotFoundError(f"Database not found: {database_path}")

    scanned_rows = 0
    updated_rows = 0
    skipped_invalid_json = 0
    like_pattern = f'%"{category_name}"%'

    connection = sqlite3.connect(database_path)
    try:
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")
        rows = connection.execute(
            """
            SELECT id, category_summaries_json
            FROM daily_reports
            WHERE category_summaries_json LIKE ?
            ORDER BY id
            """,
            (like_pattern,),
        ).fetchall()
        scanned_rows = len(rows)

        with connection:
            for report_id, raw_json in rows:
                try:
                    summaries = json.loads(raw_json)
                except json.JSONDecodeError:
                    skipped_invalid_json += 1
                    continue

                if not isinstance(summaries, dict) or category_name not in summaries:
                    continue

                summaries.pop(category_name)
                updated_json = json.dumps(summaries, ensure_ascii=False, separators=(",", ":"))
                updated_rows += 1

                if dry_run:
                    continue

                connection.execute(
                    """
                    UPDATE daily_reports
                    SET category_summaries_json = ?
                    WHERE id = ?
                    """,
                    (updated_json, report_id),
                )
    finally:
        connection.close()

    return CleanupResult(
        scanned_rows=scanned_rows,
        updated_rows=updated_rows,
        skipped_invalid_json=skipped_invalid_json,
        dry_run=dry_run,
    )


class CleanAbsenceDailySummariesTests(unittest.TestCase):
    def make_database(self, temporary_directory: Path) -> Path:
        database_path = temporary_directory / "daily-work-summarizer.sqlite"
        connection = sqlite3.connect(database_path)
        try:
            connection.execute(
                """
                CREATE TABLE daily_reports (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day_start DOUBLE NOT NULL UNIQUE,
                    daily_summary_text TEXT NOT NULL,
                    category_summaries_json TEXT NOT NULL
                )
                """
            )
            connection.executemany(
                """
                INSERT INTO daily_reports (
                    day_start,
                    daily_summary_text,
                    category_summaries_json
                )
                VALUES (?, ?, ?)
                """,
                [
                    (
                        1,
                        "日报正文可以保留离开相关自然语言",
                        json.dumps({"专注工作": "写代码", ABSENCE_CATEGORY: "离开总结"}, ensure_ascii=False),
                    ),
                    (
                        2,
                        "只有离开单项总结",
                        json.dumps({ABSENCE_CATEGORY: "全天离开"}, ensure_ascii=False),
                    ),
                    (
                        3,
                        "没有离开单项总结",
                        json.dumps({"专注工作": "继续写代码"}, ensure_ascii=False),
                    ),
                    (4, "坏 JSON 保持不动", '{"离开": "缺少结尾"'),
                ],
            )
            connection.commit()
        finally:
            connection.close()
        return database_path

    def fetch_report_json(self, database_path: Path, report_id: int) -> str:
        connection = sqlite3.connect(database_path)
        try:
            row = connection.execute(
                "SELECT category_summaries_json FROM daily_reports WHERE id = ?",
                (report_id,),
            ).fetchone()
            self.assertIsNotNone(row)
            return row[0]
        finally:
            connection.close()

    def test_removes_absence_key_without_touching_daily_summary_text(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database_path = self.make_database(Path(temporary_directory))

            result = clean_database(database_path)

            self.assertEqual(result.scanned_rows, 3)
            self.assertEqual(result.updated_rows, 2)
            self.assertEqual(result.skipped_invalid_json, 1)
            self.assertEqual(json.loads(self.fetch_report_json(database_path, 1)), {"专注工作": "写代码"})
            self.assertEqual(json.loads(self.fetch_report_json(database_path, 2)), {})
            self.assertEqual(json.loads(self.fetch_report_json(database_path, 3)), {"专注工作": "继续写代码"})
            self.assertEqual(self.fetch_report_json(database_path, 4), '{"离开": "缺少结尾"')

    def test_dry_run_does_not_update_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database_path = self.make_database(Path(temporary_directory))
            before = self.fetch_report_json(database_path, 1)

            result = clean_database(database_path, dry_run=True)

            self.assertTrue(result.dry_run)
            self.assertEqual(result.updated_rows, 2)
            self.assertEqual(self.fetch_report_json(database_path, 1), before)


def run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CleanAbsenceDailySummariesTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove the legacy absence category key from daily report category summaries."
    )
    parser.add_argument(
        "--database",
        type=Path,
        default=DEFAULT_DATABASE_PATH,
        help=f"SQLite database path. Defaults to {DEFAULT_DATABASE_PATH}",
    )
    parser.add_argument(
        "--category",
        default=ABSENCE_CATEGORY,
        help=f"Category key to remove. Defaults to {ABSENCE_CATEGORY}",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report how many rows would be updated without writing changes.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run script unit tests and exit.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_tests()

    result = clean_database(
        database_path=args.database.expanduser(),
        category_name=args.category,
        dry_run=args.dry_run,
    )
    mode = "dry run" if result.dry_run else "updated"
    action = "would remove category from" if result.dry_run else "removed category from"
    print(
        f"{mode}: scanned {result.scanned_rows} candidate rows, "
        f"{action} {result.updated_rows} rows, "
        f"skipped {result.skipped_invalid_json} invalid JSON rows"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
