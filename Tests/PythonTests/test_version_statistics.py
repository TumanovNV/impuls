import importlib.util
import contextlib
import http.client
import json
import re
import sqlite3
import tempfile
import threading
import unittest
import uuid
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load_module("impuls_collector", ROOT / "Collector/version-statistics/collector.py")
reporter = load_module("impuls_report", ROOT / "Collector/version-statistics/report.py")
release_stats = load_module("impuls_release_stats", ROOT / "Scripts/release-stats.py")


class CollectorTests(unittest.TestCase):
    def payload(self):
        return {
            "schema": 1,
            "installation_id": str(uuid.uuid4()),
            "app_version": "1.4.10",
            "previous_version": "1.4.9",
        }

    def test_schema_is_an_exact_allow_list(self):
        payload = self.payload()
        self.assertEqual(collector.parse_payload(json.dumps(payload).encode()), payload)
        for field in ("device_name", "ip", "clipboard", "path"):
            invalid = payload | {field: "must not be accepted"}
            with self.assertRaises(collector.ValidationError):
                collector.parse_payload(json.dumps(invalid).encode())

    def test_validation_rejects_nonrandom_duplicate_and_oversized_payloads(self):
        payload = self.payload()
        payload["installation_id"] = str(uuid.uuid5(uuid.NAMESPACE_DNS, "example.com"))
        with self.assertRaises(collector.ValidationError):
            collector.parse_payload(json.dumps(payload).encode())
        duplicate = b'{"schema":1,"schema":1,"installation_id":"x","app_version":"1.4.10"}'
        with self.assertRaises(collector.ValidationError):
            collector.parse_payload(duplicate)
        with self.assertRaises(collector.ValidationError):
            collector.parse_payload(b" " * (collector.MAXIMUM_BODY_BYTES + 1))

    def test_database_stores_only_hmac_and_report_states_consent_scope(self):
        payload = self.payload()
        secret = b"a production secret with more than thirty two bytes"
        now = datetime(2026, 8, 18, 12, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "statistics.sqlite3"
            collector.initialize_database(database)
            collector.record_heartbeat(database, secret, payload, now)

            raw_database = database.read_bytes()
            self.assertNotIn(payload["installation_id"].encode(), raw_database)
            with contextlib.closing(sqlite3.connect(database)) as connection:
                row = connection.execute(
                    "SELECT installation_hash, current_version, previous_version FROM installations"
                ).fetchone()
            self.assertEqual(len(row[0]), 64)
            self.assertEqual(row[1:], ("1.4.10", "1.4.9"))

            summary = reporter.build_report(database, "1.4.10", now + timedelta(hours=1))
            self.assertIn("opted in", summary["scope_notice"])
            self.assertEqual(summary["active_installations"]["1_day"], 1)
            self.assertEqual(summary["installations_by_app_version_30_day"], {"1.4.10": 1})
            self.assertEqual(summary["latest_version_share_30_day_percent"], 100.0)
            self.assertEqual(summary["transitions"][0]["from_version"], "1.4.9")

    def test_rate_limit_does_not_store_raw_addresses(self):
        limiter = collector.RateLimiter(b"x" * 32, maximum_per_minute=2)
        self.assertTrue(limiter.allows("203.0.113.42", 100))
        self.assertTrue(limiter.allows("203.0.113.42", 101))
        self.assertFalse(limiter.allows("203.0.113.42", 102))
        self.assertNotIn("203.0.113.42", limiter.events)

    def test_database_prunes_installations_inactive_for_more_than_twelve_months(self):
        secret = b"a production secret with more than thirty two bytes"
        old_payload = self.payload()
        active_payload = self.payload()
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "statistics.sqlite3"
            collector.initialize_database(database)
            collector.record_heartbeat(
                database,
                secret,
                old_payload,
                datetime(2025, 8, 17, 12, tzinfo=timezone.utc),
            )
            collector.record_heartbeat(
                database,
                secret,
                active_payload,
                datetime(2026, 8, 18, 12, tzinfo=timezone.utc),
            )

            with contextlib.closing(sqlite3.connect(database)) as connection:
                installations = connection.execute(
                    "SELECT installation_hash FROM installations"
                ).fetchall()
                transitions = connection.execute(
                    "SELECT installation_hash FROM transitions"
                ).fetchall()
            active_digest = collector.installation_digest(secret, active_payload["installation_id"])
            self.assertEqual(installations, [(active_digest,)])
            self.assertEqual(transitions, [(active_digest,)])

    def test_observed_upgrade_from_1_4_10_to_1_4_11_creates_one_transition(self):
        secret = b"a production secret with more than thirty two bytes"
        installation_id = str(uuid.uuid4())
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "statistics.sqlite3"
            collector.initialize_database(database)
            collector.record_heartbeat(
                database,
                secret,
                {
                    "schema": 1,
                    "installation_id": installation_id,
                    "app_version": "1.4.10",
                },
                datetime(2026, 8, 18, 12, tzinfo=timezone.utc),
            )
            collector.record_heartbeat(
                database,
                secret,
                {
                    "schema": 1,
                    "installation_id": installation_id,
                    "app_version": "1.4.11",
                    "previous_version": "1.4.10",
                },
                datetime(2026, 8, 18, 13, tzinfo=timezone.utc),
            )

            summary = reporter.build_report(
                database, "1.4.11", datetime(2026, 8, 18, 14, tzinfo=timezone.utc)
            )
            self.assertEqual(summary["installations_by_app_version_30_day"], {"1.4.11": 1})
            self.assertEqual(
                summary["transitions"],
                [{"from_version": "1.4.10", "to_version": "1.4.11", "installations": 1}],
            )

    def test_http_contract_returns_204_and_rejects_extra_fields(self):
        secret = b"a production secret with more than thirty two bytes"
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "statistics.sqlite3"
            collector.initialize_database(database)
            server = collector.CollectorServer(("127.0.0.1", 0), database, secret, 30)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                body = json.dumps(self.payload())
                connection.request("POST", "/v1/heartbeat", body, {"Content-Type": "application/json"})
                self.assertEqual(connection.getresponse().status, 204)
                connection.close()

                invalid = self.payload() | {"user_agent": "must not be accepted"}
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                connection.request(
                    "POST",
                    "/v1/heartbeat",
                    json.dumps(invalid),
                    {"Content-Type": "application/json"},
                )
                self.assertEqual(connection.getresponse().status, 422)
                connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


class ReleaseStatsTests(unittest.TestCase):
    def test_report_counts_dmg_assets_without_calling_them_unique(self):
        result = release_stats.build_report(
            [
                {
                    "tag_name": "v1.4.10",
                    "published_at": "2026-08-18T12:00:00Z",
                    "assets": [
                        {"name": "Impuls-1.4.10.dmg", "download_count": 12},
                        {"name": "Impuls-1.4.10.zip", "download_count": 99},
                    ],
                },
                {
                    "tag_name": "v1.4.9",
                    "published_at": "2026-08-13T12:00:00Z",
                    "assets": [{"name": "Impuls-1.4.9.dmg", "download_count": 7}],
                },
            ],
            "TumanovNV/impuls",
        )
        self.assertEqual(result["total_download_count"], 19)
        self.assertEqual(result["versions"][0]["dmg_assets"][0]["download_count"], 12)
        self.assertIn("not unique users", result["metric"])


class LocalizationTests(unittest.TestCase):
    def test_every_table_has_the_same_keys_once_and_covers_localized_calls(self):
        """Duplicate keys are only caught here.

        `check-localization.py` compares key *sets*, so a key written twice in one
        table disappears into the set and passes. This test walks every shipped
        table rather than just English and Russian: with seven of them, a duplicate
        introduced in a newly translated table would otherwise go unnoticed.
        """
        def keys(path):
            found = re.findall(
                r'^"((?:[^"\\]|\\.)*)"\s*=',
                path.read_text(encoding="utf-8"),
                re.MULTILINE,
            )
            self.assertEqual(
                [key for key, count in Counter(found).items() if count > 1],
                [],
                f"duplicate localization keys in {path}",
            )
            return set(found)

        tables = sorted((ROOT / "Resources").glob("*.lproj/Localizable.strings"))
        self.assertTrue(tables, "no Localizable.strings tables were found")

        english = keys(ROOT / "Resources/en.lproj/Localizable.strings")
        for table in tables:
            self.assertEqual(english, keys(table), f"{table} disagrees with English")

        used = set()
        for path in (ROOT / "Sources").rglob("*.swift"):
            used.update(re.findall(r'localized\("([^"]+)"', path.read_text(encoding="utf-8")))
        self.assertEqual(used - english, set())


if __name__ == "__main__":
    unittest.main()
