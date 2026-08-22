#!/usr/bin/env python3
"""Build a localized static landing page from the canonical Russian source.

The Russian landing page remains the single HTML/layout source. Locales beyond
that source live as data in ``Scripts/site-locales/<locale>.json`` and are
rendered to ``docs/<locale>/index.html``. This keeps each language on a real,
indexable URL without hand-maintaining copies of the landing page.

    python3 Scripts/build-site-locale.py --locale de
    python3 Scripts/build-site-locale.py --locale de --check

Pure standard library on purpose: the site sync workflow runs without a browser
or package installation.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "index.html"
LOCALE_DIR = ROOT / "Scripts" / "site-locales"
SITE = "https://tumanovnv.github.io/impuls/"
VOID = {"img", "br", "hr", "input", "meta", "link", "source", "path", "circle", "rect", "svg"}


def element_span(page: str, start: int) -> tuple[int, int, str] | None:
    tag_match = re.match(r"<([a-zA-Z0-9]+)", page[start:])
    if not tag_match:
        return None
    tag = tag_match.group(1)
    if tag.lower() in VOID:
        return None
    open_end = page.find(">", start)
    if open_end == -1:
        return None

    depth = 1
    cursor = open_end + 1
    pattern = re.compile(rf"<(/?){tag}\b", re.I)
    while depth:
        found = pattern.search(page, cursor)
        if not found:
            return None
        depth += -1 if found.group(1) else 1
        cursor = found.end()
    close = page.rfind("<", 0, cursor)
    return open_end + 1, close, tag


def translatable_keys(page: str) -> set[str]:
    return set(re.findall(r'\bdata-i="([^"]+)"', page))


def screenshot_keys(page: str) -> set[str]:
    return set(re.findall(r'<img[^>]*\bdata-shot="([^"]+)"', page))


def validate_config(page: str, cfg: dict) -> None:
    required = {
        "locale", "html_lang", "path", "og_locale", "title", "description",
        "og_title", "og_description", "og_image_alt", "nav_aria", "language_aria",
        "runtime", "strings", "alts", "schema",
    }
    missing = sorted(required - set(cfg))
    if missing:
        raise SystemExit("locale config missing fields: " + ", ".join(missing))

    expected = translatable_keys(page)
    actual = set(cfg["strings"])
    if expected != actual:
        missing_keys = sorted(expected - actual)
        extra_keys = sorted(actual - expected)
        details = []
        if missing_keys:
            details.append("missing data-i keys: " + ", ".join(missing_keys))
        if extra_keys:
            details.append("unknown data-i keys: " + ", ".join(extra_keys))
        raise SystemExit("; ".join(details))

    expected_alts = screenshot_keys(page)
    actual_alts = set(cfg["alts"])
    if expected_alts != actual_alts:
        missing_alts = sorted(expected_alts - actual_alts)
        extra_alts = sorted(actual_alts - expected_alts)
        details = []
        if missing_alts:
            details.append("missing screenshot alts: " + ", ".join(missing_alts))
        if extra_alts:
            details.append("unknown screenshot alts: " + ", ".join(extra_alts))
        raise SystemExit("; ".join(details))

    schema = cfg["schema"]
    if len(schema.get("faq", [])) != 6:
        raise SystemExit("localized JSON-LD must contain the same six canonical FAQ entries")
    if len(schema.get("feature_list", [])) != 8:
        raise SystemExit("localized JSON-LD must contain the same eight feature-list entries")


def translate(page: str, words: dict[str, str]) -> str:
    out: list[str] = []
    cursor = 0
    applied: set[str] = set()
    for hit in re.finditer(r'<[a-zA-Z0-9]+\b[^>]*\bdata-i="([^"]+)"[^>]*>', page):
        key = hit.group(1)
        if key not in words:
            continue
        span = element_span(page, hit.start())
        if span is None:
            continue
        inner_start, inner_end, _ = span
        if inner_start < cursor:
            continue
        out.append(page[cursor:inner_start])
        out.append(words[key])
        cursor = inner_end
        applied.add(key)
    out.append(page[cursor:])
    if applied != set(words):
        missing = sorted(set(words) - applied)
        raise SystemExit("translations did not land for: " + ", ".join(missing))
    return "".join(out)


def localized_schema(page: str, cfg: dict) -> dict:
    match = re.search(
        r'<script type="application/ld\+json" id="software-schema">(.*?)</script>', page, re.S
    )
    if not match:
        raise SystemExit("no software JSON-LD found in docs/index.html")
    schema = json.loads(match.group(1))
    graph = schema.get("@graph", [])
    locale = cfg["locale"]
    path = cfg["path"]
    shot_locale = cfg.get("screenshot_locale", "en")
    scfg = cfg["schema"]

    website = next(i for i in graph if i.get("@type") == "WebSite")
    website["inLanguage"] = cfg.get("site_languages", ["ru", "en", locale])

    app = next(i for i in graph if i.get("@type") == "SoftwareApplication")
    app["@id"] = SITE + path + "#software"
    app["description"] = scfg["software_description"]
    app["featureList"] = scfg["feature_list"]
    app["inLanguage"] = locale
    app["screenshot"] = SITE + f"assets/screens/{shot_locale}/actions.png"
    app["offers"] = {"@type": "Offer", "price": "0", "priceCurrency": scfg["price_currency"]}
    if scfg.get("alternate_name"):
        app["alternateName"] = scfg["alternate_name"]

    faq = next(i for i in graph if i.get("@type") == "FAQPage")
    faq["@id"] = SITE + path + "#faq-schema"
    faq["mainEntity"] = [
        {
            "@type": "Question",
            "name": item["question"],
            "acceptedAnswer": {"@type": "Answer", "text": item["answer"]},
        }
        for item in scfg["faq"]
    ]
    return schema


def language_control(current: str) -> str:
    locales = [
        ("ru", "RU", "../"),
        ("en", "EN", "../en/"),
        ("de", "DE", "../de/"),
    ]
    lines = []
    for code, label, href in locales:
        actual = "./" if code == current else href
        current_attr = ' aria-current="page"' if code == current else ""
        lines.append(f'        <a id="btn-{code}" href="{actual}" hreflang="{code}"{current_attr}>{label}</a>')
    return '<div class="lang" role="group" aria-label="__LANG_ARIA__">\n' + "\n".join(lines) + "\n      </div>"


def build(page: str, cfg: dict) -> str:
    validate_config(page, cfg)
    locale = cfg["locale"]
    path = cfg["path"]
    page = translate(page, cfg["strings"])

    shot_locale = cfg.get("screenshot_locale", "en")
    page = page.replace("assets/screens/ru/", f"assets/screens/{shot_locale}/")
    for name, text in cfg["alts"].items():
        page = re.sub(
            rf'(<img[^>]*data-shot="{re.escape(name)}"[^>]*\balt=")[^"]*(")',
            lambda m, t=text: m.group(1) + t + m.group(2),
            page,
        )

    version_label = cfg["runtime"]["version"]
    size_unit = cfg["runtime"]["size_unit"]
    decimal = cfg["runtime"].get("decimal", ".")
    page = re.sub(
        r'(<span data-release="version-label">)\S+\s+([^<]*)(</span>)',
        lambda m: m.group(1) + version_label + " " + m.group(2) + m.group(3),
        page,
    )
    page = re.sub(
        r'(<span data-release="size">)([\d,\.]+) МБ(</span>)',
        lambda m: m.group(1) + m.group(2).replace(",", decimal).replace(".", decimal) + " " + size_unit + m.group(3),
        page,
    )

    swaps = [
        (r'<html lang="ru">', f'<html lang="{cfg["html_lang"]}">'),
        (r"<title>[^<]*</title>", f'<title>{cfg["title"]}</title>'),
        (r'(<meta name="description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["description"] + m.group(2)),
        (r'(<link rel="canonical" href=")[^"]*(">)', lambda m: m.group(1) + SITE + path + m.group(2)),
        (r'(<meta property="og:url" content=")[^"]*(">)', lambda m: m.group(1) + SITE + path + m.group(2)),
        (r'(<meta property="og:locale" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_locale"] + m.group(2)),
        (r'(<meta property="og:title" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_title"] + m.group(2)),
        (r'(<meta property="og:description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_description"] + m.group(2)),
        (r'(<meta property="og:image:alt" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_image_alt"] + m.group(2)),
        (r'(<meta name="twitter:title" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_title"] + m.group(2)),
        (r'(<meta name="twitter:description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_description"] + m.group(2)),
        (r'(<meta name="application-name" content=")[^"]*(">)', lambda m: m.group(1) + cfg.get("application_name", "Impuls") + m.group(2)),
        (r'(<meta name="author" content=")[^"]*(">)', lambda m: m.group(1) + cfg.get("author", "Nikolay Tumanov") + m.group(2)),
        (r'<nav class="nav-links" aria-label="[^"]*">', f'<nav class="nav-links" aria-label="{cfg["nav_aria"]}">'),
    ]
    for pattern, replacement in swaps:
        page = re.sub(pattern, replacement, page, count=1)

    schema = localized_schema(page, cfg)
    page = re.sub(
        r'<script type="application/ld\+json" id="software-schema">.*?</script>',
        '<script type="application/ld+json" id="software-schema">\n'
        + json.dumps(schema, ensure_ascii=False, indent=2)
        + "\n</script>",
        page,
        flags=re.S,
    )

    page = re.sub(
        r'((?:href|src|srcset)=")(assets/|manifest\.webmanifest|site-privacy\.html)',
        r"\g<1>../\g<2>",
        page,
    )

    control = language_control(locale).replace("__LANG_ARIA__", cfg["language_aria"])
    page, count = re.subn(r'<div class="lang" role="group" aria-label="[^"]*">.*?</div>', control, page, count=1, flags=re.S)
    if count != 1:
        raise SystemExit("language control not found in docs/index.html")

    runtime = {
        "version": cfg["runtime"]["version"],
        "sizeUnit": cfg["runtime"]["size_unit"],
        "decimal": decimal,
        "copied": cfg["runtime"]["copied"],
        "modules": cfg["runtime"]["modules"],
    }
    marker = "<script>document.documentElement.classList.add('js')</script>"
    replacement = (
        "<script>document.documentElement.classList.add('js');"
        f"window.IMPULS_LANG={json.dumps(locale)};"
        f"window.IMPULS_LABELS={json.dumps(runtime, ensure_ascii=False, separators=(',', ':'))}"
        "</script>"
    )
    if marker not in page:
        raise SystemExit("JavaScript bootstrap marker not found in docs/index.html")
    page = page.replace(marker, replacement, 1)

    banner = (
        f"<!-- Generated by Scripts/build-site-locale.py from ../index.html using "
        f"Scripts/site-locales/{locale}.json. Do not edit this page directly. -->\n"
    )
    return banner + page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", required=True, help="locale code, for example de")
    parser.add_argument("--check", action="store_true", help="exit 1 if the generated page is stale")
    args = parser.parse_args()

    config_path = LOCALE_DIR / f"{args.locale}.json"
    if not config_path.exists():
        print(f"unknown site locale: {args.locale}", file=sys.stderr)
        return 2
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
    if cfg.get("locale") != args.locale:
        print(f"locale mismatch in {config_path}", file=sys.stderr)
        return 2

    built = build(SOURCE.read_text(encoding="utf-8"), cfg)
    target = ROOT / "docs" / cfg["path"] / "index.html"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != built:
            print(f"{target.relative_to(ROOT)} is out of date; rebuild locale {args.locale}", file=sys.stderr)
            return 1
        print(f"{target.relative_to(ROOT)} is current")
        return 0

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(built, encoding="utf-8")
    print(f"wrote {target.relative_to(ROOT)} ({len(built)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
