#!/usr/bin/env python3
"""Generate `docs/en/index.html` from `docs/index.html`.

The site used to serve English by swapping text in the DOM at `?lang=en`. That
is a fine reading experience and not an English page: the title, description,
canonical, OpenGraph card and JSON-LD stayed Russian, so a crawler, a link
preview and an AI answer engine only ever saw the Russian version. `hreflang`
pointing at a query string that changes nothing in the markup made the claim
worse, not better.

So English gets a real URL with its own static head. It is generated rather than
written twice, because two hand-maintained copies of a 95 KB page diverge on the
first edit and the divergence is invisible until somebody reports it.

    python3 Scripts/build-en-page.py           # write docs/en/index.html
    python3 Scripts/build-en-page.py --check   # exit 1 if it is out of date

The translations are not duplicated here: they are read out of the `EN` and `ALT`
dictionaries that already live in `docs/index.html` and drive the runtime switch.
Only the head — which has no runtime equivalent — is written below.

Pure standard library on purpose. This runs in CI right after
`sync-site-release.py`, on a runner with no browser.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "index.html"
TARGET = ROOT / "docs" / "en" / "index.html"

SITE = "https://tumanovnv.github.io/impuls/"

TITLE = "Impuls for macOS — a working surface at the top edge of the screen"
DESCRIPTION = (
    "Impuls is a free macOS app. One panel at the top edge of any screen: search across "
    "clipboard history, snippets and notes, a file shelf, scratch notes, translation, "
    "your next meeting, music and the charge of your Apple devices. Local, no account, "
    "open source."
)
OG_TITLE = "Impuls for macOS — one panel instead of a dozen switches"
OG_DESCRIPTION = (
    "A panel at the top edge of any Mac screen: clipboard, files, notes, translation and "
    "device charge, right where you are working. Free, local, open source."
)

# The English graph. Kept beside the Russian one in docs/index.html rather than
# translated at build time, because a machine-translated FAQ answer is exactly the
# kind of thing that quietly stops matching what the app does.
SCHEMA_EN = {
    "@context": "https://schema.org",
    "@graph": [
        {
            "@type": "SoftwareApplication",
            "@id": SITE + "en/#software",
            "name": "Impuls",
            "description": (
                "A free, local macOS app. A panel at the top edge of any screen brings together "
                "search across clipboard history, snippets and notes, a file shelf, translation, "
                "your calendar, music and the battery level of your Apple devices."
            ),
            "applicationCategory": "UtilitiesApplication",
            "operatingSystem": "macOS 15 or later",
            "softwareVersion": "1.4.9",
            "fileSize": "4.4 MB",
            "datePublished": "2026-08-13",
            "downloadUrl": "https://github.com/TumanovNV/impuls/releases/download/v1.4.9/Impuls-1.4.9.dmg",
            "installUrl": "https://github.com/TumanovNV/impuls/releases/download/v1.4.9/Impuls-1.4.9.dmg",
            "releaseNotes": "https://github.com/TumanovNV/impuls/releases/tag/v1.4.9",
            "softwareHelp": "https://github.com/TumanovNV/impuls/issues",
            "license": "https://github.com/TumanovNV/impuls/blob/main/LICENSE",
            "codeRepository": "https://github.com/TumanovNV/impuls",
            "author": {"@type": "Organization", "name": "Integra Impuls"},
            "publisher": {"@type": "Organization", "name": "Integra Impuls"},
            "image": SITE + "assets/og-impuls.png",
            "screenshot": SITE + "assets/screens/en/actions.png",
            "softwareRequirements": "macOS 15 or later",
            "isAccessibleForFree": True,
            "inLanguage": "en",
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "featureList": [
                "The panel opens on hover or with a global shortcut, above any application",
                "One search across clipboard history, snippets and notes",
                "A file shelf with text recognition, background removal, conversion and PDF",
                "Notes, translation and your next meeting within reach",
                "The charge of your Mac, AirPods, iPhone and iPad in one place",
                "Present on every connected display, including Sidecar",
                "Works with VoiceOver and from the keyboard",
                "No account, no cloud, no telemetry",
            ],
        },
        {
            "@type": "FAQPage",
            "@id": SITE + "en/#faq-schema",
            "mainEntity": [
                {
                    "@type": "Question",
                    "name": "Do I need a MacBook with a notch?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "No. On a MacBook with a cutout the panel uses its geometry; on any other "
                            "screen Impuls draws a compact black anchor of 120 x 12 pt at the top edge. "
                            "It works on the built-in display, on an external monitor and on an iPad "
                            "running as a Sidecar display."
                        ),
                    },
                },
                {
                    "@type": "Question",
                    "name": "Does Impuls send my clipboard and files to the internet?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "No. Clipboard, notes, snippets, files and calendar stay on the Mac. The "
                            "network is used in two explicit cases: the update check you enable "
                            "yourself, and the web player that opens only when you press Open Web Player."
                        ),
                    },
                },
                {
                    "@type": "Question",
                    "name": "What does Impuls cost?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "Nothing. Impuls is free, open source under GPL-3.0-or-later, and needs no "
                            "account."
                        ),
                    },
                },
                {
                    "@type": "Question",
                    "name": "Why does macOS refuse to open Impuls on first launch?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "The build is ad-hoc signed and not yet notarized by Apple, which needs a "
                            "Developer ID. The first launch goes through System Settings > Privacy & "
                            "Security > Open Anyway. After that Impuls updates itself through a signed "
                            "channel and checks the signature before unpacking."
                        ),
                    },
                },
                {
                    "@type": "Question",
                    "name": "Why are some Battery values missing?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "Impuls shows only what macOS publishes about that particular Mac. "
                            "Temperature, cycles, full capacity and connector type are missing on some "
                            "machines, and rather than invent a value the panel leaves it unavailable. "
                            "On a Mac mini, Mac Studio, iMac or Mac Pro the module is called Power."
                        ),
                    },
                },
                {
                    "@type": "Question",
                    "name": "How does Impuls read the charge of an iPhone or iPad?",
                    "acceptedAnswer": {
                        "@type": "Answer",
                        "text": (
                            "Through the trust the device has already given this Mac: over USB, or "
                            "through Finder Wi-Fi sync. No pairing is created, no local network is "
                            "scanned, and there is no direct connection to the device. Discovery is off "
                            "by default and iPhone and iPad support is marked Beta."
                        ),
                    },
                },
            ],
        },
    ],
}

VOID = {"img", "br", "hr", "input", "meta", "link", "source", "path", "circle", "rect", "svg"}


def read_dict(page: str, name: str) -> dict:
    """Pull one of the page's own JavaScript dictionaries out as data."""
    match = re.search(rf"var {name} = (\{{.*?\n\}});", page, re.S)
    if not match:
        raise SystemExit(f"could not find the {name} dictionary in docs/index.html")
    return json.loads(match.group(1))


