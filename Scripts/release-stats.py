#!/usr/bin/env python3
"""Report GitHub Release asset download counts for Impuls."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def fetch_releases(repository: str, token: str | None = None) -> list[dict]:
    releases: list[dict] = []
    page = 1
    while True:
        url = f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}"
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "Impuls-release-stats",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=20) as response:
            batch = json.load(response)
        if not isinstance(batch, list):
            raise ValueError("GitHub returned an unexpected response")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def build_report(releases: list[dict], repository: str) -> dict:
    versions = []
    total = 0
    for release in releases:
        assets = []
        for asset in release.get("assets", []):
            name = asset.get("name")
            count = asset.get("download_count")
            if isinstance(name, str) and name.lower().endswith(".dmg") and isinstance(count, int):
                assets.append({"filename": name, "download_count": count})
                total += count
        tag = str(release.get("tag_name") or release.get("name") or "unknown")
        versions.append(
            {
                "version": tag.removeprefix("v"),
                "date": str(release.get("published_at") or release.get("created_at") or "")[:10],
                "dmg_assets": assets,
                "download_count": sum(asset["download_count"] for asset in assets),
            }
        )
    return {
        "repository": repository,
        "metric": "GitHub asset download_count (not unique users or installations)",
        "versions": versions,
        "total_download_count": total,
    }


def print_human(report: dict) -> None:
    print("GitHub DMG asset download counts")
    print("These are asset downloads, not unique users or unique installations.\n")
    for version in report["versions"]:
        assets = version["dmg_assets"]
        if assets:
            for index, asset in enumerate(assets):
                prefix = f"{version['version']:>10}  {version['date']}" if index == 0 else " " * 22
                print(f"{prefix}  {asset['filename']}  {asset['download_count']}")
        else:
            print(f"{version['version']:>10}  {version['date']}  —  0")
    print(f"\nTotal DMG asset download_count: {report['total_download_count']}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="TumanovNV/impuls", help="GitHub owner/repository")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        releases = fetch_releases(args.repository, os.environ.get("GITHUB_TOKEN"))
        report = build_report(releases, args.repository)
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, json.JSONDecodeError) as error:
        print(f"release-stats: {error}", file=sys.stderr)
        return 1
    if args.json:
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        print()
    else:
        print_human(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
