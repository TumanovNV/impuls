---
paths:
  - "docs/**"
  - "Scripts/build-en-page.py"
  - "Scripts/sync-site-release.py"
  - "Scripts/sync-site-product-facts.py"
  - ".github/workflows/site-release-sync.yml"
  - "knowledge-base/07-web/**"
---

# The Impuls website

Read `knowledge-base/07-web/website.md` before changing website content, generators or synchronization. `knowledge-base/07-web/design-system.md` owns presentation intent.

## Static architecture

- `docs/index.html` is the canonical RU content/layout source served by GitHub Pages.
- `docs/en/index.html` is generated from the RU source by `Scripts/build-en-page.py`; never hand-edit it as an independent page.
- The public website currently has **two page locales only**: RU (`/`) and EN (`/en/`).
- The Impuls app currently has **seven interface localizations**: `ru`, `en`, `de`, `fr`, `es`, `zh-Hans`, `ja`.
- Do not confuse app localization with website localization. `hreflang`/website `inLanguage` remain RU/EN until real public pages exist for other languages.
- The RU page remains self-contained: no external stylesheet, no external script and no external font dependency.

## Release metadata

Never manually update version/DMG/SHA in one page only.

- `Scripts/sync-site-release.py` owns static release metadata.
- Runtime JavaScript reads the GitHub Releases API as a freshness layer.
- Static markup must already carry the current version, DMG URL, filename, size and SHA-256 for crawlers and visitors without JavaScript.
- `.github/workflows/site-release-sync.yml` runs the release synchronizer and regenerates EN after release publication.

These literal contracts must survive edits because CI/workflow checks them:

```
const RELEASE_API = 'https://api.github.com/repos/TumanovNV/impuls/releases/latest';
function releaseHash(asset,body)
data-conversion="feedback"
```

A normal app release must not require a manual edit to `docs/index.html` or `docs/en/index.html`.

## Durable product facts

`Scripts/sync-site-product-facts.py` owns small durable marketing facts that must survive release metadata rewrites and EN regeneration.

The current localization fact is intentionally visible in two places:

- hero metadata: `7 языков интерфейса` / `7 interface languages`;
- FAQ: the exact seven app languages and System/manual language behavior.

When the shipped app locale set changes, do **not** patch only the generated HTML or only the number. Update the app localization contract and `sync-site-product-facts.py` together, run its `--check`, regenerate EN, and verify both RU/EN assertions.

Current app-localization list:

```
ru
en
de
fr
es
zh-Hans
ja
```

This is an **app capability**. It does not mean the website itself is available in seven languages.

## Generated-page flow

For changes affecting durable site facts or shared copy, use this order:

```bash
python3 Scripts/sync-site-release.py --check
python3 Scripts/sync-site-product-facts.py
python3 Scripts/build-en-page.py
python3 Scripts/sync-site-product-facts.py --check
python3 Scripts/build-en-page.py --check
```

`sync-site-release.py --check` requires current GitHub release data/network access. In CI, `.github/workflows/site-release-sync.yml` owns the authoritative online release check.

The workflow may commit only `docs/index.html` and `docs/en/index.html`. It must never change `Scripts/version`, sign/tag an app, upload release assets or become a second release path.

## No-JavaScript contract

Without JavaScript:

- download buttons still point directly to the real DMG;
- version, size, filename and SHA-256 are present;
- durable product facts such as the seven-language app capability remain visible;
- module content remains readable;
- content is not hidden behind observer-dependent opacity.

## Theme / CSS safety

The website follows `prefers-color-scheme`; there is no website theme toggle. Review both light and dark appearances for presentation changes.

The current page does not use gradient-clipped headline text. If that technique is introduced again, theme overrides must use `background-image`, not the `background` shorthand, because shorthand resets `background-clip` and can make transparent text disappear.

Do not add external font/CSS/JS frameworks without an explicit architecture decision; the self-contained page is a performance/reliability contract.

## SEO and public pages

- RU and EN have real static URLs and real static head/SEO content.
- `?lang=en` is compatibility-only and redirects to `/en/`.
- `site-privacy.html`, `robots.txt`, `sitemap.xml`, `manifest.webmanifest`, canonical/hreflang and JSON-LD must stay consistent.
- Adding a new public language page requires an explicit sitemap/hreflang/SEO review; adding a new **app** localization alone does not.

## Screenshots / privacy

Product screenshots must be real captures or clearly demo data. Never publish personal clipboard content, notes, real calendar events, file paths or device identifiers.

## Release notes and audits

- `docs/releases/<version>.md` — Russian section, `---`, then English release notes. CI requires the file for `Scripts/version`.
- `docs/audits/` — additive historical security notes; do not rewrite old audits to describe current state.
- Website current-state architecture belongs in `knowledge-base/07-web/website.md`, not in historical release notes.
