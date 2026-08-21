#!/usr/bin/env python3
"""Private, read-only dashboard for Impuls version statistics."""

from __future__ import annotations

import contextlib
import html
import ipaddress
import json
import logging
import os
import re
import sqlite3
import tempfile
import threading
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable

from report import build_report, open_read_only_database

CONTENT_SECURITY_POLICY = (
    "default-src 'none'; "
    "style-src 'unsafe-inline'; "
    "img-src 'self' data:; "
    "base-uri 'none'; "
    "form-action 'none'; "
    "frame-ancestors 'none'"
)
GITHUB_LATEST_RELEASE_URL = "https://api.github.com/repos/TumanovNV/impuls/releases/latest"
GITHUB_RESPONSE_LIMIT = 32 * 1024
GITHUB_REQUEST_TIMEOUT_SECONDS = 5
DEFAULT_GITHUB_REFRESH_INTERVAL_SECONDS = 5 * 60
MINIMUM_GITHUB_REFRESH_INTERVAL_SECONDS = 5 * 60
MAXIMUM_GITHUB_REFRESH_INTERVAL_SECONDS = 24 * 60 * 60
LATEST_VERSION_CACHE_SCHEMA = 1
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z][0-9A-Za-z.-]*)?$")


def is_client_allowed(address: str, allowed_network: ipaddress.IPv4Network | ipaddress.IPv6Network) -> bool:
    try:
        return ipaddress.ip_address(address) in allowed_network
    except ValueError:
        return False


