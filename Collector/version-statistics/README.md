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
  --latest-version 1.4.10
```

Add `--json` for automation. Every output includes the scope warning that the
figures describe consenting active installations only.

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
