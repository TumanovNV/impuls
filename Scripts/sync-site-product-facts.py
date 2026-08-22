#!/usr/bin/env python3
"""Keep durable product facts in the generated website markup.

Release metadata is synchronized separately by ``sync-site-release.py``. This
script owns small product facts that should survive that rewrite and the English
page regeneration. It edits only ``docs/index.html``; ``build-en-page.py`` then
produces ``docs/en/index.html`` from the same source and its EN dictionary.

    python3 Scripts/sync-site-product-facts.py
    python3 Scripts/sync-site-product-facts.py --check
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"

HERO_RU = '      <li data-i="hero.m4">7 языков интерфейса</li>'
FAQ_RU = (
    '      <details data-site-fact="languages"><summary data-i="f.q9">'
    'На каких языках работает Impuls?</summary><div class="a" data-i="f.a9">'
    'Интерфейс доступен на русском, английском, немецком, французском, испанском, '
    'упрощённом китайском и японском. Можно следовать языку macOS или выбрать язык '
    'вручную в настройках.</div></details>'
)

EN_FACTS = (
    '"hero.m4":"7 interface languages",\n'
    '"f.q9":"Which languages does Impuls support?",\n'
    '"f.a9":"The interface is available in Russian, English, German, French, Spanish, '
    'Simplified Chinese and Japanese. It can follow the macOS language or use a language '
    'you choose in Settings.",\n'
)


def rewrite(page: str) -> str:
    if 'data-i="hero.m4"' not in page:
        anchor = '      <li data-i="hero.m3">Открытый код</li>'
        if anchor not in page:
            raise SystemExit("hero metadata anchor not found in docs/index.html")
        page = page.replace(anchor, HERO_RU + "\n" + anchor, 1)

    if 'data-site-fact="languages"' not in page:
        pattern = r'(\s*<details><summary data-i="f\.q8">.*?</details>)'
        replacement = r'\1\n' + FAQ_RU
        page, count = re.subn(pattern, replacement, page, count=1, flags=re.S)
        if count != 1:
            raise SystemExit("FAQ anchor f.q8 not found in docs/index.html")

    if '"hero.m4":"7 interface languages"' not in page:
        anchor = 'var EN = {\n'
        if anchor not in page:
            raise SystemExit("EN dictionary anchor not found in docs/index.html")
        page = page.replace(anchor, anchor + EN_FACTS, 1)

    return page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report staleness instead of fixing it")
    args = parser.parse_args()

    before = PAGE.read_text(encoding="utf-8")
    after = rewrite(before)

    if before == after:
        print("website product facts are current")
        return 0

    if args.check:
        print("website product facts are stale", file=sys.stderr)
        return 1

    PAGE.write_text(after, encoding="utf-8")
    print("website product facts updated: seven interface languages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
