#!/usr/bin/env python3
"""Write the current release into the website's static metadata.

The site reads the Releases API at runtime, which is enough for a person with a
browser and not enough for anybody else: a crawler, a preview card, or a visitor
with JavaScript disabled sees whatever the markup says. That is how the page
came to advertise 1.4.9 to humans and 1.2.8 to Google.

So the markup carries the real release too, and this script is what puts it
there. It runs after a release is published and touches nothing but `docs/`.
It does not sign, tag, build, or publish anything, and it cannot start a release:
`release.yml` triggers on `Scripts/version` and `build.yml` ignores `docs/`.

    python3 Scripts/sync-site-release.py            # read the latest release
    python3 Scripts/sync-site-release.py --check    # exit 1 if the site is stale

Every value it writes also exists in the page's `FALLBACK_RELEASE`, so a run that
changes nothing is a no-op rather than a reformat.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

REPO = "TumanovNV/impuls"
API = f"https://api.github.com/repos/{REPO}/releases/latest"
ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"


class Stale(Exception):
    pass


def fetch_release() -> dict:
    request = urllib.request.Request(
        API,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "impuls-site-sync",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def describe(release: dict) -> dict:
    """Reduce a GitHub release to the handful of facts the site shows."""
    version = str(release.get("tag_name", "")).lstrip("v")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit(f"unexpected tag: {release.get('tag_name')!r}")

    assets = release.get("assets") or []
    dmg = next((a for a in assets if str(a.get("name", "")).endswith(".dmg")), None)
    if dmg is None:
        raise SystemExit(f"release {version} publishes no DMG")

    size = int(dmg.get("size") or 0)
    if size <= 0:
        raise SystemExit(f"release {version} reports no DMG size")

    digest = re.fullmatch(r"sha256:([a-f0-9]{64})", str(dmg.get("digest") or ""), re.I)
    if digest:
        sha = digest.group(1).lower()
    else:
        # Older releases predate the API's digest field; the workflow writes the
        # checksum into the body, so fall back to that before giving up.
        body = re.search(r"\b([a-f0-9]{64})\b", str(release.get("body") or ""), re.I)
        if not body:
            raise SystemExit(f"release {version} exposes no SHA-256 for the DMG")
        sha = body.group(1).lower()

    return {
        "version": version,
        "file_name": str(dmg["name"]),
        "size_bytes": size,
        "size_en": f"{size / 1_000_000:.1f} MB",
        "size_ru": f"{size / 1_000_000:.1f}".replace(".", ",") + " МБ",
        "download_url": str(dmg["browser_download_url"]),
        "page_url": str(release.get("html_url") or f"https://github.com/{REPO}/releases/tag/v{version}"),
        "published": str(release.get("published_at") or "")[:10],
        "sha256": sha,
    }


def substitute(pattern: str, replacement: str, text: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.S)
    if count == 0:
        raise SystemExit(f"anchor not found in docs/index.html: {label}")
    return updated


def rewrite(page: str, r: dict) -> str:
    """Every place the release appears, and nowhere else."""

    # 1. JSON-LD, which is the copy search engines actually read.
    page = substitute(r'("softwareVersion":\s*")[^"]*(")', rf'\g<1>{r["version"]}\g<2>', page, "softwareVersion")
    page = substitute(r'("fileSize":\s*")[^"]*(")', rf'\g<1>{r["size_en"]}\g<2>', page, "fileSize")
    page = substitute(r'("datePublished":\s*")[^"]*(")', rf'\g<1>{r["published"]}\g<2>', page, "datePublished")
    for key in ("downloadUrl", "installUrl"):
        page = substitute(rf'("{key}":\s*")[^"]*(")', rf'\g<1>{r["download_url"]}\g<2>', page, key)
    page = substitute(r'("releaseNotes":\s*")[^"]*(")', rf'\g<1>{r["page_url"]}\g<2>', page, "releaseNotes")

    # 2. The record the script itself falls back to when the API is unreachable.
    page = substitute(r"(version:')[^']*(')", rf'\g<1>{r["version"]}\g<2>', page, "FALLBACK version")
    page = substitute(r"(fileName:')[^']*(')", rf'\g<1>{r["file_name"]}\g<2>', page, "FALLBACK fileName")
    page = substitute(r"(fileSizeBytes:)\d+", rf'\g<1>{r["size_bytes"]}', page, "FALLBACK fileSizeBytes")
    page = substitute(r"(downloadUrl:')[^']*(')", rf'\g<1>{r["download_url"]}\g<2>', page, "FALLBACK downloadUrl")
    page = substitute(r"(pageUrl:')[^']*(')", rf'\g<1>{r["page_url"]}\g<2>', page, "FALLBACK pageUrl")
    page = substitute(r"(hash:')[^']*(')", rf'\g<1>{r["sha256"]}\g<2>', page, "FALLBACK hash")

    # 3. What a visitor without JavaScript reads.
    page = re.sub(
        r'(<span data-release="version-label">)[^<]*(</span>)',
        rf'\g<1>Версия {r["version"]}\g<2>', page)
    page = re.sub(
        r'(<span data-release="size">)[^<]*(</span>)',
        rf'\g<1>{r["size_ru"]}\g<2>', page)
    page = re.sub(
        r'(<span data-release="filename">)[^<]*(</span>)',
        rf'\g<1>{r["file_name"]}\g<2>', page)
    page = substitute(r'(<code id="hash">)[a-f0-9]{64}(</code>)', rf'\g<1>{r["sha256"]}\g<2>', page, "hash element")

    return page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report staleness instead of fixing it")
    parser.add_argument("--release-json", type=Path, help="read the release from a file instead of the API")
    args = parser.parse_args()

    release = json.loads(args.release_json.read_text()) if args.release_json else fetch_release()
    facts = describe(release)

    before = PAGE.read_text(encoding="utf-8")
    after = rewrite(before, facts)

    if before == after:
        print(f"docs/index.html already describes {facts['version']}")
        return 0

    if args.check:
        print(f"docs/index.html is stale: the latest release is {facts['version']}", file=sys.stderr)
        return 1

    PAGE.write_text(after, encoding="utf-8")
    print(
        f"docs/index.html updated to {facts['version']} "
        f"({facts['file_name']}, {facts['size_en']}, sha256 {facts['sha256'][:12]}…)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