def validate_version(value: object) -> str:
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        raise ValueError("version must be a supported release version")
    return value


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Treat every redirect from the fixed upstream as an unavailable refresh."""

    def redirect_request(self, *_args: object, **_kwargs: object) -> None:
        return None


def parse_github_latest_release(payload_bytes: bytes) -> str:
    if len(payload_bytes) > GITHUB_RESPONSE_LIMIT:
        raise ValueError("GitHub latest-release response exceeds the limit")
    try:
        payload = json.loads(payload_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("GitHub latest-release response is not JSON") from error
    if not isinstance(payload, dict):
        raise ValueError("GitHub latest-release response is not an object")
    if payload.get("draft") is not False or payload.get("prerelease") is not False:
        raise ValueError("GitHub latest-release response is not a published stable release")
    tag_name = payload.get("tag_name")
    if not isinstance(tag_name, str) or not tag_name.startswith("v"):
        raise ValueError("GitHub latest-release tag is invalid")
    return validate_version(tag_name[1:])


def fetch_github_latest_release() -> str:
    """Fetch only the fixed public release endpoint, with no redirect follow."""

    request = urllib.request.Request(
        GITHUB_LATEST_RELEASE_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "ImpulsStatisticsDashboard/1.0",
        },
        method="GET",
    )
    opener = urllib.request.build_opener(NoRedirectHandler())
    try:
        with opener.open(request, timeout=GITHUB_REQUEST_TIMEOUT_SECONDS) as response:
            if response.geturl() != GITHUB_LATEST_RELEASE_URL:
                raise ValueError("GitHub latest-release response changed URL")
            if response.status != 200:
                raise ValueError("GitHub latest-release response has an unexpected status")
            content_length = response.headers.get("Content-Length")
            if content_length is not None and (
                not content_length.isdecimal() or int(content_length) > GITHUB_RESPONSE_LIMIT
            ):
                raise ValueError("GitHub latest-release response exceeds the limit")
            payload_bytes = response.read(GITHUB_RESPONSE_LIMIT + 1)
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as error:
        raise ValueError("GitHub latest-release request failed") from error
    return parse_github_latest_release(payload_bytes)


class LatestVersionResolver:
    """Keeps the last validated GitHub release version durable across outages."""

    def __init__(
        self,
        bootstrap_version: str,
        cache_path: Path | None,
        fetcher: Callable[[], str] = fetch_github_latest_release,
    ) -> None:
        self.bootstrap_version = validate_version(bootstrap_version)
        self.cache_path = cache_path
        self.fetcher = fetcher
        self._lock = threading.Lock()
        self._latest_version = self._read_cached_version() or self.bootstrap_version

    @property
    def latest_version(self) -> str:
        with self._lock:
            return self._latest_version

    def _read_cached_version(self) -> str | None:
        if self.cache_path is None:
            return None
        try:
            with self.cache_path.open(encoding="utf-8") as cache_file:
                cached = json.load(cache_file)
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(cached, dict) or set(cached) != {"schema", "latest_version", "fetched_at"}:
            return None
        if cached["schema"] != LATEST_VERSION_CACHE_SCHEMA or not isinstance(cached["fetched_at"], str):
            return None
        try:
            timestamp = datetime.fromisoformat(cached["fetched_at"])
            if timestamp.tzinfo is None:
                return None
            return validate_version(cached["latest_version"])
        except ValueError:
            return None

    def _write_cached_version(self, version: str) -> None:
        if self.cache_path is None:
            return
        self.cache_path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self.cache_path.name}.", suffix=".tmp", dir=self.cache_path.parent
        )
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as cache_file:
                json.dump(
                    {
                        "schema": LATEST_VERSION_CACHE_SCHEMA,
                        "latest_version": version,
                        "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    },
                    cache_file,
                    separators=(",", ":"),
                )
                cache_file.flush()
                os.fsync(cache_file.fileno())
            os.chmod(temporary_path, 0o600)
            os.replace(temporary_path, self.cache_path)
            directory_descriptor = os.open(self.cache_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        except BaseException:
            temporary_path.unlink(missing_ok=True)
            raise

    def refresh(self) -> bool:
        try:
            version = validate_version(self.fetcher())
            self._write_cached_version(version)
        except (OSError, ValueError):
            logging.warning("Latest published Impuls version refresh failed; retaining the last validated value")
            return False
        with self._lock:
            self._latest_version = version
        return True


def _escaped(value: object) -> str:
    return html.escape(str(value), quote=True)


def _percentage(count: int, total: int) -> float:
    return 0.0 if total == 0 else 100 * count / total


def _readable_timestamp(value: object) -> str:
    if not value:
        return "Пока нет данных"
    try:
        parsed = datetime.fromisoformat(str(value))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).strftime("%d.%m.%Y, %H:%M:%S UTC")
    except ValueError:
        return str(value)


def _recent_installations(report: dict) -> list[tuple[date, int]]:
    generated = datetime.fromisoformat(str(report["generated_at"])).date()
    counts = {
        date.fromisoformat(str(row["date"])): int(row["installations"])
        for row in report["new_first_seen_installations_by_day"]
    }
    first_day = generated - timedelta(days=29)
    return [(first_day + timedelta(days=offset), counts.get(first_day + timedelta(days=offset), 0))
            for offset in range(30)]


def render_dashboard(report: dict) -> str:
    active = report["active_installations"]
    versions = report["installations_by_app_version_30_day"]
    active_30 = int(active["30_day"])
    latest_share = float(report["latest_version_share_30_day_percent"])

    version_rows = []
    for version, count_value in versions.items():
        count = int(count_value)
        share = _percentage(count, active_30)
        version_rows.append(
            f"""
            <li class="version-row">
              <div class="row-heading">
                <span class="version-name">{_escaped(version)}</span>
                <span class="version-value">{_escaped(count)} · {_escaped(f'{share:.1f}')}%</span>
              </div>
              <div class="progress" role="img" aria-label="{_escaped(version)}: {_escaped(count)}, {_escaped(f'{share:.1f}')} процента">
                <span style="width: {_escaped(f'{share:.2f}')}%"></span>
              </div>
            </li>"""
        )
    versions_html = "".join(version_rows) or '<p class="empty">Нет данных за последние 30 дней.</p>'

    recent = _recent_installations(report)
    maximum = max((count for _, count in recent), default=0)
    bars = []
    for day, count in recent:
        height = 0 if maximum == 0 else max(4, round(100 * count / maximum))
        label = f"{day.strftime('%d.%m.%Y')}: {count}"
        bars.append(
            f'<span class="bar" style="--bar-height: {_escaped(height)}%" '
            f'role="img" aria-label="{_escaped(label)}" title="{_escaped(label)}"></span>'
        )
    chart_summary = (
        '<p class="empty">Новых opt-in установок за последние 30 дней нет.</p>'
        if maximum == 0
        else f'<p class="chart-summary">Всего новых за период: {_escaped(sum(count for _, count in recent))}</p>'
    )

    transition_rows = []
    for row in report["transitions"]:
        transition_rows.append(
            "<li>"
            f"<span>{_escaped(row['from_version'])} <span aria-hidden=\"true\">→</span> "
            f"{_escaped(row['to_version'])}</span>"
            f"<strong>{_escaped(row['installations'])}</strong>"
            "</li>"
        )
    transitions_html = "".join(transition_rows) or '<p class="empty">Переходов пока нет.</p>'

    return f"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <meta http-equiv="refresh" content="60">
  <title>Impuls Statistics</title>
  <style>
    :root {{
      color-scheme: light dark;
      --background: #f5f5f7;
      --surface: rgba(255, 255, 255, .86);
      --surface-solid: #ffffff;
      --text: #1d1d1f;
      --secondary: #6e6e73;
      --border: rgba(0, 0, 0, .09);
      --accent: #0a84ff;
      --accent-soft: rgba(10, 132, 255, .14);
      --shadow: 0 12px 36px rgba(0, 0, 0, .07);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-width: 280px;
      background: var(--background);
      color: var(--text);
      font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }}
    main {{ width: min(1120px, calc(100% - 32px)); margin: 0 auto; padding: 40px 0 48px; }}
    header {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 28px; }}
    h1, h2, p {{ margin-top: 0; }}
    h1 {{ margin-bottom: 4px; font-size: clamp(28px, 5vw, 40px); letter-spacing: -.035em; line-height: 1.12; }}
    h2 {{ margin-bottom: 20px; font-size: 20px; letter-spacing: -.015em; }}
    .subtitle, .updated, .empty, .chart-summary {{ color: var(--secondary); }}
    .subtitle {{ margin: 0; }}
    .vpn-badge {{
      flex: 0 0 auto;
      padding: 7px 12px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--surface-solid);
      color: var(--secondary);
      font-size: 13px;
      font-weight: 600;
    }}
    .cards {{ display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; margin-bottom: 16px; }}
    .card, .section {{
      border: 1px solid var(--border);
      border-radius: 20px;
      background: var(--surface);
      box-shadow: var(--shadow);
    }}
    .card {{ min-height: 132px; padding: 20px; }}
    .card-label {{ min-height: 42px; margin-bottom: 12px; color: var(--secondary); font-size: 13px; line-height: 1.35; }}
    .card-value {{ font-size: 32px; font-weight: 650; letter-spacing: -.035em; line-height: 1.1; font-variant-numeric: tabular-nums; }}
    .card-value.latest {{ font-size: 20px; line-height: 1.25; }}
    .section {{ margin-top: 16px; padding: 24px; }}
    .versions, .transitions {{ margin: 0; padding: 0; list-style: none; }}
    .version-row + .version-row {{ margin-top: 18px; }}
    .row-heading, .transitions li {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; }}
    .version-name, .transitions span {{ overflow-wrap: anywhere; }}
    .version-value, .transitions strong {{ flex: 0 0 auto; color: var(--secondary); font-size: 14px; font-variant-numeric: tabular-nums; }}
    .progress {{ height: 8px; margin-top: 8px; overflow: hidden; border-radius: 999px; background: var(--accent-soft); }}
    .progress span {{ display: block; height: 100%; border-radius: inherit; background: var(--accent); }}
    .chart {{ display: grid; grid-template-columns: repeat(30, minmax(2px, 1fr)); align-items: end; gap: clamp(2px, .6vw, 6px); height: 164px; padding-top: 12px; border-bottom: 1px solid var(--border); }}
    .bar {{ min-height: 1px; height: var(--bar-height); border-radius: 4px 4px 1px 1px; background: var(--accent); }}
    .chart-axis {{ display: flex; justify-content: space-between; margin-top: 8px; color: var(--secondary); font-size: 12px; font-variant-numeric: tabular-nums; }}
    .chart-summary {{ margin: 12px 0 0; font-size: 14px; }}
    .transitions li {{ padding: 12px 0; border-top: 1px solid var(--border); }}
    .transitions li:first-child {{ padding-top: 0; border-top: 0; }}
    .heartbeat {{ margin: 0; font-size: 18px; font-weight: 600; font-variant-numeric: tabular-nums; }}
    .footer {{ margin: 24px 0 0; padding: 0 4px; color: var(--secondary); font-size: 14px; }}
    .actions {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-top: 24px; }}
    .updated {{ margin: 0; font-size: 13px; }}
    .refresh {{
      display: inline-flex;
      min-height: 44px;
      align-items: center;
      justify-content: center;
      padding: 0 18px;
      border-radius: 12px;
      background: var(--accent);
      color: white;
      font-weight: 600;
      text-decoration: none;
      touch-action: manipulation;
    }}
    .refresh:hover {{ filter: brightness(.94); }}
    .refresh:active {{ filter: brightness(.86); }}
    .refresh:focus-visible {{ outline: 3px solid var(--accent-soft); outline-offset: 3px; }}
    @media (max-width: 860px) {{ .cards {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }} }}
    @media (max-width: 520px) {{
      main {{ width: min(100% - 24px, 1120px); padding-top: 24px; }}
      header {{ align-items: flex-start; }}
      .cards {{ grid-template-columns: 1fr 1fr; gap: 10px; }}
      .card {{ min-height: 120px; padding: 16px; }}
      .card:last-child {{ grid-column: 1 / -1; }}
      .section {{ padding: 20px 16px; border-radius: 18px; }}
      .actions {{ align-items: stretch; flex-direction: column; }}
      .refresh {{ width: 100%; }}
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --background: #000000;
        --surface: rgba(28, 28, 30, .92);
        --surface-solid: #1c1c1e;
        --text: #f5f5f7;
        --secondary: #a1a1a6;
        --border: rgba(255, 255, 255, .12);
        --accent: #0a84ff;
        --accent-soft: rgba(10, 132, 255, .24);
        --shadow: none;
      }}
    }}
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Impuls Statistics</h1>
        <p class="subtitle">Production version statistics</p>
      </div>
      <span class="vpn-badge">Только VPN</span>
    </header>

    <section class="cards" aria-label="Основные показатели">
      <article class="card"><div class="card-label">Активны за 24 часа</div><div class="card-value">{_escaped(active['1_day'])}</div></article>
      <article class="card"><div class="card-label">Активны за 7 дней</div><div class="card-value">{_escaped(active['7_day'])}</div></article>
      <article class="card"><div class="card-label">Активны за 30 дней</div><div class="card-value">{_escaped(active['30_day'])}</div></article>
      <article class="card"><div class="card-label">Всего opt-in установок</div><div class="card-value">{_escaped(report['total_consenting_installations'])}</div></article>
      <article class="card"><div class="card-label">Доля последней версии</div><div class="card-value latest">{_escaped(report['latest_version'])} — {_escaped(f'{latest_share:.0f}')}%</div></article>
    </section>

    <section class="section" aria-labelledby="versions-title">
      <h2 id="versions-title">Версии за 30 дней</h2>
      <ul class="versions">{versions_html}</ul>
    </section>

    <section class="section" aria-labelledby="new-title">
      <h2 id="new-title">Новые opt-in установки</h2>
      <div class="chart" aria-label="Новые opt-in установки по дням за последние 30 дней">{''.join(bars)}</div>
      <div class="chart-axis"><span>{_escaped(recent[0][0].strftime('%d.%m'))}</span><span>{_escaped(recent[-1][0].strftime('%d.%m'))}</span></div>
      {chart_summary}
    </section>

    <section class="section" aria-labelledby="transitions-title">
      <h2 id="transitions-title">Переходы между версиями</h2>
      <ul class="transitions">{transitions_html}</ul>
    </section>

    <section class="section" aria-labelledby="heartbeat-title">
      <h2 id="heartbeat-title">Последний heartbeat</h2>
      <p class="heartbeat">{_escaped(_readable_timestamp(report['last_heartbeat_at']))}</p>
    </section>

    <div class="actions">
      <p class="updated">Обновлено: {_escaped(_readable_timestamp(report['generated_at']))}</p>
      <a class="refresh" href="/">Обновить</a>
    </div>
    <p class="footer">Показаны только установки пользователей, которые добровольно включили отправку статистики версий. Это не общее количество пользователей Impuls.</p>
  </main>
</body>
</html>"""


