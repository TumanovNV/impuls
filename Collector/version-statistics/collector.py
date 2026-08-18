#!/usr/bin/env python3
"""Minimal privacy-first Impuls version heartbeat collector."""

from __future__ import annotations

import collections
import contextlib
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAXIMUM_BODY_BYTES = 2_048
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2}(?:[-.][0-9A-Za-z]+)*$")
REQUIRED_FIELDS = {"schema", "installation_id", "app_version"}
ALLOWED_FIELDS = REQUIRED_FIELDS | {"previous_version"}


class ValidationError(ValueError):
    pass


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def parse_payload(body: bytes) -> dict:
    if len(body) > MAXIMUM_BODY_BYTES:
        raise ValidationError("body too large")

    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValidationError("duplicate field")
            result[key] = value
        return result

    try:
        payload = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError("invalid JSON") from error
    if not isinstance(payload, dict) or set(payload) - ALLOWED_FIELDS or not REQUIRED_FIELDS <= set(payload):
        raise ValidationError("invalid fields")
    if type(payload["schema"]) is not int or payload["schema"] != 1:
        raise ValidationError("invalid schema")

    installation_id = payload["installation_id"]
    if not isinstance(installation_id, str) or len(installation_id) != 36:
        raise ValidationError("invalid installation_id")
    try:
        parsed_id = uuid.UUID(installation_id)
    except ValueError as error:
        raise ValidationError("invalid installation_id") from error
    if parsed_id.version != 4 or str(parsed_id) != installation_id.lower():
        raise ValidationError("installation_id must be a canonical random UUID")

    for field in ("app_version", "previous_version"):
        if field not in payload:
            continue
        value = payload[field]
        if not isinstance(value, str) or len(value) > 32 or VERSION_PATTERN.fullmatch(value) is None:
            raise ValidationError(f"invalid {field}")
    if payload.get("previous_version") == payload["app_version"]:
        raise ValidationError("previous_version must differ")
    return payload


def installation_digest(secret: bytes, installation_id: str) -> str:
    return hmac.new(secret, installation_id.encode("ascii"), hashlib.sha256).hexdigest()


def initialize_database(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as database:
        database.execute("PRAGMA journal_mode=WAL")
        database.executescript(
            """
            CREATE TABLE IF NOT EXISTS installations (
                installation_hash TEXT PRIMARY KEY CHECK(length(installation_hash) = 64),
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                current_version TEXT NOT NULL,
                previous_version TEXT
            );
            CREATE TABLE IF NOT EXISTS transitions (
                installation_hash TEXT NOT NULL,
                from_version TEXT NOT NULL,
                to_version TEXT NOT NULL,
                first_seen TEXT NOT NULL,
                PRIMARY KEY (installation_hash, from_version, to_version)
            );
            CREATE INDEX IF NOT EXISTS installations_last_seen ON installations(last_seen);
            CREATE INDEX IF NOT EXISTS installations_first_seen ON installations(first_seen);
            """
        )


def record_heartbeat(path: Path, secret: bytes, payload: dict, now: datetime | None = None) -> None:
    observed = (now or utc_now()).isoformat(timespec="seconds")
    digest = installation_digest(secret, payload["installation_id"])
    previous = payload.get("previous_version")
    with contextlib.closing(sqlite3.connect(path, timeout=5)) as database:
        database.execute("BEGIN IMMEDIATE")
        database.execute(
            """
            INSERT INTO installations (
                installation_hash, first_seen, last_seen, current_version, previous_version
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(installation_hash) DO UPDATE SET
                last_seen = excluded.last_seen,
                current_version = excluded.current_version,
                previous_version = excluded.previous_version
            """,
            (digest, observed, observed, payload["app_version"], previous),
        )
        if previous:
            database.execute(
                """
                INSERT OR IGNORE INTO transitions (
                    installation_hash, from_version, to_version, first_seen
                ) VALUES (?, ?, ?, ?)
                """,
                (digest, previous, payload["app_version"], observed),
            )
        database.commit()


class RateLimiter:
    """Process-local abuse guard; keys are HMACs and never enter the database."""

    def __init__(self, secret: bytes, maximum_per_minute: int) -> None:
        self.secret = secret
        self.maximum = maximum_per_minute
        self.events: dict[str, collections.deque[float]] = {}
        self.lock = threading.Lock()

    def allows(self, address: str, current_time: float | None = None) -> bool:
        now = current_time if current_time is not None else time.monotonic()
        key = hmac.new(self.secret, address.encode("utf-8"), hashlib.sha256).hexdigest()
        with self.lock:
            events = self.events.setdefault(key, collections.deque())
            while events and events[0] <= now - 60:
                events.popleft()
            if len(events) >= self.maximum:
                return False
            events.append(now)
            return True


class CollectorServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], database: Path, secret: bytes, rate_limit: int) -> None:
        self.database = database
        self.secret = secret
        self.rate_limiter = RateLimiter(secret, rate_limit)
        super().__init__(address, CollectorHandler)


class CollectorHandler(BaseHTTPRequestHandler):
    server: CollectorServer

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/v1/heartbeat":
            self.send_error(404)
            return
        if not self.server.rate_limiter.allows(self.client_address[0]):
            self.send_error(429)
            return
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            self.send_error(415)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error(411)
            return
        if length < 2 or length > MAXIMUM_BODY_BYTES:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        if len(body) != length:
            self.send_error(400)
            return
        try:
            payload = parse_payload(body)
            record_heartbeat(self.server.database, self.server.secret, payload)
        except ValidationError:
            self.send_error(422)
            return
        except sqlite3.Error:
            self.send_error(503)
            return
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.send_error(405)

    def log_message(self, _format: str, *args: object) -> None:
        # IP address, User-Agent and request details are intentionally not
        # written as product analytics or default access logs.
        return


def configuration() -> tuple[str, int, Path, bytes, int]:
    secret_text = os.environ.get("IMPULS_TELEMETRY_HMAC_SECRET", "")
    if len(secret_text.encode("utf-8")) < 32:
        raise SystemExit("IMPULS_TELEMETRY_HMAC_SECRET must contain at least 32 bytes")
    host = os.environ.get("IMPULS_TELEMETRY_HOST", "127.0.0.1")
    port = int(os.environ.get("IMPULS_TELEMETRY_PORT", "8080"))
    database = Path(os.environ.get("IMPULS_TELEMETRY_DATABASE", "./data/version-statistics.sqlite3"))
    rate_limit = int(os.environ.get("IMPULS_TELEMETRY_RATE_LIMIT_PER_MINUTE", "30"))
    if not (1 <= rate_limit <= 1_000):
        raise SystemExit("rate limit must be between 1 and 1000")
    return host, port, database, secret_text.encode("utf-8"), rate_limit


def main() -> None:
    host, port, database, secret, rate_limit = configuration()
    initialize_database(database)
    server = CollectorServer((host, port), database, secret, rate_limit)
    server.serve_forever()


if __name__ == "__main__":
    main()
