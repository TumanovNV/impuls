import contextlib
import http.client
import ipaddress
import sqlite3
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

    def test_dashboard_has_no_external_assets(self):
        page = dashboard.render_dashboard(self.sample_report())
        self.assertNotIn("http://", page)
        self.assertNotIn("https://", page)
        self.assertNotIn("<script", page)

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