def element_span(page: str, start: int) -> tuple[int, int, str] | None:
    """Given the offset of a start tag, return its inner-content span.

    Written by hand rather than with a regex because several translated elements
    contain nested markup, and `.*?` up to the first closing tag silently
    truncates them.
    """
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


def translate(page: str, words: dict) -> str:
    """Do to the markup exactly what setLang() does to the DOM."""
    out, cursor, applied = [], 0, 0
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
        applied += 1
    out.append(page[cursor:])
    if applied < len(words) * 0.8:
        raise SystemExit(f"only {applied} of {len(words)} translations landed; markup may have changed")
    print(f"  translated {applied} elements")
    return "".join(out)


def build(page: str) -> str:
    words = read_dict(page, "EN")
    alts = read_dict(page, "ALT")

    page = translate(page, words)

    # Screenshots have a language of their own.
    page = page.replace("assets/screens/ru/", "assets/screens/en/")
    for name, text in alts.items():
        page = re.sub(
            rf'(<img[^>]*data-shot="{re.escape(name)}"[^>]*\balt=")[^"]*(")',
            lambda m, t=text: m.group(1) + t + m.group(2),
            page,
        )

    # Release facts that the Russian markup words in Russian.
    page = re.sub(
        r'(<span data-release="version-label">)\S+\s+([^<]*)(</span>)',
        r"\g<1>Version \g<2>\g<3>", page)
    page = re.sub(
        r'(<span data-release="size">)([\d,]+) МБ(</span>)',
        lambda m: m.group(1) + m.group(2).replace(",", ".") + " MB" + m.group(3),
        page,
    )

    # The head, which has no runtime equivalent and is the whole point.
    head_swaps = [
        (r'<html lang="ru">', '<html lang="en">'),
        (r"<title>[^<]*</title>", f"<title>{TITLE}</title>"),
        (r'(<meta name="description" content=")[^"]*(">)', rf"\g<1>{DESCRIPTION}\g<2>"),
        (r'(<link rel="canonical" href=")[^"]*(">)', rf"\g<1>{SITE}en/\g<2>"),
        (r'(<meta property="og:url" content=")[^"]*(">)', rf"\g<1>{SITE}en/\g<2>"),
        (r'(<meta property="og:locale" content=")[^"]*(">)', r"\g<1>en_US\g<2>"),
        (r'(<meta property="og:locale:alternate" content=")[^"]*(">)', r"\g<1>ru_RU\g<2>"),
        (r'(<meta property="og:title" content=")[^"]*(">)', rf"\g<1>{OG_TITLE}\g<2>"),
        (r'(<meta property="og:description" content=")[^"]*(">)', rf"\g<1>{OG_DESCRIPTION}\g<2>"),
        (r'(<meta property="og:image:alt" content=")[^"]*(">)', r"\g<1>The Impuls panel at the top edge of a Mac screen\g<2>"),
        (r'(<meta name="twitter:title" content=")[^"]*(">)', rf"\g<1>{OG_TITLE}\g<2>"),
        (r'(<meta name="twitter:description" content=")[^"]*(">)', rf"\g<1>{OG_DESCRIPTION}\g<2>"),
        (r'(<meta name="application-name" content=")[^"]*(">)', r"\g<1>Impuls\g<2>"),
        (r'(<meta name="author" content=")[^"]*(">)', r"\g<1>Integra Impuls\g<2>"),
        (r'<link rel="alternate" hreflang="ru" href="[^"]*">', f'<link rel="alternate" hreflang="ru" href="{SITE}">'),
        (r'<link rel="alternate" hreflang="en" href="[^"]*">', f'<link rel="alternate" hreflang="en" href="{SITE}en/">'),
        (r'<link rel="alternate" hreflang="x-default" href="[^"]*">', f'<link rel="alternate" hreflang="x-default" href="{SITE}">'),
        (r'<nav class="nav-links" aria-label="[^"]*">', '<nav class="nav-links" aria-label="Sections of this page">'),
        (r'<div class="lang" role="group" aria-label="[^"]*">', '<div class="lang" role="group" aria-label="Page language">'),
        (r'<div class="rail" id="rail" hidden></div>', '<div class="rail" id="rail" hidden></div>'),
    ]
    for pattern, replacement in head_swaps:
        page = re.sub(pattern, replacement, page, count=1)

    # The English graph takes its release facts from the Russian page rather than
    # from the literal above. sync-site-release.py has already written the current
    # release there; copying it here is what stops docs/en/ becoming the next
    # place that quietly advertises an old version.
    source_schema = re.search(
        r'<script type="application/ld\+json" id="software-schema">(.*?)</script>', page, re.S)
    if not source_schema:
        raise SystemExit("no JSON-LD found in docs/index.html")
    current = json.loads(source_schema.group(1))
    ru_app = next(i for i in current["@graph"] if i.get("@type") == "SoftwareApplication")

    schema = json.loads(json.dumps(SCHEMA_EN))
    en_app = next(i for i in schema["@graph"] if i.get("@type") == "SoftwareApplication")
    for key in ("softwareVersion", "fileSize", "datePublished",
                "downloadUrl", "installUrl", "releaseNotes"):
        en_app[key] = ru_app[key]

    page = re.sub(
        r'<script type="application/ld\+json" id="software-schema">.*?</script>',
        '<script type="application/ld+json" id="software-schema">\n'
        + json.dumps(schema, ensure_ascii=False, indent=2)
        + "\n</script>",
        page,
        flags=re.S,
    )

    # One directory down, so every relative asset gains a level.
    page = re.sub(r'((?:href|src|srcset)=")(assets/|manifest\.webmanifest|site-privacy\.html)', r"\g<1>../\g<2>", page)

    # Both pages navigate rather than toggle; only the direction differs. The
    # replacement is asserted rather than attempted, because a silent miss here
    # leaves the English page pointing "EN" at en/en/.
    before = page
    page = page.replace(
        """<a id="btn-ru" href="./" hreflang="ru" aria-current="page">RU</a>
        <a id="btn-en" href="en/" hreflang="en">EN</a>""",
        """<a id="btn-ru" href="../" hreflang="ru">RU</a>
        <a id="btn-en" href="./" hreflang="en" aria-current="page">EN</a>""",
    )
    if page == before:
        raise SystemExit("the language control in docs/index.html no longer matches; update build-en-page.py")

    page = page.replace(
        "<script>document.documentElement.classList.add('js')</script>",
        "<script>document.documentElement.classList.add('js');window.IMPULS_LANG='en'</script>",
        1,
    )

    banner = (
        "<!-- Generated by Scripts/build-en-page.py from ../index.html. Do not edit:\n"
        "     change the Russian page or the EN dictionary inside it and re-run the script. -->\n"
    )
    return banner + page


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 when the English page is out of date")
    args = parser.parse_args()

    built = build(SOURCE.read_text(encoding="utf-8"))

    if args.check:
        current = TARGET.read_text(encoding="utf-8") if TARGET.exists() else ""
        if current != built:
            print("docs/en/index.html is out of date; run Scripts/build-en-page.py", file=sys.stderr)
            return 1
        print("docs/en/index.html is current")
        return 0

    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(built, encoding="utf-8")
    print(f"wrote {TARGET.relative_to(ROOT)} ({len(built)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
