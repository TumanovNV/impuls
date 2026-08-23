#!/usr/bin/env python3
"""Keep docs/sitemap.xml aligned with landing and privacy locale routes."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITEMAP = ROOT / "docs" / "sitemap.xml"
REGISTRY = ROOT / "Scripts" / "site-locales" / "registry.json"
SITE = "https://tumanovnv.github.io/impuls/"


def load_registry() -> dict:
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    locales = data.get("locales")
    if not isinstance(locales, list) or not locales:
        raise SystemExit("website locale registry needs a non-empty locales list")
    required = {"code", "path", "privacy_path"}
    if any(required - set(item) for item in locales):
        raise SystemExit("website locale registry needs path and privacy_path for every locale")
    return data


def maybe_lastmod(sitemap: str, url: str) -> str | None:
    match = re.search(rf'<loc>{re.escape(url)}</loc>\s*<lastmod>([^<]+)</lastmod>', sitemap)
    return match.group(1) if match else None


def block(url: str, lastmod: str, frequency: str, priority: str) -> str:
    return (
        "  <url>\n"
        f"    <loc>{url}</loc>\n"
        f"    <lastmod>{lastmod}</lastmod>\n"
        f"    <changefreq>{frequency}</changefreq>\n"
        f"    <priority>{priority}</priority>\n"
        "  </url>"
    )


def rewrite(sitemap: str) -> str:
    registry = load_registry()
    locales = registry["locales"]
    default = registry["default_locale"]
    root_lastmod = maybe_lastmod(sitemap, SITE)
    if not root_lastmod:
        raise SystemExit("sitemap root entry is missing")

    default_privacy = next(item["privacy_path"] for item in locales if item["code"] == default)
    privacy_lastmod = (
        maybe_lastmod(sitemap, SITE + default_privacy)
        or maybe_lastmod(sitemap, SITE + "site-privacy.html")
        or root_lastmod
    )

    blocks: list[str] = []
    for item in locales:
        priority = "1.0" if item["code"] == default else "0.9"
        blocks.append(block(SITE + item["path"], root_lastmod, "weekly", priority))
    for item in locales:
        priority = "0.5" if item["code"] == default else "0.4"
        blocks.append(block(SITE + item["privacy_path"], privacy_lastmod, "monthly", priority))

    legacy_note = "  <!-- Legacy site-privacy.html redirects to /privacy/ and is intentionally excluded from indexed URL entries. -->"
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(blocks)
        + "\n"
        + legacy_note
        + "\n</urlset>\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    before = SITEMAP.read_text(encoding="utf-8")
    after = rewrite(before)
    if before == after:
        print("website sitemap locale and privacy clusters are current")
        return 0
    if args.check:
        print("website sitemap locale/privacy cluster is stale", file=sys.stderr)
        return 1
    SITEMAP.write_text(after, encoding="utf-8")
    print("website sitemap locale and privacy clusters updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
