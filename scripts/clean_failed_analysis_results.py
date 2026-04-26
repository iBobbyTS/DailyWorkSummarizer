#!/usr/bin/env python3
"""Delete legacy failed analysis result rows before schema cleanup."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


DEFAULT_DATABASE_PATH = (
    Path.home()
    / "Library"
    / "Containers"
    / "com.iBobby.DeskBrief"
    / "Data"
    / "Library"
    / "Application Support"
    / "DeskBrief"
    / "desk-brief.sqlite"
)


@dataclass(frozen=True)
class CleanupResult:
    deleted_rows: int
    dry_run: bool
    skipped_missing_table: bool
    skipped_missing_status_column: bool


def table_exists(connection: sqlite3.Connection, table_name: str) -> bool:
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    ).fetchone()
    return row is not None


def column_names(connection: sqlite3.Connection, table_name: str) -> set[str]:
    rows = connection.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {row[1] for row in rows}


def clean_database(database_path: Path, dry_run: bool = False) -> CleanupResult:
    if not database_path.exists():
        raise FileNotFoundError(f"Database not found: {database_path}")

    connection = sqlite3.connect(database_path)
    try:
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")

        if not table_exists(connection, "analysis_results"):
            return CleanupResult(
                deleted_rows=0,
                dry_run=dry_run,
                skipped_missing_table=True,
                skipped_missing_status_column=False,
            )

        if "status" not in column_names(connection, "analysis_results"):
            return CleanupResult(
                deleted_rows=0,
                dry_run=dry_run,
                skipped_missing_table=False,
                skipped_missing_status_column=True,
            )

        deleted_rows = connection.execute(
            "SELECT COUNT(*) FROM analysis_results WHERE status = 'failed'"
        ).fetchone()[0]

        if not dry_run:
            with connection:
                connection.execute("DELETE FROM analysis_results WHERE status = 'failed'")

        return CleanupResult(
            deleted_rows=deleted_rows,
            dry_run=dry_run,
            skipped_missing_table=False,
            skipped_missing_status_column=False,
        )
    finally:
        connection.close()


class CleanFailedAnalysisResultsTests(unittest.TestCase):
    def make_database(self, temporary_directory: Path) -> Path:
        database_path = temporary_directory / "desk-brief.sqlite"
        connection = sqlite3.connect(database_path)
        try:
            connection.execute(
                """
                CREATE TABLE analysis_results (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    captured_at DOUBLE NOT NULL,
                    category_name TEXT,
                    status TEXT NOT NULL
                )
                """
            )
            connection.executemany(
                """
                INSERT INTO analysis_results (captured_at, category_name, status)
                VALUES (?, ?, ?)
                """,
                [
                    (1, "专注工作", "succeeded"),
                    (2, None, "failed"),
                    (3, None, "failed"),
                    (4, None, "partial_failed"),
                ],
            )
            connection.commit()
        finally:
            connection.close()
        return database_path

    def fetch_statuses(self, database_path: Path) -> list[str]:
        connection = sqlite3.connect(database_path)
        try:
            rows = connection.execute(
                "SELECT status FROM analysis_results ORDER BY id"
            ).fetchall()
            return [row[0] for row in rows]
        finally:
            connection.close()

    def test_deletes_only_failed_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database_path = self.make_database(Path(temporary_directory))

            result = clean_database(database_path)

            self.assertEqual(result.deleted_rows, 2)
            self.assertFalse(result.dry_run)
            self.assertFalse(result.skipped_missing_table)
            self.assertFalse(result.skipped_missing_status_column)
            self.assertEqual(self.fetch_statuses(database_path), ["succeeded", "partial_failed"])

    def test_dry_run_does_not_delete_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database_path = self.make_database(Path(temporary_directory))

            result = clean_database(database_path, dry_run=True)

            self.assertEqual(result.deleted_rows, 2)
            self.assertTrue(result.dry_run)
            self.assertEqual(
                self.fetch_statuses(database_path),
                ["succeeded", "failed", "failed", "partial_failed"],
            )

    def test_missing_status_column_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database_path = Path(temporary_directory) / "desk-brief.sqlite"
            connection = sqlite3.connect(database_path)
            try:
                connection.execute(
                    """
                    CREATE TABLE analysis_results (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        captured_at DOUBLE NOT NULL
                    )
                    """
                )
                connection.commit()
            finally:
                connection.close()

            result = clean_database(database_path)

            self.assertEqual(result.deleted_rows, 0)
            self.assertTrue(result.skipped_missing_status_column)


def run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CleanFailedAnalysisResultsTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Delete legacy analysis_results rows where status equals 'failed'."
    )
    parser.add_argument(
        "--database",
        type=Path,
        default=DEFAULT_DATABASE_PATH,
        help=f"SQLite database path. Defaults to {DEFAULT_DATABASE_PATH}",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report how many rows would be deleted without writing changes.",
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

    result = clean_database(args.database.expanduser(), dry_run=args.dry_run)
    mode = "dry run" if result.dry_run else "updated"
    action = "would delete" if result.dry_run else "deleted"

    if result.skipped_missing_table:
        print(f"{mode}: analysis_results table not found; no rows deleted")
    elif result.skipped_missing_status_column:
        print(f"{mode}: analysis_results.status column not found; no rows deleted")
    else:
        print(f"{mode}: {action} {result.deleted_rows} failed analysis result rows")

    return 0


if __name__ == "__main__":
    sys.exit(main())
