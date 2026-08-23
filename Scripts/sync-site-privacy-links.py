#!/usr/bin/env python3
"""Point the canonical landing-page privacy CTA at the localized privacy cluster."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"
REGISTRY = ROOT / "Scripts" / "site-locales" / "registry.json"


def canonical_privacy_path() -> str:
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    default = data["default_locale"]
    item = next(item for item in data["locales"] if item["code"] == default)
    path = item.get("privacy_path")
    if not isinstance(path, str) or not path:
        raise SystemExit("default locale needs privacy_path")
    return path


def rewrite(page: str) -> str:
    desired = canonical_privacy_path()
    pattern = r'(<a class="btn btn-ghost btn-sm" href=")(?:site-privacy\.html|privacy/)("><span data-i="p\.doc">)'
    page, count = re.subn(pattern, rf'\g<1>{desired}\g<2>', page, count=1)
    if count != 1:
        raise SystemExit("privacy CTA anchor not found")
    return page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    before = PAGE.read_text(encoding="utf-8")
    after = rewrite(before)
    if before == after:
        print("website privacy CTA is current")
        return 0
    if args.check:
        print("website privacy CTA is stale", file=sys.stderr)
        return 1
    PAGE.write_text(after, encoding="utf-8")
    print("website privacy CTA updated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