def database_is_available(database_path: Path) -> bool:
    try:
        with contextlib.closing(open_read_only_database(database_path)) as database:
            database.execute("SELECT count(*) FROM installations").fetchone()
        return True
    except sqlite3.Error:
        return False


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        database: Path,
        latest_version: str,
        allowed_network: ipaddress.IPv4Network | ipaddress.IPv6Network,
        *,
        cache_path: Path | None = None,
        github_refresh_interval_seconds: int = DEFAULT_GITHUB_REFRESH_INTERVAL_SECONDS,
        latest_version_fetcher: Callable[[], str] = fetch_github_latest_release,
        start_latest_version_refresh: bool = False,
    ) -> None:
        self.database = database
        self.allowed_network = allowed_network
        self.latest_version_resolver = LatestVersionResolver(
            latest_version, cache_path, latest_version_fetcher
        )
        self.github_refresh_interval_seconds = github_refresh_interval_seconds
        self._latest_version_refresh_stop = threading.Event()
        self._latest_version_refresh_thread: threading.Thread | None = None
        super().__init__(address, DashboardHandler)
        if start_latest_version_refresh:
            self.start_latest_version_refresh()

    @property
    def latest_version(self) -> str:
        return self.latest_version_resolver.latest_version

    def start_latest_version_refresh(self) -> None:
        if self._latest_version_refresh_thread is not None:
            return
        self._latest_version_refresh_thread = threading.Thread(
            target=self._refresh_latest_version_forever,
            name="impuls-latest-version-refresh",
            daemon=True,
        )
        self._latest_version_refresh_thread.start()

    def _refresh_latest_version_forever(self) -> None:
        while not self._latest_version_refresh_stop.is_set():
            self.latest_version_resolver.refresh()
            self._latest_version_refresh_stop.wait(self.github_refresh_interval_seconds)

    def _stop_latest_version_refresh(self) -> None:
        self._latest_version_refresh_stop.set()
        if self._latest_version_refresh_thread is not None:
            self._latest_version_refresh_thread.join(timeout=GITHUB_REQUEST_TIMEOUT_SECONDS + 1)

    def shutdown(self) -> None:
        self._stop_latest_version_refresh()
        super().shutdown()

    def server_close(self) -> None:
        self._stop_latest_version_refresh()
        super().server_close()


