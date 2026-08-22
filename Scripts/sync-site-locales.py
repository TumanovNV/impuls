#!/usr/bin/env python3
"""Keep the canonical RU landing page aware of every static website locale.

This script owns routing/runtime facts shared by all generated language pages:
``hreflang``, OpenGraph locale alternates, the visible language selector, its
narrow-screen layout and the runtime labels needed after a Releases API refresh.
It changes only ``docs/index.html``; localized pages are generated afterwards.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"
SITE = "https://tumanovnv.github.io/impuls/"
LOCALES = [
    ("ru", "RU", "", "ru_RU"),
    ("en", "EN", "en/", "en_US"),
    ("de", "DE", "de/", "de_DE"),
]


def sub_once(page: str, pattern: str, replacement: str, label: str, *, flags: int = 0) -> str:
    page, count = re.subn(pattern, replacement, page, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"site locale sync anchor not found: {label}")
    return page


def rewrite(page: str) -> str:
    alternate_links = "\n".join(
        f'<link rel="alternate" hreflang="{code}" href="{SITE}{path}">' for code, _, path, _ in LOCALES
    )
    alternate_links += f'\n<link rel="alternate" hreflang="x-default" href="{SITE}">'
    page = sub_once(
        page,
        r'(<link rel="canonical" href="[^"]+">\n)(?:<link rel="alternate" hreflang="[^"]+" href="[^"]+">\n)+(<link rel="manifest")',
        r"\g<1>" + alternate_links + "\n" + r"\g<2>",
        "hreflang block",
    )

    og_block = '<meta property="og:locale" content="ru_RU">\n' + "\n".join(
        f'<meta property="og:locale:alternate" content="{og}">' for code, _, _, og in LOCALES if code != "ru"
    )
    page = sub_once(
        page,
        r'<meta property="og:locale" content="[^"]+">\n(?:<meta property="og:locale:alternate" content="[^"]+">\n)*',
        og_block + "\n",
        "OpenGraph locale block",
    )

    page = sub_once(
        page,
        r'"inLanguage": \[[^\]]*\]',
        '"inLanguage": ["ru", "en", "de"]',
        "WebSite.inLanguage",
    )

    control_lines = [
        f'        <a id="btn-{code}" href="{("./" if code == "ru" else path)}" hreflang="{code}"'
        + (' aria-current="page"' if code == "ru" else "")
        + f'>{label}</a>'
        for code, label, path, _ in LOCALES
    ]
    control = '<div class="lang" role="group" aria-label="Язык страницы">\n' + "\n".join(control_lines) + "\n      </div>"
    page = sub_once(
        page,
        r'<div class="lang" role="group" aria-label="[^"]*">.*?</div>',
        control,
        "language control",
        flags=re.S,
    )

    old_mobile = """/* At 320 px the English header row — RU · EN · Download — is 3 px wider than the
   viewport where the shorter Russian one fits. Tighten the row rather than drop a
   control: the language pair and the download button both have to stay reachable. */
@media(max-width:359px){
  .nav-right{gap:var(--s2)}
  .btn-sm{padding:0 var(--s3)}
}"""
    new_mobile = """/* Three page locales plus Download no longer fit beside the full wordmark on
   the narrowest phones. Keep every action reachable and collapse only the brand
   text; the icon remains visible and the full wordmark returns above 419 px. */
@media(max-width:419px){
  .brand span{display:none}
  .nav-right{gap:var(--s2)}
  .lang a{padding-inline:7px}
  .btn-sm{padding:0 var(--s3)}
}"""
    if old_mobile in page:
        page = page.replace(old_mobile, new_mobile, 1)
    elif new_mobile not in page:
        raise SystemExit("site locale sync anchor not found: narrow header layout")

    runtime_functions = """function runtimeLabels(){ return window.IMPULS_LABELS || {}; }
function formatSize(l){
  var b = RELEASE.fileSizeBytes;
  if(!Number.isFinite(b) || b <= 0) return '';
  var mb = (b / 1000000).toFixed(1);
  if(l === 'ru') return mb.replace('.', ',') + ' МБ';
  if(l === 'en') return mb + ' MB';
  var labels = runtimeLabels();
  return mb.replace('.', labels.decimal || '.') + ' ' + (labels.sizeUnit || 'MB');
}"""
    # Match both the pre-localization form (formatSize only) and our already
    # synchronized form (runtimeLabels + formatSize). Without the optional helper
    # in the match, a second rewrite would prepend runtimeLabels() again and make
    # --check non-idempotent.
    page = sub_once(
        page,
        r'(?:function runtimeLabels\(\)\{.*?\}\n)?function formatSize\(l\)\{.*?\n\}',
        runtime_functions,
        "runtime release labels",
        flags=re.S,
    )

    old_version = "if(k === 'version-label') el.textContent = (LANG === 'en' ? 'Version ' : 'Версия ') + RELEASE.version;"
    new_version = "if(k === 'version-label'){ var labels = runtimeLabels(); el.textContent = (LANG === 'ru' ? 'Версия' : (labels.version || 'Version')) + ' ' + RELEASE.version; }"
    if old_version in page:
        page = page.replace(old_version, new_version, 1)
    elif new_version not in page:
        raise SystemExit("site locale sync anchor not found: release version label")

    old_rail = "rail.setAttribute('aria-label', LANG === 'en' ? 'Modules' : 'Модули');"
    new_rail = "rail.setAttribute('aria-label', LANG === 'ru' ? 'Модули' : (runtimeLabels().modules || 'Modules'));"
    if old_rail in page:
        page = page.replace(old_rail, new_rail, 1)
    elif new_rail not in page:
        raise SystemExit("site locale sync anchor not found: module rail label")

    old_copied = "span.textContent = LANG === 'en' ? 'Copied' : 'Скопировано';"
    new_copied = "span.textContent = LANG === 'ru' ? 'Скопировано' : (runtimeLabels().copied || 'Copied');"
    if old_copied in page:
        page = page.replace(old_copied, new_copied, 1)
    elif new_copied not in page:
        raise SystemExit("site locale sync anchor not found: copied label")

    start = """/* --- Start -------------------------------------------------------------- */
document.getElementById('year').textContent = new Date().getFullYear();
/* A generated static page sets IMPULS_LANG before this script. Its body/head are
   already localized, so only RU/EN use the old DOM dictionary swap. Other
   locales keep their generated body and use runtime labels for release facts. */
var initial = window.IMPULS_LANG || 'ru';
if(!window.IMPULS_LANG){
  try{
    var legacyLang = new URL(location.href).searchParams.get('lang');
    if(legacyLang === 'en' || legacyLang === 'de'){
      location.replace(legacyLang + '/');
      return;
    }
  }catch(e){}
}
if(initial === 'ru' || initial === 'en'){
  setLang(initial);
}else{
  LANG = initial;
  renderRelease();
  buildRail();
}
loadRelease();"""
    page = sub_once(
        page,
        r'/\* --- Start -------------------------------------------------------------- \*/\n.*?loadRelease\(\);',
        start,
        "startup locale flow",
        flags=re.S,
    )

    if page.count("function runtimeLabels(){") != 1:
        raise SystemExit("website locale sync must leave exactly one runtimeLabels helper")
    return page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report staleness instead of fixing it")
    args = parser.parse_args()
    before = PAGE.read_text(encoding="utf-8")
    after = rewrite(before)
    if before == after:
        print("website locale routing is current")
        return 0
    if args.check:
        print("website locale routing is stale", file=sys.stderr)
        return 1
    PAGE.write_text(after, encoding="utf-8")
    print("website locale routing updated: ru, en, de")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
