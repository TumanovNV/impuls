---
title: Version Statistics Collector
type: operations
status: active
documentation_version: 1.2
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, telemetry, collector, dashboard, sqlite]
---

# Version Statistics Collector

## Scope warning

Collector считает только **consenting active installations**. Эти числа не являются абсолютным количеством пользователей, установок или уникальных downloads.

## Source-of-truth split

Этот документ описывает **public software contract** collector/dashboard. Конкретный production host, VPN/reverse-proxy topology, service state, server paths, backup state и operational access принадлежат private infrastructure vault.

Правило разделения: [Public / Private Operations Boundary](../12-reference/operations-boundary.md).

Private operational entrypoint (repository access required): `office-it-docs: Проекты/Impuls.md`.

## Architecture

```mermaid
flowchart LR
    APP[VersionTelemetryService] -->|HTTPS POST /v1/heartbeat| RP[Owner-controlled TLS boundary]
    RP --> COL[collector.py\nprivate backend]
    COL --> H[HMAC-SHA256 installation UUID]
    H --> DB[(SQLite)]
    DB --> REP[report.py\nowner-only read-only]
    DB --> DASH[dashboard.py\nowner-only read-only]
```

The diagram is intentionally abstract. Current production addresses/routes are private operational facts, not public application architecture.

## Client contract

Owner: [`VersionTelemetryService.swift`](../../Sources/Impuls/Services/VersionTelemetryService.swift).

The client:

- has consent independent from Sparkle update networking;
- validates the configured endpoint before transport is touched;
- permits only HTTPS with exact `/v1/heartbeat` path and no credentials/query/fragment/port;
- sends at most one attempt per 24-hour interval;
- uses an ephemeral URLSession without cookies/cache;
- rejects HTTP redirects;
- isolates failure from launch and user-facing app behavior.

Payload schema is registered in [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

## Collector contract

Implementation: Python standard library + SQLite.

Accepted request:

- exact `POST /v1/heartbeat`;
- `Content-Type: application/json`;
- body ≤ 2 KiB;
- JSON object with no duplicate/unknown fields;
- `schema == 1`;
- canonical random UUID v4 installation ID;
- bounded version strings;
- optional `previous_version` differing from current version.

Success: HTTP 204.

Validation/DB failure is fail-closed with an HTTP error; malformed input is not partially recorded.

Implementation: [`collector.py`](../../Collector/version-statistics/collector.py).

## Identity/storage

Raw installation UUID **не сохраняется**. Collector stores a server-side HMAC-SHA256 digest.

Product DB does not persist IP/User-Agent. Collector request logging is disabled. The in-process rate limiter uses a temporary HMAC of peer address rather than recording it as analytics.

Application-side installation identity is a random UUID v4 kept in Keychain and used only after explicit opt-in.

## Database contract

Current tables:

- `installations` — HMAC identity, first/last seen, current and previous version;
- `transitions` — unique installation/from/to transition with first observation;
- indexes for first/last seen queries.

SQLite uses WAL mode.

The current DDL is idempotent but is not yet assigned an explicit database schema version. Before an incompatible DB change, introduce a tested migration/version mechanism as required by [Schema & Migration Registry](../12-reference/schema-migration-registry.md).

## Retention

Каждый accepted heartbeat в той же DB transaction удаляет installations и transition rows, чей `last_seen` старше 365 days. Retention не зависит от отдельного cron.

## Reverse proxy expectations

Operational deployment should:

- terminate TLS before the private collector backend;
- expose only the required heartbeat route;
- omit/anonymize client-identifying access logs for that route;
- enforce an additional body/rate limit;
- avoid forwarding public client IP merely for analytics;
- protect DB backups and HMAC secret as production credentials.

Exact current deployment topology belongs in private operational documentation.

## Reports/dashboard

[`report.py`](../../Collector/version-statistics/report.py) and [`dashboard.py`](../../Collector/version-statistics/dashboard.py) open SQLite read-only (`mode=ro` + `PRAGMA query_only=ON`).

Dashboard design contract:

- private administration access only;
- aggregate output only;
- no installation hashes/raw rows;
- GET/HEAD for `/` and `/healthz` only;
- mutating methods rejected;
- restrictive browser/cache headers;
- request logging disabled.

Tests: [`test_version_statistics_dashboard.py`](../../Tests/PythonTests/test_version_statistics_dashboard.py).

## Secret rotation

Rotating the HMAC secret creates a new unlinkable installation population. This is both a privacy property and an operational consequence: old and new digests must not be joined.

The **procedure** may be documented privately. The secret value never belongs in Git.

## Public-repo rule

This knowledge base may contain protocol/schema/privacy facts that are already part of the shipped/open-source contract. It must not become a copy of private infrastructure inventory.

For tasks that require current production runtime, use the private operational hub rather than inferring from source defaults or historical audit notes.

## Source map

- [`VersionTelemetryService.swift`](../../Sources/Impuls/Services/VersionTelemetryService.swift)
- [`collector.py`](../../Collector/version-statistics/collector.py)
- [`dashboard.py`](../../Collector/version-statistics/dashboard.py)
- [`report.py`](../../Collector/version-statistics/report.py)
- [`Dockerfile`](../../Collector/version-statistics/Dockerfile)
- [`Collector/version-statistics/README.md`](../../Collector/version-statistics/README.md)

## Verification map

- [`VersionTelemetryServiceTests.swift`](../../Tests/ImpulsTests/VersionTelemetryServiceTests.swift)
- [`test_version_statistics.py`](../../Tests/PythonTests/test_version_statistics.py)
- [`test_version_statistics_dashboard.py`](../../Tests/PythonTests/test_version_statistics_dashboard.py)
- [Generated Type → Tests → Docs Map](../12-reference/generated-type-test-doc-map.md)
