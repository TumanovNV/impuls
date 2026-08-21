import contextlib
import http.client
import ipaddress
import json
import sqlite3
import stat
import sys
import tempfile
import threading
import unittest
import uuid
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COLLECTOR_DIRECTORY = ROOT / "Collector/version-statistics"
sys.path.insert(0, str(COLLECTOR_DIRECTORY))

import collector  # noqa: E402
import dashboard  # noqa: E402
import report  # noqa: E402


class DashboardTests(unittest.TestCase):
    def create_database(self, directory: str, with_installation: bool = True) -> Path:
        database = Path(directory) / "statistics.sqlite3"
        collector.initialize_database(database)
        if with_installation:
            collector.record_heartbeat(
                database,
                b"a production secret with more than thirty two bytes",
                {
                    "schema": 1,
                    "installation_id": str(uuid.uuid4()),
                    "app_version": "1.4.10",
                    "previous_version": "1.4.9",
                },
                datetime(2026, 8, 18, 12, tzinfo=timezone.utc),
            )
        return database

    def request(self, server, method: str, path: str):
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        connection.request(method, path)
        response = connection.getresponse()
        body = response.read()
        headers = dict(response.getheaders())
        connection.close()
        return response.status, headers, body

    def running_server(self, database: Path, allowed_cidr: str = "127.0.0.0/8"):
        server = dashboard.DashboardServer(
            ("127.0.0.1", 0),
            database,
            "1.4.10",
            ipaddress.ip_network(allowed_cidr),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def sample_report(self) -> dict:
        return {
            "generated_at": "2026-08-18T14:00:00+00:00",
            "active_installations": {"1_day": 1, "7_day": 1, "30_day": 1},
            "installations_by_app_version_30_day": {"1.4.10": 1},
            "latest_version": "1.4.10",
            "latest_version_share_30_day_percent": 100.0,
            "total_consenting_installations": 1,
            "last_heartbeat_at": "2026-08-18T12:00:00+00:00",
            "transitions": [
                {"from_version": "1.4.9", "to_version": "1.4.10", "installations": 1}
            ],
            "new_first_seen_installations_by_day": [
                {"date": "2026-08-18", "installations": 1}
            ],
        }

    def test_allowed_cidr_accepts_vpn_and_rejects_lan_and_malformed_addresses(self):
        network = ipaddress.ip_network("10.0.0.0/24")
        self.assertTrue(dashboard.is_client_allowed("10.0.0.42", network))
        self.assertFalse(dashboard.is_client_allowed("192.168.77.108", network))
        self.assertFalse(dashboard.is_client_allowed("not-an-address", network))

    def test_report_uses_a_read_only_query_only_connection(self):
        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory)
            summary = report.build_report(
                database, "1.4.10", datetime(2026, 8, 18, 13, tzinfo=timezone.utc)
            )
            self.assertEqual(summary["total_consenting_installations"], 1)
            self.assertEqual(summary["last_heartbeat_at"], "2026-08-18T12:00:00+00:00")

            with contextlib.closing(report.open_read_only_database(database)) as connection:
                self.assertEqual(connection.execute("PRAGMA query_only").fetchone()[0], 1)
                with self.assertRaises(sqlite3.OperationalError):
                    connection.execute("CREATE TABLE forbidden (value TEXT)")

    def test_dashboard_escapes_values_and_never_exposes_installation_hash(self):
        summary = self.sample_report()
        summary["latest_version"] = '<script>alert("latest")</script>'
        summary["installations_by_app_version_30_day"] = {'<img src=x onerror="alert(1)">': 1}
        summary["transitions"][0]["from_version"] = "<b>unsafe</b>"
        page = dashboard.render_dashboard(summary)
        self.assertNotIn("<script>", page)
        self.assertNotIn("<img src=x", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn("&lt;img src=x", page)
        self.assertIn("&lt;b&gt;unsafe&lt;/b&gt;", page)
        self.assertNotIn("installation_hash", page)

    def test_version_cards_and_empty_database_render(self):
        page = dashboard.render_dashboard(self.sample_report())
        self.assertIn("Активны за 24 часа", page)
        self.assertIn("1.4.10 — 100%", page)
        self.assertIn("Версии за 30 дней", page)

        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory, with_installation=False)
            summary = report.build_report(
                database, "1.4.10", datetime(2026, 8, 18, 13, tzinfo=timezone.utc)
            )
            empty_page = dashboard.render_dashboard(summary)
            self.assertIn("Нет данных за последние 30 дней.", empty_page)
            self.assertIn("Переходов пока нет.", empty_page)
            self.assertIn("Пока нет данных", empty_page)

    def test_default_github_refresh_interval_is_five_minutes(self):
        # 1.4.14 follow-up: the previous one-hour default meant the
        # latest-published-version label on the dashboard could lag a fresh
        # GitHub release by up to an hour even though the heartbeat data itself
        # was already current.
        self.assertEqual(dashboard.DEFAULT_GITHUB_REFRESH_INTERVAL_SECONDS, 5 * 60)
        self.assertGreaterEqual(
            dashboard.DEFAULT_GITHUB_REFRESH_INTERVAL_SECONDS,
            dashboard.MINIMUM_GITHUB_REFRESH_INTERVAL_SECONDS,
        )

    def test_dashboard_reflects_a_new_version_heartbeat_without_restarting_the_server(self):
        # Proves there is no dashboard-side cache of installations_by_app_version:
        # a heartbeat recorded after the server started must show up on the very
        # next request, with no second Impuls launch and no server restart.
        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory)
            server = self.running_server(database)

            before = self.request(server, "GET", "/")[2].decode("utf-8")
            self.assertIn("1.4.10", before)
            self.assertNotIn("1.4.14", before)

            collector.record_heartbeat(
                database,
                b"a production secret with more than thirty two bytes",
                {
                    "schema": 1,
                    "installation_id": str(uuid.uuid4()),
                    "app_version": "1.4.14",
                    "previous_version": "1.4.13",
                },
                datetime.now(timezone.utc),
            )

            after = self.request(server, "GET", "/")[2].decode("utf-8")
            self.assertIn("1.4.14", after)
            self.assertIn("1.4.9", after)
            self.assertIn("1.4.13", after)

    def test_dashboard_has_no_external_assets(self):
        page = dashboard.render_dashboard(self.sample_report())
        self.assertNotIn("http://", page)
        self.assertNotIn("https://", page)
        self.assertNotIn("<script", page)

    def test_latest_version_refresh_uses_validated_published_release_and_durable_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            cache_path = Path(directory) / "latest-version.json"
            def fetch_latest_version() -> str:
                return "1.4.11"

            resolver = dashboard.LatestVersionResolver(
                "1.4.10", cache_path, fetch_latest_version
            )
            self.assertEqual(resolver.latest_version, "1.4.10")
            self.assertTrue(resolver.refresh())
            self.assertEqual(resolver.latest_version, "1.4.11")
            self.assertEqual(stat.S_IMODE(cache_path.stat().st_mode), 0o600)
            self.assertEqual(
                json.loads(cache_path.read_text(encoding="utf-8"))["latest_version"], "1.4.11"
            )

            recovered = dashboard.LatestVersionResolver(
                "1.4.10", cache_path, lambda: (_ for _ in ()).throw(ValueError("unavailable"))
            )
            self.assertEqual(recovered.latest_version, "1.4.11")
            with self.assertLogs(level="WARNING"):
                self.assertFalse(recovered.refresh())
            self.assertEqual(recovered.latest_version, "1.4.11")

    def test_latest_version_refresh_keeps_bootstrap_value_without_a_valid_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            cache_path = Path(directory) / "latest-version.json"
            cache_path.write_text('{"latest_version":"unsafe"}', encoding="utf-8")
            resolver = dashboard.LatestVersionResolver(
                "1.4.10", cache_path, lambda: (_ for _ in ()).throw(ValueError("unavailable"))
            )
            self.assertEqual(resolver.latest_version, "1.4.10")
            with self.assertLogs(level="WARNING"):
                self.assertFalse(resolver.refresh())
            self.assertEqual(resolver.latest_version, "1.4.10")

    def test_github_latest_release_parser_accepts_only_a_stable_v_prefixed_release_tag(self):
        payload = json.dumps(
            {"draft": False, "prerelease": False, "tag_name": "v1.4.11"}
        ).encode("utf-8")
        self.assertEqual(dashboard.parse_github_latest_release(payload), "1.4.11")

        for invalid_payload in (
            {"draft": True, "prerelease": False, "tag_name": "v1.4.11"},
            {"draft": False, "prerelease": True, "tag_name": "v1.4.11"},
            {"draft": False, "prerelease": False, "tag_name": "1.4.11"},
            {"draft": False, "prerelease": False, "tag_name": "vnot-a-version"},
        ):
            with self.assertRaises(ValueError):
                dashboard.parse_github_latest_release(json.dumps(invalid_payload).encode("utf-8"))

    def test_dashboard_refreshes_latest_version_without_a_browser_network_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory)
            refreshed = threading.Event()

            def fetch_latest_version() -> str:
                refreshed.set()
                return "1.4.11"

            server = dashboard.DashboardServer(
                ("127.0.0.1", 0),
                database,
                "1.4.10",
                ipaddress.ip_network("127.0.0.0/8"),
                cache_path=Path(directory) / "latest-version.json",
                github_refresh_interval_seconds=300,
                latest_version_fetcher=fetch_latest_version,
                start_latest_version_refresh=True,
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(thread.join, 2)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            self.assertTrue(refreshed.wait(timeout=2))
            for _ in range(100):
                if server.latest_version == "1.4.11":
                    break
                threading.Event().wait(timeout=0.01)
            self.assertEqual(server.latest_version, "1.4.11")
            self.assertIn("1.4.11 — 0%", self.request(server, "GET", "/")[2].decode("utf-8"))

    def test_http_surface_health_headers_and_methods(self):
        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory)
            server = self.running_server(database)

            status, headers, body = self.request(server, "GET", "/healthz")
            self.assertEqual((status, body), (200, b"ok\n"))
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

            status, headers, body = self.request(server, "HEAD", "/")
            self.assertEqual(status, 200)
            self.assertEqual(body, b"")
            self.assertEqual(headers["X-Frame-Options"], "DENY")
            self.assertEqual(headers["Referrer-Policy"], "no-referrer")
            self.assertIn("default-src 'none'", headers["Content-Security-Policy"])

            self.assertEqual(self.request(server, "GET", "/missing")[0], 404)
            self.assertEqual(self.request(server, "GET", "/?query=not-allowed")[0], 404)
            for method in ("POST", "PUT", "PATCH", "DELETE"):
                self.assertEqual(self.request(server, method, "/")[0], 405)

    def test_health_failure_is_neutral_and_non_vpn_source_is_forbidden(self):
        with tempfile.TemporaryDirectory() as directory:
            missing_database = Path(directory) / "missing.sqlite3"
            server = self.running_server(missing_database)
            status, _, body = self.request(server, "GET", "/healthz")
            self.assertEqual((status, body), (503, b"unavailable\n"))
            self.assertNotIn(str(missing_database).encode(), body)

        with tempfile.TemporaryDirectory() as directory:
            database = self.create_database(directory)
            server = self.running_server(database, "10.0.0.0/24")
            status, _, body = self.request(server, "GET", "/")
            self.assertEqual((status, body), (403, b"forbidden\n"))


if __name__ == "__main__":
    unittest.main()
