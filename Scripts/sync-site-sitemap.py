#!/usr/bin/env python3
"""Keep docs/sitemap.xml aligned with the published website locale registry."""

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
    return data


def current_lastmod(sitemap: str, url: str) -> str:
    pattern = rf'<loc>{re.escape(url)}</loc>\s*<lastmod>([^<]+)</lastmod>'
    match = re.search(pattern, sitemap)
    if not match:
        raise SystemExit(f"sitemap entry missing: {url}")
    return match.group(1)


def rewrite(sitemap: str) -> str:
    registry = load_registry()
    locales = registry["locales"]
    default = registry["default_locale"]
    root_lastmod = current_lastmod(sitemap, SITE)
    privacy_url = SITE + "site-privacy.html"
    privacy_lastmod = current_lastmod(sitemap, privacy_url)

    locale_blocks = []
    for item in locales:
        priority = "1.0" if item["code"] == default else "0.9"
        locale_blocks.append(
            "  <url>\n"
            f"    <loc>{SITE}{item['path']}</loc>\n"
            f"    <lastmod>{root_lastmod}</lastmod>\n"
            "    <changefreq>weekly</changefreq>\n"
            f"    <priority>{priority}</priority>\n"
            "  </url>"
        )

    privacy = (
        "  <url>\n"
        f"    <loc>{privacy_url}</loc>\n"
        f"    <lastmod>{privacy_lastmod}</lastmod>\n"
        "    <changefreq>monthly</changefreq>\n"
        "    <priority>0.3</priority>\n"
        "  </url>"
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(locale_blocks)
        + "\n"
        + privacy
        + "\n</urlset>\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    before = SITEMAP.read_text(encoding="utf-8")
    after = rewrite(before)
    if before == after:
        print("website sitemap locale cluster is current")
        return 0
    if args.check:
        print("website sitemap locale cluster is stale", file=sys.stderr)
        return 1
    SITEMAP.write_text(after, encoding="utf-8")
    print("website sitemap locale cluster updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
