#!/usr/bin/env python3
"""Generate an indexable static website locale from the canonical RU page.

`docs/index.html` owns layout. Locale data lives in `Scripts/site-locales/` and
all generated pages use this one builder. English temporarily reuses the
embedded EN/ALT dictionaries while German is fully external.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "index.html"
LOCALE_DIR = ROOT / "Scripts" / "site-locales"
SITE = "https://tumanovnv.github.io/impuls/"
SITE_LOCALES = [("ru", "RU", ""), ("en", "EN", "en/"), ("de", "DE", "de/")]
OG_LOCALES = {"ru": "ru_RU", "en": "en_US", "de": "de_DE"}
VOID = {"img", "br", "hr", "input", "meta", "link", "source", "path", "circle", "rect", "svg"}

# Old EN and the initial DE seed still contain these two strings, but the current
# landing page deliberately removed the corresponding visible eyebrow rows.
# They are the only tolerated dead keys; every other extra still fails closed.
LEGACY_UNUSED_STRING_KEYS = frozenset({"d.eyebrow", "f.eyebrow"})


def read_embedded_dict(page: str, name: str) -> dict[str, str]:
    match = re.search(rf"var {re.escape(name)} = (\{{.*?\n\}});", page, re.S)
    if not match:
        raise SystemExit(f"embedded dictionary {name} not found")
    value = json.loads(match.group(1))
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        raise SystemExit(f"embedded dictionary {name} must map strings to strings")
    return value


def translatable_keys(page: str) -> set[str]:
    return set(re.findall(r'\bdata-i="([^"]+)"', page))


def screenshot_keys(page: str) -> set[str]:
    keys: set[str] = set()
    for tag in re.findall(r'<img\b[^>]*>', page, re.I | re.S):
        match = re.search(r'\bdata-shot="([^"]+)"', tag)
        if match:
            keys.add(match.group(1))
    return keys


def resolve_content(page: str, cfg: dict) -> tuple[dict[str, str], dict[str, str]]:
    words = cfg.get("strings")
    if words is None and cfg.get("source_dictionary"):
        words = read_embedded_dict(page, cfg["source_dictionary"])
    alts = cfg.get("alts")
    if alts is None and cfg.get("source_alt_dictionary"):
        alts = read_embedded_dict(page, cfg["source_alt_dictionary"])
    if not isinstance(words, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in words.items()):
        raise SystemExit("locale config needs a valid strings/source_dictionary map")
    if not isinstance(alts, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in alts.items()):
        raise SystemExit("locale config needs a valid alts/source_alt_dictionary map")

    expected = translatable_keys(page)
    extra = set(words) - expected
    unexpected = extra - LEGACY_UNUSED_STRING_KEYS
    if unexpected:
        raise SystemExit("unknown data-i keys: " + ", ".join(sorted(unexpected)))
    words = {k: v for k, v in words.items() if k in expected}
    return words, alts


def validate_config(page: str, cfg: dict, words: dict[str, str], alts: dict[str, str]) -> None:
    required = {
        "locale", "html_lang", "path", "og_locale", "title", "description",
        "og_title", "og_description", "og_image_alt", "nav_aria", "language_aria",
        "runtime", "schema",
    }
    missing_fields = sorted(required - set(cfg))
    if missing_fields:
        raise SystemExit("locale config missing fields: " + ", ".join(missing_fields))

    expected = translatable_keys(page)
    actual = set(words)
    if expected != actual:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        parts = []
        if missing:
            parts.append("missing data-i keys: " + ", ".join(missing))
        if extra:
            parts.append("unknown data-i keys: " + ", ".join(extra))
        raise SystemExit("; ".join(parts))

    expected_alts = screenshot_keys(page)
    actual_alts = set(alts)
    if expected_alts != actual_alts:
        missing = sorted(expected_alts - actual_alts)
        extra = sorted(actual_alts - expected_alts)
        parts = []
        if missing:
            parts.append("missing screenshot alts: " + ", ".join(missing))
        if extra:
            parts.append("unknown screenshot alts: " + ", ".join(extra))
        raise SystemExit("; ".join(parts))

    schema = cfg["schema"]
    if len(schema.get("faq", [])) != 6 or len(schema.get("feature_list", [])) != 8:
        raise SystemExit("localized JSON-LD must keep six FAQ entries and eight feature-list entries")


def element_span(page: str, start: int) -> tuple[int, int] | None:
    tag_match = re.match(r"<([a-zA-Z0-9]+)", page[start:])
    if not tag_match or tag_match.group(1).lower() in VOID:
        return None
    tag = tag_match.group(1)
    open_end = page.find(">", start)
    if open_end < 0:
        return None
    depth, cursor = 1, open_end + 1
    pattern = re.compile(rf"<(/?){tag}\b", re.I)
    while depth:
        hit = pattern.search(page, cursor)
        if not hit:
            return None
        depth += -1 if hit.group(1) else 1
        cursor = hit.end()
    return open_end + 1, page.rfind("<", 0, cursor)


def translate(page: str, words: dict[str, str]) -> str:
    out: list[str] = []
    cursor = 0
    applied: set[str] = set()
    for hit in re.finditer(r'<[a-zA-Z0-9]+\b[^>]*\bdata-i="([^"]+)"[^>]*>', page, re.S):
        key = hit.group(1)
        if key not in words:
            continue
        span = element_span(page, hit.start())
        if not span:
            continue
        inner_start, inner_end = span
        if inner_start < cursor:
            continue
        out.append(page[cursor:inner_start])
        out.append(words[key])
        cursor = inner_end
        applied.add(key)
    out.append(page[cursor:])
    missing = set(words) - applied
    if missing:
        raise SystemExit("translations did not land for: " + ", ".join(sorted(missing)))
    return "".join(out)


def replace_screenshot_alts(page: str, alts: dict[str, str]) -> str:
    for key, text in alts.items():
        pattern = rf'(<img\b(?=[^>]*\bdata-shot="{re.escape(key)}")[^>]*\balt=")[^"]*(")'
        page, count = re.subn(pattern, lambda m, value=text: m.group(1) + value + m.group(2), page, count=1, flags=re.I | re.S)
        if count != 1:
            raise SystemExit(f"screenshot alt did not land for: {key}")
    return page


def localized_schema(page: str, cfg: dict) -> dict:
    match = re.search(r'<script type="application/ld\+json" id="software-schema">(.*?)</script>', page, re.S)
    if not match:
        raise SystemExit("software JSON-LD not found")
    schema = json.loads(match.group(1))
    graph = schema["@graph"]
    locale = cfg["locale"]
    local = cfg["schema"]
    shot_locale = cfg.get("screenshot_locale", locale)

    person = next(i for i in graph if i.get("@type") == "Person")
    person["name"] = cfg.get("author", person.get("name", ""))
    website = next(i for i in graph if i.get("@type") == "WebSite")
    website["name"] = cfg.get("application_name", "Impuls")
    website["inLanguage"] = cfg.get("site_languages", [code for code, _, _ in SITE_LOCALES])
    app = next(i for i in graph if i.get("@type") == "SoftwareApplication")
    app["@id"] = SITE + cfg["path"] + "#software"
    app["description"] = local["software_description"]
    app["featureList"] = local["feature_list"]
    app["inLanguage"] = locale
    app["screenshot"] = SITE + f"assets/screens/{shot_locale}/actions.png"
    app["offers"] = {"@type": "Offer", "price": "0", "priceCurrency": local["price_currency"]}
    if local.get("alternate_name"):
        app["alternateName"] = local["alternate_name"]
    faq = next(i for i in graph if i.get("@type") == "FAQPage")
    faq["@id"] = SITE + cfg["path"] + "#faq-schema"
    faq["mainEntity"] = [
        {"@type": "Question", "name": item["question"], "acceptedAnswer": {"@type": "Answer", "text": item["answer"]}}
        for item in local["faq"]
    ]
    return schema


def replace_og_locales(page: str, current: str) -> str:
    block = f'<meta property="og:locale" content="{OG_LOCALES[current]}">\n' + "\n".join(
        f'<meta property="og:locale:alternate" content="{OG_LOCALES[code]}">'
        for code, _, _ in SITE_LOCALES if code != current
    ) + "\n"
    page, count = re.subn(
        r'<meta property="og:locale" content="[^"]+">\n(?:<meta property="og:locale:alternate" content="[^"]+">\n)*',
        block, page, count=1,
    )
    if count != 1:
        raise SystemExit("OpenGraph locale block not found")
    return page


def language_control(current: str, aria: str) -> str:
    links = []
    for code, label, path in SITE_LOCALES:
        href = "./" if code == current else ("../" if code == "ru" else "../" + path)
        current_attr = ' aria-current="page"' if code == current else ""
        links.append(f'        <a id="btn-{code}" href="{href}" hreflang="{code}"{current_attr}>{label}</a>')
    return f'<div class="lang" role="group" aria-label="{aria}">\n' + "\n".join(links) + "\n      </div>"


def build(source: str, cfg: dict) -> str:
    words, alts = resolve_content(source, cfg)
    validate_config(source, cfg, words, alts)
    locale = cfg["locale"]
    page = translate(source, words)
    page = page.replace("assets/screens/ru/", f"assets/screens/{cfg.get('screenshot_locale', locale)}/")
    page = replace_screenshot_alts(page, alts)

    runtime = cfg["runtime"]
    decimal = runtime.get("decimal", ".")
    page = re.sub(r'(<span data-release="version-label">)\S+\s+([^<]*)(</span>)', lambda m: m.group(1) + runtime["version"] + " " + m.group(2) + m.group(3), page)
    page = re.sub(r'(<span data-release="size">)([\d,\.]+) МБ(</span>)', lambda m: m.group(1) + m.group(2).replace(",", decimal).replace(".", decimal) + " " + runtime["size_unit"] + m.group(3), page)

    replacements = [
        (r'<html lang="ru">', f'<html lang="{cfg["html_lang"]}">'),
        (r'<title>[^<]*</title>', f'<title>{cfg["title"]}</title>'),
        (r'(<meta name="description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["description"] + m.group(2)),
        (r'(<link rel="canonical" href=")[^"]*(">)', lambda m: m.group(1) + SITE + cfg["path"] + m.group(2)),
        (r'(<meta property="og:url" content=")[^"]*(">)', lambda m: m.group(1) + SITE + cfg["path"] + m.group(2)),
        (r'(<meta property="og:title" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_title"] + m.group(2)),
        (r'(<meta property="og:description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_description"] + m.group(2)),
        (r'(<meta property="og:image:alt" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_image_alt"] + m.group(2)),
        (r'(<meta name="twitter:title" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_title"] + m.group(2)),
        (r'(<meta name="twitter:description" content=")[^"]*(">)', lambda m: m.group(1) + cfg["og_description"] + m.group(2)),
        (r'(<meta name="application-name" content=")[^"]*(">)', lambda m: m.group(1) + cfg.get("application_name", "Impuls") + m.group(2)),
        (r'(<meta name="author" content=")[^"]*(">)', lambda m: m.group(1) + cfg.get("author", "Nikolay Tumanov") + m.group(2)),
        (r'<nav class="nav-links" aria-label="[^"]*">', f'<nav class="nav-links" aria-label="{cfg["nav_aria"]}">'),
    ]
    for pattern, replacement in replacements:
        page = re.sub(pattern, replacement, page, count=1)
    page = replace_og_locales(page, locale)

    schema = localized_schema(page, cfg)
    page = re.sub(r'<script type="application/ld\+json" id="software-schema">.*?</script>', '<script type="application/ld+json" id="software-schema">\n' + json.dumps(schema, ensure_ascii=False, indent=2) + '\n</script>', page, flags=re.S)
    page = re.sub(r'((?:href|src|srcset)=")(assets/|manifest\.webmanifest|site-privacy\.html)', r'\g<1>../\g<2>', page)

    control = language_control(locale, cfg["language_aria"])
    page, count = re.subn(r'<div class="lang" role="group" aria-label="[^"]*">.*?</div>', control, page, count=1, flags=re.S)
    if count != 1:
        raise SystemExit("language control not found")

    labels = {"version": runtime["version"], "sizeUnit": runtime["size_unit"], "decimal": decimal, "copied": runtime["copied"], "modules": runtime["modules"]}
    marker = "<script>document.documentElement.classList.add('js')</script>"
    bootstrap = "<script>document.documentElement.classList.add('js');" + f"window.IMPULS_LANG={json.dumps(locale)};" + f"window.IMPULS_LABELS={json.dumps(labels, ensure_ascii=False, separators=(',', ':'))}" + "</script>"
    if marker not in page:
        raise SystemExit("JavaScript bootstrap marker not found")
    page = page.replace(marker, bootstrap, 1)
    return f"<!-- Generated by Scripts/build-site-locale.py from ../index.html using Scripts/site-locales/{locale}.json. Do not edit this page directly. -->\n" + page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--check", action="store_true")
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
