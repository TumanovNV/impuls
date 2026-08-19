import contextlib
import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_collector():
    path = ROOT / "Collector/version-statistics/collector.py"
    spec = importlib.util.spec_from_file_location("impuls_collector_migrations", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load_collector()


class CollectorDatabaseMigrationTests(unittest.TestCase):
    def test_new_database_is_initialized_at_current_schema_version(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "statistics.sqlite3"
            collector.initialize_database(database_path)

            with contextlib.closing(sqlite3.connect(database_path)) as database:
                self.assertEqual(
                    collector.database_schema_version(database),
                    collector.DATABASE_SCHEMA_VERSION,
                )
                collector.validate_database_schema_v1(database)

    def test_unversioned_legacy_database_is_adopted_without_rewriting_rows(self):
        digest = "a" * 64
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "statistics.sqlite3"
            with contextlib.closing(sqlite3.connect(database_path)) as database:
                for statement in collector.SCHEMA_V1_STATEMENTS:
                    database.execute(statement)
                database.execute(
                    """
                    INSERT INTO installations (
                        installation_hash, first_seen, last_seen, current_version, previous_version
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (digest, "2026-08-01T00:00:00+00:00", "2026-08-19T00:00:00+00:00", "1.4.11", "1.4.10"),
                )
                database.commit()
                self.assertEqual(collector.database_schema_version(database), 0)

            collector.initialize_database(database_path)

            with contextlib.closing(sqlite3.connect(database_path)) as database:
                self.assertEqual(collector.database_schema_version(database), 1)
                row = database.execute(
                    "SELECT installation_hash, current_version, previous_version FROM installations"
                ).fetchone()
            self.assertEqual(row, (digest, "1.4.11", "1.4.10"))

    def test_future_database_schema_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "statistics.sqlite3"
            with contextlib.closing(sqlite3.connect(database_path)) as database:
                database.execute(
                    f"PRAGMA user_version = {collector.DATABASE_SCHEMA_VERSION + 1}"
                )
                database.commit()

            with self.assertRaises(collector.DatabaseMigrationError):
                collector.initialize_database(database_path)

    def test_malformed_unversioned_schema_is_rejected_and_stays_unversioned(self):
        with tempfile.TemporaryDirectory() as directory:
            database_path = Path(directory) / "statistics.sqlite3"
            with contextlib.closing(sqlite3.connect(database_path)) as database:
                database.execute(
                    """
                    CREATE TABLE installations (
                        installation_hash TEXT PRIMARY KEY,
                        first_seen TEXT NOT NULL,
                        last_seen TEXT NOT NULL,
                        current_version TEXT NOT NULL
                    )
                    """
                )
                database.commit()

            with self.assertRaises(collector.DatabaseMigrationError):
                collector.initialize_database(database_path)

            with contextlib.closing(sqlite3.connect(database_path)) as database:
                self.assertEqual(collector.database_schema_version(database), 0)
                self.assertEqual(
                    {row[1] for row in database.execute('PRAGMA table_info("installations")')},
                    {"installation_hash", "first_seen", "last_seen", "current_version"},
                )


if __name__ == "__main__":
    unittest.main()
