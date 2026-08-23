#!/usr/bin/env python3
"""Keep the canonical RU landing page aware of every static website locale.

The locale cluster comes from ``Scripts/site-locales/registry.json``. This
script owns reciprocal hreflang/OpenGraph metadata, the visible language
selector, narrow-screen header behavior and generated-page runtime labels.
It changes only ``docs/index.html``; localized pages are generated afterwards.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"
REGISTRY_PATH = ROOT / "Scripts" / "site-locales" / "registry.json"
SITE = "https://tumanovnv.github.io/impuls/"


def load_registry() -> dict:
    data = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    locales = data.get("locales")
    if not isinstance(locales, list) or not locales:
        raise SystemExit("website locale registry needs a non-empty locales list")
    required = {"code", "label", "path", "og_locale"}
    for item in locales:
        if not isinstance(item, dict) or required - set(item):
            raise SystemExit("website locale registry entry is incomplete")
        if not all(isinstance(item[k], str) for k in required):
            raise SystemExit("website locale registry fields must be strings")
    codes = [item["code"] for item in locales]
    paths = [item["path"] for item in locales]
    if len(codes) != len(set(codes)) or len(paths) != len(set(paths)):
        raise SystemExit("website locale registry codes and paths must be unique")
    default = data.get("default_locale")
    if default not in codes:
        raise SystemExit("website locale registry default_locale must exist")
    if next(item for item in locales if item["code"] == default)["path"] != "":
        raise SystemExit("website default locale must own the site root")
    return data


REGISTRY = load_registry()
LOCALES = REGISTRY["locales"]
DEFAULT_LOCALE = REGISTRY["default_locale"]


def sub_once(page: str, pattern: str, replacement: str, label: str, *, flags: int = 0) -> str:
    page, count = re.subn(pattern, replacement, page, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"site locale sync anchor not found: {label}")
    return page


def rewrite(page: str) -> str:
    alternate_links = "\n".join(
        f'<link rel="alternate" hreflang="{item["code"]}" href="{SITE}{item["path"]}">' for item in LOCALES
    )
    alternate_links += f'\n<link rel="alternate" hreflang="x-default" href="{SITE}">'
    page = sub_once(
        page,
        r'(<link rel="canonical" href="[^"]+">\n)(?:<link rel="alternate" hreflang="[^"]+" href="[^"]+">\n)+(<link rel="manifest")',
        r"\g<1>" + alternate_links + "\n" + r"\g<2>",
        "hreflang block",
    )

    default_og = next(item["og_locale"] for item in LOCALES if item["code"] == DEFAULT_LOCALE)
    og_block = f'<meta property="og:locale" content="{default_og}">\n' + "\n".join(
        f'<meta property="og:locale:alternate" content="{item["og_locale"]}">'
        for item in LOCALES if item["code"] != DEFAULT_LOCALE
    )
    page = sub_once(
        page,
        r'<meta property="og:locale" content="[^"]+">\n(?:<meta property="og:locale:alternate" content="[^"]+">\n)*',
        og_block + "\n",
        "OpenGraph locale block",
    )

    language_json = json.dumps([item["code"] for item in LOCALES], ensure_ascii=False)
    page = sub_once(
        page,
        r'"inLanguage": \[[^\]]*\]',
        f'"inLanguage": {language_json}',
        "WebSite.inLanguage",
    )

    control_lines = [
        f'        <a id="btn-{item["code"]}" href="{("./" if item["code"] == DEFAULT_LOCALE else item["path"])}" hreflang="{item["code"]}"'
        + (' aria-current="page"' if item["code"] == DEFAULT_LOCALE else "")
        + f'>{item["label"]}</a>'
        for item in LOCALES
    ]
    control = '<div class="lang" role="group" aria-label="Язык страницы">\n' + "\n".join(control_lines) + "\n      </div>"
    page = sub_once(
        page,
        r'<div class="lang" role="group" aria-label="[^"]*">.*?</div>',
        control,
        "language control",
        flags=re.S,
    )

    previous_mobile = """/* Five page locales plus Download stay reachable even on a 320 px viewport.
   Collapse only the wordmark text and tighten controls; locale links remain
   visible rather than moving into a JavaScript-only menu. */
@media(max-width:559px){
  .brand span{display:none}
  .nav-right{gap:var(--s1)}
  .lang a{padding-inline:5px;font-size:.72rem}
  .btn-sm{padding:0 var(--s2)}
}"""
    mobile = """/* Seven page locales no longer fit as a fixed row on the narrowest phones.
   Keep every language and Download reachable without JavaScript: the wordmark
   collapses first, then only the locale strip becomes horizontally scrollable. */
@media(max-width:699px){
  .brand span{display:none}
  .nav-right{gap:var(--s1);min-width:0}
  .lang{max-width:48vw;overflow-x:auto;scrollbar-width:none;-webkit-overflow-scrolling:touch}
  .lang::-webkit-scrollbar{display:none}
  .lang a{flex:0 0 auto;padding-inline:5px;font-size:.72rem}
  .btn-sm{padding:0 var(--s2)}
}
@media(max-width:359px){
  .brand{display:none}
  .lang{max-width:68vw}
}"""
    if previous_mobile in page:
        page = page.replace(previous_mobile, mobile, 1)
    elif mobile not in page:
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
    page = sub_once(
        page,
        r'(?:function runtimeLabels\(\)\{.*?\}\n)?function formatSize\(l\)\{.*?\n\}',
        runtime_functions,
        "runtime release labels",
        flags=re.S,
    )

    current_version = "if(k === 'version-label'){ var labels = runtimeLabels(); el.textContent = (LANG === 'ru' ? 'Версия' : (labels.version || 'Version')) + ' ' + RELEASE.version; }"
    if current_version not in page:
        raise SystemExit("site locale sync anchor not found: release version label")

    current_rail = "rail.setAttribute('aria-label', LANG === 'ru' ? 'Модули' : (runtimeLabels().modules || 'Modules'));"
    if current_rail not in page:
        raise SystemExit("site locale sync anchor not found: module rail label")

    current_copied = "span.textContent = LANG === 'ru' ? 'Скопировано' : (runtimeLabels().copied || 'Copied');"
    if current_copied not in page:
        raise SystemExit("site locale sync anchor not found: copied label")

    generated_routes = {
        item["code"]: item["path"]
        for item in LOCALES
        if item["code"] != DEFAULT_LOCALE
    }
    legacy_json = json.dumps(generated_routes, ensure_ascii=False, separators=(",", ":"))
    start = f"""/* --- Start -------------------------------------------------------------- */
document.getElementById('year').textContent = new Date().getFullYear();
/* A generated static page sets IMPULS_LANG before this script. Its body/head are
   already localized, so only RU/EN use the old DOM dictionary swap. Other
   locales keep their generated body and use runtime labels for release facts. */
var initial = window.IMPULS_LANG || 'ru';
if(!window.IMPULS_LANG){{
  try{{
    var legacyLang = new URL(location.href).searchParams.get('lang');
    var legacyRoutes = {legacy_json};
    if(legacyLang && legacyRoutes[legacyLang]){{
      location.replace(legacyRoutes[legacyLang]);
      return;
    }}
  }}catch(e){{}}
}}
if(initial === 'ru' || initial === 'en'){{
  setLang(initial);
}}else{{
  LANG = initial;
  renderRelease();
  buildRail();
}}
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
    print("website locale routing updated: " + ", ".join(item["code"] for item in LOCALES))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
