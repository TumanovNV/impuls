#!/usr/bin/env python3
"""Owner-only report for consenting Impuls version-statistics installations."""

from __future__ import annotations

import argparse
import contextlib
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCOPE_NOTICE = (
    "These are active installations whose users opted in to version statistics; "
    "they are not the absolute number of all Impuls users."
)


def build_report(database_path: Path, latest_version: str, now: datetime | None = None) -> dict:
    observed = now or datetime.now(timezone.utc)
    cutoffs = {
        str(days): (observed - timedelta(days=days)).isoformat(timespec="seconds")
        for days in (1, 7, 30)
    }
    with contextlib.closing(sqlite3.connect(database_path)) as database:
        active = {
            days: database.execute(
                "SELECT count(*) FROM installations WHERE last_seen >= ?", (cutoff,)
            ).fetchone()[0]
            for days, cutoff in cutoffs.items()
        }
        by_version = dict(
            database.execute(
                """
                SELECT current_version, count(*) FROM installations
                WHERE last_seen >= ? GROUP BY current_version ORDER BY count(*) DESC, current_version
                """,
                (cutoffs["30"],),
            ).fetchall()
        )
        transitions = [
            {"from_version": old, "to_version": new, "installations": count}
            for old, new, count in database.execute(
                """
                SELECT from_version, to_version, count(*) FROM transitions
                GROUP BY from_version, to_version ORDER BY count(*) DESC, from_version, to_version
                """
            )
        ]
        first_seen = [
            {"date": day, "installations": count}
            for day, count in database.execute(
                """
                SELECT substr(first_seen, 1, 10), count(*) FROM installations
                GROUP BY substr(first_seen, 1, 10) ORDER BY substr(first_seen, 1, 10)
                """
            )
        ]
    latest_share = 0.0 if active["30"] == 0 else 100 * by_version.get(latest_version, 0) / active["30"]
    return {
        "scope_notice": SCOPE_NOTICE,
        "generated_at": observed.isoformat(timespec="seconds"),
        "active_installations": {f"{days}_day": count for days, count in active.items()},
        "installations_by_app_version_30_day": by_version,
        "latest_version": latest_version,
        "latest_version_share_30_day_percent": round(latest_share, 2),
        "transitions": transitions,
        "new_first_seen_installations_by_day": first_seen,
    }


def print_human(report: dict) -> None:
    print(SCOPE_NOTICE)
    print()
    active = report["active_installations"]
    print(f"Active 1 day:  {active['1_day']}")
    print(f"Active 7 days: {active['7_day']}")
    print(f"Active 30 days: {active['30_day']}")
    print("\nActive installations by app version (30 days):")
    for version, count in report["installations_by_app_version_30_day"].items():
        print(f"  {version}: {count}")
    print(
        f"Latest {report['latest_version']} share (30 days): "
        f"{report['latest_version_share_30_day_percent']:.2f}%"
    )
    print("\nTransitions:")
    for row in report["transitions"]:
        print(f"  {row['from_version']} -> {row['to_version']}: {row['installations']}")
    print("\nNew first-seen consenting installations by day:")
    for row in report["new_first_seen_installations_by_day"]:
        print(f"  {row['date']}: {row['installations']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--latest-version", required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = build_report(args.database, args.latest_version)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print_human(report)


if __name__ == "__main__":
    main()