class DashboardHandler(BaseHTTPRequestHandler):
    server: DashboardServer
    server_version = "ImpulsDashboard"
    sys_version = ""

    def _allowed(self) -> bool:
        if is_client_allowed(self.client_address[0], self.server.allowed_network):
            return True
        self._send_text(403, "forbidden\n")
        return False

    def _security_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CONTENT_SECURITY_POLICY)

    def _send(self, status: int, content_type: str, body: bytes, include_body: bool = True) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._security_headers()
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def _send_text(self, status: int, message: str, include_body: bool = True) -> None:
        self._send(status, "text/plain; charset=utf-8", message.encode("utf-8"), include_body)

    def _send_dashboard(self, include_body: bool) -> None:
        try:
            report = build_report(self.server.database, self.server.latest_version)
            body = render_dashboard(report).encode("utf-8")
            self._send(200, "text/html; charset=utf-8", body, include_body)
        except sqlite3.Error:
            logging.exception("Dashboard database query failed")
            body = (
                "<!doctype html><html lang=\"ru\"><meta charset=\"utf-8\">"
                "<title>Impuls Statistics</title><p>Статистика временно недоступна.</p></html>"
            ).encode("utf-8")
            self._send(503, "text/html; charset=utf-8", body, include_body)

    def _handle_read(self, include_body: bool) -> None:
        if not self._allowed():
            return
        if self.path == "/":
            self._send_dashboard(include_body)
        elif self.path == "/healthz":
            status, body = (200, "ok\n") if database_is_available(self.server.database) else (503, "unavailable\n")
            self._send_text(status, body, include_body)
        else:
            self._send_text(404, "not found\n", include_body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle_read(include_body=True)

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle_read(include_body=False)

    def _method_not_allowed(self) -> None:
        if self._allowed():
            self._send_text(405, "method not allowed\n")

    do_POST = _method_not_allowed
    do_PUT = _method_not_allowed
    do_PATCH = _method_not_allowed
    do_DELETE = _method_not_allowed

    def log_message(self, _format: str, *args: object) -> None:
        return


def configuration() -> tuple[
    str,
    int,
    Path,
    str,
    Path,
    int,
    ipaddress.IPv4Network | ipaddress.IPv6Network,
]:
    host = os.environ.get("IMPULS_DASHBOARD_HOST", "127.0.0.1")
    try:
        port = int(os.environ.get("IMPULS_DASHBOARD_PORT", "8090"))
    except ValueError as error:
        raise SystemExit("IMPULS_DASHBOARD_PORT must be an integer") from error
    if not (1 <= port <= 65_535):
        raise SystemExit("IMPULS_DASHBOARD_PORT must be between 1 and 65535")

    database_text = os.environ.get("IMPULS_DASHBOARD_DATABASE", "")
    if not database_text:
        raise SystemExit("IMPULS_DASHBOARD_DATABASE is required")
    bootstrap_version = os.environ.get("IMPULS_DASHBOARD_LATEST_VERSION", "")
    if not bootstrap_version:
        raise SystemExit("IMPULS_DASHBOARD_LATEST_VERSION is required")
    try:
        bootstrap_version = validate_version(bootstrap_version)
    except ValueError as error:
        raise SystemExit("IMPULS_DASHBOARD_LATEST_VERSION must be a supported release version") from error
    cache_path = Path(
        os.environ.get(
            "IMPULS_DASHBOARD_LATEST_VERSION_CACHE",
            str(Path(database_text).with_name("latest-version.json")),
        )
    )
    try:
        github_refresh_interval_seconds = int(
            os.environ.get(
                "IMPULS_DASHBOARD_GITHUB_REFRESH_INTERVAL",
                str(DEFAULT_GITHUB_REFRESH_INTERVAL_SECONDS),
            )
        )
    except ValueError as error:
        raise SystemExit("IMPULS_DASHBOARD_GITHUB_REFRESH_INTERVAL must be an integer") from error
    if not (
        MINIMUM_GITHUB_REFRESH_INTERVAL_SECONDS
        <= github_refresh_interval_seconds
        <= MAXIMUM_GITHUB_REFRESH_INTERVAL_SECONDS
    ):
        raise SystemExit(
            "IMPULS_DASHBOARD_GITHUB_REFRESH_INTERVAL must be between "
            f"{MINIMUM_GITHUB_REFRESH_INTERVAL_SECONDS} and {MAXIMUM_GITHUB_REFRESH_INTERVAL_SECONDS}"
        )
    try:
        allowed_network = ipaddress.ip_network(
            os.environ.get("IMPULS_DASHBOARD_ALLOWED_CIDR", "127.0.0.0/8"), strict=True
        )
    except ValueError as error:
        raise SystemExit("IMPULS_DASHBOARD_ALLOWED_CIDR must be a valid network") from error
    return (
        host,
        port,
        Path(database_text),
        bootstrap_version,
        cache_path,
        github_refresh_interval_seconds,
        allowed_network,
    )


def main() -> None:
    (
        host,
        port,
        database,
        bootstrap_version,
        cache_path,
        github_refresh_interval_seconds,
        allowed_network,
    ) = configuration()
    server = DashboardServer(
        (host, port),
        database,
        bootstrap_version,
        allowed_network,
        cache_path=cache_path,
        github_refresh_interval_seconds=github_refresh_interval_seconds,
        start_latest_version_refresh=True,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
