---
paths:
  - "docs/**"
  - "Scripts/build-site-locale.py"
  - "Scripts/site-locales/**"
  - "Scripts/sync-site-locales.py"
  - "Scripts/sync-site-sitemap.py"
  - "Scripts/sync-site-release.py"
  - "Scripts/sync-site-product-facts.py"
  - ".github/workflows/site-localization.yml"
  - ".github/workflows/site-release-sync.yml"
  - "knowledge-base/07-web/**"
---

# The Impuls website

Read `knowledge-base/07-web/website.md` before changing website content, locale configs, generators or synchronization. `knowledge-base/07-web/design-system.md` owns presentation intent.

## Static architecture

- `docs/index.html` is the canonical RU content/layout source served by GitHub Pages.
- `docs/en/`, `docs/de/`, `docs/fr/`, `docs/es/`, `docs/ja/` and `docs/zh-hans/` are generated; never hand-edit them as independent pages.
- One generator owns generated pages: `Scripts/build-site-locale.py`.
- `Scripts/site-locales/registry.json` is the canonical public website-locale list.
- Website locales are currently **ru / en / de / fr / es / ja / zh-Hans**.
- App interface localizations are currently the same seven BCP-47 codes.
- Website and app locale sets are still separate contracts even when equal.
- The RU page remains self-contained: no external stylesheet, external script or external font dependency.

English body/alt copy is temporarily sourced from the existing embedded `EN` / `ALT` dictionaries via `Scripts/site-locales/en.json`. DE/FR/ES/JA/zh-Hans copy is fully external in the corresponding locale configs. New website languages must use locale configs and the registry; do not create a language-specific Python generator or copy the HTML page.

## Locale routing

`Scripts/site-locales/registry.json` owns locale code, selector label, URL path and OpenGraph locale for every public website page.

**Never derive a public/filesystem path from the locale code.** The current counterexample is `zh-Hans`, whose public path is `/zh-hans/`. Always read `path` from the registry in scripts, workflows and tests.

`Scripts/sync-site-locales.py` projects the registry into the canonical RU source:

- reciprocal `hreflang` + `x-default`;
- OpenGraph locale alternates;
- `WebSite.inLanguage`;
- visible seven-locale selector;
- generated-page runtime labels;
- compatibility redirects from old `?lang=` links using registry paths;
- responsive behavior for the seven-language header.

`Scripts/sync-site-sitemap.py` projects the same registry into `docs/sitemap.xml`. Do not maintain another hardcoded locale list in sitemap, generated pages or workflows.

## Release metadata

Never manually update version/DMG/SHA in one language page only.

- `Scripts/sync-site-release.py` owns static release metadata.
- Runtime JavaScript reads the GitHub Releases API only as a freshness layer.
- Static markup on every locale must already carry the current version, DMG URL, filename, size and SHA-256 for crawlers/no-JS visitors.

These literal contracts must survive edits:

```text
const RELEASE_API = 'https://api.github.com/repos/TumanovNV/impuls/releases/latest';
function releaseHash(asset,body)
data-conversion="feedback"
```

A normal app release must not require hand-editing any localized HTML page.

## Durable product facts

`Scripts/sync-site-product-facts.py` owns durable marketing facts in the canonical RU source. The current localization capability is visible on every public website locale:

- RU: `7 языков интерфейса`;
- EN: `7 interface languages`;
- DE: `7 Sprachen`;
- FR: `7 langues`;
- ES: `7 idiomas`;
- JA: `7 言語対応`;
- zh-Hans: `支持 7 种语言`;
- each FAQ lists the seven app interface languages and System/manual language behaviour.

When the shipped app locale set changes, do not patch a generated page or a number in isolation. Update the app contract, product-fact owner, affected locale configs and workflow assertions together.

## Generated-page flow

Site-sync order is fixed:

```bash
python3 Scripts/sync-site-release.py
python3 Scripts/sync-site-product-facts.py
python3 Scripts/sync-site-locales.py
python3 Scripts/sync-site-sitemap.py
# Then build every non-default locale code from registry.json.
python3 Scripts/build-site-locale.py --locale <locale>

python3 Scripts/sync-site-release.py --check
python3 Scripts/sync-site-product-facts.py --check
python3 Scripts/sync-site-locales.py --check
python3 Scripts/sync-site-sitemap.py --check
python3 Scripts/build-site-locale.py --locale <locale> --check
```

Generation uses locale code to select the config, but checks/commit paths use the separate registry `path`. The online release check belongs to `.github/workflows/site-release-sync.yml`. That workflow may commit only canonical/generated website markup and `docs/sitemap.xml`. It must never change `Scripts/version`, sign/tag an app or upload release assets.

## Adding another website language

Do not create `build-<locale>-page.py` or another HTML copy. Add a complete locale config under `Scripts/site-locales/`, add one registry entry with both code and public path, extend language-specific copy assertions/tests, then let registry-driven sync/generation update the cluster and sitemap. The page is public only after its real static URL exists.

DE/FR/ES/JA/zh-Hans translations are AI-assisted and technically reviewed; do not claim native-speaker linguistic review unless it actually happens.

## No-JavaScript contract

Without JavaScript on every locale:

- download buttons point to the real DMG;
- version, size, filename and SHA-256 are present;
- body/head/FAQ and durable product facts are already localized;
- module content remains readable;
- content is not hidden behind observer-dependent opacity.

Runtime JS may refresh release metadata and interaction. It must not be the translation mechanism for external locales.

## Theme / responsive safety

The site follows `prefers-color-scheme`; review light and dark for presentation changes. With seven locale links, at `<=699px` the wordmark text collapses and only the locale strip gets its own horizontal scroll; Download remains separate. At `<=359px` the brand icon also hides to preserve room. The whole page must never gain horizontal scroll, and the language selector must remain usable without JavaScript.

Do not add external font/CSS/JS frameworks without an explicit architecture decision.

## SEO and public pages

- RU, EN, DE, FR, ES, JA and Simplified Chinese have real static URLs and self-canonical localized heads.
- `registry.json`, `sitemap.xml`, canonical, reciprocal hreflang, OG locale alternates and JSON-LD must agree with the real public locale set.
- `x-default` remains the RU root.
- `zh-Hans` must use BCP-47 in `lang`/`hreflang` but `/zh-hans/` as the public path.

## Screenshots / privacy

Product screenshots must be real captures or clearly demo data. Never publish personal clipboard content, notes, real calendar events, file paths or device identifiers.

DE/FR/ES/JA/zh-Hans currently use the real EN product captures through `screenshot_locale: en`; this is preferable to drawing fake localized UI. Replace them only with real captures from the corresponding app locale.

## Release notes and audits

- `docs/releases/<version>.md` stays RU + EN and is part of the app release contract, not website locale source.
- `docs/audits/` is additive history.
- Current website architecture belongs in `knowledge-base/07-web/website.md`.
