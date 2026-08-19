# Impuls version-statistics collector

This is the first-party collector for the optional Impuls version heartbeat. It
uses only the Python standard library and SQLite. It is deliberately not given a
production hostname in the repository.

The report covers only installations whose users enabled version statistics. It
is not an absolute user count and must never be presented as one.

## Run

Set a unique secret of at least 32 random bytes and a persistent database path:

```bash
export IMPULS_TELEMETRY_HMAC_SECRET='replace-with-a-long-random-production-secret'
export IMPULS_TELEMETRY_DATABASE=/var/lib/impuls-statistics/version-statistics.sqlite3
python3 collector.py
```

The process binds to `127.0.0.1:8080` by default. Put it behind a TLS reverse
proxy and expose only `POST /v1/heartbeat`. Configure the app at build time:

```bash
IMPULS_VERSION_STATISTICS_ENDPOINT=https://your-owned-host.example/v1/heartbeat \
  ./Scripts/bundle.sh release
```

Do not set that build variable until the real owner-controlled endpoint exists.
A build without the Info.plist value performs no version-statistics request.

The collector requires `Content-Type: application/json`, a body no larger than
2 KiB, the exact schema, and a canonical random UUID. It returns `204` on
success. It stores an HMAC-SHA256 digest of the installation UUID, never the raw
UUID. IP addresses and User-Agent values are not written to the product database
or by the collector's request logger. The in-process rate limiter keeps only a
temporary HMAC of the peer address.

Every accepted heartbeat also removes installations whose `last_seen` is older
than 365 days and their transition rows. Retention is enforced inside the same
database transaction as the write, so it does not depend on a separate cron job.

At the reverse proxy, disable access logs for `/v1/heartbeat` or configure them
to omit/anonymize client IP and User-Agent. Do not forward a public client IP in
a header merely for this collector. Apply a second body-size and rate limit at
the proxy. Back up the SQLite file and protect both it and the HMAC secret as
production credentials; rotating the HMAC secret starts a new installation
population because old and new digests cannot be linked.

## Owner-only report

Run the report through a protected administration channel (SSH or a private job),
not as a public HTTP endpoint:

```bash
python3 report.py \
  --database /var/lib/impuls-statistics/version-statistics.sqlite3 \
  --latest-version 1.4.11
```

Add `--json` for automation. Every output includes the scope warning that the
figures describe consenting active installations only.

Both the CLI report and the private dashboard open SQLite with `mode=ro` and
`PRAGMA query_only=ON`. They can read the collector's WAL database but cannot
create or modify rows.

## Private dashboard

`dashboard.py` serves one owner-only HTML page using Python's
`ThreadingHTTPServer`; it has no web-framework, JavaScript, font, asset or CDN
dependency. Run it only on a private administration network, never through the
public telemetry reverse proxy:

```bash
export IMPULS_DASHBOARD_HOST=10.0.0.21
export IMPULS_DASHBOARD_PORT=8090
export IMPULS_DASHBOARD_DATABASE=/var/lib/impuls-statistics/version-statistics.sqlite3
export IMPULS_DASHBOARD_LATEST_VERSION=1.4.11
export IMPULS_DASHBOARD_ALLOWED_CIDR=10.0.0.0/24
python3 dashboard.py
```

The host defaults to `127.0.0.1`, the port to `8090`, and the allowed network
to `127.0.0.0/8`. Database and latest-version values are required. In
production, bind to the WireGuard address only and set the CIDR to the VPN peer
network. The handler checks the socket peer address directly and deliberately
ignores proxy headers.

`IMPULS_DASHBOARD_LATEST_VERSION` is deployment configuration, not a database
inference: it must match the current production release even before that release
has received its first opt-in heartbeat. Do not add a GitHub Releases request to
the private dashboard merely to derive it. A future automation needs an
owner-controlled release-to-private-deployment channel that atomically updates a
local version file or this service configuration; this repository does not yet
contain such a channel or its server credentials.

The HTTP surface is limited to `GET` and `HEAD` for `/` and `/healthz`.
Mutating methods return `405`; other paths return `404`. `/healthz` performs a
minimal read-only database query. Request logging is disabled, and the page
contains only aggregate counts: it never exposes installation hashes or raw
database rows. The page refreshes every 60 seconds and carries restrictive
cache, framing, referrer and content-security headers.

## Container

```bash
docker build -t impuls-version-statistics .
docker run --read-only --tmpfs /tmp \
  -e IMPULS_TELEMETRY_HMAC_SECRET \
  -e IMPULS_TELEMETRY_DATABASE=/data/version-statistics.sqlite3 \
  -v impuls-statistics:/data \
  -p 127.0.0.1:8080:8080 \
  impuls-version-statistics
```

The image exposes plain HTTP only on the loopback-published port; TLS belongs to
the owner-controlled reverse proxy.
