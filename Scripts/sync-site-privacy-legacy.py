#!/usr/bin/env python3
"""Keep the legacy /site-privacy.html URL as a no-JS handoff to /privacy/."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "docs" / "site-privacy.html"
CANONICAL = "https://tumanovnv.github.io/impuls/privacy/"

PAGE = f'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Политика конфиденциальности — ИМПУЛЬС</title>
<meta name="robots" content="noindex,follow">
<link rel="canonical" href="{CANONICAL}">
<meta http-equiv="refresh" content="0; url={CANONICAL}">
<style>body{{margin:0;background:#fbfbfd;color:#12141a;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}main{{max-width:720px;margin:12vh auto;padding:24px}}a{{color:#0a5fd6}}@media(prefers-color-scheme:dark){{body{{background:#0b0d11;color:#f0f2f7}}a{{color:#65a2ff}}}}</style>
</head>
<body><main><h1>Политика конфиденциальности перемещена</h1><p>Актуальная политика Impuls находится по адресу <a href="{CANONICAL}">{CANONICAL}</a>.</p><p>The current Impuls privacy policy is available at the link above.</p></main></body>
</html>
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else ""
    if current == PAGE:
        print("legacy privacy handoff is current")
        return 0
    if args.check:
        print("legacy privacy handoff is stale", file=sys.stderr)
        return 1
    TARGET.write_text(PAGE, encoding="utf-8")
    print("legacy privacy handoff updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
